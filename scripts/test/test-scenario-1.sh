#!/bin/bash

# ================================================
# test-scenario-1.sh - End-to-end test for Scenario 1
# ================================================
#
# This script executes all setup steps for Scenario 1 (single ECS cluster)
# and runs connectivity tests, recording results vs expected outcomes.
#
# Usage:
#   ./scripts/test/test-scenario-1.sh                      # Uses default config
#   ./scripts/test/test-scenario-1.sh -c myconfig.sh       # Uses custom config
#   ./scripts/test/test-scenario-1.sh -d                   # Run tests, then cleanup
#   ./scripts/test/test-scenario-1.sh -t                   # Run tests only (skip setup)
#   ./scripts/test/test-scenario-1.sh -s <step>            # Resume from specific step
#   ./scripts/test/test-scenario-1.sh -l                   # List all steps and progress
#   ./scripts/test/test-scenario-1.sh --reset              # Clear progress and start fresh
#   ./scripts/test/test-scenario-1.sh -c myconfig.sh -d    # Custom config + cleanup
#
# Default config: scripts/test/test-scenario-1-config.sh
#

set -e
set -o pipefail

# ================================================
# Setup and Source Library
# ================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONFIG="$SCRIPT_DIR/test-scenario-1-config.sh"

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

# Human-readable step descriptions (matches Readme-scenario-1.md)
declare -A STEP_DESCRIPTIONS=(
    ["sso_login"]="AWS SSO Login"
    ["eks_cluster"]="Create EKS Cluster"
    ["gateway_api_crds"]="Install Gateway API CRDs"
    ["infrastructure_iam"]="Setup Infrastructure & IAM"
    ["istio_install"]="Install Istio Ambient"
    ["eastwest_gateway"]="Deploy East-West Gateway"
    ["network_label"]="Label Network for Mesh"
    ["istio_verify"]="Verify Istio Installation"
    ["ecs_clusters"]="Deploy ECS Cluster"
    ["k8s_namespaces"]="Create Kubernetes Namespaces"
    ["add_to_mesh"]="Add ECS Services to Mesh"
    ["prepare_tests"]="Prepare Test Environment"
)

# Part groupings (matches Readme-scenario-1.md structure)
declare -A STEP_PARTS=(
    ["sso_login"]="Part 1: Infrastructure Setup"
    ["eks_cluster"]="Part 1: Infrastructure Setup"
    ["gateway_api_crds"]="Part 2: Istio Installation"
    ["infrastructure_iam"]="Part 2: Istio Installation"
    ["istio_install"]="Part 2: Istio Installation"
    ["eastwest_gateway"]="Part 2: Istio Installation"
    ["network_label"]="Part 2: Istio Installation"
    ["istio_verify"]="Part 2: Istio Installation"
    ["ecs_clusters"]="Part 3: ECS Deployment"
    ["k8s_namespaces"]="Part 3: ECS Deployment"
    ["add_to_mesh"]="Part 4: Mesh Integration"
    ["prepare_tests"]="Part 5: Testing"
)

# ================================================
# Scenario 1 Specific Functions
# ================================================
load_and_validate_config() {
    log_step "Environment Setup"

    unset_config_variables
    source "$CONFIG_FILE"

    # Validate scenario
    if [ "$SCENARIO" != "1" ]; then
        log_error "This test is for Scenario 1 only"
        log_error "Current SCENARIO=$SCENARIO"
        exit 1
    fi

    # Validate required variables
    validate_required_vars "LOCAL_ACCOUNT LOCAL_ACCOUNT_PROFILE AWS_REGION CLUSTER_NAME HUB ISTIO_TAG GLOO_MESH_LICENSE_KEY"

    log_info "Configuration validated:"
    log_info "  SCENARIO=$SCENARIO"
    log_info "  LOCAL_ACCOUNT=$LOCAL_ACCOUNT"
    log_info "  LOCAL_ACCOUNT_PROFILE=$LOCAL_ACCOUNT_PROFILE"
    log_info "  AWS_REGION=$AWS_REGION"
    log_info "  CLUSTER_NAME=$CLUSTER_NAME"
    echo ""
}

install_istio_scenario1() {
    log_step "Install Istio in Ambient Mode"

    check_istioctl

    # Check if Istio is already installed
    if kubectl get deployment istiod -n istio-system &>/dev/null; then
        log_info "Istio is already installed, skipping installation"
    else
        log_info "Installing Istio..."
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
          - role: arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local
            domain: ecs.local
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

apply_authorization_policies() {
    log_info "Applying authorization policies..."
    kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: ecs-${CLUSTER_NAME}-1
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
}

clear_authorization_policies() {
    log_info "Clearing any existing authorization policies..."
    kubectl delete authorizationpolicy deny-all allow-eks-to-echo -n "ecs-${CLUSTER_NAME}-1" 2>/dev/null || true
    sleep 5  # Brief wait for policy removal to propagate
}

# ================================================
# Test Orchestration
# ================================================
run_connectivity_tests() {
    log_step "Run Connectivity Tests"

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local ECS_HOSTNAME="echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080"

    # Disable strict error handling for connectivity tests
    set +e
    set +o pipefail

    echo ""
    test_eks_to_eks_connectivity "$EKS_SHELL_POD"

    echo ""
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME"

    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME" "ECS-to-ECS (same cluster)"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

run_authorization_policy_tests() {
    log_step "Test Authorization Policies"

    apply_authorization_policies

    log_info "Waiting 10 seconds for policies to propagate..."
    sleep 10

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local ECS_HOSTNAME="echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080"

    # Disable strict error handling for policy tests
    set +e
    set +o pipefail

    echo ""
    test_eks_policy_allowed "$EKS_SHELL_POD" "$ECS_HOSTNAME"

    echo ""
    test_connection_blocked "$ECS_HOSTNAME" "Policy: ECS denied"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

# ================================================
# Setup Orchestration
# ================================================

# Wrapper functions for run_step (must return 0 on success)
do_sso_login() { aws_sso_login "$INT"; }
do_eks_cluster() { create_eks_cluster; }
do_gateway_api_crds() { deploy_gateway_api_crds; }
do_infrastructure_iam() { setup_infrastructure_and_iam; }
do_istio_install() { install_istio_scenario1; }
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
    verify_service_discovery 2 2 2  # Expected: 2 services, 2 workloads, 2 entries
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
    echo "     SCENARIO 1 END-TO-END TEST"
    echo "     (Single ECS Cluster)"
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
    export PROGRESS_FILE="$REPO_ROOT/.workshop-progress-sc1"

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

    # Always clean up authorization policies set by the test
    log_info "Cleaning up authorization policies..."
    kubectl delete authorizationpolicy deny-all allow-eks-to-echo -n "ecs-${CLUSTER_NAME}-1" 2>/dev/null || true

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
