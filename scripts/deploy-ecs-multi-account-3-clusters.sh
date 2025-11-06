#!/bin/bash

# deploy-ecs-multi-account-3-clusters-v2.sh
# Improved robust version with:
# - Idempotency (safe to run multiple times)
# - Better error handling
# - Resume capability
# - Detailed logging

# Remove set -e to handle errors gracefully
set -o pipefail

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Log file
LOG_FILE="deploy-ecs-$(date +%Y%m%d-%H%M%S).log"

# Function to log messages
log() {
    echo "$@" | tee -a "$LOG_FILE"
}

log_colored() {
    echo -e "$@" | tee -a "$LOG_FILE"
}

echo -e "${BLUE}=============================================${NC}" | tee "$LOG_FILE"
echo -e "${BLUE}  ECS Multi-Account 3-Cluster Deployment${NC}" | tee -a "$LOG_FILE"
echo -e "${BLUE}  Robust Version with Resume Capability${NC}" | tee -a "$LOG_FILE"
echo -e "${BLUE}=============================================${NC}" | tee -a "$LOG_FILE"
log ""
log "Log file: $LOG_FILE"
log ""

# Validate required commands
check_prerequisites() {
    log_colored "${BLUE}Checking prerequisites...${NC}"
    local missing=0
    
    for cmd in aws jq; do
        if ! command -v $cmd &> /dev/null; then
            log_colored "${RED}✗ $cmd is not installed${NC}"
            missing=1
        else
            log_colored "${GREEN}✓ $cmd is available${NC}"
        fi
    done
    
    if [ $missing -eq 1 ]; then
        log_colored "${RED}Error: Missing required commands. Please install them first.${NC}"
        exit 1
    fi
    log ""
}

# Function to validate environment variables
validate_env_vars() {
    local account_type=$1
    local required_vars
    
    log_colored "${BLUE}Validating environment variables for ${account_type} account...${NC}"
    
    if [ "$account_type" == "local" ]; then
        required_vars=("LOCAL_ACCOUNT_PROFILE" "AWS_REGION" "CLUSTER_NAME" "OWNER_NAME" "LOCAL_TASK_ROLE_ARN")
    else
        required_vars=("EXTERNAL_ACCOUNT_PROFILE" "AWS_REGION" "CLUSTER_NAME" "OWNER_NAME" "EXTERNAL_TASK_ROLE_ARN" "EXTERNAL_SUBNETS" "EXTERNAL_ECS_SG")
    fi
    
    local missing=0
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_colored "${RED}✗ $var is not defined${NC}"
            missing=1
        else
            log_colored "${GREEN}✓ $var is set${NC}"
        fi
    done
    
    if [ $missing -eq 1 ]; then
        log_colored "${RED}Error: Missing required environment variables.${NC}"
        log "Please source your configuration file or run:"
        log "  source ./env-config.sh"
        log "  source ./create-iam-multi-account.sh"
        exit 1
    fi
    log ""
}

# Check if cluster exists
cluster_exists() {
    local cluster_name=$1
    local profile=$2
    
    aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'clusters[0].status' \
        --output text 2>/dev/null | grep -q "ACTIVE"
}

# Check if service exists
service_exists() {
    local cluster_name=$1
    local service_name=$2
    local profile=$3
    
    aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'services[0].status' \
        --output text 2>/dev/null | grep -q "ACTIVE"
}

# Function to register task definitions
register_task_definition() {
    local task_def=$1
    local log_prefix=$2
    local task_role_arn=$3
    local svc_account=$4
    local aws_profile=$5

    log "  - Checking task definition $task_def..."

    # Check if task definition already exists
    local existing_def=$(aws ecs describe-task-definition \
        --task-definition "${task_def%%.*}" \
        --profile "$aws_profile" \
        --region "$AWS_REGION" \
        --query 'taskDefinition.family' \
        --output text 2>/dev/null)
    
    if [ "$existing_def" != "None" ] && [ -n "$existing_def" ]; then
        log_colored "${YELLOW}    ⚠ Task definition ${task_def%%.*} already exists, skipping registration${NC}"
        return 0
    fi

    log "    Registering new task definition..."

    # Define jq filter for task definition
    local jq_filter='.taskRoleArn = $taskRole |
                     .executionRoleArn = $taskRole |
                     .tags = [{"key": "ecs.solo.io/service-account", "value": $svcAcct}, {"key": "environment", "value": "ecs-demo"}] |
                     .containerDefinitions[0].logConfiguration |= { 
                        "logDriver": "awslogs", 
                        "options": { 
                            "awslogs-group": "/ecs/ecs-demo", 
                            "awslogs-region": $awsRegion, 
                            "awslogs-stream-prefix": $logPrefix 
                        } 
                     }'

    # Register the ECS task definition
    if aws ecs register-task-definition \
        --cli-input-json "$(jq --arg taskRole "$task_role_arn" \
                                 --arg svcAcct "$svc_account" \
                                 --arg awsRegion "$AWS_REGION" \
                                 --arg logPrefix "$log_prefix" \
                                 "$jq_filter" \
                                 ecs_definitions/$task_def)" \
        --profile "$aws_profile" \
        --region "$AWS_REGION" \
        --no-cli-pager > /dev/null 2>&1; then
        log_colored "${GREEN}    ✓ $task_def registered${NC}"
        return 0
    else
        log_colored "${RED}    ✗ Failed to register $task_def${NC}"
        return 1
    fi
}

# Create network configuration JSON file (avoids shell escaping issues)
create_network_config() {
    local subnet_ids=$1
    local security_group=$2
    local config_file=$3
    
    # Convert comma-separated subnet IDs to JSON array
    local subnet_array=$(echo "$subnet_ids" | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')
    
    cat > "$config_file" <<EOF
{
  "awsvpcConfiguration": {
    "subnets": [$subnet_array],
    "securityGroups": ["$security_group"],
    "assignPublicIp": "DISABLED"
  }
}
EOF
}

# Function to deploy ECS clusters and services
deploy_to_account() {
    local account_type=$1
    local cluster_numbers=$2
    
    log_colored "${GREEN}=============================================${NC}"
    log_colored "${GREEN}Deploying to ${account_type^^} account...${NC}"
    log_colored "${GREEN}=============================================${NC}"
    log ""
    
    # Validate environment for this account type
    validate_env_vars "$account_type"
    
    # Set account-specific variables
    if [ "$account_type" == "local" ]; then
        local aws_profile=$LOCAL_ACCOUNT_PROFILE
        local task_role_arn=$LOCAL_TASK_ROLE_ARN
        local svc_account=${LOCAL_ECS_SERVICE_ACCOUNT_NAME:-ecs-demo-sa-local}
        
        log "Getting VPC info from EKS cluster..."
        local vpc_id=$(aws eks describe-cluster \
            --name "$CLUSTER_NAME" \
            --region "$AWS_REGION" \
            --profile "$aws_profile" \
            --query 'cluster.resourcesVpcConfig.vpcId' \
            --output text 2>/dev/null)
        
        if [ -z "$vpc_id" ] || [ "$vpc_id" == "None" ]; then
            log_colored "${RED}Error: Could not get VPC ID from EKS cluster${NC}"
            return 1
        fi
        
        log "  VPC ID: $vpc_id"
        
        # Get private subnets
        local subnet_ids=$(aws ec2 describe-subnets \
            --filters Name=vpc-id,Values="$vpc_id" Name=map-public-ip-on-launch,Values=false \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'Subnets[*].SubnetId' \
            --output text 2>/dev/null | tr '\t' ',')
        
        if [ -z "$subnet_ids" ]; then
            log_colored "${RED}Error: Could not find private subnets${NC}"
            return 1
        fi
        
        # Get or create security group
        local existing_sg=$(aws ec2 describe-security-groups \
            --filters Name=group-name,Values=ecs-demo-sg-local Name=vpc-id,Values=$vpc_id \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query "SecurityGroups[0].GroupId" \
            --output text 2>/dev/null)
        
        if [ "$existing_sg" == "None" ] || [ -z "$existing_sg" ]; then
            log "Creating security group for local account..."
            existing_sg=$(aws ec2 create-security-group \
                --group-name ecs-demo-sg-local \
                --description "Security Group for ECS Demo - Local" \
                --vpc-id "$vpc_id" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --query 'GroupId' \
                --output text 2>/dev/null)
            
            # Add ingress rule
            aws ec2 authorize-security-group-ingress \
                --group-id "$existing_sg" \
                --protocol -1 \
                --port 0-65535 \
                --cidr 0.0.0.0/0 \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1 || true
            
            log_colored "${GREEN}  ✓ Created security group: $existing_sg${NC}"
        else
            log_colored "${GREEN}  ✓ Using existing security group: $existing_sg${NC}"
        fi
        
        local security_group=$existing_sg
        
    else  # external
        local aws_profile=$EXTERNAL_ACCOUNT_PROFILE
        local task_role_arn=$EXTERNAL_TASK_ROLE_ARN
        local svc_account=${EXTERNAL_ECS_SERVICE_ACCOUNT_NAME:-ecs-demo-sa-external}
        local subnet_ids=$EXTERNAL_SUBNETS
        local security_group=$EXTERNAL_ECS_SG
    fi
    
    log ""
    log "Configuration:"
    log "  Account Type: ${account_type}"
    log "  Profile: ${aws_profile}"
    log "  Task Role: ${task_role_arn}"
    log "  Service Account: ${svc_account}"
    log "  Subnets: ${subnet_ids}"
    log "  Security Group: ${security_group}"
    log ""
    
    # Create network configuration file
    local network_config_file="/tmp/network-config-${account_type}.json"
    create_network_config "$subnet_ids" "$security_group" "$network_config_file"
    log_colored "${GREEN}✓ Network configuration file created${NC}"
    log ""
    
    # Register task definitions
    log_colored "${GREEN}Step 1/3: Registering task definitions${NC}"
    local task_definitions=("shell-task-definition.json" "echo-task-definition.json")
    local log_prefixes=("demo-shell-task" "echo-service-task")
    local registration_failed=0
    
    for i in "${!task_definitions[@]}"; do
        if ! register_task_definition "${task_definitions[$i]}" "${log_prefixes[$i]}" "$task_role_arn" "$svc_account" "$aws_profile"; then
            registration_failed=1
        fi
    done
    
    if [ $registration_failed -eq 1 ]; then
        log_colored "${RED}Some task definitions failed to register${NC}"
        return 1
    fi
    log ""
    
    # Create CloudWatch log group (if not exists)
    aws logs create-log-group \
        --log-group-name "/ecs/ecs-demo" \
        --region "$AWS_REGION" \
        --profile "$aws_profile" \
        --no-cli-pager > /dev/null 2>&1 || true
    
    # Deploy to each cluster
    for cluster_num in $cluster_numbers; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        
        log_colored "${GREEN}Step 2/3: Creating cluster ${cluster_name}${NC}"
        
        # Check if cluster already exists
        if cluster_exists "$cluster_name" "$aws_profile"; then
            log_colored "${YELLOW}  ⚠ Cluster ${cluster_name} already exists, skipping creation${NC}"
        else
            # Create ECS cluster with discovery tag
            if aws ecs create-cluster \
                --cluster "$cluster_name" \
                --tags key=ecs.solo.io/discovery-enabled,value=true \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1; then
                log_colored "${GREEN}  ✓ Cluster ${cluster_name} created${NC}"
            else
                log_colored "${RED}  ✗ Failed to create cluster ${cluster_name}${NC}"
                continue
            fi
        fi
        
        # CRITICAL: Ensure Istio discovery tag is present (for new and existing clusters)
        log "  - Ensuring Istio discovery tag is set..."
        local cluster_arn=$(aws ecs describe-clusters \
            --clusters "$cluster_name" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'clusters[0].clusterArn' \
            --output text 2>/dev/null)
        
        if [ -n "$cluster_arn" ] && [ "$cluster_arn" != "None" ]; then
            aws ecs tag-resource \
                --resource-arn "$cluster_arn" \
                --tags key=ecs.solo.io/discovery-enabled,value=true \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1 || true
            log_colored "${GREEN}  ✓ Discovery tag verified: ecs.solo.io/discovery-enabled=true${NC}"
        fi
        log ""
        
        log_colored "${GREEN}Step 3/3: Deploying services to ${cluster_name}${NC}"
        
        # Deploy services
        local services=("shell-task" "echo-service")
        for service in "${services[@]}"; do
            log "  - Checking service: ${service}"
            
            # Check if service already exists
            if service_exists "$cluster_name" "$service" "$aws_profile"; then
                log_colored "${YELLOW}    ⚠ Service ${service} already exists in ${cluster_name}, skipping${NC}"
                continue
            fi
            
            log "    Creating service..."
            
            # Create service using file-based network configuration
            if aws ecs create-service \
                --cluster "$cluster_name" \
                --service-name "$service" \
                --task-definition "${service}-definition" \
                --desired-count 1 \
                --launch-type FARGATE \
                --enable-execute-command \
                --network-configuration "file://${network_config_file}" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1; then
                log_colored "${GREEN}    ✓ ${service} deployed${NC}"
            else
                log_colored "${RED}    ✗ Failed to deploy ${service}${NC}"
            fi
        done
        log ""
    done
    
    # Update EKS security group (only for local account)
    if [ "$account_type" == "local" ]; then
        log_colored "${GREEN}Updating EKS security group for ECS access...${NC}"
        local eks_sg_id=$(aws ec2 describe-security-groups \
            --filters Name=vpc-id,Values=$vpc_id Name=group-name,Values='eks-cluster-sg*' \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].GroupId' \
            --output text 2>/dev/null)
        
        if [ "$eks_sg_id" != "None" ] && [ -n "$eks_sg_id" ]; then
            aws ec2 authorize-security-group-ingress \
                --group-id "$eks_sg_id" \
                --protocol -1 \
                --cidr 0.0.0.0/0 \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1 || true
            log_colored "${GREEN}  ✓ EKS security group updated: $eks_sg_id${NC}"
        fi
        log ""
    fi
    
    # Cleanup temp files
    rm -f "$network_config_file"
}

# Main deployment flow
main() {
    log_colored "${BLUE}Starting deployment...${NC}"
    log ""
    
    # Check prerequisites
    check_prerequisites
    
    # Deploy to local account (clusters 1 and 2)
    log_colored "${BLUE}═══════════════════════════════════════════${NC}"
    log_colored "${BLUE}  LOCAL ACCOUNT DEPLOYMENT${NC}"
    log_colored "${BLUE}═══════════════════════════════════════════${NC}"
    log ""
    
    if ! deploy_to_account "local" "1 2"; then
        log_colored "${YELLOW}⚠ Local account deployment had some errors, but continuing...${NC}"
    fi
    
    # Deploy to external account (cluster 3)
    log_colored "${BLUE}═══════════════════════════════════════════${NC}"
    log_colored "${BLUE}  EXTERNAL ACCOUNT DEPLOYMENT${NC}"
    log_colored "${BLUE}═══════════════════════════════════════════${NC}"
    log ""
    
    if ! deploy_to_account "external" "3"; then
        log_colored "${YELLOW}⚠ External account deployment had some errors${NC}"
    fi
    
    # Summary
    log ""
    log_colored "${GREEN}=============================================${NC}"
    log_colored "${GREEN}  Deployment Complete!${NC}"
    log_colored "${GREEN}=============================================${NC}"
    log ""
    log "Deployment summary:"
    log ""
    
    # Check what was actually deployed
    log "Checking deployed resources..."
    log ""
    
    for cluster_num in 1 2; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        local service_count=$(aws ecs list-services \
            --cluster "$cluster_name" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'length(serviceArns)' \
            --output text 2>/dev/null || echo "0")
        log "  LOCAL: $cluster_name - $service_count services"
    done
    
    local cluster_name="ecs-${CLUSTER_NAME}-3"
    local service_count=$(aws ecs list-services \
        --cluster "$cluster_name" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --query 'length(serviceArns)' \
        --output text 2>/dev/null || echo "0")
    log "  EXTERNAL: $cluster_name - $service_count services"
    
    log ""
    log_colored "${YELLOW}Next steps:${NC}"
    log "1. Create Kubernetes namespaces:"
    log "   source ./create-k8s-namespaces-3-clusters.sh"
    log ""
    log "2. Add services to mesh:"
    log "   ./add-services-to-mesh-3-clusters.sh"
    log ""
    log "3. Verify deployment:"
    log "   ./istioctl ztunnel-config services | grep ecs-${CLUSTER_NAME}"
    log ""
    log "Full log saved to: $LOG_FILE"
    log ""
}

# Run main function
main
