#!/bin/bash

# Exit on pipe failures but continue on individual command failures
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Validate required environment variables
validate_env() {
    local required_vars=(
        "LOCAL_ACCOUNT"
        "EXTERNAL_ACCOUNT"
        "LOCAL_ACCOUNT_PROFILE"
        "EXTERNAL_ACCOUNT_PROFILE"
        "AWS_REGION"
        "CLUSTER_NAME"
    )
    
    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "Required environment variable $var is not set"
            exit 1
        fi
    done
    
    export INT=$LOCAL_ACCOUNT_PROFILE
    export EXT=$EXTERNAL_ACCOUNT_PROFILE
}

# Discover and validate LOCAL_VPC from EKS cluster
discover_local_vpc() {
    log_info "=== Discovering Local VPC from EKS Cluster ==="
    
    log_info "Looking for EKS cluster: $CLUSTER_NAME"
    log_info "Using profile: $INT"
    log_info "Region: $AWS_REGION"
    
    # Check if cluster exists
    if ! aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --profile "$INT" \
        --region "$AWS_REGION" \
        --output json &>/dev/null; then
        log_error "EKS cluster '$CLUSTER_NAME' not found in region $AWS_REGION"
        log_error ""
        log_error "Available EKS clusters in this account/region:"
        aws eks list-clusters \
            --profile "$INT" \
            --region "$AWS_REGION" \
            --query 'clusters' \
            --output table 2>/dev/null || log_error "  (Unable to list clusters)"
        log_error ""
        log_error "Please check your CLUSTER_NAME environment variable"
        log_error "Current value: CLUSTER_NAME=$CLUSTER_NAME"
        log_error ""
        log_error "To fix this:"
        log_error "  1. List your EKS clusters: aws eks list-clusters --profile $INT --region $AWS_REGION"
        log_error "  2. Set the correct cluster name: export CLUSTER_NAME=<your-actual-cluster-name>"
        log_error "  3. Re-run this script"
        log_error ""
        exit 1
    fi
    
    # Get local VPC ID from EKS cluster
    local discovered_vpc=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.resourcesVpcConfig.vpcId' \
        --output text \
        --profile "$INT" \
        --region "$AWS_REGION")
    
    if ! resource_exists "$discovered_vpc"; then
        log_error "Could not find VPC for EKS cluster $CLUSTER_NAME"
        exit 1
    fi
    
    # Get VPC name and CIDR for informational purposes
    local vpc_name=$(aws ec2 describe-vpcs \
        --vpc-ids "$discovered_vpc" \
        --query 'Vpcs[0].Tags[?Key==`Name`].Value | [0]' \
        --output text \
        --profile "$INT" 2>/dev/null || echo "N/A")
    
    local discovered_cidr=$(aws ec2 describe-vpcs \
        --vpc-ids "$discovered_vpc" \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --profile "$INT")
    
    log_info "✓ Found EKS cluster: $CLUSTER_NAME"
    log_info "✓ VPC ID: $discovered_vpc"
    log_info "✓ VPC Name: $vpc_name"
    log_info "✓ VPC CIDR: $discovered_cidr"
    
    # Warn if LOCAL_VPC was already set to a different value
    if [ -n "$LOCAL_VPC" ] && [ "$LOCAL_VPC" != "$discovered_vpc" ]; then
        log_warn "LOCAL_VPC environment variable was set to: $LOCAL_VPC"
        log_warn "But the EKS cluster '$CLUSTER_NAME' is actually using VPC: $discovered_vpc"
        log_warn "Using the correct VPC from the EKS cluster: $discovered_vpc"
    fi
    
    # Export the discovered values
    export LOCAL_VPC="$discovered_vpc"
    export LOCAL_CIDR="$discovered_cidr"
    
    log_info ""
}

# Check if resource exists
resource_exists() {
    [ -n "$1" ] && [ "$1" != "None" ] && [ "$1" != "null" ]
}

# Wait for NAT Gateway to be available
wait_for_nat_gateway() {
    local nat_id=$1
    log_info "Waiting for NAT Gateway $nat_id to become available..."
    aws ec2 wait nat-gateway-available --nat-gateway-ids "$nat_id" --profile "$EXT" 2>/dev/null || true
    log_info "NAT Gateway is now available"
}

# Wait for VPC peering to be available
wait_for_peering() {
    local peering_id=$1
    log_info "Waiting for VPC Peering Connection $peering_id to be active..."
    aws ec2 wait vpc-peering-connection-exists --vpc-peering-connection-ids "$peering_id" --profile "$INT" 2>/dev/null || true
    # Additional check for active state
    local max_attempts=30
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        local state=$(aws ec2 describe-vpc-peering-connections \
            --vpc-peering-connection-ids "$peering_id" \
            --query 'VpcPeeringConnections[0].Status.Code' \
            --output text \
            --profile "$INT")
        
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

# Step 1: Create VPC in External Account
create_external_vpc() {
    log_info "=== Creating VPC in External Account ==="
    
    # Check if VPC exists
    EXTERNAL_VPC=$(aws ec2 describe-vpcs \
        --filters "Name=tag:Name,Values=istio-ecs-external-vpc" \
        --query 'Vpcs[0].VpcId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_VPC"; then
        log_info "VPC already exists: $EXTERNAL_VPC"
    else
        EXTERNAL_VPC=$(aws ec2 create-vpc \
            --cidr-block 10.1.0.0/16 \
            --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=istio-ecs-external-vpc}]' \
            --query 'Vpc.VpcId' \
            --output text \
            --profile "$EXT")
        log_info "Created VPC: $EXTERNAL_VPC"
        
        # Enable DNS
        aws ec2 modify-vpc-attribute --vpc-id "$EXTERNAL_VPC" --enable-dns-hostnames --profile "$EXT"
        aws ec2 modify-vpc-attribute --vpc-id "$EXTERNAL_VPC" --enable-dns-support --profile "$EXT"
    fi
    
    export EXTERNAL_VPC
}

# Step 2: Create Subnets
create_subnets() {
    log_info "=== Creating Subnets ==="
    
    # Private Subnet 1
    EXTERNAL_SUBNET_1=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-1" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
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
            --profile "$EXT")
        log_info "Created Private Subnet 1: $EXTERNAL_SUBNET_1"
    fi
    
    # Private Subnet 2
    EXTERNAL_SUBNET_2=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-2" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
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
            --profile "$EXT")
        log_info "Created Private Subnet 2: $EXTERNAL_SUBNET_2"
    fi
    
    # Private Subnet 3
    EXTERNAL_SUBNET_3=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-3" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
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
            --profile "$EXT")
        log_info "Created Private Subnet 3: $EXTERNAL_SUBNET_3"
    fi
    
    # Public Subnet
    EXTERNAL_PUBLIC_SUBNET=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-public" \
        --query 'Subnets[0].SubnetId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_PUBLIC_SUBNET"; then
        log_info "Public Subnet already exists: $EXTERNAL_PUBLIC_SUBNET"
    else
        EXTERNAL_PUBLIC_SUBNET=$(aws ec2 create-subnet \
            --vpc-id "$EXTERNAL_VPC" \
            --cidr-block 10.1.10.0/24 \
            --availability-zone "${AWS_REGION}a" \
            --tag-specifications 'ResourceType=subnet,Tags=[{Key=Name,Value=istio-ecs-public}]' \
            --query 'Subnet.SubnetId' \
            --output text \
            --profile "$EXT")
        log_info "Created Public Subnet: $EXTERNAL_PUBLIC_SUBNET"
    fi
    
    export EXTERNAL_SUBNET_1 EXTERNAL_SUBNET_2 EXTERNAL_SUBNET_3 EXTERNAL_PUBLIC_SUBNET
    export EXTERNAL_SUBNETS="${EXTERNAL_SUBNET_1},${EXTERNAL_SUBNET_2},${EXTERNAL_SUBNET_3}"
}

# Step 3: Create Internet Gateway
create_internet_gateway() {
    log_info "=== Creating Internet Gateway ==="
    
    # Check if IGW exists
    EXTERNAL_IGW=$(aws ec2 describe-internet-gateways \
        --filters "Name=tag:Name,Values=istio-ecs-igw" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_IGW"; then
        log_info "Internet Gateway already exists: $EXTERNAL_IGW"
    else
        EXTERNAL_IGW=$(aws ec2 create-internet-gateway \
            --tag-specifications 'ResourceType=internet-gateway,Tags=[{Key=Name,Value=istio-ecs-igw}]' \
            --query 'InternetGateway.InternetGatewayId' \
            --output text \
            --profile "$EXT")
        log_info "Created Internet Gateway: $EXTERNAL_IGW"
    fi
    
    # Attach to VPC (idempotent)
    local attached=$(aws ec2 describe-internet-gateways \
        --internet-gateway-ids "$EXTERNAL_IGW" \
        --query 'InternetGateways[0].Attachments[?VpcId==`'"$EXTERNAL_VPC"'`].State' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if [ "$attached" != "available" ]; then
        aws ec2 attach-internet-gateway \
            --vpc-id "$EXTERNAL_VPC" \
            --internet-gateway-id "$EXTERNAL_IGW" \
            --profile "$EXT" 2>/dev/null || log_warn "IGW already attached"
        log_info "Attached Internet Gateway to VPC"
    else
        log_info "Internet Gateway already attached to VPC"
    fi
    
    export EXTERNAL_IGW
}

# Step 4: Create NAT Gateway
create_nat_gateway() {
    log_info "=== Creating NAT Gateway ==="
    
    # Check if NAT Gateway exists
    EXTERNAL_NAT=$(aws ec2 describe-nat-gateways \
        --filter "Name=subnet-id,Values=$EXTERNAL_PUBLIC_SUBNET" "Name=state,Values=available,pending" \
        --query 'NatGateways[0].NatGatewayId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_NAT"; then
        log_info "NAT Gateway already exists: $EXTERNAL_NAT"
        EXTERNAL_EIP=$(aws ec2 describe-nat-gateways \
            --nat-gateway-ids "$EXTERNAL_NAT" \
            --query 'NatGateways[0].NatGatewayAddresses[0].AllocationId' \
            --output text \
            --profile "$EXT")
    else
        # Allocate Elastic IP
        EXTERNAL_EIP=$(aws ec2 allocate-address \
            --domain vpc \
            --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Name,Value=istio-ecs-nat-eip}]' \
            --query 'AllocationId' \
            --output text \
            --profile "$EXT")
        log_info "Allocated Elastic IP: $EXTERNAL_EIP"
        
        # Create NAT Gateway
        EXTERNAL_NAT=$(aws ec2 create-nat-gateway \
            --subnet-id "$EXTERNAL_PUBLIC_SUBNET" \
            --allocation-id "$EXTERNAL_EIP" \
            --tag-specifications 'ResourceType=natgateway,Tags=[{Key=Name,Value=istio-ecs-nat}]' \
            --query 'NatGateway.NatGatewayId' \
            --output text \
            --profile "$EXT")
        log_info "Created NAT Gateway: $EXTERNAL_NAT"
        
        wait_for_nat_gateway "$EXTERNAL_NAT"
    fi
    
    export EXTERNAL_NAT EXTERNAL_EIP
}

# Step 5: Configure Route Tables
configure_route_tables() {
    log_info "=== Configuring Route Tables ==="
    
    # Public Route Table
    EXTERNAL_PUBLIC_RT=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-public-rt" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_PUBLIC_RT"; then
        log_info "Public Route Table already exists: $EXTERNAL_PUBLIC_RT"
    else
        EXTERNAL_PUBLIC_RT=$(aws ec2 create-route-table \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=istio-ecs-public-rt}]' \
            --query 'RouteTable.RouteTableId' \
            --output text \
            --profile "$EXT")
        log_info "Created Public Route Table: $EXTERNAL_PUBLIC_RT"
    fi
    
    # Add route to Internet Gateway (idempotent)
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PUBLIC_RT" \
        --destination-cidr-block 0.0.0.0/0 \
        --gateway-id "$EXTERNAL_IGW" \
        --profile "$EXT" 2>/dev/null || log_info "Route to IGW already exists"
    
    # Associate public subnet
    local assoc=$(aws ec2 describe-route-tables \
        --route-table-ids "$EXTERNAL_PUBLIC_RT" \
        --query "RouteTables[0].Associations[?SubnetId=='$EXTERNAL_PUBLIC_SUBNET'].SubnetId" \
        --output text \
        --profile "$EXT" 2>/dev/null)
    
    if [ -z "$assoc" ]; then
        aws ec2 associate-route-table \
            --route-table-id "$EXTERNAL_PUBLIC_RT" \
            --subnet-id "$EXTERNAL_PUBLIC_SUBNET" \
            --profile "$EXT" >/dev/null
        log_info "Associated public subnet with public route table"
    else
        log_info "Public subnet already associated with route table"
    fi
    
    # Private Route Table
    EXTERNAL_PRIVATE_RT=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=tag:Name,Values=istio-ecs-private-rt" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_PRIVATE_RT"; then
        log_info "Private Route Table already exists: $EXTERNAL_PRIVATE_RT"
    else
        EXTERNAL_PRIVATE_RT=$(aws ec2 create-route-table \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=route-table,Tags=[{Key=Name,Value=istio-ecs-private-rt}]' \
            --query 'RouteTable.RouteTableId' \
            --output text \
            --profile "$EXT")
        log_info "Created Private Route Table: $EXTERNAL_PRIVATE_RT"
    fi
    
    # Add route to NAT Gateway (idempotent)
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PRIVATE_RT" \
        --destination-cidr-block 0.0.0.0/0 \
        --nat-gateway-id "$EXTERNAL_NAT" \
        --profile "$EXT" 2>/dev/null || log_info "Route to NAT Gateway already exists"
    
    # Associate private subnets
    for subnet in "$EXTERNAL_SUBNET_1" "$EXTERNAL_SUBNET_2" "$EXTERNAL_SUBNET_3"; do
        local assoc=$(aws ec2 describe-route-tables \
            --route-table-ids "$EXTERNAL_PRIVATE_RT" \
            --query "RouteTables[0].Associations[?SubnetId=='$subnet'].SubnetId" \
            --output text \
            --profile "$EXT" 2>/dev/null)
        
        if [ -z "$assoc" ]; then
            aws ec2 associate-route-table \
                --route-table-id "$EXTERNAL_PRIVATE_RT" \
                --subnet-id "$subnet" \
                --profile "$EXT" >/dev/null
            log_info "Associated subnet $subnet with private route table"
        fi
    done
    
    export EXTERNAL_PUBLIC_RT EXTERNAL_PRIVATE_RT
}

# Step 6: Setup VPC Peering
setup_vpc_peering() {
    log_info "=== Setting Up VPC Peering ==="
    
    log_info "Using Local VPC: $LOCAL_VPC (CIDR: $LOCAL_CIDR)"
    log_info "Using External VPC: $EXTERNAL_VPC"
    
    # Check if peering connection exists
    PEERING_ID=$(aws ec2 describe-vpc-peering-connections \
        --filters "Name=requester-vpc-info.vpc-id,Values=$LOCAL_VPC" \
                  "Name=accepter-vpc-info.vpc-id,Values=$EXTERNAL_VPC" \
                  "Name=status-code,Values=active,pending-acceptance" \
        --query 'VpcPeeringConnections[0].VpcPeeringConnectionId' \
        --output text \
        --profile "$INT" 2>/dev/null || echo "")
    
    if resource_exists "$PEERING_ID"; then
        log_info "VPC Peering Connection already exists: $PEERING_ID"
    else
        # Create peering connection
        PEERING_ID=$(aws ec2 create-vpc-peering-connection \
            --vpc-id "$LOCAL_VPC" \
            --peer-vpc-id "$EXTERNAL_VPC" \
            --peer-owner-id "$EXTERNAL_ACCOUNT" \
            --peer-region "$AWS_REGION" \
            --tag-specifications 'ResourceType=vpc-peering-connection,Tags=[{Key=Name,Value=istio-multi-account-peering}]' \
            --query 'VpcPeeringConnection.VpcPeeringConnectionId' \
            --output text \
            --profile "$INT")
        log_info "Created VPC Peering Connection: $PEERING_ID"
        
        # Accept peering connection
        aws ec2 accept-vpc-peering-connection \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$EXT" >/dev/null
        log_info "Accepted VPC Peering Connection"
        
        wait_for_peering "$PEERING_ID"
    fi
    
    # Get External CIDR (LOCAL_CIDR was already discovered in discover_local_vpc)
    EXTERNAL_CIDR=$(aws ec2 describe-vpcs \
        --vpc-ids "$EXTERNAL_VPC" \
        --query 'Vpcs[0].CidrBlock' \
        --output text \
        --profile "$EXT")
    
    log_info "Local CIDR: $LOCAL_CIDR, External CIDR: $EXTERNAL_CIDR"
    
    # Add routes in external account
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PRIVATE_RT" \
        --destination-cidr-block "$LOCAL_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" \
        --profile "$EXT" 2>/dev/null || log_info "Peering route in external private RT already exists"
    
    aws ec2 create-route \
        --route-table-id "$EXTERNAL_PUBLIC_RT" \
        --destination-cidr-block "$LOCAL_CIDR" \
        --vpc-peering-connection-id "$PEERING_ID" \
        --profile "$EXT" 2>/dev/null || log_info "Peering route in external public RT already exists"
    
    # Add routes in local account
    LOCAL_ROUTE_TABLES=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$LOCAL_VPC" \
        --query 'RouteTables[*].RouteTableId' \
        --output text \
        --profile "$INT")
    
    for rt in $LOCAL_ROUTE_TABLES; do
        aws ec2 create-route \
            --route-table-id "$rt" \
            --destination-cidr-block "$EXTERNAL_CIDR" \
            --vpc-peering-connection-id "$PEERING_ID" \
            --profile "$INT" 2>/dev/null || true
    done
    log_info "Added peering routes to local route tables"
    
    export LOCAL_VPC PEERING_ID LOCAL_CIDR EXTERNAL_CIDR
}

# Step 7: Configure Security Groups
configure_security_groups() {
    log_info "=== Configuring Security Groups ==="
    
    # External Security Group
    EXTERNAL_SG=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$EXTERNAL_VPC" "Name=group-name,Values=istio-ecs-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --profile "$EXT" 2>/dev/null || echo "")
    
    if resource_exists "$EXTERNAL_SG"; then
        log_info "External Security Group already exists: $EXTERNAL_SG"
    else
        EXTERNAL_SG=$(aws ec2 create-security-group \
            --group-name istio-ecs-sg \
            --description "Security group for Istio ECS services" \
            --vpc-id "$EXTERNAL_VPC" \
            --tag-specifications 'ResourceType=security-group,Tags=[{Key=Name,Value=istio-ecs-sg}]' \
            --query 'GroupId' \
            --output text \
            --profile "$EXT")
        log_info "Created External Security Group: $EXTERNAL_SG"
    fi
    
    # Add ingress rules (idempotent - will fail if rule exists, which is fine)
    # Allow HTTPS from local VPC
    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol tcp \
        --port 443 \
        --cidr "$LOCAL_CIDR" \
        --profile "$EXT" 2>/dev/null || log_info "HTTPS rule already exists"
    
    # Allow all traffic within security group
    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol -1 \
        --source-group "$EXTERNAL_SG" \
        --profile "$EXT" 2>/dev/null || log_info "Self-referencing rule already exists"
    
    # Allow HBONE port 15008
    aws ec2 authorize-security-group-ingress \
        --group-id "$EXTERNAL_SG" \
        --protocol tcp \
        --port 15008 \
        --cidr "$LOCAL_CIDR" \
        --profile "$EXT" 2>/dev/null || log_info "HBONE rule already exists"
    
    # Get Local Cluster Security Group
    LOCAL_CLUSTER_SG=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
        --output text \
        --profile "$INT")
    
    if resource_exists "$LOCAL_CLUSTER_SG"; then
        log_info "Local Cluster Security Group: $LOCAL_CLUSTER_SG"
        
        # Add ingress rules to local cluster SG
        aws ec2 authorize-security-group-ingress \
            --group-id "$LOCAL_CLUSTER_SG" \
            --protocol tcp \
            --port 443 \
            --cidr "$EXTERNAL_CIDR" \
            --profile "$INT" 2>/dev/null || log_info "External HTTPS rule already exists in local SG"
        
        aws ec2 authorize-security-group-ingress \
            --group-id "$LOCAL_CLUSTER_SG" \
            --protocol tcp \
            --port 15008 \
            --cidr "$EXTERNAL_CIDR" \
            --profile "$INT" 2>/dev/null || log_info "External HBONE rule already exists in local SG"
        
        aws ec2 authorize-security-group-ingress \
            --group-id "$LOCAL_CLUSTER_SG" \
            --protocol tcp \
            --port 15012 \
            --cidr "$EXTERNAL_CIDR" \
            --profile "$INT" 2>/dev/null || log_info "External XDS rule already exists in local SG"
    fi
    
    export EXTERNAL_SG LOCAL_CLUSTER_SG
}

# Step 8: Setup IAM Roles
setup_iam_roles() {
    log_info "=== Setting Up IAM Roles ==="
    
    # Create trust policy for external accounts
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
    
    # Create istiod trust policy
    cat > /tmp/istiod-trust-policy.json <<'EOF'
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
    local role_exists=$(aws iam get-role --role-name istiod-role --profile "$INT" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        aws iam create-role \
            --role-name istiod-role \
            --assume-role-policy-document file:///tmp/istiod-trust-policy.json \
            --profile "$INT" >/dev/null
        log_info "Created istiod-role in local account"
        
        # Wait for IAM role to propagate (required for it to be used as a principal)
        log_info "Waiting for istiod-role to propagate in AWS IAM..."
        sleep 10
        
        # Verify role exists and is accessible
        local retries=0
        while [ $retries -lt 6 ]; do
            if aws iam get-role --role-name istiod-role --profile "$INT" >/dev/null 2>&1; then
                log_info "Role propagation verified"
                break
            fi
            retries=$((retries + 1))
            log_info "Waiting for role propagation (attempt $retries/6)..."
            sleep 5
        done
    else
        log_info "istiod-role already exists in local account"
    fi
    
    # Create istiod-local role in local account
    role_exists=$(aws iam get-role --role-name istiod-local --profile "$INT" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        # Retry logic for role creation (handles IAM propagation delays)
        local retries=0
        local max_retries=5
        local created=false
        
        while [ $retries -lt $max_retries ] && [ "$created" = false ]; do
            if aws iam create-role \
                --role-name istiod-local \
                --assume-role-policy-document file:///tmp/external-account-trust-policy.json \
                --profile "$INT" >/dev/null 2>&1; then
                log_info "Created istiod-local role in local account"
                created=true
            else
                retries=$((retries + 1))
                if [ $retries -lt $max_retries ]; then
                    log_warn "Failed to create istiod-local (attempt $retries/$max_retries), retrying in 10 seconds..."
                    log_warn "This is often due to IAM propagation delays"
                    sleep 10
                else
                    log_error "Failed to create istiod-local after $max_retries attempts"
                    log_error "The istiod-role may not have propagated yet"
                    return 1
                fi
            fi
        done
        
        if [ "$created" = true ]; then
            aws iam attach-role-policy \
                --role-name istiod-local \
                --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
                --profile "$INT"
            log_info "Attached AmazonECS_FullAccess to istiod-local"
        fi
    else
        log_info "istiod-local role already exists in local account"
    fi
    
    # Create istiod-external role in external account
    role_exists=$(aws iam get-role --role-name istiod-external --profile "$EXT" 2>/dev/null || echo "")
    if [ -z "$role_exists" ]; then
        # Retry logic for role creation (handles IAM propagation delays)
        local retries=0
        local max_retries=5
        local created=false
        
        while [ $retries -lt $max_retries ] && [ "$created" = false ]; do
            if aws iam create-role \
                --role-name istiod-external \
                --assume-role-policy-document file:///tmp/external-account-trust-policy.json \
                --profile "$EXT" >/dev/null 2>&1; then
                log_info "Created istiod-external role in external account"
                created=true
            else
                retries=$((retries + 1))
                if [ $retries -lt $max_retries ]; then
                    log_warn "Failed to create istiod-external (attempt $retries/$max_retries), retrying in 10 seconds..."
                    log_warn "This is often due to IAM propagation delays"
                    sleep 10
                else
                    log_error "Failed to create istiod-external after $max_retries attempts"
                    log_error "The istiod-role may not have propagated yet"
                    return 1
                fi
            fi
        done
        
        if [ "$created" = true ]; then
            aws iam attach-role-policy \
                --role-name istiod-external \
                --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess \
                --profile "$EXT"
            log_info "Attached AmazonECS_FullAccess to istiod-external"
        fi
    else
        log_info "istiod-external role already exists in external account"
    fi
    
    # Create permission policy for istiod-role
    cat > /tmp/istiod-permission-policy.json <<EOF
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
        },
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ],
            "Resource": [
                "arn:aws:iam::${EXTERNAL_ACCOUNT}:role/istiod-external"
            ]
        }
    ]
}
EOF
    
    # Create or update policy
    local policy_arn="arn:aws:iam::${LOCAL_ACCOUNT}:policy/istiod-permission-policy"
    local policy_exists=$(aws iam get-policy --policy-arn "$policy_arn" --profile "$INT" 2>/dev/null || echo "")
    
    if [ -z "$policy_exists" ]; then
        aws iam create-policy \
            --policy-document file:///tmp/istiod-permission-policy.json \
            --policy-name istiod-permission-policy \
            --profile "$INT" >/dev/null
        log_info "Created istiod-permission-policy"
    else
        log_info "istiod-permission-policy already exists"
        # Update policy with new version
        aws iam create-policy-version \
            --policy-arn "$policy_arn" \
            --policy-document file:///tmp/istiod-permission-policy.json \
            --set-as-default \
            --profile "$INT" 2>/dev/null || log_info "Policy already up to date"
    fi
    
    # Attach policy to istiod-role
    aws iam attach-role-policy \
        --role-name istiod-role \
        --policy-arn "$policy_arn" \
        --profile "$INT" 2>/dev/null || log_info "Policy already attached to istiod-role"
    
    # Update pod identity association
    local assoc_id=$(aws eks list-pod-identity-associations \
        --cluster-name "$CLUSTER_NAME" \
        --query 'associations[0].associationId' \
        --output text \
        --profile "$INT" 2>/dev/null || echo "")
    
    if resource_exists "$assoc_id" && [ "$assoc_id" != "None" ]; then
        aws eks update-pod-identity-association \
            --cluster-name "$CLUSTER_NAME" \
            --association-id "$assoc_id" \
            --role-arn "arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-role" \
            --profile "$INT" >/dev/null 2>&1 || log_warn "Could not update pod identity association"
        log_info "Updated EKS pod identity association"
    else
        log_warn "No pod identity association found - you may need to create one after Istio installation"
    fi
    
    export LOCAL_ROLE="arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local"
    export EXTERNAL_ROLE="arn:aws:iam::${EXTERNAL_ACCOUNT}:role/istiod-external"
}

# Save environment to file
save_environment() {
    log_info "=== Saving Environment Variables ==="
    
    cat > /tmp/ecs-multi-account-env.sh <<EOF
# Generated by setup-ecs-multi-account.sh on $(date)

export LOCAL_ACCOUNT="$LOCAL_ACCOUNT"
export EXTERNAL_ACCOUNT="$EXTERNAL_ACCOUNT"
export LOCAL_ACCOUNT_PROFILE="$LOCAL_ACCOUNT_PROFILE"
export EXTERNAL_ACCOUNT_PROFILE="$EXTERNAL_ACCOUNT_PROFILE"
export INT="$INT"
export EXT="$EXT"
export AWS_REGION="$AWS_REGION"
export CLUSTER_NAME="$CLUSTER_NAME"

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
    
    log_info "Environment saved to: /tmp/ecs-multi-account-env.sh"
    log_info "To load these variables in a new shell, run: source /tmp/ecs-multi-account-env.sh"
}

# Main execution
main() {
    log_info "Starting ECS Multi-Account Setup"
    log_info "========================================"
    
    validate_env
    discover_local_vpc
    
    local failed_steps=()
    
    create_external_vpc || failed_steps+=("create_external_vpc")
    create_subnets || failed_steps+=("create_subnets")
    create_internet_gateway || failed_steps+=("create_internet_gateway")
    create_nat_gateway || failed_steps+=("create_nat_gateway")
    configure_route_tables || failed_steps+=("configure_route_tables")
    setup_vpc_peering || failed_steps+=("setup_vpc_peering")
    configure_security_groups || failed_steps+=("configure_security_groups")
    setup_iam_roles || failed_steps+=("setup_iam_roles")
    
    # Always save environment, even if some steps failed
    save_environment
    
    log_info "========================================"
    if [ ${#failed_steps[@]} -eq 0 ]; then
        log_info "Setup Complete!"
        log_info ""
        log_info "Next Steps:"
        log_info "1. Install Istio with multi-account configuration"
        log_info "2. Deploy ECS services in both accounts"
        log_info "3. Test cross-account service mesh communication"
    else
        log_warn "Setup completed with some failures:"
        for step in "${failed_steps[@]}"; do
            log_warn "  - $step"
        done
        log_warn ""
        log_warn "Environment has been saved, but you may need to:"
        log_warn "1. Review the errors above"
        log_warn "2. Fix any issues manually"
        log_warn "3. Re-run this script (it's idempotent)"
    fi
    log_info ""
    log_info "All environment variables have been saved to: /tmp/ecs-multi-account-env.sh"
    log_info "Load them with: source /tmp/ecs-multi-account-env.sh"
}

# Run main function
main "$@"
