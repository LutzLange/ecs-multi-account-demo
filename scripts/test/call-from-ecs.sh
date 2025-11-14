#!/bin/bash

# ================================================
# call-from-ecs.sh - Execute commands from ECS task
# ================================================

set -e

# Usage function
usage() {
    cat << EOF
Usage: call-from-ecs.sh [OPTIONS] <target_url>

Execute a curl command from an ECS shell-task container to a target URL.

Options:
  -o, --origin          Origin cluster name (where to run FROM)
                        Default: ecs-\${CLUSTER_NAME}-1
  -r, --region          AWS region
                        Default: \$AWS_REGION
  -p, --profile         AWS profile
                        Default: \$AWS_PROFILE or \$INT
  -d, --data            Data to send (automatically uses POST)
  -h, --help            Show this help message

Arguments:
  <target_url>          Target URL to curl (e.g., echo-service.ecs-cluster-1.ecs.local:8080)

Environment Variables (used as defaults):
  CLUSTER_NAME          Base cluster name
  AWS_REGION            AWS region
  AWS_PROFILE           AWS profile (primary)
  INT                   AWS profile (fallback)
  ECS_SERVICE_NAME      Service name (default: shell-task)
  ECS_CONTAINER_NAME    Container name (default: shell)

Examples:
  # GET request
  call-from-ecs.sh echo-service.ecs-two-accounts-1.ecs.local:8080

  # POST request with data
  call-from-ecs.sh -d '{"key":"value"}' echo-service.ecs-two-accounts-1.ecs.local:8080

  # With explicit origin cluster
  call-from-ecs.sh -o ecs-two-accounts-1 echo-service.ecs-two-accounts-1.ecs.local:8080

  # With explicit profile and region
  call-from-ecs.sh -p internal -r eu-central-1 -o ecs-two-accounts-1 echo-service.ecs-two-accounts-2.ecs.local:8080

EOF
    exit 0
}

# Parse arguments
TARGET_URL=""
ORIGIN_CLUSTER=""
REGION=""
PROFILE=""
DATA=""

# Check for help first (before any parsing)
if [ $# -eq 0 ]; then
    usage
fi

# Parse options using GNU getopt
TEMP=$(getopt -o 'o:r:p:d:h' --long 'origin:,region:,profile:,data:,help' -n 'call-from-ecs.sh' -- "$@")

if [ $? != 0 ]; then
    echo "Error: Failed to parse options" >&2
    exit 1
fi

# Note the quotes around "$TEMP": they are essential!
eval set -- "$TEMP"
unset TEMP

# Extract options and their arguments
while true; do
    case "$1" in
        '-o'|'--origin')
            ORIGIN_CLUSTER="$2"
            shift 2
            ;;
        '-r'|'--region')
            REGION="$2"
            shift 2
            ;;
        '-p'|'--profile')
            PROFILE="$2"
            shift 2
            ;;
        '-d'|'--data')
            DATA="$2"
            shift 2
            ;;
        '-h'|'--help')
            usage
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo "Internal error: Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# After processing options, the target URL should be the remaining argument
if [ $# -eq 0 ]; then
    echo "Error: Target URL not provided"
    usage
fi

TARGET_URL="$1"
shift

# Check for extra unexpected arguments
if [ $# -gt 0 ]; then
    echo "Error: Unexpected argument(s): $@"
    exit 1
fi

# Apply defaults from environment
if [ -z "$ORIGIN_CLUSTER" ]; then
    if [ -z "$CLUSTER_NAME" ]; then
        echo "Error: --origin not provided and \$CLUSTER_NAME not set"
        exit 1
    fi
    ORIGIN_CLUSTER="ecs-${CLUSTER_NAME}-1"
    echo "Using origin cluster from environment: $ORIGIN_CLUSTER"
fi

if [ -z "$REGION" ]; then
    if [ -z "$AWS_REGION" ]; then
        echo "Error: --region not provided and \$AWS_REGION not set"
        exit 1
    fi
    REGION="$AWS_REGION"
    echo "Using region from environment: $REGION"
fi

if [ -z "$PROFILE" ]; then
    if [ -n "$AWS_PROFILE" ]; then
        PROFILE="$AWS_PROFILE"
    elif [ -n "$INT" ]; then
        PROFILE="$INT"
    else
        echo "Error: --profile not provided and neither \$AWS_PROFILE nor \$INT are set"
        exit 1
    fi
    echo "Using profile from environment: $PROFILE"
fi

# Service and container names (can be overridden by environment variables)
SERVICE_NAME="${ECS_SERVICE_NAME:-shell-task}"
CONTAINER_NAME="${ECS_CONTAINER_NAME:-shell}"

# Retrieve the Task ID
echo "Retrieving task ID from cluster: $ORIGIN_CLUSTER"
TASK_ID=$(aws ecs list-tasks \
  --cluster "$ORIGIN_CLUSTER" \
  --service-name "$SERVICE_NAME" \
  --profile "$PROFILE" \
  --region "$REGION" \
  --query 'taskArns[0]' \
  --output text | cut -d'/' -f3)

if [ -z "$TASK_ID" ] || [ "$TASK_ID" = "None" ]; then
  echo "Error: Failed to retrieve task ID from cluster $ORIGIN_CLUSTER"
  exit 1
fi

echo "Using Task ID: $TASK_ID"
echo ""

# Validate target URL
if [ -z "$TARGET_URL" ]; then
    echo "Error: Target URL is empty"
    exit 1
fi

echo "Target URL: $TARGET_URL"
echo ""

# Build curl command based on whether data is provided
if [ -n "$DATA" ]; then
    # Escape single quotes in data for shell execution
    ESCAPED_DATA=$(echo "$DATA" | sed "s/'/'\\\\''/g")
    final_cmd="sh -c 'curl -X POST -H \"Content-Type: text/plain\" -d '\''$ESCAPED_DATA'\'' $TARGET_URL'"
    echo "====================================="
    echo "Running: curl -X POST -H \"Content-Type: text/plain\" -d '$DATA' $TARGET_URL"
    echo "====================================="
else
    final_cmd="sh -c 'curl $TARGET_URL'"
    echo "====================================="
    echo "Running: curl $TARGET_URL"
    echo "====================================="
fi

# Execute the command on the ECS task
output=$(aws ecs execute-command \
    --cluster "$ORIGIN_CLUSTER" \
    --task "$TASK_ID" \
    --container "$CONTAINER_NAME" \
    --profile "$PROFILE" \
    --region "$REGION" \
    --interactive \
    --command "$final_cmd" 2>&1 | \
    grep -v "Starting session with" | \
    grep -v "Exiting session with" | \
    grep -v "The Session Manager plugin was installed successfully" | \
    grep -v '^$')

if [ -n "$DATA" ]; then
    # For POST requests, show simplified output
    echo "$output" | jq '{hostname: .host.hostname, method: .http.method, body: .request.body}' 2>/dev/null || echo "$output"
else
    # For GET requests, show full JSON or raw output
    echo "$output" | jq '.' 2>/dev/null || echo "$output"
fi
echo ""

echo "Command completed"
