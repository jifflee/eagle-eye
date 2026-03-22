#!/usr/bin/env bash
set -euo pipefail
# milestone-checkpoint-check.sh
# Checks milestone progress and determines if a 25% promotion checkpoint has been reached.
#
# DESCRIPTION:
#   After a PR is merged to dev, this script evaluates the current milestone completion
#   percentage and determines whether a 25%, 50%, 75%, or 100% checkpoint has been crossed
#   that hasn't been promoted yet. Used to trigger the automated dev→qa checkpoint pipeline.
#
# USAGE:
#   ./scripts/milestone-checkpoint-check.sh                      # Check active milestone
#   ./scripts/milestone-checkpoint-check.sh --milestone "NAME"   # Check specific milestone
#   ./scripts/milestone-checkpoint-check.sh --dry-run            # Preview without action
#   ./scripts/milestone-checkpoint-check.sh --json               # JSON output only
#
# OUTPUT JSON:
#   {
#     "should_promote": true|false,
#     "threshold": 25|50|75|100,
#     "current_pct": 62,
#     "last_promoted_pct": 50,
#     "milestone": { "number": 1, "title": "sprint-1" },
#     "reason": "Milestone reached 75% checkpoint (62% → 75%)",
#     "block_reason": null
#   }
#
# CHECKPOINT DETECTION:
#   - Thresholds: 25%, 50%, 75%, 100%
#   - Looks for existing checkpoint PRs to determine last promoted threshold
#   - PR title pattern: "release: Milestone {name} - {pct}% checkpoint"
#   - A threshold is triggered when current_pct >= threshold AND no PR exists for that threshold

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MILESTONE_NAME=""
DRY_RUN=false
JSON_OUTPUT=false
THRESHOLDS=(25 50 75 100)

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --milestone)
      MILESTONE_NAME="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
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

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() {
  if [ "$JSON_OUTPUT" = false ]; then
    echo "$*" >&2
  fi
}

# Get active or named milestone data
get_milestone() {
  local name="$1"
  if [ -n "$name" ]; then
    gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$name\")" 2>/dev/null
  else
    gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on // "9999") | .[0]' 2>/dev/null
  fi
}

# Check for existing checkpoint PRs for a given milestone + threshold
# Returns PR number if found, empty string otherwise
find_checkpoint_pr() {
  local milestone_title="$1"
  local threshold="$2"
  local pr_title_pattern="release: Milestone ${milestone_title} - ${threshold}% checkpoint"

  gh pr list \
    --search "\"${pr_title_pattern}\" in:title" \
    --state all \
    --json number,title \
    --jq ".[] | select(.title | contains(\"${pr_title_pattern}\")) | .number" \
    2>/dev/null | head -1 || echo ""
}

# Get the highest threshold that has already been promoted for this milestone
get_last_promoted_threshold() {
  local milestone_title="$1"
  local last=0

  for threshold in "${THRESHOLDS[@]}"; do
    local pr_num
    pr_num=$(find_checkpoint_pr "$milestone_title" "$threshold")
    if [ -n "$pr_num" ]; then
      last=$threshold
    fi
  done

  echo "$last"
}

# ─── Main Logic ──────────────────────────────────────────────────────────────

# Fetch latest
git fetch origin 2>/dev/null || true

# Get milestone data
log "Checking milestone progress..."
milestone_data=$(get_milestone "$MILESTONE_NAME")

if [ -z "$milestone_data" ] || [ "$milestone_data" = "null" ]; then
  jq -n \
    --arg reason "No open milestone found${MILESTONE_NAME:+ matching '$MILESTONE_NAME'}" \
    '{should_promote: false, threshold: null, current_pct: 0, last_promoted_pct: 0,
      milestone: null, reason: null, block_reason: $reason}'
  exit 0
fi

milestone_title=$(echo "$milestone_data" | jq -r '.title')
milestone_number=$(echo "$milestone_data" | jq -r '.number')
open_issues=$(echo "$milestone_data" | jq -r '.open_issues')
closed_issues=$(echo "$milestone_data" | jq -r '.closed_issues')
total_issues=$((open_issues + closed_issues))

# Calculate current completion percentage
current_pct=0
if [ "$total_issues" -gt 0 ]; then
  current_pct=$((closed_issues * 100 / total_issues))
fi

log "Milestone: ${milestone_title} (${closed_issues}/${total_issues} issues = ${current_pct}%)"

# Get last promoted threshold
last_promoted=$(get_last_promoted_threshold "$milestone_title")
log "Last promoted checkpoint: ${last_promoted}%"

# Find the next threshold to promote
next_threshold=0
for threshold in "${THRESHOLDS[@]}"; do
  if [ "$current_pct" -ge "$threshold" ] && [ "$threshold" -gt "$last_promoted" ]; then
    next_threshold=$threshold
    # Keep going to find the highest applicable threshold
  fi
done

# Build output
milestone_json=$(jq -n \
  --argjson number "$milestone_number" \
  --arg title "$milestone_title" \
  --argjson open "$open_issues" \
  --argjson closed "$closed_issues" \
  --argjson total "$total_issues" \
  --argjson pct "$current_pct" \
  '{number: $number, title: $title, open_issues: $open, closed_issues: $closed,
    total_issues: $total, completion_pct: $pct}')

if [ "$next_threshold" -eq 0 ]; then
  # No new checkpoint reached
  if [ "$DRY_RUN" = true ]; then
    log "→ No new checkpoint reached (current: ${current_pct}%, last promoted: ${last_promoted}%)"
  fi
  jq -n \
    --argjson milestone "$milestone_json" \
    --argjson current_pct "$current_pct" \
    --argjson last_promoted "$last_promoted" \
    --arg reason "No new checkpoint: current=${current_pct}%, last_promoted=${last_promoted}%" \
    '{should_promote: false, threshold: null, current_pct: $current_pct,
      last_promoted_pct: $last_promoted, milestone: $milestone,
      reason: null, block_reason: $reason}'
  exit 0
fi

# A new threshold was reached
log "→ New checkpoint reached: ${next_threshold}% (current: ${current_pct}%, last: ${last_promoted}%)"

if [ "$DRY_RUN" = true ]; then
  log ""
  log "[dry-run] Would trigger dev→qa checkpoint pipeline for ${next_threshold}% threshold"
  log "[dry-run] PR title would be: 'release: Milestone ${milestone_title} - ${next_threshold}% checkpoint'"
fi

jq -n \
  --argjson milestone "$milestone_json" \
  --argjson threshold "$next_threshold" \
  --argjson current_pct "$current_pct" \
  --argjson last_promoted "$last_promoted" \
  --arg reason "Milestone '${milestone_title}' reached ${next_threshold}% checkpoint (${current_pct}% complete, last promoted: ${last_promoted}%)" \
  '{should_promote: true, threshold: $threshold, current_pct: $current_pct,
    last_promoted_pct: $last_promoted, milestone: $milestone,
    reason: $reason, block_reason: null}'
