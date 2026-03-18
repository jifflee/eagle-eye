#!/usr/bin/env bash
# ============================================================
# Script: check-test-coverage.sh
# Purpose: Check test coverage and enforce thresholds
#
# Calculates test coverage ratio (test files / total scripts)
# and ensures minimum thresholds are met. Integrates with CI
# to block PRs that decrease coverage.
#
# Usage:
#   ./scripts/check-test-coverage.sh [OPTIONS]
#
# Options:
#   --threshold N      Minimum coverage percentage (default: 60)
#   --mode MODE        shell|unit|all (default: all)
#   --report           Generate detailed coverage report
#   --json FILE        Write JSON report to FILE
#   --verbose          Verbose output
#   --help             Show this help
#
# Exit codes:
#   0  Coverage meets threshold
#   1  Coverage below threshold
#   2  Usage/configuration error
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

THRESHOLD="${COVERAGE_THRESHOLD:-60}"
MODE="all"
REPORT=false
JSON_FILE=""
VERBOSE=false

# ─── Functions ────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Check test coverage and enforce thresholds.

Options:
  --threshold N      Minimum coverage percentage (default: 60)
  --mode MODE        shell|unit|all (default: all)
  --report           Generate detailed coverage report
  --json FILE        Write JSON report to FILE
  --verbose          Verbose output
  --help             Show this help

Environment variables:
  COVERAGE_THRESHOLD    Override --threshold

Exit codes:
  0  Coverage meets threshold
  1  Coverage below threshold
  2  Usage/configuration error

Examples:
  # Check overall coverage (shell + unit tests)
  $(basename "$0")

  # Check shell test coverage only
  $(basename "$0") --mode shell --threshold 50

  # Generate detailed report
  $(basename "$0") --report --json coverage-report.json
EOF
}

log() {
  echo "[coverage] $*" >&2
}

verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    log "$@"
  fi
}

count_shell_scripts() {
  find "$REPO_ROOT/scripts" -type f -name '*.sh' | wc -l
}

count_shell_tests() {
  find "$REPO_ROOT/tests" -type f -name '*.sh' | wc -l
}

count_ts_tests() {
  find "$REPO_ROOT/tests/unit" -type f \( -name '*.test.ts' -o -name '*.spec.ts' \) 2>/dev/null | wc -l
}

calculate_coverage() {
  local total_scripts
  local total_tests
  local coverage

  if [[ "$MODE" == "shell" ]]; then
    total_scripts=$(count_shell_scripts)
    total_tests=$(count_shell_tests)
  elif [[ "$MODE" == "unit" ]]; then
    # For unit tests, count scripts in scripts/ci/ and other priority areas
    total_scripts=$(find "$REPO_ROOT/scripts/ci" -type f -name '*.sh' | wc -l)
    total_tests=$(count_ts_tests)
  else
    # all mode: combined coverage
    total_scripts=$(count_shell_scripts)
    local shell_tests=$(count_shell_tests)
    local ts_tests=$(count_ts_tests)
    total_tests=$((shell_tests + ts_tests))
  fi

  if [[ $total_scripts -eq 0 ]]; then
    echo "0"
    return
  fi

  # Calculate percentage
  coverage=$(awk "BEGIN {printf \"%.1f\", ($total_tests / $total_scripts) * 100}")
  echo "$coverage"
}

generate_report() {
  local coverage=$1
  local total_scripts
  local total_tests

  if [[ "$MODE" == "shell" ]]; then
    total_scripts=$(count_shell_scripts)
    total_tests=$(count_shell_tests)
  elif [[ "$MODE" == "unit" ]]; then
    total_scripts=$(find "$REPO_ROOT/scripts/ci" -type f -name '*.sh' | wc -l)
    total_tests=$(count_ts_tests)
  else
    total_scripts=$(count_shell_scripts)
    local shell_tests=$(count_shell_tests)
    local ts_tests=$(count_ts_tests)
    total_tests=$((shell_tests + ts_tests))
  fi

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                      Test Coverage Report
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Mode:              $MODE
Total Scripts:     $total_scripts
Total Tests:       $total_tests
Coverage:          ${coverage}%
Threshold:         ${THRESHOLD}%
Status:            $([ "$(echo "$coverage >= $THRESHOLD" | bc -l)" -eq 1 ] && echo "✓ PASS" || echo "✗ FAIL")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

  if [[ "$MODE" == "all" ]]; then
    local shell_scripts=$(count_shell_scripts)
    local shell_tests=$(count_shell_tests)
    local ts_tests=$(count_ts_tests)
    local shell_coverage=$(awk "BEGIN {printf \"%.1f\", ($shell_tests / $shell_scripts) * 100}")

    cat <<EOF
Breakdown:
  Shell Scripts:   $shell_scripts
  Shell Tests:     $shell_tests (${shell_coverage}%)
  TypeScript Tests: $ts_tests

Priority Areas:
  scripts/ci/:     20 scripts → $(find "$REPO_ROOT/tests/unit/ci" -type f -name '*.test.ts' 2>/dev/null | wc -l) tests

EOF
  fi
}

write_json_report() {
  local coverage=$1
  local file=$2
  local total_scripts
  local total_tests

  if [[ "$MODE" == "shell" ]]; then
    total_scripts=$(count_shell_scripts)
    total_tests=$(count_shell_tests)
  elif [[ "$MODE" == "unit" ]]; then
    total_scripts=$(find "$REPO_ROOT/scripts/ci" -type f -name '*.sh' | wc -l)
    total_tests=$(count_ts_tests)
  else
    total_scripts=$(count_shell_scripts)
    local shell_tests=$(count_shell_tests)
    local ts_tests=$(count_ts_tests)
    total_tests=$((shell_tests + ts_tests))
  fi

  local status="pass"
  if [[ "$(echo "$coverage < $THRESHOLD" | bc -l)" -eq 1 ]]; then
    status="fail"
  fi

  cat > "$file" <<EOF
{
  "mode": "$MODE",
  "totalScripts": $total_scripts,
  "totalTests": $total_tests,
  "coverage": $coverage,
  "threshold": $THRESHOLD,
  "status": "$status",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

  verbose "JSON report written to: $file"
}

# ─── Parse Arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --threshold)
      THRESHOLD="$2"
      shift 2
      ;;
    --mode)
      MODE="$2"
      if [[ ! "$MODE" =~ ^(shell|unit|all)$ ]]; then
        log "Error: Invalid mode: $MODE (must be shell|unit|all)"
        exit 2
      fi
      shift 2
      ;;
    --report)
      REPORT=true
      shift
      ;;
    --json)
      JSON_FILE="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    --help)
      show_help
      exit 0
      ;;
    *)
      log "Error: Unknown option: $1"
      show_help
      exit 2
      ;;
  esac
done

# ─── Main ─────────────────────────────────────────────────────────────────────

verbose "Calculating test coverage (mode: $MODE)..."
coverage=$(calculate_coverage)

if [[ "$REPORT" == "true" ]] || [[ "$VERBOSE" == "true" ]]; then
  generate_report "$coverage"
fi

if [[ -n "$JSON_FILE" ]]; then
  write_json_report "$coverage" "$JSON_FILE"
fi

# Check threshold
if [[ "$(echo "$coverage >= $THRESHOLD" | bc -l)" -eq 1 ]]; then
  log "✓ Coverage ${coverage}% meets threshold ${THRESHOLD}%"
  exit 0
else
  log "✗ Coverage ${coverage}% below threshold ${THRESHOLD}%"
  exit 1
fi
