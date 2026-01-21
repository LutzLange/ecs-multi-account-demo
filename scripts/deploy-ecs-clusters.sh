#!/bin/bash

# deploy-ecs-clusters.sh
# Unified ECS deployment script that adapts based on SCENARIO variable
# Supports:
#   SCENARIO=1: 1 cluster (local account)
#   SCENARIO=2: 2 clusters (local account)
#   SCENARIO=3: 3 clusters (2 local + 1 external account)

set -o pipefail

# Color codes for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Default configuration file
CONFIG_FILE="env-config.sh"

# Debug mode flag
DEBUG=false
LOG_FILE=""
ERRORS_FILE=""

# Track failures
DEPLOYMENT_FAILED=0
FAILED_SERVICES=()

# Parse command line options
parse_options() {
    local TEMP
    TEMP=$(getopt -o c: --long config:,debug -n 'deploy-ecs-clusters.sh' -- "$@")

    if [ $? != 0 ]; then
        echo "Usage: $0 [-c config-file] [--debug]" >&2
        exit 1
    fi

    eval set -- "$TEMP"

    while true; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            --debug)
                DEBUG=true
                LOG_FILE="deploy-ecs-$(date +%Y%m%d-%H%M%S).log"
                ERRORS_FILE="deploy-errors-$(date +%Y%m%d-%H%M%S).log"
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
        echo -e "${YELLOW}Error: Configuration file not found: $CONFIG_FILE${NC}"
        echo ""
        echo "Please ensure $CONFIG_FILE exists with SCENARIO variable set"
        exit 1
    fi

    echo -e "${BLUE}Loading configuration from: $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
    echo ""
}

# Function to log messages
log() {
    if [ "$DEBUG" = true ]; then
        echo "$@" | tee -a "$LOG_FILE"
    else
        echo "$@"
    fi
}

log_colored() {
    if [ "$DEBUG" = true ]; then
        echo -e "$@" | tee -a "$LOG_FILE"
    else
        echo -e "$@"
    fi
}

log_error() {
    if [ "$DEBUG" = true ]; then
        echo -e "${RED}$@${NC}" | tee -a "$LOG_FILE" | tee -a "$ERRORS_FILE"
    else
        echo -e "${RED}$@${NC}"
    fi
}

# Validate scenario and set cluster configuration
validate_scenario() {
    if [ -z "$SCENARIO" ]; then
        log_error "Error: SCENARIO variable not set in $CONFIG_FILE"
        log_error "Please set SCENARIO=1, 2, or 3"
        exit 1
    fi

    case "$SCENARIO" in
        1)
            LOCAL_CLUSTERS="1"
            EXTERNAL_CLUSTERS=""
            log_colored "${GREEN}Scenario 1: Deploying 1 cluster (local account)${NC}"
            ;;
        2)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS=""
            log_colored "${GREEN}Scenario 2: Deploying 2 clusters (local account)${NC}"
            ;;
        3)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS="3"
            log_colored "${GREEN}Scenario 3: Deploying 3 clusters (2 local + 1 external)${NC}"
            ;;
        *)
            log_error "Error: Invalid SCENARIO value: $SCENARIO"
            log_error "Valid values: 1, 2, or 3"
            exit 1
            ;;
    esac
    log ""
}

# Validate required commands
check_prerequisites() {
    log_colored "${BLUE}Checking prerequisites...${NC}"
    local missing=0

    for cmd in aws jq; do
        if ! command -v $cmd &> /dev/null; then
            log_error "✗ $cmd is not installed"
            missing=1
        else
            log_colored "${GREEN}✓ $cmd is available${NC}"
        fi
    done

    if [ $missing -eq 1 ]; then
        log_error "Error: Missing required commands. Please install them first."
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
        required_vars=("EXTERNAL_ACCOUNT_PROFILE" "AWS_REGION" "CLUSTER_NAME" "OWNER_NAME" "EXTERNAL_TASK_ROLE_ARN" "EXTERNAL_SUBNETS" "EXTERNAL_SG")
    fi

    local missing=0
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "✗ $var is not defined"
            missing=1
        else
            log_colored "${GREEN}✓ $var is set${NC}"
        fi
    done

    if [ $missing -eq 1 ]; then
        log_error "Error: Missing required environment variables."
        log ""
        log "Please ensure $CONFIG_FILE contains all required variables"
        log "or run the previous setup scripts first:"
        if [ "$SCENARIO" = "3" ]; then
            log "  ./scripts/setup-infrastructure.sh"
        fi
        log "  ./scripts/create-iam-roles.sh"
        log ""
        exit 1
    fi
    log ""
}

# Check if cluster exists and is active
cluster_exists() {
    local cluster_name=$1
    local profile=$2

    local cluster_arn=$(aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'clusters[0].clusterArn' \
        --output text 2>/dev/null)

    if [ -z "$cluster_arn" ] || [ "$cluster_arn" = "None" ]; then
        return 1
    fi

    local status=$(aws ecs describe-clusters \
        --clusters "$cluster_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'clusters[0].status' \
        --output text 2>/dev/null)

    if [ "$status" = "ACTIVE" ]; then
        return 0
    else
        return 1
    fi
}

# Check if service exists and is active
service_exists() {
    local cluster_name=$1
    local service_name=$2
    local profile=$3

    local failures=$(aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'failures' \
        --output text 2>/dev/null)

    if [ -n "$failures" ] && [ "$failures" != "None" ] && [ "$failures" != "[]" ]; then
        return 1
    fi

    local status=$(aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        --profile "$profile" \
        --region "$AWS_REGION" \
        --query 'services[0].status' \
        --output text 2>/dev/null)

    if [ "$status" = "ACTIVE" ]; then
        return 0
    else
        return 1
    fi
}

# Function to register task definitions with correct family name
register_task_definition() {
    local task_def_file=$1
    local task_def_family=$2
    local log_prefix=$3
    local task_role_arn=$4
    local svc_account=$5
    local aws_profile=$6

    log "  - Checking task definition ${task_def_family}..."

    # Check if task definition already exists
    local existing_def=$(aws ecs describe-task-definition \
        --task-definition "$task_def_family" \
        --profile "$aws_profile" \
        --region "$AWS_REGION" \
        --query 'taskDefinition.family' \
        --output text 2>/dev/null)

    if [ "$existing_def" != "None" ] && [ -n "$existing_def" ]; then
        log_colored "${YELLOW}    ⚠ Task definition ${task_def_family} already exists, skipping registration${NC}"
        return 0
    fi

    log "    Registering new task definition with family: ${task_def_family}..."

    local jq_filter='.family = $family |
                     .taskRoleArn = $taskRole |
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

    local error_output
    error_output=$(aws ecs register-task-definition \
        --cli-input-json "$(jq --arg family "$task_def_family" \
                                 --arg taskRole "$task_role_arn" \
                                 --arg svcAcct "$svc_account" \
                                 --arg awsRegion "$AWS_REGION" \
                                 --arg logPrefix "$log_prefix" \
                                 "$jq_filter" \
                                 ecs_definitions/$task_def_file)" \
        --profile "$aws_profile" \
        --region "$AWS_REGION" \
        --no-cli-pager 2>&1)

    if [ $? -eq 0 ]; then
        log_colored "${GREEN}    ✓ $task_def_family registered${NC}"
        return 0
    else
        log_error "    ✗ Failed to register $task_def_family"
        log_error "    Error: $error_output"
        return 1
    fi
}

# Create network configuration JSON file
create_network_config() {
    local subnet_ids=$1
    local security_group=$2
    local config_file=$3

    local subnet_array=$(echo "$subnet_ids" | jq -R 'split(",")' | jq -c .)

    cat > "$config_file" << EOF
{
  "awsvpcConfiguration": {
    "subnets": $subnet_array,
    "securityGroups": ["$security_group"],
    "assignPublicIp": "ENABLED"
  }
}
EOF

    if [ -f "$config_file" ]; then
        log_colored "${GREEN}✓ Network configuration file created${NC}"
        return 0
    else
        log_error "✗ Failed to create network configuration file"
        return 1
    fi
}

# Main deployment function for an account
deploy_to_account() {
    local account_type=$1
    local cluster_numbers=$2

    log_colored "${GREEN}=============================================${NC}"
    log_colored "${GREEN}Deploying to ${account_type^^} account...${NC}"
    log_colored "${GREEN}=============================================${NC}"
    log ""

    # Validate environment variables
    if ! validate_env_vars "$account_type"; then
        return 1
    fi

    # Set account-specific variables
    if [ "$account_type" == "local" ]; then
        local aws_profile="$LOCAL_ACCOUNT_PROFILE"
        local task_role_arn="$LOCAL_TASK_ROLE_ARN"
        local svc_account="ecs-demo-sa-local"

        log "Getting VPC info from EKS cluster..."
        local vpc_id=$(aws eks describe-cluster \
            --name "$CLUSTER_NAME" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'cluster.resourcesVpcConfig.vpcId' \
            --output text 2>/dev/null)
        log "  VPC ID: $vpc_id"

        # Get only public subnets (filter by Name tag containing "Public")
        # ECS tasks need public subnets with assignPublicIp ENABLED for HBONE connectivity
        # The east-west gateway needs to reach back to ECS tasks on port 15008
        local subnet_ids=$(aws ec2 describe-subnets \
            --filters "Name=vpc-id,Values=$vpc_id" "Name=tag:Name,Values=*Public*" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'Subnets[*].SubnetId' \
            --output text 2>/dev/null | tr '\t' ',')

        # Search for ECS-specific security group with cluster-specific name
        # Use exact name pattern to avoid matching EKS security groups that contain "ecs" in cluster name
        local security_group=$(aws ec2 describe-security-groups \
            --filters Name=vpc-id,Values=$vpc_id "Name=group-name,Values=ecs-${CLUSTER_NAME}-sg" \
            --profile "$aws_profile" \
            --region "$AWS_REGION" \
            --query 'SecurityGroups[0].GroupId' \
            --output text 2>/dev/null)

        if [ "$security_group" == "None" ] || [ -z "$security_group" ]; then
            log "  No ECS security group found, creating one..."
            security_group=$(aws ec2 create-security-group \
                --group-name "ecs-${CLUSTER_NAME}-sg" \
                --description "Security group for ECS tasks" \
                --vpc-id "$vpc_id" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --query 'GroupId' \
                --output text 2>/dev/null)

            aws ec2 authorize-security-group-ingress \
                --group-id "$security_group" \
                --protocol -1 \
                --cidr 0.0.0.0/0 \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager > /dev/null 2>&1 || true
            log_colored "${GREEN}  ✓ Created security group: $security_group${NC}"
        else
            log_colored "${GREEN}  ✓ Using existing security group: $security_group${NC}"
        fi
    else
        local aws_profile="$EXTERNAL_ACCOUNT_PROFILE"
        local task_role_arn="$EXTERNAL_TASK_ROLE_ARN"
        local svc_account="ecs-demo-sa-external"
        local subnet_ids="$EXTERNAL_SUBNETS"
        local security_group="$EXTERNAL_SG"
        local vpc_id="$EXTERNAL_VPC"
    fi

    log ""
    log "Configuration:"
    log "  Account Type: $account_type"
    log "  Profile: $aws_profile"
    log "  Task Role: $task_role_arn"
    log "  Service Account: $svc_account"
    log "  Subnets: $subnet_ids"
    log "  Security Group: $security_group"
    log ""

    # Create network configuration file
    local network_config_file="network-config-${account_type}.json"
    if ! create_network_config "$subnet_ids" "$security_group" "$network_config_file"; then
        return 1
    fi
    log ""

    # Create CloudWatch log group
    aws logs create-log-group \
        --log-group-name "/ecs/ecs-demo" \
        --region "$AWS_REGION" \
        --profile "$aws_profile" \
        --no-cli-pager > /dev/null 2>&1 || true

    # Register task definitions
    log_colored "${GREEN}Step 1/3: Registering task definitions${NC}"

    declare -A taskdef_map=(
        ["shell-task"]="shell-task-definition.json|shell-task-definition|demo-shell-task"
        ["echo-service"]="echo-task-definition.json|echo-service-definition|echo-service-task"
    )

    for service_name in "${!taskdef_map[@]}"; do
        IFS='|' read -r file family log_prefix <<< "${taskdef_map[$service_name]}"
        register_task_definition "$file" "$family" "$log_prefix" "$task_role_arn" "$svc_account" "$aws_profile"
    done
    log ""

    # Deploy to each cluster
    for cluster_num in $cluster_numbers; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"

        log_colored "${GREEN}Step 2/3: Creating cluster ${cluster_name}${NC}"

        if cluster_exists "$cluster_name" "$aws_profile"; then
            log_colored "${YELLOW}  ⚠ Cluster ${cluster_name} already exists and is ACTIVE, skipping creation${NC}"
        else
            local cluster_status=$(aws ecs describe-clusters \
                --clusters "$cluster_name" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --query 'clusters[0].status' \
                --output text 2>/dev/null)

            if [ -n "$cluster_status" ] && [ "$cluster_status" != "None" ] && [ "$cluster_status" != "ACTIVE" ]; then
                log_colored "${YELLOW}  ⚠ Cluster ${cluster_name} exists but status is: ${cluster_status}${NC}"
                log_colored "${YELLOW}  ⚠ Waiting for cluster to be fully removed...${NC}"

                # Wait for cluster to be fully removed
                local max_wait=120  # 2 minutes max
                local wait_time=0
                while [ $wait_time -lt $max_wait ]; do
                    cluster_status=$(aws ecs describe-clusters \
                        --clusters "$cluster_name" \
                        --profile "$aws_profile" \
                        --region "$AWS_REGION" \
                        --query 'clusters[0].status' \
                        --output text 2>/dev/null)

                    # Cluster is gone or INACTIVE (can recreate)
                    if [ -z "$cluster_status" ] || [ "$cluster_status" = "None" ] || [ "$cluster_status" = "INACTIVE" ]; then
                        if [ "$cluster_status" = "INACTIVE" ]; then
                            log_colored "${YELLOW}    Cluster is INACTIVE, waiting 30s for AWS to fully process...${NC}"
                            sleep 30
                        fi
                        break
                    fi

                    sleep 10
                    wait_time=$((wait_time + 10))
                    log_colored "${YELLOW}    Still waiting... status: ${cluster_status} (${wait_time}s)${NC}"
                done

                if [ $wait_time -ge $max_wait ]; then
                    log_colored "${RED}  ✗ Timeout waiting for cluster ${cluster_name} to be removed${NC}"
                    log_colored "${RED}  ✗ Please wait and try again, or use a different cluster name${NC}"
                    exit 1
                fi

                log_colored "${GREEN}    Cluster slot is now available${NC}"
            fi

            log "  Creating cluster..."
            local error_output
            error_output=$(aws ecs create-cluster \
                --cluster "$cluster_name" \
                --tags key=ecs.solo.io/discovery-enabled,value=true \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager 2>&1)

            if [ $? -eq 0 ]; then
                log_colored "${GREEN}  ✓ Cluster ${cluster_name} created${NC}"
            else
                log_error "  ✗ Failed to create cluster ${cluster_name}"
                log_error "  Error: $error_output"
                continue
            fi
        fi

        # Ensure Istio discovery tag is present
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

        for service in "${!taskdef_map[@]}"; do
            log "  - Checking service: ${service}"

            if service_exists "$cluster_name" "$service" "$aws_profile"; then
                log_colored "${YELLOW}    ⚠ Service ${service} already exists and is ACTIVE in ${cluster_name}, skipping${NC}"
                continue
            fi

            local service_status=$(aws ecs describe-services \
                --cluster "$cluster_name" \
                --services "$service" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --query 'services[0].status' \
                --output text 2>/dev/null)

            if [ -n "$service_status" ] && [ "$service_status" != "None" ] && [ "$service_status" != "ACTIVE" ]; then
                log_colored "${YELLOW}    ⚠ Service ${service} exists but status is: ${service_status}${NC}"
                log_colored "${YELLOW}    ⚠ Waiting for service to be fully removed...${NC}"

                # Wait for service to be fully removed (INACTIVE services eventually get purged)
                local max_wait=180  # 3 minutes max
                local wait_time=0
                while [ $wait_time -lt $max_wait ]; do
                    service_status=$(aws ecs describe-services \
                        --cluster "$cluster_name" \
                        --services "$service" \
                        --profile "$aws_profile" \
                        --region "$AWS_REGION" \
                        --query 'services[0].status' \
                        --output text 2>/dev/null)

                    # Service is gone or can be recreated
                    if [ -z "$service_status" ] || [ "$service_status" = "None" ] || [ "$service_status" = "INACTIVE" ]; then
                        # INACTIVE services can take additional time before name can be reused
                        if [ "$service_status" = "INACTIVE" ]; then
                            log_colored "${YELLOW}      Service is INACTIVE, waiting 30s for AWS to fully process...${NC}"
                            sleep 30
                        fi
                        break
                    fi

                    sleep 10
                    wait_time=$((wait_time + 10))
                    log_colored "${YELLOW}      Still waiting... status: ${service_status} (${wait_time}s)${NC}"
                done

                if [ $wait_time -ge $max_wait ]; then
                    log_colored "${RED}    ✗ Timeout waiting for service ${service} to be removed${NC}"
                    DEPLOYMENT_FAILED=1
                    FAILED_SERVICES+=("${cluster_name}/${service}")
                    continue
                fi

                log_colored "${GREEN}      Service slot is now available${NC}"
            fi

            log "    Creating service..."

            IFS='|' read -r file family log_prefix <<< "${taskdef_map[$service]}"

            local error_output
            error_output=$(aws ecs create-service \
                --cluster "$cluster_name" \
                --service-name "$service" \
                --task-definition "$family" \
                --desired-count 1 \
                --launch-type FARGATE \
                --enable-execute-command \
                --network-configuration "file://${network_config_file}" \
                --profile "$aws_profile" \
                --region "$AWS_REGION" \
                --no-cli-pager 2>&1)

            if [ $? -eq 0 ]; then
                log_colored "${GREEN}    ✓ ${service} deployed${NC}"
            else
                DEPLOYMENT_FAILED=1
                FAILED_SERVICES+=("${cluster_name}/${service}")

                log_error "    ✗ Failed to deploy ${service} in ${cluster_name}"
                log_error "    Error: $error_output"
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

# Print deployment summary
print_summary() {
    log ""
    log "Deployment summary:"
    log ""

    log "Checking deployed resources..."
    log ""

    # Check local clusters
    for cluster_num in $LOCAL_CLUSTERS; do
        local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
        local service_count=$(aws ecs list-services \
            --cluster "$cluster_name" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'length(serviceArns)' \
            --output text 2>/dev/null || echo "0")
        log "  LOCAL: $cluster_name - $service_count services"
    done

    # Check external clusters (only for scenario 3)
    if [ -n "$EXTERNAL_CLUSTERS" ]; then
        for cluster_num in $EXTERNAL_CLUSTERS; do
            local cluster_name="ecs-${CLUSTER_NAME}-${cluster_num}"
            local service_count=$(aws ecs list-services \
                --cluster "$cluster_name" \
                --profile "$EXTERNAL_ACCOUNT_PROFILE" \
                --region "$AWS_REGION" \
                --query 'length(serviceArns)' \
                --output text 2>/dev/null || echo "0")
            log "  EXTERNAL: $cluster_name - $service_count services"
        done
    fi
    log ""
}

# Main deployment flow
main() {
    parse_options "$@"
    load_config

    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  ECS Cluster Deployment (Scenario $SCENARIO)${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""

    if [ "$DEBUG" = true ]; then
        log "Debug mode enabled"
        log "Log file: $LOG_FILE"
        log "Error file: $ERRORS_FILE"
        log ""
    fi

    validate_scenario
    check_prerequisites

    # Deploy to local account
    if [ -n "$LOCAL_CLUSTERS" ]; then
        log_colored "${BLUE}═══════════════════════════════════════════${NC}"
        log_colored "${BLUE}  LOCAL ACCOUNT DEPLOYMENT${NC}"
        log_colored "${BLUE}═══════════════════════════════════════════${NC}"
        log ""

        deploy_to_account "local" "$LOCAL_CLUSTERS"
    fi

    # Deploy to external account (only for scenario 3)
    if [ -n "$EXTERNAL_CLUSTERS" ]; then
        log_colored "${BLUE}═══════════════════════════════════════════${NC}"
        log_colored "${BLUE}  EXTERNAL ACCOUNT DEPLOYMENT${NC}"
        log_colored "${BLUE}═══════════════════════════════════════════${NC}"
        log ""

        deploy_to_account "external" "$EXTERNAL_CLUSTERS"
    fi

    # Summary
    if [ $DEPLOYMENT_FAILED -eq 0 ]; then
        log_colored "${GREEN}=============================================${NC}"
        log_colored "${GREEN}  Deployment Completed Successfully!${NC}"
        log_colored "${GREEN}=============================================${NC}"
    else
        log_colored "${RED}=============================================${NC}"
        log_colored "${RED}  Deployment Completed with ERRORS${NC}"
        log_colored "${RED}=============================================${NC}"
        log ""
        log_colored "${RED}Failed services:${NC}"
        for failed_svc in "${FAILED_SERVICES[@]}"; do
            log_colored "${RED}  - $failed_svc${NC}"
        done
    fi

    print_summary

    if [ $DEPLOYMENT_FAILED -eq 0 ]; then
        log_colored "${YELLOW}Next steps:${NC}"
        log "1. Create Kubernetes namespaces:"
        log "   ./scripts/create-k8s-namespaces.sh"
        log ""
        log "2. Add services to mesh:"
        log "   ./scripts/add-services-to-mesh.sh"
        log ""
        log "3. Verify deployment:"
        log "   ~/.istioctl/bin/istioctl ztunnel-config services | grep ecs-${CLUSTER_NAME}"
    else
        log_colored "${RED}Fix the errors above before proceeding.${NC}"
    fi

    if [ "$DEBUG" = true ]; then
        log ""
        log "Full log saved to: $LOG_FILE"
    fi
    log ""

    exit $DEPLOYMENT_FAILED
}

# Run main function
main "$@"
