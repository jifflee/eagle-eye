#!/usr/bin/env bash
set -euo pipefail
#
# Test Distribution Validator
# Validates that test distribution matches the Testing Pyramid standard.
# See: docs/standards/TESTING_PYRAMID.md
#
# Target Distribution:
#   Unit:        60-70%
#   Integration: 20-30%
#   E2E:         5-10%
#
# Usage:
#   ./scripts/validate-test-distribution.sh [--strict] [--json]
#
# Options:
#   --strict  Fail on warnings (distribution outside target but within tolerance)
#   --json    Output results as JSON

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration: Target ranges (percentage)
UNIT_MIN=60
UNIT_MAX=70
INTEGRATION_MIN=20
INTEGRATION_MAX=30
E2E_MIN=5
E2E_MAX=10

# Tolerance: warn if outside target but within tolerance
TOLERANCE=5

# Parse arguments
STRICT=false
JSON_OUTPUT=false
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=true ;;
    --json) JSON_OUTPUT=true ;;
  esac
done

# Count test files in each layer
count_tests() {
  local dir="$1"
  local full_path="$REPO_DIR/tests/$dir"

  if [ ! -d "$full_path" ]; then
    echo "0"
    return
  fi

  # Count test files (*.test.ts, *.test.js, *.spec.ts, *.spec.js, test-*.sh, test_*.py)
  local count=0
  count=$(find "$full_path" -type f \( \
    -name "*.test.ts" -o \
    -name "*.test.js" -o \
    -name "*.spec.ts" -o \
    -name "*.spec.js" -o \
    -name "test-*.sh" -o \
    -name "test_*.py" -o \
    -name "test-*.sh" \
  \) 2>/dev/null | wc -l | tr -d ' ')

  echo "$count"
}

# Count individual test cases within files
count_test_cases() {
  local dir="$1"
  local full_path="$REPO_DIR/tests/$dir"

  if [ ! -d "$full_path" ]; then
    echo "0"
    return
  fi

  # Count it()/test()/assert patterns in test files
  local count=0
  count=$(grep -r -c -h '\b\(it\|test\|assert_\)\s*(' "$full_path" 2>/dev/null | \
    awk '{s+=$1} END {print s+0}')

  echo "$count"
}

# Main validation
UNIT_COUNT=$(count_tests "unit")
INTEGRATION_COUNT=$(count_tests "integration")
E2E_COUNT=$(count_tests "e2e")
TOTAL=$((UNIT_COUNT + INTEGRATION_COUNT + E2E_COUNT))

# Calculate percentages
# Minimum threshold: need at least 3 test files for meaningful distribution validation
MIN_THRESHOLD=3

if [ "$TOTAL" -eq 0 ]; then
  UNIT_PCT=0
  INTEGRATION_PCT=0
  E2E_PCT=0
elif [ "$TOTAL" -lt "$MIN_THRESHOLD" ]; then
  UNIT_PCT=$((UNIT_COUNT * 100 / TOTAL))
  INTEGRATION_PCT=$((INTEGRATION_COUNT * 100 / TOTAL))
  E2E_PCT=$((E2E_COUNT * 100 / TOTAL))
else
  UNIT_PCT=$((UNIT_COUNT * 100 / TOTAL))
  INTEGRATION_PCT=$((INTEGRATION_COUNT * 100 / TOTAL))
  E2E_PCT=$((E2E_COUNT * 100 / TOTAL))
fi

# Validation results
EXIT_CODE=0
WARNINGS=0
ERRORS=0

validate_range() {
  local name="$1"
  local pct="$2"
  local min="$3"
  local max="$4"
  local count="$5"

  if [ "$pct" -ge "$min" ] && [ "$pct" -le "$max" ]; then
    if [ "$JSON_OUTPUT" = false ]; then
      printf "${GREEN}PASS${NC} %-15s %3d%% (%d files) [target: %d-%d%%]\n" "$name" "$pct" "$count" "$min" "$max"
    fi
    return 0
  elif [ "$pct" -ge $((min - TOLERANCE)) ] && [ "$pct" -le $((max + TOLERANCE)) ]; then
    WARNINGS=$((WARNINGS + 1))
    if [ "$JSON_OUTPUT" = false ]; then
      printf "${YELLOW}WARN${NC} %-15s %3d%% (%d files) [target: %d-%d%%]\n" "$name" "$pct" "$count" "$min" "$max"
    fi
    if [ "$STRICT" = true ]; then
      return 1
    fi
    return 0
  else
    ERRORS=$((ERRORS + 1))
    if [ "$JSON_OUTPUT" = false ]; then
      printf "${RED}FAIL${NC} %-15s %3d%% (%d files) [target: %d-%d%%]\n" "$name" "$pct" "$count" "$min" "$max"
    fi
    return 1
  fi
}

# Exit early for JSON output if below threshold
if [ "$JSON_OUTPUT" = true ] && [ "$TOTAL" -lt "$MIN_THRESHOLD" ]; then
  cat <<ENDJSON
{
  "total_test_files": $TOTAL,
  "below_threshold": true,
  "min_threshold": $MIN_THRESHOLD,
  "message": "Insufficient test files for distribution validation",
  "errors": 0,
  "warnings": 0
}
ENDJSON
  exit 0
fi

if [ "$JSON_OUTPUT" = true ]; then
  cat <<ENDJSON
{
  "total_test_files": $TOTAL,
  "layers": {
    "unit": {
      "count": $UNIT_COUNT,
      "percentage": $UNIT_PCT,
      "target_min": $UNIT_MIN,
      "target_max": $UNIT_MAX,
      "status": "$([ "$UNIT_PCT" -ge "$UNIT_MIN" ] && [ "$UNIT_PCT" -le "$UNIT_MAX" ] && echo "pass" || echo "fail")"
    },
    "integration": {
      "count": $INTEGRATION_COUNT,
      "percentage": $INTEGRATION_PCT,
      "target_min": $INTEGRATION_MIN,
      "target_max": $INTEGRATION_MAX,
      "status": "$([ "$INTEGRATION_PCT" -ge "$INTEGRATION_MIN" ] && [ "$INTEGRATION_PCT" -le "$INTEGRATION_MAX" ] && echo "pass" || echo "fail")"
    },
    "e2e": {
      "count": $E2E_COUNT,
      "percentage": $E2E_PCT,
      "target_min": $E2E_MIN,
      "target_max": $E2E_MAX,
      "status": "$([ "$E2E_PCT" -ge "$E2E_MIN" ] && [ "$E2E_PCT" -le "$E2E_MAX" ] && echo "pass" || echo "fail")"
    }
  },
  "errors": $ERRORS,
  "warnings": $WARNINGS
}
ENDJSON
  [ "$ERRORS" -gt 0 ] && exit 1
  [ "$STRICT" = true ] && [ "$WARNINGS" -gt 0 ] && exit 1
  exit 0
fi

# Text output
echo ""
printf "${BLUE}Test Pyramid Distribution Validation${NC}\n"
echo "======================================"
echo ""
printf "Total test files found: %d\n" "$TOTAL"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  printf "${YELLOW}WARNING: No test files found in tests/{unit,integration,e2e}/${NC}\n"
  echo ""
  echo "Expected structure:"
  echo "  tests/unit/         - Unit tests (60-70%)"
  echo "  tests/integration/  - Integration tests (20-30%)"
  echo "  tests/e2e/          - E2E tests (5-10%)"
  exit 0
fi

if [ "$TOTAL" -lt "$MIN_THRESHOLD" ]; then
  printf "${YELLOW}INFO: Only %d test files found (minimum %d needed for distribution validation)${NC}\n" "$TOTAL" "$MIN_THRESHOLD"
  echo ""
  echo "Current counts: unit=$UNIT_COUNT integration=$INTEGRATION_COUNT e2e=$E2E_COUNT"
  echo "Add more tests to enable distribution validation."
  exit 0
fi

validate_range "Unit" "$UNIT_PCT" "$UNIT_MIN" "$UNIT_MAX" "$UNIT_COUNT" || EXIT_CODE=1
validate_range "Integration" "$INTEGRATION_PCT" "$INTEGRATION_MIN" "$INTEGRATION_MAX" "$INTEGRATION_COUNT" || EXIT_CODE=1
validate_range "E2E" "$E2E_PCT" "$E2E_MIN" "$E2E_MAX" "$E2E_COUNT" || EXIT_CODE=1

echo ""
echo "--------------------------------------"
if [ "$ERRORS" -gt 0 ]; then
  printf "${RED}Distribution does not meet pyramid standard.${NC}\n"
elif [ "$WARNINGS" -gt 0 ]; then
  printf "${YELLOW}Distribution has warnings (within tolerance).${NC}\n"
else
  printf "${GREEN}Distribution meets pyramid standard.${NC}\n"
fi
echo ""

exit $EXIT_CODE
