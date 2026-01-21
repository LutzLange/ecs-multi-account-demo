#!/bin/bash

# create-iam-roles.sh
# Unified IAM role creation script that adapts based on SCENARIO variable
# Supports:
#   SCENARIO=1 or 2: Creates roles in local account only
#   SCENARIO=3: Creates roles in both local and external accounts

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

ROLE_PREFIX='/ecs/ambient/'
TASK_ROLE_NAME=eks-ecs-task-role
TASK_POLICY_NAME=eks-ecs-task-policy

# Default configuration file
CONFIG_FILE="env-config.sh"

# Parse command line options
parse_options() {
    local TEMP
    TEMP=$(getopt -o c: --long config: -n 'create-iam-roles.sh' -- "$@")

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
        echo -e "${YELLOW}Error: Configuration file not found: $CONFIG_FILE${NC}"
        echo ""
        echo "Please create $CONFIG_FILE with required variables"
        exit 1
    fi

    echo -e "${BLUE}Loading configuration from: $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
    echo ""
}

# Validate scenario
validate_scenario() {
    if [ -z "$SCENARIO" ]; then
        echo -e "${YELLOW}Error: SCENARIO variable not set in $CONFIG_FILE${NC}"
        echo "Please set SCENARIO=1, 2, or 3"
        exit 1
    fi

    case "$SCENARIO" in
        1|2)
            MULTI_ACCOUNT=false
            echo -e "${GREEN}Scenario $SCENARIO: Creating IAM roles in local account only${NC}"
            ;;
        3)
            MULTI_ACCOUNT=true
            echo -e "${GREEN}Scenario 3: Creating IAM roles in both accounts${NC}"
            ;;
        *)
            echo -e "${YELLOW}Error: Invalid SCENARIO value: $SCENARIO${NC}"
            exit 1
            ;;
    esac
    echo ""
}

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  IAM Role Creation${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Function to create IAM role for an account
create_iam_for_account() {
    local account_type=$1
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

# Save task role ARNs to config file
save_to_config() {
    echo -e "${BLUE}Saving task role ARNs to configuration...${NC}"

    # Remove any existing section generated by this script
    if grep -q "# === Generated by create-iam" "$CONFIG_FILE" 2>/dev/null; then
        sed '/# === Generated by create-iam/,/^$/d' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"
        mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    fi

    # Append task role ARNs
    cat >> "$CONFIG_FILE" <<EOF

# === Generated by create-iam-roles.sh on $(date) ===
export LOCAL_TASK_ROLE_ARN="$LOCAL_TASK_ROLE_ARN"
EOF

    if [ "$MULTI_ACCOUNT" = true ]; then
        cat >> "$CONFIG_FILE" <<EOF
export EXTERNAL_TASK_ROLE_ARN="$EXTERNAL_TASK_ROLE_ARN"
EOF
    fi

    echo "" >> "$CONFIG_FILE"

    echo "✓ Task role ARNs appended to: $CONFIG_FILE"
    echo ""
}

# Main execution
main() {
    parse_options "$@"
    load_config
    validate_scenario

    # Validate required environment variables
    if [ -z "$LOCAL_ACCOUNT_PROFILE" ]; then
        echo -e "${YELLOW}Error: LOCAL_ACCOUNT_PROFILE not set${NC}"
        exit 1
    fi

    if [ "$MULTI_ACCOUNT" = true ] && [ -z "$EXTERNAL_ACCOUNT_PROFILE" ]; then
        echo -e "${YELLOW}Error: EXTERNAL_ACCOUNT_PROFILE not set (required for Scenario 3)${NC}"
        exit 1
    fi

    # Check if IAM policy files exist
    if [ ! -f "iam/trust-policy.json" ]; then
        echo -e "${YELLOW}Error: iam/trust-policy.json not found${NC}"
        echo "Please ensure you have the iam/ directory with required policy files"
        exit 1
    fi

    if [ ! -f "iam/task-policy.json" ]; then
        echo -e "${YELLOW}Error: iam/task-policy.json not found${NC}"
        exit 1
    fi

    # Create IAM resources for local account
    create_iam_for_account "local" "$LOCAL_ACCOUNT_PROFILE"

    # Create IAM resources for external account (only for scenario 3)
    if [ "$MULTI_ACCOUNT" = true ]; then
        create_iam_for_account "external" "$EXTERNAL_ACCOUNT_PROFILE"
    fi

    # Save to config file
    save_to_config

    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  IAM Setup Complete!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Role ARNs have been saved to: $CONFIG_FILE"
    echo "  LOCAL_TASK_ROLE_ARN=$LOCAL_TASK_ROLE_ARN"
    if [ "$MULTI_ACCOUNT" = true ]; then
        echo "  EXTERNAL_TASK_ROLE_ARN=$EXTERNAL_TASK_ROLE_ARN"
    fi
    echo ""
    echo "To load in a new shell, run: source $CONFIG_FILE"
    echo ""
}

# Run main function
main "$@"

# Clean up environment
unset -f create_iam_for_account
unset -f save_to_config
unset -f parse_options
unset -f load_config
unset -f validate_scenario
unset -f main
unset GREEN BLUE YELLOW NC
unset ROLE_PREFIX TASK_ROLE_NAME TASK_POLICY_NAME MULTI_ACCOUNT

set +e
