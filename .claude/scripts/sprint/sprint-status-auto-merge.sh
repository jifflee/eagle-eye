#!/bin/bash
set -euo pipefail
# sprint-status-auto-merge.sh
# Auto-merges PRs that are in mergeable state
#
# Usage: ./scripts/sprint-status-auto-merge.sh [--dry-run] [--milestone MILESTONE]
#
# Outputs JSON with merge results for each PR

set -e

# Ensure we're in the repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository", "merged": [], "failed": [], "skipped": []}'
  exit 1
}

DRY_RUN=false
MILESTONE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --milestone)
      MILESTONE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Get milestone if not specified (use earliest due date)
if [ -z "$MILESTONE" ]; then
  MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE" ]; then
  echo '{"error": "No open milestones found", "merged": [], "failed": [], "skipped": []}'
  exit 0
fi

# Get milestone issue numbers for PR matching
MILESTONE_ISSUE_NUMS=$(gh issue list --milestone "$MILESTONE" --state all --json number --jq '[.[].number]' 2>/dev/null)

# Get all open PRs with merge status
ALL_PRS=$(gh pr list --state open --json number,title,headRefName,mergeable,mergeStateStatus,body,isDraft,reviewDecision 2>/dev/null)

# Filter to mergeable PRs linked to milestone issues
MERGEABLE_PRS=$(echo "$ALL_PRS" | jq --argjson issues "$MILESTONE_ISSUE_NUMS" '
  [.[] |
    # Extract linked issue from body (Fixes #N, Closes #N, Resolves #N)
    . as $pr |
    (($pr.body // "") | capture("(?i)(?:fixes|closes|resolves) #(?<num>[0-9]+)") | .num | tonumber) as $linked |
    select($linked != null and ($issues | index($linked))) |
    select(.isDraft == false) |
    select(.mergeable == "MERGEABLE") |
    select(.mergeStateStatus == "CLEAN") |
    {
      pr_number: .number,
      title: .title,
      linked_issue: $linked,
      branch: .headRefName,
      review_decision: .reviewDecision
    }
  ]')

MERGED=()
FAILED=()
SKIPPED=()

# Process each mergeable PR
PR_COUNT=$(echo "$MERGEABLE_PRS" | jq 'length')

if [ "$PR_COUNT" -eq 0 ]; then
  DRY_RUN_VAL="false"
  [ "$DRY_RUN" = true ] && DRY_RUN_VAL="true"
  echo '{"merged": [], "failed": [], "skipped": [], "summary": {"merged_count": 0, "failed_count": 0, "skipped_count": 0, "dry_run": '"$DRY_RUN_VAL"'}, "message": "No mergeable PRs found"}'
  exit 0
fi

# Build output arrays
MERGED_JSON="[]"
FAILED_JSON="[]"
SKIPPED_JSON="[]"

for i in $(seq 0 $((PR_COUNT - 1))); do
  PR=$(echo "$MERGEABLE_PRS" | jq ".[$i]")
  PR_NUMBER=$(echo "$PR" | jq -r '.pr_number')
  PR_TITLE=$(echo "$PR" | jq -r '.title')
  LINKED_ISSUE=$(echo "$PR" | jq -r '.linked_issue')
  BRANCH=$(echo "$PR" | jq -r '.branch')

  if [ "$DRY_RUN" = true ]; then
    # Just report what would be merged
    SKIPPED_JSON=$(echo "$SKIPPED_JSON" | jq --arg pr "$PR_NUMBER" --arg title "$PR_TITLE" --arg issue "$LINKED_ISSUE" \
      '. + [{"pr_number": ($pr | tonumber), "title": $title, "linked_issue": ($issue | tonumber), "reason": "dry-run mode"}]')
    continue
  fi

  # Re-check PR is still mergeable (state may have changed)
  CURRENT_STATE=$(gh pr view "$PR_NUMBER" --json mergeable,mergeStateStatus 2>/dev/null) || {
    FAILED_JSON=$(echo "$FAILED_JSON" | jq --arg pr "$PR_NUMBER" --arg title "$PR_TITLE" --arg reason "Could not fetch PR state" \
      '. + [{"pr_number": ($pr | tonumber), "title": $title, "error": $reason}]')
    continue
  }

  CURRENT_MERGEABLE=$(echo "$CURRENT_STATE" | jq -r '.mergeable')
  CURRENT_STATE_STATUS=$(echo "$CURRENT_STATE" | jq -r '.mergeStateStatus')

  if [ "$CURRENT_MERGEABLE" != "MERGEABLE" ] || [ "$CURRENT_STATE_STATUS" != "CLEAN" ]; then
    SKIPPED_JSON=$(echo "$SKIPPED_JSON" | jq --arg pr "$PR_NUMBER" --arg title "$PR_TITLE" --arg reason "State changed: $CURRENT_MERGEABLE / $CURRENT_STATE_STATUS" \
      '. + [{"pr_number": ($pr | tonumber), "title": $title, "reason": $reason}]')
    continue
  fi

  # Perform merge
  echo "Merging PR #$PR_NUMBER: $PR_TITLE..." >&2

  MERGE_RESULT=$(gh pr merge "$PR_NUMBER" --squash --delete-branch 2>&1) && MERGE_SUCCESS=true || MERGE_SUCCESS=false

  if [ "$MERGE_SUCCESS" = true ]; then
    MERGED_JSON=$(echo "$MERGED_JSON" | jq --arg pr "$PR_NUMBER" --arg title "$PR_TITLE" --arg issue "$LINKED_ISSUE" --arg branch "$BRANCH" \
      '. + [{"pr_number": ($pr | tonumber), "title": $title, "linked_issue": ($issue | tonumber), "branch_deleted": $branch}]')
  else
    FAILED_JSON=$(echo "$FAILED_JSON" | jq --arg pr "$PR_NUMBER" --arg title "$PR_TITLE" --arg reason "$MERGE_RESULT" \
      '. + [{"pr_number": ($pr | tonumber), "title": $title, "error": $reason}]')
  fi
done

# Build final output
MERGED_COUNT=$(echo "$MERGED_JSON" | jq 'length')
FAILED_COUNT=$(echo "$FAILED_JSON" | jq 'length')
SKIPPED_COUNT=$(echo "$SKIPPED_JSON" | jq 'length')

jq -n \
  --argjson merged "$MERGED_JSON" \
  --argjson failed "$FAILED_JSON" \
  --argjson skipped "$SKIPPED_JSON" \
  --arg dry_run "$DRY_RUN" \
  '{
    merged: $merged,
    failed: $failed,
    skipped: $skipped,
    summary: {
      merged_count: ($merged | length),
      failed_count: ($failed | length),
      skipped_count: ($skipped | length),
      dry_run: ($dry_run == "true")
    }
  }'
