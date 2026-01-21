#!/bin/bash

# ================================================
# test-scenario-4.sh - End-to-end test for Scenario 4
# ================================================
#
# This script executes all setup steps for Scenario 4 (multicloud EKS + AKS)
# and runs connectivity tests, recording results vs expected outcomes.
#
# Usage:
#   ./scripts/test/test-scenario-4.sh                      # Uses default config
#   ./scripts/test/test-scenario-4.sh -c myconfig.sh       # Uses custom config
#   ./scripts/test/test-scenario-4.sh -d                   # Run tests, then cleanup
#   ./scripts/test/test-scenario-4.sh -t                   # Run tests only (skip setup)
#   ./scripts/test/test-scenario-4.sh -s <step>            # Resume from specific step
#   ./scripts/test/test-scenario-4.sh -l                   # List all steps and progress
#   ./scripts/test/test-scenario-4.sh --reset              # Clear progress and start fresh
#   ./scripts/test/test-scenario-4.sh -c myconfig.sh -d    # Custom config + cleanup
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

source "$SCRIPT_DIR/test-lib.sh"

# Override setup steps for Scenario 4 (multicloud)
SETUP_STEPS=(
    "cloud_login"
    "eks_cluster"
    "aks_cluster"
    "gateway_api_crds"
    "infrastructure_iam"
    "create_certs"
    "install_ca_secrets"
    "istio_eks"
    "istio_aks"
    "connect_clusters"
    "ecs_clusters"
    "k8s_namespaces"
    "add_to_mesh"
    "deploy_aks_workloads"
    "prepare_tests"
)

# Human-readable step descriptions (matches Readme-scenario-4.md)
declare -A STEP_DESCRIPTIONS=(
    ["cloud_login"]="Login to AWS & Azure"
    ["eks_cluster"]="Create EKS Cluster"
    ["aks_cluster"]="Create AKS Cluster"
    ["gateway_api_crds"]="Install Gateway API CRDs"
    ["infrastructure_iam"]="Setup Infrastructure & IAM"
    ["create_certs"]="Create Shared Root CA Certificates"
    ["install_ca_secrets"]="Install CA Secrets on Both Clouds"
    ["istio_eks"]="Install Istio on EKS"
    ["istio_aks"]="Install Istio on AKS"
    ["connect_clusters"]="Connect Clusters (Remote Secrets)"
    ["ecs_clusters"]="Deploy ECS Clusters"
    ["k8s_namespaces"]="Create Kubernetes Namespaces"
    ["add_to_mesh"]="Add ECS Services to Mesh"
    ["deploy_aks_workloads"]="Deploy AKS Workloads"
    ["prepare_tests"]="Prepare Test Environment"
)

# Part groupings (matches Readme-scenario-4.md structure)
declare -A STEP_PARTS=(
    ["cloud_login"]="Part 1: Multicloud Setup"
    ["eks_cluster"]="Part 1: Multicloud Setup"
    ["aks_cluster"]="Part 1: Multicloud Setup"
    ["gateway_api_crds"]="Part 2: Certificate Authority"
    ["infrastructure_iam"]="Part 2: Certificate Authority"
    ["create_certs"]="Part 2: Certificate Authority"
    ["install_ca_secrets"]="Part 2: Certificate Authority"
    ["istio_eks"]="Part 3: Istio Installation"
    ["istio_aks"]="Part 3: Istio Installation"
    ["connect_clusters"]="Part 3: Istio Installation"
    ["ecs_clusters"]="Part 4: ECS & AKS Workloads"
    ["k8s_namespaces"]="Part 4: ECS & AKS Workloads"
    ["add_to_mesh"]="Part 4: ECS & AKS Workloads"
    ["deploy_aks_workloads"]="Part 4: ECS & AKS Workloads"
    ["prepare_tests"]="Part 5: Cross-Cloud Testing"
)

# Override parse_arguments to show Scenario 4 specific steps
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
                echo "Usage: $0 [-c config-file] [-d|--delete] [-t|--tests-only] [-s|--step <step>] [--stop-after <step>] [-l|--list] [--reset]"
                echo ""
                echo "Options:"
                echo "  -c, --config      Config file to use (default: $DEFAULT_CONFIG)"
                echo "  -d, --delete      Delete all resources after tests complete"
                echo "  -t, --tests-only  Skip setup, run only tests"
                echo "  -s, --step        Start from a specific step (name or number)"
                echo "  --stop-after      Stop after completing a specific step"
                echo "  -l, --list        List all steps and their completion status"
                echo "  --reset           Clear progress and start fresh"
                echo "  -h, --help        Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 -c config.sh                    # Run with config file"
                echo "  $0 -s istio_eks                    # Start from istio_eks"
                echo "  $0 --stop-after aks_cluster        # Run up to and including aks_cluster"
                echo "  $0 -s 3 --stop-after 8             # Run steps 3 through 8"
                echo "  $0 --reset                         # Clear progress, run all steps"
                echo "  $0 -l                              # Show step status"
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
# Scenario 4 Specific Functions
# ================================================
load_and_validate_config() {
    log_step "Environment Setup"

    unset_config_variables
    # Also unset Azure-specific variables
    unset AZURE_SUBSCRIPTION AZURE_REGION AZURE_RESOURCE_GROUP AKS_CLUSTER_NAME
    unset AKS_NODE_COUNT AKS_NODE_VM_SIZE MESH_ID EKS_NETWORK AKS_NETWORK
    unset CTX_EKS CTX_AKS

    source "$CONFIG_FILE"

    # Validate scenario
    if [ "$SCENARIO" != "4" ]; then
        log_error "This test is for Scenario 4 only"
        log_error "Current SCENARIO=$SCENARIO"
        exit 1
    fi

    # Validate required variables
    validate_required_vars "LOCAL_ACCOUNT LOCAL_ACCOUNT_PROFILE AWS_REGION CLUSTER_NAME HUB ISTIO_TAG GLOO_MESH_LICENSE_KEY"
    validate_required_vars "AZURE_SUBSCRIPTION AZURE_REGION AZURE_RESOURCE_GROUP AKS_CLUSTER_NAME"
    validate_required_vars "MESH_ID EKS_NETWORK AKS_NETWORK"

    log_info "Configuration validated:"
    log_info "  SCENARIO=$SCENARIO"
    log_info "  AWS:"
    log_info "    LOCAL_ACCOUNT=$LOCAL_ACCOUNT"
    log_info "    LOCAL_ACCOUNT_PROFILE=$LOCAL_ACCOUNT_PROFILE"
    log_info "    AWS_REGION=$AWS_REGION"
    log_info "    CLUSTER_NAME=$CLUSTER_NAME"
    log_info "  Azure:"
    log_info "    AZURE_SUBSCRIPTION=$AZURE_SUBSCRIPTION"
    log_info "    AZURE_REGION=$AZURE_REGION"
    log_info "    AZURE_RESOURCE_GROUP=$AZURE_RESOURCE_GROUP"
    log_info "    AKS_CLUSTER_NAME=$AKS_CLUSTER_NAME"
    log_info "  Mesh:"
    log_info "    MESH_ID=$MESH_ID"
    log_info "    EKS_NETWORK=$EKS_NETWORK"
    log_info "    AKS_NETWORK=$AKS_NETWORK"
    echo ""
}

# ================================================
# Cloud Login Functions
# ================================================
cloud_login() {
    log_step "Cloud Provider Login"

    # AWS SSO Login
    if aws sts get-caller-identity --profile "$INT" &>/dev/null; then
        log_info "Already logged in to AWS SSO with profile: $INT"
    else
        log_info "Logging in to AWS SSO with profile: $INT"
        aws sso login --profile "$INT"
        if [ $? -ne 0 ]; then
            log_error "Failed to login to AWS SSO"
            exit 1
        fi
    fi

    # Azure Login
    if az account show &>/dev/null; then
        log_info "Already logged in to Azure"
    else
        log_info "Logging in to Azure..."
        az login
        if [ $? -ne 0 ]; then
            log_error "Failed to login to Azure"
            exit 1
        fi
    fi

    # Set Azure subscription
    az account set --subscription "$AZURE_SUBSCRIPTION"
    log_info "Azure subscription set to: $AZURE_SUBSCRIPTION"

    echo ""
}

# ================================================
# AKS Cluster Functions
# ================================================
create_aks_cluster() {
    log_step "Create AKS Cluster"

    # Check if cluster already exists
    if az aks show --resource-group "$AZURE_RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" &>/dev/null; then
        log_info "AKS cluster '$AKS_CLUSTER_NAME' already exists, skipping creation"
    else
        # Create resource group if it doesn't exist
        if ! az group show --name "$AZURE_RESOURCE_GROUP" &>/dev/null; then
            log_info "Creating resource group '$AZURE_RESOURCE_GROUP'..."
            az group create --name "$AZURE_RESOURCE_GROUP" --location "$AZURE_REGION"
        fi

        log_info "Creating AKS cluster '$AKS_CLUSTER_NAME'..."
        az aks create \
            --resource-group "$AZURE_RESOURCE_GROUP" \
            --name "$AKS_CLUSTER_NAME" \
            --node-count "${AKS_NODE_COUNT:-2}" \
            --node-vm-size "${AKS_NODE_VM_SIZE:-Standard_DS2_v2}" \
            --network-plugin azure \
            --enable-managed-identity \
            --generate-ssh-keys

        if [ $? -ne 0 ]; then
            log_error "Failed to create AKS cluster"
            exit 1
        fi
    fi

    # Get AKS credentials
    log_info "Getting AKS credentials..."
    az aks get-credentials \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --overwrite-existing

    # Save context
    CTX_AKS=$(kubectl config current-context)
    log_info "AKS context: $CTX_AKS"

    # Update config file with context
    if ! grep -q "^CTX_AKS=" "$CONFIG_FILE" 2>/dev/null; then
        echo "" >> "$CONFIG_FILE"
        echo "# AKS context (auto-generated)" >> "$CONFIG_FILE"
        echo "export CTX_AKS=\"$CTX_AKS\"" >> "$CONFIG_FILE"
    else
        sed -i "s|^CTX_AKS=.*|CTX_AKS=\"$CTX_AKS\"|" "$CONFIG_FILE"
    fi

    log_info "AKS cluster is ready"
    echo ""
}

# Override EKS cluster creation to save context
create_eks_cluster_sc4() {
    log_step "Create EKS Cluster"

    export AWS_PROFILE=$INT

    # Check if cluster already exists
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" &>/dev/null; then
        log_info "EKS cluster '$CLUSTER_NAME' already exists, skipping creation"
        # Update kubeconfig
        aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" --profile "$INT"
    else
        log_info "Creating EKS cluster '$CLUSTER_NAME'..."
        eval "echo \"$(cat manifests/eks-cluster.yaml)\"" | eksctl create cluster --config-file -

        if [ $? -ne 0 ]; then
            log_error "Failed to create EKS cluster"
            exit 1
        fi
    fi

    # Save context
    CTX_EKS=$(kubectl config current-context)
    log_info "EKS context: $CTX_EKS"

    # Update config file with context
    if ! grep -q "^CTX_EKS=" "$CONFIG_FILE" 2>/dev/null; then
        echo "" >> "$CONFIG_FILE"
        echo "# EKS context (auto-generated)" >> "$CONFIG_FILE"
        echo "export CTX_EKS=\"$CTX_EKS\"" >> "$CONFIG_FILE"
    else
        sed -i "s|^CTX_EKS=.*|CTX_EKS=\"$CTX_EKS\"|" "$CONFIG_FILE"
    fi

    # Verify cluster is accessible
    if ! kubectl --context="$CTX_EKS" get nodes &>/dev/null; then
        log_error "Cannot access EKS cluster with kubectl"
        exit 1
    fi

    log_info "EKS cluster is ready"
    echo ""
}

# ================================================
# Certificate Functions (Shared Root CA)
# ================================================
create_shared_certificates() {
    log_step "Create Shared Root CA Certificates"

    if [ -d "certs" ] && [ -f "certs/root-cert.pem" ]; then
        log_info "Certificates already exist, skipping creation"
        return 0
    fi

    mkdir -p certs
    cd certs

    # Generate root CA
    log_info "Generating root CA..."
    openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:4096 \
        -subj "/O=Istio/CN=Root CA" \
        -keyout root-key.pem -out root-cert.pem

    # Generate intermediate CA for EKS
    log_info "Generating intermediate CA for EKS..."
    openssl req -newkey rsa:4096 -sha256 -nodes \
        -subj "/O=Istio/CN=Intermediate CA EKS" \
        -keyout eks-ca-key.pem -out eks-ca-csr.pem

    openssl x509 -req -sha256 -days 1825 -CA root-cert.pem -CAkey root-key.pem \
        -set_serial 1 -in eks-ca-csr.pem -out eks-ca-cert.pem

    cat eks-ca-cert.pem root-cert.pem > eks-cert-chain.pem

    # Generate intermediate CA for AKS
    log_info "Generating intermediate CA for AKS..."
    openssl req -newkey rsa:4096 -sha256 -nodes \
        -subj "/O=Istio/CN=Intermediate CA AKS" \
        -keyout aks-ca-key.pem -out aks-ca-csr.pem

    openssl x509 -req -sha256 -days 1825 -CA root-cert.pem -CAkey root-key.pem \
        -set_serial 2 -in aks-ca-csr.pem -out aks-ca-cert.pem

    cat aks-ca-cert.pem root-cert.pem > aks-cert-chain.pem

    cd ..

    log_info "Certificates created in ./certs/"
    echo ""
}

install_ca_secrets() {
    log_step "Install CA Secrets on Both Clusters"

    # Create istio-system namespace on both clusters
    kubectl --context="$CTX_EKS" create namespace istio-system 2>/dev/null || true
    kubectl --context="$CTX_AKS" create namespace istio-system 2>/dev/null || true

    # Install CA secret on EKS
    log_info "Installing CA secret on EKS..."
    kubectl --context="$CTX_EKS" create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem=certs/eks-ca-cert.pem \
        --from-file=ca-key.pem=certs/eks-ca-key.pem \
        --from-file=root-cert.pem=certs/root-cert.pem \
        --from-file=cert-chain.pem=certs/eks-cert-chain.pem \
        --dry-run=client -o yaml | kubectl --context="$CTX_EKS" apply -f -

    # Install CA secret on AKS
    log_info "Installing CA secret on AKS..."
    kubectl --context="$CTX_AKS" create secret generic cacerts -n istio-system \
        --from-file=ca-cert.pem=certs/aks-ca-cert.pem \
        --from-file=ca-key.pem=certs/aks-ca-key.pem \
        --from-file=root-cert.pem=certs/root-cert.pem \
        --from-file=cert-chain.pem=certs/aks-cert-chain.pem \
        --dry-run=client -o yaml | kubectl --context="$CTX_AKS" apply -f -

    # Label networks
    log_info "Labeling networks..."
    kubectl --context="$CTX_EKS" label namespace istio-system topology.istio.io/network="$EKS_NETWORK" --overwrite
    kubectl --context="$CTX_AKS" label namespace istio-system topology.istio.io/network="$AKS_NETWORK" --overwrite

    log_info "CA secrets installed"
    echo ""
}

# ================================================
# Istio Installation Functions
# ================================================
install_istio_eks() {
    log_step "Install Istio on EKS (with ECS Support)"

    check_istioctl

    # Check if Istio is already installed
    if kubectl --context="$CTX_EKS" get deployment istiod -n istio-system &>/dev/null; then
        log_info "Istio is already installed on EKS, skipping installation"
    else
        log_info "Installing Istio on EKS..."
        cat <<EOF | "$ISTIOCTL" install --context="$CTX_EKS" -y -f -
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
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: eks-cluster
      network: ${EKS_NETWORK}
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
            log_error "Failed to install Istio on EKS"
            exit 1
        fi
    fi

    # Deploy East-West Gateway on EKS
    log_info "Deploying East-West Gateway on EKS..."
    kubectl --context="$CTX_EKS" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eastwest
  namespace: istio-system
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: ${EKS_NETWORK}
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: 15012
    protocol: TLS
    tls:
      mode: Passthrough
EOF

    # Wait for gateway to be ready
    log_info "Waiting for EKS East-West Gateway..."
    sleep 10
    kubectl --context="$CTX_EKS" wait --for=condition=Ready pods -n istio-system -l app=istiod --timeout=120s

    log_info "Istio installed on EKS"
    echo ""
}

install_istio_aks() {
    log_step "Install Istio on AKS"

    check_istioctl

    # Check if Istio is already installed
    if kubectl --context="$CTX_AKS" get deployment istiod -n istio-system &>/dev/null; then
        log_info "Istio is already installed on AKS, skipping installation"
    else
        log_info "Installing Istio on AKS..."
        cat <<EOF | "$ISTIOCTL" install --context="$CTX_AKS" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: aks-cluster
      network: ${AKS_NETWORK}
    pilot:
      env:
        PILOT_ENABLE_IP_AUTOALLOCATE: "true"
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
EOF

        if [ $? -ne 0 ]; then
            log_error "Failed to install Istio on AKS"
            exit 1
        fi
    fi

    # Deploy East-West Gateway on AKS
    log_info "Deploying East-West Gateway on AKS..."
    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eastwest
  namespace: istio-system
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: ${AKS_NETWORK}
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: 15012
    protocol: TLS
    tls:
      mode: Passthrough
EOF

    # Wait for gateway to be ready
    log_info "Waiting for AKS East-West Gateway..."
    sleep 10
    kubectl --context="$CTX_AKS" wait --for=condition=Ready pods -n istio-system -l app=istiod --timeout=120s

    log_info "Istio installed on AKS"
    echo ""
}

connect_clusters() {
    log_step "Connect Clusters with Remote Secrets"

    check_istioctl

    # Create remote secret for AKS on EKS
    log_info "Creating remote secret for AKS on EKS..."
    "$ISTIOCTL" create-remote-secret \
        --context="$CTX_AKS" \
        --name=aks-cluster | \
        kubectl apply -f - --context="$CTX_EKS"

    # Create remote secret for EKS on AKS
    log_info "Creating remote secret for EKS on AKS..."
    "$ISTIOCTL" create-remote-secret \
        --context="$CTX_EKS" \
        --name=eks-cluster | \
        kubectl apply -f - --context="$CTX_AKS"

    # Wait for discovery to propagate
    log_info "Waiting for cross-cluster discovery (30s)..."
    sleep 30

    log_info "Clusters connected"
    echo ""
}

# ================================================
# AKS Workload Deployment
# ================================================
deploy_aks_workloads() {
    log_step "Deploy Kubernetes Workloads on AKS"

    # Create namespace
    kubectl --context="$CTX_AKS" create namespace app-a 2>/dev/null || true
    kubectl --context="$CTX_AKS" label namespace app-a istio.io/dataplane-mode=ambient --overwrite

    # Deploy echo service
    log_info "Deploying echo-service on AKS..."
    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: app-a
  labels:
    app: echo-service
spec:
  ports:
  - port: 8080
    name: http
  selector:
    app: echo-service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-service
  namespace: app-a
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-service
  template:
    metadata:
      labels:
        app: echo-service
    spec:
      containers:
      - name: echo
        image: public.ecr.aws/j8r2p7b6/echo-server:latest
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
EOF

    # Deploy shell pod for testing
    log_info "Deploying shell pod on AKS..."
    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shell
  namespace: app-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: shell
  template:
    metadata:
      labels:
        app: shell
    spec:
      containers:
      - name: shell
        image: curlimages/curl:latest
        command: ["sleep", "infinity"]
EOF

    # Wait for pods
    log_info "Waiting for AKS pods to be ready..."
    kubectl --context="$CTX_AKS" wait --for=condition=Ready pods -n app-a -l app=echo-service --timeout=120s
    kubectl --context="$CTX_AKS" wait --for=condition=Ready pods -n app-a -l app=shell --timeout=120s

    log_info "AKS workloads deployed"
    echo ""
}

# ================================================
# Gateway API CRDs for both clusters
# ================================================
deploy_gateway_api_crds_sc4() {
    log_step "Deploy Gateway API CRDs (Both Clusters)"

    log_info "Installing on EKS..."
    kubectl --context="$CTX_EKS" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

    log_info "Installing on AKS..."
    kubectl --context="$CTX_AKS" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

    log_info "Gateway API CRDs deployed"
    echo ""
}

# ================================================
# Test Functions
# ================================================
clear_authorization_policies() {
    log_info "Clearing any existing authorization policies..."
    kubectl --context="$CTX_EKS" delete authorizationpolicy --all -n "ecs-${CLUSTER_NAME}-1" 2>&1 | grep -v "No resources found" || true
    kubectl --context="$CTX_EKS" delete authorizationpolicy --all -n "ecs-${CLUSTER_NAME}-2" 2>&1 | grep -v "No resources found" || true
    kubectl --context="$CTX_AKS" delete authorizationpolicy --all -n app-a 2>&1 | grep -v "No resources found" || true
    sleep 5
}

get_aks_shell_pod() {
    kubectl --context="$CTX_AKS" get pods -n app-a -l app=shell -o jsonpath="{.items[0].metadata.name}"
}

run_connectivity_tests() {
    log_step "Run Cross-Cloud Connectivity Tests"

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local AKS_SHELL_POD
    AKS_SHELL_POD=$(get_aks_shell_pod)

    local ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    local ECS_CLUSTER2="ecs-${CLUSTER_NAME}-2"
    local ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"
    local ECS_HOSTNAME_2="echo-service.${ECS_CLUSTER2}.ecs.local:8080"
    local AKS_HOSTNAME="echo-service.app-a.svc.cluster.local:8080"

    # Disable strict error handling for connectivity tests
    set +e
    set +o pipefail

    echo ""
    log_info "=== EKS Internal Tests ==="
    test_eks_to_eks_connectivity "$EKS_SHELL_POD"

    echo ""
    log_info "=== EKS to ECS Tests ==="
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME_1" "EKS-to-ECS Cluster 1"
    echo ""
    test_eks_to_ecs_connectivity "$EKS_SHELL_POD" "$ECS_HOSTNAME_2" "EKS-to-ECS Cluster 2"

    echo ""
    log_info "=== ECS Cross-Cluster Tests ==="
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_2" "ECS C1 to C2" "$ECS_CLUSTER1"
    echo ""
    test_ecs_to_ecs_connectivity "$ECS_HOSTNAME_1" "ECS C2 to C1" "$ECS_CLUSTER2"

    echo ""
    log_info "=== Cross-Cloud Tests (EKS to AKS) ==="
    test_eks_to_aks_connectivity "$EKS_SHELL_POD" "$AKS_HOSTNAME" "EKS to AKS"

    echo ""
    log_info "=== Cross-Cloud Tests (AKS to ECS) ==="
    test_aks_to_ecs_connectivity "$AKS_SHELL_POD" "$ECS_HOSTNAME_1" "AKS to ECS C1"
    echo ""
    test_aks_to_ecs_connectivity "$AKS_SHELL_POD" "$ECS_HOSTNAME_2" "AKS to ECS C2"

    echo ""
    log_info "=== Cross-Cloud Tests (ECS to AKS) ==="
    test_ecs_to_aks_connectivity "$AKS_HOSTNAME" "ECS C1 to AKS" "$ECS_CLUSTER1"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

test_eks_to_aks_connectivity() {
    local eks_shell_pod="$1"
    local aks_hostname="$2"
    local test_name="${3:-EKS-to-AKS}"

    log_test "$test_name connectivity"
    local RESULT=""
    local i
    for i in 1 2 3; do
        RESULT=$(kubectl --context="$CTX_EKS" exec "$eks_shell_pod" -- curl -s --max-time 10 "$aks_hostname" 2>&1)
        if echo "$RESULT" | grep -q "hostname"; then
            break
        fi
        if [ $i -lt 3 ]; then
            log_info "Attempt $i failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    if echo "$RESULT" | grep -q "hostname"; then
        local HOST
        HOST=$(echo "$RESULT" | jq -r '.host.hostname' 2>/dev/null)
        record_test "$test_name" "JSON with hostname" "Got hostname: ${HOST:-unknown}" "PASS"
    else
        record_test "$test_name" "JSON with hostname" "${RESULT:-CURL_FAILED}" "FAIL"
    fi
}

test_aks_to_ecs_connectivity() {
    local aks_shell_pod="$1"
    local ecs_hostname="$2"
    local test_name="${3:-AKS-to-ECS}"

    log_test "$test_name connectivity"
    local RESULT=""
    local i
    for i in 1 2 3; do
        RESULT=$(kubectl --context="$CTX_AKS" exec -n app-a "$aks_shell_pod" -- curl -s --max-time 10 "$ecs_hostname" 2>&1)
        if echo "$RESULT" | grep -q "hostname"; then
            break
        fi
        if [ $i -lt 3 ]; then
            log_info "Attempt $i failed, retrying in 5 seconds..."
            sleep 5
        fi
    done
    if echo "$RESULT" | grep -q "hostname"; then
        local HOST
        HOST=$(echo "$RESULT" | jq -r '.host.hostname' 2>/dev/null)
        record_test "$test_name" "JSON with hostname" "Got hostname: ${HOST:-unknown}" "PASS"
    else
        record_test "$test_name" "JSON with hostname" "${RESULT:-CURL_FAILED}" "FAIL"
    fi
}

test_ecs_to_aks_connectivity() {
    local aks_hostname="$1"
    local test_name="${2:-ECS-to-AKS}"
    local origin_cluster="${3:-}"

    log_test "$test_name connectivity"
    local RESULT
    if [ -n "$origin_cluster" ]; then
        RESULT=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$aks_hostname" 2>&1)
    else
        RESULT=$(./scripts/test/call-from-ecs.sh "$aks_hostname" 2>&1)
    fi
    if echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "JSON with hostname" "Got response" "PASS"
    else
        record_test "$test_name" "JSON with hostname" "${RESULT:-CURL_FAILED}" "FAIL"
    fi
}

run_authorization_policy_tests() {
    log_step "Test Cross-Cloud Authorization Policies"

    local EKS_SHELL_POD
    EKS_SHELL_POD=$(get_eks_shell_pod)
    local AKS_SHELL_POD
    AKS_SHELL_POD=$(get_aks_shell_pod)
    local AKS_HOSTNAME="echo-service.app-a.svc.cluster.local:8080"
    local ECS_CLUSTER1="ecs-${CLUSTER_NAME}-1"
    local ECS_HOSTNAME_1="echo-service.${ECS_CLUSTER1}.ecs.local:8080"

    # Disable strict error handling for policy tests
    set +e
    set +o pipefail

    # Exercise: Deny-all on AKS namespace
    echo ""
    log_info "Exercise: Testing deny-all policy on AKS app-a namespace"
    kubectl --context="$CTX_AKS" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: app-a
spec:
  {}
EOF
    sleep 10

    # EKS -> AKS should be blocked
    test_connection_blocked_cross_cloud "$EKS_SHELL_POD" "$AKS_HOSTNAME" "Deny-all: EKS to AKS blocked"

    # ECS -> AKS should be blocked
    test_connection_blocked_ecs_to_aks "$AKS_HOSTNAME" "Deny-all: ECS to AKS blocked" "$ECS_CLUSTER1"

    # Exercise: Allow EKS default namespace to AKS
    echo ""
    log_info "Exercise: Allow EKS default namespace to access AKS"
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
    sleep 10

    # EKS -> AKS should now succeed
    test_eks_to_aks_connectivity "$EKS_SHELL_POD" "$AKS_HOSTNAME" "Allow-EKS: EKS to AKS allowed"

    # ECS -> AKS should still be blocked
    test_connection_blocked_ecs_to_aks "$AKS_HOSTNAME" "Allow-EKS: ECS to AKS still blocked" "$ECS_CLUSTER1"

    # Re-enable strict error handling
    set -e
    set -o pipefail

    echo ""
}

test_connection_blocked_cross_cloud() {
    local eks_shell_pod="$1"
    local aks_hostname="$2"
    local test_name="${3:-Connection blocked}"

    log_test "$test_name (should be blocked)"
    local RESULT
    local EXIT_CODE
    RESULT=$(kubectl --context="$CTX_EKS" exec "$eks_shell_pod" -- curl -s --max-time 5 "$aks_hostname" 2>&1)
    EXIT_CODE=$?

    if echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "Connection blocked" "Unexpectedly succeeded" "FAIL"
    elif echo "$RESULT" | grep -qi "reset\|refused\|denied\|failed\|timed out"; then
        record_test "$test_name" "Connection blocked" "Blocked as expected" "PASS"
    elif [ $EXIT_CODE -ne 0 ]; then
        record_test "$test_name" "Connection blocked" "Blocked (exit code $EXIT_CODE)" "PASS"
    elif [ -z "$RESULT" ]; then
        record_test "$test_name" "Connection blocked" "Blocked (no response)" "PASS"
    else
        record_test "$test_name" "Connection blocked" "Unknown: $RESULT" "FAIL"
    fi
}

test_connection_blocked_ecs_to_aks() {
    local aks_hostname="$1"
    local test_name="${2:-Connection blocked}"
    local origin_cluster="${3:-}"

    log_test "$test_name (should be blocked)"
    local RESULT
    if [ -n "$origin_cluster" ]; then
        RESULT=$(ORIGIN_CLUSTER="$origin_cluster" ./scripts/test/call-from-ecs.sh "$aks_hostname" 2>&1)
    else
        RESULT=$(./scripts/test/call-from-ecs.sh "$aks_hostname" 2>&1)
    fi

    if echo "$RESULT" | grep -qi "reset\|refused\|denied\|failed"; then
        record_test "$test_name" "Connection blocked" "Blocked as expected" "PASS"
    elif echo "$RESULT" | grep -q "hostname"; then
        record_test "$test_name" "Connection blocked" "Unexpectedly succeeded" "FAIL"
    else
        record_test "$test_name" "Connection blocked" "Unknown: $RESULT" "FAIL"
    fi
}

# ================================================
# Setup Orchestration
# ================================================

# Wrapper functions for run_step
do_cloud_login() { cloud_login; }
do_eks_cluster() { create_eks_cluster_sc4; }
do_aks_cluster() { create_aks_cluster; }
do_gateway_api_crds() { deploy_gateway_api_crds_sc4; }
do_infrastructure_iam() { setup_infrastructure_and_iam; }
do_create_certs() { create_shared_certificates; }
do_install_ca_secrets() { install_ca_secrets; }
do_istio_eks() { install_istio_eks; }
do_istio_aks() { install_istio_aks; }
do_connect_clusters() { connect_clusters; }
do_ecs_clusters() { deploy_ecs_clusters; }
do_k8s_namespaces() { create_k8s_namespaces; }
do_add_to_mesh() { add_services_to_mesh; }
do_deploy_aks_workloads() { deploy_aks_workloads; }
do_prepare_tests() { prepare_test_environment; }

run_setup_steps() {
    local rc
    for step in "${SETUP_STEPS[@]}"; do
        case "$step" in
            cloud_login)          run_step "$step" do_cloud_login ;;
            eks_cluster)          run_step "$step" do_eks_cluster ;;
            aks_cluster)          run_step "$step" do_aks_cluster ;;
            gateway_api_crds)     run_step "$step" do_gateway_api_crds ;;
            infrastructure_iam)   run_step "$step" do_infrastructure_iam ;;
            create_certs)         run_step "$step" do_create_certs ;;
            install_ca_secrets)   run_step "$step" do_install_ca_secrets ;;
            istio_eks)            run_step "$step" do_istio_eks ;;
            istio_aks)            run_step "$step" do_istio_aks ;;
            connect_clusters)     run_step "$step" do_connect_clusters ;;
            ecs_clusters)         run_step "$step" do_ecs_clusters ;;
            k8s_namespaces)       run_step "$step" do_k8s_namespaces ;;
            add_to_mesh)          run_step "$step" do_add_to_mesh ;;
            deploy_aks_workloads) run_step "$step" do_deploy_aks_workloads ;;
            prepare_tests)        run_step "$step" do_prepare_tests ;;
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
    log_info "Waiting 30 seconds for cross-cloud service discovery..."
    sleep 30
    # Scenario 4 expects: 4 ECS services + 1 AKS service = 5 services minimum
    verify_service_discovery_sc4
}

verify_service_discovery_sc4() {
    log_info "Verifying cross-cloud service discovery..."

    set +e
    set +o pipefail

    # Check services on EKS (should see ECS + AKS services)
    local EKS_SERVICES
    EKS_SERVICES=$("$ISTIOCTL" --context="$CTX_EKS" ztunnel-config services 2>/dev/null | grep -c "$CLUSTER_NAME\|app-a" || echo "0")
    if [ "$EKS_SERVICES" -ge 4 ]; then
        record_test "EKS Service Discovery" ">=4 services" "$EKS_SERVICES services" "PASS"
    else
        record_test "EKS Service Discovery" ">=4 services" "$EKS_SERVICES services" "FAIL"
    fi

    # Check services on AKS (should see ECS services)
    local AKS_SERVICES
    AKS_SERVICES=$("$ISTIOCTL" --context="$CTX_AKS" ztunnel-config services 2>/dev/null | grep -c "$CLUSTER_NAME\|app-a" || echo "0")
    if [ "$AKS_SERVICES" -ge 4 ]; then
        record_test "AKS Service Discovery" ">=4 services" "$AKS_SERVICES services" "PASS"
    else
        record_test "AKS Service Discovery" ">=4 services" "$AKS_SERVICES services" "FAIL"
    fi

    set -e
    set -o pipefail

    echo ""
}

run_test_steps() {
    run_connectivity_tests
    run_authorization_policy_tests
    clear_authorization_policies
}

# ================================================
# Cleanup
# ================================================
cleanup_resources() {
    log_step "Cleanup: Removing all resources"

    clear_authorization_policies
    cleanup_test_pods

    # Delete AKS workloads
    log_info "Removing AKS workloads..."
    kubectl --context="$CTX_AKS" delete namespace app-a 2>/dev/null || true

    # Run ECS cleanup script
    ./scripts/cleanup.sh -c "$CONFIG_FILE" || log_warn "ECS cleanup script had some errors"

    # Delete AKS cluster
    log_info "Deleting AKS cluster..."
    az aks delete \
        --resource-group "$AZURE_RESOURCE_GROUP" \
        --name "$AKS_CLUSTER_NAME" \
        --yes --no-wait || log_warn "Failed to delete AKS cluster"

    # Delete Azure resource group
    log_info "Deleting Azure resource group..."
    az group delete \
        --name "$AZURE_RESOURCE_GROUP" \
        --yes --no-wait || log_warn "Failed to delete resource group"

    # Delete EKS cluster
    cleanup_eks_cluster "$CLUSTER_NAME" "$INT"

    # Remove certificates
    log_info "Removing certificates..."
    rm -rf certs/

    log_info "Cleanup complete"
}

# ================================================
# Main
# ================================================
print_header() {
    echo ""
    echo "=============================================="
    echo "     SCENARIO 4 END-TO-END TEST"
    echo "     (Multicloud: EKS + AKS)"
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
    export PROGRESS_FILE="$REPO_ROOT/.workshop-progress-sc4"

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
        # Reload contexts from config
        source "$CONFIG_FILE"
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
        log_info "  $0 -c $CONFIG_FILE -d"
        log_info ""
        log_info "Or manually:"
        log_info "  az aks delete --resource-group $AZURE_RESOURCE_GROUP --name $AKS_CLUSTER_NAME --yes"
        log_info "  az group delete --name $AZURE_RESOURCE_GROUP --yes"
        log_info "  ./scripts/cleanup.sh -c $CONFIG_FILE"
        log_info "  eksctl delete cluster -n $CLUSTER_NAME --profile $INT"
    fi

    exit $TEST_EXIT_CODE
}

# Run main function with all arguments
main "$@"
