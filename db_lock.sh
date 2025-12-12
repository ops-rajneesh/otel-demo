#!/usr/bin/env bash
set -euo pipefail

# Acquire a PostgreSQL advisory lock inside a Postgres pod in Kubernetes and hold it
# for a specified duration. Robust quoting and validation to avoid "not acquiring" errors.
#
# Usage:
#  ./db_lock_acquire_k8s.sh -n namespace [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] -t seconds [-P password]

NAMESPACE="otel-demo"
POD=""
LABEL=""
DB="${POSTGRES_DB:-postgres}"
USER="${POSTGRES_USER:-root}"
LOCKID=424242
DURATION=""
PGPASSWORD="${POSTGRES_PASSWORD:-}"

usage(){
  cat <<EOF
Usage: $0 -t seconds [-n namespace] [-p pod] [-l label] [-d dbname] [-U user] [-L lockid] [-P password]
  -n namespace   Kubernetes namespace (default: ${NAMESPACE})
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
  echo "Error: duration (-t) is required" >&2
  usage
fi

# Validate numeric values
if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
  echo "Error: duration (-t) must be a positive integer (seconds)." >&2
  exit 2
fi
if ! [[ "$LOCKID" =~ ^-?[0-9]+$ ]]; then
  echo "Error: lock id (-L) must be an integer." >&2
  exit 2
fi

# Find pod if not provided
if [ -z "$POD" ]; then
  if [ -n "$LABEL" ]; then
    POD=$(kubectl get pods -n "$NAMESPACE" -l "$LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  else
    POD=$(kubectl get pods -n "$NAMESPACE" --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep -i postgres | head -n1 || true)
  fi
fi

if [ -z "$POD" ]; then
  echo "Could not find Postgres pod in namespace '$NAMESPACE'. Specify with -p POD or -l label selector." >&2
  echo "Run: kubectl get pods -n $NAMESPACE" >&2
  exit 3
fi

echo "Will acquire advisory lock id=${LOCKID} on database='${DB}' in pod='${POD}' (ns='${NAMESPACE}') for ${DURATION}s"

# Build the SQL content (safe - no inline quoting problems)
read -r -d '' SQL <<EOF || true
BEGIN;
SELECT pg_advisory_lock(${LOCKID});
-- hold the lock for ${DURATION} seconds
SELECT pg_sleep(${DURATION});
COMMIT;
EOF

# Create a temporary SQL file on the pod and run it under nohup so it keeps running in background
# Also write minimal debug log to /tmp/db_lock.log inside the pod (if needed).
kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "cat > /tmp/db_lock.sql <<'SQLEOF'
$SQL
SQLEOF
PGPASSWORD='${PGPASSWORD}' nohup bash -lc \"PGPASSWORD='${PGPASSWORD}' psql -v ON_ERROR_STOP=1 -U '${USER}' -d '${DB}' -f /tmp/db_lock.sql >>/tmp/db_lock.log 2>&1 &\" >/dev/null 2>&1 || true"

echo "Dispatched lock job to pod '$POD'. Background process will write logs to /tmp/db_lock.log inside the pod."
echo "To verify run:"
echo "  kubectl exec -n ${NAMESPACE} ${POD} -- psql -U ${USER} -d ${DB} -c \"SELECT * FROM pg_locks WHERE locktype='advisory';\""
echo "Or check the job log inside pod:"
echo "  kubectl exec -n ${NAMESPACE} ${POD} -- tail -n +1 /tmp/db_lock.log || true"
