#!/bin/bash

# validate-setup.sh
# Validates that all required files and environment variables are present

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=============================================${NC}"
echo -e "${BLUE}  Multi-Account ECS Setup Validation${NC}"
echo -e "${BLUE}=============================================${NC}"
echo ""

all_good=true

# Check required files
echo -e "${BLUE}Checking Required Files...${NC}"
echo ""

required_files=(
    "env-config.sh"
    "create-iam-multi-account.sh"
    "deploy-ecs-multi-account-3-clusters.sh"
    "create-k8s-namespaces-3-clusters.sh"
    "add-services-to-mesh-3-clusters.sh"
    "iam/trust-policy.json"
    "iam/task-policy.json"
    "ecs_definitions/shell-task-definition.json"
    "ecs_definitions/echo-task-definition.json"
    "eks-shell.yaml"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $file"
    else
        echo -e "  ${RED}✗${NC} $file - MISSING"
        all_good=false
    fi
done

echo ""

# Check istioctl
echo -e "${BLUE}Checking istioctl...${NC}"
if [ -f "./istioctl" ]; then
    version=$(./istioctl version --remote=false 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} istioctl found: $version"
else
    echo -e "  ${RED}✗${NC} istioctl not found in current directory"
    all_good=false
fi

echo ""

# Check environment variables
echo -e "${BLUE}Checking Environment Variables...${NC}"
echo ""

required_vars=(
    "LOCAL_ACCOUNT"
    "EXTERNAL_ACCOUNT"
    "LOCAL_ACCOUNT_PROFILE"
    "EXTERNAL_ACCOUNT_PROFILE"
    "AWS_REGION"
    "CLUSTER_NAME"
    "EXTERNAL_SUBNETS"
    "EXTERNAL_SG"
)

for var in "${required_vars[@]}"; do
    if [ -n "${!var}" ]; then
        echo -e "  ${GREEN}✓${NC} $var = ${!var}"
    else
        echo -e "  ${RED}✗${NC} $var - NOT SET"
        all_good=false
    fi
done

echo ""

# Check optional variables (will be set by scripts)
echo -e "${BLUE}Optional Variables (OK if not set yet)...${NC}"
echo ""

optional_vars=(
    "LOCAL_TASK_ROLE_ARN"
    "EXTERNAL_TASK_ROLE_ARN"
    "LOCAL_ECS_SERVICE_ACCOUNT_NAME"
    "EXTERNAL_ECS_SERVICE_ACCOUNT_NAME"
    "GLOO_MESH_LICENSE_KEY"
)

for var in "${optional_vars[@]}"; do
    if [ -n "${!var}" ] && [ "${!var}" != "<your-license-key>" ]; then
        echo -e "  ${GREEN}✓${NC} $var is set"
    else
        echo -e "  ${YELLOW}○${NC} $var - will be set by scripts"
    fi
done

echo ""

# Check AWS CLI access
echo -e "${BLUE}Checking AWS CLI Access...${NC}"
echo ""

# Test local account
if aws sts get-caller-identity --profile $LOCAL_ACCOUNT_PROFILE &>/dev/null; then
    local_identity=$(aws sts get-caller-identity --profile $LOCAL_ACCOUNT_PROFILE --query 'Account' --output text 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} Local account access ($LOCAL_ACCOUNT_PROFILE): $local_identity"
else
    echo -e "  ${RED}✗${NC} Cannot access local account ($LOCAL_ACCOUNT_PROFILE)"
    echo -e "     Run: aws sso login --profile $LOCAL_ACCOUNT_PROFILE"
    all_good=false
fi

# Test external account
if aws sts get-caller-identity --profile $EXTERNAL_ACCOUNT_PROFILE &>/dev/null; then
    external_identity=$(aws sts get-caller-identity --profile $EXTERNAL_ACCOUNT_PROFILE --query 'Account' --output text 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} External account access ($EXTERNAL_ACCOUNT_PROFILE): $external_identity"
else
    echo -e "  ${RED}✗${NC} Cannot access external account ($EXTERNAL_ACCOUNT_PROFILE)"
    echo -e "     Run: aws sso login --profile $EXTERNAL_ACCOUNT_PROFILE"
    all_good=false
fi

echo ""

# Check kubectl access
echo -e "${BLUE}Checking Kubernetes Access...${NC}"
if kubectl cluster-info &>/dev/null; then
    cluster_name=$(kubectl config current-context 2>/dev/null)
    echo -e "  ${GREEN}✓${NC} kubectl connected to: $cluster_name"
    
    # Check if Istio is installed
    if kubectl get ns istio-system &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} istio-system namespace exists"
        
        # Check if istiod is running
        if kubectl get deployment istiod -n istio-system &>/dev/null; then
            istiod_ready=$(kubectl get deployment istiod -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
            if [ "$istiod_ready" -gt 0 ]; then
                echo -e "  ${GREEN}✓${NC} istiod is running ($istiod_ready replica(s))"
            else
                echo -e "  ${YELLOW}⚠${NC} istiod exists but not ready"
            fi
        else
            echo -e "  ${RED}✗${NC} istiod not found - please install Istio first"
            all_good=false
        fi
    else
        echo -e "  ${RED}✗${NC} istio-system namespace not found - please install Istio first"
        all_good=false
    fi
else
    echo -e "  ${RED}✗${NC} Cannot connect to Kubernetes cluster"
    echo -e "     Run: aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION --profile $LOCAL_ACCOUNT_PROFILE"
    all_good=false
fi

echo ""

# Final summary
echo -e "${BLUE}=============================================${NC}"
if [ "$all_good" = true ]; then
    echo -e "${GREEN}✓ All checks passed! Ready to proceed.${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. source ./env-config.sh"
    echo "  2. export GLOO_MESH_LICENSE_KEY=<your-key>"
    echo "  3. source ./create-iam-multi-account.sh"
    echo "  4. ./deploy-ecs-multi-account-3-clusters.sh"
    echo ""
else
    echo -e "${RED}✗ Some checks failed. Please fix the issues above.${NC}"
    echo ""
fi
echo -e "${BLUE}=============================================${NC}"
