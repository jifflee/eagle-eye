#!/bin/bash
set -euo pipefail
# close-milestone-data.sh
# Gathers milestone data for safe closure validation
#
# Usage:
#   ./scripts/milestone-close-data.sh                    # Check active milestone
#   ./scripts/milestone-close-data.sh "MVP"              # Check specific milestone
#   ./scripts/milestone-close-data.sh --validate "MVP"   # Full validation
#
# Outputs structured JSON with milestone state, issues, and branch status

set -e

MILESTONE_NAME=""
VALIDATE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --validate)
      VALIDATE=true
      if [ -n "$2" ] && [[ ! "$2" =~ ^-- ]]; then
        MILESTONE_NAME="$2"
        shift
      fi
      shift
      ;;
    *)
      MILESTONE_NAME="$1"
      shift
      ;;
  esac
done

# Function to get milestone data
get_milestone() {
  local name="$1"

  if [ -n "$name" ]; then
    # Get specific milestone
    gh api repos/:owner/:repo/milestone-list --jq ".[] | select(.title==\"$name\")"
  else
    # Get first open milestone by due date
    gh api repos/:owner/:repo/milestone-list --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0]'
  fi
}

# Function to get open issues for milestone
get_open_issues() {
  local name="$1"
  gh issue list --milestone "$name" --state open --json number,title,labels --jq '.'
}

# Function to get closed issues count
get_closed_count() {
  local name="$1"
  gh issue list --milestone "$name" --state closed --json number --jq 'length'
}

# Function to check branch state
check_branch_state() {
  git fetch origin 2>/dev/null || true

  local ahead=0
  local open_prs=0
  local ci_status="unknown"

  # Check if dev is ahead of main
  if git rev-parse --verify origin/dev >/dev/null 2>&1 && git rev-parse --verify origin/main >/dev/null 2>&1; then
    ahead=$(git rev-list --count origin/main..origin/dev 2>/dev/null || echo 0)
  fi

  # Check open PRs to dev
  open_prs=$(gh pr list --base dev --state open --json number --jq 'length' 2>/dev/null || echo 0)

  # Check CI status on dev
  ci_status=$(gh run list --branch dev --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo "unknown")

  cat <<EOF
{
  "dev_ahead_of_main": $ahead,
  "open_prs_to_dev": $open_prs,
  "ci_status": "$ci_status",
  "can_release": $([ "$open_prs" -eq 0 ] && [ "$ci_status" = "success" ] && echo "true" || echo "false")
}
EOF
}

# Main execution
milestone_data=$(get_milestone "$MILESTONE_NAME")

if [ -z "$milestone_data" ] || [ "$milestone_data" = "null" ]; then
  echo '{"error": "No milestone found", "requested": "'"$MILESTONE_NAME"'"}'
  exit 1
fi

# Extract milestone info
milestone_title=$(echo "$milestone_data" | jq -r '.title')
milestone_number=$(echo "$milestone_data" | jq -r '.number')
milestone_state=$(echo "$milestone_data" | jq -r '.state')
milestone_due=$(echo "$milestone_data" | jq -r '.due_on // "none"')
open_issues_count=$(echo "$milestone_data" | jq -r '.open_issues')
closed_issues_count=$(echo "$milestone_data" | jq -r '.closed_issues')

# Get open issues details
open_issues=$(get_open_issues "$milestone_title")

# Check readiness
all_complete=false
[ "$open_issues_count" -eq 0 ] && all_complete=true

# Get branch state if validating
branch_state='{}'
if [ "$VALIDATE" = true ]; then
  branch_state=$(check_branch_state)
fi

# Calculate total and completion percentage
total_issues=$((open_issues_count + closed_issues_count))
completion_pct=0
if [ "$total_issues" -gt 0 ]; then
  completion_pct=$((closed_issues_count * 100 / total_issues))
fi

# Build next milestone suggestion
next_milestone=""
if [ -n "$milestone_due" ] && [ "$milestone_due" != "none" ]; then
  # Calculate next due date (14 days after current)
  if command -v gdate >/dev/null 2>&1; then
    next_due=$(gdate -d "$milestone_due + 14 days" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  else
    next_due=$(date -v+14d -j -f "%Y-%m-%dT%H:%M:%SZ" "$milestone_due" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  fi
fi

cat <<EOF
{
  "milestone": {
    "number": $milestone_number,
    "title": "$milestone_title",
    "state": "$milestone_state",
    "due_on": $([ "$milestone_due" = "none" ] && echo "null" || echo "\"$milestone_due\"")
  },
  "issues": {
    "open": $open_issues_count,
    "closed": $closed_issues_count,
    "total": $total_issues,
    "completion_percent": $completion_pct,
    "open_details": $open_issues
  },
  "readiness": {
    "all_issues_complete": $all_complete,
    "can_close": $all_complete
  },
  "branch_state": $branch_state,
  "next_milestone_suggestion": {
    "name": "${milestone_title}-next",
    "due_on": $([ -n "$next_due" ] && echo "\"$next_due\"" || echo "null")
  },
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
