# Scenario 4: Multicloud - EKS + AKS (AWS + Azure)

This guide walks you through deploying **Istio Ambient service mesh** across two cloud providers: AWS (EKS with ECS workloads) and Azure (AKS with Kubernetes workloads). This demonstrates true multicloud service mesh with unified observability and security policies.

> **Note:** Istio ambient multicluster is currently in **alpha status** (as of Istio 1.27/1.28). This scenario is for testing and evaluation purposes.

## What You'll Deploy

```
                    ┌─────────────────────────────────────────────────────────┐
                    │                      UNIFIED MESH                        │
                    │                      (meshID: mesh1)                     │
                    └─────────────────────────────────────────────────────────┘
                                              │
              ┌───────────────────────────────┴───────────────────────────────┐
              │                                                               │
              ▼                                                               ▼
┌─────────────────────────────────────┐             ┌─────────────────────────────────────┐
│           AWS (network1)            │             │          AZURE (network2)           │
│                                     │             │                                     │
│  ┌───────────────────────────────┐  │             │  ┌───────────────────────────────┐  │
│  │        EKS CLUSTER            │  │             │  │        AKS CLUSTER            │  │
│  │  ┌─────────┐  ┌────────────┐  │  │             │  │  ┌─────────┐  ┌────────────┐  │  │
│  │  │ Istiod  │  │  Ztunnel   │  │  │             │  │  │ Istiod  │  │  Ztunnel   │  │  │
│  │  └─────────┘  └────────────┘  │  │   HBONE    │  │  └─────────┘  └────────────┘  │  │
│  │  ┌────────────────────────┐   │  │◄──────────►│  │  ┌────────────────────────┐   │  │
│  │  │  East-West Gateway     │   │  │   mTLS    │  │  │  East-West Gateway     │   │  │
│  │  └────────────────────────┘   │  │             │  │  └────────────────────────┘   │  │
│  └───────────────────────────────┘  │             │  └───────────────────────────────┘  │
│              │                      │             │              │                      │
│      ┌───────┴───────┐              │             │      ┌───────┴───────┐              │
│      ▼               ▼              │             │      ▼               ▼              │
│ ┌─────────┐    ┌─────────┐          │             │ ┌─────────┐    ┌─────────┐          │
│ │ECS C1   │    │ECS C2   │          │             │ │ K8s NS  │    │ K8s NS  │          │
│ │ecs.local│    │ecs.local│          │             │ │  app-a  │    │  app-b  │          │
│ └─────────┘    └─────────┘          │             │ └─────────┘    └─────────┘          │
└─────────────────────────────────────┘             └─────────────────────────────────────┘
```

**Architecture:**
- **AWS Side (Primary):** EKS cluster running Istiod + two ECS clusters with services
- **Azure Side (Primary):** AKS cluster running Istiod + Kubernetes workloads
- **Multi-Primary:** Both clusters run their own Istio control plane, sharing mesh identity
- **Cross-Cloud Communication:** Via east-west gateways using nested HBONE tunnels

**Services:**
- AWS ECS: `echo-service.ecs-{CLUSTER_NAME}-{1,2}.ecs.local:8080`
- Azure AKS: `echo-service.app-a.svc.cluster.local:8080`

---

## Prerequisites

### AWS Requirements
- AWS CLI configured with SSO profile
- eksctl installed
- istioctl with ECS support from Solo.io
- Gloo Mesh license key

### Azure Requirements
- Azure CLI (`az`) installed
- Azure subscription with permissions to create AKS clusters
- Logged in via `az login`

### General
- kubectl installed
- jq installed
- Helm 3.x installed

---

## Step 0: Environment Setup

### 0.1 Create Configuration File

```bash
cat << 'EOF' > env-config.sh
# Scenario Selection
export SCENARIO=4

# ============================================
# AWS Configuration
# ============================================
export LOCAL_ACCOUNT=<your_aws_account_id>       # e.g., 123456789012
export LOCAL_ACCOUNT_PROFILE=<your_profile>       # e.g., default
export INT=$LOCAL_ACCOUNT_PROFILE
export AWS_REGION=us-east-2

# Cluster naming
export CLUSTER_NAME=istio-multicloud
export OWNER_NAME=$(whoami)

# EKS Configuration
export NUMBER_NODES=2
export NODE_TYPE=t2.medium

# Istio Configuration (Solo.io distribution)
export HUB=us-east1-docker.pkg.dev/istio-enterprise-private/gme-istio-testing-images
export ISTIO_TAG=1.29-alpha.20806789ba7dd5528bab31384ca99d3d6f78b122
export GLOO_MESH_LICENSE_KEY=<your-license-key>

# ============================================
# Azure Configuration
# ============================================
export AZURE_SUBSCRIPTION=<your_subscription_id>  # e.g., xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
export AZURE_REGION=eastus
export AZURE_RESOURCE_GROUP=istio-multicloud-rg
export AKS_CLUSTER_NAME=istio-aks

# AKS Configuration
export AKS_NODE_COUNT=2
export AKS_NODE_VM_SIZE=Standard_DS2_v2

# ============================================
# Mesh Configuration
# ============================================
export MESH_ID=mesh1
export EKS_NETWORK=network1
export AKS_NETWORK=network2
EOF
```

### 0.2 Login to Cloud Providers

```bash
source env-config.sh

# AWS Login
aws sso login --profile $LOCAL_ACCOUNT_PROFILE

# Azure Login
az login
az account set --subscription $AZURE_SUBSCRIPTION
```

---

## Part 1: Infrastructure Setup

### Step 1.1: Create the EKS Cluster (AWS)

```bash
export AWS_PROFILE=$INT
eval "echo \"$(cat manifests/eks-cluster.yaml)\"" | eksctl create cluster --config-file -
```

Save the EKS context name:
```bash
export CTX_EKS=$(kubectl config current-context)
echo "export CTX_EKS=$CTX_EKS" >> env-config.sh
```

### Step 1.2: Create the AKS Cluster (Azure)

Create the resource group:
```bash
az group create \
  --name $AZURE_RESOURCE_GROUP \
  --location $AZURE_REGION
```

Create the AKS cluster:
```bash
az aks create \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --node-count $AKS_NODE_COUNT \
  --node-vm-size $AKS_NODE_VM_SIZE \
  --network-plugin azure \
  --enable-managed-identity \
  --generate-ssh-keys
```

Get AKS credentials and save context:
```bash
az aks get-credentials \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME

export CTX_AKS=$(kubectl config current-context)
echo "export CTX_AKS=$CTX_AKS" >> env-config.sh
```

### Step 1.3: Deploy Gateway API CRDs (Both Clusters)

```bash
# EKS
kubectl --context="${CTX_EKS}" apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml

# AKS
kubectl --context="${CTX_AKS}" apply -f \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### Step 1.4: Setup AWS Infrastructure and IAM Roles

```bash
./scripts/setup-infrastructure.sh
./scripts/create-iam-roles.sh
```

---

## Part 2: Establish Cross-Cluster Trust

For multicluster mesh, both clusters must share the same root CA.

### Step 2.1: Create Shared Root CA

```bash
# Create certs directory
mkdir -p certs
cd certs

# Generate root CA
openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:4096 \
  -subj "/O=Istio/CN=Root CA" \
  -keyout root-key.pem -out root-cert.pem

# Generate intermediate CA for EKS
openssl req -newkey rsa:4096 -sha256 -nodes \
  -subj "/O=Istio/CN=Intermediate CA EKS" \
  -keyout eks-ca-key.pem -out eks-ca-csr.pem

openssl x509 -req -sha256 -days 1825 -CA root-cert.pem -CAkey root-key.pem \
  -set_serial 1 -in eks-ca-csr.pem -out eks-ca-cert.pem

cat eks-ca-cert.pem root-cert.pem > eks-cert-chain.pem

# Generate intermediate CA for AKS
openssl req -newkey rsa:4096 -sha256 -nodes \
  -subj "/O=Istio/CN=Intermediate CA AKS" \
  -keyout aks-ca-key.pem -out aks-ca-csr.pem

openssl x509 -req -sha256 -days 1825 -CA root-cert.pem -CAkey root-key.pem \
  -set_serial 2 -in aks-ca-csr.pem -out aks-ca-cert.pem

cat aks-ca-cert.pem root-cert.pem > aks-cert-chain.pem

cd ..
```

### Step 2.2: Create Istio Namespace and CA Secrets

```bash
# EKS
kubectl --context="${CTX_EKS}" create namespace istio-system
kubectl --context="${CTX_EKS}" create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem=certs/eks-ca-cert.pem \
  --from-file=ca-key.pem=certs/eks-ca-key.pem \
  --from-file=root-cert.pem=certs/root-cert.pem \
  --from-file=cert-chain.pem=certs/eks-cert-chain.pem

# AKS
kubectl --context="${CTX_AKS}" create namespace istio-system
kubectl --context="${CTX_AKS}" create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem=certs/aks-ca-cert.pem \
  --from-file=ca-key.pem=certs/aks-ca-key.pem \
  --from-file=root-cert.pem=certs/root-cert.pem \
  --from-file=cert-chain.pem=certs/aks-cert-chain.pem
```

### Step 2.3: Label Networks

```bash
# EKS is on network1
kubectl --context="${CTX_EKS}" label namespace istio-system \
  topology.istio.io/network=$EKS_NETWORK

# AKS is on network2
kubectl --context="${CTX_AKS}" label namespace istio-system \
  topology.istio.io/network=$AKS_NETWORK
```

---

## Part 3: Install Istio on EKS (AWS)

### Step 3.1: Install Istio with ECS Support

```bash
source env-config.sh

cat <<EOF | ./istioctl install --context="${CTX_EKS}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      hub: ${HUB}
      tag: ${ISTIO_TAG}
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: eks-cluster
      network: ${EKS_NETWORK}
    license:
      value: ${GLOO_MESH_LICENSE_KEY}
    cni:
      ambient:
        dnsCapture: true
    platforms:
      ecs:
        accounts:
          - role: arn:aws:iam::${LOCAL_ACCOUNT}:role/istiod-local
            domain: ecs.local
    pilot:
      env:
        PILOT_ENABLE_IP_AUTOALLOCATE: "true"
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
        REQUIRE_3P_TOKEN: "false"
EOF
```

### Step 3.2: Deploy East-West Gateway on EKS

```bash
kubectl --context="${CTX_EKS}" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eastwest
  namespace: istio-system
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: ${EKS_NETWORK}
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: 15012
    protocol: TLS
    tls:
      mode: Passthrough
EOF
```

Wait for external IP:
```bash
kubectl --context="${CTX_EKS}" -n istio-system get svc eastwest -w
```

### Step 3.3: Verify EKS Istio Installation

```bash
kubectl --context="${CTX_EKS}" get pods -n istio-system
```

Expected pods: `istiod-*`, `ztunnel-*` (DaemonSet), `istio-cni-node-*` (DaemonSet), `eastwest-*`

---

## Part 4: Install Istio on AKS (Azure)

### Step 4.1: Install Istio in Ambient Mode

```bash
cat <<EOF | ./istioctl install --context="${CTX_AKS}" -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  profile: ambient
  meshConfig:
    accessLogFile: /dev/stdout
  values:
    global:
      meshID: ${MESH_ID}
      multiCluster:
        clusterName: aks-cluster
      network: ${AKS_NETWORK}
    pilot:
      env:
        PILOT_ENABLE_IP_AUTOALLOCATE: "true"
        PILOT_ENABLE_ALPHA_GATEWAY_API: "true"
EOF
```

### Step 4.2: Deploy East-West Gateway on AKS

```bash
kubectl --context="${CTX_AKS}" apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eastwest
  namespace: istio-system
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: ${AKS_NETWORK}
spec:
  gatewayClassName: istio-eastwest
  listeners:
  - name: cross-network
    port: 15008
    protocol: HBONE
    tls:
      mode: Passthrough
  - name: xds-tls
    port: 15012
    protocol: TLS
    tls:
      mode: Passthrough
EOF
```

Wait for external IP:
```bash
kubectl --context="${CTX_AKS}" -n istio-system get svc eastwest -w
```

### Step 4.3: Verify AKS Istio Installation

```bash
kubectl --context="${CTX_AKS}" get pods -n istio-system
```

Expected pods: `istiod-*`, `ztunnel-*` (DaemonSet), `istio-cni-node-*` (DaemonSet), `eastwest-*`

---

## Part 5: Connect the Clusters

### Step 5.1: Create Remote Secrets

Enable EKS to discover AKS services:
```bash
./istioctl create-remote-secret \
  --context="${CTX_AKS}" \
  --name=aks-cluster | \
  kubectl apply -f - --context="${CTX_EKS}"
```

Enable AKS to discover EKS services:
```bash
./istioctl create-remote-secret \
  --context="${CTX_EKS}" \
  --name=eks-cluster | \
  kubectl apply -f - --context="${CTX_AKS}"
```

### Step 5.2: Verify Cross-Cluster Discovery

Check that istiod on each cluster sees the remote cluster:
```bash
# On EKS
kubectl --context="${CTX_EKS}" logs -n istio-system -l app=istiod | grep -i "remote\|cluster"

# On AKS
kubectl --context="${CTX_AKS}" logs -n istio-system -l app=istiod | grep -i "remote\|cluster"
```

---

## Part 6: Deploy ECS Workloads (AWS)

### Step 6.1: Deploy ECS Clusters

```bash
./scripts/deploy-ecs-clusters.sh
```

### Step 6.2: Create Kubernetes Namespaces for ECS

```bash
./scripts/create-k8s-namespaces.sh
```

### Step 6.3: Add ECS Services to Mesh

```bash
./scripts/add-services-to-mesh.sh
```

---

## Part 7: Deploy Kubernetes Workloads (Azure)

### Step 7.1: Create Application Namespace

```bash
kubectl --context="${CTX_AKS}" create namespace app-a
kubectl --context="${CTX_AKS}" label namespace app-a istio.io/dataplane-mode=ambient
```

### Step 7.2: Deploy Echo Service on AKS

```bash
kubectl --context="${CTX_AKS}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: echo-service
  namespace: app-a
  labels:
    app: echo-service
    solo.io/service-scope: global
  annotations:
    networking.istio.io/traffic-distribution: Any
spec:
  ports:
  - port: 8080
    name: http
  selector:
    app: echo-service
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-service
  namespace: app-a
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-service
  template:
    metadata:
      labels:
        app: echo-service
    spec:
      containers:
      - name: echo
        image: public.ecr.aws/j8r2p7b6/echo-server:latest
        ports:
        - containerPort: 8080
        env:
        - name: PORT
          value: "8080"
EOF
```

### Step 7.3: Deploy Shell Pod for Testing

```bash
kubectl --context="${CTX_AKS}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shell
  namespace: app-a
spec:
  replicas: 1
  selector:
    matchLabels:
      app: shell
  template:
    metadata:
      labels:
        app: shell
    spec:
      containers:
      - name: shell
        image: curlimages/curl:latest
        command: ["sleep", "infinity"]
EOF
```

---

## Part 8: Deploy Test Pods on EKS

```bash
kubectl --context="${CTX_EKS}" label namespace default istio.io/dataplane-mode=ambient
kubectl --context="${CTX_EKS}" apply -f manifests/eks-echo.yaml
kubectl --context="${CTX_EKS}" apply -f manifests/eks-shell.yaml
```

---

## Part 9: Verify Service Discovery

### Check Services on EKS

```bash
./istioctl --context="${CTX_EKS}" ztunnel-config services
```

Expected: Services from both ECS clusters AND AKS app-a namespace.

### Check Services on AKS

```bash
./istioctl --context="${CTX_AKS}" ztunnel-config services
```

Expected: Services from AKS namespaces AND ECS clusters.

### Check Workloads

```bash
# EKS workloads
./istioctl --context="${CTX_EKS}" ztunnel-config workloads | grep -E "HBONE|ecs"

# AKS workloads
./istioctl --context="${CTX_AKS}" ztunnel-config workloads | grep HBONE
```

---

## Part 10: Test Cross-Cloud Connectivity

### Test EKS to AKS

```bash
# From EKS shell pod to AKS echo-service
kubectl --context="${CTX_EKS}" exec -it \
  $(kubectl --context="${CTX_EKS}" get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}") -- \
  curl -s echo-service.app-a.svc.cluster.local:8080 | jq '{hostname: .host.hostname}'
```

### Test AKS to ECS

```bash
# From AKS shell pod to ECS echo-service (Cluster 1)
kubectl --context="${CTX_AKS}" exec -it \
  $(kubectl --context="${CTX_AKS}" get pods -n app-a -l app=shell -o jsonpath="{.items[0].metadata.name}") \
  -n app-a -- \
  curl -s echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080 | jq '{hostname: .host.hostname}'
```

### Test ECS to ECS (via mesh)

```bash
ORIGIN_CLUSTER=ecs-${CLUSTER_NAME}-1 ./scripts/test/call-from-ecs.sh \
  echo-service.ecs-${CLUSTER_NAME}-2.ecs.local:8080
```

### Test ECS to AKS

```bash
ORIGIN_CLUSTER=ecs-${CLUSTER_NAME}-1 ./scripts/test/call-from-ecs.sh \
  echo-service.app-a.svc.cluster.local:8080
```

---

## Part 11: Authorization Policies (Cross-Cloud)

Authorization policies work across cloud boundaries using mesh identity.

### Example: Allow Only EKS to Access AKS Service

```bash
kubectl --context="${CTX_AKS}" apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: app-a
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-default
  namespace: app-a
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["default"]
    to:
    - operation:
        ports: ["8080"]
EOF
```

### Test Policy

```bash
# Should SUCCEED (from EKS default namespace)
kubectl --context="${CTX_EKS}" exec deployment/eks-shell -- \
  curl -s echo-service.app-a.svc.cluster.local:8080 | jq '{hostname: .host.hostname}'

# Should FAIL (from ECS - different namespace)
ORIGIN_CLUSTER=ecs-${CLUSTER_NAME}-1 ./scripts/test/call-from-ecs.sh \
  echo-service.app-a.svc.cluster.local:8080
# Expected: Connection reset
```

### Cleanup Policies

```bash
kubectl --context="${CTX_AKS}" delete authorizationpolicy --all -n app-a
```

---

## Cleanup

### Remove AKS Resources

```bash
# Delete AKS cluster
az aks delete \
  --resource-group $AZURE_RESOURCE_GROUP \
  --name $AKS_CLUSTER_NAME \
  --yes

# Delete resource group
az group delete \
  --name $AZURE_RESOURCE_GROUP \
  --yes
```

### Remove AWS Resources

```bash
# Run cleanup script for ECS
./scripts/cleanup.sh

# Delete EKS cluster
export AWS_PROFILE=$INT
eksctl delete cluster -n ${CLUSTER_NAME}
```

### Remove Certificates

```bash
rm -rf certs/
```

---

## Summary

You've successfully deployed:
- Istio Ambient mesh spanning AWS and Azure
- Multi-primary control plane architecture
- ECS workloads on AWS integrated with Kubernetes workloads on Azure
- Cross-cloud mTLS encryption via nested HBONE tunnels
- Unified authorization policies across clouds

**Key Achievements:**
- True multicloud service mesh without vendor lock-in
- Unified security policies across cloud boundaries
- Seamless service discovery between AWS ECS and Azure Kubernetes
- Zero-trust networking with automatic mTLS

---

## Troubleshooting

### Cross-Cloud Connectivity Fails?

1. Verify east-west gateways have external IPs:
   ```bash
   kubectl --context="${CTX_EKS}" -n istio-system get svc eastwest
   kubectl --context="${CTX_AKS}" -n istio-system get svc eastwest
   ```

2. Check remote secrets are applied:
   ```bash
   kubectl --context="${CTX_EKS}" -n istio-system get secrets | grep istio-remote
   kubectl --context="${CTX_AKS}" -n istio-system get secrets | grep istio-remote
   ```

3. Check istiod logs for remote cluster connection:
   ```bash
   kubectl --context="${CTX_EKS}" logs -n istio-system -l app=istiod | grep -i "remote\|cluster"
   ```

### Services Not Discovered Across Clusters?

1. Verify meshID matches:
   ```bash
   kubectl --context="${CTX_EKS}" -n istio-system get cm istio -o yaml | grep meshID
   kubectl --context="${CTX_AKS}" -n istio-system get cm istio -o yaml | grep meshID
   ```

2. Check ServiceScope (services need `istio.io/global: "true"` label for cross-cluster discovery)

3. Restart istiod to refresh discovery:
   ```bash
   kubectl --context="${CTX_EKS}" rollout restart deployment/istiod -n istio-system
   kubectl --context="${CTX_AKS}" rollout restart deployment/istiod -n istio-system
   ```

### Certificate Errors?

Verify both clusters use the same root CA:
```bash
kubectl --context="${CTX_EKS}" -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -subject
kubectl --context="${CTX_AKS}" -n istio-system get secret cacerts -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -subject
```

Both should show the same root CA subject.

---

## References

- [Istio Ambient Multicluster (Alpha)](https://istio.io/latest/blog/2025/ambient-multicluster/)
- [Istio Multicluster Installation Guide](https://istio.io/latest/docs/ambient/install/multicluster/)
- [Azure AKS Documentation](https://learn.microsoft.com/en-us/azure/aks/)
- [Solo.io Multicluster Documentation](https://docs.solo.io/gloo-mesh/main/quickstart/multi/)
