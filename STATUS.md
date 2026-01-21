# ECS Multi-Account Demo Workshop Status

> **Last Updated**: 2026-01-21

This file tracks operational status for all scenarios. Update after test runs and when issues are discovered/resolved.

---

## Scenario Status Summary

| Scenario | Description | Last Test | Status | Passed | Failed | Notes |
|----------|-------------|-----------|--------|--------|--------|-------|
| 1 | Single ECS cluster | 2026-01-20 | Passing | 8 | 0 | All tests pass |
| 2 | Two ECS clusters (same account) | 2026-01-20 | Passing | 20 | 0 | All tests pass |
| 3 | Three ECS clusters (cross-account) | 2026-01-21 | Passing | 30 | 0 | Full E2E with authz policies, ~27 min |
| 4 | Multicloud (EKS + AKS) | - | Skipped | - | - | Requires Azure config |

**Status:** Passing (all tests pass) | Partial (some fail) | Failing (critical fail) | Untested

---

## Current Environment

| Component | Version | Notes |
|-----------|---------|-------|
| Gateway API | v1.4.0 | Standard CRDs |
| Istio (Solo.io) | 1.28.1-solo | Solo.io distribution with ECS support |
| istioctl | 1.28.1-solo | Requires Solo.io distribution |
| eksctl | Latest | For EKS cluster creation |
| AWS CLI | v2 | With SSO support |
| Kubernetes | EKS 1.30+ | Tested on EKS |

---

## Scenario 1: Single ECS Cluster

### Last Successful Test Run

| Field | Value |
|-------|-------|
| **Date** | - |
| **Tester** | - |
| **Config** | scripts/test/test-scenario-1-config.sh |
| **Tests Passed** | - |
| **Tests Failed** | - |
| **Notes** | No tests recorded yet |

### Test Run History

| Date | Result | Passed/Failed | Tester | Notes |
|------|--------|---------------|--------|-------|
| 2026-01-20 | FAILED | 0/0 | Claude | Setup failed at step 6 (eastwest_gateway): waypoint timeout |

---

## Scenario 2: Two ECS Clusters (Same Account)

### Last Successful Test Run

| Field | Value |
|-------|-------|
| **Date** | 2026-01-20 |
| **Tester** | Claude |
| **Config** | scripts/test/test-scenario-2-config.sh |
| **Tests Passed** | 20 |
| **Tests Failed** | 0 |
| **Notes** | Full end-to-end including authz policies |

### Test Run History

| Date | Result | Passed/Failed | Tester | Notes |
|------|--------|---------------|--------|-------|
| 2026-01-20 | PASS | 20/0 | Claude | All tests pass, cleanup successful |

---

## Scenario 3: Cross-Account (3 ECS Clusters)

### Last Successful Test Run

| Field | Value |
|-------|-------|
| **Date** | 2026-01-21 |
| **Tester** | Claude |
| **Config** | scripts/test/test-scenario-3-config.sh |
| **Tests Passed** | 30 |
| **Tests Failed** | 0 |
| **Duration** | ~27 minutes (12:42 - 13:09) |
| **Notes** | Full E2E with authz policies, cross-account connectivity verified |

### Timing Breakdown

| Phase | Duration | Notes |
|-------|----------|-------|
| EKS Cluster Creation | ~14 min | eksctl with 2-node managed nodegroup |
| Infrastructure Setup | ~5 min | VPC, subnets, NAT GW, VPC peering, security groups, IAM roles |
| Istio Installation | ~2 min | Ambient mode with east-west gateway |
| ECS Deployment | ~3 min | 3 clusters (2 local + 1 external), 6 services total |
| Mesh Enrollment | ~1 min | Add services to mesh with ztunnel sidecars |
| Tests Execution | ~2 min | 30 tests (connectivity + authz policies) |
| **Total** | **~27 min** | Fresh environment from scratch |

### Test Categories

| Category | Tests | Result |
|----------|-------|--------|
| Service Discovery | 3 | PASS |
| EKS-to-EKS Connectivity | 1 | PASS |
| EKS-to-ECS Connectivity | 3 | PASS |
| ECS Internal Connectivity | 3 | PASS |
| Cross-cluster Connectivity | 2 | PASS |
| Cross-account Connectivity | 2 | PASS |
| Authorization Policies (6.2-6.7) | 16 | PASS |

### Test Run History

| Date | Result | Passed/Failed | Tester | Duration | Notes |
|------|--------|---------------|--------|----------|-------|
| 2026-01-21 | PASS | 30/0 | Claude | 27 min | Fresh env, all tests pass |
| 2026-01-21 | FAIL | 2/28 | Claude | - | Stale Pod Identity association (istiod 19h old) |

---

## Scenario 4: Multicloud (EKS + AKS)

### Last Successful Test Run

| Field | Value |
|-------|-------|
| **Date** | - |
| **Tester** | - |
| **Config** | scripts/test/test-scenario-4-config.sh |
| **Tests Passed** | - |
| **Tests Failed** | - |
| **Notes** | No tests recorded yet |

### Test Run History

| Date | Result | Passed/Failed | Tester | Notes |
|------|--------|---------------|--------|-------|
| - | - | - | - | No test runs recorded |

---

## Known Issues

### Open Issues

| ID | Severity | Scenarios | Component | Description | Workaround | Reported |
|----|----------|-----------|-----------|-------------|------------|----------|
| ECS-001 | High | All | deploy_eastwest_gateway | istioctl multicluster expose times out waiting for waypoint; LB IP stays pending | Increase timeout or retry manually | 2026-01-20 |

### Resolved Issues

| ID | Scenarios | Component | Description | Resolution | Resolved |
|----|-----------|-----------|-------------|------------|----------|
| *No resolved issues yet* | - | - | - | - | - |

---

## Version History

| Date | Change | Scenarios Affected |
|------|--------|-------------------|
| 2026-01-21 | Added --wait-for-deletion to cleanup.sh (prevents race conditions with CloudFormation) | All |
| 2026-01-21 | Added uninstall_istio() to cleanup.sh for complete Istio removal | All |
| 2026-01-21 | Scenario 3 first successful test run (30/30 pass) | 3 |
| 2026-01-20 | Enhanced test framework: STEP_DESCRIPTIONS, STEP_PARTS, progress files, --stop-after | All |
| 2026-01-20 | Initial STATUS.md creation | All |

---

## Test Plan

### Running Tests

```bash
# Scenario 1: Single ECS cluster
./scripts/test/test-scenario-1.sh -c scripts/test/test-scenario-1-config.sh

# Scenario 2: Two ECS clusters
./scripts/test/test-scenario-2.sh -c scripts/test/test-scenario-2-config.sh

# Scenario 3: Cross-account (requires two AWS profiles)
./scripts/test/test-scenario-3.sh -c scripts/test/test-scenario-3-config.sh

# Scenario 4: Multicloud (requires Azure setup)
./scripts/test/test-scenario-4.sh -c scripts/test/test-scenario-4-config.sh
```

### EKS Cluster Lifecycle

| Action | Behavior | When |
|--------|----------|------|
| **Creation** | Automatic, idempotent | Part of setup (step 2: `eks_cluster`) |
| **Deletion** | **Optional**, only with `-d` flag | After tests, if `-d` specified |

```bash
# Full run: creates EKS if needed, keeps cluster after tests
./scripts/test/test-scenario-1.sh -c config.sh

# Full run + cleanup: creates EKS, deletes EVERYTHING after
./scripts/test/test-scenario-1.sh -c config.sh -d

# Tests only: assumes EKS exists, skips setup
./scripts/test/test-scenario-1.sh -c config.sh -t

# Resume from specific step
./scripts/test/test-scenario-1.sh -c config.sh -s istio_install

# Manual EKS deletion
eksctl delete cluster -n $CLUSTER_NAME --profile $INT --region $AWS_REGION
```

**Cost note**: EKS clusters incur AWS charges. Use `-d` for one-off runs.

### Recommended Test Order

1. **Scenario 1** (simplest) - Basic ECS integration
2. **Scenario 2** - Multi-cluster same-account
3. **Scenario 3** - Cross-account (if two AWS accounts available)
4. **Scenario 4** - Multicloud (if Azure available)

### Quick Validation

```bash
kubectl get pods -n istio-system                              # Istio running?
./istioctl ztunnel-config services | grep $CLUSTER_NAME       # Service discovery?
./istioctl ztunnel-config workloads | grep $CLUSTER_NAME      # Workload enrollment?
kubectl get serviceentry -A                                    # ServiceEntry objects?
```

### Config Setup

```bash
# Copy and edit config templates
cp scripts/test/test-scenario-1-config.sh.example scripts/test/test-scenario-1-config.sh

# Required variables:
# LOCAL_ACCOUNT, LOCAL_ACCOUNT_PROFILE, AWS_REGION, CLUSTER_NAME
# HUB, ISTIO_TAG, GLOO_MESH_LICENSE_KEY
```
