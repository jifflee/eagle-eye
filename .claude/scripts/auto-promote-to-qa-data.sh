#!/bin/bash
set -euo pipefail
# auto-promote-to-qa-data.sh
# Gathers data for automatic dev→qa promotion on milestone completion
#
# Usage:
#   ./scripts/auto-promote-to-qa-data.sh                     # Check active milestone
#   ./scripts/auto-promote-to-qa-data.sh "MVP"               # Check specific milestone
#   ./scripts/auto-promote-to-qa-data.sh --milestone "MVP"   # Alternative syntax
#
# Outputs structured JSON with:
#   - milestone: Milestone metadata and completion state
#   - branch_state: Dev vs qa comparison
#   - readiness: Pre-computed flags for auto-promotion
#   - existing_pr: Current dev→qa PR if any
#   - changelog: Categorized commits (features, fixes, other)

set -e

MILESTONE_NAME=""
INCLUDE_CHANGELOG=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_NAME="$2"
      shift 2
      ;;
    --changelog)
      INCLUDE_CHANGELOG=true
      shift
      ;;
    -*)
      shift
      ;;
    *)
      MILESTONE_NAME="$1"
      shift
      ;;
  esac
done

# Fetch latest
git fetch origin 2>/dev/null || true

# Function to get milestone data
get_milestone() {
  local name="$1"

  if [ -n "$name" ]; then
    gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$name\")"
  else
    # Get first open milestone by due date
    gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0]'
  fi
}

# Function to check branch state
get_branch_state() {
  local ahead=0
  local behind=0
  local qa_exists=true

  # Check if qa branch exists
  if ! git rev-parse --verify origin/qa >/dev/null 2>&1; then
    qa_exists=false
    if git rev-parse --verify origin/dev >/dev/null 2>&1; then
      ahead=$(git rev-list --count origin/dev 2>/dev/null || echo 0)
    fi
  else
    if git rev-parse --verify origin/dev >/dev/null 2>&1; then
      ahead=$(git rev-list --count origin/qa..origin/dev 2>/dev/null || echo 0)
      behind=$(git rev-list --count origin/dev..origin/qa 2>/dev/null || echo 0)
    fi
  fi

  echo "{\"ahead\": $ahead, \"behind\": $behind, \"qa_exists\": $qa_exists}"
}

# Function to get CI status on dev
get_ci_status() {
  gh run list --branch dev --limit 1 --json conclusion --jq '.[0].conclusion // "unknown"' 2>/dev/null || echo "unknown"
}

# Function to get open PRs to dev
get_open_prs_to_dev() {
  gh pr list --base dev --state open --json number --jq 'length' 2>/dev/null || echo 0
}

# Function to check for existing PR from dev to qa
get_existing_pr() {
  local result
  result=$(gh pr list --head dev --base qa --state open --json number,url,title --jq '.[0] // null' 2>/dev/null) || result="null"
  # Ensure we always return valid JSON
  if [ -z "$result" ] || [ "$result" = "" ]; then
    echo "null"
  else
    echo "$result"
  fi
}

# Function to get commits for changelog
get_commits() {
  if git rev-parse --verify origin/qa >/dev/null 2>&1; then
    git log --oneline origin/qa..origin/dev 2>/dev/null || echo ""
  else
    git log --oneline origin/dev -30 2>/dev/null || echo ""
  fi
}

# Function to categorize commits
categorize_commits() {
  local commits="$1"

  local features=""
  local fixes=""
  local other=""

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if echo "$line" | grep -qiE '^[a-f0-9]+ feat'; then
      features="$features\"$(echo "$line" | sed 's/"/\\"/g')\","
    elif echo "$line" | grep -qiE '^[a-f0-9]+ fix'; then
      fixes="$fixes\"$(echo "$line" | sed 's/"/\\"/g')\","
    else
      other="$other\"$(echo "$line" | sed 's/"/\\"/g')\","
    fi
  done <<< "$commits"

  # Remove trailing commas
  features="${features%,}"
  fixes="${fixes%,}"
  other="${other%,}"

  echo "{\"features\": [${features}], \"fixes\": [${fixes}], \"other\": [${other}]}"
}

# Get milestone data
milestone_data=$(get_milestone "$MILESTONE_NAME")

if [ -z "$milestone_data" ] || [ "$milestone_data" = "null" ]; then
  echo '{"error": "No milestone found", "requested": "'"$MILESTONE_NAME"'"}'
  exit 1
fi

# Extract milestone info
milestone_title=$(echo "$milestone_data" | jq -r '.title')
milestone_number=$(echo "$milestone_data" | jq -r '.number')
milestone_state=$(echo "$milestone_data" | jq -r '.state')
open_issues_count=$(echo "$milestone_data" | jq -r '.open_issues')
closed_issues_count=$(echo "$milestone_data" | jq -r '.closed_issues')
total_issues=$((open_issues_count + closed_issues_count))

# Calculate completion
completion_pct=0
if [ "$total_issues" -gt 0 ]; then
  completion_pct=$((closed_issues_count * 100 / total_issues))
fi

all_complete=false
[ "$open_issues_count" -eq 0 ] && all_complete=true

# Get branch and CI data
branch_state=$(get_branch_state)
ci_status=$(get_ci_status)
open_prs_to_dev=$(get_open_prs_to_dev)
existing_pr=$(get_existing_pr)

# Extract branch state values
ahead=$(echo "$branch_state" | jq '.ahead')
qa_exists=$(echo "$branch_state" | jq '.qa_exists')

# Determine readiness
can_auto_promote=false
block_reasons='[]'

if [ "$all_complete" != "true" ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["milestone has open issues"]')
elif [ "$ahead" -eq 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["no commits ahead of qa"]')
elif [ "$open_prs_to_dev" -gt 0 ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["open PRs to dev"]')
elif [ "$ci_status" != "success" ]; then
  block_reasons=$(echo "$block_reasons" | jq '. + ["CI not passing on dev"]')
elif [ "$existing_pr" != "null" ]; then
  # PR already exists - might still be promotable if we just need to merge it
  can_auto_promote=true
else
  can_auto_promote=true
fi

# Get changelog if requested
changelog='null'
if [ "$INCLUDE_CHANGELOG" = true ] && [ "$ahead" -gt 0 ]; then
  commits=$(get_commits)
  changelog=$(categorize_commits "$commits")
fi

# Build output
cat <<EOF
{
  "milestone": {
    "number": $milestone_number,
    "title": "$milestone_title",
    "state": "$milestone_state",
    "issues": {
      "open": $open_issues_count,
      "closed": $closed_issues_count,
      "total": $total_issues,
      "completion_percent": $completion_pct,
      "all_complete": $all_complete
    }
  },
  "branch_state": {
    "commits_ahead": $ahead,
    "qa_branch_exists": $qa_exists
  },
  "ci_status": "$ci_status",
  "open_prs_to_dev": $open_prs_to_dev,
  "existing_pr": $existing_pr,
  "readiness": {
    "can_auto_promote": $can_auto_promote,
    "block_reasons": $block_reasons
  },
  "changelog": $changelog,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
