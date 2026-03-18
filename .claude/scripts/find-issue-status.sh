#!/bin/bash
set -euo pipefail
# find-issue-status.sh
# Locates pr-status.json for a given issue across all contexts
#
# Usage:
#   ./scripts/find-issue-status.sh ISSUE_NUMBER       # Output path to status file
#   ./scripts/find-issue-status.sh ISSUE_NUMBER --cat # Output file contents
#   ./scripts/find-issue-status.sh ISSUE_NUMBER --json # Output JSON with path and exists
#   ./scripts/find-issue-status.sh --current          # Auto-detect from context
#
# Search order:
#   1. PR_STATUS_FILE environment variable
#   2. Current directory: ./pr-status.json (worktree context)
#   3. Worktree directory: .worktrees/issue-N/pr-status.json
#   4. Container temp: /tmp/worker-N/pr-status.json
#   5. Container workspace: /workspace/pr-status.json
#   6. Main repo fallback: .pr-status/issue-N.json
#
# Exit codes:
#   0 - Found status file
#   1 - Status file not found
#   2 - Invalid arguments

set -e

# Parse arguments
ISSUE_NUMBER=""
OUTPUT_MODE="path"  # path, cat, or json

while [[ $# -gt 0 ]]; do
  case $1 in
    --cat)
      OUTPUT_MODE="cat"
      shift
      ;;
    --json)
      OUTPUT_MODE="json"
      shift
      ;;
    --current)
      ISSUE_NUMBER="current"
      shift
      ;;
    --help|-h)
      head -25 "$0" | grep "^#" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$ISSUE_NUMBER" ]; then
        ISSUE_NUMBER="$1"
      fi
      shift
      ;;
  esac
done

# Auto-detect issue number from context
detect_issue_number() {
  # Check sprint state file
  if [ -f ".sprint-state.json" ]; then
    local num
    num=$(jq -r '.issue.number // .issue // empty' .sprint-state.json 2>/dev/null)
    if [ -n "$num" ]; then
      echo "$num"
      return 0
    fi
  fi

  # Check directory name pattern: *-issue-N
  local dir
  dir=$(basename "$(pwd)")
  if [[ "$dir" =~ -issue-([0-9]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  # Check branch name pattern: */issue-N or feat/issue-N
  local branch
  branch=$(git branch --show-current 2>/dev/null || echo "")
  if [[ "$branch" =~ issue-([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  # Check for pr-status.json in current directory
  if [ -f "pr-status.json" ]; then
    local num
    num=$(jq -r '.issue_number // empty' pr-status.json 2>/dev/null)
    if [ -n "$num" ]; then
      echo "$num"
      return 0
    fi
  fi

  return 1
}

# Resolve --current to actual issue number
if [ "$ISSUE_NUMBER" = "current" ]; then
  ISSUE_NUMBER=$(detect_issue_number) || {
    echo "Error: Could not auto-detect issue number from context" >&2
    exit 2
  }
fi

# Validate issue number
if [ -z "$ISSUE_NUMBER" ]; then
  echo "Error: Issue number required" >&2
  echo "Usage: $0 ISSUE_NUMBER [--cat|--json]" >&2
  exit 2
fi

if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: Issue number must be numeric" >&2
  exit 2
fi

# Search for status file
find_status_file() {
  local issue="$1"

  # 1. Environment variable override
  if [ -n "$PR_STATUS_FILE" ] && [ -f "$PR_STATUS_FILE" ]; then
    echo "$PR_STATUS_FILE"
    return 0
  fi

  # 2. Current directory (worktree context)
  if [ -f "pr-status.json" ]; then
    # Verify it's for the right issue
    local file_issue
    file_issue=$(jq -r '.issue_number // empty' pr-status.json 2>/dev/null)
    if [ "$file_issue" = "$issue" ]; then
      echo "pr-status.json"
      return 0
    fi
  fi

  # 3. Worktree directory
  local repo_root
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [ -n "$repo_root" ]; then
    local worktree_path="$repo_root/.worktrees/issue-$issue/pr-status.json"
    if [ -f "$worktree_path" ]; then
      echo "$worktree_path"
      return 0
    fi
  fi

  # 4. Container temp directory
  local container_tmp="/tmp/worker-$issue/pr-status.json"
  if [ -f "$container_tmp" ]; then
    echo "$container_tmp"
    return 0
  fi

  # 5. Container workspace
  if [ -f "/workspace/pr-status.json" ]; then
    local file_issue
    file_issue=$(jq -r '.issue_number // empty' /workspace/pr-status.json 2>/dev/null)
    if [ "$file_issue" = "$issue" ]; then
      echo "/workspace/pr-status.json"
      return 0
    fi
  fi

  # 6. Main repo fallback
  if [ -n "$repo_root" ]; then
    local fallback_path="$repo_root/.pr-status/issue-$issue.json"
    if [ -f "$fallback_path" ]; then
      echo "$fallback_path"
      return 0
    fi
  fi

  return 1
}

# Execute search
STATUS_FILE=$(find_status_file "$ISSUE_NUMBER") || STATUS_FILE=""

# Output based on mode
case "$OUTPUT_MODE" in
  path)
    if [ -n "$STATUS_FILE" ]; then
      echo "$STATUS_FILE"
      exit 0
    else
      echo "Status file not found for issue #$ISSUE_NUMBER" >&2
      exit 1
    fi
    ;;

  cat)
    if [ -n "$STATUS_FILE" ]; then
      cat "$STATUS_FILE"
      exit 0
    else
      echo "Status file not found for issue #$ISSUE_NUMBER" >&2
      exit 1
    fi
    ;;

  json)
    if [ -n "$STATUS_FILE" ]; then
      jq -n --arg path "$STATUS_FILE" --argjson issue "$ISSUE_NUMBER" '{
        found: true,
        path: $path,
        issue_number: $issue
      }'
    else
      jq -n --argjson issue "$ISSUE_NUMBER" '{
        found: false,
        path: null,
        issue_number: $issue
      }'
      exit 1
    fi
    ;;
esac
