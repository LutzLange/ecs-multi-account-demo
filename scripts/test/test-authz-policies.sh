#!/bin/bash

# ================================================
# test-authz-policies.sh - Authorization Policy Workshop Tests
# ================================================
#
# This script runs connectivity tests for the Authorization Policy workshop
# in Scenario 2. It applies policies and tests their effects interactively.
#
# Usage:
#   ./scripts/test/test-authz-policies.sh                      # Uses default config
#   ./scripts/test/test-authz-policies.sh -c myconfig.sh       # Uses custom config
#   ./scripts/test/test-authz-policies.sh -e 1                 # Run specific exercise (1-7)
#   ./scripts/test/test-authz-policies.sh -e all               # Run all exercises
#   ./scripts/test/test-authz-policies.sh --cleanup            # Remove all policies
#
# Default config: scripts/test/test-scenario-2-config.sh
#

set -e
set -o pipefail

# ================================================
# Setup and Source Library
# ================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/test-scenario-2-config.sh"

# Source the test library for logging and test functions
source "$SCRIPT_DIR/test-lib.sh"

# ================================================
# Global Variables
# ================================================
EKS_SHELL_POD=""
ECS_CLUSTER1=""
ECS_CLUSTER2=""
ECS_HOSTNAME_1=""
ECS_HOSTNAME_2=""
EXERCISE=""
CLEANUP_ONLY=false

# ================================================
# Parse Arguments
# ================================================
parse_authz_arguments() {
    CONFIG_FILE=""
    EXERCISE=""
    CLEANUP_ONLY=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -e|--exercise)
                EXERCISE="$2"
                shift 2
                ;;
            --cleanup)
                CLEANUP_ONLY=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [-c config-file] [-e exercise] [--cleanup]"
                echo ""
                echo "Options:"
                echo "  -c, --config      Config file to use (default: $DEFAULT_CONFIG)"
                echo "  -e, --exercise    Run specific exercise (1-7 or 'all')"
                echo "  --cleanup         Remove all authorization policies"
                echo "  -h, --help        Show this help message"
                echo ""
                echo "Exercises:"
                echo "  1. Baseline connectivity (no policies)"
                echo "  2. Deny-all policy on Cluster 1"
                echo "  3. Allow EKS to Cluster 1"
                echo "  4. Allow Cluster 2 to Cluster 1"
                echo "  5. Allow internal communication within Cluster 1"
                echo "  6. Explicit deny Cluster 2 (while allowing EKS)"
                echo "  7. Run all exercises sequentially"
                echo ""
                echo "Examples:"
                echo "  $0 -e 1              # Run baseline tests"
                echo "  $0 -e 2              # Apply deny-all and test"
                echo "  $0 -e all            # Run all exercises"
                echo "  $0 --cleanup         # Clean up all policies"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Use default config if not specified
    if [ -z "$CONFIG_FILE" ]; then
        CONFIG_FILE="$DEFAULT_CONFIG"
    fi
}

# ================================================
# Configuration Loading
# ================================================
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi

    unset_config_variables
    source "$CONFIG_FILE"

    # Validate scenario
    if [ "$SCENARIO" != "2" ]; then
        log_error "This script is for Scenario 2 only (two ECS clusters)"
        log_error "Current SCENARIO=$SCENARIO"
        exit 1
    fi

    # Check istioctl
    check_istioctl

    # Set up variables
    ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    ECS_CLUSTER2="ecs-${CLUSTER_NAME}-2"
    ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"
    ECS_HOSTNAME_2="echo-service.${ECS_CLUSTER2}.ecs.local:8080"

    log_info "Configuration:"
    log_info "  CLUSTER_NAME=$CLUSTER_NAME"
    log_info "  ECS Cluster 1: $ECS_CLUSTER1"
    log_info "  ECS Cluster 2: $ECS_CLUSTER2"
    echo ""
}

setup_test_env() {
    # Get EKS shell pod
    EKS_SHELL_POD=$(get_eks_shell_pod 2>/dev/null || echo "")
    if [ -z "$EKS_SHELL_POD" ]; then
        log_error "EKS shell pod not found. Deploy test pods first:"
        log_error "  kubectl apply -f manifests/eks-shell.yaml"
        exit 1
    fi
    log_info "Using EKS shell pod: $EKS_SHELL_POD"
}

# ================================================
# Policy Management Functions
# ================================================
clear_all_policies() {
    log_info "Clearing all authorization policies..."
    kubectl delete authorizationpolicy --all -n "$ECS_CLUSTER1" 2>&1 | grep -v "No resources found" || true
    kubectl delete authorizationpolicy --all -n "$ECS_CLUSTER2" 2>&1 | grep -v "No resources found" || true
    sleep 3
}

apply_policy() {
    local name="$1"
    local namespace="$2"
    local policy_yaml="$3"

    log_info "Applying policy: $name in namespace $namespace"
    echo "$policy_yaml" | kubectl apply -f -
}

wait_for_policy_propagation() {
    local seconds="${1:-10}"
    log_info "Waiting ${seconds}s for policy propagation..."
    sleep "$seconds"
}

# ================================================
# Test Functions
# ================================================
print_exercise_header() {
    local num="$1"
    local title="$2"
    echo ""
    echo "=============================================="
    echo "  Exercise $num: $title"
    echo "=============================================="
    echo ""
}

run_connectivity_matrix() {
    local description="$1"
    log_info "Running connectivity tests: $description"
    echo ""

    # Disable strict error handling for tests
    set +e
    set +o pipefail

    # Test EKS -> Cluster 1
    log_test "EKS -> Cluster 1 echo-service"
    local result
    result=$(kubectl exec "$EKS_SHELL_POD" -- curl -s --max-time 5 "$ECS_HOSTNAME_1" 2>&1)
    if echo "$result" | grep -q "hostname"; then
        log_pass "Connected successfully"
    else
        log_fail "Connection failed: $(echo "$result" | head -c 100)"
    fi

    # Test EKS -> Cluster 2
    log_test "EKS -> Cluster 2 echo-service"
    result=$(kubectl exec "$EKS_SHELL_POD" -- curl -s --max-time 5 "$ECS_HOSTNAME_2" 2>&1)
    if echo "$result" | grep -q "hostname"; then
        log_pass "Connected successfully"
    else
        log_fail "Connection failed: $(echo "$result" | head -c 100)"
    fi

    # Test Cluster 1 -> Cluster 2
    log_test "Cluster 1 -> Cluster 2 echo-service"
    result=$(ORIGIN_CLUSTER="$ECS_CLUSTER1" ./scripts/test/call-from-ecs.sh "$ECS_HOSTNAME_2" 2>&1)
    if echo "$result" | grep -q "hostname"; then
        log_pass "Connected successfully"
    else
        log_fail "Connection failed: $(echo "$result" | head -c 100)"
    fi

    # Test Cluster 2 -> Cluster 1
    log_test "Cluster 2 -> Cluster 1 echo-service"
    result=$(ORIGIN_CLUSTER="$ECS_CLUSTER2" ./scripts/test/call-from-ecs.sh "$ECS_HOSTNAME_1" 2>&1)
    if echo "$result" | grep -q "hostname"; then
        log_pass "Connected successfully"
    else
        log_fail "Connection failed: $(echo "$result" | head -c 100)"
    fi

    # Test Cluster 1 internal
    log_test "Cluster 1 internal (shell -> echo)"
    result=$(ORIGIN_CLUSTER="$ECS_CLUSTER1" ./scripts/test/call-from-ecs.sh "$ECS_HOSTNAME_1" 2>&1)
    if echo "$result" | grep -q "hostname"; then
        log_pass "Connected successfully"
    else
        log_fail "Connection failed: $(echo "$result" | head -c 100)"
    fi

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

# ================================================
# Exercise Implementations
# ================================================
exercise_1_baseline() {
    print_exercise_header "6.1" "Baseline Connectivity (No Policies)"

    log_info "Clearing any existing policies for clean baseline..."
    clear_all_policies

    log_info "Current authorization policies:"
    kubectl get authorizationpolicies -A 2>/dev/null || echo "  (none)"
    echo ""

    run_connectivity_matrix "Baseline - all connections should succeed"

    log_info "Expected: All connections succeed (no restrictions)"
}

exercise_2_deny_all() {
    print_exercise_header "6.2" "Deny-All Policy (Cluster 1 Isolation)"

    log_info "Clearing existing policies..."
    clear_all_policies

    log_info "Applying deny-all policy to Cluster 1..."
    apply_policy "deny-all" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: $ECS_CLUSTER1
spec:
  {}
EOF
)"

    wait_for_policy_propagation 10

    run_connectivity_matrix "After deny-all on Cluster 1"

    log_info "Expected:"
    log_info "  - EKS -> Cluster 1:      BLOCKED"
    log_info "  - EKS -> Cluster 2:      OK"
    log_info "  - Cluster 1 -> Cluster 2: OK"
    log_info "  - Cluster 2 -> Cluster 1: BLOCKED"
    log_info "  - Cluster 1 internal:    BLOCKED"
}

exercise_3_allow_eks() {
    print_exercise_header "6.3" "Allow EKS to Cluster 1"

    log_info "Adding allow-eks-to-echo policy (keeping deny-all)..."

    # Ensure deny-all exists
    kubectl get authorizationpolicy deny-all -n "$ECS_CLUSTER1" &>/dev/null || {
        log_info "Applying deny-all first..."
        apply_policy "deny-all" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: $ECS_CLUSTER1
spec:
  {}
EOF
)"
    }

    apply_policy "allow-eks-to-echo" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: $ECS_CLUSTER1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]
    to:
    - operation:
        ports: ["8080"]
EOF
)"

    wait_for_policy_propagation 10

    run_connectivity_matrix "After adding allow-eks-to-echo"

    log_info "Expected:"
    log_info "  - EKS -> Cluster 1:      OK (allowed by policy)"
    log_info "  - EKS -> Cluster 2:      OK"
    log_info "  - Cluster 1 -> Cluster 2: OK"
    log_info "  - Cluster 2 -> Cluster 1: BLOCKED"
    log_info "  - Cluster 1 internal:    BLOCKED"
}

exercise_4_allow_cluster2() {
    print_exercise_header "6.4" "Allow Cluster 2 to Cluster 1"

    log_info "Adding allow-cluster-2-to-echo policy..."

    # Ensure previous policies exist
    kubectl get authorizationpolicy deny-all -n "$ECS_CLUSTER1" &>/dev/null || exercise_3_allow_eks

    apply_policy "allow-cluster-2-to-echo" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-2-to-echo
  namespace: $ECS_CLUSTER1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["$ECS_CLUSTER2"]
    to:
    - operation:
        ports: ["8080"]
EOF
)"

    wait_for_policy_propagation 10

    run_connectivity_matrix "After adding allow-cluster-2-to-echo"

    log_info "Expected:"
    log_info "  - EKS -> Cluster 1:      OK"
    log_info "  - EKS -> Cluster 2:      OK"
    log_info "  - Cluster 1 -> Cluster 2: OK"
    log_info "  - Cluster 2 -> Cluster 1: OK (allowed by policy)"
    log_info "  - Cluster 1 internal:    BLOCKED"
}

exercise_5_allow_internal() {
    print_exercise_header "6.5" "Allow Internal Communication (Cluster 1)"

    log_info "Adding allow-internal policy..."

    # Ensure previous policies exist
    kubectl get authorizationpolicy deny-all -n "$ECS_CLUSTER1" &>/dev/null || exercise_4_allow_cluster2

    apply_policy "allow-internal" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-internal
  namespace: $ECS_CLUSTER1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["$ECS_CLUSTER1"]
    to:
    - operation:
        ports: ["8080"]
EOF
)"

    wait_for_policy_propagation 10

    run_connectivity_matrix "After adding allow-internal"

    log_info "Expected:"
    log_info "  - EKS -> Cluster 1:      OK"
    log_info "  - EKS -> Cluster 2:      OK"
    log_info "  - Cluster 1 -> Cluster 2: OK"
    log_info "  - Cluster 2 -> Cluster 1: OK"
    log_info "  - Cluster 1 internal:    OK (allowed by policy)"
}

exercise_6_deny_cluster2() {
    print_exercise_header "6.6" "Explicit Deny Cluster 2"

    log_info "Resetting to deny-all + allow-eks, then adding explicit deny for Cluster 2..."
    clear_all_policies

    apply_policy "deny-all" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: $ECS_CLUSTER1
spec:
  {}
EOF
)"

    apply_policy "allow-eks-to-echo" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: $ECS_CLUSTER1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]
    to:
    - operation:
        ports: ["8080"]
EOF
)"

    apply_policy "deny-cluster-2" "$ECS_CLUSTER1" "$(cat <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-cluster-2
  namespace: $ECS_CLUSTER1
spec:
  action: DENY
  rules:
  - from:
    - source:
        namespaces: ["$ECS_CLUSTER2"]
EOF
)"

    wait_for_policy_propagation 10

    run_connectivity_matrix "With explicit deny for Cluster 2"

    log_info "Expected:"
    log_info "  - EKS -> Cluster 1:      OK"
    log_info "  - EKS -> Cluster 2:      OK"
    log_info "  - Cluster 1 -> Cluster 2: OK"
    log_info "  - Cluster 2 -> Cluster 1: BLOCKED (explicit DENY)"
    log_info "  - Cluster 1 internal:    BLOCKED"
    echo ""
    log_info "Note: DENY rules are evaluated before ALLOW rules."
    log_info "Even if you add allow-cluster-2-to-echo, the DENY takes precedence."
}

exercise_7_summary() {
    print_exercise_header "6.7" "Policy Summary & Cleanup"

    log_info "Current policies on Cluster 1:"
    kubectl get authorizationpolicies -n "$ECS_CLUSTER1" -o wide 2>/dev/null || echo "  (none)"
    echo ""

    log_info "Current policies on Cluster 2:"
    kubectl get authorizationpolicies -n "$ECS_CLUSTER2" -o wide 2>/dev/null || echo "  (none)"
    echo ""

    log_info "Key learnings:"
    echo "  1. Empty spec {} = deny-all (implicit deny)"
    echo "  2. ALLOW rules open specific paths through deny-all"
    echo "  3. DENY rules are evaluated BEFORE ALLOW rules"
    echo "  4. Policies are namespace-scoped"
    echo "  5. Source identity comes from mTLS certificates"
    echo ""

    read -p "Clean up all policies? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        clear_all_policies
        log_info "All policies removed"
    else
        log_info "Policies kept in place"
    fi
}

run_all_exercises() {
    exercise_1_baseline
    echo ""
    read -p "Press Enter to continue to Exercise 6.2..."

    exercise_2_deny_all
    echo ""
    read -p "Press Enter to continue to Exercise 6.3..."

    exercise_3_allow_eks
    echo ""
    read -p "Press Enter to continue to Exercise 6.4..."

    exercise_4_allow_cluster2
    echo ""
    read -p "Press Enter to continue to Exercise 6.5..."

    exercise_5_allow_internal
    echo ""
    read -p "Press Enter to continue to Exercise 6.6..."

    exercise_6_deny_cluster2
    echo ""
    read -p "Press Enter to continue to Summary..."

    exercise_7_summary
}

# ================================================
# Main
# ================================================
print_header() {
    echo ""
    echo "=============================================="
    echo "  AUTHORIZATION POLICY WORKSHOP"
    echo "  Scenario 2: Two ECS Clusters"
    echo "=============================================="
    echo ""
}

main() {
    parse_authz_arguments "$@"

    # Change to repository root
    cd "$(dirname "$0")/../.."

    load_config

    print_header

    # Handle cleanup-only mode
    if [ "$CLEANUP_ONLY" = true ]; then
        clear_all_policies
        log_info "Cleanup complete"
        exit 0
    fi

    setup_test_env

    # If no exercise specified, show menu
    if [ -z "$EXERCISE" ]; then
        echo "Select an exercise to run:"
        echo ""
        echo "  1) Baseline connectivity (no policies)"
        echo "  2) Deny-all policy on Cluster 1"
        echo "  3) Allow EKS to Cluster 1"
        echo "  4) Allow Cluster 2 to Cluster 1"
        echo "  5) Allow internal communication"
        echo "  6) Explicit deny Cluster 2"
        echo "  7) Summary & cleanup"
        echo ""
        echo "  all) Run all exercises sequentially"
        echo "  q) Quit"
        echo ""
        read -p "Enter choice: " EXERCISE
    fi

    case "$EXERCISE" in
        1) exercise_1_baseline ;;
        2) exercise_2_deny_all ;;
        3) exercise_3_allow_eks ;;
        4) exercise_4_allow_cluster2 ;;
        5) exercise_5_allow_internal ;;
        6) exercise_6_deny_cluster2 ;;
        7) exercise_7_summary ;;
        all) run_all_exercises ;;
        q|Q) exit 0 ;;
        *)
            log_error "Invalid exercise: $EXERCISE"
            exit 1
            ;;
    esac

    echo ""
    log_info "Done! Run with different -e option for other exercises."
}

main "$@"
