#!/bin/bash
# compliance-query.sh
# Query and analyze agent compliance violations from metrics.jsonl
# size-ok: compliance dashboard with agent ranking, trend analysis, and filtering
#
# Usage:
#   ./scripts/compliance-query.sh                     # Dashboard: all compliance data
#   ./scripts/compliance-query.sh --agent NAME        # Filter by agent
#   ./scripts/compliance-query.sh --type TYPE         # Filter by violation type
#   ./scripts/compliance-query.sh --severity LEVEL    # Filter by severity
#   ./scripts/compliance-query.sh --since DATE        # Filter from date (YYYY-MM-DD)
#   ./scripts/compliance-query.sh --top-agents N      # Top N violating agents
#   ./scripts/compliance-query.sh --trends            # Show trends over time
#   ./scripts/compliance-query.sh --json              # Output as JSON
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - No metrics file found / no compliance data

set -euo pipefail

# Detect main repo (even if in worktree)
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
METRICS_DIR="${CLAUDE_METRICS_DIR:-$MAIN_REPO/.claude}"
METRICS_FILE="${CLAUDE_METRICS_FILE:-$METRICS_DIR/metrics.jsonl}"

# Parse arguments
AGENT_FILTER=""
TYPE_FILTER=""
SEVERITY_FILTER=""
SINCE_DATE=""
UNTIL_DATE=""
TOP_AGENTS=""
SHOW_TRENDS=false
JSON_OUTPUT=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --agent)
      AGENT_FILTER="$2"
      shift 2
      ;;
    --type)
      TYPE_FILTER="$2"
      shift 2
      ;;
    --severity)
      SEVERITY_FILTER="$2"
      shift 2
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
    --trends)
      SHOW_TRENDS=true
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

if [ "$SHOW_HELP" = true ]; then
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Filters:"
  echo "  --agent NAME         Filter by agent name"
  echo "  --type TYPE          Filter by violation type (lint|format|naming|size|security|structure)"
  echo "  --severity LEVEL     Filter by severity (error|warning|info)"
  echo "  --since DATE         Filter from date (YYYY-MM-DD)"
  echo "  --until DATE         Filter until date (YYYY-MM-DD)"
  echo ""
  echo "Reports:"
  echo "  --top-agents N       Show top N agents by violation count"
  echo "  --trends             Show violation trends over time (daily buckets)"
  echo ""
  echo "Output:"
  echo "  --json               Output as JSON"
  exit 0
fi

# Validate numeric argument
if [ -n "$TOP_AGENTS" ]; then
  if ! [[ "$TOP_AGENTS" =~ ^[0-9]+$ ]] || [ "$TOP_AGENTS" -le 0 ]; then
    echo "Error: --top-agents requires a positive integer" >&2
    exit 1
  fi
fi

# Check if metrics file exists
if [ ! -f "$METRICS_FILE" ]; then
  echo "No metrics file found at $METRICS_FILE"
  echo "Run some agent invocations first to generate metrics."
  exit 2
fi

# Build jq filter for compliance events
JQ_ARGS=()
JQ_FILTER='select(.event_type == "compliance_violation")'

if [ -n "$AGENT_FILTER" ]; then
  JQ_ARGS+=(--arg agent_filter "$AGENT_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.agent == \$agent_filter)"
fi
if [ -n "$TYPE_FILTER" ]; then
  JQ_ARGS+=(--arg type_filter "$TYPE_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.violation_type == \$type_filter)"
fi
if [ -n "$SEVERITY_FILTER" ]; then
  JQ_ARGS+=(--arg severity_filter "$SEVERITY_FILTER")
  JQ_FILTER="$JQ_FILTER | select(.severity == \$severity_filter)"
fi
if [ -n "$SINCE_DATE" ]; then
  JQ_ARGS+=(--arg since_date "${SINCE_DATE}T00:00:00Z")
  JQ_FILTER="$JQ_FILTER | select(.timestamp >= \$since_date)"
fi
if [ -n "$UNTIL_DATE" ]; then
  JQ_ARGS+=(--arg until_date "${UNTIL_DATE}T23:59:59Z")
  JQ_FILTER="$JQ_FILTER | select(.timestamp <= \$until_date)"
fi

# Check if there's any compliance data
compliance_count=$(jq -sc "${JQ_ARGS[@]}" \
  "[.[] | $JQ_FILTER] | length" \
  "$METRICS_FILE" 2>/dev/null || echo "0")

if [ "$compliance_count" -eq 0 ]; then
  if [ "$JSON_OUTPUT" = true ]; then
    echo '{"total_violations":0,"agents":[],"violation_types":[],"trends":[]}'
  else
    echo "No compliance violations found."
    if [ -n "$AGENT_FILTER" ] || [ -n "$TYPE_FILTER" ] || [ -n "$SEVERITY_FILTER" ] || [ -n "$SINCE_DATE" ]; then
      echo "Try removing filters to see all available data."
    else
      echo "Compliance violations are tracked when agents produce code with lint/format/naming/size issues."
    fi
  fi
  exit 0
fi

# Top violating agents report
if [ -n "$TOP_AGENTS" ]; then
  jq -sc "${JQ_ARGS[@]}" --argjson n "$TOP_AGENTS" "
    [.[] | $JQ_FILTER] |
    group_by(.agent // \"unknown\") |
    map({
      agent: (.[0].agent // \"unknown\"),
      total_violations: length,
      by_type: (
        group_by(.violation_type) |
        map({type: .[0].violation_type, count: length}) |
        sort_by(-.count)
      ),
      by_severity: (
        group_by(.severity) |
        map({severity: .[0].severity, count: length}) |
        sort_by(-.count)
      ),
      error_count: ([.[] | select(.severity == \"error\")] | length),
      warning_count: ([.[] | select(.severity == \"warning\")] | length),
      top_files: (
        group_by(.file_path) |
        map({file: .[0].file_path, count: length}) |
        sort_by(-.count) |
        .[:3]
      )
    }) |
    sort_by(-.total_violations) |
    .[:(\$n | tonumber)]
  " "$METRICS_FILE"
  exit 0
fi

# Trends over time report (daily buckets)
if [ "$SHOW_TRENDS" = true ]; then
  jq -sc "${JQ_ARGS[@]}" "
    [.[] | $JQ_FILTER] |
    group_by(.timestamp[:10]) |
    map({
      date: .[0].timestamp[:10],
      total_violations: length,
      error_count: ([.[] | select(.severity == \"error\")] | length),
      warning_count: ([.[] | select(.severity == \"warning\")] | length),
      agents_involved: ([.[].agent] | unique | length),
      most_common_type: (group_by(.violation_type) | sort_by(-length) | .[0][0].violation_type)
    }) |
    sort_by(.date)
  " "$METRICS_FILE"
  exit 0
fi

# JSON summary output
if [ "$JSON_OUTPUT" = true ]; then
  jq -sc "${JQ_ARGS[@]}" "
    [.[] | $JQ_FILTER] |
    {
      total_violations: length,
      error_count: ([.[] | select(.severity == \"error\")] | length),
      warning_count: ([.[] | select(.severity == \"warning\")] | length),
      info_count: ([.[] | select(.severity == \"info\")] | length),
      agents: (
        group_by(.agent // \"unknown\") |
        map({
          agent: (.[0].agent // \"unknown\"),
          total: length,
          errors: ([.[] | select(.severity == \"error\")] | length),
          warnings: ([.[] | select(.severity == \"warning\")] | length),
          by_type: (group_by(.violation_type) | map({type: .[0].violation_type, count: length}) | sort_by(-.count))
        }) |
        sort_by(-.total)
      ),
      violation_types: (
        group_by(.violation_type) |
        map({type: .[0].violation_type, count: length}) |
        sort_by(-.count)
      ),
      top_files: (
        group_by(.file_path) |
        map({file: .[0].file_path, count: length}) |
        sort_by(-.count) |
        .[:10]
      ),
      date_range: {
        earliest: (sort_by(.timestamp) | first | .timestamp),
        latest: (sort_by(.timestamp) | last | .timestamp)
      }
    }
  " "$METRICS_FILE"
  exit 0
fi

# Default: human-readable compliance dashboard
jq -rs "${JQ_ARGS[@]}" "
  def pct(total): if total > 0 then (. / total * 100 | floor) else 0 end;
  def pad(w): . + (\" \" * (w - (. | length)));

  [.[] | $JQ_FILTER] |
  . as \$all |
  (\$all | length) as \$total |
  ([\$all[] | select(.severity == \"error\")] | length) as \$errors |
  ([\$all[] | select(.severity == \"warning\")] | length) as \$warnings |
  ([\$all[] | select(.severity == \"info\")] | length) as \$infos |

  \"AGENT COMPLIANCE DASHBOARD\",
  \"==========================\",
  \"\",
  \"SUMMARY\",
  \"-------\",
  \"Total Violations: \(\$total)\",
  \"  Errors:   \(\$errors) (\(\$errors | pct(\$total))%)\",
  \"  Warnings: \(\$warnings) (\(\$warnings | pct(\$total))%)\",
  \"  Info:     \(\$infos) (\(\$infos | pct(\$total))%)\",
  \"\",
  \"TOP VIOLATING AGENTS\",
  \"--------------------\",
  (
    \$all |
    group_by(.agent // \"unknown\") |
    map({
      agent: (.[0].agent // \"unknown\"),
      total: length,
      errors: ([.[] | select(.severity == \"error\")] | length),
      warnings: ([.[] | select(.severity == \"warning\")] | length),
      top_type: (group_by(.violation_type) | sort_by(-length) | .[0][0].violation_type)
    }) |
    sort_by(-.total) |
    .[:10] |
    to_entries |
    map(\"\\(.key + 1). \\(.value.agent): \\(.value.total) violations (\\(.value.errors) errors, \\(.value.warnings) warnings) [top: \\(.value.top_type)]\") |
    .[]
  ),
  \"\",
  \"VIOLATION TYPES\",
  \"---------------\",
  (
    \$all |
    group_by(.violation_type) |
    map({type: .[0].violation_type, count: length}) |
    sort_by(-.count) |
    map(\"\\(.type | . + (\" \" * (12 - ([12, (. | length)] | min)))): \\(.count) (\\(.count | pct(\$total))%)\") |
    .[]
  ),
  \"\",
  \"TOP OFFENDING FILES\",
  \"-------------------\",
  (
    \$all |
    group_by(.file_path) |
    map({file: (.[0].file_path // \"unknown\"), count: length}) |
    sort_by(-.count) |
    .[:5] |
    map(\"\\(.count)x \\(.file)\") |
    .[]
  ),
  \"\",
  \"TREND\",
  \"-----\",
  (
    \$all |
    sort_by(.timestamp) |
    if length >= 4 then
      . as \$sorted |
      (\$sorted | length) as \$len |
      (\$sorted[:(\$len / 2 | floor)] | length) as \$first_half |
      (\$sorted[(\$len / 2 | floor):] | length) as \$second_half |
      (if \$second_half > \$first_half then
        \"DEGRADING: Violations increasing (first half: \\(\$first_half), second half: \\(\$second_half))\"
      elif \$second_half < \$first_half then
        \"IMPROVING: Violations decreasing (first half: \\(\$first_half), second half: \\(\$second_half))\"
      else
        \"STABLE: No significant change (first half: \\(\$first_half), second half: \\(\$second_half))\"
      end)
    else
      \"INSUFFICIENT DATA: Need at least 4 entries for trend analysis\"
    end
  )
" "$METRICS_FILE"
