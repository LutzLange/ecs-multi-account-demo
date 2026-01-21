#!/bin/bash

# ================================================
# test-lib.sh - Shared functions for test scripts
# ================================================
#
# This library provides common functions used by all scenario test scripts.
# Source this file at the beginning of your test script:
#
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/test-lib.sh"
#

# ================================================
# Colors for output
# ================================================
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ================================================
# Test results tracking
# ================================================
declare -a TEST_RESULTS
TESTS_PASSED=0
TESTS_FAILED=0

# ================================================
# Setup Progress/Checkpoint System
# ================================================
# Progress is tracked in a separate file (not the config file)
# This allows resuming from a specific step after failures

# Progress file location (can be overridden)
PROGRESS_FILE="${PROGRESS_FILE:-.workshop-progress}"

# Current step being executed
CURRENT_STEP=""
START_FROM_STEP=""
STOP_AFTER_STEP=""
RESET_PROGRESS=false
LIST_STEPS=false
# Flag to track if we've reached the start step (run all steps after)
STARTED_FROM_FLAG=false

# Check if a step has been completed
step_completed() {
    local step="$1"
    if [ -z "$COMPLETED_STEPS" ]; then
        return 1
    fi
    [[ ",$COMPLETED_STEPS," == *",$step,"* ]]
}

# Load progress from file
load_progress() {
    local progress_file="${PROGRESS_FILE:-.workshop-progress}"
    if [ -f "$progress_file" ]; then
        source "$progress_file"
        log_info "Loaded progress: $COMPLETED_STEPS"
    fi
}

# Mark a step as completed (writes to progress file)
mark_step_complete() {
    local step="$1"
    local progress_file="${PROGRESS_FILE:-.workshop-progress}"

    if step_completed "$step"; then
        return 0  # Already marked
    fi

    if [ -z "$COMPLETED_STEPS" ]; then
        COMPLETED_STEPS="$step"
    else
        COMPLETED_STEPS="${COMPLETED_STEPS},${step}"
    fi

    # Update progress file
    echo "COMPLETED_STEPS=\"${COMPLETED_STEPS}\"" > "$progress_file"
}

# Clear all progress
clear_progress() {
    local progress_file="${PROGRESS_FILE:-.workshop-progress}"
    COMPLETED_STEPS=""
    rm -f "$progress_file"
    log_info "Progress cleared"
}

# Check if we should run a step
should_run_step() {
    local step="$1"

    # If starting from a specific step, skip until we reach it
    if [ -n "$START_FROM_STEP" ]; then
        if [ "$step" = "$START_FROM_STEP" ]; then
            START_FROM_STEP=""  # Found it, run this and all subsequent
            STARTED_FROM_FLAG=true  # Mark that we've reached the start step
            return 0
        fi
        log_info "Skipping step: $step (starting from $START_FROM_STEP)"
        return 1
    fi

    # If we started from a specific step with -s, run all subsequent steps
    # regardless of whether they were completed in a previous run
    if [ "$STARTED_FROM_FLAG" = true ]; then
        return 0
    fi

    # If step already completed (and not reset), skip it
    if step_completed "$step" && [ "$RESET_PROGRESS" != true ]; then
        log_info "Skipping step: $step (already completed)"
        return 1
    fi

    return 0
}

# Check if we should stop after this step
should_stop_after() {
    local step="$1"
    if [ -n "$STOP_AFTER_STEP" ] && [ "$step" = "$STOP_AFTER_STEP" ]; then
        return 0
    fi
    return 1
}

# Run a setup step with progress tracking
run_step() {
    local step_name="$1"
    local step_function="$2"

    CURRENT_STEP="$step_name"

    if ! should_run_step "$step_name"; then
        # Check if we should stop here (even if skipping)
        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2  # Special return code to signal stop
        fi
        return 0
    fi

    # Run the step function
    if $step_function; then
        mark_step_complete "$step_name"

        # Check if we should stop after this step
        if should_stop_after "$step_name"; then
            log_info "Stopping after step: $step_name (as requested)"
            return 2  # Special return code to signal stop
        fi
        return 0
    else
        log_error "Step '$step_name' failed"
        log_error "To retry from this step, run: $0 -c $CONFIG_FILE -s $step_name"
        return 1
    fi
}

# List all steps and their status (basic version)
# Usage: list_steps "${STEPS[@]}"
list_steps() {
    local steps=("$@")

    echo ""
    echo "=============================================="
    echo "         WORKSHOP STEPS STATUS"
    echo "=============================================="
    echo ""
    printf "%-5s %-30s %-12s\n" "NUM" "STEP NAME" "STATUS"
    echo "----------------------------------------------"

    local num=1
    for step in "${steps[@]}"; do
        local status
        if step_completed "$step"; then
            status="${GREEN}completed${NC}"
        else
            status="${YELLOW}pending${NC}"
        fi
        printf "%-5s %-30s " "$num" "$step"
        echo -e "$status"
        ((num++))
    done

    echo "----------------------------------------------"
    echo ""
    echo "To start from a specific step:"
    echo "  $0 -c $CONFIG_FILE -s <step_name>"
    echo ""
    echo "To stop after a specific step:"
    echo "  $0 -c $CONFIG_FILE --stop-after <step_name>"
    echo ""
    echo "To reset progress and start fresh:"
    echo "  $0 -c $CONFIG_FILE --reset"
    echo ""
}

# List workshop steps with descriptions and parts (enhanced version)
# Requires: SETUP_STEPS, STEP_DESCRIPTIONS, STEP_PARTS arrays defined in calling script
# Usage: list_workshop_steps
list_workshop_steps() {
    echo ""
    echo "=============================================="
    echo "         WORKSHOP STEPS STATUS"
    echo "=============================================="
    echo ""

    local current_part=""
    local num=1

    for step in "${SETUP_STEPS[@]}"; do
        local part="${STEP_PARTS[$step]:-}"
        local desc="${STEP_DESCRIPTIONS[$step]:-$step}"
        local status

        # Print part header when it changes
        if [[ -n "$part" && "$part" != "$current_part" ]]; then
            if [[ -n "$current_part" ]]; then
                echo ""
            fi
            echo -e "${BLUE}${part}${NC}"
            echo "----------------------------------------------"
            current_part="$part"
        fi

        # Determine status
        if step_completed "$step"; then
            status="${GREEN}[done]${NC}"
        else
            status="${YELLOW}[pending]${NC}"
        fi

        printf "  Step %2d: %-40s " "$num" "$desc"
        echo -e "$status"
        ((num++))
    done

    # Optional steps (if defined)
    if [[ -n "${OPTIONAL_STEPS:-}" && ${#OPTIONAL_STEPS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${BLUE}Optional${NC}"
        echo "----------------------------------------------"
        for step in "${OPTIONAL_STEPS[@]}"; do
            local desc="${STEP_DESCRIPTIONS[$step]:-$step}"
            local status
            if step_completed "$step"; then
                status="${GREEN}[done]${NC}"
            else
                status="${YELLOW}[pending]${NC}"
            fi
            printf "  Step %2d: %-40s " "$num" "$desc"
            echo -e "$status"
            ((num++))
        done
    fi

    echo ""
    echo "=============================================="
    echo ""
    echo "Usage examples:"
    echo "  $0 -c $CONFIG_FILE -s 5              # Start from step 5"
    echo "  $0 -c $CONFIG_FILE -s eks_cluster    # Start from step by name"
    echo "  $0 -c $CONFIG_FILE --stop-after 10   # Stop after step 10"
    echo "  $0 -c $CONFIG_FILE --reset           # Clear progress, start fresh"
    echo ""
}

# Get step name by number from array
# Usage: get_step_by_number "$num" "${STEPS[@]}"
get_step_by_number() {
    local num="$1"
    shift
    local steps=("$@")

    if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le "${#steps[@]}" ]; then
        echo "${steps[$((num-1))]}"
    else
        echo "$num"  # Return as-is if not a number
    fi
}

# Get step number from step name
# Usage: get_step_number "$step_name" "${STEPS[@]}"
get_step_number() {
    local target="$1"
    shift
    local steps=("$@")

    local num=1
    for step in "${steps[@]}"; do
        if [[ "$step" == "$target" ]]; then
            echo "$num"
            return
        fi
        ((num++))
    done
    echo "?"
}

# ================================================
# Logging Functions
# ================================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "\n${BLUE}==>${NC} ${YELLOW}$1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_test() { echo -e "${BLUE}[TEST]${NC} $1"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

# ================================================
# Test Recording Functions
# ================================================
record_test() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    local status="$4"  # PASS or FAIL

    TEST_RESULTS+=("$name|$expected|$actual|$status")

    if [ "$status" = "PASS" ]; then
        ((TESTS_PASSED++))
        log_pass "$name"
    else
        ((TESTS_FAILED++))
        log_fail "$name"
        log_error "  Expected: $expected"
        log_error "  Actual:   $actual"
    fi
}

print_test_summary() {
    echo ""
    echo "=============================================="
    echo "               TEST SUMMARY"
    echo "=============================================="
    echo ""
    printf "%-45s %-10s\n" "TEST NAME" "STATUS"
    echo "----------------------------------------------"

    for result in "${TEST_RESULTS[@]}"; do
        IFS='|' read -r name expected actual status <<< "$result"
        if [ "$status" = "PASS" ]; then
            printf "%-45s ${GREEN}%-10s${NC}\n" "$name" "$status"
        else
            printf "%-45s ${RED}%-10s${NC}\n" "$name" "$status"
        fi
    done

    echo "----------------------------------------------"
    echo ""
    echo "Total: $((TESTS_PASSED + TESTS_FAILED)) | Passed: $TESTS_PASSED | Failed: $TESTS_FAILED"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        log_info "All tests passed!"
        return 0
    else
        log_error "$TESTS_FAILED test(s) failed"
        return 1
    fi
}

# ================================================
# Argument Parsing
# ================================================
parse_arguments() {
    DELETE_AFTER=false
    TESTS_ONLY=false
    SKIP_SETUP=false
    CONFIG_FILE=""
    START_FROM_STEP=""
    STOP_AFTER_STEP=""
    RESET_PROGRESS=false
    LIST_STEPS=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -d|--delete)
                DELETE_AFTER=true
                shift
                ;;
            -t|--tests-only)
                TESTS_ONLY=true
                shift
                ;;
            --skip-setup)
                SKIP_SETUP=true
                shift
                ;;
            -s|--step)
                START_FROM_STEP="$2"
                shift 2
                ;;
            --stop-after)
                STOP_AFTER_STEP="$2"
                shift 2
                ;;
            -l|--list)
                LIST_STEPS=true
                shift
                ;;
            --reset)
                RESET_PROGRESS=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [-c config-file] [-d|--delete] [-t|--tests-only] [--skip-setup] [-s|--step <step>] [--stop-after <step>] [-l|--list] [--reset]"
                echo ""
                echo "Options:"
                echo "  -c, --config      Config file to use (default: $DEFAULT_CONFIG)"
                echo "  -d, --delete      Delete all resources after tests complete"
                echo "  -t, --tests-only  Skip all setup, run verification tests only"
                echo "  --skip-setup      Skip infrastructure setup (EKS, Istio), run workshop steps"
                echo "  -s, --step        Start from a specific step (name or number)"
                echo "  --stop-after      Stop after completing a specific step"
                echo "  -l, --list        List all steps and their completion status"
                echo "  --reset           Clear progress and start fresh"
                echo "  -h, --help        Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 -c config.sh                    # Run with config file"
                echo "  $0 -s istio_install                # Start from istio_install step"
                echo "  $0 --stop-after eks_cluster        # Run up to and including eks_cluster"
                echo "  $0 -s 3 --stop-after 5             # Run steps 3 through 5"
                echo "  $0 --reset                         # Clear progress, run all steps"
                echo "  $0 -l                              # Show step status"
                echo "  $0 -t                              # Run tests only (skip setup)"
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
# Configuration Functions
# ================================================
validate_config_file() {
    local example_file="${CONFIG_FILE%.sh}.sh.example"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        if [ -f "$example_file" ]; then
            log_error ""
            log_error "Create the config file from the example:"
            log_error "  cp $example_file $CONFIG_FILE"
            log_error "  # Edit $CONFIG_FILE with your settings"
        fi
        exit 1
    fi
}

unset_config_variables() {
    # Unset any existing environment variables to ensure config file values are used
    # Note: GLOO_MESH_LICENSE_KEY is NOT unset - it's expected from ~/.bashrc
    unset SCENARIO LOCAL_ACCOUNT EXTERNAL_ACCOUNT LOCAL_ACCOUNT_PROFILE EXTERNAL_ACCOUNT_PROFILE
    unset INT EXT AWS_REGION CLUSTER_NAME OWNER_NAME
    unset NUMBER_NODES NODE_TYPE HUB ISTIO_TAG
    unset LOCAL_ROLE EXTERNAL_ROLE LOCAL_VPC LOCAL_CIDR
}

validate_required_vars() {
    local required_vars="$1"
    for var in $required_vars; do
        if [ -z "${!var}" ]; then
            log_error "Required variable $var is not set in config file"
            exit 1
        fi
    done
}

# ================================================
# Pre-flight Checks
# ================================================
# Check if basic setup is complete (EKS cluster accessible, Istio installed)
# Returns 0 if setup is complete, 1 if setup is needed
check_setup_complete() {
    local cluster_name="${1:-$CLUSTER_NAME}"
    local aws_profile="${2:-$INT}"
    local aws_region="${3:-$AWS_REGION}"

    # Check EKS cluster is accessible
    if ! aws eks describe-cluster --name "$cluster_name" --region "$aws_region" --profile "$aws_profile" &>/dev/null; then
        log_info "EKS cluster '$cluster_name' not accessible"
        return 1
    fi

    # Update kubeconfig
    aws eks update-kubeconfig --name "$cluster_name" --region "$aws_region" --profile "$aws_profile" &>/dev/null || true

    # Check kubectl can connect
    if ! kubectl get nodes &>/dev/null; then
        log_info "Cannot connect to Kubernetes cluster"
        return 1
    fi

    # Check for Istio (istio-system namespace with istiod)
    local istiod_pods=$(kubectl get pods -n istio-system -l app=istiod --no-headers 2>/dev/null | wc -l)
    if [ "$istiod_pods" -eq 0 ]; then
        log_info "Istio not installed (no istiod pods found)"
        return 1
    fi

    # Check for ztunnel (ambient mode)
    local ztunnel_pods=$(kubectl get pods -n istio-system -l app=ztunnel --no-headers 2>/dev/null | wc -l)
    if [ "$ztunnel_pods" -eq 0 ]; then
        log_info "Istio ambient mode not installed (no ztunnel pods found)"
        return 1
    fi

    return 0
}

# Check if ECS clusters are deployed and services are running
check_ecs_setup_complete() {
    local cluster_name="${1:-$CLUSTER_NAME}"
    local aws_profile="${2:-$INT}"
    local aws_region="${3:-$AWS_REGION}"
    local num_clusters="${4:-1}"

    for i in $(seq 1 $num_clusters); do
        local ecs_cluster="${cluster_name}-${i}"
        local status=$(aws ecs describe-clusters --clusters "$ecs_cluster" \
            --region "$aws_region" --profile "$aws_profile" \
            --query 'clusters[0].status' --output text 2>/dev/null)

        if [ "$status" != "ACTIVE" ]; then
            log_info "ECS cluster '$ecs_cluster' not active (status: $status)"
            return 1
        fi
    done

    return 0
}

# ================================================
# Generic Wait Functions
# ================================================
wait_for_pods() {
    local context="$1"
    local namespace="$2"
    local label="$3"
    local timeout="${4:-120s}"

    log_info "Waiting for pods with label $label in $namespace..."
    if [ -n "$context" ]; then
        kubectl --context "$context" wait --for=condition=Ready pods -n "$namespace" -l "$label" --timeout="$timeout"
    else
        kubectl wait --for=condition=Ready pods -n "$namespace" -l "$label" --timeout="$timeout"
    fi
}

wait_for_deployment() {
    local context="$1"
    local namespace="$2"
    local deployment="$3"
    local timeout="${4:-120s}"

    log_info "Waiting for deployment $deployment in $namespace..."
    if [ -n "$context" ]; then
        kubectl --context "$context" rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
    else
        kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="$timeout"
    fi
}

wait_for_loadbalancer() {
    local context="$1"
    local namespace="$2"
    local service="$3"
    local max_attempts="${4:-60}"

    log_info "Waiting for LoadBalancer IP on $service..."
    for ((i=1; i<=max_attempts; i++)); do
        local ip
        if [ -n "$context" ]; then
            ip=$(kubectl get svc -n "$namespace" "$service" --context "$context" \
                -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        else
            ip=$(kubectl get svc -n "$namespace" "$service" \
                -o jsonpath="{.status.loadBalancer.ingress[0]['hostname','ip']}" 2>/dev/null)
        fi
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
        sleep 5
    done
    return 1
}

# ================================================
# Generic HTTP Test Functions
# ================================================
test_http_endpoint() {
    local url="$1"
    local expected_code="${2:-200}"
    local test_name="${3:-HTTP test}"
    local max_retries="${4:-3}"

    log_test "$test_name"

    local code
    local i
    for ((i=1; i<=max_retries; i++)); do
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" 2>/dev/null)
        if [ "$code" = "$expected_code" ]; then
            record_test "$test_name" "HTTP $expected_code" "HTTP $code" "PASS"
            return 0
        fi
        if [ $i -lt $max_retries ]; then
            sleep 2
        fi
    done

    record_test "$test_name" "HTTP $expected_code" "HTTP $code" "FAIL"
    return 1
}

test_http_contains() {
    local url="$1"
    local pattern="$2"
    local test_name="${3:-HTTP content test}"
    local max_retries="${4:-3}"

    log_test "$test_name"

    local response
    local i
    for ((i=1; i<=max_retries; i++)); do
        response=$(curl -s --max-time 10 "$url" 2>/dev/null)
        if echo "$response" | grep -q "$pattern"; then
            record_test "$test_name" "Contains: $pattern" "Found pattern" "PASS"
            return 0
        fi
        if [ $i -lt $max_retries ]; then
            sleep 2
        fi
    done

    record_test "$test_name" "Contains: $pattern" "Pattern not found" "FAIL"
    return 1
}

# ================================================
# Generic Kubernetes Test Functions
# ================================================
test_pods_running() {
    local context="$1"
    local namespace="$2"
    local label="$3"
    local expected_count="${4:-1}"
    local test_name="${5:-Pods running}"

    log_test "$test_name"

    local count
    if [ -n "$context" ]; then
        count=$(kubectl --context "$context" get pods -n "$namespace" -l "$label" \
            --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    else
        count=$(kubectl get pods -n "$namespace" -l "$label" \
            --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    fi
    # Ensure count is a single integer (remove any whitespace/newlines)
    count=$(echo "$count" | tr -d '[:space:]')
    count=${count:-0}

    if [ "$count" -ge "$expected_count" ]; then
        record_test "$test_name" ">=$expected_count running" "$count running" "PASS"
        return 0
    else
        record_test "$test_name" ">=$expected_count running" "$count running" "FAIL"
        return 1
    fi
}

test_service_exists() {
    local context="$1"
    local namespace="$2"
    local service="$3"
    local test_name="${4:-Service exists}"

    log_test "$test_name"

    local exists
    if [ -n "$context" ]; then
        exists=$(kubectl --context "$context" get svc -n "$namespace" "$service" 2>/dev/null)
    else
        exists=$(kubectl get svc -n "$namespace" "$service" 2>/dev/null)
    fi

    if [ -n "$exists" ]; then
        record_test "$test_name" "Service exists" "Found" "PASS"
        return 0
    else
        record_test "$test_name" "Service exists" "Not found" "FAIL"
        return 1
    fi
}

# ================================================
# AWS Functions
# ================================================
aws_sso_login() {
    local profile="$1"
    log_step "AWS SSO Login"

    # Check if already logged in by trying a simple AWS call
    if aws sts get-caller-identity --profile "$profile" &>/dev/null; then
        log_info "Already logged in to AWS SSO with profile: $profile"
    else
        log_info "Logging in to AWS SSO with profile: $profile"
        aws sso login --profile "$profile"

        if [ $? -ne 0 ]; then
            log_error "Failed to login to AWS SSO"
            exit 1
        fi
        log_info "AWS SSO login successful"
    fi
    echo ""
}

# ================================================
# EKS Functions
# ================================================
create_eks_cluster() {
    log_step "Create EKS Cluster"

    export AWS_PROFILE=$INT

    # Check cluster status - may be ACTIVE, CREATING, DELETING, or not exist
    local cluster_status
    cluster_status=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
        --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

    # If cluster is being deleted, wait for deletion to complete
    if [ "$cluster_status" = "DELETING" ]; then
        log_info "EKS cluster '$CLUSTER_NAME' is being deleted, waiting for completion..."
        while aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; do
            sleep 30
            log_info "  Still waiting for cluster deletion..."
        done
        log_info "Cluster deletion complete"
        cluster_status="NOT_FOUND"
    fi

    # If cluster is being created, wait for it
    if [ "$cluster_status" = "CREATING" ]; then
        log_info "EKS cluster '$CLUSTER_NAME' is being created, waiting..."
        aws eks wait cluster-active --name "$CLUSTER_NAME" --region "$AWS_REGION"
        cluster_status="ACTIVE"
    fi

    # Create cluster if it doesn't exist
    if [ "$cluster_status" = "ACTIVE" ]; then
        log_info "EKS cluster '$CLUSTER_NAME' already exists, skipping creation"
    else
        log_info "Creating EKS cluster '$CLUSTER_NAME'..."
        eval "echo \"$(cat manifests/eks-cluster.yaml)\"" | eksctl create cluster --config-file -

        if [ $? -ne 0 ]; then
            log_error "Failed to create EKS cluster"
            exit 1
        fi
    fi

    # Update kubeconfig to ensure we can access the cluster
    log_info "Updating kubeconfig for cluster '$CLUSTER_NAME'..."
    if ! aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$INT" 2>/dev/null; then
        log_error "Failed to update kubeconfig"
        exit 1
    fi

    # Verify cluster is accessible
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot access EKS cluster with kubectl"
        exit 1
    fi

    # Verify nodes are ready
    local ready_nodes
    ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " 2>/dev/null || echo "0")
    ready_nodes=$(echo "$ready_nodes" | tr -d '[:space:]')  # Clean whitespace/newlines

    if [ "$ready_nodes" -eq 0 ]; then
        log_error "EKS cluster '$CLUSTER_NAME' exists but has no ready nodes"
        log_error ""
        log_error "The cluster may have been scaled down. To fix this, either:"
        log_error "  1. Scale up the nodegroup:"
        log_error "     eksctl scale nodegroup --cluster $CLUSTER_NAME --name managed-nodes --nodes 2 --nodes-min 2 --profile $INT --region $AWS_REGION"
        log_error ""
        log_error "  2. Delete and recreate the cluster:"
        log_error "     eksctl delete cluster -n $CLUSTER_NAME --profile $INT --region $AWS_REGION"
        log_error "     Then re-run this test script"
        exit 1
    fi

    log_info "EKS cluster is ready with $ready_nodes node(s)"
    echo ""
}

deploy_gateway_api_crds() {
    log_step "Deploy Gateway API CRDs"

    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

    if [ $? -ne 0 ]; then
        log_error "Failed to deploy Gateway API CRDs"
        exit 1
    fi

    log_info "Gateway API CRDs deployed"
    echo ""
}

# ================================================
# Infrastructure Functions
# ================================================
setup_infrastructure_and_iam() {
    log_step "Setup Infrastructure and IAM Roles"

    ./scripts/setup-infrastructure.sh -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Failed to setup infrastructure"
        exit 1
    fi

    log_info "Infrastructure setup complete"

    ./scripts/create-iam-roles.sh -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Failed to create IAM roles"
        exit 1
    fi

    log_info "IAM roles created"
    echo ""
}

# ================================================
# Istio Functions
# ================================================

check_istioctl() {
    # Path to istioctl - use Solo.io distribution from ~/.istioctl/bin
    # Set here (not at file load time) so config file can override
    ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"

    if [ ! -f "$ISTIOCTL" ]; then
        log_error "istioctl not found at: $ISTIOCTL"
        log_error ""
        log_error "This demo requires the Solo.io distribution of istioctl with ECS support."
        log_error "The Solo.io istioctl is available through Solo.io evaluations or licenses."
        log_error "Contact Solo.io for access: https://www.solo.io/company/contact/"
        log_error ""
        log_error "Once obtained, place istioctl at: ~/.istioctl/bin/istioctl"
        log_error "Or set ISTIOCTL environment variable to point to your istioctl binary."
        exit 1
    fi

    # Check that istioctl is the Solo.io version (has ECS support)
    # Extract version from "client version: X.Y.Z-solo" format
    local client_version
    client_version=$("$ISTIOCTL" version --short 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ ! "$client_version" =~ -solo ]]; then
        log_error "istioctl is not the Solo.io distribution"
        log_error "  Found version: $client_version"
        log_error ""
        log_error "ECS support requires Solo.io istioctl (version should contain '-solo')."
        log_error "The upstream Istio istioctl does not include ECS commands."
        log_error "Contact Solo.io for access to the Solo.io distribution."
        exit 1
    fi

    # Verify istioctl version matches ISTIO_TAG if set
    if [ -n "$ISTIO_TAG" ]; then
        # Strip -solo suffix from both for comparison (base version must match)
        local expected_version
        expected_version=$(echo "$ISTIO_TAG" | sed 's/-solo$//')
        local actual_version
        actual_version=$(echo "$client_version" | sed 's/-solo$//')

        if [ "$actual_version" != "$expected_version" ]; then
            log_error "istioctl version mismatch!"
            log_error "  Expected: $expected_version (from ISTIO_TAG)"
            log_error "  Actual:   $actual_version"
            log_error ""
            log_error "Please use matching istioctl version for compatibility."
            exit 1
        fi
        log_info "istioctl version verified: $client_version"
    fi
}

deploy_eastwest_gateway() {
    log_step "Deploy East-West Gateway"

    # Ensure istioctl is available
    check_istioctl

    # Check if gateway is already deployed with an external address
    local existing_address=$(kubectl get svc -n istio-eastwest istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
    if [ -z "$existing_address" ]; then
        existing_address=$(kubectl get svc -n istio-eastwest istio-eastwest -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    fi
    if [ -n "$existing_address" ] && [ "$existing_address" != "" ]; then
        log_info "East-West Gateway already deployed with address: $existing_address"
        log_info "East-West Gateway deployed"
        echo ""
        return 0
    fi

    # Create the istio-eastwest namespace if it doesn't exist
    kubectl create namespace istio-eastwest 2>/dev/null || true

    # Use istioctl multicluster expose to create the east-west gateway
    # This properly exposes istiod for ECS bootstrap
    log_info "Creating east-west gateway with istioctl multicluster expose..."
    "$ISTIOCTL" multicluster expose --namespace istio-eastwest --wait

    if [ $? -ne 0 ]; then
        log_error "Failed to deploy East-West Gateway"
        exit 1
    fi

    # Wait for gateway to get an external address
    log_info "Waiting for East-West Gateway to get an external address..."
    local max_wait=180
    local wait_time=0
    while [ $wait_time -lt $max_wait ]; do
        local address=$(kubectl get svc -n istio-eastwest -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
        if [ -z "$address" ]; then
            address=$(kubectl get svc -n istio-eastwest -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}' 2>/dev/null)
        fi
        if [ -n "$address" ] && [ "$address" != "" ]; then
            log_info "East-West Gateway address: $address"
            break
        fi
        sleep 10
        wait_time=$((wait_time + 10))
        log_info "  Waiting for gateway address... (${wait_time}s)"
    done

    if [ $wait_time -ge $max_wait ]; then
        log_error "East-West Gateway did not get an address within ${max_wait}s"
        log_error "Check gateway status: kubectl get svc -n istio-eastwest"
        log_error "Common issue: AWS CLB quota exceeded - check with: aws elb describe-load-balancers"
        exit 1
    fi

    log_info "East-West Gateway deployed"
    echo ""
}

label_network() {
    log_step "Label Network"

    kubectl label namespace istio-system topology.istio.io/network=eks --overwrite

    log_info "Network labeled"
    echo ""
}

verify_istio_installation() {
    log_step "Verify Istio Installation"

    log_info "Waiting for Istio pods to be ready..."
    kubectl wait --for=condition=Ready pods -n istio-system -l app=istiod --timeout=120s
    kubectl wait --for=condition=Ready pods -n istio-system -l app=ztunnel --timeout=120s

    ISTIO_PODS=$(kubectl get pods -n istio-system --no-headers | wc -l)
    if [ "$ISTIO_PODS" -lt 2 ]; then
        log_error "Expected at least 2 Istio pods, found $ISTIO_PODS"
        exit 1
    fi

    log_info "Istio is running with $ISTIO_PODS pods"
    echo ""
}

# ================================================
# ECS Functions
# ================================================
deploy_ecs_clusters() {
    log_step "Deploy ECS Cluster(s) and Services"

    ./scripts/deploy-ecs-clusters.sh -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Failed to deploy ECS clusters"
        exit 1
    fi

    log_info "ECS cluster(s) deployed"

    # Wait for all ECS services to be stable before proceeding
    wait_for_ecs_services_stable

    echo ""
}

# Intelligent wait for a single ECS service to become stable
# Args: cluster service profile max_wait_seconds
wait_for_ecs_service() {
    local cluster="$1"
    local service="$2"
    local profile="$3"
    local max_wait="${4:-300}"  # Default 5 minutes
    local poll_interval=10
    local elapsed=0

    while [ $elapsed -lt $max_wait ]; do
        # Get service status
        local status=$(aws ecs describe-services \
            --cluster "$cluster" \
            --services "$service" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --query 'services[0].{running:runningCount,desired:desiredCount,pending:pendingCount}' \
            --output json 2>/dev/null)

        if [ -z "$status" ] || [ "$status" == "null" ]; then
            log_warn "    Service $service not found in $cluster"
            return 1
        fi

        local running=$(echo "$status" | jq -r '.running // 0')
        local desired=$(echo "$status" | jq -r '.desired // 1')
        local pending=$(echo "$status" | jq -r '.pending // 0')

        # Check if stable (running == desired and no pending)
        if [ "$running" -ge "$desired" ] && [ "$pending" -eq 0 ] && [ "$running" -gt 0 ]; then
            log_info "    ✓ $service: $running/$desired running"
            return 0
        fi

        # Show progress
        if [ $((elapsed % 30)) -eq 0 ]; then
            log_info "    $service: $running/$desired running, $pending pending (${elapsed}s elapsed)"
        fi

        sleep $poll_interval
        elapsed=$((elapsed + poll_interval))
    done

    # Timeout - check final state
    local final_running=$(aws ecs describe-services \
        --cluster "$cluster" \
        --services "$service" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'services[0].runningCount' \
        --output text 2>/dev/null)

    if [ "$final_running" -gt 0 ]; then
        log_warn "    $service: $final_running running after timeout (continuing)"
        return 0
    else
        log_warn "    Timeout waiting for $service in $cluster (0 running after ${max_wait}s)"
        return 1
    fi
}

wait_for_ecs_services_stable() {
    log_info "Waiting for ECS services to stabilize (tasks must be running)..."

    local profile="${LOCAL_ACCOUNT_PROFILE:-$INT}"
    local services=("shell-task" "echo-service")
    local max_wait="${1:-300}"  # Default 5 minutes per service

    # Determine which clusters based on scenario
    local clusters=()
    case "$SCENARIO" in
        1) clusters=("ecs-${CLUSTER_NAME}-1") ;;
        2) clusters=("ecs-${CLUSTER_NAME}-1" "ecs-${CLUSTER_NAME}-2") ;;
        3) clusters=("ecs-${CLUSTER_NAME}-1" "ecs-${CLUSTER_NAME}-2" "ecs-${CLUSTER_NAME}-3") ;;
    esac

    local all_stable=true

    for cluster in "${clusters[@]}"; do
        local use_profile="$profile"
        # Use external profile for cluster 3 in scenario 3
        if [[ "$cluster" == *"-3" ]] && [ -n "$EXTERNAL_ACCOUNT_PROFILE" ]; then
            use_profile="$EXTERNAL_ACCOUNT_PROFILE"
        fi

        log_info "  Checking cluster: $cluster"
        for service in "${services[@]}"; do
            if ! wait_for_ecs_service "$cluster" "$service" "$use_profile" "$max_wait"; then
                all_stable=false
            fi
        done
    done

    if $all_stable; then
        log_info "All ECS services are stable"
    else
        log_warn "Some ECS services did not stabilize (tests will attempt to run anyway)"
    fi
}

create_k8s_namespaces() {
    log_step "Create Kubernetes Namespace(s)"

    ./scripts/create-k8s-namespaces.sh -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Failed to create K8s namespaces"
        exit 1
    fi

    log_info "Kubernetes namespace(s) created"
    echo ""
}

add_services_to_mesh() {
    log_step "Add Services to Mesh"

    ./scripts/add-services-to-mesh.sh -c "$CONFIG_FILE"

    if [ $? -ne 0 ]; then
        log_error "Failed to add services to mesh"
        exit 1
    fi

    log_info "Services added to mesh"

    # CRITICAL: Wait for ECS services to stabilize AFTER add-to-mesh
    # The add-to-mesh script updates task definitions with ztunnel containers.
    # Services need time to deploy new tasks with the updated definitions.
    log_info "Waiting for ECS services to deploy new tasks with updated definitions..."
    wait_for_ecs_services_stable 300

    echo ""
}

# ================================================
# Test Pod Functions
# ================================================
deploy_test_pods() {
    log_info "Deploying test pods..."

    # Label namespace and deploy test pods
    kubectl label namespace default istio.io/dataplane-mode=ambient --overwrite
    kubectl apply -f manifests/eks-echo.yaml
    kubectl apply -f manifests/eks-shell.yaml

    log_info "Waiting for test pods to be ready..."
    kubectl wait --for=condition=Ready pods -l app=eks-shell --timeout=120s
    kubectl wait --for=condition=Ready pods -l app=eks-echo --timeout=120s
}

get_eks_shell_pod() {
    kubectl get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}"
}

# ================================================
# Service Discovery Verification
# ================================================
verify_service_discovery() {
    local expected_services="${1:-2}"
    local expected_workloads="${2:-2}"
    local expected_entries="${3:-2}"
    local max_retries=6
    local retry_interval=10

    log_info "Verifying service discovery..."

    # Temporarily disable strict error handling for checks that may return empty results
    set +e
    set +o pipefail

    # Check services discovered (with retry)
    local DISCOVERED_SERVICES=0
    local retry=0
    while [ "$retry" -lt "$max_retries" ]; do
        local ZTUNNEL_SERVICES
        ZTUNNEL_SERVICES=$("$ISTIOCTL" ztunnel-config services 2>/dev/null)
        DISCOVERED_SERVICES=$(echo "$ZTUNNEL_SERVICES" | grep -c "$CLUSTER_NAME" 2>/dev/null)
        DISCOVERED_SERVICES=$((DISCOVERED_SERVICES + 0))  # Ensure it's a number

        if [ "$DISCOVERED_SERVICES" -ge "$expected_services" ]; then
            break
        fi

        retry=$((retry + 1))
        if [ "$retry" -lt "$max_retries" ]; then
            log_info "  Waiting for service discovery ($DISCOVERED_SERVICES/$expected_services)... retry $retry/$max_retries"
            sleep $retry_interval
        fi
    done

    if [ "$DISCOVERED_SERVICES" -ge "$expected_services" ]; then
        record_test "Service Discovery" ">=$expected_services services" "$DISCOVERED_SERVICES services" "PASS"
    else
        record_test "Service Discovery" ">=$expected_services services" "$DISCOVERED_SERVICES services" "FAIL"
    fi

    # Check workloads using HBONE (with retry)
    local HBONE_WORKLOADS=0
    retry=0
    while [ "$retry" -lt "$max_retries" ]; do
        local ZTUNNEL_WORKLOADS
        ZTUNNEL_WORKLOADS=$("$ISTIOCTL" ztunnel-config workloads 2>/dev/null)
        HBONE_WORKLOADS=$(echo "$ZTUNNEL_WORKLOADS" | grep "$CLUSTER_NAME" | grep -c "HBONE" 2>/dev/null)
        HBONE_WORKLOADS=$((HBONE_WORKLOADS + 0))  # Ensure it's a number

        if [ "$HBONE_WORKLOADS" -ge "$expected_workloads" ]; then
            break
        fi

        retry=$((retry + 1))
        if [ "$retry" -lt "$max_retries" ]; then
            log_info "  Waiting for HBONE enrollment ($HBONE_WORKLOADS/$expected_workloads)... retry $retry/$max_retries"
            sleep $retry_interval
        fi
    done

    if [ "$HBONE_WORKLOADS" -ge "$expected_workloads" ]; then
        record_test "HBONE Enrollment" ">=$expected_workloads workloads" "$HBONE_WORKLOADS workloads" "PASS"
    else
        record_test "HBONE Enrollment" ">=$expected_workloads workloads" "$HBONE_WORKLOADS workloads" "FAIL"
    fi

    # Check ServiceEntry objects (with retry)
    local SERVICE_ENTRIES=0
    retry=0
    while [ "$retry" -lt "$max_retries" ]; do
        SERVICE_ENTRIES=$(kubectl get serviceentry -A --no-headers 2>/dev/null | wc -l)
        SERVICE_ENTRIES=$((SERVICE_ENTRIES + 0))  # Ensure it's a number

        if [ "$SERVICE_ENTRIES" -ge "$expected_entries" ]; then
            break
        fi

        retry=$((retry + 1))
        if [ "$retry" -lt "$max_retries" ]; then
            log_info "  Waiting for ServiceEntries ($SERVICE_ENTRIES/$expected_entries)... retry $retry/$max_retries"
            sleep $retry_interval
        fi
    done

    if [ "$SERVICE_ENTRIES" -ge "$expected_entries" ]; then
        record_test "ServiceEntry Creation" ">=$expected_entries entries" "$SERVICE_ENTRIES entries" "PASS"
    else
        record_test "ServiceEntry Creation" ">=$expected_entries entries" "$SERVICE_ENTRIES entries" "FAIL"
    fi

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

# ================================================
# Connectivity Test Functions
# ================================================
test_eks_to_eks_connectivity() {
    local eks_shell_pod="$1"
    local test_name="${2:-EKS-to-EKS}"

    log_test "$test_name connectivity"
    local EKS_TO_EKS
    EKS_TO_EKS=$(kubectl exec "$eks_shell_pod" -- curl -s eks-echo:8080 2>&1)
    # eks-echo returns plain text with Hostname= or JSON with hostname
    if echo "$EKS_TO_EKS" | grep -qi "hostname"; then
        record_test "$test_name" "Response with hostname" "Got response" "PASS"
    else
        record_test "$test_name" "Response with hostname" "${EKS_TO_EKS:-CURL_FAILED}" "FAIL"
    fi
}

test_eks_to_ecs_connectivity() {
    local eks_shell_pod="$1"
    local ecs_hostname="$2"
    local test_name="${3:-EKS-to-ECS}"

    log_test "$test_name connectivity"
    # Retry up to 3 times with 5 second delay (DNS/mesh propagation may need time)
    local EKS_TO_ECS=""
    local i
    for i in 1 2 3; do
        EKS_TO_ECS=$(kubectl exec "$eks_shell_pod" -- curl -s --max-time 10 "$ecs_hostname" 2>&1)
        if echo "$EKS_TO_ECS" | grep -q "hostname"; then
            break
        fi
        if [ $i -lt 3 ]; then
            log_info "Attempt $i failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    if echo "$EKS_TO_ECS" | grep -q "hostname"; then
        local ECS_HOST
        ECS_HOST=$(echo "$EKS_TO_ECS" | jq -r '.host.hostname' 2>/dev/null)
        record_test "$test_name" "JSON with hostname" "Got hostname: ${ECS_HOST:-unknown}" "PASS"
    else
        record_test "$test_name" "JSON with hostname" "${EKS_TO_ECS:-CURL_FAILED}" "FAIL"
    fi
}

test_ecs_to_ecs_connectivity() {
    local ecs_hostname="$1"
    local test_name="${2:-ECS-to-ECS}"
    local origin_cluster="${3:-}"

    log_test "$test_name connectivity"
    local ECS_TO_ECS
    if [ -n "$origin_cluster" ]; then
        ECS_TO_ECS=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$ecs_hostname" 2>&1)
    else
        ECS_TO_ECS=$(./scripts/test/call-from-ecs.sh "$ecs_hostname" 2>&1)
    fi
    if echo "$ECS_TO_ECS" | grep -q "hostname"; then
        record_test "$test_name" "JSON with hostname" "Got response" "PASS"
    else
        record_test "$test_name" "JSON with hostname" "${ECS_TO_ECS:-CURL_FAILED}" "FAIL"
    fi
}

# Test that a connection is blocked (expects failure)
test_connection_blocked() {
    local ecs_hostname="$1"
    local test_name="${2:-Connection blocked}"
    local origin_cluster="${3:-}"

    log_test "$test_name (should be blocked)"
    local RESULT
    if [ -n "$origin_cluster" ]; then
        RESULT=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$ecs_hostname" 2>&1)
    else
        RESULT=$(./scripts/test/call-from-ecs.sh "$ecs_hostname" 2>&1)
    fi
    if echo "$RESULT" | grep -qi "reset\|refused\|denied\|failed"; then
        record_test "$test_name" "Connection blocked" "Blocked as expected" "PASS"
    elif echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "Connection blocked" "Unexpectedly succeeded" "FAIL"
    else
        record_test "$test_name" "Connection blocked" "Unknown: $RESULT" "FAIL"
    fi
}

# Test that EKS can reach ECS (for policy tests)
test_eks_policy_allowed() {
    local eks_shell_pod="$1"
    local ecs_hostname="$2"
    local test_name="${3:-Policy: EKS allowed}"

    log_test "$test_name (should succeed)"
    local RESULT
    RESULT=$(kubectl exec "$eks_shell_pod" -- curl -s "$ecs_hostname" 2>&1)
    if echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "Success" "Got response" "PASS"
    else
        record_test "$test_name" "Success" "${RESULT:-CURL_FAILED}" "FAIL"
    fi
}

# Test that EKS connection to ECS is blocked (for deny-all tests)
# Works with authorization policies that block traffic
test_connection_blocked_eks() {
    local eks_shell_pod="$1"
    local ecs_hostname="$2"
    local test_name="${3:-Connection blocked}"

    log_test "$test_name (should be blocked)"
    local RESULT
    local EXIT_CODE
    RESULT=$(kubectl exec "$eks_shell_pod" -- curl -s --max-time 5 "$ecs_hostname" 2>&1)
    EXIT_CODE=$?

    # Check if response contains successful data (hostname = success)
    if echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "Connection blocked" "Unexpectedly succeeded" "FAIL"
    # Check for explicit block indicators in output
    elif echo "$RESULT" | grep -qi "reset\|refused\|denied\|failed\|timed out"; then
        record_test "$test_name" "Connection blocked" "Blocked as expected" "PASS"
    # Check for curl exit codes indicating connection failure (52=empty reply, 56=recv failure, 7=refused, 28=timeout)
    elif echo "$RESULT" | grep -qi "exit code 56\|exit code 52\|exit code 7\|exit code 28"; then
        record_test "$test_name" "Connection blocked" "Blocked (curl error)" "PASS"
    # Non-zero exit code without hostname = blocked
    elif [ $EXIT_CODE -ne 0 ]; then
        record_test "$test_name" "Connection blocked" "Blocked (exit code $EXIT_CODE)" "PASS"
    # Empty response = blocked
    elif [ -z "$RESULT" ]; then
        record_test "$test_name" "Connection blocked" "Blocked (no response)" "PASS"
    else
        record_test "$test_name" "Connection blocked" "Unknown: $RESULT" "FAIL"
    fi
}

# ================================================
# Authorization Policy Functions
# ================================================

# Clear all authorization policies from ECS cluster namespaces
# Determines namespaces based on SCENARIO and CLUSTER_NAME
# Usage: clear_authorization_policies_all [kubectl_context_args]
# Example: clear_authorization_policies_all
# Example: clear_authorization_policies_all "--context=$CTX_EKS"
clear_authorization_policies_all() {
    local context_args="${1:-}"

    log_info "Clearing all authorization policies from ECS namespaces..."

    # Build list of namespaces based on scenario
    local namespaces=()
    case "${SCENARIO:-1}" in
        1)
            namespaces=("ecs-${CLUSTER_NAME}-1")
            ;;
        2)
            namespaces=("ecs-${CLUSTER_NAME}-1" "ecs-${CLUSTER_NAME}-2")
            ;;
        3)
            namespaces=("ecs-${CLUSTER_NAME}-1" "ecs-${CLUSTER_NAME}-2" "ecs-${CLUSTER_NAME}-3")
            ;;
        4)
            namespaces=("ecs-${CLUSTER_NAME}-1" "ecs-${CLUSTER_NAME}-2")
            ;;
        *)
            namespaces=("ecs-${CLUSTER_NAME}-1")
            ;;
    esac

    # Clear policies from each namespace
    for ns in "${namespaces[@]}"; do
        if [ -n "$context_args" ]; then
            kubectl $context_args delete authorizationpolicy --all -n "$ns" 2>&1 | grep -v "No resources found" || true
        else
            kubectl delete authorizationpolicy --all -n "$ns" 2>&1 | grep -v "No resources found" || true
        fi
    done

    sleep 5  # Brief wait for policy removal to propagate
}

# ================================================
# Cleanup Functions
# ================================================
cleanup_test_pods() {
    log_info "Removing test pods..."
    kubectl delete -f manifests/eks-echo.yaml 2>/dev/null || true
    kubectl delete -f manifests/eks-shell.yaml 2>/dev/null || true
}

cleanup_eks_cluster() {
    local cluster_name="$1"
    local profile="$2"
    local region="${AWS_REGION:-eu-central-1}"

    log_step "Cleanup EKS Cluster"

    # Get VPC ID from EKS cluster or CloudFormation stack
    local eks_vpc=""
    eks_vpc=$(aws eks describe-cluster \
        --name "$cluster_name" \
        --profile "$profile" \
        --region "$region" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text 2>/dev/null)

    if [ -z "$eks_vpc" ] || [ "$eks_vpc" = "None" ]; then
        # Try to get from CloudFormation stack
        eks_vpc=$(aws cloudformation describe-stack-resource \
            --stack-name "eksctl-${cluster_name}-cluster" \
            --logical-resource-id VPC \
            --profile "$profile" \
            --region "$region" \
            --query 'StackResourceDetail.PhysicalResourceId' \
            --output text 2>/dev/null)
    fi

    if [ -n "$eks_vpc" ] && [ "$eks_vpc" != "None" ]; then
        log_info "Found VPC: $eks_vpc"

        # Step 1: Delete Classic Load Balancers in this VPC
        log_info "Checking for Classic Load Balancers..."
        local clbs=$(aws elb describe-load-balancers \
            --profile "$profile" \
            --region "$region" \
            --query "LoadBalancerDescriptions[?VPCId=='$eks_vpc'].LoadBalancerName" \
            --output text 2>/dev/null)

        if [ -n "$clbs" ] && [ "$clbs" != "None" ]; then
            for clb in $clbs; do
                log_info "  Deleting CLB: $clb"
                aws elb delete-load-balancer \
                    --load-balancer-name "$clb" \
                    --profile "$profile" \
                    --region "$region" 2>/dev/null || true
            done
        fi

        # Step 2: Delete ALB/NLB in this VPC
        log_info "Checking for ALB/NLB..."
        local v2_lbs=$(aws elbv2 describe-load-balancers \
            --profile "$profile" \
            --region "$region" \
            --query "LoadBalancers[?VpcId=='$eks_vpc'].LoadBalancerArn" \
            --output text 2>/dev/null)

        if [ -n "$v2_lbs" ] && [ "$v2_lbs" != "None" ]; then
            for lb_arn in $v2_lbs; do
                log_info "  Deleting LB: $(basename $lb_arn)"
                aws elbv2 delete-load-balancer \
                    --load-balancer-arn "$lb_arn" \
                    --profile "$profile" \
                    --region "$region" 2>/dev/null || true
            done
        fi

        # Wait for LBs to be deleted (they release ENIs and SGs)
        if [ -n "$clbs$v2_lbs" ] && [ "$clbs$v2_lbs" != "NoneNone" ] && [ "$clbs$v2_lbs" != "None" ]; then
            log_info "Waiting 60s for load balancers to fully delete..."
            sleep 60
        fi

        # Step 3: Remove all rules from non-default security groups
        log_info "Removing security group rules..."
        local security_groups=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$eks_vpc" \
            --profile "$profile" \
            --region "$region" \
            --query "SecurityGroups[?GroupName!='default'].GroupId" \
            --output text 2>/dev/null)

        for sg in $security_groups; do
            if [ -n "$sg" ] && [ "$sg" != "None" ]; then
                # Remove all ingress rules
                local ingress_rules=$(aws ec2 describe-security-groups \
                    --group-ids "$sg" \
                    --profile "$profile" \
                    --region "$region" \
                    --query 'SecurityGroups[0].IpPermissions' \
                    --output json 2>/dev/null)

                if [ -n "$ingress_rules" ] && [ "$ingress_rules" != "[]" ] && [ "$ingress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-ingress \
                        --group-id "$sg" \
                        --ip-permissions "$ingress_rules" \
                        --profile "$profile" \
                        --region "$region" 2>/dev/null || true
                fi

                # Remove all egress rules
                local egress_rules=$(aws ec2 describe-security-groups \
                    --group-ids "$sg" \
                    --profile "$profile" \
                    --region "$region" \
                    --query 'SecurityGroups[0].IpPermissionsEgress' \
                    --output json 2>/dev/null)

                if [ -n "$egress_rules" ] && [ "$egress_rules" != "[]" ] && [ "$egress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-egress \
                        --group-id "$sg" \
                        --ip-permissions "$egress_rules" \
                        --profile "$profile" \
                        --region "$region" 2>/dev/null || true
                fi
            fi
        done

        # Step 4: Delete security groups (now that rules are removed)
        log_info "Deleting security groups..."
        for sg in $security_groups; do
            if [ -n "$sg" ] && [ "$sg" != "None" ]; then
                log_info "  Deleting SG: $sg"
                aws ec2 delete-security-group \
                    --group-id "$sg" \
                    --profile "$profile" \
                    --region "$region" 2>/dev/null || true
            fi
        done
    fi

    # Step 5: Delete EKS cluster via eksctl
    log_info "Deleting EKS cluster: $cluster_name"
    if ! eksctl delete cluster -n "$cluster_name" --profile "$profile" --region "$region" 2>&1; then
        log_warn "eksctl delete failed, trying CloudFormation cleanup..."

        # Delete nodegroup stack first
        local nodegroup_stack="eksctl-${cluster_name}-nodegroup-managed-nodes"
        aws cloudformation delete-stack \
            --stack-name "$nodegroup_stack" \
            --profile "$profile" \
            --region "$region" 2>/dev/null || true

        log_info "Waiting for nodegroup stack deletion..."
        aws cloudformation wait stack-delete-complete \
            --stack-name "$nodegroup_stack" \
            --profile "$profile" \
            --region "$region" 2>/dev/null || true

        # Delete cluster stack
        local cluster_stack="eksctl-${cluster_name}-cluster"
        aws cloudformation delete-stack \
            --stack-name "$cluster_stack" \
            --profile "$profile" \
            --region "$region" 2>/dev/null || true

        log_info "Waiting for cluster stack deletion..."
        aws cloudformation wait stack-delete-complete \
            --stack-name "$cluster_stack" \
            --profile "$profile" \
            --region "$region" 2>/dev/null || true
    fi

    log_info "EKS cluster cleanup complete"
    echo ""
}
