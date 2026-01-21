# Scenario 2: Two ECS Clusters (Same Account)

This guide walks you through deploying **Istio Ambient service mesh** with two ECS clusters in a single AWS account. This demonstrates multi-cluster service mesh without cross-account complexity.

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
                    ┌────┴────┐
                    ▼         ▼
             ┌──────────┐ ┌──────────┐
             │ Cluster 1│ │ Cluster 2│
             │ (local)  │ │ (local)  │
             │          │ │          │
             │shell-task│ │shell-task│
             │echo-svc  │ │echo-svc  │
             └──────────┘ └──────────┘
               ecs.local    ecs.local
```

**Services per Cluster:**
- `shell-task.ecs-{CLUSTER_NAME}-{1,2}.ecs.local` - curl container for testing
- `echo-service.ecs-{CLUSTER_NAME}-{1,2}.ecs.local:8080` - HTTP echo server

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
export SCENARIO=2

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
export HUB=us-east1-docker.pkg.dev/istio-enterprise-private/gme-istio-testing-images
export ISTIO_TAG=1.29-alpha.20806789ba7dd5528bab31384ca99d3d6f78b122
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
wget <your-download-link>
tar xvzf istio-*.tar.gz --strip-components=2 istio-*/bin/istioctl
rm istio-*.tar.gz
chmod +x istioctl
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

---

## Part 3: Deploy ECS Workloads

### Step 3.1: Deploy ECS Clusters and Services

```bash
./scripts/deploy-ecs-clusters.sh
```

This deploys:
- 2 ECS clusters: `ecs-{CLUSTER_NAME}-1`, `ecs-{CLUSTER_NAME}-2`
- 2 services per cluster: `shell-task`, `echo-service`

### Step 3.2: Create Kubernetes Namespaces

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

Expected (4 services - 2 per cluster):
```
NAMESPACE               SERVICE NAME                               SERVICE VIP
ecs-{CLUSTER_NAME}-1   ecs-service-...-echo-service   240.240.0.2
ecs-{CLUSTER_NAME}-1   ecs-service-...-shell-task     240.240.0.4
ecs-{CLUSTER_NAME}-2   ecs-service-...-echo-service   240.240.0.6
ecs-{CLUSTER_NAME}-2   ecs-service-...-shell-task     240.240.0.5
```

### Check Workloads are Using HBONE

```bash
./istioctl ztunnel-config workloads | grep $CLUSTER_NAME | awk '{ print $2 "\t" $5; }'
```

### Check Service Entries

```bash
kubectl get serviceentry -A
```

Expected: 4 ServiceEntry objects (2 per namespace).

---

## Part 5: Test Connectivity

### Deploy Test Pods in EKS

```bash
kubectl label namespace default istio.io/dataplane-mode=ambient
kubectl apply -f manifests/eks-echo.yaml
kubectl apply -f manifests/eks-shell.yaml
```

### Test EKS-to-ECS Cluster 1

```bash
kubectl exec -it $(kubectl get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}") -- \
  curl echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080 | jq '{hostname: .host.hostname, ip: .host.ip}'
```

### Test EKS-to-ECS Cluster 2

```bash
kubectl exec -it $(kubectl get pods -l app=eks-shell -o jsonpath="{.items[0].metadata.name}") -- \
  curl echo-service.ecs-${CLUSTER_NAME}-2.ecs.local:8080 | jq '{hostname: .host.hostname, ip: .host.ip}'
```

### Test Cross-Cluster ECS Communication

From Cluster 1 to Cluster 2:
```bash
ORIGIN_CLUSTER=ecs-${CLUSTER_NAME}-1 scripts/test/call-from-ecs.sh echo-service.ecs-${CLUSTER_NAME}-2.ecs.local:8080
```

From Cluster 2 to Cluster 1:
```bash
ORIGIN_CLUSTER=ecs-${CLUSTER_NAME}-2 scripts/test/call-from-ecs.sh echo-service.ecs-${CLUSTER_NAME}-1.ecs.local:8080
```

---

## Part 6: Authorization Policy Workshop

This section walks through Istio L4 authorization policies to control traffic between clusters.

### Interactive Test Script

Run the interactive test script to explore each policy:

```bash
./scripts/test/test-authz-policies.sh
```

Or run a specific exercise:

```bash
./scripts/test/test-authz-policies.sh -e 1    # Baseline (no policies)
./scripts/test/test-authz-policies.sh -e 2    # Deny-all
./scripts/test/test-authz-policies.sh -e 3    # Allow EKS
./scripts/test/test-authz-policies.sh -e 4    # Allow Cluster 2
./scripts/test/test-authz-policies.sh -e 5    # Allow internal
./scripts/test/test-authz-policies.sh -e 6    # Explicit deny
./scripts/test/test-authz-policies.sh -e all  # Run all exercises
```

---

### Exercise 6.1: Baseline (No Policies)

Verify all connections work without policies. Clear any existing policies:

```bash
kubectl delete authorizationpolicy --all -n ecs-${CLUSTER_NAME}-1
kubectl delete authorizationpolicy --all -n ecs-${CLUSTER_NAME}-2
```

**Test:**
```bash
./scripts/test/test-authz-policies.sh -e 1
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 internal (shell -> echo)
[PASS] Connected successfully
```

---

### Exercise 6.2: Deny-All Policy

Block all traffic to Cluster 1:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  {}
```

Apply and test:
```bash
./scripts/test/test-authz-policies.sh -e 2
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
[TEST] Cluster 1 internal (shell -> echo)
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
```

**Effect:** All inbound traffic to Cluster 1 is blocked. Cluster 2 remains accessible.

---

### Exercise 6.3: Allow EKS to Cluster 1

Allow only EKS (namespace `default`) to reach Cluster 1. This policy is added alongside the deny-all:

```yaml
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
```

Apply and test:
```bash
./scripts/test/test-authz-policies.sh -e 3
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
[TEST] Cluster 1 internal (shell -> echo)
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
```

**Effect:** EKS can reach Cluster 1, but Cluster 2 and internal traffic are still blocked.

---

### Exercise 6.4: Allow Cluster 2 to Cluster 1

Enable cross-cluster communication by adding another ALLOW policy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-cluster-2-to-echo
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["ecs-${CLUSTER_NAME}-2"]
    to:
    - operation:
        ports: ["8080"]
```

Apply and test:
```bash
./scripts/test/test-authz-policies.sh -e 4
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 internal (shell -> echo)
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
```

**Effect:** Both EKS and Cluster 2 can reach Cluster 1. Internal traffic is still blocked.

---

### Exercise 6.5: Allow Internal Communication

Allow services within Cluster 1 to communicate:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-internal
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  action: ALLOW
  rules:
  - from:
    - source:
        namespaces: ["ecs-${CLUSTER_NAME}-1"]
    to:
    - operation:
        ports: ["8080"]
```

Apply and test:
```bash
./scripts/test/test-authz-policies.sh -e 5
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 internal (shell -> echo)
[PASS] Connected successfully
```

**Effect:** All traffic paths are now allowed through the combination of ALLOW policies.

---

### Exercise 6.6: Explicit Deny

This exercise resets policies and demonstrates that DENY rules take precedence over ALLOW rules.
The script clears all policies and applies: deny-all + allow-eks-to-echo + deny-cluster-2.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: deny-cluster-2
  namespace: ecs-${CLUSTER_NAME}-1
spec:
  action: DENY
  rules:
  - from:
    - source:
        namespaces: ["ecs-${CLUSTER_NAME}-2"]
```

Apply and test:
```bash
./scripts/test/test-authz-policies.sh -e 6
```

**Expected Output:**
```
[TEST] EKS -> Cluster 1 echo-service
[PASS] Connected successfully
[TEST] EKS -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 1 -> Cluster 2 echo-service
[PASS] Connected successfully
[TEST] Cluster 2 -> Cluster 1 echo-service
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
[TEST] Cluster 1 internal (shell -> echo)
[FAIL] Connection failed: curl: (56) Recv failure: Connection reset
```

**Effect:** Cluster 2 is explicitly blocked by the DENY rule. Even adding an ALLOW rule for Cluster 2 would not help because DENY is evaluated first.

---

### Cleanup Policies

Remove all authorization policies:

```bash
./scripts/test/test-authz-policies.sh --cleanup
```

Or manually:

```bash
kubectl delete authorizationpolicy --all -n ecs-${CLUSTER_NAME}-1
kubectl delete authorizationpolicy --all -n ecs-${CLUSTER_NAME}-2
```

---

### Key Concepts

| Concept | Description |
|---------|-------------|
| Empty `spec: {}` | Implicit deny-all (blocks everything) |
| `action: ALLOW` | Opens specific paths through deny-all |
| `action: DENY` | Evaluated before ALLOW rules |
| `source.namespaces` | Identity from mTLS certificates |
| `operation.ports` | L4 port filtering |

**Note:** L7 features (HTTP methods, paths, hosts) require a waypoint proxy. See [Scenario 3](Readme-scenario-3.md) for L7 examples.

---

## Part 7: Observability

### View Access Logs

```bash
kubectl logs -n istio-system -l app=ztunnel --tail=100 | grep echo-service
```

### Monitor Cross-Cluster Traffic

```bash
# Watch for traffic patterns
kubectl logs -n istio-system -l app=ztunnel -f | grep -E "ecs-${CLUSTER_NAME}-(1|2)"
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
- Two ECS clusters with automatic cross-cluster service discovery
- Zero-trust mTLS encryption
- L4 authorization policies for cluster isolation

**Key Learnings:**
- Multiple ECS clusters can be managed by a single Istio control plane
- Cross-cluster communication is automatic once services are added to the mesh
- Authorization policies can isolate clusters while still allowing specific access

**Next Steps:**
- Try [Scenario 3](Readme-scenario-3.md) for cross-account setup with VPC peering

---

## Troubleshooting

### Cross-Cluster Communication Fails?

1. Verify both namespaces are labeled for ambient mode:
   ```bash
   kubectl get ns -l istio.io/dataplane-mode=ambient
   ```

2. Check workloads are enrolled:
   ```bash
   ./istioctl ztunnel-config workloads | grep $CLUSTER_NAME
   ```

3. Check for authorization policies blocking traffic:
   ```bash
   kubectl get authorizationpolicies -A
   ```

### Only One Cluster Discovered?

```bash
# Check ECS clusters exist
aws ecs list-clusters --profile $INT

# Check discovery tag
aws ecs list-tags-for-resource --resource-arn <cluster-arn> --profile $INT
# Should show: ecs.solo.io/discovery-enabled=true
```

### Services Not Appearing?

```bash
# Re-add services to mesh
./scripts/add-services-to-mesh.sh

# Restart Istiod to refresh discovery
kubectl rollout restart deployment/istiod -n istio-system
```
