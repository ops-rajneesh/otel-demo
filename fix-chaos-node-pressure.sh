#!/bin/bash

# Remediation script for Node Resource Pressure Chaos
# Fixes: Node-level resource pressure scenario by cleaning up resources, scaling down test deployments,
# and verifying that HPAs are able to recover.

set -euo pipefail

NAMESPACE="otel-demo"
LOG_FILE="fix-chaos-node-pressure-$(date +%s).log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
  cat <<EOF
Usage: $0 [--namespace <ns>] [--keep-daemonset] [--scale-down] [--delete-deployment] [--wait <seconds>]

Options:
  --namespace <ns>        Namespace containing the chaos resources (default: otel-demo)
  --keep-daemonset        Do not delete the node-resource-hog DaemonSet (default: delete it)
  --scale-down            Scale down the 'scale-pressure' deployment to 0 instead of deleting (default: delete)
  --delete-deployment     Delete the 'scale-pressure' deployment (the default)
  --wait <seconds>        Wait up to <seconds> for pending pods to resolve (default: 300)
  -h|--help               Show this help and exit
EOF
}

# Logging helper functions
log() {
  echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE"
}

success() {
  echo -e "${GREEN}[✓]${NC} $1" | tee -a "$LOG_FILE"
}

error() {
  echo -e "${RED}[✗]${NC} $1" | tee -a "$LOG_FILE"
}

warning() {
  echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG_FILE"
}

# Default options
KEEP_DAEMONSET=false
SCALE_DOWN=false
DELETE_DEPLOYMENT=true
WAIT_SECONDS=300

# Parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --namespace)
      NAMESPACE=$2; shift 2;;
    --keep-daemonset)
      KEEP_DAEMONSET=true; shift 1;;
    --scale-down)
      SCALE_DOWN=true; DELETE_DEPLOYMENT=false; shift 1;;
    --delete-deployment)
      DELETE_DEPLOYMENT=true; SCALE_DOWN=false; shift 1;;
    --wait)
      WAIT_SECONDS=$2; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1"; usage; exit 1;;
  esac
done

check_prereqs() {
  log "Checking prerequisites..."
  if ! command -v kubectl &> /dev/null; then
    error "kubectl not found; please install kubectl"
    exit 1
  fi

  if ! kubectl cluster-info &> /dev/null; then
    error "Cannot connect to Kubernetes cluster"
    exit 1
  fi

  if ! kubectl get namespace "$NAMESPACE" &> /dev/null; then
    error "Namespace $NAMESPACE not found"
    exit 1
  fi

  success "All prerequisites are satisfied"
}

# Delete DaemonSet and wait for pods to terminate
delete_daemonset() {
  if [ "$KEEP_DAEMONSET" = true ]; then
    log "Skipping DaemonSet deletion (keep-daemonset=true)"
    return
  fi

  log "Deleting DaemonSet 'node-resource-hog' in namespace $NAMESPACE..."
  kubectl delete daemonset node-resource-hog -n "$NAMESPACE" --ignore-not-found --wait
  success "DaemonSet deletion requested"

  # Wait for pods to be removed
  log "Waiting up to 60s for daemonset pods to terminate..."
  timeout=60
  start=$(date +%s)
  while true; do
    count=$(kubectl get pods -n "$NAMESPACE" -l app=node-resource-hog --no-headers 2>/dev/null | wc -l || true)
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
      success "All node-resource-hog pods terminated"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge $timeout ]; then
      warning "DaemonSet pods still present after $timeout seconds (they may be terminating)."
      break
    fi
    sleep 2
  done
}

# Scale or delete the scale-pressure deployment
cleanup_scale_pressure() {
  if $DELETE_DEPLOYMENT; then
    log "Deleting deployment 'scale-pressure'..."
    kubectl delete deployment scale-pressure -n "$NAMESPACE" --ignore-not-found --wait
    success "scale-pressure deployment deletion requested"
  elif $SCALE_DOWN; then
    log "Scaling 'scale-pressure' deployment down to 0 replicas..."
    kubectl scale deployment/scale-pressure -n "$NAMESPACE" --replicas=0 || true
    success "scale-pressure scaled to 0"
  else
    log "scale-pressure: no action requested (neither delete nor scale-down)"
  fi

  # Wait for pods to terminate
  log "Waiting for scale-pressure pods to terminate (up to 60s) ..."
  timeout=60
  start=$(date +%s)
  while true; do
    count=$(kubectl get pods -n "$NAMESPACE" -l app=scale-pressure --no-headers 2>/dev/null | wc -l || true)
    if [ -z "$count" ] || [ "$count" -eq 0 ]; then
      success "scale-pressure pods terminated"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge $timeout ]; then
      warning "scale-pressure pods still present after $timeout seconds"
      break
    fi
    sleep 2
  done
}

# Remove any ephemeral chaos load pods created by the earlier script
remove_ephemeral_load_pods() {
  log "Removing ephemeral chaos load pods (ep-*) and chaos-load pods, if any..."
  kubectl delete pod -n "$NAMESPACE" -l app=chaos-load --ignore-not-found
  kubectl delete pod -n "$NAMESPACE" -l app=ep --ignore-not-found || true
  # The earlier script uses names like ep-<n> and also may create jobs named chaos-load
  kubectl delete pod -n "$NAMESPACE" -l app=scale-pressure --ignore-not-found || true
  kubectl delete jobs -n "$NAMESPACE" --ignore-not-found --all
  success "Ephemeral load pods removed (if present)"
}

# Wait for cluster pending pods to clear
wait_pending_cleared() {
  log "Waiting for pending pods (if any) in namespace $NAMESPACE to clear (up to $WAIT_SECONDS seconds)..."
  start=$(date +%s)

  while true; do
    pending=$(kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "$pending" ]; then
      success "No pending pods in $NAMESPACE"
      break
    fi
    now=$(date +%s)
    if [ $((now - start)) -ge $WAIT_SECONDS ]; then
      warning "Pending pods still exist after waiting $WAIT_SECONDS seconds: $pending"
      break
    fi
    log "Pending pods present: $pending. Waiting..."
    sleep 10
  done
}

# Verify HPA desired vs current
verify_hpa() {
  log "Checking HPA desired vs current replicas in $NAMESPACE..."
  for hpa in frontend-hpa cart-hpa checkout-hpa; do
    if kubectl get hpa -n "$NAMESPACE" "$hpa" &> /dev/null; then
      desired=$(kubectl get hpa -n "$NAMESPACE" "$hpa" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)
      current=$(kubectl get hpa -n "$NAMESPACE" "$hpa" -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)
      log "HPA $hpa: desired=$desired current=$current"
    fi
  done
}

# Check node status and cluster CPU/memory usage
check_nodes_and_metrics() {
  log "Checking nodes and optionally metrics (kubectl top)"
  kubectl get nodes -o wide | tee -a "$LOG_FILE"
  if kubectl top nodes &> /dev/null 2>&1; then
    kubectl top nodes | tee -a "$LOG_FILE"
  else
    warning "kubectl top nodes not available (metrics-server not present)"
  fi
}

# Main execution flow
main() {
  check_prereqs

  log "Starting remediation steps..."

  # Step 1: Remove resource hogs
  delete_daemonset

  # Step 2: Remove or scale down the scale-pressure deployment
  cleanup_scale_pressure

  # Step 3: Remove ephemeral load pods
  remove_ephemeral_load_pods

  # Step 4: Wait for pending pods to clear
  wait_pending_cleared

  # Step 5: Verify HPA and cluster health
  verify_hpa
  check_nodes_and_metrics

  # Step 6: Final report
  log "Final: Pods in namespace $NAMESPACE:"
  kubectl get pods -n "$NAMESPACE" -o wide | tee -a "$LOG_FILE"
  log "HPAs in namespace $NAMESPACE"
  kubectl get hpa -n "$NAMESPACE" -o wide | tee -a "$LOG_FILE" || true

  success "Remediation complete. Review $LOG_FILE for details"
}

main "$@"
