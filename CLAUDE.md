# CLAUDE.md - Project Guidelines for Claude Code

## Quick Reference

> **Before starting work**: Check `STATUS.md` for current workshop status and known issues.

**Critical rules:**
1. **Full automation**: Scripts MUST run end-to-end without manual intervention. If manual steps are needed, **fix the script** instead.
2. **Three-way sync**: Markdown guides, test scripts, and setup scripts MUST stay synchronized
3. **Idempotency**: Every operation must be safe to run multiple times
4. **Step system**: Use `run_step()` for all significant operations; track progress in `.workshop-progress-scN` files
5. **Config-driven**: Never hardcode values; use config file variables
6. **Key file**: Read `scripts/test/test-lib.sh` first - it contains all shared functions

**Key files:**
| File | Purpose |
|------|---------|
| `STATUS.md` | Current status, known issues, test history |
| `scripts/test/test-lib.sh` | All shared functions - **read this first** |
| `scripts/test/test-scenario-*-config.sh.example` | Config templates |
| `Readme-scenario-*.md` | User-facing workshop guides |

---

## Project Context

This repository contains **Solo.io Istio Ambient Service Mesh workshops** for presales demonstrations:

- **Setup scripts**: Prepare AWS/Kubernetes infrastructure
- **Test scripts**: Automated end-to-end testing
- **Markdown guides**: Step-by-step user instructions

**Scenarios:**
| Scenario | Description | Clusters |
|----------|-------------|----------|
| 1 | Single ECS cluster, single account | 1 ECS |
| 2 | Two ECS clusters, single account | 2 ECS |
| 3 | Three ECS clusters, two accounts | 3 ECS (cross-account) |
| 4 | Multicloud (EKS + AKS) | EKS + AKS |

---

## Working Methodology

### The Plan-Verify-Execute-Evaluate Cycle

#### 1. PLAN - Understand Before Acting
- Read relevant existing code before proposing changes
- Identify all files that will be affected
- Check how similar functionality is implemented elsewhere in the codebase

#### 2. VERIFY - Validate the Plan
- Cross-reference with existing patterns in `test-lib.sh`
- Ensure the approach maintains idempotency
- Verify the plan doesn't break the step system

#### 3. EXECUTE - Implement Incrementally
- Make one logical change at a time
- Test each change before proceeding

#### 4. EVALUATE - Assess Results
- Run the script to verify it works
- Check for edge cases (script restart, missing config, etc.)

#### 5. RE-PLAN - Iterate if Needed
- If issues are found, understand the root cause
- Adjust the approach based on learnings

---

## Full Automation Requirements

**Scripts must be completely self-sufficient.** When a script encounters an issue:

1. **Fix the script** - Never work around issues manually
2. **Wait for async operations** - AWS operations (EKS deletion, LB deletion, etc.) are async; scripts must wait for completion
3. **Check resource states** - Before proceeding, verify resources are in expected state
4. **Handle edge cases** - Scripts may run on partially-configured systems or mid-cleanup states

### Common Automation Patterns

```bash
# Wait for EKS cluster deletion before proceeding
while aws eks describe-cluster --name "$CLUSTER" &>/dev/null; do
    log_info "Waiting for cluster deletion..."
    sleep 30
done

# Wait for CloudFormation stack deletion
aws cloudformation wait stack-delete-complete --stack-name "$STACK"

# Check if resource exists before creating
if ! aws eks describe-cluster --name "$CLUSTER" &>/dev/null; then
    create_cluster
fi

# Update kubeconfig when cluster exists (don't assume it's configured)
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION"
```

### Cleanup Must Be Thorough

Cleanup scripts must handle:
- **Load Balancers** (CLB and ALB/NLB) - Delete before VPC/SG cleanup
- **Security Groups** - Remove rules first (SGs can reference each other), then delete
- **CloudFormation stacks** - Wait for deletion to complete
- **Async deletion** - AWS resources take time to fully delete; wait before proceeding

**Example: Proper security group cleanup**
```bash
# Step 1: Remove all rules (SGs may reference each other)
for sg in $security_groups; do
    aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions "$(get_rules $sg)"
    aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions "$(get_egress_rules $sg)"
done

# Step 2: Now delete (rules removed, no dependencies)
for sg in $security_groups; do
    aws ec2 delete-security-group --group-id "$sg"
done
```

---

## Script Architecture Standards

### Required Features

Every script MUST implement:

#### 1. Configuration File Support (`-c` option)

```bash
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config) CONFIG_FILE="$2"; shift 2 ;;
            # ... other options
        esac
    done
}
```

#### 2. Step System for Resumability

```bash
source "$SCRIPT_DIR/test-lib.sh"

SETUP_STEPS=("step_one" "step_two" "step_three")

declare -A STEP_DESCRIPTIONS=(
    ["step_one"]="First Step Description"
    ["step_two"]="Second Step Description"
)

declare -A STEP_PARTS=(
    ["step_one"]="Part 1: Setup"
    ["step_two"]="Part 2: Deploy"
)

export PROGRESS_FILE="$REPO_ROOT/.workshop-progress-sc1"
load_progress

# run_step returns: 0=success, 1=failure, 2=stop-after reached
run_step "step_one" do_step_one
```

**Required options:**
- `-s|--step <name|number>`: Start from specific step
- `--stop-after <name|number>`: Stop after specific step
- `-l|--list`: List steps with descriptions and progress
- `-t|--tests-only`: Skip setup, run only tests
- `--reset`: Clear progress and start fresh

#### 3. Idempotency Patterns

```bash
# Check before create
aws eks describe-cluster --name "$CLUSTER_NAME" &>/dev/null && log_info "Exists" || create_cluster

# Suppress expected errors
kubectl create namespace "$NS" 2>/dev/null || true

# Safe deletions
kubectl delete pod "$POD" --ignore-not-found
```

#### 4. Logging (from test-lib.sh)

```bash
log_info "Message"    # Green [INFO]
log_step "Step X"     # Blue [STEP]
log_warn "Warning"    # Yellow [WARN]
log_error "Error"     # Red [ERROR]
log_pass "Passed"     # Green [PASS]
log_fail "Failed"     # Red [FAIL]
```

---

## File Organization

```
scripts/
├── setup-*.sh              # Infrastructure setup
├── deploy-*.sh             # Service deployment
├── create-*.sh             # Resource creation
├── add-*-to-mesh.sh        # Mesh integration
├── cleanup*.sh             # Resource cleanup
└── test/
    ├── test-lib.sh         # SHARED LIBRARY
    ├── test-scenario-*.sh  # Scenario test runners
    └── test-*-config.sh.example  # Config templates
```

**Config conventions:**
- Config files use `.sh` extension (sourced)
- Templates use `.sh.example` suffix
- All variables are `export`ed

---

## Documentation Synchronization

### The Three-Way Contract

1. **Markdown Guide** (`Readme-scenario-X.md`): User-facing instructions
2. **Test Script** (`test-scenario-X.sh`): Automated validation
3. **Setup Scripts** (`scripts/*.sh`): Reusable automation

**Rule**: Change in one = change in all related files.

### Markdown Structure

```markdown
## Part N: Section Title

### Step N.X: Action Description

Brief explanation.

\`\`\`bash
actual-command --with-flags
\`\`\`
```

---

## Test Framework

### Recording Results

```bash
if echo "$result" | grep -q "expected"; then
    record_test "Test Name" "expected" "actual" "PASS"
else
    record_test "Test Name" "expected" "actual" "FAIL"
fi
```

### Helper Functions (from test-lib.sh)

```bash
# Wait helpers
wait_for_pods "app=myapp" "namespace" 120
wait_for_deployment "name" "namespace" 120

# Test helpers
test_http_endpoint "http://url" 200
test_http_contains "http://url" "expected"
test_pods_running "app=myapp" "namespace" 2
```

### Pre-flight Checks

```bash
check_setup_complete || exit 1
check_ecs_setup_complete || exit 1
```

---

## Common Patterns

### AWS Resource Checks

```bash
aws eks describe-cluster --name "$NAME" &>/dev/null      # EKS exists?
aws iam get-role --role-name "$ROLE" &>/dev/null         # IAM role exists?
```

### Kubernetes Waits

```bash
kubectl rollout status deployment/"$NAME" -n "$NS" --timeout=300s
kubectl wait --for=condition=ready pod -l app="$APP" -n "$NS" --timeout=300s
```

### Error Recovery

```bash
if ! some_operation; then
    log_error "Failed. Retry with: $0 -c $CONFIG_FILE -s $CURRENT_STEP"
    exit 1
fi
```

---

## Anti-Patterns

**DO NOT:**
- Hardcode values (use config variables)
- Skip existence checks
- Use silent failures
- Forget step tracking
- Break the three-way contract
- Use `set -e` globally (breaks step resumption)
- Assume fresh environment

**DO:**
- Read existing code first
- Test incrementally
- Provide context in logs
- Warn before destructive operations

---

## Debugging

**When a script fails:**
1. Check step status: `./script.sh -l`
2. View progress: `cat .workshop-progress-scN`
3. Verbose mode: `bash -x ./script.sh`
4. Resume: `./script.sh -c config.sh -s failed_step`

**Debug specific steps with `--stop-after`:**
```bash
./scripts/test/test-scenario-1.sh -c config.sh --stop-after istio_install
./scripts/test/test-scenario-1.sh -c config.sh -s 3 --stop-after 7
```

**Progress files:** `.workshop-progress-sc1` through `.workshop-progress-sc4`

---

## Quality Checklist

Before completing any script change:
- [ ] Config file support (`-c`) works
- [ ] Step system tracks progress correctly
- [ ] Script is idempotent (safe to re-run)
- [ ] Error messages include recovery instructions
- [ ] Related Markdown documentation updated
- [ ] Test script validates the same flow

---

## Status Tracking (STATUS.md)

**Update STATUS.md when:**
1. **After tests**: Record results in scenario section
2. **Issues found**: Add to "Open Issues" with severity
3. **Issues fixed**: Move to "Resolved Issues"
4. **Version changes**: Update "Current Environment"

**Issue format:**
```markdown
| ID | Severity | Scenarios | Component | Description | Workaround | Reported |
| ECS-001 | High | 2,3 | script.sh | Description | Workaround | 2026-01-15 |
```

**Severity:** Critical (blocks, no workaround) > High (broken, has workaround) > Medium (degraded) > Low (cosmetic)

---

## Communication Style

When explaining changes or asking questions:
1. Be specific about which files and line numbers
2. Reference existing patterns: "Following the pattern in test-lib.sh:XXX"
3. Explain the "why" not just the "what"
4. Provide complete, runnable examples
5. Note any documentation that needs updating
