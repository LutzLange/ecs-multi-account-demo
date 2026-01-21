#!/bin/bash

# ================================================
# test-scenario-3.sh - End-to-end test for Scenario 3
# ================================================
#
# This script executes all setup steps for Scenario 3 (three ECS clusters
# across two AWS accounts) and runs connectivity tests, recording results
# vs expected outcomes.
#
# Usage:
#   ./scripts/test/test-scenario-3.sh                      # Uses default config
#   ./scripts/test/test-scenario-3.sh -c myconfig.sh       # Uses custom config
#   ./scripts/test/test-scenario-3.sh -d                   # Run tests, then cleanup
#   ./scripts/test/test-scenario-3.sh -t                   # Run tests only (skip setup)
#   ./scripts/test/test-scenario-3.sh -s <step>            # Resume from specific step
#   ./scripts/test/test-scenario-3.sh -l                   # List all steps and progress
#   ./scripts/test/test-scenario-3.sh --reset              # Clear progress and start fresh
#   ./scripts/test/test-scenario-3.sh -c myconfig.sh -d    # Custom config + cleanup
#
# Default config: scripts/test/test-scenario-3-config.sh
#

set -e
set -o pipefail

# ================================================
# Setup and Source Library
# ================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/test-scenario-3-config.sh"

source "$SCRIPT_DIR/test-lib.sh"

# ================================================
# Define Setup Steps for This Scenario
# ================================================
SETUP_STEPS=(
    "sso_login"
    "eks_cluster"
    "gateway_api_crds"
    "infrastructure_iam"
    "istio_install"
    "eastwest_gateway"
    "network_label"
    "istio_verify"
    "ecs_clusters"
    "k8s_namespaces"
    "add_to_mesh"
    "prepare_tests"
)

# Human-readable step descriptions (matches Readme-scenario-3.md)
declare -A STEP_DESCRIPTIONS=(
    ["sso_login"]="AWS SSO Login (Both Accounts)"
    ["eks_cluster"]="Create EKS Cluster"
    ["gateway_api_crds"]="Install Gateway API CRDs"
    ["infrastructure_iam"]="Setup Infrastructure & IAM (Cross-Account)"
    ["istio_install"]="Install Istio Ambient"
    ["eastwest_gateway"]="Deploy East-West Gateway"
    ["network_label"]="Label Network for Mesh"
    ["istio_verify"]="Verify Istio Installation"
    ["ecs_clusters"]="Deploy ECS Clusters (3 across 2 accounts)"
    ["k8s_namespaces"]="Create Kubernetes Namespaces"
    ["add_to_mesh"]="Add ECS Services to Mesh"
    ["prepare_tests"]="Prepare Test Environment"
)

# Part groupings (matches Readme-scenario-3.md structure)
declare -A STEP_PARTS=(
    ["sso_login"]="Part 1: Cross-Account Setup"
    ["eks_cluster"]="Part 1: Cross-Account Setup"
    ["gateway_api_crds"]="Part 2: Istio Installation"
    ["infrastructure_iam"]="Part 2: Istio Installation"
    ["istio_install"]="Part 2: Istio Installation"
    ["eastwest_gateway"]="Part 2: Istio Installation"
    ["network_label"]="Part 2: Istio Installation"
    ["istio_verify"]="Part 2: Istio Installation"
    ["ecs_clusters"]="Part 3: Multi-Account ECS"
    ["k8s_namespaces"]="Part 3: Multi-Account ECS"
    ["add_to_mesh"]="Part 4: Cross-Account Mesh"
    ["prepare_tests"]="Part 5: Testing"
)

# ================================================
# Scenario 3 Specific Functions
# ================================================
load_and_validate_config() {
    log_step "Environment Setup"

    unset_config_variables
    source "$CONFIG_FILE"

    # Validate scenario
    if [ "$SCENARIO" != "3" ]; then
        log_error "This test is for Scenario 3 only"
        log_error "Current SCENARIO=$SCENARIO"
        exit 1
    fi

    # Validate required variables
    validate_required_vars "LOCAL_ACCOUNT EXTERNAL_ACCOUNT LOCAL_ACCOUNT_PROFILE EXTERNAL_ACCOUNT_PROFILE AWS_REGION CLUSTER_NAME HUB ISTIO_TAG GLOO_MESH_LICENSE_KEY"

    log_info "Configuration validated:"
    log_info "  SCENARIO=$SCENARIO"
    log_info "  LOCAL_ACCOUNT=$LOCAL_ACCOUNT"
    log_info "  EXTERNAL_ACCOUNT=$EXTERNAL_ACCOUNT"
    log_info "  LOCAL_ACCOUNT_PROFILE=$LOCAL_ACCOUNT_PROFILE"
    log_info "  EXTERNAL_ACCOUNT_PROFILE=$EXTERNAL_ACCOUNT_PROFILE"
    log_info "  AWS_REGION=$AWS_REGION"
    log_info "  CLUSTER_NAME=$CLUSTER_NAME"
    echo ""
}

install_istio_scenario3() {
    log_step "Install Istio in Ambient Mode"

    check_istioctl

    # Check if Istio is already installed
    if kubectl get deployment istiod -n istio-system &>/dev/null; then
        log_info "Istio is already installed, skipping installation"
    else
        log_info "Installing Istio..."

        # Get LOCAL_ROLE and EXTERNAL_ROLE from config or construct them
        local local_role="${LOCAL_ROLE:-arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local}"
        local external_role="${EXTERNAL_ROLE:-arn:aws:iam::${EXTERNAL_ACCOUNT}:role/istiod-external}"

        cat <<EOF | "$ISTIOCTL" install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      hub: ${HUB}
      tag: ${ISTIO_TAG}
      network: eks
    license:
      value: ${GLOO_MESH_LICENSE_KEY}
    cni:
      ambient:
        dnsCapture: true
    platforms:
      ecs:
        accounts:
          - role: ${local_role}
            domain: ecs.local
          - role: ${external_role}
            domain: ecs.external
    pilot:
      env:
        PILOT_ENABLE_IP_AUTOALLOCATE: "true"
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
        REQUIRE_3P_TOKEN: "false"
EOF

        if [ $? -ne 0 ]; then
            log_error "Failed to install Istio"
            exit 1
        fi
    fi

    log_info "Istio installed"
    echo ""
}

clear_authorization_policies() {
    log_info "Clearing any existing authorization policies..."
    kubectl delete authorizationpolicy --all -n "ecs-${CLUSTER_NAME}-1" 2>&1 | grep -v "No resources found" || true
    kubectl delete authorizationpolicy --all -n "ecs-${CLUSTER_NAME}-2" 2>&1 | grep -v "No resources found" || true
    kubectl delete authorizationpolicy --all -n "ecs-${CLUSTER_NAME}-3" 2>&1 | grep -v "No resources found" || true
    sleep 5  # Brief wait for policy removal to propagate
}

# ================================================
# Test Orchestration
# ================================================
run_connectivity_tests() {
    log_step "Run Connectivity Tests"

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    local ECS_CLUSTER2="ecs-${CLUSTER_NAME}-2"
    local ECS_CLUSTER3="ecs-${CLUSTER_NAME}-3"
    local ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"
    local ECS_HOSTNAME_2="echo-service.${ECS_CLUSTER2}.ecs.local:8080"
    local ECS_HOSTNAME_3="echo-service.${ECS_CLUSTER3}.ecs.external:8080"

    # Disable strict error handling for connectivity tests
    set +e
    set +o pipefail

    echo ""
    test_eks_to_eks_connectivity "$EKS_SHELL_POD"

    echo ""
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME_1" "EKS-to-ECS Cluster 1 (local)"

    echo ""
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME_2" "EKS-to-ECS Cluster 2 (local)"

    echo ""
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME_3" "EKS-to-ECS Cluster 3 (external)"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "ECS Cluster 1 internal" "$ECS_CLUSTER1"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_2" "ECS Cluster 2 internal" "$ECS_CLUSTER2"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_3" "ECS Cluster 3 internal (external)" "$ECS_CLUSTER3"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_2" "Cross-cluster: C1 to C2" "$ECS_CLUSTER1"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "Cross-cluster: C2 to C1" "$ECS_CLUSTER2"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_3" "Cross-account: C1 to C3" "$ECS_CLUSTER1"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "Cross-account: C3 to C1" "$ECS_CLUSTER3"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

run_authorization_policy_tests() {
    log_step "Test Authorization Policies (Workshop Exercises)"

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    local ECS_CLUSTER2="ecs-${CLUSTER_NAME}-2"
    local ECS_CLUSTER3="ecs-${CLUSTER_NAME}-3"
    local ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"
    local ECS_HOSTNAME_3="echo-service.${ECS_CLUSTER3}.ecs.external:8080"

    # Disable strict error handling for policy tests
    set +e
    set +o pipefail

    # Exercise 6.1: Baseline (no policies) - already tested in run_connectivity_tests
    log_info "Exercise 6.1: Baseline already verified in connectivity tests"

    # Exercise 6.2: Deny-all policy
    echo ""
    log_info "Exercise 6.2: Testing deny-all policy on Cluster 1"
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ${ECS_CLUSTER1}
spec:
  {}
EOF
    sleep 10

    # EKS -> Cluster 1 should be blocked
    test_connection_blocked_eks "$EKS_SHELL_POD" "$ECS_HOSTNAME_1" "6.2: EKS to C1 blocked"
    # Cluster 2 -> Cluster 1 should be blocked
    test_connection_blocked "$ECS_HOSTNAME_1" "6.2: C2 to C1 blocked" "$ECS_CLUSTER2"
    # Cluster 3 -> Cluster 1 should be blocked (cross-account)
    test_connection_blocked "$ECS_HOSTNAME_1" "6.2: C3 to C1 blocked (cross-account)" "$ECS_CLUSTER3"
    # Cluster 1 internal should be blocked
    test_connection_blocked "$ECS_HOSTNAME_1" "6.2: C1 internal blocked" "$ECS_CLUSTER1"

    # Exercise 6.3: Allow EKS to Cluster 1
    echo ""
    log_info "Exercise 6.3: Adding allow-eks-to-echo policy"
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: ${ECS_CLUSTER1}
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
    sleep 10

    # EKS -> Cluster 1 should now succeed
    test_eks_policy_allowed "$EKS_SHELL_POD" "$ECS_HOSTNAME_1" "6.3: EKS to C1 allowed"
    # Cluster 2 -> Cluster 1 should still be blocked
    test_connection_blocked "$ECS_HOSTNAME_1" "6.3: C2 to C1 blocked" "$ECS_CLUSTER2"
    # Cluster 3 -> Cluster 1 should still be blocked (cross-account)
    test_connection_blocked "$ECS_HOSTNAME_1" "6.3: C3 to C1 blocked (cross-account)" "$ECS_CLUSTER3"

    # Exercise 6.4: Allow Cluster 2 to Cluster 1 (same account)
    echo ""
    log_info "Exercise 6.4: Adding allow-cluster-2-to-echo policy"
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-2-to-echo
  namespace: ${ECS_CLUSTER1}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["${ECS_CLUSTER2}"]
    to:
    - operation:
        ports: ["8080"]
EOF
    sleep 10

    # Cluster 2 -> Cluster 1 should now succeed
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "6.4: C2 to C1 allowed" "$ECS_CLUSTER2"
    # Cluster 3 -> Cluster 1 should still be blocked (cross-account)
    test_connection_blocked "$ECS_HOSTNAME_1" "6.4: C3 to C1 blocked (cross-account)" "$ECS_CLUSTER3"
    # Cluster 1 internal should still be blocked
    test_connection_blocked "$ECS_HOSTNAME_1" "6.4: C1 internal blocked" "$ECS_CLUSTER1"

    # Exercise 6.5: Allow Cluster 3 to Cluster 1 (cross-account)
    echo ""
    log_info "Exercise 6.5: Adding allow-cluster-3-to-echo policy (cross-account)"
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-3-to-echo
  namespace: ${ECS_CLUSTER1}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["${ECS_CLUSTER3}"]
    to:
    - operation:
        ports: ["8080"]
EOF
    sleep 10

    # Cluster 3 -> Cluster 1 should now succeed (cross-account)
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "6.5: C3 to C1 allowed (cross-account)" "$ECS_CLUSTER3"
    # Cluster 1 internal should still be blocked
    test_connection_blocked "$ECS_HOSTNAME_1" "6.5: C1 internal blocked" "$ECS_CLUSTER1"

    # Exercise 6.6: Allow internal communication
    echo ""
    log_info "Exercise 6.6: Adding allow-internal policy"
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-internal
  namespace: ${ECS_CLUSTER1}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["${ECS_CLUSTER1}"]
    to:
    - operation:
        ports: ["8080"]
EOF
    sleep 10

    # Cluster 1 internal should now succeed
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "6.6: C1 internal allowed" "$ECS_CLUSTER1"

    # Exercise 6.7: Explicit deny external account (reset and test DENY precedence)
    echo ""
    log_info "Exercise 6.7: Testing explicit DENY for external account"
    clear_authorization_policies
    sleep 5

    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ${ECS_CLUSTER1}
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: ${ECS_CLUSTER1}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]
    to:
    - operation:
        ports: ["8080"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-2-to-echo
  namespace: ${ECS_CLUSTER1}
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["${ECS_CLUSTER2}"]
    to:
    - operation:
        ports: ["8080"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-external-account
  namespace: ${ECS_CLUSTER1}
spec:
  action: DENY
  rules:
  - from:
    - source:
        namespaces: ["${ECS_CLUSTER3}"]
EOF
    sleep 10

    # EKS -> Cluster 1 should succeed
    test_eks_policy_allowed "$EKS_SHELL_POD" "$ECS_HOSTNAME_1" "6.7: EKS to C1 allowed"
    # Cluster 2 -> Cluster 1 should succeed
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "6.7: C2 to C1 allowed" "$ECS_CLUSTER2"
    # Cluster 3 -> Cluster 1 should be blocked by explicit DENY (cross-account)
    test_connection_blocked "$ECS_HOSTNAME_1" "6.7: C3 to C1 denied (explicit)" "$ECS_CLUSTER3"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

# test_connection_blocked_eks() is now provided by test-lib.sh

# ================================================
# Setup Orchestration
# ================================================

# Wrapper functions for run_step (must return 0 on success)
do_sso_login() {
    aws_sso_login "$INT"
    aws_sso_login "$EXT"
}
do_eks_cluster() { create_eks_cluster; }
do_gateway_api_crds() { deploy_gateway_api_crds; }
do_infrastructure_iam() { setup_infrastructure_and_iam; }
do_istio_install() { install_istio_scenario3; }
do_eastwest_gateway() { deploy_eastwest_gateway; }
do_network_label() { label_network; }
do_istio_verify() { verify_istio_installation; }
do_ecs_clusters() { deploy_ecs_clusters; }
do_k8s_namespaces() { create_k8s_namespaces; }
do_add_to_mesh() { add_services_to_mesh; }
do_prepare_tests() { prepare_test_environment; }

run_setup_steps() {
    local rc
    for step in "${SETUP_STEPS[@]}"; do
        case "$step" in
            sso_login)        run_step "$step" do_sso_login ;;
            eks_cluster)      run_step "$step" do_eks_cluster ;;
            gateway_api_crds) run_step "$step" do_gateway_api_crds ;;
            infrastructure_iam) run_step "$step" do_infrastructure_iam ;;
            istio_install)    run_step "$step" do_istio_install ;;
            eastwest_gateway) run_step "$step" do_eastwest_gateway ;;
            network_label)    run_step "$step" do_network_label ;;
            istio_verify)     run_step "$step" do_istio_verify ;;
            ecs_clusters)     run_step "$step" do_ecs_clusters ;;
            k8s_namespaces)   run_step "$step" do_k8s_namespaces ;;
            add_to_mesh)      run_step "$step" do_add_to_mesh ;;
            prepare_tests)    run_step "$step" do_prepare_tests ;;
        esac
        rc=$?
        if [ $rc -eq 1 ]; then
            return 1  # Step failed
        elif [ $rc -eq 2 ]; then
            return 0  # Stop-after reached, but not an error
        fi
    done
}

prepare_test_environment() {
    log_step "Preparing test environment"
    clear_authorization_policies
    deploy_test_pods
    log_info "Waiting 30 seconds for service discovery..."
    sleep 30
    # Scenario 3 expects 6 services, 6 workloads, 6 entries (2 per cluster)
    verify_service_discovery 6 6 6
}

run_test_steps() {
    run_connectivity_tests
    run_authorization_policy_tests
    # Clean up authorization policies after testing
    clear_authorization_policies
}

# ================================================
# Cleanup
# ================================================
cleanup_resources() {
    log_step "Cleanup: Removing all resources"

    clear_authorization_policies
    cleanup_test_pods

    # Run cleanup script
    ./scripts/cleanup.sh -c "$CONFIG_FILE" || log_warn "Cleanup script had some errors"

    cleanup_eks_cluster "$CLUSTER_NAME" "$INT"

    log_info "Cleanup complete"
}

# ================================================
# Main
# ================================================
print_header() {
    echo ""
    echo "=============================================="
    echo "     SCENARIO 3 END-TO-END TEST"
    echo "     (Cross-Account: 3 Clusters, 2 Accounts)"
    echo "=============================================="
    echo ""
    log_info "Repository root: $REPO_ROOT"
    log_info "Config file: $CONFIG_FILE"
    log_info "Tests only mode: $TESTS_ONLY"
    log_info "Skip setup: $SKIP_SETUP"
    log_info "Cleanup after tests: $DELETE_AFTER"
    if [ -n "$START_FROM_STEP" ]; then
        local step_num=$(get_step_number "$START_FROM_STEP" "${SETUP_STEPS[@]}")
        local step_desc="${STEP_DESCRIPTIONS[$START_FROM_STEP]:-$START_FROM_STEP}"
        log_info "Starting from: Step $step_num - $step_desc"
    fi
    if [ -n "$STOP_AFTER_STEP" ]; then
        local step_num=$(get_step_number "$STOP_AFTER_STEP" "${SETUP_STEPS[@]}")
        local step_desc="${STEP_DESCRIPTIONS[$STOP_AFTER_STEP]:-$STOP_AFTER_STEP}"
        log_info "Stopping after: Step $step_num - $step_desc"
    fi
    if [ "$RESET_PROGRESS" = true ]; then
        log_info "Progress will be reset"
    fi
    echo ""
}

main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Resolve step names (convert numbers to names if needed)
    if [ -n "$START_FROM_STEP" ]; then
        START_FROM_STEP="$(get_step_by_number "$START_FROM_STEP" "${SETUP_STEPS[@]}")"
    fi
    if [ -n "$STOP_AFTER_STEP" ]; then
        STOP_AFTER_STEP="$(get_step_by_number "$STOP_AFTER_STEP" "${SETUP_STEPS[@]}")"
    fi

    # Validate config file exists
    validate_config_file

    # Change to repository root
    cd "$(dirname "$0")/../.."
    REPO_ROOT=$(pwd)

    # Set progress file in repo root
    export PROGRESS_FILE="$REPO_ROOT/.workshop-progress-sc3"

    # Load and validate configuration
    load_and_validate_config

    # Load progress from progress file
    load_progress

    # Handle --list option
    if [ "$LIST_STEPS" = true ]; then
        list_workshop_steps
        exit 0
    fi

    # Handle --reset option
    if [ "$RESET_PROGRESS" = true ]; then
        clear_progress
    fi

    # Print header
    print_header

    # Run setup if not in tests-only mode
    if [ "$TESTS_ONLY" = true ]; then
        log_info "Skipping setup steps (tests-only mode)"
        echo ""
        # Still need to clear leftover policies and ensure test pods exist
        clear_authorization_policies
        deploy_test_pods
    else
        if ! run_setup_steps; then
            log_error "Setup failed. Fix the issue and retry with:"
            log_error "  $0 -c $CONFIG_FILE -s $CURRENT_STEP"
            exit 1
        fi
    fi

    # Run tests
    run_test_steps

    # Print summary
    print_test_summary
    TEST_EXIT_CODE=$?

    # Cleanup if requested
    if [ "$DELETE_AFTER" = true ]; then
        echo ""
        cleanup_resources
    else
        echo ""
        log_info "Environment kept intact. To cleanup later, run:"
        log_info "  ./scripts/cleanup.sh -c $CONFIG_FILE"
        log_info "  eksctl delete cluster -n $CLUSTER_NAME --profile $INT"
    fi

    exit $TEST_EXIT_CODE
}

# Run main function with all arguments
main "$@"
