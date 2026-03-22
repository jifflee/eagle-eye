#!/bin/bash
# auto-select-issue.sh
# Automatically selects the highest priority non-conflicting backlog issue(s)
# for autonomous sprint-work execution (feature #1253).
#
# Usage:
#   ./scripts/auto-select-issue.sh [OPTIONS]
#
# Options:
#   --dry-run          Show selection logic without launching
#   --json             Output JSON result
#   --max N            Override max parallel slots (default: from check-resource-capacity.sh)
#   --milestone TITLE  Use specific milestone (default: first open milestone)
#
# Output (JSON with --json):
# {
#   "selected": [42, 38],
#   "reason": "P1 issues with no running conflicts",
#   "available_slots": 2,
#   "skipped": [{"number":55,"reason":"in-progress"},{"number":42,"reason":"conflict"}],
#   "fallback_interactive": false
# }
#
# Exit codes:
#   0 = Success (check JSON "selected" array; may be empty if fallback needed)
#   1 = Error (capacity check failed, API error, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Argument parsing ───────────────────────────────────────────────────────────

DRY_RUN="false"
JSON_OUTPUT="false"
MAX_OVERRIDE=""
MILESTONE_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN="true"; shift ;;
    --json)          JSON_OUTPUT="true"; shift ;;
    --max)           MAX_OVERRIDE="$2"; shift 2 ;;
    --milestone)     MILESTONE_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | head -30 | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ────────────────────────────────────────────────────────────────────

log() { [[ "$JSON_OUTPUT" == "false" ]] && echo "$*" >&2 || true; }

# Get the numeric priority weight for a set of label names (JSON array string)
# Returns 0 (P0) through 4 (unset)
get_priority_weight() {
  local labels_json="$1"
  echo "$labels_json" | jq -r '
    if any(.[]; . == "P0") then 0
    elif any(.[]; . == "P1") then 1
    elif any(.[]; . == "P2") then 2
    elif any(.[]; . == "P3") then 3
    else 4 end'
}

# Get type rank within same priority (bug first)
get_type_rank() {
  local labels_json="$1"
  echo "$labels_json" | jq -r '
    if any(.[]; . == "bug")       then 0
    elif any(.[]; . == "feature") then 1
    elif any(.[]; . == "tech-debt") then 2
    elif any(.[]; . == "docs")    then 3
    else 4 end'
}

# ── Step 1: Resource capacity check ───────────────────────────────────────────

CAPACITY_SCRIPT="$SCRIPT_DIR/check-resource-capacity.sh"

if [[ ! -f "$CAPACITY_SCRIPT" ]]; then
  log "⚠️  check-resource-capacity.sh not found; assuming 2 local slots"
  CAPACITY_JSON='{"has_capacity":true,"max_containers":2,"running_containers":0,"environment":"local","reason":"script not found, assuming defaults"}'
else
  CAPACITY_JSON=$("$CAPACITY_SCRIPT" 2>/dev/null) || {
    log "⚠️  Capacity check failed; assuming 1 available slot (safe default)"
    CAPACITY_JSON='{"has_capacity":true,"max_containers":2,"running_containers":1,"environment":"local","reason":"capacity check error"}'
  }
fi

HAS_CAPACITY=$(echo "$CAPACITY_JSON" | jq -r '.has_capacity')
MAX_CONTAINERS=$(echo "$CAPACITY_JSON" | jq -r '.max_containers')
RUNNING_CONTAINERS=$(echo "$CAPACITY_JSON" | jq -r '.running_containers')

# Allow manual override
[[ -n "$MAX_OVERRIDE" ]] && MAX_CONTAINERS="$MAX_OVERRIDE"

AVAILABLE_SLOTS=$(( MAX_CONTAINERS - RUNNING_CONTAINERS ))
[[ "$AVAILABLE_SLOTS" -lt 0 ]] && AVAILABLE_SLOTS=0

if [[ "$HAS_CAPACITY" == "false" || "$AVAILABLE_SLOTS" -eq 0 ]]; then
  CAPACITY_REASON=$(echo "$CAPACITY_JSON" | jq -r '.reason')
  log "⚠️  No container slots available (${RUNNING_CONTAINERS}/${MAX_CONTAINERS} running)"
  log "    Reason: $CAPACITY_REASON"
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n \
      --argjson slots "$AVAILABLE_SLOTS" \
      --arg reason "$CAPACITY_REASON" \
      '{selected:[],available_slots:$slots,reason:$reason,skipped:[],fallback_interactive:true}'
  fi
  exit 0
fi

log "✅ Resource capacity: ${AVAILABLE_SLOTS} slot(s) available (${RUNNING_CONTAINERS}/${MAX_CONTAINERS} running)"

# ── Step 2: Query backlog ──────────────────────────────────────────────────────

if [[ -n "$MILESTONE_OVERRIDE" ]]; then
  MILESTONE="$MILESTONE_OVERRIDE"
else
  MILESTONE=$(gh api "repos/:owner/:repo/milestones" \
    --jq '.[] | select(.state=="open") | .title' 2>/dev/null | head -1 || true)
fi

if [[ -z "$MILESTONE" ]]; then
  log "⚠️  No open milestone found; falling back to interactive selection"
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n '{selected:[],available_slots:0,reason:"no open milestone",skipped:[],fallback_interactive:true}'
  fi
  exit 0
fi

log "📋 Querying backlog for milestone: $MILESTONE"

# Fetch backlog issues excluding skip labels
BACKLOG_JSON=$(gh issue list \
  --milestone "$MILESTONE" \
  --label "backlog" \
  --json number,title,labels,createdAt \
  --jq '[.[] | select(
    ([.labels[].name] | any(. == "blocked" or . == "in-progress" or . == "needs-triage")) | not
  ) | {
    number: .number,
    title:  .title,
    labels: [.labels[].name],
    createdAt: .createdAt
  }]' 2>/dev/null || echo "[]")

BACKLOG_COUNT=$(echo "$BACKLOG_JSON" | jq 'length')
log "  Found $BACKLOG_COUNT eligible backlog issues (skip-label filtered)"

if [[ "$BACKLOG_COUNT" -eq 0 ]]; then
  log "⚠️  No eligible backlog issues; falling back to interactive selection"
  if [[ "$JSON_OUTPUT" == "true" ]]; then
    jq -n '{selected:[],available_slots:'"$AVAILABLE_SLOTS"',reason:"no eligible backlog issues",skipped:[],fallback_interactive:true}'
  fi
  exit 0
fi

# ── Step 3: Detect active work (containers + worktrees) for file overlap ───────

CONTAINER_STATUS_SCRIPT="$SCRIPT_DIR/container/container-status.sh"
RUNNING_ISSUE_NUMS=()
declare -A RUNNING_FILE_SETS  # issue_num -> newline-sep file list

# Step 3a: Check running containers
if [[ -f "$CONTAINER_STATUS_SCRIPT" ]]; then
  CONTAINER_JSON=$("$CONTAINER_STATUS_SCRIPT" --json 2>/dev/null || echo '{"containers":[]}')
  while IFS= read -r running_issue; do
    [[ -z "$running_issue" ]] && continue
    RUNNING_ISSUE_NUMS+=("$running_issue")
    BRANCH="feat/issue-${running_issue}"
    CHANGED=$(git diff --name-only "origin/main...origin/${BRANCH}" 2>/dev/null || true)
    RUNNING_FILE_SETS["$running_issue"]="$CHANGED"
  done < <(echo "$CONTAINER_JSON" | jq -r '.containers[]? | select(.status=="running") | .issue // empty')
fi

# Step 3b: Check active worktrees (git worktree list)
# Extracts issue numbers from worktrees matching {repo}-issue-{N} naming convention
REPO_ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || echo "$REPO_ROOT")"
REPO_BASE_NAME="$(basename "$REPO_ROOT_DIR" | sed 's/-issue-[0-9]*$//')"

while IFS= read -r wt_line; do
  WORKTREE_PATH=$(echo "$wt_line" | awk '{print $1}')
  WORKTREE_DIR=$(basename "$WORKTREE_PATH")
  # Match pattern: {repo}-issue-{N}
  if [[ "$WORKTREE_DIR" =~ ${REPO_BASE_NAME}-issue-([0-9]+)$ ]]; then
    wt_issue="${BASH_REMATCH[1]}"
    # Skip if we already have this issue from container detection
    already_tracked=false
    for existing in "${RUNNING_ISSUE_NUMS[@]:-}"; do
      [[ "$existing" == "$wt_issue" ]] && already_tracked=true && break
    done
    if [[ "$already_tracked" == "false" ]]; then
      RUNNING_ISSUE_NUMS+=("$wt_issue")
      BRANCH="feat/issue-${wt_issue}"
      # Try to get changed files from local worktree diff first, then remote branch
      CHANGED=""
      if [[ -d "$WORKTREE_PATH" ]]; then
        CHANGED=$(cd "$WORKTREE_PATH" && git diff --name-only "origin/main" 2>/dev/null || true)
      fi
      [[ -z "$CHANGED" ]] && CHANGED=$(git diff --name-only "origin/main...origin/${BRANCH}" 2>/dev/null || true)
      RUNNING_FILE_SETS["$wt_issue"]="$CHANGED"
    fi
  fi
done < <(git worktree list 2>/dev/null || true)

log "  Active work items detected (containers + worktrees): ${#RUNNING_ISSUE_NUMS[@]}"

# Check if a candidate issue has file overlap with any running container
has_file_overlap() {
  local candidate="$1"
  local branch="feat/issue-${candidate}"
  local candidate_files
  candidate_files=$(git diff --name-only "origin/main...origin/${branch}" 2>/dev/null || true)

  # If no branch yet, we can't detect overlap — assume safe
  [[ -z "$candidate_files" ]] && return 1

  for running_issue in "${RUNNING_ISSUE_NUMS[@]}"; do
    local running_files="${RUNNING_FILE_SETS[$running_issue]:-}"
    [[ -z "$running_files" ]] && continue
    local overlap
    overlap=$(comm -12 \
      <(echo "$candidate_files" | sort -u) \
      <(echo "$running_files"   | sort -u) 2>/dev/null || true)
    [[ -n "$overlap" ]] && return 0  # Overlap detected
  done
  return 1  # No overlap
}

# ── Step 4: Auto-select by priority + type, respecting conflict/slot limits ────

SELECTED_ISSUES=()
SKIPPED_ISSUES=()
HIGHEST_PRIORITY_WEIGHT=""

# Sort backlog by priority weight, then type rank, then createdAt (oldest first)
SORTED_BACKLOG=$(echo "$BACKLOG_JSON" | jq -c '
  map(. + {
    priority_weight: (
      if ([.labels[]] | any(. == "P0")) then 0
      elif ([.labels[]] | any(. == "P1")) then 1
      elif ([.labels[]] | any(. == "P2")) then 2
      elif ([.labels[]] | any(. == "P3")) then 3
      else 4 end
    ),
    type_rank: (
      if ([.labels[]] | any(. == "bug"))       then 0
      elif ([.labels[]] | any(. == "feature")) then 1
      elif ([.labels[]] | any(. == "tech-debt")) then 2
      elif ([.labels[]] | any(. == "docs"))    then 3
      else 4 end
    )
  }) | sort_by(.priority_weight, .type_rank, .createdAt) | .[]')

while IFS= read -r issue_json; do
  [[ -z "$issue_json" ]] && continue

  num=$(echo "$issue_json"      | jq -r '.number')
  title=$(echo "$issue_json"    | jq -r '.title')
  pw=$(echo "$issue_json"       | jq -r '.priority_weight')
  labels_str=$(echo "$issue_json" | jq -r '[.labels[]] | join(",")')

  # Stop collecting if we've filled all slots
  if [[ "${#SELECTED_ISSUES[@]}" -ge "$AVAILABLE_SLOTS" ]]; then
    log "  ⏹️  Slot limit reached (${#SELECTED_ISSUES[@]}/${AVAILABLE_SLOTS})"
    break
  fi

  # If we have at least one selection, stop if priority drops
  if [[ -n "$HIGHEST_PRIORITY_WEIGHT" && "$pw" -gt "$HIGHEST_PRIORITY_WEIGHT" ]]; then
    log "  ⏹️  Priority dropped from P${HIGHEST_PRIORITY_WEIGHT} — stopping selection"
    break
  fi

  # File overlap check
  if has_file_overlap "$num"; then
    log "  ⏭️  #${num} '${title}' — skipped (file overlap with running container)"
    SKIPPED_ISSUES+=("{\"number\":${num},\"reason\":\"file overlap with running container\"}")
    continue
  fi

  log "  ✅ #${num} '${title}' (P${pw}, labels: ${labels_str}) — selected"
  SELECTED_ISSUES+=("$num")
  HIGHEST_PRIORITY_WEIGHT="$pw"
done < <(echo "$SORTED_BACKLOG")

# ── Step 5: Output result ──────────────────────────────────────────────────────

FALLBACK="false"
if [[ "${#SELECTED_ISSUES[@]}" -eq 0 ]]; then
  log ""
  log "⚠️  No suitable issues found. All eligible backlog issues are conflicting."
  log "    Falling back to interactive selection."
  FALLBACK="true"
fi

SKIPPED_JSON="[$(IFS=,; echo "${SKIPPED_ISSUES[*]:-}")]"
SELECTED_JSON="[$(IFS=,; echo "${SELECTED_ISSUES[*]:-}")]"

PRIORITY_LABEL="P${HIGHEST_PRIORITY_WEIGHT:-?}"
[[ -z "$HIGHEST_PRIORITY_WEIGHT" ]] && PRIORITY_LABEL="none"

REASON="Auto-selected ${#SELECTED_ISSUES[@]} ${PRIORITY_LABEL} issue(s) with no running conflicts"
[[ "$FALLBACK" == "true" ]] && REASON="No non-conflicting issues available; interactive selection required"

if [[ "$JSON_OUTPUT" == "true" ]]; then
  jq -n \
    --argjson selected "$SELECTED_JSON" \
    --argjson slots "$AVAILABLE_SLOTS" \
    --arg reason "$REASON" \
    --argjson skipped "$SKIPPED_JSON" \
    --argjson fallback "$FALLBACK" \
    '{
      selected: $selected,
      available_slots: $slots,
      reason: $reason,
      skipped: $skipped,
      fallback_interactive: $fallback
    }'
else
  echo ""
  echo "## Auto-Selected Issues"
  echo ""
  if [[ "$FALLBACK" == "false" ]]; then
    echo "Selected ${#SELECTED_ISSUES[@]} issue(s) for launch:"
    for n in "${SELECTED_ISSUES[@]}"; do
      ISSUE_INFO=$(echo "$BACKLOG_JSON" | jq -r --argjson n "$n" '.[] | select(.number == $n) | "  #\(.number) [\(.labels | join(", "))] \(.title)"')
      echo "$ISSUE_INFO"
    done
    echo ""
    echo "Available slots: ${AVAILABLE_SLOTS}/${MAX_CONTAINERS}"
    echo "Reason: $REASON"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo ""
      echo "(dry-run: no containers launched)"
    fi
  else
    echo "No issues auto-selected."
    echo "Reason: $REASON"
    echo ""
    echo "Skipped issues:"
    for s in "${SKIPPED_ISSUES[@]:-}"; do
      echo "  $s"
    done
  fi
fi

exit 0
