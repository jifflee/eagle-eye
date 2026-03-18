#!/bin/bash
# pr-creation-validate-runner.sh
# Runs local validation on a newly created PR and reports merge status
#
# Usage:
#   ./scripts/pr-creation-validate-runner.sh <PR_NUMBER> [OPTIONS]
#
# Options:
#   --skip-issue-update    Don't update the linked issue on failure
#   --check-ci             Also check CI status (waits for CI completion)
#   --ci-wait <sec>        Initial wait before CI check (default: 30)
#   --ci-timeout <sec>     Max time to wait for CI (default: 300)
#   --verbose              Show detailed output
#   --dry-run              Show what would be done without executing
#
# This script:
#   1. Runs pr-validate.sh for PR-specific checks
#   2. Runs validate-local.sh for code quality checks (optional)
#   3. Reports pass/fail status
#   4. On failure: updates linked issue with details and remediation
#
# Exit Codes:
#   0 - All validation passed, PR is mergeable
#   1 - Validation failed, issue updated with failures
#   2 - Error (invalid PR, script failure)
#
# Issue: #371 - Add PR creation hook to run local validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source common utilities if available
if [[ -f "$SCRIPT_DIR/lib/common.sh" ]]; then
  # shellcheck source=lib/common.sh
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >&2; }
  log_warn() { echo "[WARN] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >&2; }
  log_error() { echo "[ERROR] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >&2; }
  log_success() { echo "[OK] $(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >&2; }
  die() { log_error "$*"; exit 2; }
fi

# Defaults
PR_NUMBER=""
SKIP_ISSUE_UPDATE=false
CHECK_CI=false
CI_WAIT=30
CI_TIMEOUT=300
VERBOSE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-issue-update)
      SKIP_ISSUE_UPDATE=true
      shift
      ;;
    --check-ci)
      CHECK_CI=true
      shift
      ;;
    --ci-wait)
      CI_WAIT="$2"
      shift 2
      ;;
    --ci-timeout)
      CI_TIMEOUT="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        log_error "Unknown argument: $1"
        exit 2
      fi
      shift
      ;;
  esac
done

# Validate PR number
if [[ -z "$PR_NUMBER" ]]; then
  die "PR number required. Usage: $0 <PR_NUMBER>"
fi

log_info "Starting validation for PR #${PR_NUMBER}"

# Step 1: Run PR validation checks
log_info "Running PR validation checks..."

PR_VALIDATE_OUTPUT=""
PR_VALIDATE_EXIT=0

if [[ -x "$SCRIPT_DIR/pr-validate.sh" ]]; then
  PR_VALIDATE_OUTPUT=$("$SCRIPT_DIR/pr-validate.sh" "$PR_NUMBER" --json 2>&1) || PR_VALIDATE_EXIT=$?
else
  log_warn "pr-validate.sh not found, skipping PR-specific checks"
  PR_VALIDATE_OUTPUT='{"status":"skipped","summary":"pr-validate.sh not available"}'
fi

if $VERBOSE; then
  log_info "PR validation output: $PR_VALIDATE_OUTPUT"
fi

# Step 2: Run local validation (code quality checks)
log_info "Running local validation checks..."

LOCAL_VALIDATE_OUTPUT=""
LOCAL_VALIDATE_EXIT=0

if [[ -x "$SCRIPT_DIR/validate-local.sh" ]]; then
  # Use quick mode for faster feedback
  LOCAL_VALIDATE_OUTPUT=$("$SCRIPT_DIR/validate-local.sh" --quick 2>&1) || LOCAL_VALIDATE_EXIT=$?
else
  log_warn "validate-local.sh not found, skipping local validation"
fi

if $VERBOSE; then
  log_info "Local validation exit code: $LOCAL_VALIDATE_EXIT"
fi

# Step 3: Aggregate results
log_info "Aggregating validation results..."

# Parse PR validation status
pr_status=$(echo "$PR_VALIDATE_OUTPUT" | jq -r '.status // "error"' 2>/dev/null || echo "error")
pr_summary=$(echo "$PR_VALIDATE_OUTPUT" | jq -r '.summary // "Unknown"' 2>/dev/null || echo "Unknown")
pr_failures=$(echo "$PR_VALIDATE_OUTPUT" | jq -r '.failures // []' 2>/dev/null || echo "[]")
pr_remediations=$(echo "$PR_VALIDATE_OUTPUT" | jq -r '.remediations // []' 2>/dev/null || echo "[]")
linked_issue=$(echo "$PR_VALIDATE_OUTPUT" | jq -r '.linked_issue // null' 2>/dev/null || echo "null")

# Determine overall status
overall_status="mergeable"
overall_failures='[]'
overall_remediations='[]'

if [[ "$pr_status" == "needs_fixes" || "$pr_status" == "error" ]]; then
  overall_status="needs_fixes"
  overall_failures="$pr_failures"
  overall_remediations="$pr_remediations"
fi

if [[ "$LOCAL_VALIDATE_EXIT" -ne 0 ]]; then
  overall_status="needs_fixes"
  # Add local validation failure
  local_failure='{"name":"local-validation","description":"Local validation checks failed"}'
  local_remediation='{"check":"local-validation","suggestion":"Run ./scripts/validate-local.sh to see detailed failures"}'
  overall_failures=$(echo "$overall_failures" | jq --argjson f "$local_failure" '. + [$f]')
  overall_remediations=$(echo "$overall_remediations" | jq --argjson r "$local_remediation" '. + [$r]')
fi

# Step 3.5: Check CI status (if requested)
CI_STATUS_RESULT=""
if $CHECK_CI && [[ -x "$SCRIPT_DIR/check-pr-ci-status.sh" ]]; then
  log_info "Checking CI status (wait: ${CI_WAIT}s, timeout: ${CI_TIMEOUT}s)..."

  CI_STATUS_RESULT=$("$SCRIPT_DIR/check-pr-ci-status.sh" "$PR_NUMBER" \
    --wait "$CI_WAIT" \
    --timeout "$CI_TIMEOUT" \
    --json 2>&1) || true

  ci_check_status=$(echo "$CI_STATUS_RESULT" | jq -r '.status // "error"' 2>/dev/null || echo "error")

  if $VERBOSE; then
    log_info "CI status result: $CI_STATUS_RESULT"
  fi

  case "$ci_check_status" in
    mergeable|no_checks)
      log_success "CI checks passed"
      ;;
    pending)
      log_warn "CI checks still pending after timeout"
      ci_failure='{"name":"ci-pending","description":"CI checks are still running after timeout"}'
      ci_remediation='{"check":"ci-pending","suggestion":"CI is still running. Check status: gh pr checks '"$PR_NUMBER"'"}'
      overall_failures=$(echo "$overall_failures" | jq --argjson f "$ci_failure" '. + [$f]')
      overall_remediations=$(echo "$overall_remediations" | jq --argjson r "$ci_remediation" '. + [$r]')
      ;;
    needs_review)
      overall_status="needs_fixes"
      failed_checks=$(echo "$CI_STATUS_RESULT" | jq -r '.checks.failed_checks // "unknown"' 2>/dev/null || echo "unknown")
      ci_failure='{"name":"ci-failed","description":"CI checks failed: '"$failed_checks"'"}'
      ci_remediation='{"check":"ci-failed","suggestion":"Fix failing CI checks. View details: gh pr checks '"$PR_NUMBER"' --web"}'
      overall_failures=$(echo "$overall_failures" | jq --argjson f "$ci_failure" '. + [$f]')
      overall_remediations=$(echo "$overall_remediations" | jq --argjson r "$ci_remediation" '. + [$r]')
      log_warn "CI checks failed: $failed_checks"
      ;;
    *)
      log_warn "Could not determine CI status"
      ;;
  esac
fi

# Step 4: Update CI check labels
log_info "Updating CI check labels..."

LABEL_SCRIPT="${SCRIPT_DIR}/update-ci-check-labels.sh"
if [[ -x "${LABEL_SCRIPT}" && ! $DRY_RUN ]]; then
  if [[ "$overall_status" == "needs_fixes" ]]; then
    "${LABEL_SCRIPT}" "${PR_NUMBER}" fail 2>/dev/null || log_warn "Failed to update CHECK_FAIL label"
  else
    "${LABEL_SCRIPT}" "${PR_NUMBER}" pass 2>/dev/null || log_warn "Failed to update CHECK_PASS label"
  fi
else
  log_warn "Label update script not found or dry-run mode, skipping label update"
fi

# Step 5: Report status
log_info "Validation complete. Status: $overall_status"

# Build final result
ci_status_json="${CI_STATUS_RESULT:-null}"
if [[ "$ci_status_json" == "" || "$ci_status_json" == "null" ]]; then
  ci_status_json="null"
fi

result=$(jq -n \
  --arg pr_number "$PR_NUMBER" \
  --arg status "$overall_status" \
  --argjson linked_issue "$linked_issue" \
  --argjson failures "$overall_failures" \
  --argjson remediations "$overall_remediations" \
  --arg summary "$pr_summary" \
  --argjson ci_status "$ci_status_json" \
  '{
    pr_number: ($pr_number | tonumber),
    status: $status,
    linked_issue: $linked_issue,
    failures: $failures,
    remediations: $remediations,
    summary: $summary,
    ci_status: $ci_status,
    timestamp: (now | todate)
  }')

if $VERBOSE; then
  echo "$result" | jq .
fi

# Step 6: Update linked issue if validation failed
if [[ "$overall_status" == "needs_fixes" && "$linked_issue" != "null" && "$SKIP_ISSUE_UPDATE" == "false" ]]; then
  log_info "Validation failed. Updating issue #${linked_issue}..."

  # Build issue comment
  failure_count=$(echo "$overall_failures" | jq 'length')

  # Format failures as markdown list
  failures_md=$(echo "$overall_failures" | jq -r '.[] | "- **\(.name)**: \(.description)"')

  # Format remediations as markdown list
  remediations_md=$(echo "$overall_remediations" | jq -r '.[] | "- \(.check): \(.suggestion)"')

  comment_body="## PR Validation Failed

PR #${PR_NUMBER} has ${failure_count} validation failure(s) that need to be resolved before merging.

### Failing Checks

${failures_md}

### How to Fix

${remediations_md}

---
*This comment was automatically generated by the PR validation hook.*
*Run \`./scripts/pr-validate.sh ${PR_NUMBER} --human\` for detailed output.*"

  if $DRY_RUN; then
    log_info "[DRY RUN] Would post comment to issue #${linked_issue}:"
    echo "$comment_body"
  else
    # Post comment to issue
    if gh issue comment "$linked_issue" --body "$comment_body" 2>/dev/null; then
      log_success "Issue #${linked_issue} updated with validation failures"
    else
      log_warn "Failed to update issue #${linked_issue}"
    fi

    # Add needs-fixes label if not already present
    if gh issue edit "$linked_issue" --add-label "needs-fixes" 2>/dev/null; then
      log_info "Added 'needs-fixes' label to issue #${linked_issue}"
    fi
  fi
fi

# Step 7: Log to action audit (if available)
if [[ -x "$SCRIPT_DIR/action-log.sh" ]]; then
  action_status="success"
  [[ "$overall_status" != "mergeable" ]] && action_status="failure"

  "$SCRIPT_DIR/action-log.sh" \
    --source-type hook \
    --source-name "pr-creation-validate" \
    --category "github" \
    --operation "pr.validate" \
    --command "pr-creation-validate-runner.sh $PR_NUMBER" \
    --status "$action_status" \
    >/dev/null 2>&1 || true
fi

# Output final result to stdout
echo "$result"

# Exit with appropriate code
case "$overall_status" in
  mergeable) exit 0 ;;
  needs_fixes) exit 1 ;;
  *) exit 2 ;;
esac
