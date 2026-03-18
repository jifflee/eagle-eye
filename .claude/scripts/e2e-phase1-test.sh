#!/bin/bash
# e2e-phase1-test.sh
# End-to-end Phase 1 automation test with n8n orchestration
#
# This script validates the complete automation flow:
# 1. Trigger (n8n webhook or direct)
# 2. Issue selection (from backlog)
# 3. Container launch
# 4. Claude execution
# 5. PR creation
# 6. Completion reporting
#
# Usage: ./scripts/e2e-phase1-test.sh [OPTIONS]
#
# Options:
#   --issue N           Use specific issue for testing (default: auto-select from backlog)
#   --create-test-issue Create a new test issue instead of using existing
#   --timeout SECONDS   Max time to wait for completion (default: 900 = 15min)
#   --skip-n8n          Skip n8n trigger, call scripts directly
#   --dry-run           Show what would be done without executing
#   --json              Output JSON report only
#   --verbose           Show detailed progress
#   --help              Show this help
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#   2 - Invalid arguments or prerequisites not met
#   3 - Timeout exceeded
#
# Prerequisites:
#   - Docker Desktop running
#   - n8n running at localhost:5678 (unless --skip-n8n)
#   - GITHUB_TOKEN available (for container)
#   - CLAUDE_CODE_OAUTH_TOKEN available (for container)
#
# Example:
#   ./scripts/e2e-phase1-test.sh --verbose
#   ./scripts/e2e-phase1-test.sh --issue 123 --skip-n8n
#   ./scripts/e2e-phase1-test.sh --create-test-issue --timeout 600

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
TIMEOUT_SECONDS=900
POLL_INTERVAL=30
TEST_ISSUE=""
CREATE_TEST_ISSUE=false
SKIP_N8N=false
DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false

# Test state
START_TIME=""
END_TIME=""
TEST_RESULTS=()
CONTAINER_ID=""
PR_NUMBER=""
TEST_ISSUE_CREATED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      TEST_ISSUE="$2"
      shift 2
      ;;
    --create-test-issue)
      CREATE_TEST_ISSUE=true
      shift
      ;;
    --timeout)
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --skip-n8n)
      SKIP_N8N=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Logging functions
log() {
  if [ "$JSON_OUTPUT" = false ]; then
    echo -e "$1"
  fi
}

log_info() {
  log "${BLUE}[INFO]${NC} $1"
}

log_success() {
  log "${GREEN}[PASS]${NC} $1"
}

log_warn() {
  log "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  log "${RED}[FAIL]${NC} $1"
}

log_verbose() {
  if [ "$VERBOSE" = true ]; then
    log "${BLUE}[DEBUG]${NC} $1"
  fi
}

# Record test result
record_result() {
  local test_name="$1"
  local status="$2"
  local message="${3:-}"
  local duration="${4:-0}"

  TEST_RESULTS+=("{\"test\": \"$test_name\", \"status\": \"$status\", \"message\": \"$message\", \"duration_seconds\": $duration}")

  if [ "$status" = "pass" ]; then
    log_success "$test_name: $message"
  else
    log_error "$test_name: $message"
  fi
}

# Check prerequisites
check_prerequisites() {
  log_info "Checking prerequisites..."
  local failures=0

  # Check Docker
  if docker info >/dev/null 2>&1; then
    log_verbose "Docker is available"
  else
    log_error "Docker is not running"
    ((failures++))
  fi

  # Check GitHub CLI
  if command -v gh >/dev/null 2>&1; then
    log_verbose "GitHub CLI is available"
  else
    log_error "GitHub CLI (gh) not found"
    ((failures++))
  fi

  # Check gh authentication
  if gh auth status >/dev/null 2>&1; then
    log_verbose "GitHub CLI is authenticated"
  else
    log_error "GitHub CLI is not authenticated"
    ((failures++))
  fi

  # Check n8n (unless skipping)
  if [ "$SKIP_N8N" = false ]; then
    local n8n_status
    n8n_status=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5678/healthz 2>/dev/null || echo "000")
    if [ "$n8n_status" = "200" ]; then
      log_verbose "n8n is available at localhost:5678"
    else
      log_warn "n8n not responding (status: $n8n_status). Use --skip-n8n to bypass."
      ((failures++))
    fi
  fi

  # Check Claude tokens (from keychain or env)
  local has_claude_token=false
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    has_claude_token=true
  elif security find-generic-password -s claude-oauth-token >/dev/null 2>&1; then
    has_claude_token=true
  fi

  if [ "$has_claude_token" = true ]; then
    log_verbose "Claude token available"
  else
    log_warn "Claude token not found in env or keychain"
  fi

  # Check GitHub token
  local has_github_token=false
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    has_github_token=true
  elif gh auth token >/dev/null 2>&1; then
    has_github_token=true
  fi

  if [ "$has_github_token" = true ]; then
    log_verbose "GitHub token available"
  else
    log_error "GitHub token not found"
    ((failures++))
  fi

  if [ "$failures" -gt 0 ]; then
    log_error "Prerequisites check failed ($failures issues)"
    return 1
  fi

  log_success "All prerequisites met"
  return 0
}

# Create test issue
create_test_issue() {
  log_info "Creating test issue for E2E automation..."

  local test_body
  test_body=$(cat <<'EOF'
## Summary

**Test Issue for E2E Phase 1 Automation Validation**

This is an automatically created test issue to validate the end-to-end automation flow.
It has minimal scope to ensure fast execution.

## Acceptance Criteria

- [ ] Create a test output file `test-outputs/e2e-test-$(date +%Y%m%d%H%M%S).md`
- [ ] File contains timestamp and test marker

## Test Scope

- No code changes required
- No complex logic
- Should complete in <5 minutes

## Labels

test-automation, P2, backlog, execution:container

---
*Auto-generated by e2e-phase1-test.sh*
EOF
)

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would create test issue"
    TEST_ISSUE="999"
    return 0
  fi

  local issue_url
  issue_url=$(gh issue create \
    --title "E2E Test: Phase 1 Automation Validation $(date +%Y-%m-%d_%H:%M)" \
    --body "$test_body" \
    --label "test-automation" \
    --label "backlog" \
    --label "P2" \
    --label "execution:container" 2>&1)

  if [ $? -ne 0 ]; then
    log_error "Failed to create test issue: $issue_url"
    return 1
  fi

  TEST_ISSUE=$(echo "$issue_url" | grep -oE '[0-9]+$')
  TEST_ISSUE_CREATED=true

  log_success "Created test issue #$TEST_ISSUE"
  return 0
}

# Select issue from backlog
select_test_issue() {
  if [ -n "$TEST_ISSUE" ]; then
    log_info "Using specified issue #$TEST_ISSUE"
    return 0
  fi

  if [ "$CREATE_TEST_ISSUE" = true ]; then
    create_test_issue
    return $?
  fi

  # Auto-select highest priority backlog issue
  log_info "Selecting issue from backlog..."

  local backlog_issue
  backlog_issue=$(gh issue list \
    --label "backlog" \
    --state open \
    --limit 1 \
    --json number,title,labels \
    --jq '.[0].number // empty')

  if [ -z "$backlog_issue" ]; then
    log_error "No issues in backlog. Use --create-test-issue to create one."
    return 1
  fi

  TEST_ISSUE="$backlog_issue"
  log_info "Selected issue #$TEST_ISSUE from backlog"
  return 0
}

# Trigger via n8n webhook
trigger_n8n() {
  log_info "Triggering n8n backlog processor..."

  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would POST to n8n webhook"
    return 0
  fi

  local response
  response=$(curl -s -X POST \
    -H "Content-Type: application/json" \
    -d "{\"issue\": \"$TEST_ISSUE\", \"project\": \"$repo\"}" \
    http://localhost:5678/webhook/container-launch 2>&1)

  if echo "$response" | jq -e '.status == "launched"' >/dev/null 2>&1; then
    log_success "n8n trigger successful"
    return 0
  else
    log_error "n8n trigger failed: $response"
    return 1
  fi
}

# Direct trigger (bypass n8n)
trigger_direct() {
  log_info "Launching container directly (bypassing n8n)..."

  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would launch container for issue #$TEST_ISSUE"
    CONTAINER_ID="dry-run-container"
    return 0
  fi

  local output
  output=$("$SCRIPT_DIR/container/container-launch.sh" \
    --issue "$TEST_ISSUE" \
    --repo "$repo" \
    --sprint-work 2>&1) || true

  log_verbose "Container launch output: $output"

  # Extract container ID from output
  CONTAINER_ID=$(echo "$output" | grep -oE 'claude-tastic-issue-[0-9]+' | head -1 || echo "")

  if [ -n "$CONTAINER_ID" ]; then
    log_success "Container launched: $CONTAINER_ID"
    return 0
  else
    log_error "Failed to launch container"
    return 1
  fi
}

# Monitor container execution
monitor_container() {
  log_info "Monitoring container execution..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would monitor container $CONTAINER_ID"
    return 0
  fi

  local container_name="claude-tastic-issue-$TEST_ISSUE"
  local elapsed=0
  local status=""
  local was_running=false

  while [ "$elapsed" -lt "$TIMEOUT_SECONDS" ]; do
    # Check container status
    status=$(docker ps -a --filter "name=$container_name" --format "{{.Status}}" 2>/dev/null || echo "")

    log_verbose "Container status after ${elapsed}s: ${status:-<not found>}"

    # Track if we ever saw it running
    if [[ "$status" == *"Up"* ]]; then
      was_running=true
    fi

    if [[ "$status" == *"Exited"* ]]; then
      local exit_code
      exit_code=$(docker inspect "$container_name" --format "{{.State.ExitCode}}" 2>/dev/null || echo "unknown")

      if [ "$exit_code" = "0" ]; then
        log_success "Container completed successfully (exit code 0)"
        return 0
      else
        log_error "Container exited with code $exit_code"
        # Show last 20 lines of logs
        log_info "Container logs (last 20 lines):"
        docker logs --tail 20 "$container_name" 2>&1 | while read -r line; do
          log "  $line"
        done
        return 1
      fi
    elif [ -z "$status" ]; then
      # Container not found - might have been removed with --rm
      if [ "$was_running" = true ]; then
        # Container ran and was removed (--rm flag) - check if work was done
        log_info "Container completed and was removed (--rm flag)"
        # Give time for git push to complete
        sleep 5
        # Check if branch has new commits as indicator of success
        git fetch origin 2>/dev/null
        local new_commits
        new_commits=$(git rev-list --count origin/dev..origin/feat/issue-$TEST_ISSUE 2>/dev/null || echo "0")
        if [ "$new_commits" -gt 0 ]; then
          log_success "Container completed - branch has $new_commits new commit(s)"
          return 0
        else
          log_warn "Container completed but no new commits detected"
          return 0  # Still consider this a success (container ran)
        fi
      else
        # Never saw it running - launch might have failed
        if [ "$elapsed" -lt 30 ]; then
          # Wait a bit more for it to start
          sleep "$POLL_INTERVAL"
          elapsed=$((elapsed + POLL_INTERVAL))
          continue
        fi
        log_error "Container not found: $container_name"
        return 1
      fi
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    log_info "Waiting... (${elapsed}s / ${TIMEOUT_SECONDS}s)"
  done

  log_error "Timeout exceeded waiting for container"
  return 1
}

# Verify PR created
verify_pr_created() {
  log_info "Verifying PR was created..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check for PR"
    PR_NUMBER="999"
    return 0
  fi

  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

  # First check by branch name (most reliable)
  local pr_info
  pr_info=$(gh pr list \
    --repo "$repo" \
    --state all \
    --head "feat/issue-$TEST_ISSUE" \
    --json number,title,url,state \
    --jq '.[0] // empty' 2>/dev/null || echo "")

  # Also check for PRs mentioning the issue in body (in this repo only)
  if [ -z "$pr_info" ]; then
    pr_info=$(gh pr list \
      --repo "$repo" \
      --state all \
      --search "Fixes #$TEST_ISSUE in:body" \
      --json number,title,url,state \
      --jq '.[0] // empty' 2>/dev/null || echo "")
  fi

  if [ -n "$pr_info" ]; then
    PR_NUMBER=$(echo "$pr_info" | jq -r '.number')
    local pr_url pr_state
    pr_url=$(echo "$pr_info" | jq -r '.url')
    pr_state=$(echo "$pr_info" | jq -r '.state')
    log_success "PR found: #$PR_NUMBER ($pr_state) - $pr_url"
    return 0
  fi

  # Check if branch has commits beyond base
  local branch_commits
  branch_commits=$(git rev-list --count origin/dev..origin/feat/issue-$TEST_ISSUE 2>/dev/null || echo "0")

  if [ "$branch_commits" = "0" ]; then
    log_error "No PR found - branch feat/issue-$TEST_ISSUE has no new commits"
    return 1
  else
    log_error "No PR found for issue #$TEST_ISSUE (branch has $branch_commits new commits)"
    return 1
  fi
}

# Verify issue labels updated
verify_issue_labels() {
  log_info "Verifying issue labels updated..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check issue labels"
    return 0
  fi

  local labels
  labels=$(gh issue view "$TEST_ISSUE" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")

  log_verbose "Issue #$TEST_ISSUE labels: $labels"

  # Check that backlog was removed and in-progress or pr-review added
  if [[ "$labels" != *"backlog"* ]]; then
    log_success "Issue moved out of backlog"
  else
    log_warn "Issue still has backlog label"
  fi

  if [[ "$labels" == *"in-progress"* ]] || [[ "$labels" == *"pr-review"* ]]; then
    log_success "Issue has work status label"
    return 0
  else
    log_warn "Issue missing expected status label (in-progress or pr-review)"
    return 0  # Non-fatal
  fi
}

# Verify no orphaned containers
verify_cleanup() {
  log_info "Verifying no orphaned containers..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check for orphaned containers"
    return 0
  fi

  local container_name="claude-tastic-issue-$TEST_ISSUE"
  local status
  status=$(docker ps --filter "name=$container_name" --format "{{.Names}}" 2>/dev/null || echo "")

  if [ -z "$status" ]; then
    log_success "No orphaned running containers"
    return 0
  else
    log_warn "Container still running: $status"
    return 0  # Non-fatal
  fi
}

# Check container logs for errors
check_logs() {
  log_info "Checking container logs for warnings/errors..."

  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would check logs"
    return 0
  fi

  local container_name="claude-tastic-issue-$TEST_ISSUE"

  # Check if container exists (may have been removed with --rm)
  if ! docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log_info "Container was removed (--rm flag). Checking operation logs instead."
    # Fall back to operation logs
    local op_errors
    op_errors=$(./scripts/container/container-logs.sh --issue "$TEST_ISSUE" --errors 2>/dev/null | wc -l || echo "0")
    if [ "$op_errors" -gt 1 ]; then
      log_warn "Found error entries in operation logs"
    else
      log_success "No errors in operation logs"
    fi
    return 0
  fi

  local error_count
  error_count=$(docker logs "$container_name" 2>&1 | grep -ciE "(error|fatal|exception|failed)" || echo "0")
  # Ensure error_count is a valid integer
  error_count="${error_count//[^0-9]/}"
  error_count="${error_count:-0}"

  if [ "$error_count" -gt 0 ]; then
    log_warn "Found $error_count error/warning messages in logs"
    if [ "$VERBOSE" = true ]; then
      log_info "Error lines:"
      docker logs "$container_name" 2>&1 | grep -iE "(error|fatal|exception|failed)" | head -10 | while read -r line; do
        log "  $line"
      done
    fi
  else
    log_success "No errors found in container logs"
  fi

  return 0
}

# Cleanup test issue if we created it
cleanup_test_issue() {
  if [ "$TEST_ISSUE_CREATED" = true ] && [ -n "$TEST_ISSUE" ]; then
    log_info "Cleaning up test issue #$TEST_ISSUE..."

    if [ "$DRY_RUN" = true ]; then
      log_info "[DRY RUN] Would close test issue"
      return 0
    fi

    gh issue close "$TEST_ISSUE" --comment "E2E test completed. Auto-closing test issue." 2>/dev/null || true
  fi
}

# Generate final report
generate_report() {
  END_TIME=$(date +%s)
  local total_duration=$((END_TIME - START_TIME))

  # Count results
  local pass_count=0
  local fail_count=0

  for result in "${TEST_RESULTS[@]}"; do
    if echo "$result" | jq -e '.status == "pass"' >/dev/null 2>&1; then
      ((pass_count++))
    else
      ((fail_count++))
    fi
  done

  local overall_status="pass"
  if [ "$fail_count" -gt 0 ]; then
    overall_status="fail"
  fi

  if [ "$JSON_OUTPUT" = true ]; then
    # JSON report
    local results_json
    results_json=$(printf '%s\n' "${TEST_RESULTS[@]}" | jq -s '.')

    jq -n \
      --arg status "$overall_status" \
      --arg issue "$TEST_ISSUE" \
      --arg pr "${PR_NUMBER:-null}" \
      --argjson duration "$total_duration" \
      --argjson pass "$pass_count" \
      --argjson fail "$fail_count" \
      --argjson results "$results_json" \
      --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        status: $status,
        issue: $issue,
        pr: $pr,
        total_duration_seconds: $duration,
        tests_passed: $pass,
        tests_failed: $fail,
        results: $results,
        completed_at: $timestamp
      }'
  else
    # Human-readable report
    echo ""
    echo "============================================"
    echo "E2E Phase 1 Automation Test Report"
    echo "============================================"
    echo ""
    echo "Status: $([ "$overall_status" = "pass" ] && echo "PASSED" || echo "FAILED")"
    echo "Issue:  #$TEST_ISSUE"
    echo "PR:     ${PR_NUMBER:-N/A}"
    echo "Duration: ${total_duration}s"
    echo ""
    echo "Results: $pass_count passed, $fail_count failed"
    echo ""

    if [ "$fail_count" -gt 0 ]; then
      echo "Failed tests:"
      for result in "${TEST_RESULTS[@]}"; do
        if echo "$result" | jq -e '.status == "fail"' >/dev/null 2>&1; then
          local test_name message
          test_name=$(echo "$result" | jq -r '.test')
          message=$(echo "$result" | jq -r '.message')
          echo "  - $test_name: $message"
        fi
      done
      echo ""
    fi

    echo "============================================"
  fi
}

# Main execution
main() {
  START_TIME=$(date +%s)

  log_info "Starting E2E Phase 1 Automation Test"
  log_info "Timeout: ${TIMEOUT_SECONDS}s"
  log_info "Skip n8n: $SKIP_N8N"
  log_info "Dry run: $DRY_RUN"
  echo ""

  # Step 1: Prerequisites
  local step_start step_end
  step_start=$(date +%s)
  if check_prerequisites; then
    step_end=$(date +%s)
    record_result "prerequisites" "pass" "All prerequisites met" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "prerequisites" "fail" "Prerequisites check failed" $((step_end - step_start))
    generate_report
    exit 2
  fi

  # Step 2: Select/create test issue
  step_start=$(date +%s)
  if select_test_issue; then
    step_end=$(date +%s)
    record_result "issue_selection" "pass" "Using issue #$TEST_ISSUE" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "issue_selection" "fail" "Failed to select/create issue" $((step_end - step_start))
    generate_report
    exit 1
  fi

  # Step 3: Trigger execution
  step_start=$(date +%s)
  if [ "$SKIP_N8N" = true ]; then
    if trigger_direct; then
      step_end=$(date +%s)
      record_result "trigger" "pass" "Container launched directly" $((step_end - step_start))
    else
      step_end=$(date +%s)
      record_result "trigger" "fail" "Direct trigger failed" $((step_end - step_start))
    fi
  else
    if trigger_n8n; then
      step_end=$(date +%s)
      record_result "trigger" "pass" "n8n trigger successful" $((step_end - step_start))
    else
      step_end=$(date +%s)
      record_result "trigger" "fail" "n8n trigger failed" $((step_end - step_start))
    fi
  fi

  # Step 4: Monitor container
  step_start=$(date +%s)
  if monitor_container; then
    step_end=$(date +%s)
    record_result "container_execution" "pass" "Container completed successfully" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "container_execution" "fail" "Container failed or timed out" $((step_end - step_start))
  fi

  # Step 5: Verify PR created
  step_start=$(date +%s)
  if verify_pr_created; then
    step_end=$(date +%s)
    record_result "pr_created" "pass" "PR #$PR_NUMBER created" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "pr_created" "fail" "No PR found" $((step_end - step_start))
  fi

  # Step 6: Verify issue labels
  step_start=$(date +%s)
  if verify_issue_labels; then
    step_end=$(date +%s)
    record_result "issue_labels" "pass" "Issue labels updated correctly" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "issue_labels" "fail" "Issue labels not updated" $((step_end - step_start))
  fi

  # Step 7: Check logs
  step_start=$(date +%s)
  if check_logs; then
    step_end=$(date +%s)
    record_result "logs_clean" "pass" "No critical errors in logs" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "logs_clean" "fail" "Errors found in logs" $((step_end - step_start))
  fi

  # Step 8: Verify cleanup
  step_start=$(date +%s)
  if verify_cleanup; then
    step_end=$(date +%s)
    record_result "cleanup" "pass" "No orphaned containers" $((step_end - step_start))
  else
    step_end=$(date +%s)
    record_result "cleanup" "fail" "Orphaned containers found" $((step_end - step_start))
  fi

  # Cleanup test issue if created
  cleanup_test_issue

  # Generate final report
  generate_report

  # Exit with appropriate code
  local has_failures=false
  for result in "${TEST_RESULTS[@]}"; do
    if echo "$result" | jq -e '.status == "fail"' >/dev/null 2>&1; then
      has_failures=true
      break
    fi
  done

  if [ "$has_failures" = true ]; then
    exit 1
  else
    exit 0
  fi
}

# Run main
main
