#!/bin/bash
# detect-epic-children.sh
# Detects child issues for an epic and tracks new children since last check
#
# Usage:
#   ./scripts/detect-epic-children.sh <EPIC_NUMBER>
#   ./scripts/detect-epic-children.sh <EPIC_NUMBER> --since <TIMESTAMP>
#   ./scripts/detect-epic-children.sh <EPIC_NUMBER> --since-file <FILE>
#
# Arguments:
#   EPIC_NUMBER - The issue number of the epic
#   --since     - ISO timestamp to compare against (find children created after)
#   --since-file - File containing last check timestamp (updates file after check)
#
# Output: JSON with epic status and children information
#   {
#     "is_epic": true,
#     "epic_number": 65,
#     "children": {
#       "total": 3,
#       "open": 2,
#       "closed": 1,
#       "new_since_check": 1,
#       "items": [...]
#     }
#   }
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - GitHub API error
#   3 - Issue is not an epic

set -euo pipefail

# Parse arguments
EPIC_NUMBER=""
SINCE_TIMESTAMP=""
SINCE_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --since)
      SINCE_TIMESTAMP="${2:-}"
      shift 2
      ;;
    --since-file)
      SINCE_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 <EPIC_NUMBER> [--since TIMESTAMP] [--since-file FILE]"
      exit 0
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$EPIC_NUMBER" ]; then
        EPIC_NUMBER="$1"
      fi
      shift
      ;;
  esac
done

if [ -z "$EPIC_NUMBER" ]; then
  echo '{"error": "Epic number required"}' >&2
  exit 1
fi

# Read timestamp from file if specified
if [ -n "$SINCE_FILE" ] && [ -f "$SINCE_FILE" ]; then
  SINCE_TIMESTAMP=$(cat "$SINCE_FILE" 2>/dev/null || echo "")
fi

# Check if issue exists and is an epic
ISSUE_DATA=$(gh issue view "$EPIC_NUMBER" --json number,title,labels,state 2>/dev/null) || {
  echo '{"error": "Issue not found", "number": '"$EPIC_NUMBER"'}' >&2
  exit 2
}

# Check for epic label
IS_EPIC=$(echo "$ISSUE_DATA" | jq -r '[.labels[].name] | any(. == "epic")')

if [ "$IS_EPIC" != "true" ]; then
  # Not an epic, return status indicating this
  jq -n \
    --argjson epic_number "$EPIC_NUMBER" \
    --argjson issue "$ISSUE_DATA" \
    '{
      is_epic: false,
      epic_number: $epic_number,
      issue_title: $issue.title,
      children: {
        total: 0,
        open: 0,
        closed: 0,
        new_since_check: 0,
        items: []
      }
    }'
  exit 0
fi

# Get all children with parent:N label
CHILDREN=$(gh issue list \
  --label "parent:${EPIC_NUMBER}" \
  --state all \
  --json number,title,state,labels,createdAt \
  --limit 100 2>/dev/null) || {
  CHILDREN="[]"
}

# Calculate statistics
TOTAL=$(echo "$CHILDREN" | jq 'length')
CLOSED=$(echo "$CHILDREN" | jq '[.[] | select(.state == "CLOSED")] | length')
OPEN=$(echo "$CHILDREN" | jq '[.[] | select(.state == "OPEN")] | length')

# Find new children since timestamp (if provided)
NEW_COUNT=0
if [ -n "$SINCE_TIMESTAMP" ]; then
  NEW_COUNT=$(echo "$CHILDREN" | jq --arg since "$SINCE_TIMESTAMP" '
    [.[] | select(.createdAt > $since)] | length
  ')
fi

# Get current timestamp for next check
CURRENT_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Update since file if specified
if [ -n "$SINCE_FILE" ]; then
  echo "$CURRENT_TIMESTAMP" > "$SINCE_FILE"
fi

# Build output JSON
jq -n \
  --argjson epic_number "$EPIC_NUMBER" \
  --argjson issue "$ISSUE_DATA" \
  --argjson children "$CHILDREN" \
  --argjson total "$TOTAL" \
  --argjson closed "$CLOSED" \
  --argjson open "$OPEN" \
  --argjson new_count "$NEW_COUNT" \
  --arg since "${SINCE_TIMESTAMP:-}" \
  --arg checked_at "$CURRENT_TIMESTAMP" \
  '{
    is_epic: true,
    epic_number: $epic_number,
    epic_title: $issue.title,
    epic_state: $issue.state,
    checked_at: $checked_at,
    children: {
      total: $total,
      open: $open,
      closed: $closed,
      percent_complete: (if $total > 0 then ($closed * 100 / $total | floor) else 0 end),
      new_since_check: $new_count,
      since_timestamp: (if $since != "" then $since else null end),
      items: [$children[] | {
        number: .number,
        title: .title,
        state: .state,
        created_at: .createdAt,
        labels: [.labels[].name]
      }]
    }
  }'
