#!/bin/bash

# create-iam-multi-account.sh
# Creates IAM roles for both LOCAL and EXTERNAL accounts

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROLE_PREFIX='/ecs/ambient/'
TASK_ROLE_NAME=eks-ecs-task-role
TASK_POLICY_NAME=eks-ecs-task-policy

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  IAM Role Creation for Multi-Account${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Function to create IAM role for an account
create_iam_for_account() {
    local account_type=$1  # "local" or "external"
    local aws_profile=$2
    
    echo -e "${GREEN}Creating IAM resources for ${account_type^^} account...${NC}"
    echo "Profile: ${aws_profile}"
    echo ""
    
    # Check if the task role exists
    if aws iam get-role --role-name $TASK_ROLE_NAME --profile $aws_profile > /dev/null 2>&1; then
        echo "  ✓ $TASK_ROLE_NAME already exists."
        ROLE_ARN=$(aws iam get-role --role-name $TASK_ROLE_NAME --profile $aws_profile --query 'Role.Arn' --output text)
        echo "    Existing role ARN: $ROLE_ARN"
    else
        echo "  Creating task role..."
        
        # Create the task role
        ROLE_ARN=$(aws iam create-role \
            --path "${ROLE_PREFIX}" \
            --role-name $TASK_ROLE_NAME \
            --assume-role-policy-document file://iam/trust-policy.json \
            --profile $aws_profile \
            --query 'Role.Arn' \
            --output text)
        
        # Wait until the role exists
        aws iam wait role-exists --role-name $TASK_ROLE_NAME --profile $aws_profile
        echo "    ✓ Role created: $ROLE_ARN"
    fi
    
    # Check if the task policy exists
    POLICY_ARN=$(aws iam list-policies \
        --profile $aws_profile \
        --query "Policies[?PolicyName=='$TASK_POLICY_NAME'].Arn" \
        --output text)
    
    if [ -z "$POLICY_ARN" ]; then
        echo "  Creating task policy..."
        
        # Create the task policy
        POLICY_ARN=$(aws iam create-policy \
            --path "${ROLE_PREFIX}" \
            --policy-name $TASK_POLICY_NAME \
            --policy-document file://iam/task-policy.json \
            --profile $aws_profile \
            --query 'Policy.Arn' \
            --output text)
        
        echo "    ✓ Policy created: $POLICY_ARN"
    else
        echo "  ✓ Policy $TASK_POLICY_NAME already exists."
        echo "    Existing policy ARN: $POLICY_ARN"
    fi
    
    # Attach the task policy to the task role
    aws iam attach-role-policy \
        --role-name $TASK_ROLE_NAME \
        --policy-arn $POLICY_ARN \
        --profile $aws_profile > /dev/null 2>&1 || true
    
    echo "  ✓ Policy attached to role"
    echo ""
    
    # Export the role ARN with appropriate variable name
    if [ "$account_type" == "local" ]; then
        export LOCAL_TASK_ROLE_ARN=$ROLE_ARN
        echo "LOCAL_TASK_ROLE_ARN exported: $LOCAL_TASK_ROLE_ARN"
    else
        export EXTERNAL_TASK_ROLE_ARN=$ROLE_ARN
        echo "EXTERNAL_TASK_ROLE_ARN exported: $EXTERNAL_TASK_ROLE_ARN"
    fi
    echo ""
}

# Main execution
main() {
    # Validate required environment variables
    if [ -z "$LOCAL_ACCOUNT_PROFILE" ] || [ -z "$EXTERNAL_ACCOUNT_PROFILE" ]; then
        echo -e "${YELLOW}Error: LOCAL_ACCOUNT_PROFILE and EXTERNAL_ACCOUNT_PROFILE must be set${NC}"
        echo "Example:"
        echo "  export LOCAL_ACCOUNT_PROFILE=default"
        echo "  export EXTERNAL_ACCOUNT_PROFILE=external-profile"
        exit 1
    fi
    
    # Check if IAM trust policy file exists
    if [ ! -f "iam/trust-policy.json" ]; then
        echo -e "${YELLOW}Error: iam/trust-policy.json not found${NC}"
        echo "Please ensure you have the iam/ directory with required policy files"
        exit 1
    fi
    
    if [ ! -f "iam/task-policy.json" ]; then
        echo -e "${YELLOW}Error: iam/task-policy.json not found${NC}"
        exit 1
    fi
    
    # Create IAM resources for both accounts
    create_iam_for_account "local" "$LOCAL_ACCOUNT_PROFILE"
    create_iam_for_account "external" "$EXTERNAL_ACCOUNT_PROFILE"
    
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  IAM Setup Complete!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Role ARNs have been exported:"
    echo "  LOCAL_TASK_ROLE_ARN=$LOCAL_TASK_ROLE_ARN"
    echo "  EXTERNAL_TASK_ROLE_ARN=$EXTERNAL_TASK_ROLE_ARN"
    echo ""
    echo "These variables are now available in your shell session."
    echo ""
}

# Run main function
main

# clean up enviornment
unset -f create_iam_for_account
unset -f main
unset GREEN BLUE YELLOW RED NC
unset ROLE_PREFIX TASK_ROLE_NAME TASK_POLICY_NAME

# Reset shell options
set +e
