#!/bin/bash
set -euo pipefail
# worktree-auto-merge.sh
# Automatically merges a PR when conditions are met (CI passes, approved)
#
# Usage:
#   ./scripts/worktree-auto-merge.sh <PR_NUMBER> [OPTIONS]
#
# Options:
#   --wait           Wait for CI to complete (default: check current state only)
#   --timeout <sec>  Timeout in seconds when waiting (default: 600)
#   --require-approval  Require at least one approval before merge
#   --dry-run        Show what would be done without merging
#   --json           Output JSON result
#
# Exit Codes:
#   0 - Successfully merged
#   1 - Error (PR not found, merge conflict, etc.)
#   2 - Conditions not met (CI failing, needs approval)
#   3 - Timeout waiting for conditions
#
# Output (JSON mode):
#   {
#     "success": true|false,
#     "pr_number": N,
#     "action": "merged"|"waiting"|"blocked"|"error",
#     "reason": "description",
#     "merged_sha": "sha" (if merged),
#     "issue_number": N (if linked)
#   }

set -e

# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ DEPRECATION NOTICE (Phase 2 - Apr 2026)                                     │
# │                                                                             │
# │ This script is DEPRECATED and scheduled for removal in Phase 3 (H2 2026).  │
# │                                                                             │
# │ Replacements:                                                               │
# │   - Container mode: /sprint-work --issue N --container                     │
# │   - PR merge:       gh pr merge --squash --delete-branch                   │
# │   - Worktree-safe:  ./scripts/worktree-safe-merge.sh (until containers)    │
# │                                                                             │
# │ See: docs/CONTAINERIZED_WORKFLOW.md#worktree-deprecation-timeline          │
# └─────────────────────────────────────────────────────────────────────────────┘
echo "⚠️  DEPRECATED: worktree-auto-merge.sh → Use 'gh pr merge' or '/sprint-work --container'" >&2

# Script directory for calling sibling scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
PR_NUMBER=""
WAIT_FOR_CI=false
TIMEOUT=600
REQUIRE_APPROVAL=false
DRY_RUN=false
JSON_OUTPUT=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --wait)
      WAIT_FOR_CI=true
      shift
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --require-approval)
      REQUIRE_APPROVAL=true
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
    -h|--help)
      echo "Usage: $0 <PR_NUMBER> [OPTIONS]"
      echo ""
      echo "Automatically merges a PR when conditions are met."
      echo ""
      echo "Options:"
      echo "  --wait              Wait for CI to complete"
      echo "  --timeout <sec>     Timeout in seconds when waiting (default: 600)"
      echo "  --require-approval  Require at least one approval"
      echo "  --dry-run           Show what would be done"
      echo "  --json              Output JSON result"
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        echo "Error: Unknown argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "Error: PR number required" >&2
  exit 1
fi

# Output helpers
output_json() {
  local success="$1"
  local action="$2"
  local reason="$3"
  local sha="${4:-}"
  local issue="${5:-}"

  if $JSON_OUTPUT; then
    cat << EOF
{
  "success": $success,
  "pr_number": $PR_NUMBER,
  "action": "$action",
  "reason": "$reason"$([ -n "$sha" ] && echo ", \"merged_sha\": \"$sha\"")$([ -n "$issue" ] && echo ", \"issue_number\": $issue")
}
EOF
  fi
}

output_message() {
  if ! $JSON_OUTPUT; then
    echo "$1"
  fi
}

# Get PR details
PR_INFO=$(gh pr view "$PR_NUMBER" --json state,headRefName,mergeable,mergeStateStatus,statusCheckRollup,reviewDecision,body 2>/dev/null) || {
  output_json "false" "error" "Could not fetch PR #$PR_NUMBER"
  output_message "Error: Could not fetch PR #$PR_NUMBER"
  exit 1
}

PR_STATE=$(echo "$PR_INFO" | jq -r '.state')
MERGEABLE=$(echo "$PR_INFO" | jq -r '.mergeable')
MERGE_STATE=$(echo "$PR_INFO" | jq -r '.mergeStateStatus')
REVIEW_DECISION=$(echo "$PR_INFO" | jq -r '.reviewDecision')
PR_BODY=$(echo "$PR_INFO" | jq -r '.body')

# Extract linked issue from PR body
LINKED_ISSUE=$(echo "$PR_BODY" | grep -oE '(fix(es)?|close[sd]?|resolve[sd]?)\s+#([0-9]+)' | grep -oE '[0-9]+' | head -1 || echo "")

# Check PR state
if [[ "$PR_STATE" != "OPEN" ]]; then
  if [[ "$PR_STATE" == "MERGED" ]]; then
    output_json "true" "already_merged" "PR #$PR_NUMBER was already merged" "" "$LINKED_ISSUE"
    output_message "PR #$PR_NUMBER is already merged"
    exit 0
  fi
  output_json "false" "error" "PR #$PR_NUMBER is not open (state: $PR_STATE)"
  output_message "Error: PR #$PR_NUMBER is not open (state: $PR_STATE)"
  exit 1
fi

# Check for merge conflicts
if [[ "$MERGEABLE" == "CONFLICTING" ]]; then
  output_json "false" "blocked" "PR has merge conflicts" "" "$LINKED_ISSUE"
  output_message "PR #$PR_NUMBER has merge conflicts"
  exit 2
fi

# Function to check CI status
check_ci_status() {
  local checks=$(echo "$PR_INFO" | jq -r '.statusCheckRollup')

  # Count check states
  local total=$(echo "$checks" | jq 'length')
  local success=$(echo "$checks" | jq '[.[] | select(.conclusion == "SUCCESS" or .conclusion == "SKIPPED")] | length')
  local pending=$(echo "$checks" | jq '[.[] | select(.status == "IN_PROGRESS" or .status == "QUEUED" or .status == "PENDING")] | length')
  local failed=$(echo "$checks" | jq '[.[] | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED")] | length')

  if [[ "$pending" -gt 0 ]]; then
    echo "pending"
  elif [[ "$failed" -gt 0 ]]; then
    echo "failed"
  elif [[ "$total" -eq 0 || "$success" -eq "$total" ]]; then
    echo "success"
  else
    echo "unknown"
  fi
}

# Function to check approval status
check_approval() {
  if [[ "$REVIEW_DECISION" == "APPROVED" ]]; then
    echo "approved"
  elif [[ "$REVIEW_DECISION" == "CHANGES_REQUESTED" ]]; then
    echo "changes_requested"
  else
    echo "pending"
  fi
}

# Check current conditions
CI_STATUS=$(check_ci_status)
APPROVAL_STATUS=$(check_approval)

output_message "PR #$PR_NUMBER status:"
output_message "  CI: $CI_STATUS"
output_message "  Approval: $APPROVAL_STATUS"
output_message "  Mergeable: $MERGEABLE"

# Wait for CI if requested
if $WAIT_FOR_CI && [[ "$CI_STATUS" == "pending" ]]; then
  output_message "Waiting for CI to complete (timeout: ${TIMEOUT}s)..."

  START_TIME=$(date +%s)
  while true; do
    ELAPSED=$(($(date +%s) - START_TIME))
    if [[ $ELAPSED -ge $TIMEOUT ]]; then
      output_json "false" "timeout" "Timed out waiting for CI after ${TIMEOUT}s" "" "$LINKED_ISSUE"
      output_message "Timeout: CI did not complete within ${TIMEOUT}s"
      exit 3
    fi

    # Refresh PR info
    PR_INFO=$(gh pr view "$PR_NUMBER" --json statusCheckRollup 2>/dev/null)
    CI_STATUS=$(check_ci_status)

    if [[ "$CI_STATUS" != "pending" ]]; then
      break
    fi

    sleep 10
  done

  output_message "CI completed with status: $CI_STATUS"
fi

# Check if conditions are met
if [[ "$CI_STATUS" == "failed" ]]; then
  output_json "false" "blocked" "CI checks are failing" "" "$LINKED_ISSUE"
  output_message "Cannot merge: CI checks are failing"
  exit 2
fi

if [[ "$CI_STATUS" == "pending" ]]; then
  output_json "false" "waiting" "CI checks are still running" "" "$LINKED_ISSUE"
  output_message "Cannot merge: CI checks still running (use --wait to wait)"
  exit 2
fi

if $REQUIRE_APPROVAL && [[ "$APPROVAL_STATUS" != "approved" ]]; then
  output_json "false" "blocked" "PR requires approval (current: $APPROVAL_STATUS)" "" "$LINKED_ISSUE"
  output_message "Cannot merge: PR requires approval"
  exit 2
fi

if [[ "$APPROVAL_STATUS" == "changes_requested" ]]; then
  output_json "false" "blocked" "Changes have been requested on this PR" "" "$LINKED_ISSUE"
  output_message "Cannot merge: Changes have been requested"
  exit 2
fi

# Dry run mode
if $DRY_RUN; then
  output_json "true" "would_merge" "Conditions met, would merge" "" "$LINKED_ISSUE"
  output_message "Dry run: Would merge PR #$PR_NUMBER"
  output_message "  - CI: $CI_STATUS"
  output_message "  - Approval: $APPROVAL_STATUS"
  [[ -n "$LINKED_ISSUE" ]] && output_message "  - Linked issue: #$LINKED_ISSUE"
  exit 0
fi

# Perform the merge using worktree-safe-merge.sh
output_message "Merging PR #$PR_NUMBER..."

MERGE_RESULT=$("$SCRIPT_DIR/worktree-safe-merge.sh" "$PR_NUMBER" --squash 2>&1) || {
  ERROR_MSG=$(echo "$MERGE_RESULT" | jq -r '.error // "Unknown error"' 2>/dev/null || echo "$MERGE_RESULT")
  output_json "false" "error" "Merge failed: $ERROR_MSG" "" "$LINKED_ISSUE"
  output_message "Error: Merge failed - $ERROR_MSG"
  exit 1
}

MERGED_SHA=$(echo "$MERGE_RESULT" | jq -r '.sha // "unknown"' 2>/dev/null || echo "unknown")

output_json "true" "merged" "PR #$PR_NUMBER merged successfully" "$MERGED_SHA" "$LINKED_ISSUE"
output_message "PR #$PR_NUMBER merged successfully"
[[ -n "$LINKED_ISSUE" ]] && output_message "Linked issue #$LINKED_ISSUE will be closed by GitHub automation"

exit 0
