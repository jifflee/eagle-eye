#!/bin/bash
set -euo pipefail
# generate-sprint-state.sh
# Generates cached sprint state to reduce redundant GitHub API calls
#
# Usage: ./scripts/generate-sprint-state.sh <ISSUE_NUMBER> [--output FILE] [--base-branch BRANCH]
#
# Fetches all issue-related data in a single pass and writes to .sprint-state.json
# Other scripts can then read from this cache instead of making API calls
#
# Output: JSON sprint state (also written to file if --output specified)

set -e

ISSUE_NUMBER="${1:-}"
OUTPUT_FILE=""
BASE_BRANCH="dev"  # Default base branch
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --base-branch)
      BASE_BRANCH="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        ISSUE_NUMBER="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$ISSUE_NUMBER" ]; then
  echo '{"error": "Issue number required"}' >&2
  exit 1
fi

# Fetch issue data (single API call with all fields)
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json number,title,body,labels,state,milestone,createdAt,updatedAt 2>/dev/null || echo '{"error": "Issue not found"}')

if echo "$ISSUE_DATA" | jq -e '.error' >/dev/null 2>&1; then
  echo "$ISSUE_DATA" >&2
  exit 1
fi

# Get current branch
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")

# Check for existing PR linked to this branch (include merge state for accurate status)
PR_DATA=$(gh pr list --head "$CURRENT_BRANCH" --state all --json number,url,state,mergeable,mergeStateStatus,reviewDecision,isDraft,title --jq '.[0] // empty' 2>/dev/null || echo "")

if [ -n "$PR_DATA" ]; then
  PR_EXISTS=true
  # Add lifecycle_state for consistent status reporting (matches sprint-status-data.sh)
  PR_INFO=$(echo "$PR_DATA" | jq '
    . + {
      lifecycle_state: (
        if .isDraft then "draft"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == "APPROVED" then "ready"
        elif .mergeStateStatus == "CLEAN" then "open"
        elif .mergeStateStatus == "BLOCKED" or .reviewDecision == "CHANGES_REQUESTED" then "blocked"
        elif .mergeStateStatus == "UNSTABLE" then "unstable"
        elif .mergeStateStatus == "BEHIND" then "behind"
        else "open"
        end
      ),
      action_needed: (
        if .isDraft then "Complete draft and mark ready for review"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == "APPROVED" then "Ready to merge"
        elif .mergeStateStatus == "CLEAN" and .reviewDecision == null then "Awaiting review"
        elif .mergeStateStatus == "BLOCKED" then "Resolve blocking issues (CI or conflicts)"
        elif .mergeStateStatus == "UNSTABLE" then "Fix failing CI checks"
        elif .mergeStateStatus == "BEHIND" then "Update branch with base"
        elif .reviewDecision == "CHANGES_REQUESTED" then "Address review feedback"
        else "Development in progress"
        end
      )
    }
  ')
else
  PR_EXISTS=false
  PR_INFO='{"number": null, "url": null, "state": null, "lifecycle_state": null, "action_needed": null}'

  # No PR on current branch - check if a merged PR exists for this issue
  # This detects orphaned issues where PR was merged but issue not closed
  MERGED_PR=$(gh pr list --state merged --search "$ISSUE_NUMBER in:body" --json number,url,state,mergedAt,body --jq '
    [.[] |
      select((.body // "") | test("(?i)(fixes|closes|resolves) #'"$ISSUE_NUMBER"'\\b")) |
      {number: .number, url: .url, state: .state, merged_at: .mergedAt}
    ] | .[0] // empty' 2>/dev/null || echo "")

  if [ -n "$MERGED_PR" ]; then
    PR_EXISTS=true
    PR_INFO=$(echo "$MERGED_PR" | jq '. + {
      lifecycle_state: "merged",
      action_needed: "Issue should be closed - PR was already merged",
      is_orphaned: true
    }')
  fi
fi

# Get dependencies (if script exists)
DEPS_DATA='{}'
if [ -x "$SCRIPT_DIR/issue-dependencies.sh" ]; then
  DEPS_DATA=$("$SCRIPT_DIR/issue-dependencies.sh" "$ISSUE_NUMBER" 2>/dev/null || echo '{}')
fi

# Get worktree info
WORKTREE_DATA='{}'
if [ -x "$SCRIPT_DIR/detect-worktree.sh" ]; then
  WORKTREE_DATA=$("$SCRIPT_DIR/detect-worktree.sh" 2>/dev/null || echo '{}')
fi

# Get milestone info from issue data
MILESTONE=$(echo "$ISSUE_DATA" | jq '.milestone // {}')

# Check if this is an epic issue with children
EPIC_DATA='{"is_epic": false}'
IS_EPIC=$(echo "$ISSUE_DATA" | jq -r '[.labels[].name] | any(. == "epic")')
if [ "$IS_EPIC" = "true" ]; then
  if [ -x "$SCRIPT_DIR/detect-epic-children.sh" ]; then
    EPIC_DATA=$("$SCRIPT_DIR/detect-epic-children.sh" "$ISSUE_NUMBER" 2>/dev/null || echo '{"is_epic": true, "children": {"total": 0, "items": []}}')
  fi
fi

# Check for active batch branch
BATCH_BRANCH=""
if [ -x "$SCRIPT_DIR/batch-branch-manager.sh" ]; then
  BATCH_BRANCH=$("$SCRIPT_DIR/batch-branch-manager.sh" get-current 2>/dev/null || echo "")
fi

# Build sprint state JSON
SPRINT_STATE=$(jq -n \
  --arg version "1.2" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg issue_num "$ISSUE_NUMBER" \
  --arg base_branch "$BASE_BRANCH" \
  --arg batch_branch "$BATCH_BRANCH" \
  --argjson issue "$ISSUE_DATA" \
  --argjson pr_exists "$PR_EXISTS" \
  --argjson pr_info "$PR_INFO" \
  --argjson deps "$DEPS_DATA" \
  --argjson worktree "$WORKTREE_DATA" \
  --argjson epic "$EPIC_DATA" \
  '{
    version: $version,
    created_at: $created_at,
    base_branch: $base_branch,
    batch_branch: (if $batch_branch != "" then $batch_branch else null end),
    issue: $issue,
    pr: {
      exists: $pr_exists,
      details: $pr_info
    },
    dependencies: $deps.dependencies // {},
    worktree: $worktree,
    epic: $epic
  }')

# Write to file if specified
if [ -n "$OUTPUT_FILE" ]; then
  echo "$SPRINT_STATE" > "$OUTPUT_FILE"
  echo "Sprint state written to $OUTPUT_FILE" >&2
fi

# Output JSON
echo "$SPRINT_STATE"
