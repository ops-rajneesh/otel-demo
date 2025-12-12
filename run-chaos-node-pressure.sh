#!/bin/bash

# Chaos Engineering Testing Script
# Use Case: Application not able to scale despite HPA criteria met
# Description: Node-level resource pressure prevents pods from scheduling (insufficient node resources)

set -e

NAMESPACE="otel-demo"
LOG_FILE="chaos-node-pressure-$(date +%s).log"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
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

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    if ! command -v kubectl &> /dev/null; then
        error "kubectl not found. Please install kubectl."
        exit 1
    fi
    success "kubectl found"

    if ! kubectl cluster-info &> /dev/null; then
        error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    success "Connected to Kubernetes cluster"

    if ! kubectl get namespace $NAMESPACE &> /dev/null; then
        error "Namespace $NAMESPACE does not exist"
        exit 1
    fi
    success "Namespace $NAMESPACE exists"
}

# Phase 1: Deploy Chaos Resources (DaemonSet that hogs CPU/memory across nodes)
deploy_chaos() {
    log "Phase 1: Deploying chaos resources (DaemonSet node-resource-hog)..."
    kubectl apply -f chaos-usecase-node-resource-pressure.yaml
    sleep 5
    success "Chaos resources applied"
}

# Phase 2: Verify DaemonSet and Pod status
verify_chaos_setup() {
    log "Phase 2: Verifying chaos setup..."

    if kubectl get daemonset node-resource-hog -n $NAMESPACE &> /dev/null; then
        success "DaemonSet 'node-resource-hog' present"
        kubectl get daemonset node-resource-hog -n $NAMESPACE -o wide | tee -a "$LOG_FILE"
    else
        error "DaemonSet node-resource-hog not found"
        return 1
    fi

    # Ensure pods are running (some may go pending if nodes don't allow the heavy request)
    log "Checking node-resource-hog pods status..."
    kubectl get pods -n $NAMESPACE -l app=node-resource-hog -o wide | tee -a "$LOG_FILE"
}

# Phase 3: Generate load to trigger HPAs (use either load-generator or ad-hoc load)
generate_load() {
    log "Phase 3: Starting load generation to trigger HPAs..."
    load_gen_pod=$(kubectl get pod -n $NAMESPACE -l app=loadgenerator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$load_gen_pod" ]; then
        warning "Load generator pod not found. Will create ephemeral load job..."
        kubectl run -n $NAMESPACE chaos-load --image=curlimages/curl:7.90.0 --restart=Never -- sh -c "for i in \\$(seq 1 1000); do curl -s http://frontend:3000 >/dev/null; done"
    else
        success "Found load generator: $load_gen_pod"
        kubectl exec -n $NAMESPACE -it $load_gen_pod -- sh -c 'for i in {1..600}; do curl -s http://frontend:3000 >/dev/null & done; wait' &
    fi

    log "Load generation triggered"
}

# Phase 4: Monitor HPAs & cluster
monitor_hpa_and_cluster() {
    log "Phase 4: Monitoring HPA and Cluster state..."

    for hpa_name in frontend-hpa cart-hpa checkout-hpa; do
        if kubectl get hpa $hpa_name -n $NAMESPACE &> /dev/null; then
            log "HPA: $hpa_name"
            kubectl describe hpa $hpa_name -n $NAMESPACE | grep -E "Desired|Current|CPU|Memory" | tee -a "$LOG_FILE"
        fi
    done

    log "Checking nodes allocatable and capacity"
    kubectl get nodes -o wide | tee -a "$LOG_FILE"
    kubectl describe nodes | grep -A 5 "Allocatable" | tee -a "$LOG_FILE" || true

    log "Checking pending pods in namespace"
    kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o wide | tee -a "$LOG_FILE" || true

    log "Checking events for scheduling failures"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep -E "Failed|Insufficient|FailedScheduling|Unschedulable|evicted|OutOf" | tail -30 | tee -a "$LOG_FILE" || true

    # Show a sample of failing pod description if exists
    pending_pod_name=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$pending_pod_name" ]; then
        log "Describing a pending pod: $pending_pod_name"
        kubectl describe pod -n $NAMESPACE $pending_pod_name | tee -a "$LOG_FILE"
    fi

    # Optionally show top nodes/pods (requires metrics-server)
    if command -v kubectl &> /dev/null && kubectl top nodes &> /dev/null; then
        log "Node metrics (kubectl top nodes)"
        kubectl top nodes | tee -a "$LOG_FILE"
    fi
}

# Phase 5: Verify HPA desires vs actuals & reason: Pending due to Insufficient
verify_hpa_scaling_blocked() {
    log "Phase 5: Verifying that HPA is blocked by lack of node resources..."

    local blocked=false

    for hpa_name in frontend-hpa cart-hpa checkout-hpa; do
        if kubectl get hpa $hpa_name -n $NAMESPACE &> /dev/null; then
            desired=$(kubectl get hpa $hpa_name -n $NAMESPACE -o jsonpath='{.status.desiredReplicas}')
            current=$(kubectl get hpa $hpa_name -n $NAMESPACE -o jsonpath='{.status.currentReplicas}')
            if [ "$desired" -gt "$current" ]; then
                log "HPA $hpa_name desired=$desired > current=$current"
                # Are there pending pods matching this deployment?
                pending=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
                for p in $pending; do
                    # Check event reasons
                    reason=$(kubectl describe pod -n $NAMESPACE $p | grep -E "Reason:|FailedScheduling|Insufficient" -m 5 || true)
                    if echo "$reason" | grep -q "Insufficient"; then
                        log "Found pending pod $p due to insufficient resources"
                        blocked=true
                    fi
                done
            fi
        fi
    done

    if $blocked; then
        success "Verified: HPA desired > current and pods pending due to Insufficient resources"
    else
        warning "Did not detect pending pods due to insufficient resources; double-check load and resource requests or tune the DaemonSet" 
    fi
}

# Remediation: Remove resource hog DaemonSet
remediate() {
    log "Remediating chaos scenario: deleting DaemonSet to free node resources"
    kubectl delete daemonset node-resource-hog -n $NAMESPACE --ignore-not-found
    success "DaemonSet removed; resources should be freed shortly"
    sleep 10
}

# Cleanup
cleanup_chaos() {
    log "Cleaning up chaos resources (daemonset & job)..."
    read -p "Remove all chaos resources? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        kubectl delete -f chaos-usecase-node-resource-pressure.yaml
        success "Chaos resources removed"
    else
        log "Cleanup cancelled"
    fi
}

# Generate report (similar to namespace quota script)
generate_report() {
    log "Generating chaos report..."
    report_file="chaos-node-pressure-report-$(date +%s).txt"

    {
        echo "============================================"
        echo "Chaos Node-Pressure Test Report"
        echo "Scenario: Application cannot scale due to insufficient node resources"
        echo "Date: $(date)"
        echo "============================================"
        echo ""
        echo "1. NAMESPACE PODs"
        kubectl get pods -n $NAMESPACE -o wide
        echo ""
        echo "2. Pending Pods"
        kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o wide || true
        echo ""
        echo "3. HPA STATUS"
        kubectl get hpa -n $NAMESPACE -o wide || true
        echo ""
        echo "4. NODE STATUS"
        kubectl get nodes -o wide || true
        echo ""
        echo "5. Events (last 50)"
        kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | tail -50 || true
        echo ""
        echo "6. DaemonSet status"
        kubectl get ds -n $NAMESPACE | tee -a "$LOG_FILE" || true

    } | tee "$report_file"

    success "Report saved to: $report_file"
}

# Main
main() {
    log "============================================"
    log "Chaos Engineering: Node Resource Pressure Scenario"
    log "============================================"

    check_prerequisites

    echo ""
    echo "Options:"
    echo "1. Deploy chaos scenario and monitor"
    echo "2. Monitor existing scenario"
    echo "3. Remediate (delete resource hog)"
    echo "4. Cleanup chaos resources"
    read -p "Enter option (1-4): " choice

    case $choice in
        1)
            deploy_chaos
            verify_chaos_setup
            generate_load
            sleep 30
            ;;
        2)
            log "Monitoring existing chaos scenario..."
            ;;
        3)
            remediate
            sleep 20
            ;;
        4)
            cleanup_chaos
            exit 0
            ;;
        *)
            error "Invalid option"
            exit 1
            ;;
    esac

    monitor_hpa_and_cluster
    verify_hpa_scaling_blocked
    generate_report

    log "Test completed. Check log file: $LOG_FILE"
    success "Chaos node-pressure tests completed!"
}

main
