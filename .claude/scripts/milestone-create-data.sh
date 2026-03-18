#!/bin/bash
set -euo pipefail
# new-milestone-data.sh
# Gathers existing milestone data for creating a new milestone
#
# Usage:
#   ./scripts/milestone-create-data.sh                 # Get existing milestones
#   ./scripts/milestone-create-data.sh --check "name"  # Check if name exists
#
# Outputs structured JSON with existing milestones and suggestions

set -e

CHECK_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --check)
      CHECK_NAME="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

# Function to get all milestones
get_milestones() {
  gh api repos/:owner/:repo/milestones --paginate --jq '[.[] | {number, title, state, due_on, open_issues, closed_issues}]'
}

# Function to check if name exists
check_name_exists() {
  local name="$1"
  local milestones="$2"
  echo "$milestones" | jq --arg name "$name" 'map(select(.title == $name)) | length > 0'
}

# Get current milestones
milestones=$(get_milestones)

# Get counts
open_count=$(echo "$milestones" | jq '[.[] | select(.state == "open")] | length')
closed_count=$(echo "$milestones" | jq '[.[] | select(.state == "closed")] | length')

# Generate suggestions using the validation script for sprint-MMYY-N convention
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
if [ -x "$SCRIPT_DIR/validate/validate-milestone-name.sh" ]; then
  # Get the recommended next sprint name
  next_sprint_data=$("$SCRIPT_DIR/validate/validate-milestone-name.sh" 2>/dev/null || echo '{"name": "sprint-0226-1"}')
  next_sprint=$(echo "$next_sprint_data" | jq -r '.name')
  suggestions="[\"$next_sprint\", \"MVP\", \"Phase 1\", \"v1.0\"]"
else
  # Fallback suggestions if validation script not available
  suggestions='["MVP", "Phase 1", "v1.0", "Sprint 1"]'

  # Check for naming pattern
  if echo "$milestones" | jq -e '[.[] | select(.title | test("^v[0-9]"))] | length > 0' > /dev/null 2>&1; then
    # Version pattern detected
    last_version=$(echo "$milestones" | jq -r '[.[] | select(.title | test("^v[0-9]"))] | sort_by(.title) | last | .title // "v0.0"')
    # Suggest next version
    next_version=$(echo "$last_version" | awk -F. '{print $1"."$2+1}')
    suggestions="[\"$next_version\", \"MVP\", \"Phase 1\"]"
  elif echo "$milestones" | jq -e '[.[] | select(.title | test("Sprint"))] | length > 0' > /dev/null 2>&1; then
    # Sprint pattern detected
    last_sprint=$(echo "$milestones" | jq -r '[.[] | select(.title | test("Sprint"))] | sort_by(.title) | last | .title // "Sprint 0"')
    sprint_num=$(echo "$last_sprint" | grep -oE '[0-9]+' | tail -1)
    next_sprint="Sprint $((sprint_num + 1))"
    suggestions="[\"$next_sprint\", \"MVP\", \"v1.0\"]"
  fi
fi

# Calculate suggested due dates
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if command -v gdate >/dev/null 2>&1; then
  due_30=$(gdate -d "+30 days" -u +%Y-%m-%dT%H:%M:%SZ)
  due_60=$(gdate -d "+60 days" -u +%Y-%m-%dT%H:%M:%SZ)
  due_90=$(gdate -d "+90 days" -u +%Y-%m-%dT%H:%M:%SZ)
else
  due_30=$(date -v+30d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "+30 days" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  due_60=$(date -v+60d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "+60 days" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  due_90=$(date -v+90d -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "+90 days" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
fi

# Check name if requested
name_exists=false
if [ -n "$CHECK_NAME" ]; then
  name_exists=$(check_name_exists "$CHECK_NAME" "$milestones")
fi

cat <<EOF
{
  "existing_milestones": $milestones,
  "counts": {
    "open": $open_count,
    "closed": $closed_count,
    "total": $((open_count + closed_count))
  },
  "suggestions": {
    "names": $suggestions,
    "due_dates": {
      "30_days": $([ -n "$due_30" ] && echo "\"$due_30\"" || echo "null"),
      "60_days": $([ -n "$due_60" ] && echo "\"$due_60\"" || echo "null"),
      "90_days": $([ -n "$due_90" ] && echo "\"$due_90\"" || echo "null")
    }
  },
  "name_check": {
    "name": $([ -n "$CHECK_NAME" ] && echo "\"$CHECK_NAME\"" || echo "null"),
    "exists": $name_exists
  },
  "checked_at": "$now"
}
EOF
