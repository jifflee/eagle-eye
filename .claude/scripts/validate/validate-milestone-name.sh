#!/usr/bin/env bash
set -euo pipefail
#
# Validate Milestone Name Convention
# Validates and auto-generates milestone names following sprint-MMYY-N convention
#
# Convention: sprint-MMYY-N
#   - MMYY: Month and 2-digit year (e.g., 0226 for February 2026)
#   - N: Sequential number — total completed milestones + 1
#   - Historical milestones are grandfathered (MVP, n8n-mvp, sprint-1/13, sprint-2/7, sprint-2/8, backlog)
#
# Usage:
#   ./scripts/validate-milestone-name.sh                    # Generate next milestone name
#   ./scripts/validate-milestone-name.sh sprint-0226-6      # Validate specific name
#   ./scripts/validate-milestone-name.sh --check sprint-0226-6  # Same as above
#   ./scripts/validate-milestone-name.sh --next             # Calculate next sequential number
#   ./scripts/validate-milestone-name.sh --help             # Show help
#
# Exit codes:
#   0 - Valid or successfully generated
#   1 - Invalid format
#   2 - Error (API failure, etc.)

set -e

# Get repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

# Grandfathered historical milestone names (exempt from validation)
GRANDFATHERED_NAMES=(
  "MVP"
  "n8n-mvp"
  "sprint-1/13"
  "sprint-2/7"
  "sprint-2/8"
  "backlog"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
  cat << 'EOF'
Usage: validate-milestone-name.sh [options] [NAME]

Validate milestone names against sprint-MMYY-N convention.

Options:
  --check NAME      Validate a specific milestone name
  --next            Calculate next sequential number only
  --help, -h        Show this help message

Arguments:
  NAME              Milestone name to validate (same as --check NAME)

Convention:
  sprint-MMYY-N
    - MMYY: Month and 2-digit year (e.g., 0226 for February 2026)
    - N: Sequential number based on total closed milestones (excluding grandfathered)

Examples:
  ./scripts/validate-milestone-name.sh                    # Generate next name
  ./scripts/validate-milestone-name.sh sprint-0226-6      # Validate name
  ./scripts/validate-milestone-name.sh --check sprint-0226-6
  ./scripts/validate-milestone-name.sh --next             # Get next N value

Grandfathered Names (always valid):
  - MVP, n8n-mvp, backlog
  - sprint-1/13, sprint-2/7, sprint-2/8

Exit Codes:
  0 - Valid or successfully generated
  1 - Invalid format
  2 - Error (API failure, etc.)

Output Format:
  If validating:
    {"valid": true|false, "reason": "...", "name": "..."}

  If generating:
    {"valid": true, "name": "sprint-MMYY-N", "next_n": N, "mmyy": "MMYY"}
EOF
}

# Check if name is grandfathered
is_grandfathered() {
  local name="$1"
  for gf in "${GRANDFATHERED_NAMES[@]}"; do
    if [ "$name" = "$gf" ]; then
      return 0
    fi
  done
  return 1
}

# Get highest sequential number from existing sprint-MMYY-N milestones
# This handles the case where historical milestones were deleted/closed
get_next_sequential_number() {
  local all_milestones
  all_milestones=$(gh api repos/:owner/:repo/milestones --paginate --jq '[.[] | .title]' 2>/dev/null || echo "[]")

  # Extract N from all sprint-MMYY-N format milestones
  local highest_n=0
  while IFS= read -r milestone; do
    if [[ "$milestone" =~ ^sprint-[0-9]{4}-([0-9]+)$ ]]; then
      local n="${BASH_REMATCH[1]}"
      if [ "$n" -gt "$highest_n" ]; then
        highest_n=$n
      fi
    fi
  done < <(echo "$all_milestones" | jq -r '.[]')

  # Next N is highest + 1
  echo $((highest_n + 1))
}

# Get count of closed milestones (excluding grandfathered)
# This is kept for informational purposes but next_n is based on highest existing
get_closed_milestone_count() {
  local all_closed
  all_closed=$(gh api repos/:owner/:repo/milestones --paginate --jq '[.[] | select(.state == "closed")] | length' 2>/dev/null || echo "0")

  # Count grandfathered milestones that are closed
  local grandfathered_closed=0
  for gf in "${GRANDFATHERED_NAMES[@]}"; do
    local is_closed
    is_closed=$(gh api repos/:owner/:repo/milestones --paginate --jq --arg name "$gf" '[.[] | select(.title == $name and .state == "closed")] | length' 2>/dev/null || echo "0")
    grandfathered_closed=$((grandfathered_closed + is_closed))
  done

  # Return non-grandfathered closed count
  echo $((all_closed - grandfathered_closed))
}

# Generate next milestone name
generate_next_name() {
  local next_n
  next_n=$(get_next_sequential_number)

  # Get current MMYY
  local mmyy
  mmyy=$(date +%m%y)

  local name="sprint-${mmyy}-${next_n}"

  local closed_count
  closed_count=$(get_closed_milestone_count)

  cat <<EOF
{
  "valid": true,
  "name": "$name",
  "next_n": $next_n,
  "mmyy": "$mmyy",
  "closed_count": $closed_count
}
EOF
}

# Validate milestone name format
validate_name() {
  local name="$1"

  # Check if grandfathered
  if is_grandfathered "$name"; then
    cat <<EOF
{
  "valid": true,
  "name": "$name",
  "reason": "Grandfathered milestone name"
}
EOF
    return 0
  fi

  # Check format: sprint-MMYY-N
  if ! [[ "$name" =~ ^sprint-[0-9]{4}-[0-9]+$ ]]; then
    cat <<EOF
{
  "valid": false,
  "name": "$name",
  "reason": "Invalid format. Expected: sprint-MMYY-N (e.g., sprint-0226-6)"
}
EOF
    return 1
  fi

  # Extract components
  local mmyy="${name#sprint-}"
  mmyy="${mmyy%-*}"
  local n="${name##*-}"

  # Validate MMYY format (basic check)
  local mm="${mmyy:0:2}"
  local yy="${mmyy:2:2}"

  if [ "$mm" -lt 1 ] || [ "$mm" -gt 12 ]; then
    cat <<EOF
{
  "valid": false,
  "name": "$name",
  "reason": "Invalid month in MMYY. Must be 01-12. Got: $mm"
}
EOF
    return 1
  fi

  # Check if N is reasonable (basic sanity check)
  if [ "$n" -lt 1 ]; then
    cat <<EOF
{
  "valid": false,
  "name": "$name",
  "reason": "Sequential number N must be >= 1. Got: $n"
}
EOF
    return 1
  fi

  # Check if this milestone already exists
  local milestone_exists
  milestone_exists=$(gh api repos/:owner/:repo/milestones --paginate 2>/dev/null | jq --arg name "$name" '[.[] | select(.title == $name)] | length' || echo "0")

  if [ "$milestone_exists" -gt 0 ]; then
    # Existing milestone - format is valid
    cat <<EOF
{
  "valid": true,
  "name": "$name",
  "mmyy": "$mmyy",
  "n": $n,
  "reason": "Valid milestone name (existing milestone)"
}
EOF
    return 0
  fi

  # Get expected next N (based on highest existing sprint number)
  local expected_n
  expected_n=$(get_next_sequential_number)

  # For new milestones, validate N matches expected sequence
  if [ "$n" != "$expected_n" ]; then
    local closed_count
    closed_count=$(get_closed_milestone_count)
    cat <<EOF
{
  "valid": false,
  "name": "$name",
  "reason": "Sequential number mismatch. Expected N=$expected_n (next in sequence), got N=$n. Use ./scripts/validate-milestone-name.sh to generate the correct next name.",
  "expected_n": $expected_n,
  "actual_n": $n,
  "closed_count": $closed_count
}
EOF
    return 1
  fi

  # All checks passed
  cat <<EOF
{
  "valid": true,
  "name": "$name",
  "mmyy": "$mmyy",
  "n": $n,
  "reason": "Valid milestone name (correct sequence)"
}
EOF
  return 0
}

# Parse arguments
CHECK_NAME=""
MODE="generate"

while [[ $# -gt 0 ]]; do
  case $1 in
    --check)
      CHECK_NAME="$2"
      MODE="validate"
      shift 2
      ;;
    --next)
      MODE="next"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      # Treat as milestone name
      CHECK_NAME="$1"
      MODE="validate"
      shift
      ;;
  esac
done

# Execute based on mode
case "$MODE" in
  generate)
    generate_next_name
    exit 0
    ;;
  next)
    next_n=$(get_next_sequential_number)
    closed_count=$(get_closed_milestone_count)
    cat <<EOF
{
  "next_n": $next_n,
  "closed_count": $closed_count
}
EOF
    exit 0
    ;;
  validate)
    if [ -z "$CHECK_NAME" ]; then
      echo "Error: No milestone name provided" >&2
      usage
      exit 2
    fi
    validate_name "$CHECK_NAME"
    exit $?
    ;;
esac
