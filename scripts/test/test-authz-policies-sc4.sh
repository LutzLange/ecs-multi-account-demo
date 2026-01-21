#!/bin/bash

# ================================================
# test-authz-policies-sc4.sh - Authorization Policy Workshop Tests (Scenario 4)
# ================================================
#
# This script runs connectivity tests for the Authorization Policy workshop
# in Scenario 4 (Multicloud: EKS + AKS). It applies policies and tests their
# effects interactively across cloud boundaries.
#
# Usage:
#   ./scripts/test/test-authz-policies-sc4.sh                      # Uses default config
#   ./scripts/test/test-authz-policies-sc4.sh -c myconfig.sh       # Uses custom config
#   ./scripts/test/test-authz-policies-sc4.sh -e 1                 # Run specific exercise (1-6)
#   ./scripts/test/test-authz-policies-sc4.sh -e all               # Run all exercises
#   ./scripts/test/test-authz-policies-sc4.sh --cleanup            # Remove all policies
#
# Default config: scripts/test/test-scenario-4-config.sh
#

set -e
set -o pipefail

# ================================================
# Setup and Source Library
# ================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/test-scenario-4-config.sh"

# Source the test library for logging and test functions
source "$SCRIPT_DIR/test-lib.sh"

# ================================================
# Global Variables
# ================================================
EKS_SHELL_POD=""
AKS_SHELL_POD=""
ECS_CLUSTER1=""
ECS_CLUSTER2=""
ECS_HOSTNAME_1=""
ECS_HOSTNAME_2=""
AKS_HOSTNAME=""
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
                echo "  -e, --exercise    Run specific exercise (1-6 or 'all')"
                echo "  --cleanup         Remove all authorization policies"
                echo "  -h, --help        Show this help message"
                echo ""
                echo "Exercises:"
                echo "  1. Baseline connectivity (no policies) - cross-cloud tests"
                echo "  2. Deny-all policy on AKS app-a namespace"
                echo "  3. Allow EKS default namespace to AKS"
                echo "  4. Allow ECS Cluster 1 to AKS"
                echo "  5. Deny-all on ECS Cluster 1, allow only AKS"
                echo "  6. Run all exercises sequentially"
                echo ""
                echo "Examples:"
                echo "  $0 -e 1              # Run baseline cross-cloud tests"
                echo "  $0 -e 2              # Apply deny-all on AKS and test"
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
# Configuration
# ================================================
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        log_error "Create it from the example:"
        log_error "  cp ${CONFIG_FILE%.sh}.sh.example $CONFIG_FILE"
        exit 1
    fi

    source "$CONFIG_FILE"

    if [ "$SCENARIO" != "4" ]; then
        log_error "This script is for Scenario 4 only (found SCENARIO=$SCENARIO)"
        exit 1
    fi

    # Validate required contexts
    if [ -z "$CTX_EKS" ] || [ -z "$CTX_AKS" ]; then
        log_error "CTX_EKS and CTX_AKS must be set in config file"
        log_error "Run the full test-scenario-4.sh first to set up the clusters"
        exit 1
    fi

    # Set up variables
    ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    ECS_CLUSTER2="ecs-${CLUSTER_NAME}-2"
    ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"
    ECS_HOSTNAME_2="echo-service.${ECS_CLUSTER2}.ecs.local:8080"
    AKS_HOSTNAME="echo-service.app-a.svc.cluster.local:8080"

    # Get pod names
    EKS_SHELL_POD=$(kubectl --context="$CTX_EKS" get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)
    AKS_SHELL_POD=$(kubectl --context="$CTX_AKS" get pods -n app-a -l app=shell -o jsonpath="{.items[0].metadata.name}" 2>/dev/null)

    if [ -z "$EKS_SHELL_POD" ]; then
        log_error "EKS shell pod not found. Ensure test pods are deployed."
        exit 1
    fi

    if [ -z "$AKS_SHELL_POD" ]; then
        log_error "AKS shell pod not found. Ensure AKS workloads are deployed."
        exit 1
    fi

    log_info "Configuration loaded:"
    log_info "  EKS Context: $CTX_EKS"
    log_info "  AKS Context: $CTX_AKS"
    log_info "  EKS Shell Pod: $EKS_SHELL_POD"
    log_info "  AKS Shell Pod: $AKS_SHELL_POD"
    log_info "  ECS Cluster 1: $ECS_CLUSTER1"
    log_info "  ECS Cluster 2: $ECS_CLUSTER2"
    echo ""
}

# ================================================
# Cleanup Function
# ================================================
cleanup_policies() {
    log_step "Cleaning up all authorization policies"
    kubectl --context="$CTX_EKS" delete authorizationpolicy --all -n "$ECS_CLUSTER1" 2>&1 | grep -v "No resources found" || true
    kubectl --context="$CTX_EKS" delete authorizationpolicy --all -n "$ECS_CLUSTER2" 2>&1 | grep -v "No resources found" || true
    kubectl --context="$CTX_AKS" delete authorizationpolicy --all -n app-a 2>&1 | grep -v "No resources found" || true
    log_info "All policies removed"
    echo ""
}

# ================================================
# Test Functions
# ================================================
test_eks_to_aks() {
    local test_name="${1:-EKS to AKS}"
    log_test "$test_name"
    local RESULT
    RESULT=$(kubectl --context="$CTX_EKS" exec "$EKS_SHELL_POD" -- curl -s --max-time 5 "$AKS_HOSTNAME" 2>&1)
    if echo "$RESULT" | grep -q "hostname"; then
        log_pass "$test_name - Success"
        return 0
    else
        log_fail "$test_name - Failed: $RESULT"
        return 1
    fi
}

test_aks_to_ecs() {
    local cluster="$1"
    local hostname="$2"
    local test_name="${3:-AKS to ECS}"
    log_test "$test_name"
    local RESULT
    RESULT=$(kubectl --context="$CTX_AKS" exec -n app-a "$AKS_SHELL_POD" -- curl -s --max-time 5 "$hostname" 2>&1)
    if echo "$RESULT" | grep -q "hostname"; then
        log_pass "$test_name - Success"
        return 0
    else
        log_fail "$test_name - Failed: $RESULT"
        return 1
    fi
}

test_ecs_to_aks() {
    local origin_cluster="$1"
    local test_name="${2:-ECS to AKS}"
    log_test "$test_name"
    local RESULT
    RESULT=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$AKS_HOSTNAME" 2>&1)
    if echo "$RESULT" | grep -q "hostname"; then
        log_pass "$test_name - Success"
        return 0
    else
        log_fail "$test_name - Failed"
        return 1
    fi
}

test_eks_to_aks_blocked() {
    local test_name="${1:-EKS to AKS (blocked)}"
    log_test "$test_name"
    local RESULT
    RESULT=$(kubectl --context="$CTX_EKS" exec "$EKS_SHELL_POD" -- curl -s --max-time 5 "$AKS_HOSTNAME" 2>&1) || true
    if echo "$RESULT" | grep -q "hostname"; then
        log_fail "$test_name - Unexpectedly succeeded"
        return 1
    else
        log_pass "$test_name - Blocked as expected"
        return 0
    fi
}

test_ecs_to_aks_blocked() {
    local origin_cluster="$1"
    local test_name="${2:-ECS to AKS (blocked)}"
    log_test "$test_name"
    local RESULT
    RESULT=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$AKS_HOSTNAME" 2>&1) || true
    if echo "$RESULT" | grep -q "hostname"; then
        log_fail "$test_name - Unexpectedly succeeded"
        return 1
    else
        log_pass "$test_name - Blocked as expected"
        return 0
    fi
}

test_aks_to_ecs_blocked() {
    local hostname="$1"
    local test_name="${2:-AKS to ECS (blocked)}"
    log_test "$test_name"
    local RESULT
    RESULT=$(kubectl --context="$CTX_AKS" exec -n app-a "$AKS_SHELL_POD" -- curl -s --max-time 5 "$hostname" 2>&1) || true
    if echo "$RESULT" | grep -q "hostname"; then
        log_fail "$test_name - Unexpectedly succeeded"
        return 1
    else
        log_pass "$test_name - Blocked as expected"
        return 0
    fi
}

# ================================================
# Exercise Functions
# ================================================

exercise_1_baseline() {
    log_step "Exercise 1: Baseline Cross-Cloud Connectivity (No Policies)"
    echo ""
    log_info "Testing connectivity between all cloud boundaries..."
    echo ""

    cleanup_policies
    sleep 5

    set +e
    echo "--- EKS to AKS ---"
    test_eks_to_aks "EKS → AKS echo-service"
    echo ""

    echo "--- AKS to ECS ---"
    test_aks_to_ecs "$ECS_CLUSTER1" "$ECS_HOSTNAME_1" "AKS → ECS Cluster 1"
    test_aks_to_ecs "$ECS_CLUSTER2" "$ECS_HOSTNAME_2" "AKS → ECS Cluster 2"
    echo ""

    echo "--- ECS to AKS ---"
    test_ecs_to_aks "$ECS_CLUSTER1" "ECS C1 → AKS"
    test_ecs_to_aks "$ECS_CLUSTER2" "ECS C2 → AKS"
    set -e

    echo ""
    log_info "Exercise 1 complete. All cross-cloud paths should be open."
    echo ""
}

exercise_2_deny_all_aks() {
    log_step "Exercise 2: Deny-All Policy on AKS app-a Namespace"
    echo ""
    log_info "Applying deny-all policy to AKS app-a namespace..."
    echo ""

    cleanup_policies
    sleep 3

    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: app-a
spec:
  {}
EOF

    log_info "Waiting for policy to propagate..."
    sleep 10

    set +e
    echo ""
    echo "--- Testing Access to AKS (should be blocked) ---"
    test_eks_to_aks_blocked "EKS → AKS (should be blocked)"
    test_ecs_to_aks_blocked "$ECS_CLUSTER1" "ECS C1 → AKS (should be blocked)"
    set -e

    echo ""
    log_info "Exercise 2 complete. All access to AKS should be blocked."
    log_info "Policy applied: deny-all in app-a namespace"
    echo ""
}

exercise_3_allow_eks_to_aks() {
    log_step "Exercise 3: Allow EKS Default Namespace to AKS"
    echo ""
    log_info "Adding ALLOW policy for EKS default namespace..."
    echo ""

    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-default
  namespace: app-a
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

    log_info "Waiting for policy to propagate..."
    sleep 10

    set +e
    echo ""
    echo "--- Testing Access ---"
    test_eks_to_aks "EKS → AKS (should succeed)"
    test_ecs_to_aks_blocked "$ECS_CLUSTER1" "ECS C1 → AKS (should still be blocked)"
    set -e

    echo ""
    log_info "Exercise 3 complete."
    log_info "Policies: deny-all + allow-eks-default"
    echo ""
}

exercise_4_allow_ecs_to_aks() {
    log_step "Exercise 4: Allow ECS Cluster 1 to AKS"
    echo ""
    log_info "Adding ALLOW policy for ECS Cluster 1 namespace..."
    echo ""

    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-ecs-cluster1
  namespace: app-a
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

    log_info "Waiting for policy to propagate..."
    sleep 10

    set +e
    echo ""
    echo "--- Testing Access ---"
    test_eks_to_aks "EKS → AKS (should succeed)"
    test_ecs_to_aks "$ECS_CLUSTER1" "ECS C1 → AKS (should now succeed)"
    test_ecs_to_aks_blocked "$ECS_CLUSTER2" "ECS C2 → AKS (should still be blocked)"
    set -e

    echo ""
    log_info "Exercise 4 complete."
    log_info "Policies: deny-all + allow-eks-default + allow-ecs-cluster1"
    echo ""
}

exercise_5_deny_all_ecs_allow_aks() {
    log_step "Exercise 5: Deny-All on ECS Cluster 1, Allow Only AKS"
    echo ""
    log_info "Applying deny-all to ECS Cluster 1, then allowing AKS..."
    echo ""

    # First clean up AKS policies
    kubectl --context="$CTX_AKS" delete authorizationpolicy --all -n app-a 2>&1 | grep -v "No resources found" || true

    # Apply policies to ECS Cluster 1 namespace
    kubectl --context="$CTX_EKS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: $ECS_CLUSTER1
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-aks
  namespace: $ECS_CLUSTER1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["app-a"]
    to:
    - operation:
        ports: ["8080"]
EOF

    log_info "Waiting for policy to propagate..."
    sleep 10

    set +e
    echo ""
    echo "--- Testing Access to ECS Cluster 1 ---"
    test_aks_to_ecs "$ECS_CLUSTER1" "$ECS_HOSTNAME_1" "AKS → ECS C1 (should succeed)"

    log_test "EKS → ECS C1 (should be blocked)"
    local RESULT
    RESULT=$(kubectl --context="$CTX_EKS" exec "$EKS_SHELL_POD" -- curl -s --max-time 5 "$ECS_HOSTNAME_1" 2>&1) || true
    if echo "$RESULT" | grep -q "hostname"; then
        log_fail "EKS → ECS C1 - Unexpectedly succeeded"
    else
        log_pass "EKS → ECS C1 - Blocked as expected"
    fi
    set -e

    echo ""
    log_info "Exercise 5 complete."
    log_info "Policies on ECS C1: deny-all + allow-aks"
    echo ""
}

exercise_all() {
    log_step "Running All Exercises"
    echo ""

    exercise_1_baseline
    read -p "Press Enter to continue to Exercise 2..." </dev/tty

    exercise_2_deny_all_aks
    read -p "Press Enter to continue to Exercise 3..." </dev/tty

    exercise_3_allow_eks_to_aks
    read -p "Press Enter to continue to Exercise 4..." </dev/tty

    exercise_4_allow_ecs_to_aks
    read -p "Press Enter to continue to Exercise 5..." </dev/tty

    exercise_5_deny_all_ecs_allow_aks

    echo ""
    log_step "All Exercises Complete"
    cleanup_policies
}

# ================================================
# Interactive Menu
# ================================================
show_menu() {
    echo ""
    echo "=============================================="
    echo "  Authorization Policy Workshop - Scenario 4"
    echo "  (Multicloud: EKS + AKS)"
    echo "=============================================="
    echo ""
    echo "Available exercises:"
    echo "  1. Baseline cross-cloud connectivity (no policies)"
    echo "  2. Deny-all on AKS app-a namespace"
    echo "  3. Allow EKS default namespace to AKS"
    echo "  4. Allow ECS Cluster 1 to AKS"
    echo "  5. Deny-all on ECS C1, allow only AKS"
    echo "  6. Run all exercises sequentially"
    echo ""
    echo "  c. Cleanup all policies"
    echo "  q. Quit"
    echo ""
    read -p "Select exercise (1-6, c, q): " choice

    case $choice in
        1) exercise_1_baseline ;;
        2) exercise_2_deny_all_aks ;;
        3) exercise_3_allow_eks_to_aks ;;
        4) exercise_4_allow_ecs_to_aks ;;
        5) exercise_5_deny_all_ecs_allow_aks ;;
        6|all) exercise_all ;;
        c|C) cleanup_policies ;;
        q|Q) exit 0 ;;
        *) log_error "Invalid choice" ;;
    esac

    show_menu
}

# ================================================
# Main
# ================================================
main() {
    parse_authz_arguments "$@"

    # Change to repository root
    cd "$(dirname "$0")/../.."

    load_config

    if [ "$CLEANUP_ONLY" = true ]; then
        cleanup_policies
        exit 0
    fi

    if [ -n "$EXERCISE" ]; then
        case $EXERCISE in
            1) exercise_1_baseline ;;
            2) exercise_2_deny_all_aks ;;
            3) exercise_3_allow_eks_to_aks ;;
            4) exercise_4_allow_ecs_to_aks ;;
            5) exercise_5_deny_all_ecs_allow_aks ;;
            6|all) exercise_all ;;
            *) log_error "Invalid exercise: $EXERCISE"; exit 1 ;;
        esac
    else
        show_menu
    fi
}

main "$@"
