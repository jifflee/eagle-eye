#!/bin/bash
set -euo pipefail
# milestones-data.sh
# Gathers milestone information for display
#
# Usage:
#   ./scripts/milestone-list-data.sh              # Show open milestones
#   ./scripts/milestone-list-data.sh --all        # Show all milestones
#
# Outputs structured JSON with milestone status

set -e

SHOW_ALL=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --all)
      SHOW_ALL=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Get milestones
if [ "$SHOW_ALL" = true ]; then
  milestones=$(gh api repos/:owner/:repo/milestone-list?state=all --jq '.')
else
  milestones=$(gh api repos/:owner/:repo/milestone-list --jq '.')
fi

# Process each milestone
processed=$(echo "$milestones" | jq '[.[] | {
  number,
  title,
  state,
  due_on,
  open_issues,
  closed_issues,
  total_issues: (.open_issues + .closed_issues),
  progress_percent: (if (.open_issues + .closed_issues) > 0 then ((.closed_issues * 100) / (.open_issues + .closed_issues) | floor) else 0 end),
  is_overdue: (if .due_on != null then (.due_on < now | todate) else false end)
}] | sort_by(.due_on)')

# Get counts
open_count=$(echo "$processed" | jq '[.[] | select(.state == "open")] | length')
closed_count=$(echo "$processed" | jq '[.[] | select(.state == "closed")] | length')

# Get active milestone (first open by due date)
active=$(echo "$processed" | jq '[.[] | select(.state == "open")] | sort_by(.due_on) | .[0] // null')

cat <<EOF
{
  "milestones": $processed,
  "summary": {
    "open": $open_count,
    "closed": $closed_count,
    "total": $((open_count + closed_count))
  },
  "active_milestone": $active,
  "checked_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
