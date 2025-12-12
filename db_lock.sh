#!/usr/bin/env bash
set -euo pipefail

# Acquire a PostgreSQL advisory lock inside a Postgres pod in Kubernetes and hold it
# for a specified duration. This is the k8s equivalent of `db_lock_acquire.sh`.
#
# Usage:
#  ./db_lock_acquire_k8s.sh -n namespace [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] -t seconds [-P password]
# Provide either `-p pod` or `-l label` (label selector) to locate the Postgres pod.

NAMESPACE="otel-demo2"
POD=""
DB="${POSTGRES_DB:-postgres}"
USER="${POSTGRES_USER:-root}"
LOCKID=424242
DURATION=""
PGPASSWORD="${POSTGRES_PASSWORD:-}"

usage(){
  cat <<EOF
Usage: $0 -t seconds [-n namespace] [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] [-P password]
  -n namespace   Kubernetes namespace (default: default)
  -p pod         Exact Postgres pod name to exec into
  -l label       Label selector to find a Postgres pod (e.g. "app=postgresql")
  -d dbname      Database name (default from POSTGRES_DB or 'postgres')
  -U user        DB user (default from POSTGRES_USER or 'root')
  -L lockid      Advisory lock id (default: ${LOCKID})
  -t seconds     Duration to hold the lock (required)
  -P password    Postgres password (optional) or set via POSTGRES_PASSWORD env
EOF
  exit 2
}

while getopts ":n:p:l:d:U:L:t:P:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    p) POD="$OPTARG" ;;
    l) LABEL="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    U) USER="$OPTARG" ;;
    L) LOCKID="$OPTARG" ;;
    t) DURATION="$OPTARG" ;;
    P) PGPASSWORD="$OPTARG" ;;
    *) usage ;;
  esac
done

if [ -z "$DURATION" ]; then
  echo "Error: duration (-t) is required"
  usage
fi

# Find pod if not provided
if [ -z "$POD" ]; then
  if [ -n "$LABEL" ]; then
    POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}') || true
  else
    # try to heuristically find a postgres pod name containing "postgres"
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" | grep -i postgres | head -n1 || true)
  fi
fi

if [ -z "$POD" ]; then
  echo "Could not find Postgres pod. Specify with -p POD or -l label selector." >&2
  exit 3
fi

echo "Acquiring advisory lock id=$LOCKID on database=$DB in pod=$POD (ns=$NAMESPACE) for ${DURATION}s"

# Build psql command and run it in background inside the pod using nohup
# NOTE: use single quotes around the SQL so parentheses are not mis-parsed by bash
PSQL_CMD="PGPASSWORD='$PGPASSWORD' psql -v ON_ERROR_STOP=1 -U '$USER' -d '$DB' -c 'BEGIN; SELECT pg_advisory_lock(${LOCKID}); SELECT pg_sleep(${DURATION}); COMMIT;'"

# Run PSQL_CMD in background inside the pod
kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "nohup $PSQL_CMD >/dev/null 2>&1 &"

echo "Lock acquire command dispatched to pod $POD. It will hold the lock for ${DURATION}s (or until terminated)."
