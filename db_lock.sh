#!/usr/bin/env bash
set -euo pipefail

# Acquire a PostgreSQL advisory lock inside the Postgres container and hold it
# for a specified duration to simulate DB locking that causes downstream
# failures (e.g. order fulfillment blocking).
#
# Usage:
#   ./db_lock_acquire.sh [-c container] [-d dbname] [-U user] [-l lockid] -t seconds
# Defaults assume docker-compose service `postgresql` with env vars set in compose.

CONTAINER="postgresql"
DB="${POSTGRES_DB:-postgres}"
USER="${POSTGRES_USER:-root}"
LOCKID=424242
DURATION=30

usage(){
  cat <<EOF
Usage: $0 [-c container] [-d dbname] [-U user] [-l lockid] -t seconds
  -c container   Postgres container name (default: postgresql)
  -d dbname      Database name (default: from POSTGRES_DB or 'postgres')
  -U user        Postgres user (default: from POSTGRES_USER or 'root')
  -l lockid      Advisory lock id (integer, default: ${LOCKID})
  -t seconds     Duration to hold the lock (required)
EOF
  exit 2
}

while getopts ":c:d:U:l:t:" opt; do
  case $opt in
    c) CONTAINER="$OPTARG" ;;
    d) DB="$OPTARG" ;;
    U) USER="$OPTARG" ;;
    l) LOCKID="$OPTARG" ;;
    t) DURATION="$OPTARG" ;;
    *) usage ;;
  esac
done

if [ -z "$DURATION" ]; then
  echo "Error: duration (-t) is required"
  usage
fi

echo "Acquiring advisory lock id=$LOCKID on database=$DB (container=$CONTAINER) for ${DURATION}s"

# Run a background psql session inside the container that acquires the advisory lock
# and sleeps for the requested duration inside the transaction so the lock is held.

docker exec -d "$CONTAINER" bash -lc "psql -v ON_ERROR_STOP=1 -U '$USER' -d '$DB' <<'SQL'
BEGIN;
SELECT pg_advisory_lock(${LOCKID});
SELECT pg_sleep(${DURATION});
COMMIT;
SQL"

echo "Lock acquired (background session started)."
