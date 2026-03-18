#!/usr/bin/env bash
# store-results.sh
# Stores CI pipeline run results to .ci/ for local status dashboard
#
# Usage:
#   ./scripts/ci/store-results.sh --report FILE [OPTIONS]
#   cat ci-report.json | ./scripts/ci/store-results.sh --stdin [OPTIONS]
#
# Options:
#   --report FILE     Read CI result JSON from FILE (default: ci-report.json)
#   --stdin           Read CI result JSON from stdin
#   --branch NAME     Branch name to associate (default: current git branch)
#   --pr NUMBER       PR number to associate (optional)
#   --ci-dir DIR      Override .ci/ directory (default: .ci/)
#   --no-history      Skip storing to history (latest only)
#   --quiet           Suppress non-essential output
#   --help            Show this help
#
# Output:
#   Stores results to:
#     .ci/latest/{mode}.json       (always updated)
#     .ci/history/YYYY-MM-DD/{mode}-{timestamp}.json (unless --no-history)
#
# Exit codes:
#   0  Success
#   1  Error (missing input, invalid JSON, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPORT_FILE="${CI_REPORT_FILE:-$REPO_ROOT/ci-report.json}"
READ_STDIN=false
BRANCH=""
PR_NUMBER=""
CI_DIR="$REPO_ROOT/.ci"
STORE_HISTORY=true
QUIET=false

# ─── Parse Args ───────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)     REPORT_FILE="$2"; shift 2 ;;
    --stdin)      READ_STDIN=true; shift ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    --pr)         PR_NUMBER="$2"; shift 2 ;;
    --ci-dir)     CI_DIR="$2"; shift 2 ;;
    --no-history) STORE_HISTORY=false; shift ;;
    --quiet)      QUIET=true; shift ;;
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

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo "[store-results] $*"
  fi
}

log_error() {
  echo "[store-results] ERROR: $*" >&2
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Get current git branch
get_branch() {
  if [[ -n "$BRANCH" ]]; then
    echo "$BRANCH"
    return
  fi
  git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown"
}

# Validate required tools
check_deps() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    exit 1
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps

  # Read input JSON
  local result_json
  if [[ "$READ_STDIN" == "true" ]]; then
    result_json=$(cat)
  elif [[ -f "$REPORT_FILE" ]]; then
    result_json=$(cat "$REPORT_FILE")
  else
    log_error "Report file not found: $REPORT_FILE"
    log_error "Use --report FILE or --stdin to provide CI results"
    exit 1
  fi

  # Validate JSON
  if ! echo "$result_json" | jq -e . &>/dev/null; then
    log_error "Invalid JSON in CI result"
    exit 1
  fi

  # Extract mode from JSON
  local mode
  mode=$(echo "$result_json" | jq -r '.mode // "unknown"')
  if [[ "$mode" == "unknown" || -z "$mode" ]]; then
    log_error "CI result missing 'mode' field"
    exit 1
  fi

  # Enrich result with branch/PR info
  local branch
  branch=$(get_branch)

  local enriched_json
  enriched_json=$(echo "$result_json" | jq \
    --arg branch "$branch" \
    --arg pr "$PR_NUMBER" \
    'if $pr != "" then . + {branch: $branch, pr_number: ($pr | tonumber)} else . + {branch: $branch} end')

  # Create .ci/ directory structure
  local latest_dir="$CI_DIR/latest"
  local history_dir="$CI_DIR/history"
  mkdir -p "$latest_dir"

  # Store to latest/
  local latest_file="$latest_dir/${mode}.json"
  echo "$enriched_json" > "$latest_file"
  log_info "Stored latest result: $latest_file"

  # Store to history/ (date-partitioned)
  if [[ "$STORE_HISTORY" == "true" ]]; then
    local date_str
    date_str=$(date -u +"%Y-%m-%d")
    local ts_str
    ts_str=$(date -u +"%Y%m%dT%H%M%SZ")

    local history_date_dir="$history_dir/$date_str"
    mkdir -p "$history_date_dir"

    local history_file="$history_date_dir/${mode}-${ts_str}.json"
    echo "$enriched_json" > "$history_file"
    log_info "Stored history result: $history_file"
  fi

  log_info "CI results stored successfully (mode: $mode, branch: $branch)"
}

main "$@"
