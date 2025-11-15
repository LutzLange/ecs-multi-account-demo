#!/bin/bash

# diagnose-ecs-failure.sh
# Quick diagnostic script to analyze ECS deployment failures

set -o pipefail

# Source environment if available
if [ -f "./ecs-multi-account-env.sh" ]; then
    source ./ecs-multi-account-env.sh
fi

# Color codes
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  ECS Deployment Failure Diagnostics${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Check if we have the required environment variables
if [ -z "$EXTERNAL_ACCOUNT_PROFILE" ] || [ -z "$AWS_REGION" ]; then
    echo -e "${RED}Error: Environment not loaded${NC}"
    echo "Please run: source ./ecs-multi-account-env.sh"
    exit 1
fi

CLUSTER="ecs-aws-accounts-3"
SERVICE="echo-service"
PROFILE="$EXTERNAL_ACCOUNT_PROFILE"
REGION="$AWS_REGION"

echo -e "${BLUE}Checking cluster: $CLUSTER${NC}"
echo -e "${BLUE}Service: $SERVICE${NC}"
echo -e "${BLUE}Profile: $PROFILE${NC}"
echo -e "${BLUE}Region: $REGION${NC}"
echo ""

# 1. Check if cluster exists
echo -e "${YELLOW}[1/6] Cluster Status${NC}"
aws ecs describe-clusters \
    --clusters "$CLUSTER" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'clusters[0].{Status:status,RunningTasks:runningTasksCount,PendingTasks:pendingTasksCount}' \
    --output table
echo ""

# 2. Check service status
echo -e "${YELLOW}[2/6] Service Status${NC}"
SERVICE_EXISTS=$(aws ecs describe-services \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'services[0].serviceName' \
    --output text 2>/dev/null)

if [ "$SERVICE_EXISTS" = "$SERVICE" ]; then
    echo -e "${GREEN}Service exists${NC}"
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'services[0].{Status:status,DesiredCount:desiredCount,RunningCount:runningCount,PendingCount:pendingCount}' \
        --output table
else
    echo -e "${RED}Service does NOT exist${NC}"
    
    # Check for failures
    echo ""
    echo -e "${YELLOW}Checking for service creation failures...${NC}"
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'failures' \
        --output json
fi
echo ""

# 3. Check recent service events
echo -e "${YELLOW}[3/6] Recent Service Events${NC}"
if [ "$SERVICE_EXISTS" = "$SERVICE" ]; then
    aws ecs describe-services \
        --cluster "$CLUSTER" \
        --services "$SERVICE" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'services[0].events[0:5].[createdAt,message]' \
        --output table
else
    echo "Service does not exist - no events to show"
fi
echo ""

# 4. Check task definition
echo -e "${YELLOW}[4/6] Task Definition Status${NC}"
TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "${SERVICE}-definition" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'taskDefinition.{Family:family,Revision:revision,Status:status,TaskRole:taskRoleArn,NetworkMode:networkMode}' \
    --output table 2>&1)

if echo "$TASK_DEF" | grep -q "Unable to describe task definition"; then
    echo -e "${RED}Task definition does NOT exist${NC}"
    echo ""
    echo -e "${YELLOW}Available task definitions:${NC}"
    aws ecs list-task-definitions \
        --profile "$PROFILE" \
        --region "$REGION" \
        --family-prefix "echo" \
        --output table
else
    echo "$TASK_DEF"
fi
echo ""

# 5. Check IAM role
echo -e "${YELLOW}[5/6] IAM Task Role Verification${NC}"
if [ -n "$EXTERNAL_TASK_ROLE_ARN" ]; then
    echo "Configured role: $EXTERNAL_TASK_ROLE_ARN"
    
    ROLE_NAME=$(echo "$EXTERNAL_TASK_ROLE_ARN" | awk -F'/' '{print $NF}')
    
    # Try to get role (this will fail if role doesn't exist or we don't have permissions)
    ROLE_CHECK=$(aws iam get-role \
        --role-name "$ROLE_NAME" \
        --profile "$PROFILE" \
        --query 'Role.{RoleName:RoleName,CreateDate:CreateDate}' \
        --output table 2>&1)
    
    if echo "$ROLE_CHECK" | grep -q "NoSuchEntity"; then
        echo -e "${RED}✗ Role does NOT exist${NC}"
    elif echo "$ROLE_CHECK" | grep -q "AccessDenied"; then
        echo -e "${YELLOW}⚠ Cannot verify role (permission denied - may still exist)${NC}"
    else
        echo -e "${GREEN}✓ Role exists${NC}"
        echo "$ROLE_CHECK"
    fi
else
    echo -e "${RED}EXTERNAL_TASK_ROLE_ARN not set${NC}"
fi
echo ""

# 6. Check network configuration
echo -e "${YELLOW}[6/6] Network Configuration${NC}"
echo "Subnets: $EXTERNAL_SUBNETS"
echo "Security Group: $EXTERNAL_SG"
echo "VPC: $EXTERNAL_VPC"
echo ""

# Verify subnets exist
echo -e "${YELLOW}Verifying subnets...${NC}"
for subnet in $(echo "$EXTERNAL_SUBNETS" | tr ',' ' '); do
    SUBNET_CHECK=$(aws ec2 describe-subnets \
        --subnet-ids "$subnet" \
        --profile "$PROFILE" \
        --region "$REGION" \
        --query 'Subnets[0].{SubnetId:SubnetId,AvailabilityZone:AvailabilityZone,CidrBlock:CidrBlock}' \
        --output table 2>&1)
    
    if echo "$SUBNET_CHECK" | grep -q "InvalidSubnetID"; then
        echo -e "${RED}✗ Subnet $subnet does NOT exist${NC}"
    else
        echo -e "${GREEN}✓ Subnet $subnet exists${NC}"
    fi
done
echo ""

# Verify security group exists
echo -e "${YELLOW}Verifying security group...${NC}"
SG_CHECK=$(aws ec2 describe-security-groups \
    --group-ids "$EXTERNAL_SG" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --query 'SecurityGroups[0].{GroupId:GroupId,GroupName:GroupName,VpcId:VpcId}' \
    --output table 2>&1)

if echo "$SG_CHECK" | grep -q "InvalidGroup"; then
    echo -e "${RED}✗ Security group $EXTERNAL_SG does NOT exist${NC}"
else
    echo -e "${GREEN}✓ Security group exists${NC}"
    echo "$SG_CHECK"
fi
echo ""

# Summary and recommendations
echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Diagnostic Summary${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

if [ "$SERVICE_EXISTS" != "$SERVICE" ]; then
    echo -e "${YELLOW}LIKELY CAUSES:${NC}"
    echo ""
    echo "1. Task definition missing or invalid"
    echo "   → Check: aws ecs describe-task-definition --task-definition echo-service-definition --profile $PROFILE --region $REGION"
    echo ""
    echo "2. IAM role doesn't exist or lacks permissions"
    echo "   → Check: aws iam get-role --role-name eks-ecs-task-role --profile $PROFILE"
    echo ""
    echo "3. Network configuration invalid (subnets/security groups)"
    echo "   → See subnet/SG verification above"
    echo ""
    echo "4. Service account tag mismatch in task definition"
    echo "   → Task definition must have tag: ecs.solo.io/service-account=ecs-demo-sa-external"
    echo ""
    
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    echo ""
    echo "1. Try creating the service manually with verbose output:"
    echo "   aws ecs create-service \\"
    echo "     --cluster $CLUSTER \\"
    echo "     --service-name $SERVICE \\"
    echo "     --task-definition ${SERVICE}-definition \\"
    echo "     --desired-count 1 \\"
    echo "     --launch-type FARGATE \\"
    echo "     --enable-execute-command \\"
    echo "     --network-configuration \"awsvpcConfiguration={subnets=[$EXTERNAL_SUBNETS],securityGroups=[$EXTERNAL_SG],assignPublicIp=DISABLED}\" \\"
    echo "     --profile $PROFILE \\"
    echo "     --region $REGION"
    echo ""
    echo "2. Check CloudWatch logs for task failures:"
    echo "   aws logs tail /ecs/ecs-demo --profile $PROFILE --region $REGION --follow=false --since 1h"
else
    echo -e "${GREEN}Service exists and is running${NC}"
    echo ""
    echo "Check the events above for any issues or warnings."
fi

echo ""
