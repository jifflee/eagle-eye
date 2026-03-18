#!/bin/bash
set -euo pipefail
# check-pr-ci-status.sh
# Checks CI completion status for PRs after creation with wait and retry
#
# Usage:
#   ./scripts/check-pr-ci-status.sh <PR_NUMBER> [OPTIONS]
#   ./scripts/check-pr-ci-status.sh --all [OPTIONS]
#
# Options:
#   --wait <sec>         Initial wait before first check (default: 60)
#   --interval <sec>     Poll interval for retries (default: 30)
#   --timeout <sec>      Max time to wait for CI completion (default: 600)
#   --all                Check all open PRs targeting dev/main
#   --json               Output JSON format
#   --quiet              Minimal output (exit codes only)
#   --state-file <path>  Persist wait state for recovery (default: /tmp/ci-wait-state-<PR>.json)
#   --resume             Resume from saved state if available
#
# Exit Codes:
#   0 - All checks passed (mergeable)
#   1 - Some checks failed (needs review)
#   2 - Checks still pending (timed out)
#   3 - Error (invalid PR, API failure)
#
# Output (JSON mode):
#   {
#     "pr_number": N,
#     "status": "mergeable|needs_review|pending|error",
#     "checks": {...},
#     "summary": "human readable summary"
#   }
#
# Resilience Features (Issue #547):
#   - Persists wait state across container restarts
#   - Exponential backoff retry for GitHub API failures
#   - Health checks during long waits
#   - Detailed diagnostic logging

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
PR_NUMBER=""
CHECK_ALL=false
INITIAL_WAIT=60
POLL_INTERVAL=30
TIMEOUT=600
JSON_OUTPUT=false
QUIET=false
STATE_FILE=""
RESUME=false
MAX_API_RETRIES=5
RETRY_BASE_DELAY=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --wait)
      INITIAL_WAIT="$2"
      shift 2
      ;;
    --interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --all)
      CHECK_ALL=true
      shift
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --quiet|-q)
      QUIET=true
      shift
      ;;
    --state-file)
      STATE_FILE="$2"
      shift 2
      ;;
    --resume)
      RESUME=true
      shift
      ;;
    -h|--help)
      echo "Usage: $0 <PR_NUMBER> [OPTIONS]"
      echo "       $0 --all [OPTIONS]"
      echo ""
      echo "Check CI completion status for PRs with wait and retry."
      echo ""
      echo "Options:"
      echo "  --wait <sec>         Initial wait before first check (default: 60)"
      echo "  --interval <sec>     Poll interval for retries (default: 30)"
      echo "  --timeout <sec>      Max wait for CI completion (default: 600)"
      echo "  --all                Check all open PRs targeting dev/main"
      echo "  --json               Output JSON format"
      echo "  --quiet              Minimal output"
      echo "  --state-file <path>  Persist wait state for recovery"
      echo "  --resume             Resume from saved state if available"
      echo ""
      echo "Exit codes:"
      echo "  0 - All checks passed (mergeable)"
      echo "  1 - Some checks failed (needs review)"
      echo "  2 - Checks still pending"
      echo "  3 - Error"
      exit 0
      ;;
    *)
      if [[ -z "$PR_NUMBER" && "$1" =~ ^[0-9]+$ ]]; then
        PR_NUMBER="$1"
      else
        echo "Error: Unknown argument: $1" >&2
        exit 3
      fi
      shift
      ;;
  esac
done

# Validate arguments
if [[ -z "$PR_NUMBER" && "$CHECK_ALL" == "false" ]]; then
  echo "Error: PR number or --all required" >&2
  exit 3
fi

# Output helpers
log() {
  if ! $QUIET && ! $JSON_OUTPUT; then
    echo -e "$1"
  fi
}

log_status() {
  if ! $QUIET && ! $JSON_OUTPUT; then
    echo -e "${CYAN}[$(date '+%H:%M:%S')]${NC} $1"
  fi
}

log_debug() {
  if [[ "${DEBUG:-false}" == "true" ]]; then
    echo -e "${CYAN}[DEBUG $(date '+%H:%M:%S')]${NC} $1" >&2
  fi
}

# State persistence functions for container restart recovery
save_wait_state() {
  local pr="$1"
  local elapsed="$2"
  local attempt="$3"
  local state_file="${STATE_FILE:-/tmp/ci-wait-state-${pr}.json}"

  local state_json=$(cat <<EOF
{
  "pr_number": $pr,
  "elapsed_seconds": $elapsed,
  "attempt": $attempt,
  "last_update": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "timeout": $TIMEOUT,
  "poll_interval": $POLL_INTERVAL
}
EOF
)

  echo "$state_json" > "$state_file" 2>/dev/null || true
  log_debug "Saved wait state to $state_file (elapsed: ${elapsed}s, attempt: $attempt)"
}

load_wait_state() {
  local pr="$1"
  local state_file="${STATE_FILE:-/tmp/ci-wait-state-${pr}.json}"

  if [[ ! -f "$state_file" ]]; then
    log_debug "No saved state found at $state_file"
    return 1
  fi

  if ! jq empty "$state_file" 2>/dev/null; then
    log_debug "Invalid state file, ignoring"
    rm -f "$state_file"
    return 1
  fi

  log_debug "Loaded wait state from $state_file"
  cat "$state_file"
  return 0
}

clear_wait_state() {
  local pr="$1"
  local state_file="${STATE_FILE:-/tmp/ci-wait-state-${pr}.json}"
  rm -f "$state_file" 2>/dev/null || true
  log_debug "Cleared wait state for PR #$pr"
}

# GitHub API retry with exponential backoff
call_gh_api_with_retry() {
  local cmd="$1"
  local max_retries="${MAX_API_RETRIES:-5}"
  local base_delay="${RETRY_BASE_DELAY:-2}"
  local attempt=1

  while [[ $attempt -le $max_retries ]]; do
    log_debug "GitHub API call attempt $attempt/$max_retries: $cmd"

    local result
    local exit_code=0
    result=$(eval "$cmd" 2>&1) || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      echo "$result"
      return 0
    fi

    # Check if it's a transient error (network, timeout, rate limit)
    if echo "$result" | grep -qiE "(timeout|connection|EOF|rate limit|502|503|504)"; then
      local delay=$((base_delay ** attempt))
      log_status "GitHub API error (attempt $attempt/$max_retries), retrying in ${delay}s: ${result:0:100}"
      sleep "$delay"
      ((attempt++))
    else
      # Non-transient error, fail immediately
      log_debug "Non-retryable GitHub API error: $result"
      echo "$result"
      return $exit_code
    fi
  done

  log_status "GitHub API failed after $max_retries attempts"
  return 1
}

# Health check during long waits
perform_health_check() {
  local pr="$1"

  log_debug "Performing health check for PR #$pr"

  # Check Docker connectivity
  if ! docker info &>/dev/null 2>&1; then
    log_status "Warning: Docker connection lost, attempting reconnect..."
    sleep 2
    if ! docker info &>/dev/null 2>&1; then
      log_status "ERROR: Docker connection unavailable"
      return 1
    fi
    log_status "Docker connection restored"
  fi

  # Check GitHub API connectivity
  if ! gh api /rate_limit &>/dev/null 2>&1; then
    log_status "Warning: GitHub API connection lost"
    return 1
  fi

  log_debug "Health check passed"
  return 0
}

# Function to get check status for a single PR with retry logic
get_pr_checks() {
  local pr="$1"
  call_gh_api_with_retry "gh pr checks \"$pr\" --json name,state,bucket,completedAt,description,workflow"
}

# Function to analyze check results
analyze_checks() {
  local checks_json="$1"

  # Validate JSON input before parsing
  if ! echo "$checks_json" | jq empty 2>/dev/null; then
    log_debug "Invalid JSON input to analyze_checks: ${checks_json:0:100}"
    # Return error status JSON
    cat <<EOF
{
  "status": "error",
  "counts": {
    "total": 0,
    "pass": 0,
    "fail": 0,
    "pending": 0,
    "skip": 0,
    "cancel": 0
  },
  "failed_checks": "",
  "pending_checks": "",
  "error": "Invalid JSON response from GitHub API"
}
EOF
    return 0
  fi

  # Count by bucket
  local pass_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "pass")] | length')
  local fail_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "fail")] | length')
  local pending_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "pending")] | length')
  local skip_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "skipping")] | length')
  local cancel_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "cancel")] | length')
  local total=$((pass_count + fail_count + pending_count + skip_count + cancel_count))

  # Determine overall status
  local status="unknown"
  if [[ $pending_count -gt 0 ]]; then
    status="pending"
  elif [[ $fail_count -gt 0 || $cancel_count -gt 0 ]]; then
    status="needs_review"
  elif [[ $total -eq 0 ]]; then
    status="no_checks"
  else
    status="mergeable"
  fi

  # Get failed check names
  local failed_checks=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | .[].name' | tr '\n' ',' | sed 's/,$//')
  local pending_checks=$(echo "$checks_json" | jq -r '[.[] | select(.bucket == "pending")] | .[].name' | tr '\n' ',' | sed 's/,$//')

  # Build result
  cat <<EOF
{
  "status": "$status",
  "counts": {
    "total": $total,
    "pass": $pass_count,
    "fail": $fail_count,
    "pending": $pending_count,
    "skip": $skip_count,
    "cancel": $cancel_count
  },
  "failed_checks": "$failed_checks",
  "pending_checks": "$pending_checks"
}
EOF
}

# Function to format human-readable status
format_status() {
  local pr="$1"
  local analysis="$2"

  local status=$(echo "$analysis" | jq -r '.status')
  local total=$(echo "$analysis" | jq -r '.counts.total')
  local pass=$(echo "$analysis" | jq -r '.counts.pass')
  local fail=$(echo "$analysis" | jq -r '.counts.fail')
  local pending=$(echo "$analysis" | jq -r '.counts.pending')
  local failed_checks=$(echo "$analysis" | jq -r '.failed_checks')
  local pending_checks=$(echo "$analysis" | jq -r '.pending_checks')

  case "$status" in
    mergeable)
      echo -e "${GREEN}✓${NC} PR #$pr: ${GREEN}MERGEABLE${NC} ($pass/$total checks passed)"
      ;;
    needs_review)
      echo -e "${RED}✗${NC} PR #$pr: ${RED}NEEDS REVIEW${NC} ($fail failed: $failed_checks)"
      ;;
    pending)
      echo -e "${YELLOW}⏳${NC} PR #$pr: ${YELLOW}PENDING${NC} ($pending in progress: $pending_checks)"
      ;;
    no_checks)
      echo -e "${CYAN}○${NC} PR #$pr: ${CYAN}NO CHECKS${NC} (no CI configured or checks not started)"
      ;;
    *)
      echo -e "${RED}?${NC} PR #$pr: Unknown status"
      ;;
  esac
}

# Function to check a single PR with retries and state persistence
check_single_pr() {
  local pr="$1"
  local do_initial_wait="$2"

  local start_time=$(date +%s)
  local attempt=1
  local elapsed=0

  # Try to resume from saved state if --resume flag is set
  if [[ "$RESUME" == "true" ]]; then
    local saved_state
    if saved_state=$(load_wait_state "$pr"); then
      elapsed=$(echo "$saved_state" | jq -r '.elapsed_seconds // 0')
      attempt=$(echo "$saved_state" | jq -r '.attempt // 1')
      # Adjust start time to account for previous elapsed time
      start_time=$(($(date +%s) - elapsed))
      log_status "Resuming from saved state: elapsed ${elapsed}s, attempt $attempt"
      # Skip initial wait since we're resuming
      do_initial_wait="false"
    fi
  fi

  # Initial wait (only for first check after PR creation, unless resuming)
  if [[ "$do_initial_wait" == "true" && $INITIAL_WAIT -gt 0 ]]; then
    log_status "Waiting ${INITIAL_WAIT}s before first CI check..."
    sleep "$INITIAL_WAIT"
  fi

  # Health check counter (check every 5 attempts)
  local health_check_interval=5
  local next_health_check=$health_check_interval

  while true; do
    elapsed=$(($(date +%s) - start_time))

    # Save state periodically for recovery
    save_wait_state "$pr" "$elapsed" "$attempt"

    # Perform health check periodically
    if [[ $attempt -ge $next_health_check ]]; then
      if ! perform_health_check "$pr"; then
        log_status "Health check failed, will retry after interval..."
        sleep "$POLL_INTERVAL"
        ((attempt++))
        next_health_check=$((attempt + health_check_interval))
        continue
      fi
      next_health_check=$((attempt + health_check_interval))
    fi

    log_status "Checking PR #$pr (attempt $attempt, elapsed ${elapsed}s/${TIMEOUT}s)..."

    local checks_json=$(get_pr_checks "$pr")
    local api_exit=$?

    # Handle API failures gracefully
    if [[ $api_exit -ne 0 ]] || [[ -z "$checks_json" ]]; then
      log_status "Failed to fetch PR checks, will retry..."
      sleep "$POLL_INTERVAL"
      ((attempt++))
      continue
    fi

    if [[ "$checks_json" == "[]" || "$checks_json" == "null" ]]; then
      # No checks yet - might need to wait
      if [[ $elapsed -ge $TIMEOUT ]]; then
        clear_wait_state "$pr"
        if $JSON_OUTPUT; then
          echo "{\"pr_number\": $pr, \"status\": \"no_checks\", \"summary\": \"No CI checks found within timeout\"}"
        else
          log "PR #$pr: No CI checks found within timeout"
        fi
        return 2
      fi
      log_status "No checks found yet, retrying in ${POLL_INTERVAL}s..."
      sleep "$POLL_INTERVAL"
      ((attempt++))
      continue
    fi

    local analysis=$(analyze_checks "$checks_json")
    local status=$(echo "$analysis" | jq -r '.status')

    if [[ "$status" == "pending" ]]; then
      if [[ $elapsed -ge $TIMEOUT ]]; then
        clear_wait_state "$pr"
        if $JSON_OUTPUT; then
          echo "{\"pr_number\": $pr, \"status\": \"pending\", \"checks\": $analysis, \"summary\": \"CI checks timed out while pending (${elapsed}s)\"}"
        else
          format_status "$pr" "$analysis"
          log "Timed out after ${elapsed}s"
        fi
        return 2
      fi

      local pending_count=$(echo "$analysis" | jq -r '.counts.pending')
      log_status "$pending_count checks still pending, retrying in ${POLL_INTERVAL}s..."
      sleep "$POLL_INTERVAL"
      ((attempt++))
    else
      # Not pending - we have a final result
      clear_wait_state "$pr"

      if $JSON_OUTPUT; then
        local summary=""
        case "$status" in
          mergeable) summary="All CI checks passed - ready to merge" ;;
          needs_review) summary="CI checks failed - needs review" ;;
          no_checks) summary="No CI checks configured" ;;
          *) summary="Unknown status" ;;
        esac
        echo "{\"pr_number\": $pr, \"status\": \"$status\", \"checks\": $analysis, \"summary\": \"$summary\"}"
      else
        format_status "$pr" "$analysis"
      fi

      case "$status" in
        mergeable|no_checks) return 0 ;;
        needs_review) return 1 ;;
        *) return 3 ;;
      esac
    fi
  done
}

# Function to get all open PRs
get_open_prs() {
  gh pr list --state open --json number,headRefName,baseRefName --jq '.[] | select(.baseRefName == "dev" or .baseRefName == "main") | .number'
}

# Main logic
if $CHECK_ALL; then
  log "Checking all open PRs targeting dev/main..."
  log ""

  prs=$(get_open_prs)
  if [[ -z "$prs" ]]; then
    if $JSON_OUTPUT; then
      echo '{"status": "no_prs", "prs": [], "summary": "No open PRs found"}'
    else
      log "No open PRs found targeting dev/main"
    fi
    exit 0
  fi

  all_results=()
  overall_status="mergeable"
  first_pr=true

  for pr in $prs; do
    if $first_pr; then
      result=$(check_single_pr "$pr" "true")
      first_pr=false
    else
      # Subsequent PRs don't need initial wait
      result=$(check_single_pr "$pr" "false")
    fi
    exit_code=$?
    all_results+=("$result")

    case $exit_code in
      1) overall_status="needs_review" ;;
      2) [[ "$overall_status" != "needs_review" ]] && overall_status="pending" ;;
    esac

    log ""
  done

  if $JSON_OUTPUT; then
    # Combine results
    results_json=$(printf '%s\n' "${all_results[@]}" | jq -s '.')
    echo "{\"status\": \"$overall_status\", \"prs\": $results_json}"
  else
    log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    case "$overall_status" in
      mergeable)
        log "${GREEN}All PRs are in mergeable state${NC}"
        ;;
      needs_review)
        log "${RED}Some PRs need review (see failures above)${NC}"
        ;;
      pending)
        log "${YELLOW}Some PRs still have pending checks${NC}"
        ;;
    esac
  fi

  case "$overall_status" in
    mergeable) exit 0 ;;
    needs_review) exit 1 ;;
    pending) exit 2 ;;
    *) exit 3 ;;
  esac
else
  # Single PR mode
  check_single_pr "$PR_NUMBER" "true"
  exit $?
fi
