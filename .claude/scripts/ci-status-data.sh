#!/usr/bin/env bash
# ci-status-data.sh
# Gathers local CI status data from .ci/ for the /ci-status skill dashboard
# size-ok: single-pass data aggregator for CI status dashboard
#
# Usage:
#   ./scripts/ci-status-data.sh [OPTIONS]
#
# Options:
#   --branch NAME   Show status for specific branch (default: current branch)
#   --pr NUMBER     Show status for specific PR
#   --mode MODE     Filter by CI mode (pre-commit, pre-pr, pre-merge, pre-release)
#   --history N     Include last N history entries per mode (default: 5)
#   --all-modes     Include all CI modes in output
#   --ci-dir DIR    Override .ci/ directory (default: .ci/)
#   --json          Output raw JSON (default)
#   --help          Show this help
#
# Output: JSON with CI status summary for /ci-status skill rendering

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

BRANCH_FILTER=""
PR_FILTER=""
MODE_FILTER=""
HISTORY_COUNT=5
CI_DIR="$REPO_ROOT/.ci"

# ─── Parse Args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)     BRANCH_FILTER="$2"; shift 2 ;;
    --pr)         PR_FILTER="$2"; shift 2 ;;
    --mode)       MODE_FILTER="$2"; shift 2 ;;
    --history)    HISTORY_COUNT="$2"; shift 2 ;;
    --ci-dir)     CI_DIR="$2"; shift 2 ;;
    --all-modes)  MODE_FILTER=""; shift ;;
    --json)       shift ;; # already default
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Check for jq
if ! command -v jq &>/dev/null; then
  echo '{"error": "jq is required but not installed"}'
  exit 1
fi

# Get current git branch
get_current_branch() {
  git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

# Read a CI result file and return enriched JSON
read_result_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  local content
  content=$(cat "$file" 2>/dev/null || echo "")
  if [[ -z "$content" ]] || ! echo "$content" | jq -e . &>/dev/null; then
    return
  fi
  echo "$content"
}

# Get trend symbol from last N results
# Returns: improving, stable, degrading, unknown
compute_trend() {
  local -a results=("$@")
  local pass_count=0
  local fail_count=0

  for result in "${results[@]}"; do
    local passed
    passed=$(echo "$result" | jq -r '.passed // "true"')
    if [[ "$passed" == "true" ]]; then
      pass_count=$((pass_count + 1))
    else
      fail_count=$((fail_count + 1))
    fi
  done

  local total=$((pass_count + fail_count))
  if [[ $total -eq 0 ]]; then
    echo "unknown"
  elif [[ $fail_count -eq 0 ]]; then
    echo "stable"
  elif [[ $pass_count -eq 0 ]]; then
    echo "degrading"
  elif [[ $fail_count -gt $pass_count ]]; then
    echo "degrading"
  else
    echo "improving"
  fi
}

# ─── Load Latest Results ──────────────────────────────────────────────────────

load_latest_results() {
  local latest_dir="$CI_DIR/latest"

  if [[ ! -d "$latest_dir" ]]; then
    echo "[]"
    return
  fi

  local modes=("pre-commit" "pre-pr" "pre-merge" "pre-release")
  local results_json="["
  local first=true

  for mode in "${modes[@]}"; do
    # Apply mode filter
    if [[ -n "$MODE_FILTER" && "$mode" != "$MODE_FILTER" ]]; then
      continue
    fi

    local latest_file="$latest_dir/${mode}.json"
    if [[ ! -f "$latest_file" ]]; then
      continue
    fi

    local result
    result=$(read_result_file "$latest_file")
    if [[ -z "$result" ]]; then
      continue
    fi

    # Apply branch/PR filter
    if [[ -n "$BRANCH_FILTER" ]]; then
      local result_branch
      result_branch=$(echo "$result" | jq -r '.branch // ""')
      if [[ "$result_branch" != "$BRANCH_FILTER" ]]; then
        continue
      fi
    fi

    if [[ -n "$PR_FILTER" ]]; then
      local result_pr
      result_pr=$(echo "$result" | jq -r '.pr_number // ""')
      if [[ "$result_pr" != "$PR_FILTER" ]]; then
        continue
      fi
    fi

    if [[ "$first" != "true" ]]; then
      results_json+=","
    fi
    first=false
    results_json+="$result"
  done

  results_json+="]"
  echo "$results_json"
}

# ─── Load History for a Mode ──────────────────────────────────────────────────

load_history_for_mode() {
  local mode="$1"
  local history_dir="$CI_DIR/history"

  if [[ ! -d "$history_dir" ]]; then
    echo "[]"
    return
  fi

  # Find all history files for this mode, sorted newest first
  local history_files=()
  while IFS= read -r -d '' file; do
    local basename
    basename=$(basename "$file")
    local file_mode
    file_mode=$(echo "$basename" | sed 's/-[0-9]\{8\}T[0-9]\{6\}Z\.json$//')
    if [[ "$file_mode" == "$mode" ]]; then
      history_files+=("$file")
    fi
  done < <(find "$history_dir" -name "*.json" -type f -print0 2>/dev/null | \
           xargs -0 ls -t 2>/dev/null | tr '\n' '\0' || \
           find "$history_dir" -name "*.json" -type f -print0 2>/dev/null)

  local history_json="["
  local first=true
  local count=0

  for file in "${history_files[@]}"; do
    if [[ $count -ge $HISTORY_COUNT ]]; then
      break
    fi

    local result
    result=$(read_result_file "$file")
    if [[ -z "$result" ]]; then
      continue
    fi

    if [[ "$first" != "true" ]]; then
      history_json+=","
    fi
    first=false
    # Include only summary fields for history (not full check output)
    history_json+=$(echo "$result" | jq '{
      timestamp: .timestamp,
      mode: .mode,
      branch: (.branch // "unknown"),
      pr_number: (.pr_number // null),
      passed: .passed,
      duration_seconds: .duration_seconds,
      summary: .summary
    }')
    count=$((count + 1))
  done

  history_json+="]"
  echo "$history_json"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local current_branch
  current_branch=$(get_current_branch)

  # Effective branch for display (use filter if specified, else current)
  local display_branch="${BRANCH_FILTER:-$current_branch}"

  # Load latest results
  local latest_results
  latest_results=$(load_latest_results)

  # Compute overall status
  local total_modes
  total_modes=$(echo "$latest_results" | jq 'length')

  local pass_count
  pass_count=$(echo "$latest_results" | jq '[.[] | select(.passed == true)] | length')

  local fail_count
  fail_count=$(echo "$latest_results" | jq '[.[] | select(.passed == false)] | length')

  local overall_status="unknown"
  if [[ "$total_modes" -gt 0 ]]; then
    if [[ "$fail_count" -gt 0 ]]; then
      overall_status="failing"
    else
      overall_status="passing"
    fi
  fi

  # Load history for each mode (for trend analysis)
  local modes=("pre-commit" "pre-pr" "pre-merge" "pre-release")
  local history_json="{"
  local h_first=true

  for mode in "${modes[@]}"; do
    if [[ -n "$MODE_FILTER" && "$mode" != "$MODE_FILTER" ]]; then
      continue
    fi

    local mode_history
    mode_history=$(load_history_for_mode "$mode")

    if [[ "$mode_history" == "[]" ]]; then
      continue
    fi

    if [[ "$h_first" != "true" ]]; then
      history_json+=","
    fi
    h_first=false
    history_json+="\"$mode\": $mode_history"
  done
  history_json+="}"

  # Compute per-mode trend from history
  local mode_status_json="["
  local ms_first=true

  for mode in "${modes[@]}"; do
    if [[ -n "$MODE_FILTER" && "$mode" != "$MODE_FILTER" ]]; then
      continue
    fi

    # Get latest result for this mode
    local latest_for_mode
    latest_for_mode=$(echo "$latest_results" | jq --arg m "$mode" '.[] | select(.mode == $m)')

    if [[ -z "$latest_for_mode" ]]; then
      continue
    fi

    # Get history results for trend
    local mode_hist
    mode_hist=$(echo "$history_json" | jq --arg m "$mode" '.[$m] // []')

    # Compute trend
    local trend="unknown"
    local hist_count
    hist_count=$(echo "$mode_hist" | jq 'length')
    if [[ "$hist_count" -gt 0 ]]; then
      local hist_passed
      hist_passed=$(echo "$mode_hist" | jq '[.[] | select(.passed == true)] | length')
      local hist_failed
      hist_failed=$(echo "$mode_hist" | jq '[.[] | select(.passed == false)] | length')

      if [[ "$hist_failed" -eq 0 ]]; then
        trend="stable"
      elif [[ "$hist_passed" -eq 0 ]]; then
        trend="degrading"
      elif [[ "$hist_failed" -gt "$hist_passed" ]]; then
        trend="degrading"
      else
        trend="improving"
      fi
    fi

    if [[ "$ms_first" != "true" ]]; then
      mode_status_json+=","
    fi
    ms_first=false

    mode_status_json+=$(echo "$latest_for_mode" | jq \
      --arg trend "$trend" \
      --argjson hist_count "$hist_count" \
      '{
        mode: .mode,
        passed: .passed,
        timestamp: .timestamp,
        branch: (.branch // "unknown"),
        pr_number: (.pr_number // null),
        duration_seconds: .duration_seconds,
        summary: .summary,
        trend: $trend,
        history_count: $hist_count,
        checks: [.checks[]? | {
          name: .name,
          status: .status,
          duration_seconds: .duration_seconds
        }]
      }')
  done
  mode_status_json+="]"

  # Get last run time (most recent across all modes)
  local last_run_time
  last_run_time=$(echo "$latest_results" | jq -r \
    '[.[] | .timestamp] | sort | last // "never"')

  # Build final output
  jq -n \
    --arg current_branch "$current_branch" \
    --arg display_branch "$display_branch" \
    --arg overall_status "$overall_status" \
    --arg last_run_time "$last_run_time" \
    --argjson total_modes "$total_modes" \
    --argjson pass_count "$pass_count" \
    --argjson fail_count "$fail_count" \
    --argjson mode_status "$mode_status_json" \
    --argjson history "$history_json" \
    '{
      current_branch: $current_branch,
      display_branch: $display_branch,
      overall_status: $overall_status,
      last_run_time: $last_run_time,
      summary: {
        total_modes: $total_modes,
        passing: $pass_count,
        failing: $fail_count
      },
      modes: $mode_status,
      history: $history
    }'
}

main "$@"
