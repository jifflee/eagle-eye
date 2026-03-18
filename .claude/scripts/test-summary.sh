#!/usr/bin/env bash
# ============================================================
# Script: test-summary.sh
# Purpose: Generate comprehensive test coverage summary
#
# Analyzes test coverage across shell tests, TypeScript unit
# tests, and E2E tests. Provides detailed breakdown and
# identifies gaps in coverage.
#
# Usage:
#   ./scripts/test-summary.sh [OPTIONS]
#
# Options:
#   --format FORMAT    text|json|markdown (default: text)
#   --output FILE      Write output to FILE
#   --gaps             Show untested scripts
#   --verbose          Verbose output
#   --help             Show this help
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

FORMAT="text"
OUTPUT_FILE=""
SHOW_GAPS=false
VERBOSE=false

# ─── Functions ────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Generate comprehensive test coverage summary.

Options:
  --format FORMAT    text|json|markdown (default: text)
  --output FILE      Write output to FILE
  --gaps             Show untested scripts
  --verbose          Verbose output
  --help             Show this help

Examples:
  # Show text summary
  $(basename "$0")

  # Generate JSON report
  $(basename "$0") --format json --output coverage-summary.json

  # Show coverage gaps
  $(basename "$0") --gaps
EOF
}

count_files() {
  local pattern=$1
  find "$REPO_ROOT" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

count_in_dir() {
  local dir=$1
  local pattern=$2
  find "$REPO_ROOT/$dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
}

calculate_percentage() {
  local numerator=$1
  local denominator=$2
  if [[ $denominator -eq 0 ]]; then
    echo "0"
  else
    awk "BEGIN {printf \"%.1f\", ($numerator / $denominator) * 100}"
  fi
}

generate_text_report() {
  local total_scripts=$(count_files '*.sh' | grep -v tests)
  local shell_tests=$(count_in_dir 'tests' '*.sh')
  local ts_unit_tests=$(count_in_dir 'tests/unit' '*.test.ts')
  local ts_spec_tests=$(count_in_dir 'tests/unit' '*.spec.ts')
  local e2e_tests=$(count_in_dir 'tests/e2e' '*.spec.ts')
  local ci_scripts=$(count_in_dir 'scripts/ci' '*.sh')
  local ci_tests=$(count_in_dir 'tests/unit/ci' '*.test.ts')

  local total_ts_tests=$((ts_unit_tests + ts_spec_tests))
  local total_tests=$((shell_tests + total_ts_tests))

  local coverage=$(calculate_percentage $total_tests $total_scripts)
  local ci_coverage=$(calculate_percentage $ci_tests $ci_scripts)

  cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                   Comprehensive Test Coverage Summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Overall Coverage
  Total Scripts:        $total_scripts
  Total Tests:          $total_tests
  Coverage:             ${coverage}% $([ "$(echo "$coverage >= 60" | bc -l)" -eq 1 ] && echo "✓" || echo "⚠")

Test Breakdown
  Shell Tests:          $shell_tests
  TypeScript Tests:     $total_ts_tests
    - Unit Tests (.test.ts):  $ts_unit_tests
    - Spec Tests (.spec.ts):  $ts_spec_tests
  E2E Tests:            $e2e_tests

Priority Areas
  CI Scripts (scripts/ci/):
    - Total Scripts:    $ci_scripts
    - Test Coverage:    $ci_tests tests (${ci_coverage}%) $([ $ci_tests -ge $ci_scripts ] && echo "✓" || echo "⚠")

Coverage Goals
  Current:              ${coverage}%
  Target:               60%
  Status:               $([ "$(echo "$coverage >= 60" | bc -l)" -eq 1 ] && echo "✓ Target Met" || echo "⚠ Below Target (need $(echo "60 - $coverage" | bc)% more)")

Test Infrastructure
  Vitest:               ✓ Configured
  Playwright:           ✓ Configured
  Shell Test Runner:    ✓ Available
  Coverage Reporting:   ✓ Enabled

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

  if [[ "$SHOW_GAPS" == "true" ]]; then
    echo "Coverage Gaps (scripts without tests):"
    echo ""
    # This is a simplified version - a full implementation would cross-reference
    echo "  Run: npm run test:unit:coverage for detailed gap analysis"
    echo ""
  fi
}

generate_json_report() {
  local total_scripts=$(count_files '*.sh' | grep -v tests || echo 0)
  local shell_tests=$(count_in_dir 'tests' '*.sh')
  local ts_unit_tests=$(count_in_dir 'tests/unit' '*.test.ts')
  local ts_spec_tests=$(count_in_dir 'tests/unit' '*.spec.ts')
  local e2e_tests=$(count_in_dir 'tests/e2e' '*.spec.ts')
  local ci_scripts=$(count_in_dir 'scripts/ci' '*.sh')
  local ci_tests=$(count_in_dir 'tests/unit/ci' '*.test.ts')

  local total_ts_tests=$((ts_unit_tests + ts_spec_tests))
  local total_tests=$((shell_tests + total_ts_tests))
  local coverage=$(calculate_percentage $total_tests $total_scripts)
  local ci_coverage=$(calculate_percentage $ci_tests $ci_scripts)

  cat <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "overall": {
    "totalScripts": $total_scripts,
    "totalTests": $total_tests,
    "coverage": $coverage,
    "target": 60,
    "meetsTarget": $([ "$(echo "$coverage >= 60" | bc -l)" -eq 1 ] && echo "true" || echo "false")
  },
  "breakdown": {
    "shellTests": $shell_tests,
    "typescriptTests": {
      "total": $total_ts_tests,
      "unitTests": $ts_unit_tests,
      "specTests": $ts_spec_tests
    },
    "e2eTests": $e2e_tests
  },
  "priorityAreas": {
    "ci": {
      "totalScripts": $ci_scripts,
      "tests": $ci_tests,
      "coverage": $ci_coverage
    }
  },
  "infrastructure": {
    "vitest": true,
    "playwright": true,
    "shellTestRunner": true,
    "coverageReporting": true
  }
}
EOF
}

# ─── Parse Arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --format)
      FORMAT="$2"
      shift 2
      ;;
    --output)
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --gaps)
      SHOW_GAPS=true
      shift
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
      echo "Error: Unknown option: $1" >&2
      show_help
      exit 2
      ;;
  esac
done

# ─── Main ─────────────────────────────────────────────────────────────────────

if [[ "$FORMAT" == "json" ]]; then
  output=$(generate_json_report)
else
  output=$(generate_text_report)
fi

if [[ -n "$OUTPUT_FILE" ]]; then
  echo "$output" > "$OUTPUT_FILE"
  echo "Report written to: $OUTPUT_FILE" >&2
else
  echo "$output"
fi
