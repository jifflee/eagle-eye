#!/bin/bash
set -euo pipefail
# parse-ci-logs.sh
# Fetches and parses CI logs to extract actionable error information
#
# Usage:
#   ./scripts/parse-ci-logs.sh <PR_NUMBER>
#
# Outputs JSON with parsed errors and targeted fix suggestions
#
# Exit Codes:
#   0 - Success (logs fetched and parsed)
#   1 - No failed checks found
#   2 - Error fetching logs
#   3 - Invalid arguments

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
for path in "${SCRIPT_DIR}/lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        break
    fi
done

# Parse arguments
PR_NUMBER=""
MAX_ERRORS=20  # Limit errors to prevent overwhelming Claude

while [[ $# -gt 0 ]]; do
  case $1 in
    --max-errors)
      MAX_ERRORS="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 <PR_NUMBER> [OPTIONS]"
      echo ""
      echo "Fetch and parse CI logs to extract actionable error information."
      echo ""
      echo "Options:"
      echo "  --max-errors <N>  Maximum number of errors to extract (default: 20)"
      echo ""
      echo "Output: JSON with parsed errors and fix suggestions"
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
if [[ -z "$PR_NUMBER" ]]; then
  echo '{"error": "PR number required"}' >&2
  exit 3
fi

# Function to get failed check run IDs
get_failed_check_runs() {
  local pr="$1"

  # Get check runs with their details
  gh pr checks "$pr" --json name,state,detailsUrl,workflowName 2>/dev/null | \
    jq -r '.[] | select(.state == "FAILURE") | .detailsUrl' | \
    grep -oE '[0-9]+$' || echo ""
}

# Function to fetch logs for a specific run
fetch_run_logs() {
  local run_id="$1"

  # Get failed job logs only
  gh run view "$run_id" --log-failed 2>/dev/null || echo ""
}

# Function to parse linting errors
parse_lint_errors() {
  local logs="$1"

  echo "$logs" | grep -E '(eslint|prettier|lint)' | \
    grep -E '(error|warning).*\.(js|ts|tsx|jsx|vue|py|go|rs):[0-9]+' | \
    head -n "$MAX_ERRORS" | \
    sed -E 's/^[^/]*(\/[^ ]+):([0-9]+):([0-9]+): (error|warning) (.+)$/{"file":"\1","line":\2,"column":\3,"severity":"\4","message":"\5","type":"lint"}/' || echo ""
}

# Function to parse test failures
parse_test_errors() {
  local logs="$1"

  # Pattern 1: Jest/Vitest style: "FAIL path/to/test.spec.ts"
  # Pattern 2: pytest style: "FAILED tests/test_file.py::test_name"
  # Pattern 3: Go test: "--- FAIL: TestName"
  echo "$logs" | grep -E '(FAIL|FAILED|Error:|AssertionError|Expected)' | \
    grep -v 'npm ERR!' | \
    head -n "$MAX_ERRORS" | \
    awk '
      /FAIL.*\.(spec|test)\.(js|ts|tsx|jsx|py)/ {
        match($0, /FAIL[[:space:]]+([^[:space:]]+)/, arr)
        if (arr[1]) print "{\"file\":\"" arr[1] "\",\"type\":\"test\",\"message\":\"Test file failed\"}"
      }
      /FAILED.*::/ {
        match($0, /FAILED[[:space:]]+([^[:space:]]+)/, arr)
        if (arr[1]) {
          split(arr[1], parts, "::")
          print "{\"file\":\"" parts[1] "\",\"test\":\"" parts[2] "\",\"type\":\"test\",\"message\":\"Test failed\"}"
        }
      }
      /--- FAIL: Test/ {
        match($0, /--- FAIL: ([^[:space:]]+)/, arr)
        if (arr[1]) print "{\"test\":\"" arr[1] "\",\"type\":\"test\",\"message\":\"Go test failed\"}"
      }
      /Expected.*received|AssertionError/ {
        print "{\"type\":\"test\",\"message\":\"" $0 "\"}"
      }
    ' || echo ""
}

# Function to parse TypeScript errors
parse_type_errors() {
  local logs="$1"

  echo "$logs" | grep -E '\.(ts|tsx).*TS[0-9]+:' | \
    head -n "$MAX_ERRORS" | \
    sed -E 's/^[^/]*(\/[^(]+)\(([0-9]+),([0-9]+)\): error (TS[0-9]+): (.+)$/{"file":"\1","line":\2,"column":\3,"code":"\4","message":"\5","type":"typescript"}/' || echo ""
}

# Function to parse build errors
parse_build_errors() {
  local logs="$1"

  echo "$logs" | grep -E '(Error:|ERROR|Build failed|compilation error)' | \
    grep -v 'npm ERR!' | \
    grep -v 'error Command failed' | \
    head -n "$MAX_ERRORS" | \
    awk '
      /Error:/ {
        # Extract file and line if present
        if (match($0, /([^[:space:]]+\.(js|ts|tsx|jsx|py|go|rs)):([0-9]+)/, arr)) {
          print "{\"file\":\"" arr[1] "\",\"line\":" arr[3] ",\"type\":\"build\",\"message\":\"" $0 "\"}"
        } else {
          print "{\"type\":\"build\",\"message\":\"" $0 "\"}"
        }
      }
    ' || echo ""
}

# Function to generate targeted fix prompt based on error type
generate_fix_prompt() {
  local error_type="$1"
  local errors_json="$2"
  local error_count="$3"

  case "$error_type" in
    lint)
      cat <<EOF
CI CHECK FAILED: Linting Errors

Found $error_count linting error(s):

$errors_json

INSTRUCTIONS:
1. Review each linting error listed above
2. Fix the code style issues in the specified files and line numbers
3. Run the linting tool locally to verify fixes
4. Commit your changes with message: fix: resolve linting errors

Focus on the specific files and line numbers mentioned. Common fixes include:
- Adding/removing semicolons
- Fixing indentation
- Removing unused variables/imports
- Fixing quote style consistency
EOF
      ;;
    test)
      cat <<EOF
CI CHECK FAILED: Test Failures

Found $error_count test failure(s):

$errors_json

INSTRUCTIONS:
1. Analyze the failing tests listed above
2. Identify the root cause of each test failure
3. Fix the underlying code or update the test expectations as appropriate
4. Run the tests locally to verify fixes
5. Commit your changes with message: fix: resolve test failures

Focus on understanding why each test is failing and fixing the root cause, not just the test assertions.
EOF
      ;;
    typescript)
      cat <<EOF
CI CHECK FAILED: TypeScript Type Errors

Found $error_count type error(s):

$errors_json

INSTRUCTIONS:
1. Review each type error listed above
2. Fix type mismatches in the specified files and line numbers
3. Run type checking locally to verify fixes
4. Commit your changes with message: fix: resolve type errors

Common fixes include:
- Adding proper type annotations
- Fixing interface/type mismatches
- Handling undefined/null cases
- Updating type definitions
EOF
      ;;
    build)
      cat <<EOF
CI CHECK FAILED: Build Errors

Found $error_count build error(s):

$errors_json

INSTRUCTIONS:
1. Analyze the build errors listed above
2. Fix syntax errors, missing dependencies, or configuration issues
3. Run the build locally to verify fixes
4. Commit your changes with message: fix: resolve build errors

Common issues include:
- Syntax errors
- Missing or incorrect imports
- Configuration problems
- Dependency issues
EOF
      ;;
    *)
      cat <<EOF
CI CHECK FAILED: Multiple Error Types

Found errors in the CI logs. Review the details below:

$errors_json

INSTRUCTIONS:
1. Review all errors listed above
2. Fix the issues systematically
3. Run the relevant checks locally to verify fixes
4. Commit your changes with message: fix: resolve CI failures
EOF
      ;;
  esac
}

# Main execution
log_info "Fetching failed checks for PR #$PR_NUMBER..."

# Get failed check run IDs
FAILED_RUNS=$(get_failed_check_runs "$PR_NUMBER")

if [[ -z "$FAILED_RUNS" ]]; then
  echo '{"status":"no_failures","message":"No failed checks found"}'
  exit 1
fi

# Fetch logs for each failed run
ALL_LOGS=""
RUN_COUNT=0
for run_id in $FAILED_RUNS; do
  log_info "Fetching logs for run $run_id..."
  RUN_LOGS=$(fetch_run_logs "$run_id")
  if [[ -n "$RUN_LOGS" ]]; then
    ALL_LOGS="${ALL_LOGS}${RUN_LOGS}\n"
    ((RUN_COUNT++))
  fi
done

if [[ -z "$ALL_LOGS" ]]; then
  echo '{"status":"error","message":"Could not fetch logs"}'
  exit 2
fi

log_info "Parsing errors from $RUN_COUNT failed run(s)..."

# Parse different error types
LINT_ERRORS=$(parse_lint_errors "$ALL_LOGS")
TEST_ERRORS=$(parse_test_errors "$ALL_LOGS")
TYPE_ERRORS=$(parse_type_errors "$ALL_LOGS")
BUILD_ERRORS=$(parse_build_errors "$ALL_LOGS")

# Combine and categorize errors
LINT_COUNT=$(echo "$LINT_ERRORS" | grep -c '{' || echo "0")
TEST_COUNT=$(echo "$TEST_ERRORS" | grep -c '{' || echo "0")
TYPE_COUNT=$(echo "$TYPE_ERRORS" | grep -c '{' || echo "0")
BUILD_COUNT=$(echo "$BUILD_ERRORS" | grep -c '{' || echo "0")

# Determine primary error type (the one with most errors)
PRIMARY_TYPE="mixed"
MAX_COUNT=0

if [[ $LINT_COUNT -gt $MAX_COUNT ]]; then
  PRIMARY_TYPE="lint"
  MAX_COUNT=$LINT_COUNT
fi
if [[ $TEST_COUNT -gt $MAX_COUNT ]]; then
  PRIMARY_TYPE="test"
  MAX_COUNT=$TEST_COUNT
fi
if [[ $TYPE_COUNT -gt $MAX_COUNT ]]; then
  PRIMARY_TYPE="typescript"
  MAX_COUNT=$TYPE_COUNT
fi
if [[ $BUILD_COUNT -gt $MAX_COUNT ]]; then
  PRIMARY_TYPE="build"
  MAX_COUNT=$BUILD_COUNT
fi

# Collect all errors for JSON output
ALL_ERRORS_JSON="[]"
if [[ $LINT_COUNT -gt 0 ]]; then
  ALL_ERRORS_JSON=$(echo "$ALL_ERRORS_JSON" | jq --argjson errs "[$(echo "$LINT_ERRORS" | tr '\n' ',' | sed 's/,$//')]" '. + $errs')
fi
if [[ $TEST_COUNT -gt 0 ]]; then
  ALL_ERRORS_JSON=$(echo "$ALL_ERRORS_JSON" | jq --argjson errs "[$(echo "$TEST_ERRORS" | tr '\n' ',' | sed 's/,$//')]" '. + $errs')
fi
if [[ $TYPE_COUNT -gt 0 ]]; then
  ALL_ERRORS_JSON=$(echo "$ALL_ERRORS_JSON" | jq --argjson errs "[$(echo "$TYPE_ERRORS" | tr '\n' ',' | sed 's/,$//')]" '. + $errs')
fi
if [[ $BUILD_COUNT -gt 0 ]]; then
  ALL_ERRORS_JSON=$(echo "$ALL_ERRORS_JSON" | jq --argjson errs "[$(echo "$BUILD_ERRORS" | tr '\n' ',' | sed 's/,$//')]" '. + $errs')
fi

TOTAL_ERRORS=$(echo "$ALL_ERRORS_JSON" | jq 'length')

# Format errors for human-readable prompt
FORMATTED_ERRORS=$(echo "$ALL_ERRORS_JSON" | jq -r '
  group_by(.type) |
  map({
    type: .[0].type,
    count: length,
    errors: map(
      if .file then
        "  - \(.file):\(.line // "?") - \(.message // .test // "error")"
      else
        "  - \(.message // .test // "error")"
      end
    )
  }) |
  map("[\(.type | ascii_upcase)] (\(.count) error(s)):\n\(.errors | join("\n"))") |
  join("\n\n")
')

# Generate targeted fix prompt
FIX_PROMPT=$(generate_fix_prompt "$PRIMARY_TYPE" "$FORMATTED_ERRORS" "$TOTAL_ERRORS")

# Build JSON output
jq -n \
  --arg primary_type "$PRIMARY_TYPE" \
  --argjson total_errors "$TOTAL_ERRORS" \
  --argjson lint_count "$LINT_COUNT" \
  --argjson test_count "$TEST_COUNT" \
  --argjson type_count "$TYPE_COUNT" \
  --argjson build_count "$BUILD_COUNT" \
  --argjson errors "$ALL_ERRORS_JSON" \
  --arg fix_prompt "$FIX_PROMPT" \
  '{
    status: "parsed",
    pr_number: ($ENV.PR_NUMBER | tonumber),
    primary_error_type: $primary_type,
    total_errors: $total_errors,
    error_counts: {
      lint: $lint_count,
      test: $test_count,
      typescript: $type_count,
      build: $build_count
    },
    errors: $errors,
    fix_prompt: $fix_prompt
  }'

exit 0
