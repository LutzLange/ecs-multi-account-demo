#!/bin/bash

# cleanup.sh
# Unified cleanup script that adapts based on SCENARIO variable
# Supports:
#   SCENARIO=1: Clean up 1 cluster (local account)
#   SCENARIO=2: Clean up 2 clusters (local account)
#   SCENARIO=3: Clean up 3 clusters (2 local + 1 external account) + VPC peering

set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "${BLUE}[====]${NC} $1"; }

# Default configuration file
CONFIG_FILE="env-config.sh"

# Path to istioctl - use Solo.io distribution from ~/.istioctl/bin
ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"

# Track deleted resources
DELETED_RESOURCES=()

# Parse command line options
parse_options() {
    local TEMP
    TEMP=$(getopt -o c:yew --long config:,yes,eks,wait-for-deletion,no-wait-for-deletion -n 'cleanup.sh' -- "$@")

    if [ $? != 0 ]; then
        echo "Usage: $0 [-c config-file] [-y|--yes] [-e|--eks] [-w|--wait-for-deletion] [--no-wait-for-deletion]" >&2
        exit 1
    fi

    eval set -- "$TEMP"

    SKIP_CONFIRM=false
    DELETE_EKS=false
    WAIT_FOR_DELETION=true  # Enabled by default

    while true; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -y|--yes)
                SKIP_CONFIRM=true
                shift
                ;;
            -e|--eks)
                DELETE_EKS=true
                shift
                ;;
            -w|--wait-for-deletion)
                WAIT_FOR_DELETION=true
                shift
                ;;
            --no-wait-for-deletion)
                WAIT_FOR_DELETION=false
                shift
                ;;
            --)
                shift
                break
                ;;
            *)
                echo "Internal error!" >&2
                exit 1
                ;;
        esac
    done
}

# Load configuration file
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi

    log_info "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
}

# Validate scenario and set cluster configuration
validate_scenario() {
    if [ -z "$SCENARIO" ]; then
        log_error "SCENARIO variable not set in $CONFIG_FILE"
        exit 1
    fi

    case "$SCENARIO" in
        1)
            LOCAL_CLUSTERS="1"
            EXTERNAL_CLUSTERS=""
            log_info "Scenario 1: Cleaning up 1 cluster (local account)"
            ;;
        2)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS=""
            log_info "Scenario 2: Cleaning up 2 clusters (local account)"
            ;;
        3)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS="3"
            log_info "Scenario 3: Cleaning up 3 clusters (2 local + 1 external) + infrastructure"
            ;;
        *)
            log_error "Invalid SCENARIO value: $SCENARIO"
            exit 1
            ;;
    esac
}

# Check if resource exists
resource_exists() {
    [ -n "$1" ] && [ "$1" != "None" ] && [ "$1" != "null" ]
}

# Wait for CloudFormation stack deletion with progress updates
# Args: stack_name, aws_profile, max_wait_minutes (default 30)
wait_for_stack_deletion() {
    local stack_name=$1
    local aws_profile=$2
    local max_wait=${3:-30}
    local wait_time=0
    local interval=30

    while [ $wait_time -lt $((max_wait * 60)) ]; do
        local status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null)

        # Stack is gone
        if ! resource_exists "$status"; then
            log_info "    Stack $stack_name deleted successfully"
            return 0
        fi

        # Stack deletion failed
        if [ "$status" = "DELETE_FAILED" ]; then
            log_error "    Stack $stack_name deletion failed"
            log_error "    Check AWS CloudFormation console for details"
            return 1
        fi

        # Still deleting
        local elapsed_min=$((wait_time / 60))
        log_info "    Stack status: $status (${elapsed_min}m elapsed...)"

        sleep $interval
        wait_time=$((wait_time + interval))
    done

    log_warn "    Timeout waiting for stack $stack_name deletion after ${max_wait}m"
    return 1
}

# Confirmation prompt
confirm_cleanup() {
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi

    echo ""
    log_section "=== ECS Multi-Account Cleanup Script (Scenario $SCENARIO) ==="
    echo ""
    if [ "$DELETE_EKS" = true ]; then
        echo "CLEANUP MODE: Full cleanup (including EKS cluster deletion)"
    else
        echo "CLEANUP MODE: Retain EKS cluster (remove all deployments)"
    fi
    echo ""
    echo "This script will delete the following resources:"
    echo "  - Istio installation (istiod, ztunnel, east-west gateway + load balancer)"
    echo "  - Istio resources (authorization policies, waypoints)"
    echo "  - Kubernetes namespaces (ecs-${CLUSTER_NAME}-*)"
    echo "  - EKS test deployments (eks-shell, eks-echo)"
    for cluster_num in $LOCAL_CLUSTERS; do
        echo "  - ECS cluster: ecs-${CLUSTER_NAME}-${cluster_num} (local account)"
    done
    for cluster_num in $EXTERNAL_CLUSTERS; do
        echo "  - ECS cluster: ecs-${CLUSTER_NAME}-${cluster_num} (external account)"
    done
    echo "  - IAM roles and policies"
    if [ "$SCENARIO" = "3" ]; then
        echo "  - VPC peering connection"
        echo "  - External VPC and all networking resources"
    fi
    if [ "$DELETE_EKS" = true ]; then
        echo "  - EKS cluster: ${CLUSTER_NAME} (and all CloudFormation stacks)"
    fi
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirm

    if [ "$confirm" != "yes" ]; then
        log_info "Cleanup cancelled."
        exit 0
    fi
}

# Clean up Istio resources
cleanup_istio() {
    log_section "=== Cleaning Up Istio Resources ==="

    # Remove authorization policies
    log_info "Removing authorization policies..."
    for cluster_num in $LOCAL_CLUSTERS $EXTERNAL_CLUSTERS; do
        local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
        kubectl delete authorizationpolicy --all -n "$namespace" 2>/dev/null || true
        DELETED_RESOURCES+=("AuthorizationPolicy: $namespace/*")
    done

    # Remove waypoint proxies
    log_info "Removing waypoint proxies..."
    for cluster_num in $LOCAL_CLUSTERS $EXTERNAL_CLUSTERS; do
        local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
        if [ -f "$ISTIOCTL" ]; then
            "$ISTIOCTL" waypoint delete --all -n "$namespace" 2>/dev/null || true
        fi
    done

    # Remove EKS test deployments
    log_info "Removing EKS test deployments..."
    kubectl delete -f manifests/eks-shell.yaml 2>/dev/null || true
    kubectl delete -f manifests/eks-echo.yaml 2>/dev/null || true
    kubectl label namespace default istio.io/dataplane-mode- 2>/dev/null || true
    DELETED_RESOURCES+=("Deployment: eks-shell, eks-echo")
}

# Uninstall Istio completely (including east-west gateway and load balancer)
uninstall_istio() {
    log_section "=== Uninstalling Istio ==="

    if ! kubectl get namespace istio-system &>/dev/null; then
        log_info "Istio is not installed, skipping uninstall"
        return 0
    fi

    # Uninstall Istio using istioctl (this removes east-west gateway and its load balancer)
    if [ -f "$ISTIOCTL" ]; then
        log_info "Uninstalling Istio with istioctl (removes east-west gateway load balancer)..."
        "$ISTIOCTL" uninstall --purge -y 2>/dev/null || true
        DELETED_RESOURCES+=("Istio installation (including east-west gateway)")
    else
        log_warn "istioctl not found at $ISTIOCTL, attempting manual cleanup"
    fi

    # Wait for load balancer to be deleted
    log_info "Waiting for east-west gateway load balancer to be deleted..."
    local wait_count=0
    while kubectl get svc -n istio-system istio-eastwest &>/dev/null 2>&1; do
        if [ $wait_count -ge 30 ]; then
            log_warn "Timed out waiting for load balancer deletion, continuing..."
            break
        fi
        sleep 10
        wait_count=$((wait_count + 1))
    done

    # Delete istio-system namespace to ensure all resources are cleaned up
    log_info "Deleting istio-system namespace..."
    kubectl delete namespace istio-system --timeout=120s 2>/dev/null || true
    DELETED_RESOURCES+=("Namespace: istio-system")

    # Delete istio-eastwest namespace if it exists
    if kubectl get namespace istio-eastwest &>/dev/null 2>&1; then
        log_info "Deleting istio-eastwest namespace..."
        kubectl delete namespace istio-eastwest --timeout=60s 2>/dev/null || true
        DELETED_RESOURCES+=("Namespace: istio-eastwest")
    fi

    # Delete Gateway API CRDs if they exist
    log_info "Cleaning up Gateway API resources..."
    kubectl delete gateways.gateway.networking.k8s.io --all -A 2>/dev/null || true
    kubectl delete httproutes.gateway.networking.k8s.io --all -A 2>/dev/null || true

    log_info "Istio uninstalled successfully"
}

# Clean up Kubernetes namespaces
cleanup_namespaces() {
    log_section "=== Cleaning Up Kubernetes Namespaces ==="

    for cluster_num in $LOCAL_CLUSTERS $EXTERNAL_CLUSTERS; do
        local namespace="ecs-${CLUSTER_NAME}-${cluster_num}"
        log_info "Deleting namespace: $namespace"
        kubectl delete namespace "$namespace" 2>/dev/null || true
        DELETED_RESOURCES+=("Namespace: $namespace")
    done
}

# Wait for ECS service to reach INACTIVE state
# Services go through: ACTIVE -> DRAINING -> INACTIVE
# We need to wait for INACTIVE before recreating or deleting the cluster
wait_for_service_inactive() {
    local cluster_name=$1
    local service_name=$2
    local aws_profile=$3
    local max_wait=180  # 3 minutes max
    local wait_time=0

    while [ $wait_time -lt $max_wait ]; do
        local status=$(aws ecs describe-services \
            --cluster "$cluster_name" \
            --services "$service_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'services[0].status' \
            --output text 2>/dev/null)

        # Service is gone or INACTIVE - we're done
        if [ -z "$status" ] || [ "$status" = "None" ] || [ "$status" = "INACTIVE" ]; then
            return 0
        fi

        sleep 10
        wait_time=$((wait_time + 10))
        log_info "      Service $service_name status: $status (waiting... ${wait_time}s)"
    done

    log_warn "      Timeout waiting for service $service_name to become INACTIVE"
    return 1
}

# Wait for ECS cluster to be fully deleted
# Clusters go through: ACTIVE -> INACTIVE -> fully removed
# We need to wait until describe-clusters returns empty or MISSING
wait_for_cluster_deleted() {
    local cluster_name=$1
    local aws_profile=$2
    local max_wait=120  # 2 minutes max
    local wait_time=0

    log_info "  Waiting for cluster $cluster_name to be fully deleted..."

    while [ $wait_time -lt $max_wait ]; do
        local status=$(aws ecs describe-clusters \
            --clusters "$cluster_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'clusters[0].status' \
            --output text 2>/dev/null)

        # Cluster is gone or INACTIVE is acceptable for our purposes
        # (INACTIVE clusters don't block name reuse after ~60s)
        if [ -z "$status" ] || [ "$status" = "None" ] || [ "$status" = "INACTIVE" ]; then
            # For INACTIVE, give AWS a bit more time to fully process
            if [ "$status" = "INACTIVE" ]; then
                log_info "    Cluster is INACTIVE, waiting 30s for AWS to fully process..."
                sleep 30
            fi
            log_info "  Cluster $cluster_name deleted"
            return 0
        fi

        sleep 10
        wait_time=$((wait_time + 10))
        log_info "    Cluster status: $status (waiting... ${wait_time}s)"
    done

    log_warn "  Timeout waiting for cluster $cluster_name to be deleted"
    return 1
}

# Clean up ECS resources in an account
cleanup_ecs_account() {
    local account_type=$1
    local cluster_numbers=$2
    local aws_profile=$3

    log_section "=== Cleaning Up ECS Resources in ${account_type^^} Account ==="

    for cluster_num in $cluster_numbers; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        log_info "Processing cluster: $cluster_name"

        # Get all services (ACTIVE only from list-services)
        local services=$(aws ecs list-services \
            --cluster "$cluster_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'serviceArns[]' \
            --output text 2>/dev/null)

        local service_names=""

        if [ -n "$services" ] && [ "$services" != "None" ]; then
            log_info "  Deleting services in $cluster_name..."
            for service_arn in $services; do
                local service_name=$(basename "$service_arn")
                service_names="$service_names $service_name"
                log_info "    Deleting service: $service_name"

                # Scale down first
                aws ecs update-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --desired-count 0 \
                    --profile "$aws_profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1 || true

                # Delete service (--force stops running tasks)
                aws ecs delete-service \
                    --cluster "$cluster_name" \
                    --service "$service_name" \
                    --force \
                    --profile "$aws_profile" \
                    --region "$AWS_REGION" \
                    --no-cli-pager > /dev/null 2>&1 || true

                DELETED_RESOURCES+=("ECS Service: $cluster_name/$service_name")
            done

            # Wait for each service to reach INACTIVE state
            # Services transition: ACTIVE -> DRAINING -> INACTIVE
            # We must wait for INACTIVE before recreating services with same name
            log_info "  Waiting for services to reach INACTIVE state..."
            for service_name in $service_names; do
                wait_for_service_inactive "$cluster_name" "$service_name" "$aws_profile"
            done
        fi

        # Delete cluster (will transition to INACTIVE)
        log_info "  Deleting cluster: $cluster_name"
        aws ecs delete-cluster \
            --cluster "$cluster_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --no-cli-pager > /dev/null 2>&1 || true

        # Wait for cluster to be fully deleted before proceeding
        wait_for_cluster_deleted "$cluster_name" "$aws_profile"

        DELETED_RESOURCES+=("ECS Cluster: $cluster_name")
    done

    # Delete task definitions
    log_info "Deregistering task definitions..."
    for family in "shell-task-definition" "echo-service-definition"; do
        local task_defs=$(aws ecs list-task-definitions \
            --family-prefix "$family" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'taskDefinitionArns[]' \
            --output text 2>/dev/null)

        for task_def in $task_defs; do
            aws ecs deregister-task-definition \
                --task-definition "$task_def" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1 || true
        done
    done

    # Delete CloudWatch log group
    log_info "Deleting CloudWatch log group..."
    aws logs delete-log-group \
        --log-group-name "/ecs/ecs-demo" \
        --profile "$aws_profile" \
        --region "$AWS_REGION" 2>/dev/null || true
}

# Clean up ECS security group in local account (created by deploy-ecs-clusters.sh)
cleanup_local_ecs_security_group() {
    log_section "=== Cleaning Up Local ECS Security Group ==="

    local sg_name="ecs-${CLUSTER_NAME}-sg"

    # Find the security group by name
    local sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$sg_name" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if resource_exists "$sg_id" && [ "$sg_id" != "None" ]; then
        log_info "Deleting ECS security group: $sg_name ($sg_id)"

        # Remove all ingress rules first
        local ingress_rules=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].IpPermissions' \
            --output json 2>/dev/null)

        if [ -n "$ingress_rules" ] && [ "$ingress_rules" != "[]" ] && [ "$ingress_rules" != "null" ]; then
            aws ec2 revoke-security-group-ingress \
                --group-id "$sg_id" \
                --ip-permissions "$ingress_rules" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
        fi

        # Remove all egress rules
        local egress_rules=$(aws ec2 describe-security-groups \
            --group-ids "$sg_id" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].IpPermissionsEgress' \
            --output json 2>/dev/null)

        if [ -n "$egress_rules" ] && [ "$egress_rules" != "[]" ] && [ "$egress_rules" != "null" ]; then
            aws ec2 revoke-security-group-egress \
                --group-id "$sg_id" \
                --ip-permissions "$egress_rules" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
        fi

        # Delete the security group
        aws ec2 delete-security-group \
            --group-id "$sg_id" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true

        DELETED_RESOURCES+=("Security Group: $sg_name ($sg_id)")
    else
        log_info "ECS security group $sg_name not found (already deleted)"
    fi
}

# Clean up IAM resources
cleanup_iam() {
    local account_type=$1
    local aws_profile=$2

    log_section "=== Cleaning Up IAM Resources in ${account_type^^} Account ==="

    local role_name="eks-ecs-task-role"
    local policy_name="eks-ecs-task-policy"

    # Get policy ARN
    local policy_arn=$(aws iam list-policies \
        --profile "$aws_profile" \
        --query "Policies[?PolicyName=='$policy_name'].Arn" \
        --output text 2>/dev/null)

    # Detach policy from role
    if resource_exists "$policy_arn"; then
        log_info "Detaching policy from role..."
        aws iam detach-role-policy \
            --role-name "$role_name" \
            --policy-arn "$policy_arn" \
            --profile "$aws_profile" 2>/dev/null || true
    fi

    # Delete role
    log_info "Deleting role: $role_name"
    aws iam delete-role \
        --role-name "$role_name" \
        --profile "$aws_profile" 2>/dev/null || true
    DELETED_RESOURCES+=("IAM Role: $role_name ($account_type)")

    # Delete policy
    if resource_exists "$policy_arn"; then
        log_info "Deleting policy: $policy_name"
        aws iam delete-policy \
            --policy-arn "$policy_arn" \
            --profile "$aws_profile" 2>/dev/null || true
        DELETED_RESOURCES+=("IAM Policy: $policy_name ($account_type)")
    fi
}

# Clean up Istiod IAM roles (local account)
# For all scenarios, we create istiod-local role
# For scenario 3, we also create istiod-role
cleanup_istiod_iam_local() {
    log_section "=== Cleaning Up Istiod IAM Roles (Local Account) ==="

    # Clean up istiod-local (created for all scenarios)
    log_info "Processing role: istiod-local (local account)"

    # Detach policies from istiod-local
    local attached=$(aws iam list-attached-role-policies \
        --role-name "istiod-local" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --query 'AttachedPolicies[*].PolicyArn' \
        --output text 2>/dev/null)

    for policy_arn in $attached; do
        aws iam detach-role-policy \
            --role-name "istiod-local" \
            --policy-arn "$policy_arn" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
    done

    # Delete istiod-local role
    aws iam delete-role \
        --role-name "istiod-local" \
        --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
    DELETED_RESOURCES+=("IAM Role: istiod-local (local)")

    # For scenarios 1 & 2, remove inline policy from eksctl-created role
    if [ "$SCENARIO" != "3" ]; then
        local eksctl_role="istiod-eks-ecs-${CLUSTER_NAME}"
        log_info "Removing inline policy from $eksctl_role..."
        aws iam delete-role-policy \
            --role-name "$eksctl_role" \
            --policy-name "AssumeIstiodLocal" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        DELETED_RESOURCES+=("IAM Inline Policy: AssumeIstiodLocal from $eksctl_role")
    fi

    # For scenario 3, also clean up istiod-role and related resources
    if [ "$SCENARIO" = "3" ]; then
        log_info "Processing role: istiod-role (local account)"

        # Detach policies from istiod-role
        attached=$(aws iam list-attached-role-policies \
            --role-name "istiod-role" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --query 'AttachedPolicies[*].PolicyArn' \
            --output text 2>/dev/null)

        for policy_arn in $attached; do
            aws iam detach-role-policy \
                --role-name "istiod-role" \
                --policy-arn "$policy_arn" \
                --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        done

        # Delete istiod-role
        aws iam delete-role \
            --role-name "istiod-role" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        DELETED_RESOURCES+=("IAM Role: istiod-role (local)")

        # Delete istiod-permission-policy
        local policy_arn="arn:aws:iam::${LOCAL_ACCOUNT}:policy/istiod-permission-policy"
        aws iam delete-policy \
            --policy-arn "$policy_arn" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        DELETED_RESOURCES+=("IAM Policy: istiod-permission-policy (local)")

        # Delete pod identity association (only for scenario 3 where we update it)
        log_info "Deleting pod identity association..."
        local assoc_id=$(aws eks list-pod-identity-associations \
            --cluster-name "$CLUSTER_NAME" \
            --namespace istio-system \
            --service-account istiod \
            --query 'associations[0].associationId' \
            --output text \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || echo "")

        if [ -n "$assoc_id" ] && [ "$assoc_id" != "None" ]; then
            aws eks delete-pod-identity-association \
                --cluster-name "$CLUSTER_NAME" \
                --association-id "$assoc_id" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
            DELETED_RESOURCES+=("Pod Identity Association: $assoc_id")
        fi
    fi
}

# Clean up Istiod IAM roles (external account - scenario 3 only)
cleanup_istiod_iam_external() {
    log_section "=== Cleaning Up Istiod IAM Roles (External Account) ==="

    # Clean up in external account
    log_info "Processing role: istiod-external (external account)"
    local attached=$(aws iam list-attached-role-policies \
        --role-name "istiod-external" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" \
        --query 'AttachedPolicies[*].PolicyArn' \
        --output text 2>/dev/null)

    for policy_arn in $attached; do
        aws iam detach-role-policy \
            --role-name "istiod-external" \
            --policy-arn "$policy_arn" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    done

    aws iam delete-role \
        --role-name "istiod-external" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    DELETED_RESOURCES+=("IAM Role: istiod-external (external)")
}

# Clean up VPC peering (only for scenario 3)
cleanup_vpc_peering() {
    log_section "=== Cleaning Up VPC Peering ==="

    # Method 1: Use PEERING_ID from config if available
    if resource_exists "$PEERING_ID"; then
        log_info "Deleting VPC peering connection from config: $PEERING_ID"
        aws ec2 delete-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true
        DELETED_RESOURCES+=("VPC Peering: $PEERING_ID")
    fi

    # Method 2: Find and delete peerings associated with the EKS VPC
    local eks_vpc=""
    eks_vpc=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text 2>/dev/null)

    if [ -z "$eks_vpc" ] || [ "$eks_vpc" = "None" ]; then
        # Try CloudFormation stack
        eks_vpc=$(aws cloudformation describe-stack-resource \
            --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
            --logical-resource-id VPC \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'StackResourceDetail.PhysicalResourceId' \
            --output text 2>/dev/null)
    fi

    if resource_exists "$eks_vpc"; then
        log_info "Finding VPC peerings for EKS VPC: $eks_vpc"

        # Find peerings where EKS VPC is requester (local account)
        local peerings=$(aws ec2 describe-vpc-peering-connections \
            --filters "Name=requester-vpc-info.vpc-id,Values=$eks_vpc" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "VpcPeeringConnections[?Status.Code!='deleted'].VpcPeeringConnectionId" \
            --output text 2>/dev/null)

        for peering in $peerings; do
            if [ -n "$peering" ] && [ "$peering" != "None" ] && [ "$peering" != "$PEERING_ID" ]; then
                log_info "Deleting peering (EKS as requester): $peering"
                aws ec2 delete-vpc-peering-connection \
                    --vpc-peering-connection-id "$peering" \
                    --profile "$LOCAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" 2>/dev/null || true
                DELETED_RESOURCES+=("VPC Peering: $peering")
            fi
        done

        # Find peerings where EKS VPC is accepter (shouldn't happen normally but check anyway)
        peerings=$(aws ec2 describe-vpc-peering-connections \
            --filters "Name=accepter-vpc-info.vpc-id,Values=$eks_vpc" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "VpcPeeringConnections[?Status.Code!='deleted'].VpcPeeringConnectionId" \
            --output text 2>/dev/null)

        for peering in $peerings; do
            if [ -n "$peering" ] && [ "$peering" != "None" ] && [ "$peering" != "$PEERING_ID" ]; then
                log_info "Deleting peering (EKS as accepter): $peering"
                aws ec2 delete-vpc-peering-connection \
                    --vpc-peering-connection-id "$peering" \
                    --profile "$LOCAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" 2>/dev/null || true
                DELETED_RESOURCES+=("VPC Peering: $peering")
            fi
        done
    fi

    # Method 3: Clean up peerings on external account side to external VPC
    if resource_exists "$EXTERNAL_VPC"; then
        log_info "Finding VPC peerings to external VPC: $EXTERNAL_VPC"

        local peerings=$(aws ec2 describe-vpc-peering-connections \
            --filters "Name=accepter-vpc-info.vpc-id,Values=$EXTERNAL_VPC" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "VpcPeeringConnections[?Status.Code!='deleted'].VpcPeeringConnectionId" \
            --output text 2>/dev/null)

        for peering in $peerings; do
            if [ -n "$peering" ] && [ "$peering" != "None" ]; then
                log_info "Deleting peering to external VPC: $peering"
                aws ec2 delete-vpc-peering-connection \
                    --vpc-peering-connection-id "$peering" \
                    --profile "$EXTERNAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" 2>/dev/null || true
                DELETED_RESOURCES+=("VPC Peering: $peering (external)")
            fi
        done
    fi
}

# Clean up external VPC (only for scenario 3)
cleanup_external_vpc() {
    log_section "=== Cleaning Up External VPC ==="

    if ! resource_exists "$EXTERNAL_VPC"; then
        log_warn "No external VPC found to delete"
        return
    fi

    log_info "Cleaning up external VPC: $EXTERNAL_VPC"

    # Delete NAT Gateway
    if resource_exists "$EXTERNAL_NAT"; then
        log_info "  Deleting NAT Gateway: $EXTERNAL_NAT"
        aws ec2 delete-nat-gateway \
            --nat-gateway-id "$EXTERNAL_NAT" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_info "  Waiting for NAT Gateway to delete (this may take 5-10 minutes)..."
        aws ec2 wait nat-gateway-deleted \
            --nat-gateway-ids "$EXTERNAL_NAT" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || sleep 60

        DELETED_RESOURCES+=("NAT Gateway: $EXTERNAL_NAT")
    fi

    # Release Elastic IP
    if resource_exists "$EXTERNAL_EIP"; then
        log_info "  Releasing Elastic IP: $EXTERNAL_EIP"
        aws ec2 release-address \
            --allocation-id "$EXTERNAL_EIP" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true
        DELETED_RESOURCES+=("Elastic IP: $EXTERNAL_EIP")
    fi

    # Detach and delete Internet Gateway
    if resource_exists "$EXTERNAL_IGW"; then
        log_info "  Detaching Internet Gateway: $EXTERNAL_IGW"
        aws ec2 detach-internet-gateway \
            --internet-gateway-id "$EXTERNAL_IGW" \
            --vpc-id "$EXTERNAL_VPC" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_info "  Deleting Internet Gateway: $EXTERNAL_IGW"
        aws ec2 delete-internet-gateway \
            --internet-gateway-id "$EXTERNAL_IGW" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true
        DELETED_RESOURCES+=("Internet Gateway: $EXTERNAL_IGW")
    fi

    # Delete subnets
    for subnet in "$EXTERNAL_SUBNET_1" "$EXTERNAL_SUBNET_2" "$EXTERNAL_SUBNET_3" "$EXTERNAL_PUBLIC_SUBNET"; do
        if resource_exists "$subnet"; then
            log_info "  Deleting subnet: $subnet"
            aws ec2 delete-subnet \
                --subnet-id "$subnet" \
                --profile "$EXTERNAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
            DELETED_RESOURCES+=("Subnet: $subnet")
        fi
    done

    # Delete route tables
    for rt in "$EXTERNAL_PUBLIC_RT" "$EXTERNAL_PRIVATE_RT"; do
        if resource_exists "$rt"; then
            log_info "  Deleting route table: $rt"
            aws ec2 delete-route-table \
                --route-table-id "$rt" \
                --profile "$EXTERNAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
            DELETED_RESOURCES+=("Route Table: $rt")
        fi
    done

    # Delete security group
    if resource_exists "$EXTERNAL_SG"; then
        log_info "  Deleting security group: $EXTERNAL_SG"
        aws ec2 delete-security-group \
            --group-id "$EXTERNAL_SG" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true
        DELETED_RESOURCES+=("Security Group: $EXTERNAL_SG")
    fi

    # Delete VPC
    log_info "  Deleting VPC: $EXTERNAL_VPC"
    aws ec2 delete-vpc \
        --vpc-id "$EXTERNAL_VPC" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || true
    DELETED_RESOURCES+=("VPC: $EXTERNAL_VPC")
}

# Clean up EKS cluster (only when -e/--eks flag is used)
cleanup_eks_cluster() {
    log_section "=== Cleaning Up EKS Cluster ==="

    # Check if EKS cluster exists
    local cluster_status=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --query 'cluster.status' \
        --output text 2>/dev/null)

    if ! resource_exists "$cluster_status"; then
        log_info "EKS cluster '$CLUSTER_NAME' does not exist, checking for orphaned CloudFormation stacks..."

        # Check for orphaned CloudFormation stacks
        local stack_status=$(aws cloudformation describe-stacks \
            --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null)

        if resource_exists "$stack_status"; then
            log_info "Found orphaned CloudFormation stack (status: $stack_status), cleaning up..."
            # Skip to CloudFormation cleanup below
        else
            log_info "No EKS cluster or CloudFormation stacks found, nothing to clean up"
            return 0
        fi
    else
        log_info "EKS cluster '$CLUSTER_NAME' found (status: $cluster_status)"
        # Istio is already uninstalled by uninstall_istio() earlier in the cleanup process
    fi

    # Find and delete any remaining load balancers in the EKS VPC
    # These can block CloudFormation stack deletion
    log_info "Checking for remaining load balancers in EKS VPC..."

    # Try to get VPC ID from the cluster first
    local eks_vpc=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text 2>/dev/null)

    # If cluster doesn't exist, try to get VPC ID from CloudFormation stack
    if ! resource_exists "$eks_vpc"; then
        eks_vpc=$(aws cloudformation describe-stack-resource \
            --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
            --logical-resource-id VPC \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'StackResourceDetail.PhysicalResourceId' \
            --output text 2>/dev/null)
    fi

    if resource_exists "$eks_vpc"; then
        log_info "  EKS VPC: $eks_vpc"

        # Find classic load balancers in this VPC
        local elbs=$(aws elb describe-load-balancers \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "LoadBalancerDescriptions[?VPCId=='$eks_vpc'].LoadBalancerName" \
            --output text 2>/dev/null)

        for elb in $elbs; do
            log_info "  Deleting classic load balancer: $elb"
            aws elb delete-load-balancer \
                --load-balancer-name "$elb" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
            DELETED_RESOURCES+=("Classic LB: $elb")
        done

        # Find ALB/NLB load balancers in this VPC
        local v2_lbs=$(aws elbv2 describe-load-balancers \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "LoadBalancers[?VpcId=='$eks_vpc'].LoadBalancerArn" \
            --output text 2>/dev/null)

        for lb_arn in $v2_lbs; do
            local lb_name=$(basename "$lb_arn")
            log_info "  Deleting load balancer: $lb_name"
            aws elbv2 delete-load-balancer \
                --load-balancer-arn "$lb_arn" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" 2>/dev/null || true
            DELETED_RESOURCES+=("Load Balancer: $lb_name")
        done

        # Wait for load balancers to be fully deleted
        local has_lbs=false
        if [ -n "$elbs" ] && [ "$elbs" != "None" ]; then
            has_lbs=true
        fi
        if [ -n "$v2_lbs" ] && [ "$v2_lbs" != "None" ]; then
            has_lbs=true
        fi
        if [ "$has_lbs" = true ]; then
            log_info "  Waiting 60s for load balancers to fully delete (releases ENIs and SGs)..."
            sleep 60
        fi

        # Delete orphaned security groups (left behind by load balancers)
        # These block VPC deletion. Skip the default security group.
        # IMPORTANT: Must remove rules first since SGs can reference each other
        log_info "  Checking for orphaned security groups..."
        local security_groups=$(aws ec2 describe-security-groups \
            --filters "Name=vpc-id,Values=$eks_vpc" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query "SecurityGroups[?GroupName!='default'].GroupId" \
            --output text 2>/dev/null)

        # Step 1: Remove all rules from security groups (they may reference each other)
        log_info "  Removing security group rules..."
        for sg in $security_groups; do
            if [ -n "$sg" ] && [ "$sg" != "None" ]; then
                # Remove all ingress rules
                local ingress_rules=$(aws ec2 describe-security-groups \
                    --group-ids "$sg" \
                    --profile "$LOCAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'SecurityGroups[0].IpPermissions' \
                    --output json 2>/dev/null)

                if [ -n "$ingress_rules" ] && [ "$ingress_rules" != "[]" ] && [ "$ingress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-ingress \
                        --group-id "$sg" \
                        --ip-permissions "$ingress_rules" \
                        --profile "$LOCAL_ACCOUNT_PROFILE" \
                        --region "$AWS_REGION" 2>/dev/null || true
                fi

                # Remove all egress rules
                local egress_rules=$(aws ec2 describe-security-groups \
                    --group-ids "$sg" \
                    --profile "$LOCAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" \
                    --query 'SecurityGroups[0].IpPermissionsEgress' \
                    --output json 2>/dev/null)

                if [ -n "$egress_rules" ] && [ "$egress_rules" != "[]" ] && [ "$egress_rules" != "null" ]; then
                    aws ec2 revoke-security-group-egress \
                        --group-id "$sg" \
                        --ip-permissions "$egress_rules" \
                        --profile "$LOCAL_ACCOUNT_PROFILE" \
                        --region "$AWS_REGION" 2>/dev/null || true
                fi
            fi
        done

        # Step 2: Delete security groups (now that rules are removed)
        log_info "  Deleting security groups..."
        for sg in $security_groups; do
            if [ -n "$sg" ] && [ "$sg" != "None" ]; then
                log_info "    Deleting SG: $sg"
                aws ec2 delete-security-group \
                    --group-id "$sg" \
                    --profile "$LOCAL_ACCOUNT_PROFILE" \
                    --region "$AWS_REGION" 2>/dev/null || true
                DELETED_RESOURCES+=("Security Group: $sg")
            fi
        done
    fi

    # Delete the EKS cluster using eksctl
    log_info "Deleting EKS cluster: $CLUSTER_NAME"
    if ! eksctl delete cluster \
        --name "$CLUSTER_NAME" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION"; then

        log_warn "eksctl delete cluster failed, attempting to delete CloudFormation stacks directly..."

        # Delete nodegroup stack first
        local nodegroup_stack="eksctl-${CLUSTER_NAME}-nodegroup-managed-nodes"
        log_info "  Deleting nodegroup stack: $nodegroup_stack"
        aws cloudformation delete-stack \
            --stack-name "$nodegroup_stack" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_info "  Waiting for nodegroup stack deletion (this may take 5-10 minutes)..."
        wait_for_stack_deletion "$nodegroup_stack" "$LOCAL_ACCOUNT_PROFILE" 15

        # Delete cluster stack
        local cluster_stack="eksctl-${CLUSTER_NAME}-cluster"
        log_info "  Deleting cluster stack: $cluster_stack"
        aws cloudformation delete-stack \
            --stack-name "$cluster_stack" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" 2>/dev/null || true

        log_info "  Waiting for cluster stack deletion (this may take 10-15 minutes)..."
        wait_for_stack_deletion "$cluster_stack" "$LOCAL_ACCOUNT_PROFILE" 20
    fi

    # Wait for CloudFormation stacks to be fully deleted (eksctl uses async deletion for cluster)
    if [ "$WAIT_FOR_DELETION" = true ]; then
        log_info "Waiting for all CloudFormation stacks to be fully deleted..."

        local cluster_stack="eksctl-${CLUSTER_NAME}-cluster"
        local nodegroup_stack="eksctl-${CLUSTER_NAME}-nodegroup-managed-nodes"
        local addon_stack="eksctl-${CLUSTER_NAME}-addon-vpc-cni"
        local podidentity_stack="eksctl-${CLUSTER_NAME}-podidentityrole-istio-system-istiod"

        # Wait for each stack (they may already be deleted)
        for stack in "$nodegroup_stack" "$addon_stack" "$podidentity_stack" "$cluster_stack"; do
            local stack_status=$(aws cloudformation describe-stacks \
                --stack-name "$stack" \
                --profile "$LOCAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" \
                --query 'Stacks[0].StackStatus' \
                --output text 2>/dev/null)

            if [ -n "$stack_status" ] && [ "$stack_status" != "None" ]; then
                log_info "  Waiting for $stack (status: $stack_status)..."
                wait_for_stack_deletion "$stack" "$LOCAL_ACCOUNT_PROFILE" 20
            fi
        done

        log_info "All CloudFormation stacks deleted"
    else
        log_info "Skipping wait for CloudFormation stack deletion (--no-wait-for-deletion)"
    fi

    DELETED_RESOURCES+=("EKS Cluster: $CLUSTER_NAME")
}

# Clear progress tracking from config file and progress files
clear_progress_tracking() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Clearing progress tracking from config file..."
        # Remove COMPLETED_STEPS line from config file
        sed -i '/^COMPLETED_STEPS=/d' "$CONFIG_FILE"
        sed -i '/^export COMPLETED_STEPS=/d' "$CONFIG_FILE"
    fi

    # Delete the workshop progress file for this scenario
    local progress_file=".workshop-progress-sc${SCENARIO}"
    if [ -f "$progress_file" ]; then
        log_info "Removing progress file: $progress_file"
        rm -f "$progress_file"
        DELETED_RESOURCES+=("Progress file: $progress_file")
    fi
}

# Print summary
print_summary() {
    log_section "=== Cleanup Summary ==="

    if [ ${#DELETED_RESOURCES[@]} -eq 0 ]; then
        log_warn "No resources were deleted"
    else
        log_info "Successfully deleted ${#DELETED_RESOURCES[@]} resources:"
        for resource in "${DELETED_RESOURCES[@]}"; do
            echo "  ✓ $resource"
        done
    fi

    echo ""
    log_info "Cleanup complete!"

    if [ "$DELETE_EKS" != true ]; then
        echo ""
        echo "Remaining manual steps:"
        echo "  - Delete EKS cluster: $0 -c $CONFIG_FILE -e"
        echo "  - Or: eksctl delete cluster -n ${CLUSTER_NAME} --profile $LOCAL_ACCOUNT_PROFILE --region $AWS_REGION"
    fi
}

# Main execution
main() {
    parse_options "$@"
    load_config
    validate_scenario
    confirm_cleanup

    # Clean up Istio policies and test deployments
    cleanup_istio
    cleanup_namespaces

    # Uninstall Istio completely (always, not just when deleting EKS)
    # This ensures a clean state for re-running the workshop
    uninstall_istio

    # Clean up ECS in local account
    if [ -n "$LOCAL_CLUSTERS" ]; then
        cleanup_ecs_account "local" "$LOCAL_CLUSTERS" "$LOCAL_ACCOUNT_PROFILE"
        cleanup_iam "local" "$LOCAL_ACCOUNT_PROFILE"
        cleanup_local_ecs_security_group
    fi

    # Clean up Istiod IAM roles in local account (all scenarios)
    cleanup_istiod_iam_local

    # Clean up ECS in external account (only for scenario 3)
    if [ -n "$EXTERNAL_CLUSTERS" ]; then
        cleanup_ecs_account "external" "$EXTERNAL_CLUSTERS" "$EXTERNAL_ACCOUNT_PROFILE"
        cleanup_iam "external" "$EXTERNAL_ACCOUNT_PROFILE"
        cleanup_istiod_iam_external
        cleanup_vpc_peering
        cleanup_external_vpc
    fi

    # Clean up EKS cluster (only when -e/--eks flag is used)
    if [ "$DELETE_EKS" = true ]; then
        cleanup_eks_cluster
    fi

    # Clear progress tracking from config file
    # This ensures the test script starts fresh after cleanup
    clear_progress_tracking

    print_summary
}

# Run main function
main "$@"
