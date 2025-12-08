#!/usr/bin/env bash
set -euo pipefail

# Basic verification helper to exercise the checkout flow and show failures
# when Postgres locking is in effect. This script POSTs to the checkout endpoint
# and prints HTTP status and body. It is intentionally small — adapt for more
# advanced checks in your environment.
#
# Usage:
#   ./verify_checkout.sh [-u url]

URL="http://localhost:8080/api/checkout"  # default; adjust as needed

while getopts ":u:" opt; do
  case $opt in
    u) URL="$OPTARG" ;;
    *) echo "Usage: $0 [-u url]"; exit 2 ;;
  esac
done

echo "POSTing a simple checkout payload to $URL"
HTTP_STATUS=$(curl -s -o /tmp/chaos_verify_body -w "%{http_code}" -X POST "$URL" -H 'Content-Type: application/json' -d '{"user_id":"test","items":[{"id":"1","qty":1}]}' --max-time 10 || true)

echo "HTTP status: $HTTP_STATUS"
echo "Body:"; cat /tmp/chaos_verify_body || true

if [ "$HTTP_STATUS" -ge 500 ]; then
  echo "Observed server error (>=500) — likely manifestation of DB blocking"
fi
