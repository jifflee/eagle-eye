#!/bin/bash
set -euo pipefail
# pr-review-data.sh
# Gathers PR data for review agents
#
# Usage:
#   ./scripts/pr-review-data.sh --pr N                 # By PR number
#   ./scripts/pr-review-data.sh --issue N              # By issue number (finds associated PR)
#   ./scripts/pr-review-data.sh --current              # Auto-detect from context
#   ./scripts/pr-review-data.sh --pr N --diff-only     # Only include diff (smaller output)
#   ./scripts/pr-review-data.sh --pr N --files-only    # Only include changed files list
#
# Options:
#   --pr N            PR number to review
#   --issue N         Issue number (will find associated PR)
#   --current         Auto-detect PR from current branch/context
#   --diff-only       Only include diff in output (smaller payload)
#   --files-only      Only include changed files list
#   --include-status  Include pr-status.json data if available
#   --base BRANCH     Base branch for comparison (default: auto-detect)
#
# Output: JSON with PR diff, files, implementation_agents, and review context
#
# Exit codes:
#   0 - Success
#   1 - PR not found
#   2 - Invalid arguments

set -e

# Parse arguments
PR_NUMBER=""
ISSUE_NUMBER=""
AUTO_DETECT=false
DIFF_ONLY=false
FILES_ONLY=false
INCLUDE_STATUS=false
BASE_BRANCH=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --pr)
      PR_NUMBER="$2"
      shift 2
      ;;
    --issue)
      ISSUE_NUMBER="$2"
      shift 2
      ;;
    --current)
      AUTO_DETECT=true
      shift
      ;;
    --diff-only)
      DIFF_ONLY=true
      shift
      ;;
    --files-only)
      FILES_ONLY=true
      shift
      ;;
    --include-status)
      INCLUDE_STATUS=true
      shift
      ;;
    --base)
      BASE_BRANCH="$2"
      shift 2
      ;;
    --help|-h)
      head -30 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Auto-detect PR from context
detect_pr_number() {
  # Check for existing PR on current branch
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "")
  if [ -n "$branch" ]; then
    local pr
    pr=$(gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [ -n "$pr" ]; then
      echo "$pr"
      return 0
    fi
  fi

  # Check sprint state for PR
  if [ -f ".sprint-state.json" ]; then
    local pr
    pr=$(jq -r '.pr.details.number // empty' .sprint-state.json 2>/dev/null)
    if [ -n "$pr" ] && [ "$pr" != "null" ]; then
      echo "$pr"
      return 0
    fi
  fi

  # Check pr-status.json
  if [ -f "pr-status.json" ]; then
    local pr
    pr=$(jq -r '.pr_number // empty' pr-status.json 2>/dev/null)
    if [ -n "$pr" ] && [ "$pr" != "null" ]; then
      echo "$pr"
      return 0
    fi
  fi

  return 1
}

# Find PR for an issue
find_pr_for_issue() {
  local issue="$1"
  # Search PRs that close this issue
  local pr
  pr=$(gh pr list --search "closes:#$issue OR fixes:#$issue" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [ -n "$pr" ]; then
    echo "$pr"
    return 0
  fi

  # Search PRs with issue number in branch name
  pr=$(gh pr list --search "issue-$issue in:head" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
  if [ -n "$pr" ]; then
    echo "$pr"
    return 0
  fi

  return 1
}

# Resolve PR number
if [ "$AUTO_DETECT" = true ]; then
  PR_NUMBER=$(detect_pr_number) || {
    echo '{"error": "Could not auto-detect PR from context"}' >&2
    exit 1
  }
elif [ -n "$ISSUE_NUMBER" ]; then
  PR_NUMBER=$(find_pr_for_issue "$ISSUE_NUMBER") || {
    echo "{\"error\": \"No PR found for issue #$ISSUE_NUMBER\"}" >&2
    exit 1
  }
fi

if [ -z "$PR_NUMBER" ]; then
  echo '{"error": "PR number required. Use --pr N, --issue N, or --current"}' >&2
  exit 2
fi

# Validate PR number
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
  echo '{"error": "PR number must be numeric"}' >&2
  exit 2
fi

# Get PR metadata
get_pr_metadata() {
  local pr="$1"
  gh pr view "$pr" --json number,title,state,baseRefName,headRefName,author,createdAt,updatedAt,body,mergeable,mergeStateStatus,isDraft,additions,deletions,changedFiles 2>/dev/null || echo '{}'
}

# Get changed files list
get_changed_files() {
  local pr="$1"
  gh pr view "$pr" --json files --jq '.files[] | {path: .path, additions: .additions, deletions: .deletions}' 2>/dev/null | jq -s '.' || echo '[]'
}

# Get PR diff
get_pr_diff() {
  local pr="$1"
  # gh pr diff outputs plain text, we need to escape for JSON
  gh pr diff "$pr" 2>/dev/null || echo ""
}

# Get implementation agents from pr-status.json
get_implementation_agents() {
  local issue="$1"
  local status_file

  # Try to find status file
  if [ -f "pr-status.json" ]; then
    status_file="pr-status.json"
  elif [ -n "$issue" ] && command -v find-issue-status.sh &>/dev/null; then
    status_file=$(./scripts/find-issue-status.sh "$issue" 2>/dev/null || echo "")
  fi

  if [ -n "$status_file" ] && [ -f "$status_file" ]; then
    jq '.implementation_agents // {}' "$status_file" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# Get full pr-status.json
get_pr_status() {
  local issue="$1"
  local status_file

  if [ -f "pr-status.json" ]; then
    status_file="pr-status.json"
  elif [ -n "$issue" ] && command -v find-issue-status.sh &>/dev/null; then
    status_file=$(./scripts/find-issue-status.sh "$issue" 2>/dev/null || echo "")
  fi

  if [ -n "$status_file" ] && [ -f "$status_file" ]; then
    cat "$status_file"
  else
    echo 'null'
  fi
}

# Get CI check status
get_ci_status() {
  local pr="$1"
  gh pr checks "$pr" --json name,state,status,conclusion 2>/dev/null | jq '.' || echo '[]'
}

# Main output generation
PR_META=$(get_pr_metadata "$PR_NUMBER")
CHANGED_FILES=$(get_changed_files "$PR_NUMBER")

# Extract issue number from PR if not provided
if [ -z "$ISSUE_NUMBER" ]; then
  # Try to extract from PR body (Fixes #N, Closes #N patterns)
  PR_BODY=$(echo "$PR_META" | jq -r '.body // ""')
  ISSUE_NUMBER=$(echo "$PR_BODY" | grep -oE '(Fixes|Closes|Resolves)\s*#[0-9]+' | grep -oE '[0-9]+' | head -1 || echo "")
fi

# Files-only mode
if [ "$FILES_ONLY" = true ]; then
  jq -n --argjson pr "$PR_NUMBER" --argjson files "$CHANGED_FILES" '{
    pr_number: $pr,
    changed_files: $files
  }'
  exit 0
fi

# Get implementation agents
IMPL_AGENTS=$(get_implementation_agents "$ISSUE_NUMBER")

# Diff-only mode
if [ "$DIFF_ONLY" = true ]; then
  DIFF=$(get_pr_diff "$PR_NUMBER")
  jq -n --argjson pr "$PR_NUMBER" --argjson agents "$IMPL_AGENTS" --arg diff "$DIFF" '{
    pr_number: $pr,
    implementation_agents: $agents,
    diff: $diff
  }'
  exit 0
fi

# Full output
DIFF=$(get_pr_diff "$PR_NUMBER")
CI_STATUS=$(get_ci_status "$PR_NUMBER")

# Build output
OUTPUT=$(jq -n \
  --argjson meta "$PR_META" \
  --argjson files "$CHANGED_FILES" \
  --arg diff "$DIFF" \
  --argjson agents "$IMPL_AGENTS" \
  --argjson ci "$CI_STATUS" \
  --argjson issue "${ISSUE_NUMBER:-null}" '{
    pr_number: $meta.number,
    issue_number: $issue,
    title: $meta.title,
    state: $meta.state,
    base_branch: $meta.baseRefName,
    head_branch: $meta.headRefName,
    author: $meta.author.login,
    created_at: $meta.createdAt,
    updated_at: $meta.updatedAt,
    is_draft: $meta.isDraft,
    mergeable: $meta.mergeable,
    merge_state: $meta.mergeStateStatus,
    stats: {
      additions: $meta.additions,
      deletions: $meta.deletions,
      changed_files_count: $meta.changedFiles
    },
    changed_files: $files,
    implementation_agents: $agents,
    ci_checks: $ci,
    diff: $diff
  }')

# Optionally include full pr-status.json
if [ "$INCLUDE_STATUS" = true ]; then
  PR_STATUS=$(get_pr_status "$ISSUE_NUMBER")
  OUTPUT=$(echo "$OUTPUT" | jq --argjson status "$PR_STATUS" '. + {pr_status: $status}')
fi

echo "$OUTPUT"
