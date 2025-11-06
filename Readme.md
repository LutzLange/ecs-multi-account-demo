# Istio Ambient Multi-Account ECS Integration - Complete Guide

This guide demonstrates **Istio Ambient service mesh** across multiple AWS ECS clusters in different accounts, showcasing zero-trust mTLS, unified policy management, and seamless cross-account service discovery.

## Overview

Deploy a single Istio control plane in an EKS cluster that manages ECS services across multiple AWS accounts with:

- 🔗 **Automatic Service Discovery** across clusters and accounts
- 🔐 **Zero-Trust mTLS** without sidecars (Ambient mode)
- 🛡️ **Unified Security Policies** (L4 and L7)
- 🌐 **Seamless Cross-Account Communication**
- 📊 **Rich Observability** with access logs and metrics

**Architecture simplicity:** Part 1 automates AWS infrastructure complexity, Part 2 focuses on service mesh concepts.

---

## Architecture: Service Mesh Perspective

```
┌─────────────────────────────────────────────────────────────┐
│                    ISTIO CONTROL PLANE                      │
│                      (in EKS cluster)                        │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐           │
│  │  Istiod  │  │ Ztunnel  │  │  East-West GW  │           │
│  │          │  │  (CNI)   │  │   (HBONE)      │           │
│  └──────────┘  └──────────┘  └────────────────┘           │
│       │                              │                      │
│       │ Service Discovery            │ Secure tunnel       │
│       │ Policy Enforcement           │ mTLS (HBONE)        │
│       │                              │                      │
└───────┼──────────────────────────────┼─────────────────────┘
        │                              │
        ├──────────┬───────────────────┼─────────┐
        │          │                   │         │
        ▼          ▼                   ▼         ▼
   ┌─────────┐ ┌─────────┐       ┌─────────┐ ┌─────────┐
   │ Cluster │ │ Cluster │       │ Cluster │ │ EKS Pod │
   │    1    │ │    2    │       │    3    │ │         │
   │ (local) │ │ (local) │       │(external)│ │         │
   └─────────┘ └─────────┘       └─────────┘ └─────────┘
     ecs.local   ecs.local        ecs.external
```

### Key Service Mesh Concepts

**Ambient Mode**: No sidecars! Traffic handling via:
- **Ztunnel** (node-level proxy) - handles mTLS and L4 policies
- **Waypoint Proxy** (optional) - for L7 policies

**Service Discovery**: Istiod automatically discovers ECS tasks across multiple clusters, accounts, and network domains.

**⚠️ CRITICAL REQUIREMENT**: All ECS clusters **must** have the tag `ecs.solo.io/discovery-enabled=true` for Istio to discover them. Without this tag, services will not be added to the mesh.

**HBONE Protocol**: HTTP-Based Overlay Network Encapsulation tunnels mTLS traffic through the east-west gateway, enabling secure cross-account communication.

---

## Prerequisites

### Required Tools
- ✅ AWS CLI configured with 2 profiles (local + external account)
- ✅ kubectl with access to your EKS cluster
- ✅ eksctl (if creating a new EKS cluster)
- ✅ istioctl with ECS support from Solo.io
- ✅ jq for JSON processing
- ✅ Gloo Mesh license key from Solo.io

### Required AWS Resources
- ✅ Two AWS accounts (local and external)
- ✅ EKS cluster in the local account
- ✅ Administrative access to both accounts

### Environment Setup

Set these variables before starting:

```bash
# AWS Account Information
export LOCAL_ACCOUNT=<your_local_account_id>              # e.g., 123456789012
export EXTERNAL_ACCOUNT=<your_external_account_id>        # e.g., 987654321098
export LOCAL_ACCOUNT_PROFILE=<local_profile>              # e.g., default
export EXTERNAL_ACCOUNT_PROFILE=<external_profile>        # e.g., external-profile
export INT=$LOCAL_ACCOUNT_PROFILE
export EXT=$EXTERNAL_ACCOUNT_PROFILE

# AWS Region and Cluster Configuration
export AWS_REGION=us-east-2
export CLUSTER_NAME=istio-multi-account
export OWNER_NAME=$(whoami)

# Istio Configuration
export HUB=us-east1-docker.pkg.dev/istio-enterprise-private/gme-istio-testing-images
export ISTIO_TAG=1.29-alpha.20806789ba7dd5528bab31384ca99d3d6f78b122
export GLOO_MESH_LICENSE_KEY=<your-license-key>
```

**Login to AWS:**

```bash
aws sso login --profile $LOCAL_ACCOUNT_PROFILE
aws sso login --profile $EXTERNAL_ACCOUNT_PROFILE
```

---

# Part 1: Infrastructure Setup

This section creates all required AWS infrastructure using an automated, idempotent script. The script handles VPC creation, networking, peering, security groups, and IAM roles for Istiod.

## What Gets Created

**In the External Account:**
- VPC with public and private subnets across 3 availability zones
- Internet Gateway and NAT Gateway
- Route tables for public and private traffic
- Security groups with proper ingress rules

**Cross-Account:**
- VPC peering connection between local and external accounts
- Peering routes in all route tables
- Security group rules for cross-account traffic

**IAM Roles:**
- `istiod-role` - Main role for Istiod with EKS Pod Identity
- `istiod-local` - Role for accessing local account ECS resources
- `istiod-external` - Role for accessing external account ECS resources
- Permission policies for cross-account role assumption

## Run Infrastructure Setup

Execute the automated setup script:

```bash
chmod +x setup-ecs-multi-account.sh
./setup-ecs-multi-account.sh
```

**The script is idempotent** - safe to run multiple times. It will:
- Check for existing resources before creating new ones
- Skip resources that already exist
- Update policies if they've changed
- Wait for resources (NAT Gateway, VPC Peering) to be ready

**Expected output:**
```
[INFO] === Creating VPC in External Account ===
[INFO] Created VPC: vpc-xxxxx
[INFO] === Creating Subnets ===
[INFO] Created Private Subnet 1: subnet-xxxxx
...
[INFO] === Setting Up IAM Roles ===
[INFO] Created istiod-role in local account
...
[INFO] Setup Complete!
```

## Load Environment Variables

The script saves all created resource IDs to a file:

```bash
source /tmp/ecs-multi-account-env.sh
```

This loads variables including:
- VPC and subnet IDs
- Security group IDs
- IAM role ARNs
- Network CIDRs

**Verify the setup:**

```bash
echo "Local VPC: $LOCAL_VPC"
echo "External VPC: $EXTERNAL_VPC"
echo "Peering ID: $PEERING_ID"
echo "Local Role: $LOCAL_ROLE"
echo "External Role: $EXTERNAL_ROLE"
```

---

# Part 2: Service Mesh Deployment

Now that infrastructure is ready, let's deploy Istio and demonstrate service mesh capabilities.

## Step 1: Install Istio in Ambient Mode

Install Istio with multi-account ECS discovery:

```bash
cat <<EOF | ./istioctl install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient                    # 👈 Ambient mode - no sidecars!
  meshConfig:
    accessLogFile: /dev/stdout        # 👈 See all traffic
  values:
    global:
      hub: ${HUB}
      tag: ${ISTIO_TAG}
      network: eks
    license:
      value: ${GLOO_MESH_LICENSE_KEY}
    cni:
      ambient:
        dnsCapture: true              # 👈 Capture DNS for service discovery
    platforms:
      ecs:
        accounts:
          - role: ${LOCAL_ROLE}       # 👈 Discover ECS in local account
            domain: ecs.local
          - role: ${EXTERNAL_ROLE}    # 👈 Discover ECS in external account
            domain: ecs.external
    pilot:
      env:
        PILOT_ENABLE_IP_AUTOALLOCATE: "true"    # 👈 Auto-assign IPs
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
        REQUIRE_3P_TOKEN: "false"               # 👈 Simplified auth for demo
EOF
```

**Key Service Mesh Settings Explained:**

| Setting | Purpose |
|---------|---------|
| `profile: ambient` | Uses ztunnel instead of sidecars - simpler, more efficient |
| `dnsCapture: true` | Intercepts DNS queries for seamless service discovery |
| `accounts: [...]` | Tells Istiod where to discover ECS tasks (multi-account) |
| `domain: ecs.local/external` | DNS suffix for service names |

**Expected output:**
```
✔ Istio core installed ⛵️
✔ Istiod installed 🧠
✔ CNI installed 🪢
✔ Ztunnel installed 🔒
✔ Installation complete
```

## Step 2: Deploy East-West Gateway

The east-west gateway enables secure cross-cluster communication:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/expose-istiod: "15012"     # 👈 Expose control plane
    topology.istio.io/network: eks
  name: eastwest
  namespace: istio-system
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE                      # 👈 HBONE protocol for mTLS tunneling
    tls:
      mode: Passthrough
  - name: xds-tls
    port: 15012                          # 👈 Control plane communication
    protocol: TLS
    tls:
      mode: Passthrough
EOF
```

**What This Does:**
- Creates a gateway for cross-cluster traffic
- Port 15008: HBONE (encrypted data plane traffic)
- Port 15012: xDS (control plane configuration)
- All traffic is mTLS-encrypted

## Step 3: Label Network

```bash
kubectl label namespace istio-system topology.istio.io/network=eks
```

This identifies which network the control plane is in.

**Verify Istio is running:**

```bash
kubectl get pods -n istio-system
```

Expected:
```
NAME                      READY   STATUS    RESTARTS   AGE
istiod-xxx                1/1     Running   0          2m
ztunnel-xxx               1/1     Running   0          2m
istio-cni-node-xxx        1/1     Running   0          2m
```

---

## Step 4: Deploy ECS Workloads

Now deploy ECS clusters and services using automation scripts. These scripts are idempotent and handle AWS complexity.

### Step 4.1: Create IAM Roles for ECS Tasks

Create IAM task roles for both accounts:

```bash
source ./create-iam-multi-account.sh
```

**What this creates:**
- Task execution roles in both accounts
- Policies for CloudWatch Logs, ECR access, and SSM (for debugging)
- Exports `LOCAL_TASK_ROLE_ARN` and `EXTERNAL_TASK_ROLE_ARN`

**Expected output:**
```
Creating IAM resources for LOCAL account...
  ✓ Role created: arn:aws:iam::xxx:role/eks-ecs-task-role
  ✓ Policy attached to role

Creating IAM resources for EXTERNAL account...
  ✓ Role created: arn:aws:iam::xxx:role/eks-ecs-task-role

IAM Setup Complete!
```

### Step 4.2: Deploy 3 ECS Clusters

Deploy ECS clusters with services in both accounts:

```bash
./deploy-ecs-multi-account-3-clusters.sh
```

**What this creates:**
- 3 ECS clusters:
  - `ecs-istio-multi-account-1` (local account)
  - `ecs-istio-multi-account-2` (local account)
  - `ecs-istio-multi-account-3` (external account)
- 2 services per cluster:
  - `shell-task` - curl container for testing
  - `echo-service` - HTTP echo server on port 8080

**🔴 CRITICAL: ECS Discovery Tag**

Each ECS cluster is tagged with `ecs.solo.io/discovery-enabled=true`. This tag is **mandatory** for Istio to discover the cluster. The script:
1. Adds this tag during cluster creation
2. Verifies the tag exists on all clusters (even existing ones)
3. Without this tag, Istiod will not discover your ECS services

**Expected output:**
```
LOCAL ACCOUNT DEPLOYMENT
  ✓ Cluster ecs-istio-multi-account-1 created
  ✓ Discovery tag verified: ecs.solo.io/discovery-enabled=true
  ✓ shell-task deployed
  ✓ echo-service deployed
...
EXTERNAL ACCOUNT DEPLOYMENT
  ✓ Cluster ecs-istio-multi-account-3 created
  ✓ Discovery tag verified: ecs.solo.io/discovery-enabled=true
  ✓ shell-task deployed
  ✓ echo-service deployed

Deployment Complete!
```

**Verify ECS clusters:**

```bash
# List local clusters
aws ecs list-clusters --profile $LOCAL_ACCOUNT_PROFILE

# List external clusters
aws ecs list-clusters --profile $EXTERNAL_ACCOUNT_PROFILE
```

**Verify discovery tags (CRITICAL CHECK):**

```bash
# Check local clusters have the discovery tag
for cluster in 1 2; do
  echo "Checking cluster $cluster..."
  aws ecs list-tags-for-resource \
    --resource-arn $(aws ecs describe-clusters \
      --clusters ecs-istio-multi-account-$cluster \
      --profile $LOCAL_ACCOUNT_PROFILE \
      --query 'clusters[0].clusterArn' \
      --output text) \
    --profile $LOCAL_ACCOUNT_PROFILE \
    --query 'tags[?key==`ecs.solo.io/discovery-enabled`]'
done

# Check external cluster has the discovery tag
aws ecs list-tags-for-resource \
  --resource-arn $(aws ecs describe-clusters \
    --clusters ecs-istio-multi-account-3 \
    --profile $EXTERNAL_ACCOUNT_PROFILE \
    --query 'clusters[0].clusterArn' \
    --output text) \
  --profile $EXTERNAL_ACCOUNT_PROFILE \
  --query 'tags[?key==`ecs.solo.io/discovery-enabled`]'
```

**Expected output for each cluster:**
```json
[
    {
        "key": "ecs.solo.io/discovery-enabled",
        "value": "true"
    }
]
```

**⚠️ If the tag is missing, Istiod will not discover the cluster!** Manually add it:
```bash
aws ecs tag-resource \
  --resource-arn <cluster-arn> \
  --tags key=ecs.solo.io/discovery-enabled,value=true \
  --profile <profile>
```

---

## Step 5: Add Workloads to the Service Mesh

### Step 5.1: Create Kubernetes Namespaces

Create namespaces with Ambient mode enabled:

```bash
source ./create-k8s-namespaces-3-clusters.sh
```

**What this creates:**

For each ECS cluster, creates a namespace like:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ecs-istio-multi-account-1
  labels:
    istio.io/dataplane-mode: ambient    # 👈 Enables Ambient mode!
```

**Service Mesh Concept**: The `istio.io/dataplane-mode: ambient` label tells Istio to use **ztunnel** (not sidecars). Traffic from this namespace is automatically captured and secured with mTLS.

**Verify namespaces:**

```bash
kubectl get ns | grep ecs-istio-multi-account
```

Expected:
```
ecs-istio-multi-account-1   Active   1m
ecs-istio-multi-account-2   Active   1m
ecs-istio-multi-account-3   Active   1m
```

### Step 5.2: Enroll Services in the Mesh

Add all ECS services to the mesh:

```bash
./add-services-to-mesh-3-clusters.sh
```

**What happens behind the scenes:**

For each service, `istioctl` automatically:
1. 🎫 Generates bootstrap tokens (for secure Istiod connection)
2. 🔐 Fetches Istiod root certificate
3. 📝 Creates `ServiceEntry` (tells Istio about the service)
4. 📍 Creates `WorkloadEntry` (tells Istio where tasks are running)
5. 🔄 Updates ECS task definition (adds mesh configuration)
6. 🚀 Redeploys task with mesh integration

**Expected output:**
```
Adding services for cluster 1 (local)...
  ✓ shell-task added successfully
  ✓ echo-service added successfully

Adding services for cluster 3 (external)...
  ✓ shell-task added successfully
  ✓ echo-service added successfully

All Services Added to Mesh!
```

---

## Step 6: Verify Service Discovery

Check that all services are discovered:

```bash
./istioctl ztunnel-config services
```

**Expected output:**
```
NAMESPACE                      NAME           ADDRESS      
ecs-istio-multi-account-1      shell-task     10.0.1.100   
ecs-istio-multi-account-1      echo-service   10.0.1.101   
ecs-istio-multi-account-2      shell-task     10.0.2.100   
ecs-istio-multi-account-2      echo-service   10.0.2.101   
ecs-istio-multi-account-3      shell-task     10.1.1.100   
ecs-istio-multi-account-3      echo-service   10.1.1.101   
```

**Check workloads are using HBONE** (mesh enrolled):

```bash
./istioctl ztunnel-config workloads
```

**Expected output:**
```
NAMESPACE                      NAME           PROTOCOL    
ecs-istio-multi-account-1      shell-task     HBONE    👈 Meshed!
ecs-istio-multi-account-1      echo-service   HBONE    
ecs-istio-multi-account-2      shell-task     HBONE    
ecs-istio-multi-account-2      echo-service   HBONE    
ecs-istio-multi-account-3      shell-task     HBONE    
ecs-istio-multi-account-3      echo-service   HBONE    
```

**🎉 If you see HBONE protocol, your services are enrolled in the mesh with automatic mTLS!**

---

## Step 7: Test Cross-Account Communication

Deploy a test pod in EKS to test service mesh connectivity:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: eks-shell
  namespace: default
  labels:
    app: eks-shell
spec:
  replicas: 1
  selector:
    matchLabels:
      app: eks-shell
  template:
    metadata:
      labels:
        app: eks-shell
        istio.io/dataplane-mode: ambient
    spec:
      containers:
      - name: eks-shell
        image: curlimages/curl:latest
        command: ["/bin/sh", "-c", "sleep 3600"]
EOF
```

**Test connectivity to local cluster services:**

```bash
# Test cluster 1 (local)
kubectl exec deployment/eks-shell -- \
  curl -s echo-service.ecs-istio-multi-account-1.ecs.local:8080

# Test cluster 2 (local)
kubectl exec deployment/eks-shell -- \
  curl -s echo-service.ecs-istio-multi-account-2.ecs.local:8080
```

**Test cross-account connectivity to external cluster:**

```bash
# Test cluster 3 (external account)
kubectl exec deployment/eks-shell -- \
  curl -s echo-service.ecs-istio-multi-account-3.ecs.external:8080
```

**Expected response from echo service:**
```json
{
  "host": {
    "hostname": "echo-service.ecs-istio-multi-account-3.ecs.external",
    "ip": "10.1.1.101"
  },
  "http": {
    "method": "GET",
    "baseUrl": "",
    "originalUrl": "/",
    "protocol": "http"
  }
}
```

**✅ Success criteria:**
- All requests return 200 OK
- Responses include correct hostname
- Cross-account communication works seamlessly
- All traffic is automatically encrypted with mTLS

---

## Step 8: Apply Security Policies

### L4 Authorization Policy (Network-Level)

Deny all traffic by default, then allow specific access:

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ecs-istio-multi-account-1
spec:
  {}  # Empty spec = deny all
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: ecs-istio-multi-account-1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]  # 👈 Only allow from EKS pods in default namespace
    to:
    - operation:
        ports: ["8080"]          # 👈 Only port 8080
EOF
```

**Test the L4 policy:**

```bash
# Should SUCCEED (from default namespace)
kubectl exec deployment/eks-shell -- \
  curl echo-service.ecs-istio-multi-account-1.ecs.local:8080

# From shell-task in same cluster - should FAIL
# (requires accessing ECS task console via AWS)
```

### L7 Authorization Policy (Application-Level)

For HTTP method restrictions, deploy a waypoint proxy:

```bash
./istioctl waypoint apply \
  -n ecs-istio-multi-account-1 \
  --enroll-namespace
```

**Apply L7 policy:**

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: echo-service-http-policy
  namespace: ecs-istio-multi-account-1
spec:
  targetRefs:
  - kind: Service
    name: echo-service
  action: ALLOW
  rules:
  - to:
    - operation:
        methods: ["POST"]  # 👈 Only allow POST
EOF
```

**Test L7 policy:**

```bash
# POST request - should SUCCEED
kubectl exec deployment/eks-shell -- \
  curl -X POST echo-service.ecs-istio-multi-account-1.ecs.local:8080

# GET request - should FAIL
kubectl exec deployment/eks-shell -- \
  curl -X GET echo-service.ecs-istio-multi-account-1.ecs.local:8080
# Expected: RBAC: access denied
```

**Service Mesh Concept: Two-Layer Security**
```
┌─────────────────────────────────────────┐
│         Your Workload                   │
└─────────────────────────────────────────┘
                 ↑
                 │ L7 (HTTP method, headers)
         ┌───────▼────────┐
         │   Waypoint     │ (optional, for L7)
         └───────┬────────┘
                 │ L4 (IP, port, protocol)
         ┌───────▼────────┐
         │    Ztunnel     │ (always on)
         └────────────────┘
```

---

## Step 9: Observability

### View Traffic Patterns

Check ztunnel access logs (all traffic is logged):

```bash
kubectl logs -n istio-system -l app=ztunnel --tail=50
```

**Example log entry:**
```json
{
  "authority": "echo-service.ecs-istio-multi-account-1.ecs.local:8080",
  "bytes_sent": 234,
  "bytes_received": 456,
  "connection_termination_details": "mTLS",  👈 Encrypted!
  "duration": 5,
  "method": "GET",
  "protocol": "HTTP/1.1",
  "response_code": 200,
  "upstream_cluster": "ecs-istio-multi-account-1"
}
```

### View Service Mesh Topology

```bash
# All services in the mesh
./istioctl ztunnel-config services

# All workloads and their status
./istioctl ztunnel-config workloads

# Specific workload details
./istioctl ztunnel-config workload shell-task -n ecs-istio-multi-account-1
```

### Verify mTLS Status

```bash
# Check certificates being used
./istioctl proxy-config secret -n istio-system deployment/ztunnel
```

**You should see:**
- ROOTCA: Common root certificate for all workloads
- default: Workload-specific certificates
- All using SPIFFE identities

---

## Service Mesh Patterns Demonstrated

### 1. Multi-Cluster Service Discovery

```
Service in EKS → Discovers → Service in ECS Cluster 1
                          → Service in ECS Cluster 2
                          → Service in ECS Cluster 3 (external account)
```

**No manual configuration!** Istiod automatically:
- Discovers all ECS tasks
- Creates DNS entries
- Maintains service registry

### 2. Zero-Trust mTLS

```
All traffic flow:
Workload A → Ztunnel A → [mTLS tunnel] → Ztunnel B → Workload B
```

**Automatic encryption:**
- No application changes
- No certificates to manage
- Works across accounts/networks

### 3. Policy Enforcement

```
Request → Ztunnel (L4 checks) → Waypoint (L7 checks) → Destination
```

**Flexible security:**
- L4: Fast network-level policies
- L7: Rich application-level policies
- Combine both for defense in depth

### 4. Cross-Account Communication

```
Local Account ECS ←→ External Account ECS
      (ecs.local)         (ecs.external)
```

**Seamless integration:**
- Different AWS accounts
- Different VPCs
- Different security policies
- One unified mesh

---

## Testing Scenarios

### High Availability Testing

```bash
# Scale cluster 1 to 0 (simulate failure)
aws ecs update-service \
    --cluster ecs-istio-multi-account-1 \
    --service echo-service \
    --desired-count 0 \
    --profile $LOCAL_ACCOUNT_PROFILE

# Traffic should still work via cluster 2
kubectl exec deployment/eks-shell -- \
  curl echo-service.ecs.local:8080  # Still works!
```

### Progressive Security Rollout

```bash
# 1. Start with permissive (allow all)
# 2. Add L4 policies (network segmentation)
# 3. Add L7 policies (application-level auth)
# 4. Monitor and refine
```

### Service Migration

```bash
# Move service from cluster 1 to cluster 2
# No DNS changes needed
# Clients use same service name
# Istio handles routing automatically
```

---

## Troubleshooting

### Services Not Discovered?

```bash
# Check Istiod can see the ECS clusters
kubectl logs -n istio-system deploy/istiod | grep ecs

# Should see:
# "configured ecs accounts" with both account roles
```

**🔴 CRITICAL: Verify ECS cluster discovery tags**

The most common reason for services not being discovered is missing the required tag on ECS clusters:

```bash
# Check if clusters have the discovery tag
for cluster in ecs-istio-multi-account-1 ecs-istio-multi-account-2; do
  echo "Checking $cluster..."
  cluster_arn=$(aws ecs describe-clusters \
    --clusters $cluster \
    --profile $LOCAL_ACCOUNT_PROFILE \
    --query 'clusters[0].clusterArn' \
    --output text)
  
  aws ecs list-tags-for-resource \
    --resource-arn $cluster_arn \
    --profile $LOCAL_ACCOUNT_PROFILE \
    --query 'tags[?key==`ecs.solo.io/discovery-enabled`].value' \
    --output text
done

# For external cluster
cluster_arn=$(aws ecs describe-clusters \
  --clusters ecs-istio-multi-account-3 \
  --profile $EXTERNAL_ACCOUNT_PROFILE \
  --query 'clusters[0].clusterArn' \
  --output text)

aws ecs list-tags-for-resource \
  --resource-arn $cluster_arn \
  --profile $EXTERNAL_ACCOUNT_PROFILE \
  --query 'tags[?key==`ecs.solo.io/discovery-enabled`].value' \
  --output text
```

**Expected output:** `true` for each cluster

**If missing, add the tag:**
```bash
aws ecs tag-resource \
  --resource-arn <cluster-arn> \
  --tags key=ecs.solo.io/discovery-enabled,value=true \
  --profile <profile>

# Restart istiod to re-discover clusters
kubectl rollout restart deployment/istiod -n istio-system
```

### Traffic Not Encrypted?

```bash
# Check workloads are using HBONE
./istioctl ztunnel-config workloads | grep -i hbone

# If showing TCP instead of HBONE:
# - Service not added to mesh (run add-services script)
# - Namespace not labeled for ambient
# - Task needs redeployment
```

### Policies Not Working?

```bash
# Check authorization policies
kubectl get authorizationpolicies --all-namespaces

# Check waypoint is deployed (for L7 policies)
kubectl get pods -n ecs-istio-multi-account-1 \
  -l gateway.istio.io/managed=istio.io-mesh-controller

# View policy evaluation logs
kubectl logs -n istio-system -l app=ztunnel | grep -i "authz"
```

### Cross-Account Connectivity Issues?

```bash
# Verify VPC peering
aws ec2 describe-vpc-peering-connections \
    --vpc-peering-connection-ids $PEERING_ID \
    --profile $LOCAL_ACCOUNT_PROFILE

# Check security group rules
aws ec2 describe-security-groups \
    --group-ids $EXTERNAL_SG \
    --profile $EXTERNAL_ACCOUNT_PROFILE

# Verify IAM roles
aws iam get-role --role-name istiod-role --profile $LOCAL_ACCOUNT_PROFILE
```

---

## Key Service Mesh Takeaways

### ✅ What Ambient Mode Gives You

1. **No Sidecars** - Simpler, more efficient
2. **Transparent mTLS** - Zero application changes
3. **Flexible L7** - Only deploy waypoint when needed
4. **Easier Ops** - Fewer moving parts

### ✅ Multi-Cluster Benefits

1. **Unified Service Discovery** - One namespace, multiple clusters
2. **Consistent Security** - Same policies everywhere
3. **HA & Failover** - Built-in redundancy
4. **Gradual Migration** - Move services cluster-by-cluster

### ✅ Cross-Account Advantages

1. **Organizational Boundaries** - Different teams, different accounts
2. **Cost Allocation** - Clear AWS billing separation
3. **Security Isolation** - Account-level separation + mesh security
4. **Compliance** - Meet regulatory requirements

---

## Summary: Before vs After

**Before** (without service mesh):
- ❌ Manual TLS certificate management
- ❌ Application-level authentication
- ❌ Network policies scattered across AWS
- ❌ No visibility into service communication
- ❌ Complex cross-account setup

**After** (with Istio Ambient):
- ✅ Automatic mTLS (zero-trust by default)
- ✅ Centralized policy management
- ✅ Service discovery across accounts/clusters
- ✅ Rich observability (logs, metrics, traces)
- ✅ Simple cross-account communication

**AWS infrastructure complexity is automated** - you focus on **service mesh features**!

---

## Cleanup

To remove all resources, use the automated cleanup script:

### Run Automated Cleanup

```bash
# Ensure environment is loaded
source /tmp/ecs-multi-account-env.sh

# Run cleanup script
chmod +x cleanup-ecs-multi-account.sh
./cleanup-ecs-multi-account.sh
```

The script will:
1. **Prompt for confirmation** - You must type "yes" to proceed
2. **Clean up in the correct order** to handle dependencies:
   - Istio resources (policies, waypoints, services from mesh, control plane)
   - ECS resources (services, clusters, task definitions, CloudWatch logs)
   - IAM resources (roles and policies in both accounts)
   - Infrastructure (VPC peering, external VPC, subnets, NAT gateway, IGW)

**The cleanup script is idempotent** - safe to run multiple times. It checks for resource existence before attempting deletion.

**Expected output:**
```
[====] === ECS Multi-Account Cleanup Script ===

This script will delete ALL resources created by the setup:
  - Istio installation and mesh resources
  - All ECS clusters and services (in both accounts)
  - IAM roles and policies
  - External VPC and all networking resources
  - VPC peering connection

Are you sure you want to continue? (yes/no): yes

[====] === Cleaning Up Istio Resources ===
[INFO] Removing authorization policies...
[INFO] Removing waypoint proxies...
[INFO] Removing ECS services from mesh...
[INFO] Uninstalling Istio...

[====] === Cleaning Up ECS Resources in LOCAL Account ===
[INFO] Processing cluster: ecs-istio-multi-account-1
[INFO]   Deleting services in ecs-istio-multi-account-1...
[INFO]     Deleting service: shell-task
[INFO]     Deleting service: echo-service
[INFO]   Deleting cluster: ecs-istio-multi-account-1

[====] === Cleaning Up IAM Resources in LOCAL Account ===
[INFO] Processing role: istiod-role
[INFO]   Detaching policies from istiod-role...

[====] === Cleaning Up Infrastructure ===
[INFO] Deleting VPC peering connection: pcx-xxxxx
[INFO] Cleaning up external VPC: vpc-xxxxx
[INFO]   Deleting NAT Gateway: nat-xxxxx
[INFO]   Waiting for NAT Gateway to delete (this may take 5-10 minutes)...
[INFO]   NAT Gateway deleted
[INFO]   Releasing Elastic IP: eipalloc-xxxxx

[====] === Cleanup Summary ===
[INFO] Successfully deleted 45 resources:
  ✓ AuthorizationPolicy: ecs-istio-multi-account-1/deny-all
  ✓ Mesh service: shell-task in ecs-istio-multi-account-1
  ✓ ECS cluster: ecs-istio-multi-account-1
  ✓ IAM role: istiod-role
  ✓ VPC Peering: pcx-xxxxx
  ✓ VPC: vpc-xxxxx
  ...

[INFO] Cleanup complete!
```

### What Gets Deleted

**Istio Resources:**
- Authorization policies in all namespaces
- Waypoint proxies
- Services removed from mesh (ServiceEntry, WorkloadEntry)
- Kubernetes namespaces (ecs-istio-multi-account-{1,2,3})
- EKS test deployments (eks-shell, eks-echo)
- Istio control plane (istiod, ztunnel, CNI)

**ECS Resources (Both Accounts):**
- All ECS services in all 3 clusters
- All 3 ECS clusters
- Task definitions (shell-task, echo-service)
- CloudWatch log group (/ecs/ecs-demo)

**IAM Resources:**
- Local account: istiod-role, istiod-local, eks-ecs-task-role
- External account: istiod-external, eks-ecs-task-role
- Custom policies: istiod-permission-policy, eks-ecs-task-policy

**Infrastructure:**
- VPC peering connection
- NAT Gateway (waits for deletion to complete)
- Elastic IP
- Internet Gateway
- All subnets (3 private + 1 public)
- Route tables
- Security groups
- External VPC

### Manual Cleanup (If Script Fails)

If the automated script fails, you can manually clean up using AWS Console or CLI. The script output will show which resources were successfully deleted and which failed.

**To retry failed deletions:**
```bash
# The script is idempotent - just run it again
./cleanup-ecs-multi-account.sh
```

### After Cleanup

Remove the environment configuration file:
```bash
rm /tmp/ecs-multi-account-env.sh
```

**Verify everything is deleted:**
```bash
# Check ECS clusters
aws ecs list-clusters --profile $LOCAL_ACCOUNT_PROFILE
aws ecs list-clusters --profile $EXTERNAL_ACCOUNT_PROFILE

# Check VPCs
aws ec2 describe-vpcs --profile $EXTERNAL_ACCOUNT_PROFILE

# Check IAM roles
aws iam list-roles --profile $LOCAL_ACCOUNT_PROFILE | grep -E "istiod|ecs-task"
```

---

## Appendix: Quick Command Reference

```bash
# View service mesh topology
./istioctl ztunnel-config services
./istioctl ztunnel-config workloads

# Check if traffic is meshed
./istioctl ztunnel-config workloads | grep HBONE

# View mTLS certificates
./istioctl proxy-config secret -n istio-system deployment/ztunnel

# Apply security policy
kubectl apply -f policy.yaml

# Deploy waypoint for L7
./istioctl waypoint apply -n <namespace> --enroll-namespace

# View access logs
kubectl logs -n istio-system -l app=ztunnel --tail=100

# Test connectivity
kubectl exec deployment/eks-shell -- curl <service-dns>:8080

# Reload environment
source /tmp/ecs-multi-account-env.sh
```

---

## Next Steps

**Explore advanced features:**
- Traffic splitting and canary deployments
- Fault injection for resilience testing
- Distributed tracing with Jaeger/Zipkin
- Metrics and dashboards with Prometheus/Grafana
- Multi-cluster mesh expansion to more accounts

**Additional resources:**
- [Istio Documentation](https://istio.io/latest/docs/)
- [Solo.io Gloo Mesh](https://docs.solo.io/gloo-mesh/)
- [AWS ECS Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/)

---

*This guide demonstrates Istio Ambient's capabilities for multi-account, multi-cluster ECS deployments with zero-trust security and unified management.*
