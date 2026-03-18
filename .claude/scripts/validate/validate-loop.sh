#!/usr/bin/env bash
# ============================================================
# Script: validate-loop.sh
# Purpose: Autonomous validation loop - run validation commands iteratively
#          until they pass or max iterations reached
#
# Usage:
#   ./scripts/validate-loop.sh [OPTIONS] -- <validation_command> [args...]
#
# DESCRIPTION:
#   Executes a validation command repeatedly, tracking iterations and status.
#   Designed for autonomous Claude Code workflows where validation should
#   continue until all checks pass or a maximum iteration limit is reached.
#
#   The script runs the validation command, captures output and exit code,
#   and returns structured JSON with iteration history, final status, and
#   actionable insights.
#
# OPTIONS:
#   --max-iterations N    Maximum iterations before stopping (default: 5)
#   --iteration-delay N   Seconds to wait between iterations (default: 0)
#   --timeout N           Timeout per iteration in seconds (default: 300)
#   --output FILE         Write JSON report to FILE (default: stdout)
#   --quiet               Suppress iteration progress output
#   --verbose             Show detailed output from each iteration
#   --stop-on-pass        Stop immediately on first pass (default: true)
#   --continue-on-pass    Continue even after passing (for stability checks)
#   --json                Output JSON only (alias for --quiet)
#   --help                Show this help
#
# EXIT CODES:
#   0   Validation passed within max iterations
#   1   Validation failed after max iterations
#   2   Fatal error (invalid arguments, missing command)
#   3   Validation command timed out on all iterations
#
# VALIDATION COMMAND:
#   The validation command must follow POSIX exit code conventions:
#     0   = PASS (all checks passed)
#     1+  = FAIL (one or more checks failed)
#
#   Examples of compatible validators:
#     - ./scripts/qa-gate.sh --quick
#     - ./scripts/test-runner.sh --fast
#     - ./scripts/ci/validators/shellcheck-all.sh
#     - shellcheck scripts/*.sh
#     - python -m pytest tests/
#
# JSON OUTPUT FORMAT:
#   {
#     "status": "pass|fail|error|timeout",
#     "total_iterations": N,
#     "final_iteration": N,
#     "final_exit_code": N,
#     "duration_seconds": N,
#     "validation_command": "...",
#     "iterations": [
#       {
#         "iteration": 1,
#         "exit_code": 1,
#         "duration_seconds": 12,
#         "output": "...",
#         "timestamp": "ISO-8601"
#       },
#       ...
#     ],
#     "summary": "Concise summary of final state",
#     "next_steps": ["Actionable recommendation 1", ...]
#   }
#
# EXAMPLES:
#   # Run qa-gate until it passes (max 5 iterations)
#   ./scripts/validate-loop.sh -- ./scripts/qa-gate.sh --quick
#
#   # Run tests with custom iteration limit
#   ./scripts/validate-loop.sh --max-iterations 3 -- ./scripts/test-runner.sh --fast
#
#   # Run shellcheck on all scripts with JSON output
#   ./scripts/validate-loop.sh --json --output results.json -- shellcheck scripts/*.sh
#
#   # Stability check: run 3 times even after passing
#   ./scripts/validate-loop.sh --max-iterations 3 --continue-on-pass -- npm test
#
# AUTONOMOUS VALIDATION PATTERN:
#   This script enables Claude Code to self-validate and self-correct outputs:
#
#   1. Claude makes changes to code
#   2. Claude runs: ./scripts/validate-loop.sh -- <validator>
#   3. Script executes validator and returns structured results
#   4. If validator fails:
#      - Claude analyzes failure output
#      - Claude applies fixes
#      - Script automatically re-runs validator (iteration 2)
#   5. Loop continues until:
#      - Validator passes (exit 0) → success
#      - Max iterations reached → failure
#      - Timeout on all iterations → timeout
#
#   See docs/autonomous-validation-pattern.md for detailed guidance.
#
# INTEGRATION:
#   - Works with any POSIX-compliant validation command
#   - Integrates with qa-gate, test-runner, CI validators
#   - Compatible with n8n workflows, GitHub Actions
#   - Supports both interactive and automated usage
#
# Related:
#   - docs/autonomous-validation-pattern.md - Claude Code usage guide
#   - scripts/qa-gate.sh - QA validation gate
#   - scripts/test-runner.sh - Test discovery runner
#   - scripts/ci/runners/run-pipeline.sh - CI orchestrator
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────

MAX_ITERATIONS=5
ITERATION_DELAY=0
TIMEOUT=300
OUTPUT_FILE=""
QUIET=false
VERBOSE=false
STOP_ON_PASS=true
VALIDATION_CMD=()

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -120
  exit 0
}

# Parse arguments before --
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --iteration-delay)
      ITERATION_DELAY="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --quiet|--json)
      QUIET=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --stop-on-pass)
      STOP_ON_PASS=true
      shift
      ;;
    --continue-on-pass)
      STOP_ON_PASS=false
      shift
      ;;
    --help|-h)
      show_help
      ;;
    --)
      shift
      VALIDATION_CMD=("$@")
      break
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      echo "Note: Use -- to separate options from validation command" >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if [[ ${#VALIDATION_CMD[@]} -eq 0 ]]; then
  echo "ERROR: No validation command provided" >&2
  echo "Usage: $0 [OPTIONS] -- <validation_command> [args...]" >&2
  echo "Run with --help for full usage." >&2
  exit 2
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed" >&2
  echo "Install with: apt-get install jq" >&2
  exit 2
fi

# Validate numeric arguments
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [[ "$MAX_ITERATIONS" -lt 1 ]]; then
  echo "ERROR: --max-iterations must be a positive integer" >&2
  exit 2
fi

if ! [[ "$ITERATION_DELAY" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --iteration-delay must be a non-negative integer" >&2
  exit 2
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -lt 1 ]]; then
  echo "ERROR: --timeout must be a positive integer" >&2
  exit 2
fi

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${BLUE}[INFO]${NC} $*" >&2
  fi
}

log_success() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
  fi
}

log_warn() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*" >&2
  fi
}

# ─── Iteration Tracking ───────────────────────────────────────────────────────

declare -a ITERATION_RESULTS=()
PIPELINE_START=$(date +%s)

# Run a single validation iteration
run_iteration() {
  local iteration_num="$1"
  local start_time
  start_time=$(date +%s)
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  log_info "Running iteration $iteration_num/${MAX_ITERATIONS}..."
  log_verbose "Command: ${VALIDATION_CMD[*]}"

  # Run validation command with timeout
  local tmp_out
  tmp_out=$(mktemp)
  local exit_code=0

  # Use timeout command to enforce per-iteration timeout
  if timeout "$TIMEOUT" "${VALIDATION_CMD[@]}" > "$tmp_out" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  local output
  output=$(cat "$tmp_out")
  rm -f "$tmp_out"

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Handle timeout (exit code 124 from timeout command)
  if [[ $exit_code -eq 124 ]]; then
    log_warn "Iteration $iteration_num timed out after ${TIMEOUT}s"
    output="TIMEOUT: Validation command exceeded ${TIMEOUT}s limit\n$output"
  elif [[ $exit_code -eq 0 ]]; then
    log_success "Iteration $iteration_num passed (${duration}s)"
  else
    log_warn "Iteration $iteration_num failed with exit code $exit_code (${duration}s)"
  fi

  # Show output if verbose
  if [[ "$VERBOSE" == "true" ]]; then
    echo "$output" | head -50 | sed 's/^/  | /' >&2
  fi

  # Escape output for JSON
  local escaped_output
  escaped_output=$(printf '%s' "$output" | jq -Rs '.')

  # Build iteration result JSON
  local result
  result=$(jq -n \
    --argjson iteration "$iteration_num" \
    --argjson exit_code "$exit_code" \
    --argjson duration "$duration" \
    --argjson output "$escaped_output" \
    --arg timestamp "$timestamp" \
    '{
      iteration: $iteration,
      exit_code: $exit_code,
      duration_seconds: $duration,
      output: $output,
      timestamp: $timestamp
    }')

  ITERATION_RESULTS+=("$result")

  return $exit_code
}

# ─── Main Loop ────────────────────────────────────────────────────────────────

main() {
  local validation_cmd_str="${VALIDATION_CMD[*]}"

  if [[ "$QUIET" != "true" ]]; then
    echo "" >&2
    echo -e "${BOLD}Autonomous Validation Loop${NC}" >&2
    echo -e "Command: ${CYAN}${validation_cmd_str}${NC}" >&2
    echo -e "Max iterations: $MAX_ITERATIONS  |  Timeout: ${TIMEOUT}s/iter" >&2
    echo "────────────────────────────────────────" >&2
    echo "" >&2
  fi

  local final_status="fail"
  local final_exit_code=1
  local final_iteration=0
  local all_timeouts=true

  # Run iterations
  for ((i=1; i<=MAX_ITERATIONS; i++)); do
    final_iteration=$i

    if run_iteration "$i"; then
      # Validation passed
      final_status="pass"
      final_exit_code=0
      all_timeouts=false

      if [[ "$STOP_ON_PASS" == "true" ]]; then
        log_success "Validation passed on iteration $i"
        break
      fi
    else
      final_exit_code=$?
      # Check if this was a timeout
      if [[ $final_exit_code -ne 124 ]]; then
        all_timeouts=false
      fi

      # Don't sleep after last iteration
      if [[ $i -lt $MAX_ITERATIONS ]] && [[ $ITERATION_DELAY -gt 0 ]]; then
        log_verbose "Waiting ${ITERATION_DELAY}s before next iteration..."
        sleep "$ITERATION_DELAY"
      fi
    fi
  done

  # Determine final status
  if [[ "$final_status" != "pass" ]]; then
    if [[ "$all_timeouts" == "true" ]]; then
      final_status="timeout"
      log_error "All $final_iteration iteration(s) timed out"
    else
      log_error "Validation failed after $final_iteration iteration(s)"
    fi
  fi

  local pipeline_end
  pipeline_end=$(date +%s)
  local total_duration=$((pipeline_end - PIPELINE_START))

  # Build iterations JSON array
  local iterations_json
  iterations_json=$(printf '%s\n' "${ITERATION_RESULTS[@]}" | jq -s '.')

  # Generate summary and next steps
  local summary next_steps
  case "$final_status" in
    pass)
      summary="Validation passed on iteration $final_iteration of $MAX_ITERATIONS"
      next_steps='["Proceed with deployment or next workflow step","Review iteration history for any patterns or instabilities"]'
      ;;
    timeout)
      summary="All $final_iteration validation iteration(s) exceeded ${TIMEOUT}s timeout"
      next_steps='["Increase --timeout value for longer-running validations","Optimize validation command performance","Check for hanging processes or deadlocks"]'
      ;;
    fail)
      summary="Validation failed after $final_iteration iteration(s) (max: $MAX_ITERATIONS)"
      next_steps='["Review iteration outputs to identify failure patterns","Increase --max-iterations if fixes are converging","Manually investigate and fix root cause issues","Check validation command for correctness"]'
      ;;
    *)
      summary="Unknown validation status"
      next_steps='["Review script output for errors"]'
      ;;
  esac

  # Build final JSON report
  local report
  report=$(jq -n \
    --arg status "$final_status" \
    --argjson total_iterations "$MAX_ITERATIONS" \
    --argjson final_iteration "$final_iteration" \
    --argjson final_exit_code "$final_exit_code" \
    --argjson duration "$total_duration" \
    --arg validation_command "$validation_cmd_str" \
    --argjson iterations "$iterations_json" \
    --arg summary "$summary" \
    --argjson next_steps "$next_steps" \
    '{
      status: $status,
      total_iterations: $total_iterations,
      final_iteration: $final_iteration,
      final_exit_code: $final_exit_code,
      duration_seconds: $duration,
      validation_command: $validation_command,
      iterations: $iterations,
      summary: $summary,
      next_steps: $next_steps
    }')

  # Output report
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" > "$OUTPUT_FILE"
    log_verbose "Report written to: $OUTPUT_FILE"
  fi

  # Always output JSON (either to stdout or file)
  if [[ -z "$OUTPUT_FILE" ]] || [[ "$VERBOSE" == "true" ]]; then
    echo "$report"
  fi

  # Print summary to stderr if not quiet
  if [[ "$QUIET" != "true" ]]; then
    echo "" >&2
    echo -e "${BOLD}════════════════════════════════════════${NC}" >&2
    echo -e "${BOLD}  Validation Loop Summary${NC}" >&2
    echo -e "${BOLD}════════════════════════════════════════${NC}" >&2
    echo "" >&2
    echo "  Status:     $final_status" >&2
    echo "  Iterations: $final_iteration / $MAX_ITERATIONS" >&2
    echo "  Duration:   ${total_duration}s" >&2
    echo "" >&2

    case "$final_status" in
      pass)
        echo -e "  ${GREEN}✓ PASSED${NC} - $summary" >&2
        ;;
      timeout)
        echo -e "  ${YELLOW}⏱ TIMEOUT${NC} - $summary" >&2
        ;;
      fail)
        echo -e "  ${RED}✗ FAILED${NC} - $summary" >&2
        ;;
    esac

    echo "" >&2
    echo "  Next steps:" >&2
    echo "$next_steps" | jq -r '.[]' | sed 's/^/    - /' >&2
    echo "" >&2
    echo -e "${BOLD}════════════════════════════════════════${NC}" >&2
    echo "" >&2
  fi

  # Exit with appropriate code
  case "$final_status" in
    pass) exit 0 ;;
    timeout) exit 3 ;;
    fail) exit 1 ;;
    *) exit 2 ;;
  esac
}

main "$@"
