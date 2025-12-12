#!/usr/bin/env bash
#
# remediate-namespace-quota.sh
#
# Purpose:
#   Diagnose and remediate a Namespace ResourceQuota that is blocking HPA-driven scaling.
#   Supports interactive flow and non-interactive flags for automation.
#
# Features:
#   - show status (quota, pending pods, HPA)
#   - increase quota (patch)
#   - delete quota
#   - scale a deployment manually (if quota allows)
#   - create a GitOps-ready ResourceQuota patch YAML (for PR)
#   - annotate the quota change for audit
#
# Usage examples:
#   Interactive:
#     ./remediate-namespace-quota.sh -n otel-demo
#
#   Non-interactive (increase pods to 50 and annotate change):
#     ./remediate-namespace-quota.sh -n otel-demo --increase 50 --annot "emergency-recovery-2025-12-12" --yes
#
#   Delete quota non-interactively:
#     ./remediate-namespace-quota.sh -n otel-demo --delete --yes
#
set -euo pipefail

# Defaults
NAMESPACE="otel-demo"
QUOTA_NAME="otel-demo-pod-quota"
LOGFILE="remediate-$(date +%s).log"
AUTO_YES=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*" | tee -a "$LOGFILE"; }
info() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOGFILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOGFILE"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOGFILE" >&2; }

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -n, --namespace NAMESPACE    Kubernetes namespace (default: ${NAMESPACE})
  --quota-name NAME            ResourceQuota name (default: ${QUOTA_NAME})
  --show                       Show current status (quota, pending pods, HPA)
  --increase N                 Increase pod quota to N (patch)
  --delete                     Delete the ResourceQuota
  --scale DEPLOYMENT:REPLICAS  Scale a deployment (e.g. frontend:10)
  --gitops-patch N             Create GitOps-ready patch YAML to set pods to N
  --annot TEXT                 Annotate ResourceQuota with TEXT after change
  --yes                        Non-interactive; assume "yes" to confirmations
  -h, --help                   Show this help

Examples:
  $0 -n otel-demo --show
  $0 -n otel-demo --increase 50 --annot "emergency-fix-2025-12-12" --yes
  $0 -n otel-demo --delete --yes
  $0 -n otel-demo --scale frontend:10 --yes

EOF
  exit 2
}

# Basic check
check_prereqs() {
  log "Checking prerequisites..."
  if ! command -v kubectl &>/dev/null; then
    err "kubectl is required but not found in PATH."
    exit 1
  fi

  if ! kubectl version --client &>/dev/null; then
    err "kubectl client not available."
    exit 1
  fi

  if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    err "Namespace '$NAMESPACE' does not exist or not accessible."
    exit 1
  fi

  info "Prerequisites OK"
}

confirm() {
  if $AUTO_YES; then
    return 0
  fi
  read -rp "$1 [y/N]: " ans
  case "$ans" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

show_status() {
  log "==== Current cluster / namespace status ===="
  echo
  log "ResourceQuota (describe):"
  if kubectl get resourcequota "$QUOTA_NAME" -n "$NAMESPACE" &>/dev/null; then
    kubectl describe resourcequota "$QUOTA_NAME" -n "$NAMESPACE" | tee -a "$LOGFILE"
  else
    warn "ResourceQuota '$QUOTA_NAME' not found in $NAMESPACE"
  fi
  echo
  log "LimitRanges in namespace:"
  kubectl get limitrange -n "$NAMESPACE" -o wide | tee -a "$LOGFILE" || true
  echo
  log "Pending pods (if any):"
  kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending -o wide | tee -a "$LOGFILE" || true
  echo
  log "HPA status:"
  kubectl get hpa -n "$NAMESPACE" -o wide | tee -a "$LOGFILE" || true
  echo
  log "Recent events (last 50 lines):"
  kubectl get events -n "$NAMESPACE" --sort-by='.lastTimestamp' | tail -50 | tee -a "$LOGFILE" || true
  echo
  info "Status snapshot saved to $LOGFILE"
}

increase_quota() {
  local new_value="$1"
  log "Will attempt to increase pod quota to: $new_value"

  if ! kubectl get resourcequota "$QUOTA_NAME" -n "$NAMESPACE" &>/dev/null; then
    err "ResourceQuota '$QUOTA_NAME' not found in $NAMESPACE. Aborting increase."
    return 1
  fi

  if ! confirm "Proceed to patch ResourceQuota $QUOTA_NAME in namespace $NAMESPACE to pods=$new_value?"; then
    info "Cancelled by user."
    return 0
  fi

  kubectl patch resourcequota "$QUOTA_NAME" -n "$NAMESPACE" \
    --type='json' \
    -p="[ { \"op\": \"replace\", \"path\": \"/spec/hard/pods\", \"value\": \"${new_value}\" } ]"

  info "Patched ResourceQuota to pods=${new_value}."

  # annotate for audit
  if [ -n "${ANNOTATION:-}" ]; then
    kubectl annotate resourcequota "$QUOTA_NAME" -n "$NAMESPACE" "remediation.note=${ANNOTATION}" --overwrite
    info "Annotated ResourceQuota with remediation.note=${ANNOTATION}"
  fi

  sleep 5
  info "Verifying quota after patch..."
  kubectl describe resourcequota "$QUOTA_NAME" -n "$NAMESPACE" | tee -a "$LOGFILE"
  return 0
}

delete_quota() {
  log "Will delete ResourceQuota $QUOTA_NAME in namespace $NAMESPACE."

  if ! kubectl get resourcequota "$QUOTA_NAME" -n "$NAMESPACE" &>/dev/null; then
    warn "ResourceQuota '$QUOTA_NAME' not present; nothing to delete."
    return 0
  fi

  if ! confirm "Confirm deletion of ResourceQuota $QUOTA_NAME in $NAMESPACE?"; then
    info "Cancelled by user."
    return 0
  fi

  kubectl delete resourcequota "$QUOTA_NAME" -n "$NAMESPACE"
  info "ResourceQuota deleted."
  return 0
}

scale_deployment() {
  local target="$1"
  # expected format deployment:replicas
  IFS=':' read -r deploy replicas <<< "$target"
  if [ -z "$deploy" ] || [ -z "$replicas" ]; then
    err "Invalid --scale argument. Expected DEPLOYMENT:REPLICAS"
    return 1
  fi

  log "Will scale deployment '$deploy' in '$NAMESPACE' to $replicas replicas."

  if ! kubectl get deployment "$deploy" -n "$NAMESPACE" &>/dev/null; then
    err "Deployment $deploy not found in namespace $NAMESPACE."
    return 1
  fi

  if ! confirm "Proceed to scale $deploy to $replicas replicas?"; then
    info "Cancelled by user."
    return 0
  fi

  kubectl scale deployment/"$deploy" -n "$NAMESPACE" --replicas="$replicas"
  info "Scale request submitted. Watching pods for 30s..."
  kubectl get pods -n "$NAMESPACE" --selector=app="$deploy" -o wide || true
  sleep 2
  kubectl get pods -n "$NAMESPACE" --field-selector=status.phase=Pending -o wide || true
  return 0
}

create_gitops_patch() {
  local new_value="$1"
  local outdir="gitops-patch-$(date +%s)"
  mkdir -p "$outdir"
  local outfile="${outdir}/${QUOTA_NAME}-patch.yaml"

  cat > "$outfile" <<EOF
# GitOps patch to update ResourceQuota '${QUOTA_NAME}' pods to '${new_value}'
# Apply by creating a PR to your GitOps repo. This file replaces the pods hard limit.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${QUOTA_NAME}
  namespace: ${NAMESPACE}
spec:
  hard:
    pods: "${new_value}"
EOF

  info "Created GitOps-ready patch: $outfile"
}

annotate_quota() {
  local note="$1"
  if ! kubectl get resourcequota "$QUOTA_NAME" -n "$NAMESPACE" &>/dev/null; then
    err "ResourceQuota $QUOTA_NAME not found; cannot annotate."
    return 1
  fi
  kubectl annotate resourcequota "$QUOTA_NAME" -n "$NAMESPACE" "remediation.note=${note}" --overwrite
  info "Annotated ResourceQuota with remediation.note=${note}"
}

# Parse args
INCREASE_VALUE=""
DELETE_FLAG=false
SCALE_ARG=""
GITOPS_PATCH_VAL=""
ANNOTATION=""
SHOW_ONLY=false

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2;;
    --quota-name) QUOTA_NAME="$2"; shift 2;;
    --show) SHOW_ONLY=true; shift;;
    --increase) INCREASE_VALUE="$2"; shift 2;;
    --delete) DELETE_FLAG=true; shift;;
    --scale) SCALE_ARG="$2"; shift 2;;
    --gitops-patch) GITOPS_PATCH_VAL="$2"; shift 2;;
    --annot) ANNOTATION="$2"; shift 2;;
    --yes) AUTO_YES=true; shift;;
    -h|--help) usage;;
    --) shift; break;;
    -*)
      err "Unknown option: $1"
      usage
      ;;
    *)
      POSITIONAL+=("$1"); shift;;
  esac
done
set -- "${POSITIONAL[@]}"

# Run
check_prereqs

# If user passed only show or nothing, show status
if $SHOW_ONLY || ( [ -z "$INCREASE_VALUE" ] && [ "$DELETE_FLAG" = false ] && [ -z "$SCALE_ARG" ] && [ -z "$GITOPS_PATCH_VAL" ] ); then
  show_status
fi

if [ -n "$INCREASE_VALUE" ]; then
  ANNOTATION="${ANNOTATION:-}"
  increase_quota "$INCREASE_VALUE"
  if [ -n "$ANNOTATION" ]; then
    annotate_quota "$ANNOTATION"
  fi
fi

if [ "$DELETE_FLAG" = true ]; then
  delete_quota
fi

if [ -n "$SCALE_ARG" ]; then
  scale_deployment "$SCALE_ARG"
fi

if [ -n "$GITOPS_PATCH_VAL" ]; then
  create_gitops_patch "$GITOPS_PATCH_VAL"
fi

info "Remediation script finished. Review $LOGFILE for details."
