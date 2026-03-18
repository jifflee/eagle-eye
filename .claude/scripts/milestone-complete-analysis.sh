#!/bin/bash
set -euo pipefail
# milestone-complete-analysis.sh
# Analyzes milestone issues for completion readiness: MVP-critical vs deferrable
#
# Usage:
#   ./scripts/milestone-complete-analysis.sh [milestone]
#   ./scripts/milestone-complete-analysis.sh --milestone "sprint-1/13"
#   ./scripts/milestone-complete-analysis.sh --json           # JSON output only
#   ./scripts/milestone-complete-analysis.sh --auto           # Auto-move deferrals
#   ./scripts/milestone-complete-analysis.sh --dry-run        # Preview without action
#
# MVP-Critical Detection Rules:
#   - P0 priority: Always critical
#   - In-progress status: Must complete (work already started)
#   - Dependency of MVP-critical: Required for critical item
#
# Deferrable Detection Rules:
#   - P1 epic with no progress: Can defer to future sprint
#   - P2/P3 any status: Lower priority, defer
#   - Optimization/tech-debt: Nice-to-have, defer
#
# Returns JSON:
# {
#   "milestone": "sprint-1/13",
#   "total_open": 39,
#   "analysis": {
#     "mvp_critical": [...],
#     "deferrable": [...],
#     "in_progress": [...]
#   },
#   "recommendation": {
#     "complete_count": 4,
#     "defer_count": 35,
#     "ready_to_close": false,
#     "blockers": [...]
#   }
# }

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

MILESTONE_NAME=""
JSON_ONLY=false
AUTO_MOVE=false
DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_NAME="$2"
      shift 2
      ;;
    --json)
      JSON_ONLY=true
      shift
      ;;
    --auto)
      AUTO_MOVE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -*)
      echo '{"error": "Unknown option: '"$1"'"}' >&2
      exit 2
      ;;
    *)
      MILESTONE_NAME="$1"
      shift
      ;;
  esac
done

# Create temp directory for intermediate files
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

# Get milestone if not specified (use earliest due date among open milestones)
if [ -z "$MILESTONE_NAME" ]; then
  MILESTONE_NAME=$(gh api repos/:owner/:repo/milestone-list --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty')
fi

if [ -z "$MILESTONE_NAME" ]; then
  echo '{"error": "No open milestones found"}'
  exit 1
fi

# Verify milestone exists and get metadata
MILESTONE_DATA=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.title=="'"$MILESTONE_NAME"'")')
if [ -z "$MILESTONE_DATA" ]; then
  echo '{"error": "Milestone not found: '"$MILESTONE_NAME"'"}'
  exit 1
fi

MILESTONE_NUMBER=$(echo "$MILESTONE_DATA" | jq -r '.number')

# Get all open issues for this milestone with full details
gh issue list --milestone "$MILESTONE_NAME" --state open \
  --json number,title,labels,body,createdAt,updatedAt \
  > "$TMPDIR/open_issues.json" 2>/dev/null || echo "[]" > "$TMPDIR/open_issues.json"

TOTAL_OPEN=$(jq length "$TMPDIR/open_issues.json")

# Function to check if issue has a specific label
has_label() {
  local issue="$1"
  local label="$2"
  echo "$issue" | jq -e --arg l "$label" '.labels | map(.name) | index($l) != null' >/dev/null 2>&1
}

# Function to get priority level (0, 1, 2, 3, or 99 for none)
get_priority() {
  local issue="$1"
  if echo "$issue" | jq -e '.labels | map(.name) | index("P0") != null' >/dev/null 2>&1; then
    echo 0
  elif echo "$issue" | jq -e '.labels | map(.name) | index("P1") != null' >/dev/null 2>&1; then
    echo 1
  elif echo "$issue" | jq -e '.labels | map(.name) | index("P2") != null' >/dev/null 2>&1; then
    echo 2
  elif echo "$issue" | jq -e '.labels | map(.name) | index("P3") != null' >/dev/null 2>&1; then
    echo 3
  else
    echo 99
  fi
}

# Function to check if issue is an epic
is_epic() {
  local issue="$1"
  echo "$issue" | jq -e '.labels | map(.name) | index("epic") != null' >/dev/null 2>&1
}

# Function to check if issue is tech-debt
is_tech_debt() {
  local issue="$1"
  echo "$issue" | jq -e '.labels | map(.name) | (index("tech-debt") != null or index("optimization") != null)' >/dev/null 2>&1
}

# Function to check if issue is in-progress
is_in_progress() {
  local issue="$1"
  echo "$issue" | jq -e '.labels | map(.name) | index("in-progress") != null' >/dev/null 2>&1
}

# Function to check if issue is blocked
is_blocked() {
  local issue="$1"
  echo "$issue" | jq -e '.labels | map(.name) | index("blocked") != null' >/dev/null 2>&1
}

# Arrays to collect classifications
> "$TMPDIR/mvp_critical.json"
> "$TMPDIR/deferrable.json"
> "$TMPDIR/in_progress.json"

echo "[" > "$TMPDIR/mvp_critical.json"
echo "[" > "$TMPDIR/deferrable.json"
echo "[" > "$TMPDIR/in_progress.json"

FIRST_CRITICAL=true
FIRST_DEFERRABLE=true
FIRST_INPROGRESS=true

# Track issue numbers that are MVP-critical (for dependency detection)
MVP_CRITICAL_NUMBERS=""

# First pass: Identify P0 and in-progress as critical
jq -c '.[]' "$TMPDIR/open_issues.json" | while read -r issue; do
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue" | jq -r '.title')
  PRIORITY=$(get_priority "$issue")

  # Check if P0 (always critical)
  if [ "$PRIORITY" -eq 0 ]; then
    REASON="P0 - highest priority"
    ACTION="complete"

    if [ "$FIRST_CRITICAL" = true ]; then
      FIRST_CRITICAL=false
    else
      echo "," >> "$TMPDIR/mvp_critical.json"
    fi

    jq -n \
      --argjson number "$NUMBER" \
      --arg title "$TITLE" \
      --arg reason "$REASON" \
      --arg action "$ACTION" \
      '{number: $number, title: $title, reason: $reason, action: $action}' >> "$TMPDIR/mvp_critical.json"

    echo "$NUMBER" >> "$TMPDIR/critical_numbers.txt"
  fi

  # Check if in-progress (must complete started work)
  if is_in_progress "$issue"; then
    # Find worktree if exists
    WORKTREE=$(find .. -maxdepth 1 -type d -name "*-issue-$NUMBER" 2>/dev/null | head -1 | xargs basename 2>/dev/null || echo "")

    if [ "$FIRST_INPROGRESS" = true ]; then
      FIRST_INPROGRESS=false
    else
      echo "," >> "$TMPDIR/in_progress.json"
    fi

    jq -n \
      --argjson number "$NUMBER" \
      --arg title "$TITLE" \
      --arg worktree "$WORKTREE" \
      '{number: $number, title: $title, worktree: $worktree}' >> "$TMPDIR/in_progress.json"

    # Add to critical if not P0 (P0 already added above)
    if [ "$PRIORITY" -ne 0 ]; then
      REASON="in-progress - work already started"
      ACTION="complete"

      if [ "$FIRST_CRITICAL" = true ]; then
        FIRST_CRITICAL=false
      else
        echo "," >> "$TMPDIR/mvp_critical.json"
      fi

      jq -n \
        --argjson number "$NUMBER" \
        --arg title "$TITLE" \
        --arg reason "$REASON" \
        --arg action "$ACTION" \
        '{number: $number, title: $title, reason: $reason, action: $action}' >> "$TMPDIR/mvp_critical.json"

      echo "$NUMBER" >> "$TMPDIR/critical_numbers.txt"
    fi
  fi
done

echo "]" >> "$TMPDIR/mvp_critical.json"
echo "]" >> "$TMPDIR/in_progress.json"

# Second pass: Classify remaining issues
FIRST_DEFERRABLE=true
jq -c '.[]' "$TMPDIR/open_issues.json" | while read -r issue; do
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue" | jq -r '.title')
  PRIORITY=$(get_priority "$issue")

  # Skip if already marked as critical (P0 or in-progress)
  if [ -f "$TMPDIR/critical_numbers.txt" ] && grep -q "^${NUMBER}$" "$TMPDIR/critical_numbers.txt" 2>/dev/null; then
    continue
  fi

  # Check if in-progress (already handled)
  if is_in_progress "$issue"; then
    continue
  fi

  # Classification logic
  REASON=""
  ACTION=""
  IS_DEFERRABLE=false

  # P2/P3: Always deferrable
  if [ "$PRIORITY" -ge 2 ]; then
    REASON="P$PRIORITY - lower priority"
    ACTION="move_to_backlog"
    IS_DEFERRABLE=true
  # P1 epic with no progress: Deferrable
  elif [ "$PRIORITY" -eq 1 ] && is_epic "$issue"; then
    REASON="P1 epic - no urgent children"
    ACTION="move_to_backlog"
    IS_DEFERRABLE=true
  # Tech-debt/optimization: Deferrable
  elif is_tech_debt "$issue"; then
    REASON="tech-debt/optimization - not functional"
    ACTION="move_to_backlog"
    IS_DEFERRABLE=true
  # Blocked: Deferrable (can't make progress anyway)
  elif is_blocked "$issue"; then
    REASON="blocked - cannot progress"
    ACTION="move_to_backlog"
    IS_DEFERRABLE=true
  # P1 non-epic: MVP-critical
  elif [ "$PRIORITY" -eq 1 ]; then
    REASON="P1 - high priority"
    ACTION="complete"
    IS_DEFERRABLE=false
  # No priority: Deferrable
  elif [ "$PRIORITY" -eq 99 ]; then
    REASON="no priority set - needs triage"
    ACTION="move_to_backlog"
    IS_DEFERRABLE=true
  fi

  if [ "$IS_DEFERRABLE" = true ]; then
    if [ "$FIRST_DEFERRABLE" = true ]; then
      FIRST_DEFERRABLE=false
    else
      echo "," >> "$TMPDIR/deferrable.json"
    fi

    jq -n \
      --argjson number "$NUMBER" \
      --arg title "$TITLE" \
      --arg reason "$REASON" \
      --arg action "$ACTION" \
      '{number: $number, title: $title, reason: $reason, action: $action}' >> "$TMPDIR/deferrable.json"
  elif [ -n "$REASON" ]; then
    # Add to MVP-critical
    echo "," >> "$TMPDIR/mvp_critical.json"
    # Remove the closing bracket, add item, re-add bracket
    # This is handled differently - we write to a separate file
    echo "$NUMBER|$TITLE|$REASON|$ACTION" >> "$TMPDIR/additional_critical.txt"
  fi
done

echo "]" >> "$TMPDIR/deferrable.json"

# Build final MVP-critical array including additional items
if [ -f "$TMPDIR/additional_critical.txt" ]; then
  # Read current mvp_critical (remove trailing ])
  head -c -2 "$TMPDIR/mvp_critical.json" > "$TMPDIR/mvp_critical_temp.json"

  FIRST_ADDITIONAL=true
  # Check if there are existing items
  if [ "$(jq 'length' "$TMPDIR/mvp_critical.json" 2>/dev/null)" -gt 0 ]; then
    FIRST_ADDITIONAL=false
  fi

  while IFS='|' read -r num title reason action; do
    if [ "$FIRST_ADDITIONAL" = true ]; then
      FIRST_ADDITIONAL=false
    else
      echo "," >> "$TMPDIR/mvp_critical_temp.json"
    fi
    jq -n \
      --argjson number "$num" \
      --arg title "$title" \
      --arg reason "$reason" \
      --arg action "$action" \
      '{number: $number, title: $title, reason: $reason, action: $action}' >> "$TMPDIR/mvp_critical_temp.json"
  done < "$TMPDIR/additional_critical.txt"

  echo "]" >> "$TMPDIR/mvp_critical_temp.json"
  mv "$TMPDIR/mvp_critical_temp.json" "$TMPDIR/mvp_critical.json"
fi

# Count results
CRITICAL_COUNT=$(jq 'length' "$TMPDIR/mvp_critical.json" 2>/dev/null || echo 0)
DEFERRABLE_COUNT=$(jq 'length' "$TMPDIR/deferrable.json" 2>/dev/null || echo 0)
INPROGRESS_COUNT=$(jq 'length' "$TMPDIR/in_progress.json" 2>/dev/null || echo 0)

# Determine readiness
READY_TO_CLOSE=false
BLOCKERS=""

if [ "$INPROGRESS_COUNT" -gt 0 ]; then
  BLOCKERS=$(jq -r '.[].number | "#\(.)"' "$TMPDIR/in_progress.json" | tr '\n' ',' | sed 's/,$//')
fi

if [ "$INPROGRESS_COUNT" -eq 0 ] && [ "$CRITICAL_COUNT" -eq 0 ]; then
  READY_TO_CLOSE=true
fi

# Build final JSON output
OUTPUT=$(jq -n \
  --arg milestone "$MILESTONE_NAME" \
  --argjson total_open "$TOTAL_OPEN" \
  --slurpfile mvp_critical "$TMPDIR/mvp_critical.json" \
  --slurpfile deferrable "$TMPDIR/deferrable.json" \
  --slurpfile in_progress "$TMPDIR/in_progress.json" \
  --argjson critical_count "$CRITICAL_COUNT" \
  --argjson defer_count "$DEFERRABLE_COUNT" \
  --argjson inprogress_count "$INPROGRESS_COUNT" \
  --argjson ready_to_close "$READY_TO_CLOSE" \
  --arg blockers "$BLOCKERS" \
  '{
    milestone: $milestone,
    total_open: $total_open,
    analysis: {
      mvp_critical: $mvp_critical[0],
      deferrable: $deferrable[0],
      in_progress: $in_progress[0]
    },
    recommendation: {
      complete_count: $critical_count,
      defer_count: $defer_count,
      in_progress_count: $inprogress_count,
      ready_to_close: $ready_to_close,
      blockers: (if $blockers == "" then [] else ($blockers | split(",")) end)
    }
  }')

# If auto-move requested, move deferrable issues to backlog milestone
if [ "$AUTO_MOVE" = true ] && [ "$DEFERRABLE_COUNT" -gt 0 ]; then
  if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would move $DEFERRABLE_COUNT issues to backlog milestone"
  else
    log_info "Moving $DEFERRABLE_COUNT deferrable issues to backlog..."

    # Get or create backlog milestone
    BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.title=="backlog") | .number' 2>/dev/null)

    if [ -z "$BACKLOG_NUMBER" ]; then
      log_info "Creating backlog milestone..."
      BACKLOG_NUMBER=$(gh api repos/:owner/:repo/milestone-list -X POST \
        -f title="backlog" \
        -f description="Unscheduled work: epics and features not assigned to an active sprint" \
        --jq '.number')
    fi

    # Move each deferrable issue
    jq -r '.[].number' "$TMPDIR/deferrable.json" | while read -r issue_num; do
      log_info "Moving #$issue_num to backlog..."
      gh issue edit "$issue_num" --milestone "backlog" --remove-label "in-progress" --add-label "backlog" 2>/dev/null || true
    done

    log_success "Moved $DEFERRABLE_COUNT issues to backlog"

    # Update output to reflect moves
    OUTPUT=$(echo "$OUTPUT" | jq '.actions_taken = {moved_to_backlog: '"$DEFERRABLE_COUNT"'}')
  fi
fi

# Output result
echo "$OUTPUT"
