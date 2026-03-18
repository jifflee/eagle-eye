#!/bin/bash
set -euo pipefail
# test-structured-logging.sh
# Test suite for structured logging and metrics collection
# Part of Issue #510: Structured logging and metrics collection

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the structured logging library
source "${SCRIPT_DIR}/lib/structured-logging.sh"

# Test configuration
TEST_LOG_DIR="/tmp/structured-logging-test-$$"
export STRUCTURED_LOG_FILE="${TEST_LOG_DIR}/container.log"
export PROGRESS_LOG_FILE="${TEST_LOG_DIR}/progress.jsonl"
export METRICS_FILE="${TEST_LOG_DIR}/metrics.json"
export STRUCTURED_LOGGING_AUTO_CLEANUP=false

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# ============================================================
# Test Utilities
# ============================================================

setup_test() {
    mkdir -p "$TEST_LOG_DIR"
    init_structured_logging
}

teardown_test() {
    rm -rf "$TEST_LOG_DIR"
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Assertion failed}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_file_exists() {
    local file="$1"
    local message="${2:-File should exist: $file}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_json_valid() {
    local file="$1"
    local message="${2:-JSON should be valid: $file}"

    TESTS_RUN=$((TESTS_RUN + 1))

    if jq empty "$file" 2>/dev/null; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_jsonl_valid() {
    local file="$1"
    local message="${2:-JSON Lines should be valid: $file}"

    TESTS_RUN=$((TESTS_RUN + 1))

    local line_count
    line_count=$(wc -l < "$file")

    local valid_count=0
    while IFS= read -r line; do
        if echo "$line" | jq empty 2>/dev/null; then
            valid_count=$((valid_count + 1))
        fi
    done < "$file"

    if [ "$line_count" -eq "$valid_count" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Total lines: $line_count"
        echo "  Valid JSON: $valid_count"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_jq_equals() {
    local file="$1"
    local jq_filter="$2"
    local expected="$3"
    local message="${4:-JQ assertion failed}"

    TESTS_RUN=$((TESTS_RUN + 1))

    local actual
    actual=$(jq -r "$jq_filter" "$file")

    if [ "$expected" = "$actual" ]; then
        echo -e "${GREEN}✓${NC} $message"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "${RED}✗${NC} $message"
        echo "  Expected: $expected"
        echo "  Actual:   $actual"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

# ============================================================
# Test Cases
# ============================================================

test_initialization() {
    echo ""
    echo "Test: Initialization"
    echo "===================="

    setup_test

    assert_file_exists "$STRUCTURED_LOG_FILE" "Log file created"
    assert_file_exists "$PROGRESS_LOG_FILE" "Progress log created"

    # Check for session_start event
    local event_count
    event_count=$(jq -s '[.[] | select(.event == "session_start")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$event_count" "Session start event logged"

    teardown_test
}

test_basic_logging() {
    echo ""
    echo "Test: Basic Logging"
    echo "==================="

    setup_test

    # Log different levels
    log_info "test_event" '{"key":"value"}' "Test info message"
    log_warn "test_warning" '{}' "Test warning message"
    log_error "test_error" '{}' "Test error message"

    # Verify log entries
    assert_jsonl_valid "$STRUCTURED_LOG_FILE" "All log entries are valid JSON"

    # Check log levels
    local info_count
    info_count=$(jq -s '[.[] | select(.level == "INFO")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "2" "$info_count" "INFO entries logged (session_start + test)"

    local warn_count
    warn_count=$(jq -s '[.[] | select(.level == "WARN")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$warn_count" "WARN entry logged"

    local error_count
    error_count=$(jq -s '[.[] | select(.level == "ERROR")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$error_count" "ERROR entry logged"

    teardown_test
}

test_phase_tracking() {
    echo ""
    echo "Test: Phase Tracking"
    echo "===================="

    setup_test

    # Track a phase
    phase_start "test_phase"
    sleep 1
    phase_complete "test_phase" "complete"

    # Verify phase events
    local phase_start_count
    phase_start_count=$(jq -s '[.[] | select(.event == "phase_start")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$phase_start_count" "Phase start event logged"

    local phase_complete_count
    phase_complete_count=$(jq -s '[.[] | select(.event == "phase_complete")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$phase_complete_count" "Phase complete event logged"

    # Verify duration is tracked
    local duration
    duration=$(jq -s '[.[] | select(.event == "phase_complete")][0].context.duration_ms' "$STRUCTURED_LOG_FILE")
    if [ "$duration" -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Phase duration tracked (${duration}ms)"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Phase duration not tracked"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    teardown_test
}

test_operation_tracking() {
    echo ""
    echo "Test: Operation Tracking"
    echo "========================"

    setup_test

    # Log operations
    log_file_write "/test/file.txt" "create"
    log_file_write "/test/file2.txt" "edit"
    log_git_commit "abc123" "Test commit message"
    log_pr_created "42" "https://github.com/test/repo/pull/42"

    # Verify operation events
    local file_write_count
    file_write_count=$(jq -s '[.[] | select(.event == "file_write")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "2" "$file_write_count" "File write events logged"

    local commit_count
    commit_count=$(jq -s '[.[] | select(.event == "git_commit")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$commit_count" "Git commit event logged"

    local pr_count
    pr_count=$(jq -s '[.[] | select(.event == "pr_created")] | length' "$STRUCTURED_LOG_FILE")
    assert_equals "1" "$pr_count" "PR created event logged"

    teardown_test
}

test_metrics_generation() {
    echo ""
    echo "Test: Metrics Generation"
    echo "========================"

    setup_test

    # Simulate workflow
    phase_start "implement"
    log_file_write "/test/file1.txt" "create"
    log_file_write "/test/file2.txt" "edit"
    log_git_commit "abc123" "Test commit"
    phase_complete "implement" "complete"

    phase_start "test"
    phase_complete "test" "complete"

    # Finalize metrics
    finalize_metrics

    # Verify metrics file
    assert_file_exists "$METRICS_FILE" "Metrics file created"
    assert_json_valid "$METRICS_FILE" "Metrics JSON is valid"

    # Check metrics content
    assert_jq_equals "$METRICS_FILE" '.files_written' "2" "Files written count"
    assert_jq_equals "$METRICS_FILE" '.commits' "1" "Commits count"
    assert_jq_equals "$METRICS_FILE" '.errors' "0" "Errors count"

    # Check phases in metrics
    local has_implement
    has_implement=$(jq -r '.phases | has("implement")' "$METRICS_FILE")
    assert_equals "true" "$has_implement" "Implement phase in metrics"

    local has_test
    has_test=$(jq -r '.phases | has("test")' "$METRICS_FILE")
    assert_equals "true" "$has_test" "Test phase in metrics"

    teardown_test
}

test_progress_log() {
    echo ""
    echo "Test: Progress Log"
    echo "=================="

    setup_test

    # Log events that should appear in progress log
    phase_start "implement"
    log_file_write "/test/file.txt" "create"
    log_git_commit "abc123" "Test commit"
    phase_complete "implement" "complete"

    # Verify progress log has monitoring events
    assert_file_exists "$PROGRESS_LOG_FILE" "Progress log file exists"
    assert_jsonl_valid "$PROGRESS_LOG_FILE" "Progress log entries are valid JSON"

    # Progress log should have phase events but not all events
    local progress_count
    progress_count=$(wc -l < "$PROGRESS_LOG_FILE")

    local total_count
    total_count=$(wc -l < "$STRUCTURED_LOG_FILE")

    if [ "$progress_count" -lt "$total_count" ]; then
        echo -e "${GREEN}✓${NC} Progress log contains subset of events"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Progress log should contain fewer events than main log"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    teardown_test
}

test_log_rotation() {
    echo ""
    echo "Test: Log Rotation"
    echo "=================="

    setup_test

    # Set small max size for testing
    export STRUCTURED_LOG_MAX_LINES=5

    # Log more than max lines
    for i in {1..10}; do
        log_info "test_event" "{\"iteration\":$i}" "Test message $i"
    done

    # Check log size
    local line_count
    line_count=$(wc -l < "$STRUCTURED_LOG_FILE")

    if [ "$line_count" -le 6 ]; then  # 5 + session_start + truncation message
        echo -e "${GREEN}✓${NC} Log truncated to max lines"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Log not truncated (has $line_count lines)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    teardown_test
}

test_json_escaping() {
    echo ""
    echo "Test: JSON Escaping"
    echo "==================="

    setup_test

    # Test message with special characters
    log_info "test_event" '{}' 'Message with "quotes" and \backslash and 	tab'

    # Verify log is still valid JSON
    assert_jsonl_valid "$STRUCTURED_LOG_FILE" "Log with special characters is valid JSON"

    # Verify message was logged
    local message
    message=$(jq -s -r '[.[] | select(.event == "test_event")][0].message' "$STRUCTURED_LOG_FILE")

    if echo "$message" | grep -q "quotes"; then
        echo -e "${GREEN}✓${NC} Message with special characters preserved"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "${RED}✗${NC} Message with special characters not preserved"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    teardown_test
}

# ============================================================
# Run Tests
# ============================================================

echo "=========================================="
echo "Structured Logging Test Suite"
echo "=========================================="

test_initialization
test_basic_logging
test_phase_tracking
test_operation_tracking
test_metrics_generation
test_progress_log
test_log_rotation
test_json_escaping

# ============================================================
# Test Summary
# ============================================================

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total:  $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo "=========================================="

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
