# Scenario 1: Single ECS Cluster

This guide walks you through deploying **Istio Ambient service mesh** with a single ECS cluster in one AWS account. This is the simplest scenario, ideal for learning the basics.

## What You'll Deploy

```
┌─────────────────────────────────────────────────────┐
│                 ISTIO CONTROL PLANE                 │
│                   (in EKS cluster)                  │
│         ┌──────────┐       ┌──────────┐             │
│         │  Istiod  │       │ Ztunnel  │             │
│         └──────────┘       └──────────┘             │
└────────────────────────┬────────────────────────────┘
                         │
                         ▼
                  ┌─────────────┐
                  │  Cluster 1  │
                  │  (local)    │
                  │             │
                  │ shell-task  │
                  │ echo-service│
                  └─────────────┘
                    ecs.local
```

**Services:**
- `shell-task.ecs-{CLUSTER_NAME}-1.ecs.local` - curl container for testing
- `echo-service.ecs-{CLUSTER_NAME}-1.ecs.local:8080` - HTTP echo server

---

## Prerequisites

- AWS CLI configured with one profile
- kubectl with access to your EKS cluster (or eksctl to create one)
- istioctl with ECS support from Solo.io
- jq
- Gloo Mesh license key

---

## Step 0: Environment Setup

### 0.1 Create Configuration File

```bash
cat << 'EOF' > env-config.sh
# Scenario Selection
export SCENARIO=1

# AWS Account Information
export LOCAL_ACCOUNT=<your_account_id>              # e.g., 123456789012
export LOCAL_ACCOUNT_PROFILE=<your_profile>         # e.g., default
export INT=$LOCAL_ACCOUNT_PROFILE

# AWS Region and Cluster Configuration
export AWS_REGION=us-east-2
export CLUSTER_NAME=istio-ecs-demo
export OWNER_NAME=$(whoami)

# EKS Configuration
export NUMBER_NODES=2
export NODE_TYPE=t2.medium

# Istio Configuration
export HUB=us-docker.pkg.dev/gloo-mesh/istio-594e990587b9
export ISTIO_TAG=1.28.1-solo
export GLOO_MESH_LICENSE_KEY=<your-license-key>
EOF
```

### 0.2 Login to AWS

```bash
source env-config.sh
aws sso login --profile $LOCAL_ACCOUNT_PROFILE
```

---

## Part 1: Infrastructure Setup

### Step 1.1: Create the EKS Cluster

```bash
export AWS_PROFILE=$INT
eval "echo \"$(cat manifests/eks-cluster.yaml)\"" | eksctl create cluster --config-file -
```

### Step 1.2: Deploy Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
```

### Step 1.3: Setup Infrastructure and IAM Roles

Run the infrastructure setup script. This:
- Validates the EKS cluster exists
- Creates `istiod-local` IAM role for Istio's ECS integration
- Configures the eksctl-created role to assume `istiod-local`

```bash
./scripts/setup-infrastructure.sh
```

Then create IAM roles for ECS tasks:

```bash
./scripts/create-iam-roles.sh
```

---

## Part 2: Service Mesh Deployment

### Step 2.1: Download istioctl

Contact Solo.io for the download link, then:

```bash
# Example for Linux amd64
wget <your-download-link>
tar xvzf istio-*.tar.gz --strip-components=2 istio-*/bin/istioctl
rm istio-*.tar.gz
chmod +x istioctl
```

Verify:
```bash
./istioctl version
```

### Step 2.2: Install Istio in Ambient Mode

```bash
source env-config.sh

cat <<EOF | ./istioctl install -y -f -
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
      network: eks
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

### Step 2.3: Deploy East-West Gateway

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/expose-istiod: "15012"
    topology.istio.io/network: eks
  name: eastwest
  namespace: istio-system
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

### Step 2.4: Label Network

```bash
kubectl label namespace istio-system topology.istio.io/network=eks
```

### Step 2.5: Verify Istio Installation

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

## Part 3: Deploy ECS Workloads

### Step 3.1: Deploy ECS Cluster and Services

```bash
./scripts/deploy-ecs-clusters.sh
```

This deploys:
- 1 ECS cluster: `ecs-{CLUSTER_NAME}-1`
- 2 services: `shell-task`, `echo-service`

### Step 3.2: Create Kubernetes Namespace

```bash
./scripts/create-k8s-namespaces.sh
```

### Step 3.3: Add Services to Mesh

```bash
./scripts/add-services-to-mesh.sh
```

---

## Part 4: Verify Service Discovery

### Check Services are Discovered

```bash
./istioctl ztunnel-config services | grep $CLUSTER_NAME
```

Expected:
```
NAMESPACE          SERVICE NAME                                              SERVICE VIP
ecs-{CLUSTER_NAME}-1  ecs-service-...-echo-service   240.240.0.2,2001:2::2
ecs-{CLUSTER_NAME}-1  ecs-service-...-shell-task     240.240.0.4,2001:2::4
```

### Check Workloads are Using HBONE

```bash
./istioctl ztunnel-config workloads | grep $CLUSTER_NAME
```

Look for `HBONE` in the output - this confirms mTLS is active.

### Check Service Entries

```bash
kubectl get serviceentry -A
```

---

## Part 5: Test Connectivity

### Deploy Test Pods in EKS

```bash
# Label default namespace for ambient mode
kubectl label namespace default istio.io/dataplane-mode=ambient

# Deploy test applications
kubectl apply -f manifests/eks-echo.yaml
kubectl apply -f manifests/eks-shell.yaml
```

### Test EKS-to-EKS

```bash
kubectl exec -it $(kubectl get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}") -- curl eks-echo:8080
```

### Test EKS-to-ECS

```bash
kubectl exec -it $(kubectl get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}") -- \
  curl echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080 | jq
```

Expected response includes hostname and IP from the ECS task.

### Test ECS-to-ECS (within same cluster)

```bash
scripts/test/call-from-ecs.sh echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080
```

---

## Part 6: Apply Security Policies

### L4 Authorization Policy

Deny all traffic by default, then allow specific access:

```bash
kubectl apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  {}
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-eks-to-echo
  namespace: ecs-${CLUSTER_NAME}-1
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
kubectl exec deployment/eks-shell -- \
  curl echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080 \
  | jq '{hostname: .host.hostname}'

# Should FAIL (from ECS shell-task - not in allowed namespace)
scripts/test/call-from-ecs.sh echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080
# Expected: curl: (56) Recv failure: Connection reset by peer
```

---

## Part 7: Observability

### View Access Logs

```bash
kubectl logs -n istio-system -l app=ztunnel --tail=50
```

### View Service Topology

```bash
./istioctl ztunnel-config services
./istioctl ztunnel-config workloads
```

---

## Cleanup

### Remove All Resources

```bash
./scripts/cleanup.sh
```

### Delete EKS Cluster

```bash
export AWS_PROFILE=$INT
eksctl delete cluster -n ${CLUSTER_NAME}
```

---

## Summary

You've successfully deployed:
- Istio Ambient service mesh on EKS
- Single ECS cluster with automatic service discovery
- Zero-trust mTLS encryption
- L4 authorization policies

**Next Steps:**
- Try [Scenario 2](Readme-scenario-2.md) for multi-cluster within same account
- Try [Scenario 3](Readme-scenario-3.md) for cross-account setup

---

## Troubleshooting

### Services Not Discovered?

```bash
kubectl logs -n istio-system deploy/istiod | grep ecs
# Restart istiod
kubectl rollout restart deployment/istiod -n istio-system
```

### Traffic Not Encrypted?

```bash
./istioctl ztunnel-config workloads | grep -i hbone
# If showing TCP instead of HBONE, re-run add-services-to-mesh.sh
```

### ECS Tasks Not Starting?

```bash
# Check task logs
aws ecs describe-tasks --cluster ecs-${CLUSTER_NAME}-1 --tasks <task-id> --profile $INT
# Check CloudWatch logs
aws logs tail /ecs/ecs-demo --profile $INT
```
