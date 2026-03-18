#!/bin/bash
set -euo pipefail
# action-audit-data.sh
# Query and analyze the action audit log for skill/agent operations
#
# Usage:
#   ./scripts/audit-actions-data.sh                       # Dashboard summary (JSON)
#   ./scripts/audit-actions-data.sh --tier T3             # Filter by tier
#   ./scripts/audit-actions-data.sh --skill sprint-work   # Filter by skill/source
#   ./scripts/audit-actions-data.sh --session ID          # Session timeline
#   ./scripts/audit-actions-data.sh --since YYYY-MM-DD    # Date filter
#   ./scripts/audit-actions-data.sh --failures            # Failed actions only
#   ./scripts/audit-actions-data.sh --unapproved          # Unapproved actions
#   ./scripts/audit-actions-data.sh --policy-suggest      # Generate policy recommendations
#   ./scripts/audit-actions-data.sh --category github     # Filter by category
#   ./scripts/audit-actions-data.sh --json                # Full JSON output (default)
#   ./scripts/audit-actions-data.sh --raw                 # Raw filtered JSONL
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - No action log found

set -e

# Configuration - detect main repo (even if in worktree)
get_main_repo() {
  local toplevel git_common main_git
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo "."

  if [ -f "$toplevel/.git" ]; then
    git_common=$(git rev-parse --git-common-dir 2>/dev/null)
    main_git="${git_common%/worktrees/*}"
    echo "${main_git%/.git}"
  else
    echo "$toplevel"
  fi
}

MAIN_REPO=$(get_main_repo)
ACTIONS_DIR="${CLAUDE_ACTIONS_DIR:-$MAIN_REPO/.claude}"
ACTIONS_FILE="${CLAUDE_ACTIONS_FILE:-$ACTIONS_DIR/actions.jsonl}"

# Parse arguments
TIER_FILTER=""
SKILL_FILTER=""
SESSION_FILTER=""
CATEGORY_FILTER=""
SINCE_DATE=""
UNTIL_DATE=""
FAILURES_ONLY=false
UNAPPROVED_ONLY=false
POLICY_SUGGEST=false
RAW_OUTPUT=false
JSON_OUTPUT=true
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --tier) TIER_FILTER="$2"; shift 2 ;;
    --skill) SKILL_FILTER="$2"; shift 2 ;;
    --session) SESSION_FILTER="$2"; shift 2 ;;
    --category) CATEGORY_FILTER="$2"; shift 2 ;;
    --since) SINCE_DATE="$2"; shift 2 ;;
    --until) UNTIL_DATE="$2"; shift 2 ;;
    --failures) FAILURES_ONLY=true; shift ;;
    --unapproved) UNAPPROVED_ONLY=true; shift ;;
    --policy-suggest) POLICY_SUGGEST=true; shift ;;
    --raw) RAW_OUTPUT=true; JSON_OUTPUT=false; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  echo "Usage: ./scripts/audit-actions-data.sh [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --tier T0|T1|T2|T3    Filter by permission tier"
  echo "  --skill NAME          Filter by source skill/agent"
  echo "  --session ID          Filter by session ID"
  echo "  --category NAME       Filter by action category (github|git|file|shell|api)"
  echo "  --since YYYY-MM-DD    Filter from date"
  echo "  --until YYYY-MM-DD    Filter until date"
  echo "  --failures            Show only failed actions"
  echo "  --unapproved          Show actions without approval"
  echo "  --policy-suggest      Generate auto-approve recommendations"
  echo "  --raw                 Output raw filtered JSONL"
  echo "  --json                Output structured JSON (default)"
  echo "  --help, -h            Show this help"
  exit 0
fi

# Validate date format (YYYY-MM-DD)
validate_date() {
  if ! [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: Invalid date format: $1 (use YYYY-MM-DD)" >&2
    exit 1
  fi
}

if [ -n "$SINCE_DATE" ]; then
  validate_date "$SINCE_DATE"
fi
if [ -n "$UNTIL_DATE" ]; then
  validate_date "$UNTIL_DATE"
fi

# Check if actions file exists
if [ ! -f "$ACTIONS_FILE" ]; then
  if [ "$JSON_OUTPUT" = true ]; then
    echo '{"error": "no_actions_file", "message": "No action audit log found", "path": "'"$ACTIONS_FILE"'"}'
  else
    echo "No action audit log found at: $ACTIONS_FILE" >&2
  fi
  exit 2
fi

# Build safe jq args and filter (prevents injection via --arg)
JQ_ARGS=()
JQ_FILTER="."

if [ -n "$TIER_FILTER" ]; then
  JQ_ARGS+=(--arg tier_filter "$TIER_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.tier.assigned == \$tier_filter)"
fi

if [ -n "$SKILL_FILTER" ]; then
  JQ_ARGS+=(--arg skill_filter "$SKILL_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.source.name == \$skill_filter)"
fi

if [ -n "$SESSION_FILTER" ]; then
  JQ_ARGS+=(--arg session_filter "$SESSION_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.session_id == \$session_filter)"
fi

if [ -n "$CATEGORY_FILTER" ]; then
  JQ_ARGS+=(--arg category_filter "$CATEGORY_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.action.category == \$category_filter)"
fi

if [ -n "$SINCE_DATE" ]; then
  JQ_ARGS+=(--arg since_date "${SINCE_DATE}T00:00:00Z")
  JQ_FILTER="$JQ_FILTER | select(.timestamp >= \$since_date)"
fi

if [ -n "$UNTIL_DATE" ]; then
  JQ_ARGS+=(--arg until_date "${UNTIL_DATE}T23:59:59Z")
  JQ_FILTER="$JQ_FILTER | select(.timestamp <= \$until_date)"
fi

if [ "$FAILURES_ONLY" = true ]; then
  JQ_FILTER="$JQ_FILTER | select(.result.status == \"failure\")"
fi

if [ "$UNAPPROVED_ONLY" = true ]; then
  JQ_FILTER="$JQ_FILTER | select(.approval.approved == false or .approval == null)"
fi

# Raw output mode
if [ "$RAW_OUTPUT" = true ]; then
  jq -c "${JQ_ARGS[@]}" "$JQ_FILTER" "$ACTIONS_FILE"
  exit 0
fi

# Policy suggestion mode
if [ "$POLICY_SUGGEST" = true ]; then
  jq -s '
    # Group by operation
    group_by(.action.operation) |
    map({
      operation: .[0].action.operation,
      category: .[0].action.category,
      source: .[0].source.name,
      current_tier: .[0].tier.assigned,
      total_invocations: length,
      success_count: map(select(.result.status == "success")) | length,
      failure_count: map(select(.result.status == "failure")) | length,
      success_rate: ((map(select(.result.status == "success")) | length) / length * 100 | floor),
      blocked_count: map(select(.result.status == "blocked")) | length,
      user_cancelled: map(select(.result.status == "cancelled")) | length,
      reversible: (.[0].tier.reasons | if . then (. | index("irreversible") | not) else true end)
    }) |
    sort_by(-.total_invocations) |
    {
      total_operations: (map(.total_invocations) | add),
      unique_operations: length,
      recommendations: {
        promote_to_t0: map(select(
          .success_rate >= 100 and .total_invocations >= 10 and .reversible == true and
          (.current_tier == "T1" or .current_tier == "T2")
        )),
        promote_to_t1: map(select(
          .success_rate >= 95 and .total_invocations >= 5 and .reversible == true and
          (.current_tier == "T2" or .current_tier == "T3")
        )),
        keep_t2: map(select(
          .success_rate >= 90 and .success_rate < 100 and
          .user_cancelled > 0
        )),
        keep_t3: map(select(
          .reversible == false or .success_rate < 90 or
          .failure_count > 2
        ))
      },
      all_operations: .
    }
  ' <(jq -c "${JQ_ARGS[@]}" "$JQ_FILTER" "$ACTIONS_FILE")
  exit 0
fi

# Session timeline mode
if [ -n "$SESSION_FILTER" ]; then
  jq -s '
    if length == 0 then
      {session_id: null, start_time: null, end_time: null, total_actions: 0, actions: []}
    else
      sort_by(.timestamp) |
      {
        session_id: .[0].session_id,
        start_time: .[0].timestamp,
        end_time: .[-1].timestamp,
        total_actions: length,
        actions: map({
          timestamp: .timestamp,
          source: .source.name,
          category: .action.category,
          operation: .action.operation,
          tier: .tier.assigned,
          status: .result.status,
          duration_ms: .result.duration_ms
        })
      }
    end
  ' <(jq -c "${JQ_ARGS[@]}" "$JQ_FILTER" "$ACTIONS_FILE")
  exit 0
fi

# Dashboard mode (default)
jq -s '
  if length == 0 then
    {total_actions: 0, period: {earliest: "N/A", latest: "N/A"}, by_tier: [], by_category: [], by_source: [], by_status: [], recent_t3: [], sessions: 0}
  else
  {
    total_actions: length,
    period: {
      earliest: (sort_by(.timestamp) | first | .timestamp),
      latest: (sort_by(.timestamp) | last | .timestamp)
    },
    by_tier: (group_by(.tier.assigned) | map({
      tier: .[0].tier.assigned,
      count: length,
      auto_approved: (map(select(.approval.auto_approved == true)) | length)
    }) | sort_by(.tier)),
    by_category: (group_by(.action.category) | map({
      category: .[0].action.category,
      count: length,
      operations: (group_by(.action.operation) | map({
        operation: .[0].action.operation,
        count: length
      }) | sort_by(-.count) | .[0:5])
    }) | sort_by(-.count)),
    by_source: (group_by(.source.name) | map({
      source: .[0].source.name,
      count: length,
      categories: (group_by(.action.category) | map({
        category: .[0].action.category,
        count: length
      }))
    }) | sort_by(-.count) | .[0:10]),
    by_status: (group_by(.result.status) | map({
      status: .[0].result.status,
      count: length
    })),
    recent_t3: (
      map(select(.tier.assigned == "T3")) |
      sort_by(.timestamp) |
      reverse |
      .[0:10] |
      map({
        timestamp: .timestamp,
        source: .source.name,
        operation: .action.operation,
        status: .result.status
      })
    ),
    sessions: (group_by(.session_id) | length)
  }
  end
' <(jq -c "${JQ_ARGS[@]}" "$JQ_FILTER" "$ACTIONS_FILE")
