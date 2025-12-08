#!/usr/bin/env bash
set -euo pipefail

# Port-forward the frontend service to localhost and run a checkout verification
# This helps exercise the checkout flow in a k8s cluster when you don't have
# ingress configured locally.

NAMESPACE="default"
SERVICE="frontend"
LOCAL_PORT=8080
PF_PID=""

usage(){
  cat <<EOF
Usage: $0 [-n namespace] [-s service] [-p local_port]
  -n namespace   Kubernetes namespace (default: default)
  -s service     Service name to port-forward (default: frontend)
  -p local_port  Local port to bind (default: 8080)
EOF
  exit 2
}

while getopts ":n:s:p:" opt; do
  case $opt in
    n) NAMESPACE="$OPTARG" ;;
    s) SERVICE="$OPTARG" ;;
    p) LOCAL_PORT="$OPTARG" ;;
    *) usage ;;
  esac
done

echo "Port-forwarding service/$SERVICE in ns/$NAMESPACE to localhost:${LOCAL_PORT}"

# Start port-forward in background
kubectl port-forward -n "$NAMESPACE" service/$SERVICE ${LOCAL_PORT}:8080 >/dev/null 2>&1 &
PF_PID=$!
sleep 1

echo "Running checkout verification against http://localhost:${LOCAL_PORT}/api/checkout"
HTTP_STATUS=$(curl -s -o /tmp/chaos_verify_body -w "%{http_code}" -X POST "http://localhost:${LOCAL_PORT}/api/checkout" -H 'Content-Type: application/json' -d '{"user_id":"test","items":[{"id":"1","qty":1}]}' --max-time 10 || true)

echo "HTTP status: $HTTP_STATUS"
echo "Body:"; cat /tmp/chaos_verify_body || true

if [ "$HTTP_STATUS" -ge 500 ]; then
  echo "Observed server error (>=500) — likely manifestation of DB blocking"
fi

echo "Stopping port-forward (pid $PF_PID)"
kill $PF_PID 2>/dev/null || true
