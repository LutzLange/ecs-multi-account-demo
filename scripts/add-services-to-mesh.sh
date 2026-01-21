#!/bin/bash

# add-services-to-mesh.sh
# Unified script to add ECS services to Istio mesh based on SCENARIO variable
# Supports:
#   SCENARIO=1: 1 cluster (local account)
#   SCENARIO=2: 2 clusters (local account)
#   SCENARIO=3: 3 clusters (2 local + 1 external account)

set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Default configuration file
CONFIG_FILE="env-config.sh"

# Path to istioctl - use Solo.io distribution from ~/.istioctl/bin
ISTIOCTL="${ISTIOCTL:-$HOME/.istioctl/bin/istioctl}"

# Parse command line options
parse_options() {
    local TEMP
    TEMP=$(getopt -o c: --long config: -n 'add-services-to-mesh.sh' -- "$@")

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
        echo "Please ensure $CONFIG_FILE exists or run previous setup scripts first"
        exit 1
    fi

    echo -e "${BLUE}Loading configuration from: $CONFIG_FILE${NC}"
    source "$CONFIG_FILE"
    echo ""
}

# Validate scenario and set cluster configuration
validate_scenario() {
    if [ -z "$SCENARIO" ]; then
        echo -e "${YELLOW}Error: SCENARIO variable not set in $CONFIG_FILE${NC}"
        echo "Please set SCENARIO=1, 2, or 3"
        exit 1
    fi

    case "$SCENARIO" in
        1)
            LOCAL_CLUSTERS="1"
            EXTERNAL_CLUSTERS=""
            echo -e "${GREEN}Scenario 1: Adding services from 1 cluster (local account)${NC}"
            ;;
        2)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS=""
            echo -e "${GREEN}Scenario 2: Adding services from 2 clusters (local account)${NC}"
            ;;
        3)
            LOCAL_CLUSTERS="1 2"
            EXTERNAL_CLUSTERS="3"
            echo -e "${GREEN}Scenario 3: Adding services from 3 clusters (2 local + 1 external)${NC}"
            ;;
        *)
            echo -e "${YELLOW}Error: Invalid SCENARIO value: $SCENARIO${NC}"
            echo "Valid values: 1, 2, or 3"
            exit 1
            ;;
    esac
    echo ""
}

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Add ECS Services to Istio Mesh${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

# Validate required environment variables
validate_env() {
    local required_vars=("CLUSTER_NAME" "LOCAL_ACCOUNT_PROFILE" "LOCAL_ECS_SERVICE_ACCOUNT_NAME")

    # Only require external variables for scenario 3
    if [ "$SCENARIO" = "3" ]; then
        required_vars+=("EXTERNAL_ACCOUNT_PROFILE" "EXTERNAL_ECS_SERVICE_ACCOUNT_NAME")
    fi

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            echo -e "${YELLOW}Error: $var is not defined.${NC}"
            echo ""
            echo "Please ensure $CONFIG_FILE contains this variable"
            echo "or run the previous setup scripts first"
            exit 1
        fi
    done

    echo "Configuration:"
    echo "  Scenario: ${SCENARIO}"
    echo "  Cluster Name: ${CLUSTER_NAME}"
    echo "  Local Profile: ${LOCAL_ACCOUNT_PROFILE}"
    if [ "$SCENARIO" = "3" ]; then
        echo "  External Profile: ${EXTERNAL_ACCOUNT_PROFILE}"
    fi
    echo ""
}

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
    "$ISTIOCTL" ecs add-service shell-task \
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
    "$ISTIOCTL" ecs add-service echo-service \
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
    parse_options "$@"
    load_config
    validate_scenario
    validate_env

    # Check if istioctl exists
    if [ ! -f "$ISTIOCTL" ]; then
        echo -e "${YELLOW}Error: istioctl not found at: $ISTIOCTL${NC}"
        echo ""
        echo "This script requires the Solo.io distribution of istioctl with ECS support."
        echo "The Solo.io istioctl is available through Solo.io evaluations or licenses."
        echo "Contact Solo.io for access: https://www.solo.io/company/contact/"
        echo ""
        echo "Once obtained, place istioctl at: ~/.istioctl/bin/istioctl"
        echo "Or set ISTIOCTL environment variable to point to your istioctl binary."
        exit 1
    fi

    # Check that istioctl is the Solo.io version (has ECS support)
    # Extract version from "client version: X.Y.Z-solo" format
    local client_version
    client_version=$("$ISTIOCTL" version --short 2>/dev/null | head -1 | awk '{print $NF}')
    if [[ ! "$client_version" =~ -solo ]]; then
        echo -e "${YELLOW}Error: istioctl is not the Solo.io distribution${NC}"
        echo "  Found version: $client_version"
        echo ""
        echo "ECS support requires Solo.io istioctl (version should contain '-solo')."
        echo "The upstream Istio istioctl does not include ECS commands."
        echo "Contact Solo.io for access to the Solo.io distribution."
        exit 1
    fi

    # Add services for local clusters
    if [ -n "$LOCAL_CLUSTERS" ]; then
        echo -e "${BLUE}Adding services for LOCAL clusters...${NC}"
        echo ""

        for cluster_num in $LOCAL_CLUSTERS; do
            add_services_for_cluster "$cluster_num" "$LOCAL_ACCOUNT_PROFILE" "$LOCAL_ECS_SERVICE_ACCOUNT_NAME" "local"
        done
    fi

    # Add services for external cluster (only for scenario 3)
    if [ -n "$EXTERNAL_CLUSTERS" ]; then
        echo -e "${BLUE}Adding services for EXTERNAL cluster...${NC}"
        echo ""

        for cluster_num in $EXTERNAL_CLUSTERS; do
            add_services_for_cluster "$cluster_num" "$EXTERNAL_ACCOUNT_PROFILE" "$EXTERNAL_ECS_SERVICE_ACCOUNT_NAME" "external"
        done
    fi

    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}  All Services Added to Mesh!${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo ""
    echo "Services added:"
    echo "  LOCAL ACCOUNT:"
    for cluster_num in $LOCAL_CLUSTERS; do
        echo "    ecs-${CLUSTER_NAME}-${cluster_num}: shell-task, echo-service"
    done
    if [ -n "$EXTERNAL_CLUSTERS" ]; then
        echo "  EXTERNAL ACCOUNT:"
        for cluster_num in $EXTERNAL_CLUSTERS; do
            echo "    ecs-${CLUSTER_NAME}-${cluster_num}: shell-task, echo-service"
        done
    fi
    echo ""
    echo "Verify with:"
    echo "  $ISTIOCTL ztunnel-config services | grep ecs-${CLUSTER_NAME}"
    echo "  $ISTIOCTL ztunnel-config workloads | grep ecs-${CLUSTER_NAME}"
    echo ""
    echo "Expected service DNS names:"
    for cluster_num in $LOCAL_CLUSTERS; do
        echo "  Local Cluster ${cluster_num}:"
        echo "    - shell-task.ecs-${CLUSTER_NAME}-${cluster_num}.ecs.local:80"
        echo "    - echo-service.ecs-${CLUSTER_NAME}-${cluster_num}.ecs.local:8080"
    done
    for cluster_num in $EXTERNAL_CLUSTERS; do
        echo "  External Cluster ${cluster_num}:"
        echo "    - shell-task.ecs-${CLUSTER_NAME}-${cluster_num}.ecs.external:80"
        echo "    - echo-service.ecs-${CLUSTER_NAME}-${cluster_num}.ecs.external:8080"
    done
    echo ""
}

# Run main function
main "$@"

# ============================================
# CLEANUP - Prevents shell pollution
# ============================================

unset -f parse_options
unset -f load_config
unset -f validate_scenario
unset -f validate_env
unset -f add_services_for_cluster
unset -f main

unset GREEN BLUE YELLOW NC
unset LOCAL_CLUSTERS EXTERNAL_CLUSTERS

set +e
