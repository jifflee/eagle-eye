#!/bin/bash
set -euo pipefail
# pr-validate.sh
# Validates PR through script-based checks (not GitHub Actions)
#
# Usage:
#   ./scripts/pr-validate.sh <PR_NUMBER> [OPTIONS]
#
# Options:
#   --json            Output JSON format (default)
#   --human           Output human-readable format
#   --checks-only     Run checks without merge evaluation
#   --skip-ci         Skip CI status check (use script checks only)
#   --quick           Quick validation (essential checks only)
#   --verbose         Show detailed check output
#
# Exit Codes:
#   0 - All checks passed, PR is mergeable
#   1 - Some checks failed, PR needs fixes
#   2 - PR is pending (checks in progress)
#   3 - Error (invalid PR, API failure)
#
# Output (JSON):
#   {
#     "pr_number": N,
#     "status": "mergeable|needs_fixes|pending|error",
#     "linked_issue": N,
#     "checks": { ... },
#     "failures": [ ... ],
#     "remediations": [ ... ],
#     "summary": "human readable summary"
#   }

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
PR_NUMBER=""
OUTPUT_FORMAT="json"
CHECKS_ONLY=false
SKIP_CI=false
QUICK_MODE=false
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --json)
      OUTPUT_FORMAT="json"
      shift
      ;;
    --human)
      OUTPUT_FORMAT="human"
      shift
      ;;
    --checks-only)
      CHECKS_ONLY=true
      shift
      ;;
    --skip-ci)
      SKIP_CI=true
      shift
      ;;
    --quick)
      QUICK_MODE=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <PR_NUMBER> [OPTIONS]"
      echo ""
      echo "Validates PR through script-based checks."
      echo ""
      echo "Options:"
      echo "  --json            Output JSON format (default)"
      echo "  --human           Output human-readable format"
      echo "  --checks-only     Run checks without merge evaluation"
      echo "  --skip-ci         Skip CI status check"
      echo "  --quick           Quick validation (essential checks only)"
      echo "  --verbose         Show detailed check output"
      echo ""
      echo "Exit codes:"
      echo "  0 - All checks passed (mergeable)"
      echo "  1 - Some checks failed (needs fixes)"
      echo "  2 - Checks pending"
      echo "  3 - Error"
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        echo "Error: Unknown argument: $1" >&2
        exit 3
      fi
      shift
      ;;
  esac
done

# Validate arguments
if [[ -z "$PR_NUMBER" ]]; then
  echo "Error: PR number required" >&2
  exit 3
fi

# Logging helpers
log_verbose() {
  if $VERBOSE && [[ "$OUTPUT_FORMAT" == "human" ]]; then
    echo -e "$1"
  fi
}

log_human() {
  if [[ "$OUTPUT_FORMAT" == "human" ]]; then
    echo -e "$1"
  fi
}

# Extract linked issue from PR body
extract_linked_issue() {
  local pr_body="$1"
  # Match patterns: Fixes #N, Closes #N, Resolves #N (case insensitive)
  echo "$pr_body" | grep -oiE '(fixes|closes|resolves)\s*#[0-9]+' | head -1 | grep -oE '[0-9]+' || echo ""
}

# Run script-based validation checks
run_validation_checks() {
  local pr_num="$1"
  local checks_passed=0
  local checks_failed=0
  local checks_total=0
  local failures='[]'
  local remediations='[]'

  # Check 1: PR has linked issue
  log_verbose "Check 1: Verifying linked issue..."
  ((checks_total++))
  local pr_body
  pr_body=$(gh pr view "$pr_num" --json body --jq '.body // ""' 2>/dev/null) || pr_body=""
  local linked_issue
  linked_issue=$(extract_linked_issue "$pr_body")

  if [[ -z "$linked_issue" ]]; then
    ((checks_failed++))
    failures=$(echo "$failures" | jq --arg name "linked-issue" --arg desc "PR has no linked issue (Fixes #N, Closes #N, or Resolves #N)" \
      '. + [{"name": $name, "description": $desc}]')
    remediations=$(echo "$remediations" | jq --arg check "linked-issue" --arg suggestion "Add 'Fixes #ISSUE_NUMBER' to PR description" \
      '. + [{"check": $check, "suggestion": $suggestion}]')
    log_verbose "  ${RED}✗${NC} No linked issue found"
  else
    ((checks_passed++))
    log_verbose "  ${GREEN}✓${NC} Linked to issue #$linked_issue"
  fi

  # Check 2: PR is not draft
  log_verbose "Check 2: Checking draft status..."
  ((checks_total++))
  local is_draft
  is_draft=$(gh pr view "$pr_num" --json isDraft --jq '.isDraft' 2>/dev/null) || is_draft="true"

  if [[ "$is_draft" == "true" ]]; then
    ((checks_failed++))
    failures=$(echo "$failures" | jq --arg name "draft-status" --arg desc "PR is still in draft state" \
      '. + [{"name": $name, "description": $desc}]')
    remediations=$(echo "$remediations" | jq --arg check "draft-status" --arg suggestion "Mark PR as ready: gh pr ready $pr_num" \
      '. + [{"check": $check, "suggestion": $suggestion}]')
    log_verbose "  ${RED}✗${NC} PR is draft"
  else
    ((checks_passed++))
    log_verbose "  ${GREEN}✓${NC} PR is ready for review"
  fi

  # Check 3: No merge conflicts
  log_verbose "Check 3: Checking for merge conflicts..."
  ((checks_total++))
  local mergeable
  mergeable=$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable="UNKNOWN"

  if [[ "$mergeable" == "CONFLICTING" ]]; then
    ((checks_failed++))
    failures=$(echo "$failures" | jq --arg name "merge-conflicts" --arg desc "PR has merge conflicts with base branch" \
      '. + [{"name": $name, "description": $desc}]')
    remediations=$(echo "$remediations" | jq --arg check "merge-conflicts" --arg suggestion "Rebase on base branch: git fetch origin && git rebase origin/dev" \
      '. + [{"check": $check, "suggestion": $suggestion}]')
    log_verbose "  ${RED}✗${NC} Merge conflicts detected"
  elif [[ "$mergeable" == "UNKNOWN" ]]; then
    log_verbose "  ${YELLOW}⏳${NC} Mergeability unknown (GitHub calculating)"
  else
    ((checks_passed++))
    log_verbose "  ${GREEN}✓${NC} No merge conflicts"
  fi

  # Check 4: CI status (unless skipped)
  if ! $SKIP_CI && ! $QUICK_MODE; then
    log_verbose "Check 4: Checking CI status..."
    ((checks_total++))

    # Use existing check-pr-ci-status.sh with --json --quiet flags
    local ci_result
    ci_result=$(timeout 10 "$SCRIPT_DIR/check-pr-ci-status.sh" "$pr_num" --json --wait 0 --timeout 5 2>/dev/null) || ci_result='{"status":"error"}'
    local ci_status
    ci_status=$(echo "$ci_result" | jq -r '.status // "error"')

    case "$ci_status" in
      mergeable|no_checks)
        ((checks_passed++))
        log_verbose "  ${GREEN}✓${NC} CI checks passed"
        ;;
      pending)
        # Pending is not a failure, just note it
        log_verbose "  ${YELLOW}⏳${NC} CI checks still running"
        ;;
      needs_review)
        ((checks_failed++))
        local failed_checks
        failed_checks=$(echo "$ci_result" | jq -r '.checks.failed_checks // ""')
        failures=$(echo "$failures" | jq --arg name "ci-checks" --arg desc "CI checks failed: $failed_checks" \
          '. + [{"name": $name, "description": $desc}]')
        remediations=$(echo "$remediations" | jq --arg check "ci-checks" --arg suggestion "Fix failing checks. Run: gh pr checks $pr_num --web" \
          '. + [{"check": $check, "suggestion": $suggestion}]')
        log_verbose "  ${RED}✗${NC} CI checks failed: $failed_checks"
        ;;
      *)
        log_verbose "  ${YELLOW}?${NC} Could not determine CI status"
        ;;
    esac
  fi

  # Check 5: Branch is not behind base (unless quick mode)
  if ! $QUICK_MODE; then
    log_verbose "Check 5: Checking branch freshness..."
    ((checks_total++))
    local merge_state
    merge_state=$(gh pr view "$pr_num" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null) || merge_state="UNKNOWN"

    if [[ "$merge_state" == "BEHIND" ]]; then
      ((checks_failed++))
      failures=$(echo "$failures" | jq --arg name "branch-behind" --arg desc "Branch is behind base branch" \
        '. + [{"name": $name, "description": $desc}]')
      remediations=$(echo "$remediations" | jq --arg check "branch-behind" --arg suggestion "Update branch: gh pr update-branch $pr_num OR git rebase origin/dev" \
        '. + [{"check": $check, "suggestion": $suggestion}]')
      log_verbose "  ${RED}✗${NC} Branch is behind base"
    else
      ((checks_passed++))
      log_verbose "  ${GREEN}✓${NC} Branch is up to date"
    fi
  fi

  # Check 6: PR title follows convention (feature/fix/docs/etc.)
  log_verbose "Check 6: Checking PR title convention..."
  ((checks_total++))
  local pr_title
  pr_title=$(gh pr view "$pr_num" --json title --jq '.title' 2>/dev/null) || pr_title=""

  # Check for conventional commit style: type(scope): description or type: description
  # Scope can include #, numbers, letters, hyphens, underscores, and commas (e.g., feat(#396):, fix(api,auth):)
  if echo "$pr_title" | grep -qE '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-zA-Z0-9_#,/-]+\))?[!]?:'; then
    ((checks_passed++))
    log_verbose "  ${GREEN}✓${NC} Title follows convention"
  else
    ((checks_failed++))
    failures=$(echo "$failures" | jq --arg name "title-convention" --arg desc "PR title doesn't follow conventional commits format" \
      '. + [{"name": $name, "description": $desc}]')
    remediations=$(echo "$remediations" | jq --arg check "title-convention" --arg suggestion "Update title to format: type(scope): description (e.g., feat: add feature, fix: resolve bug)" \
      '. + [{"check": $check, "suggestion": $suggestion}]')
    log_verbose "  ${RED}✗${NC} Title doesn't follow convention"
  fi

  # Build checks summary
  local checks_summary
  checks_summary=$(jq -n \
    --arg total "$checks_total" \
    --arg passed "$checks_passed" \
    --arg failed "$checks_failed" \
    '{
      total: ($total | tonumber),
      passed: ($passed | tonumber),
      failed: ($failed | tonumber)
    }')

  # Return results
  jq -n \
    --argjson checks "$checks_summary" \
    --argjson failures "$failures" \
    --argjson remediations "$remediations" \
    --arg linked_issue "${linked_issue:-null}" \
    '{
      checks: $checks,
      failures: $failures,
      remediations: $remediations,
      linked_issue: (if $linked_issue == "null" or $linked_issue == "" then null else ($linked_issue | tonumber) end)
    }'
}

# Evaluate merge readiness
evaluate_merge_readiness() {
  local pr_num="$1"
  local validation_result="$2"

  local checks_failed
  checks_failed=$(echo "$validation_result" | jq '.checks.failed')

  local mergeable
  mergeable=$(gh pr view "$pr_num" --json mergeable --jq '.mergeable' 2>/dev/null) || mergeable="UNKNOWN"

  local merge_state
  merge_state=$(gh pr view "$pr_num" --json mergeStateStatus --jq '.mergeStateStatus' 2>/dev/null) || merge_state="UNKNOWN"

  local status="error"
  local summary=""

  if [[ "$checks_failed" -gt 0 ]]; then
    status="needs_fixes"
    summary="$checks_failed check(s) failed - see failures for details"
  elif [[ "$mergeable" == "UNKNOWN" ]] || [[ "$merge_state" == "UNKNOWN" ]]; then
    status="pending"
    summary="GitHub is calculating mergeability"
  elif [[ "$mergeable" == "CONFLICTING" ]]; then
    status="needs_fixes"
    summary="PR has merge conflicts"
  elif [[ "$merge_state" == "UNSTABLE" ]]; then
    status="needs_fixes"
    summary="CI checks are failing"
  elif [[ "$merge_state" == "BEHIND" ]]; then
    status="needs_fixes"
    summary="Branch needs to be updated from base"
  elif [[ "$merge_state" == "BLOCKED" ]]; then
    status="needs_fixes"
    summary="PR is blocked by branch protection rules"
  elif [[ "$mergeable" == "MERGEABLE" ]] && [[ "$merge_state" == "CLEAN" ]]; then
    status="mergeable"
    summary="All checks passed - ready to merge"
  else
    status="pending"
    summary="Merge status: $mergeable / $merge_state"
  fi

  echo "$status|$summary"
}

# Main execution
main() {
  log_human ""
  log_human "PR #$PR_NUMBER Validation"
  log_human "========================"
  log_human ""

  # Run validation checks
  local validation_result
  validation_result=$(run_validation_checks "$PR_NUMBER")

  if [[ $? -ne 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      echo "{\"pr_number\": $PR_NUMBER, \"status\": \"error\", \"summary\": \"Failed to validate PR\"}"
    else
      echo -e "${RED}Error: Failed to validate PR${NC}"
    fi
    exit 3
  fi

  # Evaluate merge readiness (unless checks-only mode)
  local status="pending"
  local summary="Checks completed"

  if ! $CHECKS_ONLY; then
    local merge_eval
    merge_eval=$(evaluate_merge_readiness "$PR_NUMBER" "$validation_result")
    status=$(echo "$merge_eval" | cut -d'|' -f1)
    summary=$(echo "$merge_eval" | cut -d'|' -f2-)
  else
    local checks_failed
    checks_failed=$(echo "$validation_result" | jq '.checks.failed')
    if [[ "$checks_failed" -eq 0 ]]; then
      status="passed"
      summary="All validation checks passed"
    else
      status="needs_fixes"
      summary="$checks_failed check(s) failed"
    fi
  fi

  # Build final output
  local linked_issue
  linked_issue=$(echo "$validation_result" | jq '.linked_issue')

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    jq -n \
      --arg pr_number "$PR_NUMBER" \
      --arg status "$status" \
      --argjson linked_issue "$linked_issue" \
      --argjson checks "$(echo "$validation_result" | jq '.checks')" \
      --argjson failures "$(echo "$validation_result" | jq '.failures')" \
      --argjson remediations "$(echo "$validation_result" | jq '.remediations')" \
      --arg summary "$summary" \
      '{
        pr_number: ($pr_number | tonumber),
        status: $status,
        linked_issue: $linked_issue,
        checks: $checks,
        failures: $failures,
        remediations: $remediations,
        summary: $summary
      }'
  else
    # Human-readable output
    local checks_total checks_passed checks_failed
    checks_total=$(echo "$validation_result" | jq '.checks.total')
    checks_passed=$(echo "$validation_result" | jq '.checks.passed')
    checks_failed=$(echo "$validation_result" | jq '.checks.failed')

    log_human ""
    log_human "Summary: $checks_passed/$checks_total checks passed"
    log_human ""

    if [[ "$checks_failed" -gt 0 ]]; then
      log_human "Failures:"
      echo "$validation_result" | jq -r '.failures[] | "  - \(.name): \(.description)"'
      log_human ""
      log_human "Remediations:"
      echo "$validation_result" | jq -r '.remediations[] | "  - \(.check): \(.suggestion)"'
      log_human ""
    fi

    case "$status" in
      mergeable|passed)
        echo -e "${GREEN}✓ PR #$PR_NUMBER: $summary${NC}"
        ;;
      needs_fixes)
        echo -e "${RED}✗ PR #$PR_NUMBER: $summary${NC}"
        ;;
      pending)
        echo -e "${YELLOW}⏳ PR #$PR_NUMBER: $summary${NC}"
        ;;
      *)
        echo -e "${RED}? PR #$PR_NUMBER: $summary${NC}"
        ;;
    esac
  fi

  # Exit with appropriate code
  case "$status" in
    mergeable|passed) exit 0 ;;
    needs_fixes) exit 1 ;;
    pending) exit 2 ;;
    *) exit 3 ;;
  esac
}

main
