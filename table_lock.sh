#!/usr/bin/env bash
set -euo pipefail

# table_lock.sh
# Auto-detect target table (if not provided) and run a table-only ACCESS EXCLUSIVE lock with monitoring.
#
# Usage:
#  ./table_lock.sh [--namespace <ns>] [--pod <pod>] [--user <dbuser>] [--schema <schema>] [--table <table>] [--seconds <secs>] [--sample-interval <s>]
# If --schema/--table omitted, the script will search known candidate tables and auto-select the first found.
#
# Example:
#  ./table_lock.sh --seconds 120
#  ./table_lock.sh --schema accounting --table shipping --seconds 60

# Defaults
NAMESPACE="otel-demo"
POD="postgresql-655974c7d-h594n"
USER="root"
SCHEMA=""
TABLE=""
SECONDS=60
SAMPLE_INTERVAL=10
PGPASSWORD="${PGPASSWORD:-}"

print_usage(){
  cat <<EOF
Usage: $0 [--namespace <ns>] [--pod <pod>] [--user <dbuser>] [--schema <schema>] [--table <table>] [--seconds <secs>] [--sample-interval <s>]
  --namespace         Kubernetes namespace (default: ${NAMESPACE})
  --pod               Postgres pod name (default: ${POD})
  --user              Postgres user (default: ${USER})
  --schema            Schema name containing the table (optional; auto-detect if omitted)
  --table             Table name (optional; auto-detect if omitted)
  --seconds           How long to hold lock (seconds). Default: ${SECONDS}
  --sample-interval   How often to snapshot pg_locks / pg_stat_activity (seconds). Default: ${SAMPLE_INTERVAL}
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
    -h|--help) print_usage ;;
    *) echo "Unknown arg: $1"; print_usage ;;
  esac
done

# validate numeric args
if ! [[ "$SECONDS" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --seconds must be a positive integer" >&2
  exit 2
fi
if ! [[ "$SAMPLE_INTERVAL" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --sample-interval must be a positive integer" >&2
  exit 2
fi

echo "Namespace: $NAMESPACE"
echo "Pod: $POD"
echo "User: $USER"
echo "Lock duration: $SECONDS seconds"
echo "Sample interval: $SAMPLE_INTERVAL seconds"
echo ""

# helper: run a command inside pod
kubectl_exec() {
  kubectl exec -n "$NAMESPACE" "$POD" -- bash -lc "$1"
}

# Candidate tables to search if user omitted schema/table. Order matters.
CANDIDATES=(
  "accounting.order"
  "accounting.shipping"
  "accounting.orderitem"
  "reviews.productreviews"
)

# If schema/table provided, use it. Otherwise search for candidates
if [ -n "$SCHEMA" ] && [ -n "$TABLE" ]; then
  SELECTED_SCHEMA="$SCHEMA"
  SELECTED_TABLE="$TABLE"
else
  echo "No schema/table provided — attempting automatic discovery of candidate tables..."
  SELECTED_SCHEMA=""
  SELECTED_TABLE=""
  for candidate in "${CANDIDATES[@]}"; do
    cand_schema=${candidate%%.*}
    cand_table=${candidate##*.}
    echo -n "Searching for ${cand_schema}.${cand_table} ... "
    found_db=$(kubectl_exec "for db in \$(psql -U $USER -tAc \"SELECT datname FROM pg_database WHERE datistemplate = false\"); do
      if psql -U $USER -d \"\$db\" -tAc \"SELECT 1 FROM information_schema.tables WHERE table_schema = '$cand_schema' AND table_name = '$cand_table'\" | grep -q 1; then
        echo \$db; break;
      fi;
    done")
    if [ -n "$found_db" ]; then
      echo "FOUND in DB: $found_db"
      SELECTED_SCHEMA="$cand_schema"
      SELECTED_TABLE="$cand_table"
      DBNAME="$found_db"
      break
    else
      echo "not found"
    fi
  done
fi

# If user provided schema/table but not DB, detect DB containing it
if [ -n "$SCHEMA" ] && [ -n "$TABLE" ] && [ -z "${DBNAME-}" ]; then
  echo "Detecting database containing ${SCHEMA}.${TABLE} ..."
  DBNAME=$(kubectl_exec "for db in \$(psql -U $USER -tAc \"SELECT datname FROM pg_database WHERE datistemplate = false\"); do
    if psql -U $USER -d \"\$db\" -tAc \"SELECT 1 FROM information_schema.tables WHERE table_schema = '$SCHEMA' AND table_name = '$TABLE'\" | grep -q 1; then
      echo \$db; break;
    fi;
  done")
fi

if [ -z "${SELECTED_SCHEMA:-}" ] || [ -z "${SELECTED_TABLE:-}" ]; then
  echo "ERROR: Could not find any candidate tables. Manual intervention required." >&2
  echo "Try running the script with --schema and --table, or ensure the schemas were created." >&2
  exit 3
fi

if [ -z "${DBNAME:-}" ]; then
  echo "ERROR: Could not detect database name for ${SELECTED_SCHEMA}.${SELECTED_TABLE}" >&2
  exit 4
fi

echo ""
echo "Auto-selected table: ${SELECTED_SCHEMA}.${SELECTED_TABLE} (database: ${DBNAME})"
echo ""

# Prepare fully qualified table identifier for SQL (we'll quote the table part to handle reserved words)
REMOTE_SQL="/tmp/chaos_lock_$(date +%s).sql"
REMOTE_LOG="/tmp/chaos_lock_$(date +%s).log"
REPORT="/tmp/chaos_report_$(date +%s).txt"
FQ_TABLE="${SELECTED_SCHEMA}.\"${SELECTED_TABLE}\""

# Write SQL file into pod
echo "Writing lock SQL to pod: $REMOTE_SQL"
kubectl_exec "cat > $REMOTE_SQL <<'SQL'
BEGIN;
LOCK TABLE ${FQ_TABLE} IN ACCESS EXCLUSIVE MODE;
SELECT pg_sleep(${SECONDS});
COMMIT;
SQL"

# Start background lock job
echo "Starting background lock job (nohup) — output -> $REMOTE_LOG"
kubectl_exec "nohup bash -lc \"psql -U $USER -d $DBNAME -f $REMOTE_SQL\" >> $REMOTE_LOG 2>&1 &"

# Start sampling/report generation inside pod
echo "Starting sampling loop in pod to generate chaos report: $REPORT"
kubectl_exec "cat > /tmp/chaos_sampler.sh <<'SH'
#!/usr/bin/env bash
USER='$USER'
DB='$DBNAME'
SCHEMA='${SELECTED_SCHEMA}'
TABLE='${SELECTED_TABLE}'
REPORT='$REPORT'
SAMPLE_INTERVAL=${SAMPLE_INTERVAL}
END_TIME=\$(( \$(date +%s) + ${SECONDS} + 10 ))

echo \"Chaos report for \${SCHEMA}.\${TABLE}\" > \$REPORT
echo \"Started: \$(date -u)\" >> \$REPORT
echo \"Pod: ${POD}\" >> \$REPORT
echo \"DB: $DBNAME\" >> \$REPORT
echo \"Lock duration: ${SECONDS}s\" >> \$REPORT
echo >> \$REPORT

while [ \$(date +%s) -le \$END_TIME ]; do
  echo \"--- SAMPLE: \$(date -u) ---\" >> \$REPORT
  echo \"pg_locks (relation::regclass, mode, granted, pid):\" >> \$REPORT
  psql -U \$USER -d \$DB -c \"SELECT relation::regclass AS table_name, mode, granted, pid FROM pg_locks WHERE relation = '\${SCHEMA}.\"\${TABLE}\"'::regclass;\" >> \$REPORT 2>&1 || true
  echo >> \$REPORT
  echo \"pg_stat_activity (lock/pg_sleep related):\" >> \$REPORT
  psql -U \$USER -d \$DB -c \"SELECT pid, usename, datname, state, now()-query_start AS age, query FROM pg_stat_activity WHERE query ILIKE '%LOCK TABLE%' OR query ILIKE '%pg_sleep%' OR query ILIKE '%pg_advisory_lock%' ORDER BY query_start DESC LIMIT 50;\" >> \$REPORT 2>&1 || true
  echo >> \$REPORT
  echo \"Blocked queries (if any):\" >> \$REPORT
  psql -U \$USER -d \$DB -c \"SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query, blocking.pid AS blocking_pid, blocking.query AS blocking_query FROM pg_stat_activity blocked JOIN pg_locks bl ON bl.pid = blocked.pid AND NOT bl.granted JOIN pg_locks br ON bl.locktype = br.locktype AND bl.relation = br.relation AND br.granted = true JOIN pg_stat_activity blocking ON blocking.pid = br.pid;\" >> \$REPORT 2>&1 || true
  echo >> \$REPORT
  echo \"ps aux (top processes):\" >> \$REPORT
  ps aux | head -n 30 >> \$REPORT
  echo >> \$REPORT
  sleep \$SAMPLE_INTERVAL
done
echo \"--- END OF SAMPLING: \$(date -u) ---\" >> \$REPORT
SH"

kubectl_exec "chmod +x /tmp/chaos_sampler.sh && nohup /tmp/chaos_sampler.sh >/dev/null 2>&1 &"

# Print verification/help commands
echo ""
echo "Lock job dispatched. Background log: $REMOTE_LOG"
echo "Chaos report being generated at: $REPORT"
echo ""
echo "Quick verification commands:"
echo "  Show locks for the table:"
echo "    kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT relation::regclass AS table_name, mode, granted, pid FROM pg_locks WHERE relation = '${SELECTED_SCHEMA}.\"${SELECTED_TABLE}\"'::regclass;\""
echo ""
echo "  Show lock-holding sessions / pg_sleep:"
echo "    kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT pid, usename, datname, state, now()-query_start AS age, query FROM pg_stat_activity WHERE query ILIKE '%LOCK TABLE%' OR query ILIKE '%pg_sleep%';\""
echo ""
echo "  Tail background psql log:"
echo "    kubectl exec -n $NAMESPACE $POD -- tail -F $REMOTE_LOG"
echo ""
echo "  View generated chaos report inside pod:"
echo "    kubectl exec -n $NAMESPACE $POD -- cat $REPORT"
echo ""
echo "  Copy chaos report to local machine:"
echo "    kubectl cp $NAMESPACE/$POD:$REPORT ./chaos_report_$(date +%s).txt"
echo ""
echo "If you need to force release the lock (destructive):"
echo "  1) Find pid: (use the pg_stat_activity command above)"
echo "  2) Terminate: kubectl exec -n $NAMESPACE $POD -- psql -U $USER -d $DBNAME -c \"SELECT pg_terminate_backend(<pid>);\""
echo ""
echo "Done."
