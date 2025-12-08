#!/usr/bin/env bash
set -euo pipefail

# Find and terminate the psql session(s) holding advisory locks in a Kubernetes
# Postgres pod so locks are released earlier than the original duration.
#
# Usage:
#  ./db_lock_release_k8s.sh [-n namespace] [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] [-P password]

NAMESPACE="default"
POD=""
LABEL=""
DB="${POSTGRES_DB:-postgres}"
USER="${POSTGRES_USER:-root}"
LOCKID=""
PGPASSWORD="${POSTGRES_PASSWORD:-}"

usage(){
  cat <<EOF
Usage: $0 [-n namespace] [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] [-P password]
  -n namespace   Kubernetes namespace (default: default)
  -p pod         Exact Postgres pod name to exec into
  -l label       Label selector to find a Postgres pod (e.g. "app=postgresql")
  -d dbname      Database name (default from POSTGRES_DB or 'postgres')
  -U user        DB user (default from POSTGRES_USER or 'root')
  -L lockid      Advisory lock id (optional) - if provided will try to kill sessions
  -P password    Postgres password (optional) or set via POSTGRES_PASSWORD env
EOF
  exit 2
}

while getopts ":n:p:l:d:U:L:P:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    p) POD="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    U) USER="$OPTARG" ;;
    L) LOCKID="$OPTARG" ;;
    P) PGPASSWORD="$OPTARG" ;;
    *) usage ;;
  esac
done

# Find pod if not provided
if [ -z "$POD" ]; then
  if [ -n "$LABEL" ]; then
    POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}') || true
  else
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep -i postgres | head -n1 || true)
  fi
fi

if [ -z "$POD" ]; then
  echo "Could not find Postgres pod. Specify with -p POD or -l label selector." >&2
  exit 3
fi

if [ -n "$LOCKID" ]; then
  echo "Attempting to terminate sessions holding advisory lock id=$LOCKID in pod=$POD"
  SQL="SELECT pg_terminate_backend(pid) FROM pg_locks l JOIN pg_stat_activity a ON l.pid = a.pid WHERE l.locktype = 'advisory' AND l.objid = ${LOCKID};"
else
  echo "Attempting to terminate sessions running pg_advisory_lock() or idle-in-transaction in pod=$POD"
  SQL="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_advisory_lock(%' AND state = 'idle in transaction';"
fi

# Execute the termination SQL inside the pod
kubectl exec -n "$NAMESPACE" -i "$POD" -- bash -lc "PGPASSWORD='$PGPASSWORD' psql -v ON_ERROR_STOP=1 -U '$USER' -d '$DB' -c \"$SQL\""

echo "Release attempt complete."
