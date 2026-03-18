#!/bin/bash
set -euo pipefail
# create-issue-data.sh
# Gathers milestone and label data for issue creation
#
# Usage:
#   ./scripts/create-issue-data.sh              # Get all data for issue creation
#   ./scripts/create-issue-data.sh --milestones # Get only milestones
#   ./scripts/create-issue-data.sh --labels     # Get only labels
#
# Outputs structured JSON with milestones and labels for validation

set -e

MODE="all"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestones)
      MODE="milestones"
      shift
      ;;
    --labels)
      MODE="labels"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Function to get milestones
get_milestones() {
  gh api repos/:owner/:repo/milestones --jq '[.[] | {
    number,
    title,
    state,
    due_on,
    open_issues,
    closed_issues
  }] | sort_by(.due_on)'
}

# Function to get labels
get_labels() {
  gh label list --json name,description,color --jq '.'
}

# Function to categorize labels
categorize_labels() {
  local labels="$1"

  # Extract type labels
  local type_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^(bug|feature|tech-debt|docs)$"))]')

  # Extract status labels
  local status_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^(backlog|in-progress|blocked|wip:)")) ]')

  # Extract priority labels
  local priority_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^P[0-3]$"))]')

  # Build categorized output
  cat <<EOF
{
  "all": $labels,
  "by_category": {
    "type": $type_labels,
    "status": $status_labels,
    "priority": $priority_labels
  },
  "required_when_milestone": {
    "type": ["bug", "feature", "tech-debt", "docs"],
    "status": ["backlog", "in-progress", "blocked"]
  }
}
EOF
}

# Execute based on mode
if [ "$MODE" = "milestones" ]; then
  # Return only milestones
  milestones=$(get_milestones)
  cat <<EOF
{
  "milestones": $milestones,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

elif [ "$MODE" = "labels" ]; then
  # Return only labels
  labels=$(get_labels)
  categorized=$(categorize_labels "$labels")
  cat <<EOF
{
  "labels": $categorized,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

else
  # Return all data in single batched call
  milestones=$(get_milestones)
  labels=$(get_labels)
  categorized=$(categorize_labels "$labels")

  # Get active milestone (first open by due date)
  active_milestone=$(echo "$milestones" | jq '[.[] | select(.state == "open")] | sort_by(.due_on) | .[0] // null')

  cat <<EOF
{
  "milestones": $milestones,
  "active_milestone": $active_milestone,
  "labels": $categorized,
  "enforcement_modes": {
    "lenient": {
      "description": "Auto-adds missing required labels (default)",
      "auto_add_status": "backlog"
    },
    "strict": {
      "description": "Blocks creation if required labels missing",
      "blocks_on_missing": true
    },
    "advisory": {
      "description": "Warns but creates anyway (no milestone specified)",
      "validates": false
    }
  },
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
fi
