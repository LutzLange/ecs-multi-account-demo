#!/bin/bash

# add-services-to-mesh-3-clusters.sh
# Adds all ECS services from all 3 clusters to the Istio mesh

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Add ECS Services to Istio Mesh${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Validate required environment variables
required_vars=("CLUSTER_NAME" "LOCAL_ACCOUNT_PROFILE" "EXTERNAL_ACCOUNT_PROFILE" "LOCAL_ECS_SERVICE_ACCOUNT_NAME" "EXTERNAL_ECS_SERVICE_ACCOUNT_NAME")
for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
        echo -e "${YELLOW}Error: $var is not defined.${NC}"
        echo "Please run create-k8s-namespaces-3-clusters.sh first"
        exit 1
    fi
done

echo "Configuration:"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  Local Profile: ${LOCAL_ACCOUNT_PROFILE}"
echo "  External Profile: ${EXTERNAL_ACCOUNT_PROFILE}"
echo ""

# Function to add services for a cluster
add_services_for_cluster() {
    local cluster_num=$1
    local aws_profile=$2
    local svc_account=$3
    local account_type=$4
    
    local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
    local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
    
    echo -e "${GREEN}Adding services for cluster ${cluster_num} (${account_type})...${NC}"
    echo "  Cluster: ${cluster_name}"
    echo "  Namespace: ${namespace}"
    echo "  Profile: ${aws_profile}"
    echo ""
    
    # Add shell-task service
    echo "  Adding shell-task..."
    ./istioctl ecs add-service shell-task \
        --cluster ${cluster_name} \
        --namespace ${namespace} \
        --service-account ${svc_account} \
        --external \
        --profile ${aws_profile}
    
    if [ $? -eq 0 ]; then
        echo "    ✓ shell-task added successfully"
    else
        echo -e "${YELLOW}    ⚠ Failed to add shell-task${NC}"
    fi
    echo ""
    
    # Add echo-service
    echo "  Adding echo-service..."
    ./istioctl ecs add-service echo-service \
        --cluster ${cluster_name} \
        --namespace ${namespace} \
        --service-account ${svc_account} \
        --external \
        --profile ${aws_profile}
    
    if [ $? -eq 0 ]; then
        echo "    ✓ echo-service added successfully"
    else
        echo -e "${YELLOW}    ⚠ Failed to add echo-service${NC}"
    fi
    echo ""
    
    echo "  Waiting 10 seconds for services to register..."
    sleep 10
    echo ""
}

# Main execution
main() {
    # Check if istioctl exists
    if [ ! -f "./istioctl" ]; then
        echo -e "${YELLOW}Error: istioctl not found in current directory${NC}"
        echo "Please ensure istioctl is in the current directory"
        exit 1
    fi
    
    echo -e "${BLUE}Adding services for LOCAL clusters (1 and 2)...${NC}"
    echo ""
    
    # Add services for local clusters
    add_services_for_cluster "1" "$LOCAL_ACCOUNT_PROFILE" "$LOCAL_ECS_SERVICE_ACCOUNT_NAME" "local"
    add_services_for_cluster "2" "$LOCAL_ACCOUNT_PROFILE" "$LOCAL_ECS_SERVICE_ACCOUNT_NAME" "local"
    
    echo -e "${BLUE}Adding services for EXTERNAL cluster (3)...${NC}"
    echo ""
    
    # Add services for external cluster
    add_services_for_cluster "3" "$EXTERNAL_ACCOUNT_PROFILE" "$EXTERNAL_ECS_SERVICE_ACCOUNT_NAME" "external"
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  All Services Added to Mesh!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Services added:"
    echo "  LOCAL ACCOUNT:"
    echo "    ecs-${CLUSTER_NAME}-1: shell-task, echo-service"
    echo "    ecs-${CLUSTER_NAME}-2: shell-task, echo-service"
    echo "  EXTERNAL ACCOUNT:"
    echo "    ecs-${CLUSTER_NAME}-3: shell-task, echo-service"
    echo ""
    echo "Verify with:"
    echo "  ./istioctl ztunnel-config services | grep ecs-${CLUSTER_NAME}"
    echo "  ./istioctl ztunnel-config workloads | grep ecs-${CLUSTER_NAME}"
    echo ""
    echo "Expected service DNS names:"
    echo "  Local Cluster 1:"
    echo "    - shell-task.ecs-${CLUSTER_NAME}-1.ecs.local:80"
    echo "    - echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080"
    echo "  Local Cluster 2:"
    echo "    - shell-task.ecs-${CLUSTER_NAME}-2.ecs.local:80"
    echo "    - echo-service.ecs-${CLUSTER_NAME}-2.ecs.local:8080"
    echo "  External Cluster 3:"
    echo "    - shell-task.ecs-${CLUSTER_NAME}-3.ecs.external:80"
    echo "    - echo-service.ecs-${CLUSTER_NAME}-3.ecs.external:8080"
    echo ""
}

# Run main function
main
