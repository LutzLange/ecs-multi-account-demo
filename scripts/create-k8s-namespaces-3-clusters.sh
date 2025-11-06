#!/bin/bash

# create-k8s-namespaces-3-clusters.sh
# Creates Kubernetes namespaces and service accounts for all 3 ECS clusters

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Kubernetes Namespace Setup${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Validate required environment variables
required_vars=("CLUSTER_NAME" "LOCAL_TASK_ROLE_ARN" "EXTERNAL_TASK_ROLE_ARN")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${YELLOW}Error: $var is not defined.${NC}"
        echo "Please source your configuration file or run create-iam-multi-account.sh first"
        exit 1
    fi
done

# Set service account names
export LOCAL_ECS_SERVICE_ACCOUNT_NAME=${LOCAL_ECS_SERVICE_ACCOUNT_NAME:-ecs-demo-sa-local}
export EXTERNAL_ECS_SERVICE_ACCOUNT_NAME=${EXTERNAL_ECS_SERVICE_ACCOUNT_NAME:-ecs-demo-sa-external}

echo "Configuration:"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  Local Service Account: ${LOCAL_ECS_SERVICE_ACCOUNT_NAME}"
echo "  External Service Account: ${EXTERNAL_ECS_SERVICE_ACCOUNT_NAME}"
echo ""

# Function to create namespace for a cluster
create_namespace_for_cluster() {
    local cluster_num=$1
    local task_role_arn=$2
    local svc_account_name=$3
    local account_type=$4
    
    local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
    
    echo -e "${GREEN}Creating namespace for cluster ${cluster_num} (${account_type})...${NC}"
    
    # Create namespace
    kubectl create ns ${namespace} 2>/dev/null || echo "  Namespace ${namespace} already exists"
    
    # Label namespace for ambient mode
    kubectl label namespace ${namespace} istio.io/dataplane-mode=ambient --overwrite
    echo "  ✓ Namespace labeled for ambient mode"
    
    # Create service account
    kubectl create sa ${svc_account_name} -n ${namespace} 2>/dev/null || echo "  Service account ${svc_account_name} already exists"
    
    # Annotate service account with task role ARN (remove /ecs/ambient prefix)
    local clean_role_arn=$task_role_arn
    kubectl -n ${namespace} annotate sa ${svc_account_name} \
        ecs.solo.io/role-arn=${clean_role_arn} \
        --overwrite
    
    echo "  ✓ Service account annotated with role ARN"
    echo "    Namespace: ${namespace}"
    echo "    Service Account: ${svc_account_name}"
    echo "    Role ARN: ${clean_role_arn}"
    echo ""
}

# Main execution
main() {
    echo -e "${BLUE}Creating namespaces for LOCAL clusters (1 and 2)...${NC}"
    echo ""
    
    # Create namespaces for local clusters
    create_namespace_for_cluster "1" "$LOCAL_TASK_ROLE_ARN" "$LOCAL_ECS_SERVICE_ACCOUNT_NAME" "local"
    create_namespace_for_cluster "2" "$LOCAL_TASK_ROLE_ARN" "$LOCAL_ECS_SERVICE_ACCOUNT_NAME" "local"
    
    echo -e "${BLUE}Creating namespace for EXTERNAL cluster (3)...${NC}"
    echo ""
    
    # Create namespace for external cluster
    create_namespace_for_cluster "3" "$EXTERNAL_TASK_ROLE_ARN" "$EXTERNAL_ECS_SERVICE_ACCOUNT_NAME" "external"
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  Namespace Setup Complete!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Created namespaces:"
    echo "  - ecs-${CLUSTER_NAME}-1 (local)"
    echo "  - ecs-${CLUSTER_NAME}-2 (local)"
    echo "  - ecs-${CLUSTER_NAME}-3 (external)"
    echo ""
    echo "Verify with:"
    echo "  kubectl get ns | grep ecs-${CLUSTER_NAME}"
    echo "  kubectl get sa -n ecs-${CLUSTER_NAME}-1"
    echo ""
}

# Run main function
main

# ============================================
# CLEANUP - Prevents shell pollution
# ============================================
# This section ensures that when the script is sourced (. script.sh),
# only the exported service account names remain in the shell environment.

# Unset all functions
unset -f create_namespace_for_cluster
unset -f main

# Unset internal variables (keep only exports: LOCAL_ECS_SERVICE_ACCOUNT_NAME, EXTERNAL_ECS_SERVICE_ACCOUNT_NAME)
unset GREEN BLUE YELLOW NC
unset required_vars

# Reset shell options
set +e

# Note: LOCAL_ECS_SERVICE_ACCOUNT_NAME and EXTERNAL_ECS_SERVICE_ACCOUNT_NAME remain exported
