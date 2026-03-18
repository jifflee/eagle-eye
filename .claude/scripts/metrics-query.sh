#!/bin/bash
set -euo pipefail
# metrics-query.sh
# Query and analyze agent performance metrics from JSONL log
# size-ok: multi-filter query engine with dashboard, agent, model, phase, and date modes
#
# Usage:
#   ./scripts/metrics-query.sh                      # Dashboard summary
#   ./scripts/metrics-query.sh --agent NAME         # Filter by agent
#   ./scripts/metrics-query.sh --model MODEL        # Filter by model
#   ./scripts/metrics-query.sh --phase PHASE        # Filter by SDLC phase
#   ./scripts/metrics-query.sh --since DATE         # Filter by date (YYYY-MM-DD)
#   ./scripts/metrics-query.sh --until DATE         # Filter until date
#   ./scripts/metrics-query.sh --top-agents N       # Top N agents by tokens
#   ./scripts/metrics-query.sh --top-invocations N  # Most expensive invocations
#   ./scripts/metrics-query.sh --model-comparison   # Compare model efficiency
#   ./scripts/metrics-query.sh --raw                # Output raw filtered JSONL
#   ./scripts/metrics-query.sh --json               # Output summary as JSON
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - No metrics file found

set -e

# Configuration
# Detect main repo (even if in worktree) - metrics aggregate to main repo
get_main_repo() {
  local toplevel git_common main_git
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || echo "."

  if [ -f "$toplevel/.git" ]; then
    git_common=$(git rev-parse --git-common-dir 2>/dev/null)
    # Remove /worktrees/<name> suffix if present
    main_git="${git_common%/worktrees/*}"
    # Remove /.git suffix to get repo root
    echo "${main_git%/.git}"
  else
    echo "$toplevel"
  fi
}

MAIN_REPO=$(get_main_repo)
METRICS_DIR="${CLAUDE_METRICS_DIR:-$MAIN_REPO/.claude}"
METRICS_FILE="${CLAUDE_METRICS_FILE:-$METRICS_DIR/metrics.jsonl}"

# Parse arguments
AGENT_FILTER=""
MODEL_FILTER=""
PHASE_FILTER=""
ISSUE_FILTER=""
SINCE_DATE=""
UNTIL_DATE=""
TOP_AGENTS=""
TOP_INVOCATIONS=""
MODEL_COMPARISON=false
WORKTREE_SUMMARY=false
RAW_OUTPUT=false
JSON_OUTPUT=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_FILTER="$2"
      shift 2
      ;;
    --model)
      MODEL_FILTER="$2"
      shift 2
      ;;
    --phase)
      PHASE_FILTER="$2"
      shift 2
      ;;
    --issue)
      ISSUE_FILTER="$2"
      shift 2
      ;;
    --worktree-summary)
      WORKTREE_SUMMARY=true
      shift
      ;;
    --since)
      SINCE_DATE="$2"
      shift 2
      ;;
    --until)
      UNTIL_DATE="$2"
      shift 2
      ;;
    --top-agents)
      TOP_AGENTS="$2"
      shift 2
      ;;
    --top-invocations)
      TOP_INVOCATIONS="$2"
      shift 2
      ;;
    --model-comparison)
      MODEL_COMPARISON=true
      shift
      ;;
    --raw)
      RAW_OUTPUT=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --help|-h)
      SHOW_HELP=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Show help (before file existence check)
if [ "$SHOW_HELP" = true ]; then
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Filters:"
  echo "  --agent NAME         Filter by agent name"
  echo "  --model MODEL        Filter by model (haiku|sonnet|opus)"
  echo "  --phase PHASE        Filter by SDLC phase"
  echo "  --issue NUMBER       Filter by worktree issue number"
  echo "  --since DATE         Filter from date (YYYY-MM-DD)"
  echo "  --until DATE         Filter until date (YYYY-MM-DD)"
  echo ""
  echo "Reports:"
  echo "  --top-agents N       Show top N agents by token usage"
  echo "  --top-invocations N  Show N most expensive invocations"
  echo "  --model-comparison   Compare model efficiency"
  echo "  --worktree-summary   Show metrics grouped by worktree/issue"
  echo ""
  echo "Output:"
  echo "  --raw                Output raw filtered JSONL"
  echo "  --json               Output summary as JSON"
  exit 0
fi

# Validate numeric arguments
if [ -n "$TOP_AGENTS" ]; then
  if ! [[ "$TOP_AGENTS" =~ ^[0-9]+$ ]] || [ "$TOP_AGENTS" -le 0 ]; then
    echo "Error: --top-agents requires a positive integer" >&2
    exit 1
  fi
fi

if [ -n "$TOP_INVOCATIONS" ]; then
  if ! [[ "$TOP_INVOCATIONS" =~ ^[0-9]+$ ]] || [ "$TOP_INVOCATIONS" -le 0 ]; then
    echo "Error: --top-invocations requires a positive integer" >&2
    exit 1
  fi
fi

# Check if metrics file exists
if [ ! -f "$METRICS_FILE" ]; then
  echo "No metrics file found at $METRICS_FILE"
  echo "Run some agent invocations first to generate metrics."
  exit 2
fi

# =============================================================================
# READ-TIME SECURITY SANITIZATION (Issue #165)
# Defense-in-depth validation for metrics queries
# =============================================================================

# Field length limits for truncation (match write-time limits)
MAX_TASK_DESC_LEN=500
MAX_NOTES_LEN=1000

# Sanitize metrics file content by:
# 1. Skipping corrupt/invalid JSON lines
# 2. Truncating oversized text fields
# 3. Removing potentially dangerous patterns for display
#
# This creates a temporary sanitized view of the metrics file
sanitize_metrics_for_query() {
  local input_file="$1"

  # Use jq with error handling to process line-by-line
  # -R reads raw lines, -c outputs compact JSON
  # Invalid lines are silently skipped (try-catch in jq)
  jq -Rc '
    try (
      fromjson |
      # Truncate oversized fields (defense-in-depth)
      .task_description = (if .task_description then .task_description[0:500] else null end) |
      .notes = (if .notes then .notes[0:1000] else null end) |
      # Sanitize display fields by removing control characters
      # (Preserves printable ASCII and common unicode)
      .task_description = (if .task_description then .task_description | gsub("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]"; "") else null end) |
      .notes = (if .notes then .notes | gsub("[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F]"; "") else null end)
    ) catch empty
  ' "$input_file"
}

# Create a temporary sanitized file for queries
# This ensures all subsequent queries work with clean data
SANITIZED_METRICS=""
create_sanitized_metrics() {
  if [ -z "$SANITIZED_METRICS" ]; then
    SANITIZED_METRICS=$(mktemp) || {
      echo "Error: Failed to create temp file for sanitization" >&2
      exit 3
    }
    sanitize_metrics_for_query "$METRICS_FILE" > "$SANITIZED_METRICS"

    # Cleanup on exit
    trap 'rm -f "$SANITIZED_METRICS"' EXIT
  fi
}

# Use sanitized metrics by default (can be disabled for raw access)
USE_SANITIZED=true

# For --raw output, we can optionally skip sanitization
# (useful for debugging, but default to sanitized for safety)
if [ "$RAW_OUTPUT" = true ]; then
  # Still sanitize raw output for safety by default
  # Only skip if explicitly requested via environment variable
  if [ "${CLAUDE_METRICS_RAW_UNSAFE:-false}" = "true" ]; then
    USE_SANITIZED=false
  fi
fi

# Create sanitized view for queries
if [ "$USE_SANITIZED" = true ]; then
  create_sanitized_metrics
  QUERY_FILE="$SANITIZED_METRICS"
else
  QUERY_FILE="$METRICS_FILE"
fi

# =============================================================================
# END READ-TIME SECURITY SANITIZATION
# =============================================================================

# Build jq args array for safe filter passing (prevents injection)
JQ_ARGS=()
if [ -n "$AGENT_FILTER" ]; then
  JQ_ARGS+=(--arg agent_filter "$AGENT_FILTER")
fi
if [ -n "$MODEL_FILTER" ]; then
  JQ_ARGS+=(--arg model_filter "$MODEL_FILTER")
fi
if [ -n "$PHASE_FILTER" ]; then
  JQ_ARGS+=(--arg phase_filter "$PHASE_FILTER")
fi
if [ -n "$ISSUE_FILTER" ]; then
  JQ_ARGS+=(--arg issue_filter "$ISSUE_FILTER")
fi
if [ -n "$SINCE_DATE" ]; then
  JQ_ARGS+=(--arg since_date "${SINCE_DATE}T00:00:00Z")
fi
if [ -n "$UNTIL_DATE" ]; then
  JQ_ARGS+=(--arg until_date "${UNTIL_DATE}T23:59:59Z")
fi

# Build jq filter expression (uses variables safely)
JQ_FILTER="."
if [ -n "$AGENT_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.agent == \$agent_filter)"
fi
if [ -n "$MODEL_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.model == \$model_filter)"
fi
if [ -n "$PHASE_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.phase == \$phase_filter)"
fi
if [ -n "$ISSUE_FILTER" ]; then
  JQ_FILTER="$JQ_FILTER | select(.worktree_issue == \$issue_filter)"
fi
if [ -n "$SINCE_DATE" ]; then
  JQ_FILTER="$JQ_FILTER | select(.timestamp >= \$since_date)"
fi
if [ -n "$UNTIL_DATE" ]; then
  JQ_FILTER="$JQ_FILTER | select(.timestamp <= \$until_date)"
fi

# Output raw filtered data
if [ "$RAW_OUTPUT" = true ]; then
  jq -c "${JQ_ARGS[@]}" "$JQ_FILTER" "$QUERY_FILE"
  exit 0
fi

# Worktree summary report
if [ "$WORKTREE_SUMMARY" = true ]; then
  jq -s "${JQ_ARGS[@]}" "
    [.[] | $JQ_FILTER | select(.status == \"completed\")] |
    group_by(.worktree_issue // \"main\") |
    map({
      issue: (.[0].worktree_issue // \"main\"),
      invocations: length,
      total_tokens: (map(.tokens_total // 0) | add),
      total_duration_ms: (map(.duration_ms // 0) | add),
      avg_duration_min: (if length > 0 then ((map(.duration_ms // 0) | add) / length / 60000) | . * 10 | floor | . / 10 else 0 end),
      models: (group_by(.model) | map({model: .[0].model, count: length}) | sort_by(-.count)),
      agents: ([.[].agent] | unique | map(select(. != null)))
    }) |
    sort_by(-.invocations)
  " "$QUERY_FILE"
  exit 0
fi

# Model comparison report
if [ "$MODEL_COMPARISON" = true ]; then
  jq -s "${JQ_ARGS[@]}" "
    [.[] | $JQ_FILTER | select(.status == \"completed\")] |
    group_by(.model) |
    map({
      model: .[0].model,
      count: length,
      total_tokens: (map(.tokens_total // 0) | add),
      avg_tokens: (if length > 0 then (map(.tokens_total // 0) | add) / length | floor else 0 end),
      total_duration_ms: (map(.duration_ms // 0) | add),
      avg_duration_ms: (if length > 0 then (map(.duration_ms // 0) | add) / length | floor else 0 end)
    }) |
    sort_by(-.total_tokens)
  " "$QUERY_FILE"
  exit 0
fi

# Top agents report
if [ -n "$TOP_AGENTS" ]; then
  jq -s "${JQ_ARGS[@]}" --argjson n "$TOP_AGENTS" "
    [.[] | $JQ_FILTER | select(.agent != null and .status == \"completed\")] |
    group_by(.agent) |
    map({
      agent: .[0].agent,
      invocations: length,
      total_tokens: (map(.tokens_total // 0) | add),
      avg_tokens: (if length > 0 then (map(.tokens_total // 0) | add) / length | floor else 0 end),
      total_duration_ms: (map(.duration_ms // 0) | add),
      avg_duration_min: (if length > 0 then ((map(.duration_ms // 0) | add) / length / 60000) | . * 10 | floor | . / 10 else 0 end)
    }) |
    sort_by(-.total_tokens) |
    .[:\$n]
  " "$QUERY_FILE"
  exit 0
fi

# Top invocations report
if [ -n "$TOP_INVOCATIONS" ]; then
  jq -s "${JQ_ARGS[@]}" --argjson n "$TOP_INVOCATIONS" "
    [.[] | $JQ_FILTER | select(.status == \"completed\")] |
    sort_by(-(.tokens_total // 0)) |
    .[:\$n] |
    map({
      timestamp: .timestamp,
      agent: .agent,
      skill: .skill,
      model: .model,
      tokens_total: .tokens_total,
      duration_min: ((.duration_ms // 0) / 60000 | . * 10 | floor | . / 10),
      task: .task_description,
      commit: .git_commit
    })
  " "$QUERY_FILE"
  exit 0
fi

# Default: Dashboard summary
if [ "$JSON_OUTPUT" = true ]; then
  # JSON output for programmatic use
  jq -s "${JQ_ARGS[@]}" "
    [.[] | $JQ_FILTER] |
    {
      total_invocations: length,
      completed: [.[] | select(.status == \"completed\")] | length,
      in_progress: [.[] | select(.status == \"in_progress\")] | length,
      blocked: [.[] | select(.status == \"blocked\")] | length,
      error: [.[] | select(.status == \"error\")] | length,
      total_tokens: ([.[] | .tokens_total // 0] | add),
      total_duration_ms: ([.[] | .duration_ms // 0] | add),
      avg_tokens_per_invocation: (if length > 0 then ([.[] | .tokens_total // 0] | add) / length | floor else 0 end),
      avg_duration_ms: (if length > 0 then ([.[] | .duration_ms // 0] | add) / length | floor else 0 end),
      models: (
        [.[] | select(.status == \"completed\")] |
        group_by(.model) |
        map({
          model: .[0].model,
          count: length,
          percentage: 0,
          tokens: (map(.tokens_total // 0) | add)
        }) |
        . as \$models |
        (\$models | map(.count) | add) as \$total |
        \$models | map(. + {percentage: (if \$total > 0 then (.count / \$total * 100 | floor) else 0 end)})
      ),
      agents: (
        [.[] | select(.agent != null and .status == \"completed\")] |
        group_by(.agent) |
        map({
          agent: .[0].agent,
          count: length,
          tokens: (map(.tokens_total // 0) | add)
        }) |
        sort_by(-.tokens)
      ),
      phases: (
        [.[] | select(.status == \"completed\")] |
        group_by(.phase) |
        map({
          phase: .[0].phase,
          count: length,
          tokens: (map(.tokens_total // 0) | add)
        }) |
        sort_by(-.tokens)
      ),
      date_range: {
        earliest: (sort_by(.timestamp) | first | .timestamp),
        latest: (sort_by(.timestamp) | last | .timestamp)
      }
    }
  " "$QUERY_FILE"
else
  # Human-readable dashboard
  jq -rs "${JQ_ARGS[@]}" "
    def format_tokens: . | tostring | split(\"\") | reverse | [range(0;length;3) as \$i | .[(\$i):(\$i+3)]] | map(reverse | join(\"\")) | reverse | join(\",\");
    def format_duration: . / 60000 | . * 10 | floor | . / 10 | tostring + \" min\";

    [.[] | $JQ_FILTER] |
    . as \$all |
    (\$all | length) as \$total |
    ([\$all[] | select(.status == \"completed\")] | length) as \$completed |

    \"CLAUDE CODE AGENT METRICS DASHBOARD\",
    \"=====================================\",
    \"\",
    \"SUMMARY\",
    \"-------\",
    \"Total Invocations: \(\$total)\",
    \"Completed:         \(\$completed)\",
    \"In Progress:       \([\$all[] | select(.status == \"in_progress\")] | length)\",
    \"Blocked/Error:     \([\$all[] | select(.status == \"blocked\" or .status == \"error\")] | length)\",
    \"\",
    \"Total Tokens:      \(([\$all[] | .tokens_total // 0] | add) | format_tokens)\",
    \"Avg Tokens/Inv:    \((if \$total > 0 then ([\$all[] | .tokens_total // 0] | add) / \$total | floor else 0 end) | format_tokens)\",
    \"Total Duration:    \(([\$all[] | .duration_ms // 0] | add) | format_duration)\",
    \"\",
    \"MODEL USAGE\",
    \"-----------\",
    (
      [\$all[] | select(.status == \"completed\")] |
      group_by(.model) |
      . as \$groups |
      (map(length) | add) as \$model_total |
      \$groups | map(
        \"\\(.[0].model | . + (\" \" * (10 - (. | length)))): \\(length) invocations (\\(if \$model_total > 0 then (length / \$model_total * 100 | floor) else 0 end)%) - \\((map(.tokens_total // 0) | add) | format_tokens) tokens\"
      ) | .[]
    ),
    \"\",
    \"TOP AGENTS (by tokens)\",
    \"----------------------\",
    (
      [\$all[] | select(.agent != null and .status == \"completed\")] |
      group_by(.agent) |
      map({agent: .[0].agent, tokens: (map(.tokens_total // 0) | add), count: length}) |
      sort_by(-.tokens) |
      .[:5] |
      to_entries |
      map(\"\\(.key + 1). \\(.value.agent): \\(.value.tokens | format_tokens) tokens (\\(.value.count) invocations)\") |
      .[]
    ),
    \"\",
    \"PHASES\",
    \"------\",
    (
      [\$all[] | select(.status == \"completed\")] |
      group_by(.phase) |
      map({phase: .[0].phase, tokens: (map(.tokens_total // 0) | add), count: length}) |
      sort_by(-.tokens) |
      map(\"\\(.phase): \\(.tokens | format_tokens) tokens (\\(.count) invocations)\") |
      .[]
    )
  " "$QUERY_FILE"
fi
