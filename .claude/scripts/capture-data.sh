#!/bin/bash
set -euo pipefail
# capture-data.sh
# Gathers context for quick issue capture
#
# Usage:
#   ./scripts/capture-data.sh                        # Get context only
#   ./scripts/capture-data.sh --search "term"        # Search for duplicates
#   ./scripts/capture-data.sh --categorize "text"    # Get category suggestion
#
# Outputs structured JSON with milestone, duplicates, and category suggestions

set -e

SEARCH_TERM=""
CATEGORIZE_TEXT=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --search)
      SEARCH_TERM="$2"
      shift 2
      ;;
    --categorize)
      CATEGORIZE_TEXT="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Function to get active milestone
get_active_milestone() {
  gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0] | {number, title, due_on}' 2>/dev/null || echo 'null'
}

# Function to search for duplicates
search_duplicates() {
  local term="$1"

  # Search in open issues
  local results=$(gh issue list --state all --search "$term" --limit 10 --json number,title,state,labels 2>/dev/null || echo "[]")

  echo "$results"
}

# Function to categorize text
categorize_text() {
  local text="$1"
  local lower_text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

  local category="feature"
  local labels='["feature", "backlog"]'

  # Bug patterns
  if echo "$lower_text" | grep -qE '(broken|error|crash|bug|fail|wrong|doesnt work|not working)'; then
    category="bug"
    labels='["bug", "backlog"]'
  # Tech-debt patterns
  elif echo "$lower_text" | grep -qE '(refactor|cleanup|optimize|performance|technical debt|tech debt)'; then
    category="tech-debt"
    labels='["tech-debt", "backlog"]'
  # Documentation patterns
  elif echo "$lower_text" | grep -qE '(document|readme|guide|instructions|docs)'; then
    category="docs"
    labels='["docs", "backlog"]'
  # Design patterns
  elif echo "$lower_text" | grep -qE '(design|ux|ui|architect|layout)'; then
    category="feature"
    labels='["feature", "phase:design", "backlog"]'
  fi

  cat <<EOF
{
  "category": "$category",
  "labels": $labels
}
EOF
}

# Get context
milestone=$(get_active_milestone)

# Search if requested
duplicates='[]'
if [ -n "$SEARCH_TERM" ]; then
  duplicates=$(search_duplicates "$SEARCH_TERM")
fi

# Categorize if requested
categorization='null'
if [ -n "$CATEGORIZE_TEXT" ]; then
  categorization=$(categorize_text "$CATEGORIZE_TEXT")
fi

# Get current branch for context
current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

cat <<EOF
{
  "context": {
    "active_milestone": $milestone,
    "current_branch": "$current_branch",
    "default_labels": ["backlog"]
  },
  "search": {
    "term": $([ -n "$SEARCH_TERM" ] && echo "\"$SEARCH_TERM\"" || echo "null"),
    "results": $duplicates,
    "has_duplicates": $(echo "$duplicates" | jq 'length > 0')
  },
  "categorization": $categorization,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
