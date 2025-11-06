#!/bin/bash

# cleanup-ecs-multi-account.sh
# Idempotent cleanup script for ECS Multi-Account Istio setup
# Removes all resources created by the setup and deployment scripts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "${BLUE}[====]${NC} $1"; }

# Track what gets deleted for summary
DELETED_RESOURCES=()
FAILED_DELETIONS=()

# Validate required environment variables
validate_env() {
    local required_vars=(
        "LOCAL_ACCOUNT_PROFILE"
        "EXTERNAL_ACCOUNT_PROFILE"
        "AWS_REGION"
        "CLUSTER_NAME"
    )
    
    local missing=0
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "Required environment variable $var is not set"
            missing=1
        fi
    done
    
    if [ $missing -eq 1 ]; then
        log_error "Please source your environment configuration first:"
        log_error "  source /tmp/ecs-multi-account-env.sh"
        log_error "  OR"
        log_error "  source ./env-config.sh"
        exit 1
    fi
    
    export INT=$LOCAL_ACCOUNT_PROFILE
    export EXT=$EXTERNAL_ACCOUNT_PROFILE
    
    # Get account IDs if not set
    if [ -z "$LOCAL_ACCOUNT" ]; then
        log_info "Discovering LOCAL_ACCOUNT ID..."
        LOCAL_ACCOUNT=$(aws sts get-caller-identity \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --query Account \
            --output text 2>/dev/null || echo "")
        if [ -z "$LOCAL_ACCOUNT" ]; then
            log_error "Could not determine LOCAL_ACCOUNT ID"
            exit 1
        fi
        export LOCAL_ACCOUNT
        log_info "LOCAL_ACCOUNT: $LOCAL_ACCOUNT"
    fi
    
    if [ -z "$EXTERNAL_ACCOUNT" ]; then
        log_info "Discovering EXTERNAL_ACCOUNT ID..."
        EXTERNAL_ACCOUNT=$(aws sts get-caller-identity \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --query Account \
            --output text 2>/dev/null || echo "")
        if [ -z "$EXTERNAL_ACCOUNT" ]; then
            log_error "Could not determine EXTERNAL_ACCOUNT ID"
            exit 1
        fi
        export EXTERNAL_ACCOUNT
        log_info "EXTERNAL_ACCOUNT: $EXTERNAL_ACCOUNT"
    fi
}

# Check if resource exists
resource_exists() {
    [ -n "$1" ] && [ "$1" != "None" ] && [ "$1" != "null" ] && [ "$1" != "" ]
}

# Cleanup Istio Resources
cleanup_istio() {
    log_section "=== Cleaning Up Istio Resources ==="
    
    if ! kubectl cluster-info &>/dev/null; then
        log_warn "Cannot connect to Kubernetes cluster, skipping Istio cleanup"
        return
    fi
    
    # Remove authorization policies
    log_info "Removing authorization policies..."
    local policies=$(kubectl get authorizationpolicies --all-namespaces -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"' 2>/dev/null)
    if [ -n "$policies" ]; then
        while IFS= read -r line; do
            local ns=$(echo $line | awk '{print $1}')
            local name=$(echo $line | awk '{print $2}')
            if kubectl delete authorizationpolicy "$name" -n "$ns" 2>/dev/null; then
                DELETED_RESOURCES+=("AuthorizationPolicy: $ns/$name")
            fi
        done <<< "$policies"
    else
        log_info "No authorization policies found"
    fi
    
    # Remove waypoint proxies
    log_info "Removing waypoint proxies..."
    for ns in ecs-${CLUSTER_NAME}-{1,2,3}; do
        if kubectl get namespace "$ns" &>/dev/null; then
            if ./istioctl waypoint delete --all -n "$ns" 2>/dev/null; then
                DELETED_RESOURCES+=("Waypoints in namespace: $ns")
            fi
        fi
    done
    
    # Remove services from mesh
    log_info "Removing ECS services from mesh..."
    for cluster_num in 1 2 3; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
        local profile=$LOCAL_ACCOUNT_PROFILE
        
        if [ "$cluster_num" -eq 3 ]; then
            profile=$EXTERNAL_ACCOUNT_PROFILE
        fi
        
        if kubectl get namespace "$namespace" &>/dev/null; then
            for service in shell-task echo-service; do
                if ./istioctl ecs remove-service "$service" \
                    --cluster "$cluster_name" \
                    --namespace "$namespace" \
                    --profile "$profile" 2>/dev/null; then
                    DELETED_RESOURCES+=("Mesh service: $service in $cluster_name")
                fi
            done
        fi
    done
    
    # Delete Kubernetes namespaces
    log_info "Deleting Kubernetes namespaces..."
    for ns in ecs-${CLUSTER_NAME}-{1,2,3}; do
        if kubectl get namespace "$ns" &>/dev/null; then
            if kubectl delete namespace "$ns" --timeout=60s 2>/dev/null; then
                DELETED_RESOURCES+=("Namespace: $ns")
            fi
        fi
    done
    
    # Delete EKS test deployments
    log_info "Deleting EKS test deployments..."
    for deployment in eks-shell eks-echo; do
        if kubectl get deployment "$deployment" -n default &>/dev/null; then
            if kubectl delete deployment "$deployment" -n default 2>/dev/null; then
                DELETED_RESOURCES+=("EKS deployment: $deployment")
            fi
        fi
    done
    
    # Delete EKS services
    for svc in eks-echo; do
        if kubectl get service "$svc" -n default &>/dev/null; then
            if kubectl delete service "$svc" -n default 2>/dev/null; then
                DELETED_RESOURCES+=("EKS service: $svc")
            fi
        fi
    done
    
    # Uninstall Istio
    log_info "Uninstalling Istio..."
    if kubectl get namespace istio-system &>/dev/null; then
        if ./istioctl uninstall --purge -y 2>/dev/null; then
            DELETED_RESOURCES+=("Istio control plane")
        fi
    else
        log_info "Istio not installed"
    fi
    
    echo ""
}

# Cleanup ECS Resources
cleanup_ecs() {
    local account_type=$1
    local cluster_numbers=$2
    
    log_section "=== Cleaning Up ECS Resources in ${account_type^^} Account ==="
    
    local profile=$LOCAL_ACCOUNT_PROFILE
    if [ "$account_type" == "external" ]; then
        profile=$EXTERNAL_ACCOUNT_PROFILE
    fi
    
    for cluster_num in $cluster_numbers; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        
        log_info "Processing cluster: $cluster_name"
        
        # Check if cluster exists
        local cluster_status=$(aws ecs describe-clusters \
            --clusters "$cluster_name" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --query 'clusters[0].status' \
            --output text 2>/dev/null || echo "")
        
        if [ "$cluster_status" != "ACTIVE" ]; then
            log_info "  Cluster $cluster_name does not exist or not active"
            continue
        fi
        
        # Stop all running tasks first
        log_info "  Stopping all running tasks in $cluster_name..."
        local task_arns=$(aws ecs list-tasks \
            --cluster "$cluster_name" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --query 'taskArns' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$task_arns" ]; then
            for task_arn in $task_arns; do
                log_info "    Stopping task: $(basename $task_arn)"
                aws ecs stop-task \
                    --cluster "$cluster_name" \
                    --task "$task_arn" \
                    --profile "$profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1 || true
            done
            log_info "    Waiting for tasks to stop..."
            sleep 15
        fi
        
        # Delete services
        log_info "  Deleting services in $cluster_name..."
        local services=$(aws ecs list-services \
            --cluster "$cluster_name" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --query 'serviceArns' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$services" ]; then
            for service_arn in $services; do
                local service_name=$(basename "$service_arn")
                log_info "    Deleting service: $service_name"
                
                # Scale to 0 first
                aws ecs update-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --desired-count 0 \
                    --profile "$profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1 || true
                
                # Delete service with force flag
                if aws ecs delete-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --force \
                    --profile "$profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1; then
                    log_info "      Service deletion initiated: $service_name"
                else
                    log_warn "      Failed to delete service: $service_name"
                fi
            done
            
            # Wait for services to actually be deleted (not just DRAINING)
            log_info "    Waiting for services to be fully deleted (this may take 1-2 minutes)..."
            local max_wait=180  # 3 minutes
            local elapsed=0
            local all_deleted=false
            
            while [ $elapsed -lt $max_wait ]; do
                local active_services=$(aws ecs list-services \
                    --cluster "$cluster_name" \
                    --profile "$profile" \
                    --region "$AWS_REGION" \
                    --query 'serviceArns' \
                    --output text 2>/dev/null || echo "")
                
                if [ -z "$active_services" ]; then
                    log_info "    All services deleted"
                    all_deleted=true
                    
                    # Track successfully deleted services
                    for service_arn in $services; do
                        local service_name=$(basename "$service_arn")
                        DELETED_RESOURCES+=("ECS service: $service_name in $cluster_name")
                    done
                    break
                fi
                
                sleep 10
                elapsed=$((elapsed + 10))
                log_info "    Still waiting... ($elapsed seconds elapsed)"
            done
            
            if [ "$all_deleted" = false ]; then
                log_warn "    Services did not fully delete within timeout"
                log_warn "    Cluster deletion may fail - you may need to delete manually"
            fi
        else
            log_info "    No services found in cluster"
        fi
        
        # Delete cluster
        log_info "  Deleting cluster: $cluster_name"
        if aws ecs delete-cluster \
            --cluster "$cluster_name" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --no-cli-pager > /dev/null 2>&1; then
            DELETED_RESOURCES+=("ECS cluster: $cluster_name")
            log_info "    Cluster deleted successfully"
        else
            log_error "    Failed to delete cluster: $cluster_name"
            log_error "    This may be because services are still draining"
            FAILED_DELETIONS+=("ECS cluster: $cluster_name")
        fi
    done
    
    # Deregister task definitions
    log_info "Deregistering task definitions..."
    for task_family in shell-task-definition echo-task-definition; do
        local task_arns=$(aws ecs list-task-definitions \
            --family-prefix "$task_family" \
            --profile "$profile" \
            --region "$AWS_REGION" \
            --query 'taskDefinitionArns' \
            --output text 2>/dev/null || echo "")
        
        if [ -n "$task_arns" ]; then
            for task_arn in $task_arns; do
                if aws ecs deregister-task-definition \
                    --task-definition "$task_arn" \
                    --profile "$profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1; then
                    DELETED_RESOURCES+=("Task definition: $(basename $task_arn)")
                fi
            done
        fi
    done
    
    # Delete CloudWatch log group
    log_info "Deleting CloudWatch log group..."
    if aws logs delete-log-group \
        --log-group-name "/ecs/ecs-demo" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --no-cli-pager 2>/dev/null; then
        DELETED_RESOURCES+=("CloudWatch log group: /ecs/ecs-demo")
    fi
    
    echo ""
}

# Helper function to delete a role
delete_iam_role() {
    local role_name=$1
    local profile=$2
    
    log_info "Processing role: $role_name"
    
    # Check if role exists
    if ! aws iam get-role --role-name "$role_name" --profile "$profile" &>/dev/null; then
        log_info "  Role $role_name does not exist"
        return 0
    fi
    
    # Detach all managed policies
    log_info "  Detaching managed policies from $role_name..."
    local attached_policies=$(aws iam list-attached-role-policies \
        --role-name "$role_name" \
        --profile "$profile" \
        --query 'AttachedPolicies[].PolicyArn' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$attached_policies" ]; then
        for policy_arn in $attached_policies; do
            aws iam detach-role-policy \
                --role-name "$role_name" \
                --policy-arn "$policy_arn" \
                --profile "$profile" 2>/dev/null || true
        done
    fi
    
    # Delete inline policies
    local inline_policies=$(aws iam list-role-policies \
        --role-name "$role_name" \
        --profile "$profile" \
        --query 'PolicyNames' \
        --output text 2>/dev/null || echo "")
    
    if [ -n "$inline_policies" ]; then
        for policy_name in $inline_policies; do
            aws iam delete-role-policy \
                --role-name "$role_name" \
                --policy-name "$policy_name" \
                --profile "$profile" 2>/dev/null || true
        done
    fi
    
    # Delete role
    if aws iam delete-role \
        --role-name "$role_name" \
        --profile "$profile" 2>/dev/null; then
        DELETED_RESOURCES+=("IAM role: $role_name")
    fi
}

# Helper function to delete a policy
delete_iam_policy() {
    local policy_arn=$1
    local profile=$2
    local policy_display_name=$3
    
    # Check if policy exists
    if ! aws iam get-policy --policy-arn "$policy_arn" --profile "$profile" &>/dev/null; then
        return 0
    fi
    
    log_info "  Deleting policy: $policy_display_name"
    
    # Delete all non-default versions
    local versions=$(aws iam list-policy-versions \
        --policy-arn "$policy_arn" \
        --profile "$profile" \
        --query 'Versions[?IsDefaultVersion==`false`].VersionId' \
        --output text 2>/dev/null || echo "")
    
    for version in $versions; do
        aws iam delete-policy-version \
            --policy-arn "$policy_arn" \
            --version-id "$version" \
            --profile "$profile" 2>/dev/null || true
    done
    
    # Delete policy
    if aws iam delete-policy \
        --policy-arn "$policy_arn" \
        --profile "$profile" 2>/dev/null; then
        DELETED_RESOURCES+=("IAM policy: $policy_display_name")
    fi
}

# Cleanup IAM Resources
cleanup_iam() {
    local account_type=$1
    
    log_section "=== Cleaning Up IAM Resources in ${account_type^^} Account ==="
    
    local profile=$LOCAL_ACCOUNT_PROFILE
    local account_id=$LOCAL_ACCOUNT
    
    if [ "$account_type" == "external" ]; then
        profile=$EXTERNAL_ACCOUNT_PROFILE
        account_id=$EXTERNAL_ACCOUNT
    fi
    
    # Define roles to delete (check both with and without path)
    local base_roles=("eks-ecs-task-role")
    local path_roles=("ecs/ambient/eks-ecs-task-role")
    
    if [ "$account_type" == "local" ]; then
        base_roles+=("istiod-role" "istiod-local")
    else
        base_roles+=("istiod-external")
    fi
    
    # Delete roles without path prefix
    for role_name in "${base_roles[@]}"; do
        delete_iam_role "$role_name" "$profile"
    done
    
    # Delete roles WITH path prefix (these need the full path in the role name)
    for role_path in "${path_roles[@]}"; do
        delete_iam_role "$role_path" "$profile"
    done
    
    # Delete custom policies
    log_info "Deleting custom IAM policies..."
    
    # Policy paths to check (both root and /ecs/ambient/)
    local policy_paths=("" "ecs/ambient/")
    
    if [ "$account_type" == "local" ]; then
        # Local account policies
        for path in "${policy_paths[@]}"; do
            local path_prefix=""
            local display_prefix=""
            if [ -n "$path" ]; then
                path_prefix="${path}"
                display_prefix="/${path}"
            fi
            
            # eks-ecs-task-policy
            local policy_arn="arn:aws:iam::${account_id}:policy/${path_prefix}eks-ecs-task-policy"
            delete_iam_policy "$policy_arn" "$profile" "${display_prefix}eks-ecs-task-policy"
            
            # istiod-permission-policy (only in root path typically)
            if [ -z "$path" ]; then
                local policy_arn="arn:aws:iam::${account_id}:policy/istiod-permission-policy"
                delete_iam_policy "$policy_arn" "$profile" "istiod-permission-policy"
            fi
        done
    else
        # External account policies
        for path in "${policy_paths[@]}"; do
            local path_prefix=""
            local display_prefix=""
            if [ -n "$path" ]; then
                path_prefix="${path}"
                display_prefix="/${path}"
            fi
            
            local policy_arn="arn:aws:iam::${account_id}:policy/${path_prefix}eks-ecs-task-policy"
            delete_iam_policy "$policy_arn" "$profile" "${display_prefix}eks-ecs-task-policy"
        done
    fi
    
    echo ""
}

# Cleanup Infrastructure
cleanup_infrastructure() {
    log_section "=== Cleaning Up Infrastructure ==="
    
    # Delete VPC peering connection
    if resource_exists "$PEERING_ID"; then
        log_info "Deleting VPC peering connection: $PEERING_ID"
        if aws ec2 delete-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$INT" \
            --region "$AWS_REGION" 2>/dev/null; then
            DELETED_RESOURCES+=("VPC Peering: $PEERING_ID")
        fi
    else
        log_info "No VPC peering connection to delete"
    fi
    
    # Cleanup external VPC resources
    if resource_exists "$EXTERNAL_VPC"; then
        log_info "Cleaning up external VPC: $EXTERNAL_VPC"
        
        # Delete NAT Gateway
        if resource_exists "$EXTERNAL_NAT"; then
            log_info "  Deleting NAT Gateway: $EXTERNAL_NAT"
            if aws ec2 delete-nat-gateway \
                --nat-gateway-id "$EXTERNAL_NAT" \
                --profile "$EXT" \
                --region "$AWS_REGION" 2>/dev/null; then
                DELETED_RESOURCES+=("NAT Gateway: $EXTERNAL_NAT")
                
                log_info "  Waiting for NAT Gateway to delete (this may take 5-10 minutes)..."
                local max_wait=600  # 10 minutes
                local elapsed=0
                while [ $elapsed -lt $max_wait ]; do
                    local state=$(aws ec2 describe-nat-gateways \
                        --nat-gateway-ids "$EXTERNAL_NAT" \
                        --profile "$EXT" \
                        --region "$AWS_REGION" \
                        --query 'NatGateways[0].State' \
                        --output text 2>/dev/null || echo "deleted")
                    
                    if [ "$state" == "deleted" ] || [ "$state" == "None" ]; then
                        log_info "  NAT Gateway deleted"
                        break
                    fi
                    
                    sleep 15
                    elapsed=$((elapsed + 15))
                done
            fi
        fi
        
        # Release Elastic IP
        if resource_exists "$EXTERNAL_EIP"; then
            log_info "  Releasing Elastic IP: $EXTERNAL_EIP"
            if aws ec2 release-address \
                --allocation-id "$EXTERNAL_EIP" \
                --profile "$EXT" \
                --region "$AWS_REGION" 2>/dev/null; then
                DELETED_RESOURCES+=("Elastic IP: $EXTERNAL_EIP")
            fi
        fi
        
        # Detach and delete Internet Gateway
        if resource_exists "$EXTERNAL_IGW"; then
            log_info "  Detaching Internet Gateway: $EXTERNAL_IGW"
            aws ec2 detach-internet-gateway \
                --internet-gateway-id "$EXTERNAL_IGW" \
                --vpc-id "$EXTERNAL_VPC" \
                --profile "$EXT" \
                --region "$AWS_REGION" 2>/dev/null || true
            
            log_info "  Deleting Internet Gateway: $EXTERNAL_IGW"
            if aws ec2 delete-internet-gateway \
                --internet-gateway-id "$EXTERNAL_IGW" \
                --profile "$EXT" \
                --region "$AWS_REGION" 2>/dev/null; then
                DELETED_RESOURCES+=("Internet Gateway: $EXTERNAL_IGW")
            fi
        fi
        
        # Delete subnets
        log_info "  Deleting subnets..."
        for subnet in $EXTERNAL_SUBNET_1 $EXTERNAL_SUBNET_2 $EXTERNAL_SUBNET_3 $EXTERNAL_PUBLIC_SUBNET; do
            if resource_exists "$subnet"; then
                if aws ec2 delete-subnet \
                    --subnet-id "$subnet" \
                    --profile "$EXT" \
                    --region "$AWS_REGION" 2>/dev/null; then
                    DELETED_RESOURCES+=("Subnet: $subnet")
                fi
            fi
        done
        
        # Delete route tables (except main)
        log_info "  Deleting route tables..."
        for rt in $EXTERNAL_PRIVATE_RT $EXTERNAL_PUBLIC_RT; do
            if resource_exists "$rt"; then
                # Disassociate all subnets first
                local associations=$(aws ec2 describe-route-tables \
                    --route-table-ids "$rt" \
                    --profile "$EXT" \
                    --region "$AWS_REGION" \
                    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
                    --output text 2>/dev/null || echo "")
                
                for assoc in $associations; do
                    aws ec2 disassociate-route-table \
                        --association-id "$assoc" \
                        --profile "$EXT" \
                        --region "$AWS_REGION" 2>/dev/null || true
                done
                
                if aws ec2 delete-route-table \
                    --route-table-id "$rt" \
                    --profile "$EXT" \
                    --region "$AWS_REGION" 2>/dev/null; then
                    DELETED_RESOURCES+=("Route table: $rt")
                fi
            fi
        done
        
        # Delete security group
        if resource_exists "$EXTERNAL_SG"; then
            log_info "  Deleting security group: $EXTERNAL_SG"
            if aws ec2 delete-security-group \
                --group-id "$EXTERNAL_SG" \
                --profile "$EXT" \
                --region "$AWS_REGION" 2>/dev/null; then
                DELETED_RESOURCES+=("Security group: $EXTERNAL_SG")
            fi
        fi
        
        # Delete VPC
        log_info "  Deleting VPC: $EXTERNAL_VPC"
        if aws ec2 delete-vpc \
            --vpc-id "$EXTERNAL_VPC" \
            --profile "$EXT" \
            --region "$AWS_REGION" 2>/dev/null; then
            DELETED_RESOURCES+=("VPC: $EXTERNAL_VPC")
        fi
    else
        log_info "No external VPC to delete"
    fi
    
    echo ""
}

# Print summary
print_summary() {
    log_section "=== Cleanup Summary ==="
    
    if [ ${#DELETED_RESOURCES[@]} -gt 0 ]; then
        log_info "Successfully deleted ${#DELETED_RESOURCES[@]} resources:"
        for resource in "${DELETED_RESOURCES[@]}"; do
            echo "  ✓ $resource"
        done
    else
        log_warn "No resources were deleted (may have already been cleaned up)"
    fi
    
    echo ""
    
    if [ ${#FAILED_DELETIONS[@]} -gt 0 ]; then
        log_warn "Failed to delete ${#FAILED_DELETIONS[@]} resources:"
        for resource in "${FAILED_DELETIONS[@]}"; do
            echo "  ✗ $resource"
        done
    fi
    
    echo ""
    log_info "Cleanup complete!"
}

# Main execution
main() {
    log_section "=== ECS Multi-Account Cleanup Script ==="
    echo ""
    
    log_warn "This script will delete ALL resources created by the setup:"
    log_warn "  - Istio installation and mesh resources"
    log_warn "  - All ECS clusters and services (in both accounts)"
    log_warn "  - IAM roles and policies"
    log_warn "  - External VPC and all networking resources"
    log_warn "  - VPC peering connection"
    echo ""
    
    read -p "Are you sure you want to continue? (yes/no): " -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        log_info "Cleanup cancelled"
        exit 0
    fi
    
    validate_env
    
    # Cleanup in order (dependencies first)
    cleanup_istio
    cleanup_ecs "local" "1 2"
    cleanup_ecs "external" "3"
    cleanup_iam "local"
    cleanup_iam "external"
    cleanup_infrastructure
    
    print_summary
    
    log_info "Remember to delete the environment file if you no longer need it:"
    log_info "  rm /tmp/ecs-multi-account-env.sh"
}

# Run main function
main "$@"
