#!/bin/bash
set -euo pipefail
# label-issue-data.sh
# Gathers issue and label data for label management
#
# Usage:
#   ./scripts/issue-label-data.sh <issue_number>      # Get issue labels
#   ./scripts/issue-label-data.sh --available         # Get all repo labels
#
# Outputs structured JSON with label information

set -e

ISSUE_NUMBER=""
AVAILABLE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --available)
      AVAILABLE=true
      shift
      ;;
    *)
      ISSUE_NUMBER="$1"
      shift
      ;;
  esac
done

# Function to get available labels
get_available_labels() {
  gh label list --json name,description,color --jq '[.[] | {name, description, color}]'
}

# Function to get issue labels
get_issue_labels() {
  local number="$1"
  gh issue view "$number" --json number,title,labels --jq '{number, title, labels: [.labels[].name]}'
}

if [ "$AVAILABLE" = true ]; then
  # List available labels
  labels=$(get_available_labels)

  # Group by category
  status_labels=$(echo "$labels" | jq '[.[] | select(.name | startswith("wip:") or . == "backlog" or . == "blocked")]')
  type_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^(bug|feature|tech-debt|docs)$"))]')
  priority_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^P[0-3]$"))]')
  phase_labels=$(echo "$labels" | jq '[.[] | select(.name | startswith("phase:"))]')
  other_labels=$(echo "$labels" | jq '[.[] | select(.name | test("^(wip:|backlog|blocked|bug|feature|tech-debt|docs|P[0-3]|phase:)") | not)]')

  cat <<EOF
{
  "all_labels": $labels,
  "by_category": {
    "status": $status_labels,
    "type": $type_labels,
    "priority": $priority_labels,
    "phase": $phase_labels,
    "other": $other_labels
  },
  "total_count": $(echo "$labels" | jq 'length'),
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

elif [ -n "$ISSUE_NUMBER" ]; then
  # Get issue labels
  issue=$(get_issue_labels "$ISSUE_NUMBER")
  available=$(get_available_labels)

  # Get current labels
  current=$(echo "$issue" | jq '.labels')

  # Find labels not on issue
  addable=$(echo "$available" | jq --argjson current "$current" '[.[] | select(.name as $n | $current | index($n) | not) | .name]')

  cat <<EOF
{
  "issue": $issue,
  "current_labels": $current,
  "available_labels": $available,
  "addable_labels": $addable,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

else
  echo '{"error": "Usage: label-issue-data.sh <number> | --available"}'
  exit 1
fi
