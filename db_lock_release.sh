#!/usr/bin/env bash
set -euo pipefail

# Find and terminate the psql session(s) holding advisory locks or running
# the blocking query so locks are released earlier than the original duration.
#
# Usage:
#   ./db_lock_release.sh [-c container] [-d dbname] [-U user] [-l lockid]

CONTAINER="postgresql"
DB="${POSTGRES_DB:-postgres}"
USER="${POSTGRES_USER:-root}"
LOCKID=""

usage(){
  cat <<EOF
Usage: $0 [-c container] [-d dbname] [-U user] [-l lockid]
  -c container   Postgres container name (default: postgresql)
  -d dbname      Database name (default: from POSTGRES_DB or 'postgres')
  -U user        Postgres user (default: from POSTGRES_USER or 'root')
  -l lockid      Advisory lock id (optional) - if provided will try to kill sessions
EOF
  exit 2
}

while getopts ":c:d:U:l:" opt; do
  case $opt in
    c) CONTAINER="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    U) USER="$OPTARG" ;;
    l) LOCKID="$OPTARG" ;;
    *) usage ;;
  esac
done

if [ -n "$LOCKID" ]; then
  echo "Attempting to terminate sessions holding advisory lock id=$LOCKID"
  SQL="SELECT pg_terminate_backend(pid) FROM pg_locks l JOIN pg_stat_activity a ON l.pid = a.pid WHERE l.locktype = 'advisory' AND l.objid = ${LOCKID};"
else
  echo "Attempting to terminate sessions running pg_advisory_lock() or idle-in-transaction"
  SQL="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE query LIKE '%pg_advisory_lock(%' AND state = 'idle in transaction';"
fi

docker exec -i "$CONTAINER" bash -lc "psql -v ON_ERROR_STOP=1 -U '$USER' -d '$DB' -c \"$SQL\""

echo "Release attempt complete."
