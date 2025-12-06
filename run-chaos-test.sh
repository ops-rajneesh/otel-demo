#!/bin/bash

# Chaos Engineering Testing Script
# Use Case: Application not able to scale despite HPA criteria met
# Description: Namespace quota limiting the number of pods

set -e

NAMESPACE="otel-demo"
LOG_FILE="chaos-test-$(date +%s).log"

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

# Phase 1: Deploy Chaos Resources
deploy_chaos() {
    log "Phase 1: Deploying chaos resources (ResourceQuota, LimitRange, HPA)..."
    
    kubectl apply -f chaos-usecase-namespace-quota.yaml
    
    sleep 5
    success "Chaos resources deployed"
}

# Phase 2: Verify Chaos Setup
verify_chaos_setup() {
    log "Phase 2: Verifying chaos setup..."
    
    # Check ResourceQuota
    if kubectl get resourcequota otel-demo-pod-quota -n $NAMESPACE &> /dev/null; then
        success "ResourceQuota 'otel-demo-pod-quota' exists"
        
        quota_info=$(kubectl describe resourcequota otel-demo-pod-quota -n $NAMESPACE)
        echo "$quota_info" | tee -a "$LOG_FILE"
    else
        error "ResourceQuota not found"
        return 1
    fi
    
    # Check LimitRange
    if kubectl get limitrange otel-demo-limit-range -n $NAMESPACE &> /dev/null; then
        success "LimitRange 'otel-demo-limit-range' exists"
    else
        error "LimitRange not found"
        return 1
    fi
    
    # Check HPAs
    hpa_count=$(kubectl get hpa -n $NAMESPACE --no-headers 2>/dev/null | wc -l)
    log "Found $hpa_count HPAs in namespace"
}

# Phase 3: Generate Load
generate_load() {
    log "Phase 3: Starting load generation (this will take ~2 minutes)..."
    
    # Find load-generator pod
    load_gen_pod=$(kubectl get pod -n $NAMESPACE -l app=loadgenerator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -z "$load_gen_pod" ]; then
        warning "Load generator pod not found. Skipping load generation."
        warning "You can manually generate load with: kubectl exec -it deployment/load-generator -n $NAMESPACE -- sh"
        return
    fi
    
    success "Found load generator: $load_gen_pod"
    
    log "Generating load for 2 minutes..."
    # Load generation will be done in parallel
    kubectl exec -i "$load_gen_pod" -n $NAMESPACE -- sh -c 'for i in {1..120}; do curl -s http://frontend:3000 > /dev/null 2>&1 & done; wait' &
    
    sleep 5
    success "Load generation started in background"
}

# Phase 4: Monitor HPA Status
monitor_hpa() {
    log "Phase 4: Monitoring HPA status..."
    
    for hpa_name in frontend-hpa cart-hpa checkout-hpa; do
        if kubectl get hpa $hpa_name -n $NAMESPACE &> /dev/null; then
            log "HPA: $hpa_name"
            kubectl describe hpa $hpa_name -n $NAMESPACE | grep -E "Desired|Current|CPU|Memory" | tee -a "$LOG_FILE"
        fi
    done
}

# Phase 5: Check for Pending Pods
check_pending_pods() {
    log "Phase 5: Checking for pending pods..."
    
    pending_pods=$(kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o wide)
    
    if [ -z "$pending_pods" ]; then
        warning "No pending pods found (quota might not be restrictive enough)"
    else
        warning "Found pending pods (expected - this indicates the chaos scenario is working):"
        echo "$pending_pods" | tee -a "$LOG_FILE"
    fi
}

# Phase 6: Analyze Events
analyze_events() {
    log "Phase 6: Analyzing Kubernetes events..."
    
    log "Recent events related to scheduling:"
    kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | grep -E "Failed|Quota|Pod" | tail -20 | tee -a "$LOG_FILE"
}

# Phase 7: Check Quota Usage
check_quota_usage() {
    log "Phase 7: Checking quota usage..."
    
    quota_desc=$(kubectl describe resourcequota otel-demo-pod-quota -n $NAMESPACE)
    
    log "Quota Status:"
    echo "$quota_desc" | grep -A 20 "Resource Quotas" | tee -a "$LOG_FILE"
    
    # Extract used/hard values
    pods_used=$(echo "$quota_desc" | grep "pods" | grep -oE "[0-9]+/[0-9]+" | cut -d'/' -f1)
    pods_hard=$(echo "$quota_desc" | grep "pods" | grep -oE "[0-9]+/[0-9]+" | cut -d'/' -f2)
    
    if [ "$pods_used" = "$pods_hard" ]; then
        warning "Pod quota is FULL ($pods_used/$pods_hard) - HPA will fail to scale"
    else
        log "Pod quota usage: $pods_used/$pods_hard"
    fi
}

# Phase 8: Prometheus Metrics
check_prometheus_metrics() {
    log "Phase 8: Checking Prometheus metrics..."
    
    log "Querying Prometheus for HPA and quota metrics..."
    
    # Try to port-forward to Prometheus if not already done
    if ! kubectl get service prometheus -n $NAMESPACE &> /dev/null; then
        warning "Prometheus service not found"
        return
    fi
    
    log "Prometheus queries to run manually (after port-forward):"
    echo "  kubectl port-forward svc/prometheus 9090:9090 -n $NAMESPACE" | tee -a "$LOG_FILE"
    echo "" | tee -a "$LOG_FILE"
    echo "  Then visit: http://localhost:9090 and run:" | tee -a "$LOG_FILE"
    echo "    - kube_hpa_status_desired_replicas{namespace=\"$NAMESPACE\"}" | tee -a "$LOG_FILE"
    echo "    - kube_hpa_status_current_replicas{namespace=\"$NAMESPACE\"}" | tee -a "$LOG_FILE"
    echo "    - kube_resourcequota_pods_used{namespace=\"$NAMESPACE\"}" | tee -a "$LOG_FILE"
}

# Phase 9: Test Logs
collect_service_logs() {
    log "Phase 9: Collecting service logs (frontend)..."
    
    log "Frontend pod logs:"
    kubectl logs -n $NAMESPACE deployment/frontend --tail=50 2>/dev/null | head -30 | tee -a "$LOG_FILE" || warning "Could not fetch frontend logs"
}

# Phase 10: Generate Report
generate_report() {
    log "Phase 10: Generating report..."
    
    report_file="chaos-test-report-$(date +%s).txt"
    
    {
        echo "============================================"
        echo "Chaos Engineering Test Report"
        echo "Scenario: Application Cannot Scale Due to Namespace Quota"
        echo "Date: $(date)"
        echo "============================================"
        echo ""
        
        echo "1. CLUSTER STATUS"
        echo "================="
        kubectl cluster-info 2>/dev/null || echo "Cluster info unavailable"
        echo ""
        
        echo "2. NAMESPACE PODS"
        echo "================="
        kubectl get pods -n $NAMESPACE -o wide
        echo ""
        
        echo "3. RESOURCE QUOTA"
        echo "================="
        kubectl describe resourcequota -n $NAMESPACE 2>/dev/null || echo "No quotas found"
        echo ""
        
        echo "4. HPA STATUS"
        echo "=============="
        kubectl get hpa -n $NAMESPACE -o wide
        echo ""
        
        echo "5. PENDING PODS"
        echo "==============="
        kubectl get pods -n $NAMESPACE --field-selector=status.phase=Pending -o wide || echo "No pending pods"
        echo ""
        
        echo "6. RECENT EVENTS"
        echo "================"
        kubectl get events -n $NAMESPACE --sort-by='.lastTimestamp' | head -30
        echo ""
        
    } | tee "$report_file"
    
    success "Report saved to: $report_file"
}

# Remediation: Fix the Chaos
remediate() {
    log "Remediating chaos scenario..."
    
    warning "Choose remediation option:"
    echo "1. Increase pod quota to 50"
    echo "2. Remove ResourceQuota entirely"
    echo "3. Cancel remediation"
    read -p "Enter option (1-3): " option
    
    case $option in
        1)
            log "Increasing pod quota to 50..."
            kubectl patch resourcequota otel-demo-pod-quota -n $NAMESPACE \
              --type='json' \
              -p='[{"op": "replace", "path": "/spec/hard/pods", "value": "50"}]'
            success "Pod quota increased"
            ;;
        2)
            log "Removing ResourceQuota..."
            kubectl delete resourcequota otel-demo-pod-quota -n $NAMESPACE
            success "ResourceQuota removed"
            ;;
        3)
            log "Remediation cancelled"
            return
            ;;
        *)
            error "Invalid option"
            return 1
            ;;
    esac
    
    # Wait for reconciliation
    sleep 10
    
    log "Checking if scaling works now..."
    kubectl get hpa -n $NAMESPACE -o wide
}

# Cleanup
cleanup_chaos() {
    log "Cleaning up chaos resources..."
    
    read -p "Remove all chaos resources? (y/n): " confirm
    if [ "$confirm" = "y" ]; then
        kubectl delete -f chaos-usecase-namespace-quota.yaml
        success "Chaos resources removed"
    else
        log "Cleanup cancelled"
    fi
}

# Main execution
main() {
    log "============================================"
    log "Chaos Engineering: Namespace Quota Scenario"
    log "============================================"
    log ""
    
    check_prerequisites
    
    echo ""
    echo "Options:"
    echo "1. Deploy chaos scenario and monitor"
    echo "2. Monitor existing chaos scenario"
    echo "3. Remediate (fix) chaos scenario"
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
    
    # Run monitoring phases
    monitor_hpa
    check_pending_pods
    analyze_events
    check_quota_usage
    check_prometheus_metrics
    collect_service_logs
    generate_report
    
    echo ""
    log "Test completed. Check log file: $LOG_FILE"
    success "All chaos engineering tests completed!"
}

# Run main function
main "$@"
