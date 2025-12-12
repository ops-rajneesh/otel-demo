#!/usr/bin/env bash
set -euo pipefail

# chaos_table_lock.sh
# Usage:
#  ./chaos_table_lock.sh --namespace <ns> --pod <pod> --user <dbuser> --schema <schema> --table <table> --seconds <secs> [--sample-interval <s>] [--local-report-dir <path>]
#
# Example:
#  ./chaos_table_lock.sh --namespace otel-demo --pod postgresql-655974c7d-h594n --user root --schema accounting --table shipping --seconds 120 --sample-interval 10

NAMESPACE="otel-demo"
POD="postgresql-655974c7d-h594n"
USER="root"
SCHEMA=""
TABLE=""
SECONDS=60
SAMPLE_INTERVAL=10
LOCAL_REPORT_DIR=""
PGPASSWORD="${PGPASSWORD:-}"

print_usage(){
  cat <<EOF
Usage: $0 --namespace <ns> --pod <pod> --user <dbuser> --schema <schema> --table <table> --seconds <secs> [--sample-interval <s>] [--local-report-dir <path>]
  --namespace         Kubernetes namespace (default: ${NAMESPACE})
  --pod               Postgres pod name (default: ${POD})
  --user              Postgres user (default: ${USER})
  --schema            Schema name containing the table (required)
  --table             Table name (required). For reserved words like order, pass: order
  --seconds           How long to hold lock (seconds). Default: ${SECONDS}
  --sample-interval   How often to snapshot pg_locks / pg_stat_activity (seconds). Default: ${SAMPLE_INTERVAL}
  --local-report-dir  Optional: local path to copy the chaos report to after run
EOF
  exit 1
}

# parse args
while [ $# -gt 0 ]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --pod) POD="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --schema) SCHEMA="$2"; shift 2 ;;
    --table) TABLE="$2"; shift 2 ;;
    --seconds) SECONDS="$2"; shift 2 ;;
    --sample-interval) SAMPLE_INTERVAL="$2"; shift 2 ;;
    --local-report-dir) LOCAL_REPORT_DIR="$2"; shift 2 ;;
    -h|--help) print_usage ;;
    *)
      echo "Unknown arg: $1"; print_usage ;;
  esac
done

if [ -z "$SCHEMA" ] || [ -z "$TABLE" ]; then
  echo "ERROR: --schema and --table are required"
  print_usage
fi

# ensure numeric
if ! [[ "$SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --seconds must be a positive integer"
  exit 2
fi
if ! [[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --sample-interval must be a positive integer"
  exit 2
fi

echo "Namespace: $NAMESPACE"
echo "Pod: $POD"
echo "User: $USER"
echo "Schema: $SCHEMA"
echo "Table: $TABLE"
echo "Lock duration: $SECONDS seconds"
echo "Sample interval: $SAMPLE_INTERVAL seconds"

# helper to run SQL inside the pod
kubectl_exec() {
  kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "$1"
}

echo
echo "Step 1: Detect database that contains ${SCHEMA}.${TABLE} ..."
# find database that contains the table
DBNAME=$(kubectl_exec "for db in \$(psql -U $USER -tAc \"SELECT datname FROM pg_database WHERE datistemplate = false\"); do \
  if psql -U $USER -d \"\$db\" -tAc \"SELECT 1 FROM information_schema.tables WHERE table_schema = '$SCHEMA' AND table_name = '$TABLE'\" | grep -q 1; then \
    echo \$db; break; \
  fi; \
done")

if [ -z "$DBNAME" ]; then
  echo "ERROR: Table ${SCHEMA}.${TABLE} not found in any database on this server."
  echo "Run the SQL that creates the schema/tables or point to the correct postgres instance."
  exit 3
fi

echo "Found table in database: $DBNAME"

# prepare fully qualified table identifier, properly quoted
# Use double quotes for schema and table if necessary
# If table contains uppercase or is a reserved word, we must quote it. We'll always quote to be safe.
QSCHEMA=$(printf '%q' "$SCHEMA")  # for safe embedding in here-doc
QTABLE=$(printf '%q' "$TABLE")
FQ="\"$SCHEMA\".\"$TABLE\""
# But prefer unquoted schema (usual usage): schema.table normally works; still we will also use ::regclass checks with explicit quoting below.

TS=$(date +%Y%m%dT%H%M%S)
REMOTE_SQL="/tmp/chaos_lock_${TS}.sql"
REMOTE_LOG="/tmp/chaos_lock_${TS}.log"
REPORT="/tmp/chaos_report_${TS}.txt"

echo
echo "Step 2: Create lock SQL on pod: $REMOTE_SQL"

kubectl_exec "cat > $REMOTE_SQL <<'SQL'
-- lock single table for chaos testing
BEGIN;
LOCK TABLE $SCHEMA.\"$TABLE\" IN ACCESS EXCLUSIVE MODE;
-- hold the lock
SELECT pg_sleep($SECONDS);
COMMIT;
SQL"

echo "SQL written to $REMOTE_SQL"

echo
echo "Step 3: Start lock job in background (nohup). Output will go to $REMOTE_LOG"

kubectl_exec "nohup bash -lc \"psql -U $USER -d $DBNAME -f $REMOTE_SQL\" >> $REMOTE_LOG 2>&1 &"

echo "Lock job dispatched. Background log: $REMOTE_LOG"

echo
echo "Step 4: Start sampling / chaos report generation into $REPORT"

# create report header
kubectl_exec "cat > $REPORT <<'HDR'
Chaos report for table: ${SCHEMA}.${TABLE}
Started: $(date -u)
Pod: ${POD}
DB: ${DBNAME}
Lock duration: ${SECONDS}s
Sample interval: ${SAMPLE_INTERVAL}s

HDR"

# Sampling loop runs inside pod (so it won't be affected by local connection)
kubectl_exec "bash -lc 'END_TIME=\$(( \$(date +%s) + $SECONDS + 10 )); \
while [ \$(date +%s) -le \$END_TIME ]; do \
  echo \"--- SAMPLE: \$(date -u) ---\" >> $REPORT; \
  echo \"pg_locks (relation::regclass, mode, granted):\" >> $REPORT; \
  psql -U $USER -d $DBNAME -c \"SELECT relation::regclass AS table_name, mode, granted, pid, virtualtransaction FROM pg_locks WHERE relation = '$SCHEMA.\"$TABLE\"'::regclass OR (locktype='advisory' AND objid = 424242) ORDER BY granted DESC;\" >> $REPORT 2>&1 || true; \
  echo \"pg_stat_activity (lock/pg_sleep related):\" >> $REPORT; \
  psql -U $USER -d $DBNAME -c \"SELECT pid, usename, datname, state, now()-query_start AS age, query FROM pg_stat_activity WHERE query ILIKE '%LOCK TABLE%' OR query ILIKE '%pg_sleep%' OR query ILIKE '%pg_advisory_lock%' ORDER BY query_start DESC LIMIT 50;\" >> $REPORT 2>&1 || true; \
  echo \"blocked queries (if any):\" >> $REPORT; \
  psql -U $USER -d $DBNAME -c \"SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query, blocking.pid AS blocking_pid, blocking.query AS blocking_query FROM pg_stat_activity blocked JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted JOIN pg_locks br ON bl.locktype = br.locktype AND bl.relation = br.relation AND br.granted = true JOIN pg_stat_activity blocking ON blocking.pid = br.pid;\" >> $REPORT 2>&1 || true; \
  echo \"top processes in pod (ps aux | head -n 20):\" >> $REPORT; ps aux | head -n 20 >> $REPORT; \
  echo \"\" >> $REPORT; \
  sleep $SAMPLE_INTERVAL; \
done; \
echo \"--- END OF SAMPLING: \$(date -u) ---\" >> $REPORT'"

echo "Sampling started inside pod and will run for approx ${SECONDS}+10 seconds. Report file: $REPORT"

echo
echo "Step 5: Quick verification commands (showing sample output live):"
echo "Show current locks for the table:"
echo "kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT relation::regclass AS table_name, mode, granted, pid FROM pg_locks WHERE relation = '$SCHEMA.\"$TABLE\"'::regclass;\""
echo
echo "Show lock-holding sessions / pg_sleep:"
echo "kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT pid, usename, datname, state, now()-query_start AS age, query FROM pg_stat_activity WHERE query ILIKE '%LOCK TABLE%' OR query ILIKE '%pg_sleep%';\""
echo
echo "To tail the background log:"
echo "kubectl exec -n $NAMESPACE $POD -- tail -F $REMOTE_LOG"
echo
echo "To view the generated chaos report inside the pod:"
echo "kubectl exec -n $NAMESPACE $POD -- cat $REPORT"
echo
echo "To copy the chaos report to local machine (if desired):"
echo "kubectl cp $NAMESPACE/$POD:$REPORT ./chaos_report_${TS}.txt"
echo
echo "If you must force-release the lock (destructive):"
echo "  1) find pid that holds lock using pg_stat_activity"
echo "  2) kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT pg_terminate_backend(<pid>);\""
echo
echo "Script finished - lock dispatched and monitoring started. Please monitor app/service behavior and metrics while test runs."
