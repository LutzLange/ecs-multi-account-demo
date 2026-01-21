# Istio Ambient Service Mesh for AWS ECS

Workshops demonstrating **Solo.io's Istio Ambient service mesh** integration with AWS ECS Fargate.

## The Problem

ECS Fargate workloads run outside Kubernetes and lack native service mesh support:
- No automatic mTLS between services
- No unified traffic policies across EKS and ECS
- No service discovery for ECS tasks from Kubernetes

## The Solution

Solo.io's Istio distribution extends Ambient mesh to ECS workloads, providing:
- **Zero-Trust mTLS** - Automatic encryption between all workloads
- **Unified Policies** - Same AuthorizationPolicy syntax for K8s and ECS
- **Service Discovery** - ECS services appear in Istio's service registry
- **No Sidecars** - Ambient mode uses ztunnel instead of per-pod sidecars

---

## Workshop Scenarios

| Scenario | Description | Guide |
|----------|-------------|-------|
| **1** | Single ECS cluster, single AWS account | [Readme-scenario-1.md](Readme-scenario-1.md) |
| **2** | Two ECS clusters, single AWS account | [Readme-scenario-2.md](Readme-scenario-2.md) |
| **3** | Three ECS clusters, two AWS accounts | [Readme-scenario-3.md](Readme-scenario-3.md) |
| **4** | Multicloud: AWS + Azure | [Readme-scenario-4.md](Readme-scenario-4.md) *(not yet implemented)* |

**Pick based on your environment:**
- Have one AWS account? Start with **Scenario 1** or **2**
- Have two AWS accounts? **Scenario 3** shows cross-account mesh
- Have AWS and Azure? **Scenario 4** demonstrates multicloud

Each scenario guide includes prerequisites, setup, verification, and cleanup.

---

## Key Concepts

**Istio Ambient Mode** - A sidecar-less service mesh architecture where traffic is handled by:
- **Ztunnel** - Node-level proxy for mTLS and L4 policies
- **Waypoint Proxy** (optional) - For L7 policies

**ECS Integration** - Solo.io extends Istio to discover and secure ECS tasks:
- Ztunnel runs as an ECS sidecar container
- Istiod discovers ECS tasks via AWS APIs
- ServiceEntry/WorkloadEntry represent ECS services in Kubernetes

**HBONE Protocol** - HTTP-Based Overlay Network Encapsulation tunnels mTLS traffic through east-west gateways for cross-network communication.

---

## Support

- [Solo.io](https://www.solo.io/company/contact/) - For Gloo Mesh licensing and istioctl access
- [Solo.io Docs](https://docs.solo.io/) - Product documentation
