#!/bin/bash

# setup-infrastructure.sh
# Unified infrastructure setup script that adapts based on SCENARIO variable
# Supports:
#   SCENARIO=1 or 2: Minimal setup (just validates EKS exists)
#   SCENARIO=3: Full cross-account setup (VPC, peering, IAM)

set -o pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_section() { echo -e "${BLUE}[====]${NC} $1"; }

# Default configuration file
CONFIG_FILE="env-config.sh"

# Parse command line options
parse_options() {
    local TEMP
    TEMP=$(getopt -o c: --long config: -n 'setup-infrastructure.sh' -- "$@")

    if [ $? != 0 ]; then
        echo "Usage: $0 [-c config-file]" >&2
        exit 1
    fi

    eval set -- "$TEMP"

    while true; do
        case "$1" in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
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
        log_error ""
        log_error "Please create $CONFIG_FILE with required variables"
        exit 1
    fi

    log_info "Loading configuration from: $CONFIG_FILE"
    source "$CONFIG_FILE"
}

# Validate scenario
validate_scenario() {
    if [ -z "$SCENARIO" ]; then
        log_error "SCENARIO variable not set in $CONFIG_FILE"
        exit 1
    fi

    case "$SCENARIO" in
        1|2)
            log_info "Scenario $SCENARIO: Single-account setup (minimal infrastructure)"
            MULTI_ACCOUNT=false
            ;;
        3)
            log_info "Scenario 3: Cross-account setup (full infrastructure)"
            MULTI_ACCOUNT=true
            ;;
        *)
            log_error "Invalid SCENARIO value: $SCENARIO"
            exit 1
            ;;
    esac
}

# Validate EKS cluster exists
validate_eks_cluster() {
    log_section "=== Validating EKS Cluster ==="

    if [ -z "$CLUSTER_NAME" ]; then
        log_error "CLUSTER_NAME not set"
        exit 1
    fi

    log_info "Looking for EKS cluster: $CLUSTER_NAME"
    log_info "Using profile: $LOCAL_ACCOUNT_PROFILE"
    log_info "Region: $AWS_REGION"

    if ! aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" \
        --output json &>/dev/null; then
        log_error "EKS cluster '$CLUSTER_NAME' not found in region $AWS_REGION"
        log_error ""
        log_error "Available EKS clusters:"
        aws eks list-clusters \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" \
            --query 'clusters' \
            --output table 2>/dev/null || log_error "  (Unable to list clusters)"
        log_error ""
        log_error "Please create an EKS cluster first:"
        log_error "  export AWS_PROFILE=$LOCAL_ACCOUNT_PROFILE"
        log_error "  eval \"echo \"\$(cat manifests/eks-cluster.yaml)\"\" | eksctl create cluster --config-file -"
        exit 1
    fi

    # Get VPC and CIDR info
    LOCAL_VPC=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION")

    LOCAL_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids "$LOCAL_VPC" \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE")

    log_info "✓ Found EKS cluster: $CLUSTER_NAME"
    log_info "✓ VPC ID: $LOCAL_VPC"
    log_info "✓ VPC CIDR: $LOCAL_CIDR"

    export LOCAL_VPC LOCAL_CIDR
}

# Setup for scenarios 1 and 2 (minimal)
setup_single_account() {
    log_section "=== Single-Account Setup ==="

    validate_eks_cluster

    # The EKS cluster manifest (eks-cluster.yaml) creates a pod identity association
    # with role 'istiod-eks-ecs-${CLUSTER_NAME}'. However, Istio's ECS integration
    # expects to ASSUME a role specified in the config. So we need to create
    # 'istiod-local' that can be assumed by the eksctl-created role.
    local EKSCTL_ROLE_NAME="istiod-eks-ecs-${CLUSTER_NAME}"
    local EKSCTL_ROLE_ARN="arn:aws:iam::${LOCAL_ACCOUNT}:role/${EKSCTL_ROLE_NAME}"

    log_info "Checking eksctl-created role: $EKSCTL_ROLE_NAME"

    # Verify the eksctl role exists
    if ! aws iam get-role --role-name "$EKSCTL_ROLE_NAME" --profile "$LOCAL_ACCOUNT_PROFILE" &>/dev/null; then
        log_error "Role $EKSCTL_ROLE_NAME not found"
        log_error "This role should have been created by eksctl when the EKS cluster was created"
        log_error "Please ensure the EKS cluster was created with the eks-cluster.yaml manifest"
        exit 1
    fi
    log_info "✓ Role $EKSCTL_ROLE_NAME exists"

    # Create istiod-local role that the eksctl role can assume
    create_istiod_local_role "$EKSCTL_ROLE_ARN"

    # Add permission for eksctl role to assume istiod-local
    add_assume_role_permission "$EKSCTL_ROLE_NAME"

    log_info ""
    log_info "✓ Single-account setup complete!"
    log_info ""
    log_info "The Istio install will use role: arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local"
}

# Create istiod-local role that can be assumed by the specified role
create_istiod_local_role() {
    local trusted_role_arn=$1

    log_section "=== Creating istiod-local Role ==="

    # Create trust policy for istiod-local (allows the eksctl role to assume it)
    cat > /tmp/istiod-local-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "${trusted_role_arn}"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

    # Check if role already exists
    if aws iam get-role --role-name istiod-local --profile "$LOCAL_ACCOUNT_PROFILE" &>/dev/null; then
        log_info "✓ istiod-local role already exists"
        # Update trust policy in case it changed
        aws iam update-assume-role-policy \
            --role-name istiod-local \
            --policy-document file:///tmp/istiod-local-trust-policy.json \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        log_info "✓ Updated trust policy for istiod-local"
    else
        log_info "Creating istiod-local role..."
        aws iam create-role \
            --role-name istiod-local \
            --assume-role-policy-document file:///tmp/istiod-local-trust-policy.json \
            --profile "$LOCAL_ACCOUNT_PROFILE" >/dev/null

        # Attach ECS access policy
        aws iam attach-role-policy \
            --role-name istiod-local \
            --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
            --profile "$LOCAL_ACCOUNT_PROFILE"

        log_info "✓ Created istiod-local role with AmazonECS_FullAccess"
    fi

    rm -f /tmp/istiod-local-trust-policy.json
}

# Add permission for a role to assume istiod-local
add_assume_role_permission() {
    local role_name=$1

    log_section "=== Adding AssumeRole Permission ==="

    # Create inline policy to allow assuming istiod-local
    cat > /tmp/assume-istiod-local-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ],
            "Resource": [
                "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local"
            ]
        }
    ]
}
EOF

    # Add inline policy to the role
    aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "AssumeIstiodLocal" \
        --policy-document file:///tmp/assume-istiod-local-policy.json \
        --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true

    log_info "✓ Added AssumeIstiodLocal policy to $role_name"

    rm -f /tmp/assume-istiod-local-policy.json
}

# Check if resource exists (not empty, not "None", not "null")
resource_exists() {
    [ -n "$1" ] && [ "$1" != "None" ] && [ "$1" != "null" ]
}

# Wait for NAT Gateway to be available
wait_for_nat_gateway() {
    local nat_id=$1
    log_info "Waiting for NAT Gateway $nat_id to become available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat_id" --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    log_info "NAT Gateway is now available"
}

# Wait for VPC peering to be active
wait_for_peering() {
    local peering_id=$1
    log_info "Waiting for VPC Peering Connection $peering_id to be active..."
    aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids "$peering_id" --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        local state=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$peering_id" \
            --query 'VpcPeeringConnections[0].Status.Code' \
            --output text \
            --profile "$LOCAL_ACCOUNT_PROFILE")

        if [ "$state" = "active" ]; then
            log_info "VPC Peering Connection is now active"
            return 0
        fi

        log_info "Peering state: $state (attempt $((attempt+1))/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    log_warn "VPC Peering Connection did not become active within expected time"
}

# Create VPC in External Account
create_external_vpc() {
    log_section "=== Creating VPC in External Account ==="

    EXTERNAL_VPC=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=istio-ecs-external-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_VPC"; then
        log_info "VPC already exists: $EXTERNAL_VPC"
    else
        EXTERNAL_VPC=$(aws ec2 create-vpc \
            --cidr-block 10.1.0.0/16 \
            --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=istio-ecs-external-vpc}]' \
            --query 'Vpc.VpcId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created VPC: $EXTERNAL_VPC"

        aws ec2 modify-vpc-attribute --vpc-id "$EXTERNAL_VPC" --enable-dns-hostnames --profile "$EXTERNAL_ACCOUNT_PROFILE"
        aws ec2 modify-vpc-attribute --vpc-id "$EXTERNAL_VPC" --enable-dns-support --profile "$EXTERNAL_ACCOUNT_PROFILE"
    fi

    export EXTERNAL_VPC
}

# Create Subnets in External Account
create_subnets() {
    log_section "=== Creating Subnets ==="

    # Private Subnet 1
    EXTERNAL_SUBNET_1=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-1" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_SUBNET_1"; then
        log_info "Private Subnet 1 already exists: $EXTERNAL_SUBNET_1"
    else
        EXTERNAL_SUBNET_1=$(aws ec2 create-subnet \
            --vpc-id "$EXTERNAL_VPC" \
            --cidr-block 10.1.1.0/24 \
            --availability-zone "${AWS_REGION}a" \
            --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=istio-ecs-private-1}]' \
            --query 'Subnet.SubnetId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Private Subnet 1: $EXTERNAL_SUBNET_1"
    fi

    # Private Subnet 2
    EXTERNAL_SUBNET_2=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-2" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_SUBNET_2"; then
        log_info "Private Subnet 2 already exists: $EXTERNAL_SUBNET_2"
    else
        EXTERNAL_SUBNET_2=$(aws ec2 create-subnet \
            --vpc-id "$EXTERNAL_VPC" \
            --cidr-block 10.1.2.0/24 \
            --availability-zone "${AWS_REGION}b" \
            --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=istio-ecs-private-2}]' \
            --query 'Subnet.SubnetId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Private Subnet 2: $EXTERNAL_SUBNET_2"
    fi

    # Private Subnet 3
    EXTERNAL_SUBNET_3=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-3" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_SUBNET_3"; then
        log_info "Private Subnet 3 already exists: $EXTERNAL_SUBNET_3"
    else
        EXTERNAL_SUBNET_3=$(aws ec2 create-subnet \
            --vpc-id "$EXTERNAL_VPC" \
            --cidr-block 10.1.3.0/24 \
            --availability-zone "${AWS_REGION}c" \
            --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=istio-ecs-private-3}]' \
            --query 'Subnet.SubnetId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Private Subnet 3: $EXTERNAL_SUBNET_3"
    fi

    # Public Subnet for NAT
    EXTERNAL_PUBLIC_SUBNET=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-public" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_PUBLIC_SUBNET"; then
        log_info "Public Subnet already exists: $EXTERNAL_PUBLIC_SUBNET"
    else
        EXTERNAL_PUBLIC_SUBNET=$(aws ec2 create-subnet \
            --vpc-id "$EXTERNAL_VPC" \
            --cidr-block 10.1.4.0/24 \
            --availability-zone "${AWS_REGION}a" \
            --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=istio-ecs-public}]' \
            --query 'Subnet.SubnetId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Public Subnet: $EXTERNAL_PUBLIC_SUBNET"
    fi

    export EXTERNAL_SUBNET_1 EXTERNAL_SUBNET_2 EXTERNAL_SUBNET_3 EXTERNAL_PUBLIC_SUBNET
    export EXTERNAL_SUBNETS="$EXTERNAL_SUBNET_1,$EXTERNAL_SUBNET_2,$EXTERNAL_SUBNET_3"
}

# Create Internet Gateway
create_internet_gateway() {
    log_section "=== Creating Internet Gateway ==="

    EXTERNAL_IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$EXTERNAL_VPC" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_IGW"; then
        log_info "Internet Gateway already exists: $EXTERNAL_IGW"
    else
        EXTERNAL_IGW=$(aws ec2 create-internet-gateway \
            --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=istio-ecs-igw}]' \
            --query 'InternetGateway.InternetGatewayId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Internet Gateway: $EXTERNAL_IGW"

        aws ec2 attach-internet-gateway \
            --internet-gateway-id "$EXTERNAL_IGW" \
            --vpc-id "$EXTERNAL_VPC" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE"
        log_info "Attached Internet Gateway to VPC"
    fi

    export EXTERNAL_IGW
}

# Create NAT Gateway
create_nat_gateway() {
    log_section "=== Creating NAT Gateway ==="

    EXTERNAL_NAT=$(aws ec2 describe-nat-gateways \
        --filter "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=state,Values=available,pending" \
        --query 'NatGateways[0].NatGatewayId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_NAT"; then
        log_info "NAT Gateway already exists: $EXTERNAL_NAT"
        EXTERNAL_EIP=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids "$EXTERNAL_NAT" \
            --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
    else
        EXTERNAL_EIP=$(aws ec2 allocate-address \
            --domain vpc \
            --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=istio-ecs-eip}]' \
            --query 'AllocationId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Allocated EIP: $EXTERNAL_EIP"

        EXTERNAL_NAT=$(aws ec2 create-nat-gateway \
            --subnet-id "$EXTERNAL_PUBLIC_SUBNET" \
            --allocation-id "$EXTERNAL_EIP" \
            --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=istio-ecs-nat}]' \
            --query 'NatGateway.NatGatewayId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created NAT Gateway: $EXTERNAL_NAT"

        wait_for_nat_gateway "$EXTERNAL_NAT"
    fi

    export EXTERNAL_NAT EXTERNAL_EIP
}

# Configure Route Tables
configure_route_tables() {
    log_section "=== Configuring Route Tables ==="

    # Public Route Table
    EXTERNAL_PUBLIC_RT=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-public-rt" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_PUBLIC_RT"; then
        log_info "Public Route Table already exists: $EXTERNAL_PUBLIC_RT"
    else
        EXTERNAL_PUBLIC_RT=$(aws ec2 create-route-table \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=istio-ecs-public-rt}]' \
            --query 'RouteTable.RouteTableId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Public Route Table: $EXTERNAL_PUBLIC_RT"
    fi

    # Add route to Internet Gateway
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PUBLIC_RT" \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$EXTERNAL_IGW" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || log_info "Route to IGW already exists"

    # Associate public subnet
    local assoc=$(aws ec2 describe-route-tables \
        --route-table-ids "$EXTERNAL_PUBLIC_RT" \
        --query "RouteTables[0].Associations[?SubnetId=='$EXTERNAL_PUBLIC_SUBNET'].SubnetId" \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null)

    if [ -z "$assoc" ]; then
        aws ec2 associate-route-table \
            --route-table-id "$EXTERNAL_PUBLIC_RT" \
            --subnet-id "$EXTERNAL_PUBLIC_SUBNET" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" >/dev/null
        log_info "Associated public subnet with public route table"
    else
        log_info "Public subnet already associated with route table"
    fi

    # Private Route Table
    EXTERNAL_PRIVATE_RT=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-rt" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_PRIVATE_RT"; then
        log_info "Private Route Table already exists: $EXTERNAL_PRIVATE_RT"
    else
        EXTERNAL_PRIVATE_RT=$(aws ec2 create-route-table \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=istio-ecs-private-rt}]' \
            --query 'RouteTable.RouteTableId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Private Route Table: $EXTERNAL_PRIVATE_RT"
    fi

    # Add route to NAT Gateway
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PRIVATE_RT" \
        --destination-cidr-block 0.0.0.0/0 \
        --nat-gateway-id "$EXTERNAL_NAT" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || log_info "Route to NAT Gateway already exists"

    # Associate private subnets
    for subnet in "$EXTERNAL_SUBNET_1" "$EXTERNAL_SUBNET_2" "$EXTERNAL_SUBNET_3"; do
        local assoc=$(aws ec2 describe-route-tables \
            --route-table-ids "$EXTERNAL_PRIVATE_RT" \
            --query "RouteTables[0].Associations[?SubnetId=='$subnet'].SubnetId" \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null)

        if [ -z "$assoc" ]; then
            aws ec2 associate-route-table \
                --route-table-id "$EXTERNAL_PRIVATE_RT" \
                --subnet-id "$subnet" \
                --profile "$EXTERNAL_ACCOUNT_PROFILE" >/dev/null
            log_info "Associated subnet $subnet with private route table"
        fi
    done

    export EXTERNAL_PUBLIC_RT EXTERNAL_PRIVATE_RT
}

# Check for conflicting peering connections
check_peering_conflicts() {
    log_section "=== Checking for Peering Conflicts ==="

    local peerings=$(aws ec2 describe-vpc-peering-connections \
        --filters "Name=accepter-vpc-info.vpc-id,Values=$EXTERNAL_VPC" \
                  "Name=status-code,Values=active,pending-acceptance" \
        --query 'VpcPeeringConnections[*].[VpcPeeringConnectionId,RequesterVpcInfo.VpcId,RequesterVpcInfo.CidrBlock]' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null)

    if [ -z "$peerings" ]; then
        log_info "No existing peerings found to external VPC"
        return 0
    fi

    log_info "Found existing peering(s) to external VPC:"

    local conflicts=()
    while IFS=$'\t' read -r pcx_id requester_vpc requester_cidr; do
        log_info "  - $pcx_id: $requester_vpc ($requester_cidr)"

        if [ "$requester_cidr" = "$LOCAL_CIDR" ] && [ "$requester_vpc" != "$LOCAL_VPC" ]; then
            conflicts+=("$pcx_id|$requester_vpc|$requester_cidr")
        fi
    done <<< "$peerings"

    if [ ${#conflicts[@]} -gt 0 ]; then
        log_error ""
        log_error "CONFLICT DETECTED: Asymmetric routing issue!"
        log_error "Found peering(s) with same CIDR ($LOCAL_CIDR) from different VPC(s)."
        log_error ""
        for conflict in "${conflicts[@]}"; do
            IFS='|' read -r pcx old_vpc cidr <<< "$conflict"
            log_error "  - Peering: $pcx from VPC: $old_vpc"
        done
        log_error ""
        log_error "Delete conflicting peerings before proceeding."
        exit 1
    else
        log_info "No conflicts detected"
    fi
}

# Setup VPC Peering
setup_vpc_peering() {
    log_section "=== Setting Up VPC Peering ==="

    log_info "Using Local VPC: $LOCAL_VPC (CIDR: $LOCAL_CIDR)"
    log_info "Using External VPC: $EXTERNAL_VPC"

    check_peering_conflicts

    PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
        --filters "Name=requester-vpc-info.vpc-id,Values=$LOCAL_VPC" \
                  "Name=accepter-vpc-info.vpc-id,Values=$EXTERNAL_VPC" \
                  "Name=status-code,Values=active,pending-acceptance" \
        --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$PEERING_ID"; then
        log_info "VPC Peering Connection already exists: $PEERING_ID"
    else
        PEERING_ID=$(aws ec2 create-vpc-peering-connection \
            --vpc-id "$LOCAL_VPC" \
            --peer-vpc-id "$EXTERNAL_VPC" \
            --peer-owner-id "$EXTERNAL_ACCOUNT" \
            --peer-region "$AWS_REGION" \
            --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=istio-multi-account-peering}]' \
            --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
            --output text \
            --profile "$LOCAL_ACCOUNT_PROFILE")
        log_info "Created VPC Peering Connection: $PEERING_ID"

        aws ec2 accept-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" >/dev/null
        log_info "Accepted VPC Peering Connection"

        wait_for_peering "$PEERING_ID"
    fi

    EXTERNAL_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids "$EXTERNAL_VPC" \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE")

    log_info "Local CIDR: $LOCAL_CIDR, External CIDR: $EXTERNAL_CIDR"

    # Add routes in external account
    log_info "Configuring routes in external account..."
    local existing_route=$(aws ec2 describe-route-tables \
        --route-table-ids "$EXTERNAL_PRIVATE_RT" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='$LOCAL_CIDR'].VpcPeeringConnectionId" \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null)

    if [ -n "$existing_route" ] && [ "$existing_route" != "$PEERING_ID" ]; then
        aws ec2 replace-route \
            --route-table-id "$EXTERNAL_PRIVATE_RT" \
            --destination-cidr-block "$LOCAL_CIDR" \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    else
        aws ec2 create-route \
            --route-table-id "$EXTERNAL_PRIVATE_RT" \
            --destination-cidr-block "$LOCAL_CIDR" \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    fi

    existing_route=$(aws ec2 describe-route-tables \
        --route-table-ids "$EXTERNAL_PUBLIC_RT" \
        --query "RouteTables[0].Routes[?DestinationCidrBlock=='$LOCAL_CIDR'].VpcPeeringConnectionId" \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null)

    if [ -n "$existing_route" ] && [ "$existing_route" != "$PEERING_ID" ]; then
        aws ec2 replace-route \
            --route-table-id "$EXTERNAL_PUBLIC_RT" \
            --destination-cidr-block "$LOCAL_CIDR" \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    else
        aws ec2 create-route \
            --route-table-id "$EXTERNAL_PUBLIC_RT" \
            --destination-cidr-block "$LOCAL_CIDR" \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    fi

    # Add routes in local account
    log_info "Configuring routes in local account..."
    LOCAL_ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$LOCAL_VPC" \
        --query 'RouteTables[*].RouteTableId' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE")

    for rt in $LOCAL_ROUTE_TABLES; do
        local existing_route=$(aws ec2 describe-route-tables \
            --route-table-ids "$rt" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='$EXTERNAL_CIDR'].VpcPeeringConnectionId" \
            --output text \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null)

        if [ -n "$existing_route" ] && [ "$existing_route" != "$PEERING_ID" ]; then
            aws ec2 replace-route \
                --route-table-id "$rt" \
                --destination-cidr-block "$EXTERNAL_CIDR" \
                --vpc-peering-connection-id "$PEERING_ID" \
                --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        else
            aws ec2 create-route \
                --route-table-id "$rt" \
                --destination-cidr-block "$EXTERNAL_CIDR" \
                --vpc-peering-connection-id "$PEERING_ID" \
                --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        fi
    done
    log_info "Added peering routes to local route tables"

    export PEERING_ID EXTERNAL_CIDR
}

# Configure Security Groups
configure_security_groups() {
    log_section "=== Configuring Security Groups ==="

    EXTERNAL_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=group-name,Values=istio-ecs-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if resource_exists "$EXTERNAL_SG"; then
        log_info "Security Group already exists: $EXTERNAL_SG"
    else
        EXTERNAL_SG=$(aws ec2 create-security-group \
            --group-name istio-ecs-sg \
            --description "Security group for Istio ECS services" \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=istio-ecs-sg}]' \
            --query 'GroupId' \
            --output text \
            --profile "$EXTERNAL_ACCOUNT_PROFILE")
        log_info "Created Security Group: $EXTERNAL_SG"
    fi

    # Allow traffic within security group
    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol all \
        --source-group "$EXTERNAL_SG" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true

    # Allow specific TCP ports from local VPC CIDR
    log_info "Configuring ingress rules for external security group..."
    for port in 80 8080 443; do
        aws ec2 authorize-security-group-ingress \
            --group-id "$EXTERNAL_SG" \
            --protocol tcp \
            --port $port \
            --cidr "$LOCAL_CIDR" \
            --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true
    done

    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol tcp \
        --port 15000-15200 \
        --cidr "$LOCAL_CIDR" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true

    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol icmp \
        --port -1 \
        --cidr "$LOCAL_CIDR" \
        --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || true

    # Get local cluster security group
    LOCAL_CLUSTER_SG=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE")

    if resource_exists "$LOCAL_CLUSTER_SG"; then
        log_info "Found EKS Cluster Security Group: $LOCAL_CLUSTER_SG"
        log_info "Configuring ingress rules for cluster security group..."

        for port in 80 8080 443; do
            aws ec2 authorize-security-group-ingress \
                --group-id "$LOCAL_CLUSTER_SG" \
                --protocol tcp \
                --port $port \
                --cidr "$EXTERNAL_CIDR" \
                --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        done

        aws ec2 authorize-security-group-ingress \
            --group-id "$LOCAL_CLUSTER_SG" \
            --protocol tcp \
            --port 15000-15200 \
            --cidr "$EXTERNAL_CIDR" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true

        aws ec2 authorize-security-group-ingress \
            --group-id "$LOCAL_CLUSTER_SG" \
            --protocol icmp \
            --port -1 \
            --cidr "$EXTERNAL_CIDR" \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
    else
        log_warn "Could not find EKS cluster security group"
    fi

    export EXTERNAL_SG LOCAL_CLUSTER_SG
}

# Setup IAM Roles for Cross-Account
setup_cross_account_iam_roles() {
    log_section "=== Setting Up IAM Roles ==="

    # Create trust policy for istiod-role
    cat > /tmp/istiod-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

    # Create istiod-role in local account
    local role_exists=$(aws iam get-role --role-name istiod-role --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        aws iam create-role \
            --role-name istiod-role \
            --assume-role-policy-document file:///tmp/istiod-trust-policy.json \
            --profile "$LOCAL_ACCOUNT_PROFILE" >/dev/null
        log_info "Created istiod-role in local account"
        log_info "Waiting 15 seconds for IAM role to propagate..."
        sleep 15
    else
        log_info "istiod-role already exists in local account"
    fi

    # Create trust policies for istiod-local and istiod-external
    cat > /tmp/local-account-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-role"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

    cat > /tmp/external-account-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-role"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

    # Create istiod-local role
    role_exists=$(aws iam get-role --role-name istiod-local --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        log_info "Creating istiod-local role..."
        local retries=0 max_retries=5 created=false
        while [ $retries -lt $max_retries ] && [ "$created" = false ]; do
            if aws iam create-role \
                --role-name istiod-local \
                --assume-role-policy-document file:///tmp/local-account-trust-policy.json \
                --profile "$LOCAL_ACCOUNT_PROFILE" >/dev/null 2>&1; then
                created=true
                aws iam attach-role-policy \
                    --role-name istiod-local \
                    --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
                    --profile "$LOCAL_ACCOUNT_PROFILE"
                log_info "✓ Created istiod-local role"
            else
                retries=$((retries + 1))
                [ $retries -lt $max_retries ] && sleep 10
            fi
        done
        [ "$created" = false ] && { log_error "Failed to create istiod-local"; return 1; }
    else
        log_info "istiod-local role already exists"
    fi

    # Create istiod-external role
    role_exists=$(aws iam get-role --role-name istiod-external --profile "$EXTERNAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        log_info "Creating istiod-external role..."
        local retries=0 max_retries=5 created=false
        while [ $retries -lt $max_retries ] && [ "$created" = false ]; do
            if aws iam create-role \
                --role-name istiod-external \
                --assume-role-policy-document file:///tmp/external-account-trust-policy.json \
                --profile "$EXTERNAL_ACCOUNT_PROFILE" >/dev/null 2>&1; then
                created=true
                aws iam attach-role-policy \
                    --role-name istiod-external \
                    --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
                    --profile "$EXTERNAL_ACCOUNT_PROFILE"
                log_info "✓ Created istiod-external role"
            else
                retries=$((retries + 1))
                [ $retries -lt $max_retries ] && sleep 10
            fi
        done
        [ "$created" = false ] && { log_error "Failed to create istiod-external"; return 1; }
    else
        log_info "istiod-external role already exists"
    fi

    # Create permission policy
    cat > /tmp/istiod-permission-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": ["sts:AssumeRole", "sts:TagSession"],
            "Resource": ["arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local"]
        },
        {
            "Effect": "Allow",
            "Action": ["sts:AssumeRole", "sts:TagSession"],
            "Resource": ["arn:aws:iam::${EXTERNAL_ACCOUNT}:role/istiod-external"]
        }
    ]
}
EOF

    local policy_arn="arn:aws:iam::${LOCAL_ACCOUNT}:policy/istiod-permission-policy"
    local policy_exists=$(aws iam get-policy --policy-arn "$policy_arn" --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || echo "")

    if [ -z "$policy_exists" ]; then
        aws iam create-policy \
            --policy-document file:///tmp/istiod-permission-policy.json \
            --policy-name istiod-permission-policy \
            --profile "$LOCAL_ACCOUNT_PROFILE" >/dev/null
        log_info "✓ Created istiod-permission-policy"
    else
        aws iam create-policy-version \
            --policy-arn "$policy_arn" \
            --policy-document file:///tmp/istiod-permission-policy.json \
            --set-as-default \
            --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
        log_info "✓ Updated istiod-permission-policy"
    fi

    aws iam attach-role-policy \
        --role-name istiod-role \
        --policy-arn "$policy_arn" \
        --profile "$LOCAL_ACCOUNT_PROFILE" 2>/dev/null || true
    log_info "✓ Attached policy to istiod-role"

    # Create pod identity association
    log_section "=== Setting Up Pod Identity Association ==="
    local assoc_id=$(aws eks list-pod-identity-associations \
        --cluster-name "$CLUSTER_NAME" \
        --namespace istio-system \
        --service-account istiod \
        --query 'associations[0].associationId' \
        --output text \
        --profile "$LOCAL_ACCOUNT_PROFILE" \
        --region "$AWS_REGION" 2>/dev/null || echo "")

    if resource_exists "$assoc_id" && [ "$assoc_id" != "None" ]; then
        aws eks update-pod-identity-association \
            --cluster-name "$CLUSTER_NAME" \
            --association-id "$assoc_id" \
            --role-arn "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-role" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || true
        log_info "✓ Updated EKS pod identity association"
    else
        aws eks create-pod-identity-association \
            --cluster-name "$CLUSTER_NAME" \
            --namespace istio-system \
            --service-account istiod \
            --role-arn "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-role" \
            --profile "$LOCAL_ACCOUNT_PROFILE" \
            --region "$AWS_REGION" >/dev/null 2>&1 || \
            log_warn "Could not create pod identity association - Istio may not be installed yet"
    fi

    # Cleanup temp files
    rm -f /tmp/istiod-trust-policy.json /tmp/local-account-trust-policy.json \
          /tmp/external-account-trust-policy.json /tmp/istiod-permission-policy.json

    export LOCAL_ROLE="arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local"
    export EXTERNAL_ROLE="arn:aws:iam::${EXTERNAL_ACCOUNT}:role/istiod-external"
}

# Save environment to config file
save_multi_account_environment() {
    log_section "=== Saving Environment Variables ==="

    # Remove any existing section
    if grep -q "# === Generated by setup-infrastructure.sh" "$CONFIG_FILE" 2>/dev/null; then
        sed '/# === Generated by setup-infrastructure.sh/,$d' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    cat >> "$CONFIG_FILE" <<EOF

# === Generated by setup-infrastructure.sh on $(date) ===

# VPC and Network Resources
export LOCAL_VPC="$LOCAL_VPC"
export EXTERNAL_VPC="$EXTERNAL_VPC"
export LOCAL_CIDR="$LOCAL_CIDR"
export EXTERNAL_CIDR="$EXTERNAL_CIDR"
export PEERING_ID="$PEERING_ID"

# External Account Subnets
export EXTERNAL_SUBNET_1="$EXTERNAL_SUBNET_1"
export EXTERNAL_SUBNET_2="$EXTERNAL_SUBNET_2"
export EXTERNAL_SUBNET_3="$EXTERNAL_SUBNET_3"
export EXTERNAL_PUBLIC_SUBNET="$EXTERNAL_PUBLIC_SUBNET"
export EXTERNAL_SUBNETS="$EXTERNAL_SUBNETS"

# Network Infrastructure
export EXTERNAL_IGW="$EXTERNAL_IGW"
export EXTERNAL_NAT="$EXTERNAL_NAT"
export EXTERNAL_EIP="$EXTERNAL_EIP"
export EXTERNAL_PUBLIC_RT="$EXTERNAL_PUBLIC_RT"
export EXTERNAL_PRIVATE_RT="$EXTERNAL_PRIVATE_RT"

# Security Groups
export EXTERNAL_SG="$EXTERNAL_SG"
export LOCAL_CLUSTER_SG="$LOCAL_CLUSTER_SG"

# IAM Roles
export LOCAL_ROLE="$LOCAL_ROLE"
export EXTERNAL_ROLE="$EXTERNAL_ROLE"
EOF

    log_info "Infrastructure variables saved to: $CONFIG_FILE"
}

# Setup for scenario 3 (full cross-account)
setup_multi_account() {
    log_section "=== Cross-Account Setup ==="

    log_info "Running full infrastructure setup for Scenario 3..."
    log_info "This will create:"
    log_info "  - External VPC with subnets"
    log_info "  - VPC peering between accounts"
    log_info "  - NAT Gateway and Internet Gateway"
    log_info "  - Security groups"
    log_info "  - IAM roles for Istiod"
    log_info ""

    # Validate required variables for cross-account
    if [ -z "$EXTERNAL_ACCOUNT" ] || [ -z "$EXTERNAL_ACCOUNT_PROFILE" ]; then
        log_error "Cross-account setup requires EXTERNAL_ACCOUNT and EXTERNAL_ACCOUNT_PROFILE"
        exit 1
    fi

    validate_eks_cluster

    local failed_steps=()

    create_external_vpc || failed_steps+=("create_external_vpc")
    create_subnets || failed_steps+=("create_subnets")
    create_internet_gateway || failed_steps+=("create_internet_gateway")
    create_nat_gateway || failed_steps+=("create_nat_gateway")
    configure_route_tables || failed_steps+=("configure_route_tables")
    setup_vpc_peering || failed_steps+=("setup_vpc_peering")
    configure_security_groups || failed_steps+=("configure_security_groups")
    setup_cross_account_iam_roles || failed_steps+=("setup_cross_account_iam_roles")

    save_multi_account_environment

    if [ ${#failed_steps[@]} -eq 0 ]; then
        log_info ""
        log_info "✓ Cross-account setup complete!"
    else
        log_warn "Setup completed with some failures:"
        for step in "${failed_steps[@]}"; do
            log_warn "  - $step"
        done
    fi
}

# Main execution
main() {
    parse_options "$@"
    load_config
    validate_scenario

    echo ""
    log_section "=== Infrastructure Setup (Scenario $SCENARIO) ==="
    echo ""

    if [ "$MULTI_ACCOUNT" = true ]; then
        setup_multi_account
    else
        setup_single_account
    fi
}

# Run main function
main "$@"
