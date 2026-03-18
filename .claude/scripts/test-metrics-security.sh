#!/bin/bash
set -euo pipefail
# scripts/test-metrics-security.sh - Metrics Security Validation Test Suite
# size-ok: comprehensive security test suite for metrics system validation
#
# Purpose:
#   Validates security measures for the metrics/telemetry system (Issue #165):
#   - Field length validation
#   - Secret pattern detection
#   - Shell injection detection
#   - Model enum validation
#   - Commit hash validation
#   - Agent name validation
#   - Read-time sanitization
#
# Usage:
#   ./scripts/test-metrics-security.sh              # Run all tests
#   ./scripts/test-metrics-security.sh --quick      # Quick validation only
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

# Don't use set -e as we need to handle test failures gracefully

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
TESTS_PASSED=0
TESTS_FAILED=0
QUICK_MODE=false

# Use a temporary metrics file for tests
export CLAUDE_METRICS_DIR=$(mktemp -d)
export CLAUDE_METRICS_FILE="$CLAUDE_METRICS_DIR/test-metrics.jsonl"
export CLAUDE_METRICS_SKIP_AGENT_VALIDATION=true  # Skip for testing

# Cleanup on exit
cleanup() {
    rm -rf "$CLAUDE_METRICS_DIR"
}
trap cleanup EXIT

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick)
            QUICK_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--quick]"
            echo "  --quick  Quick validation only"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Test helpers
test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

print_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Test function: run metrics-log.sh and check result
run_metrics_test() {
    local description="$1"
    local should_fail="$2"  # "true" or "false"
    local expected_error="$3"  # Pattern to match in error output
    shift 3
    local args=("$@")

    local result
    local exit_code=0
    result=$("$SCRIPT_DIR/metrics-log.sh" "${args[@]}" 2>&1) || exit_code=$?

    if [ "$should_fail" = "true" ]; then
        if [ $exit_code -ne 0 ] && [[ "$result" == *"$expected_error"* ]]; then
            test_pass "$description"
        else
            test_fail "$description (exit_code=$exit_code, expected error: '$expected_error')"
            echo "    Output: $result"
        fi
    else
        if [ $exit_code -eq 0 ]; then
            test_pass "$description"
        else
            test_fail "$description"
            echo "    Output: $result"
        fi
    fi
}

# =============================================================================
# TEST SUITE
# =============================================================================

print_header "METRICS SECURITY TEST SUITE (Issue #165)"
echo "Metrics dir: $CLAUDE_METRICS_DIR"
echo "Metrics file: $CLAUDE_METRICS_FILE"
echo ""

# -----------------------------------------------------------------------------
print_header "1. FIELD LENGTH VALIDATION"
# -----------------------------------------------------------------------------

# Test: Normal operation works
run_metrics_test "Normal operation succeeds" "false" "" \
    --start --agent "test-agent" --model "haiku" --phase "test"

# Test: Task description > 500 chars rejected
LONG_TASK=$(python3 -c "print('x' * 600)")
run_metrics_test "Task description > 500 chars rejected" "true" "exceeds max length" \
    --start --agent "test-agent" --model "haiku" --phase "test" --task "$LONG_TASK"

# Test: Agent name > 64 chars rejected
LONG_AGENT=$(python3 -c "print('a' * 70)")
run_metrics_test "Agent name > 64 chars rejected" "true" "exceeds max length" \
    --start --agent "$LONG_AGENT" --model "haiku" --phase "test"

# Test: Notes > 1000 chars rejected (via --end)
LONG_NOTES=$(python3 -c "print('n' * 1100)")
ID=$("$SCRIPT_DIR/metrics-log.sh" --start --agent "test" --model "haiku" --phase "other" 2>/dev/null)
run_metrics_test "Notes > 1000 chars rejected" "true" "exceeds max length" \
    --end --id "$ID" --status "completed" --notes "$LONG_NOTES"

# Test: Valid length task accepted
run_metrics_test "Task at limit (500 chars) accepted" "false" "" \
    --start --agent "test-agent" --model "haiku" --phase "test" \
    --task "$(python3 -c "print('x' * 500)")"

# -----------------------------------------------------------------------------
print_header "2. SECRET PATTERN DETECTION"
# -----------------------------------------------------------------------------

# Test: AWS key detected
run_metrics_test "AWS key (AKIA...) detected" "true" "AWS access key" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task "Connect to AKIAIOSFODNN7EXAMPLE"

# Test: OpenAI key detected
run_metrics_test "OpenAI key (sk-...) detected" "true" "API key" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task "Use sk-1234567890abcdefghij1234567890"

# Test: GitHub token detected
run_metrics_test "GitHub token (ghp_...) detected" "true" "GitHub token" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task "Clone with ghp_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

# Test: Private key header detected
run_metrics_test "Private key header detected" "true" "private key" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task "Key is: -----BEGIN PRIVATE KEY-----"

# Test: Safe text with similar patterns allowed
run_metrics_test "Safe text 'sky-high' allowed (not sk-...)" "false" "" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task "Build sky-high quality code"

# -----------------------------------------------------------------------------
print_header "3. SHELL INJECTION DETECTION"
# -----------------------------------------------------------------------------

# Test: Command substitution $() rejected
run_metrics_test "Shell substitution \$(command) rejected" "true" "shell substitution" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task 'Run $(rm -rf /)'

# Test: Backtick substitution rejected
run_metrics_test "Backtick substitution rejected" "true" "shell substitution" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task 'Run `whoami`'

# Test: Script tag injection rejected
run_metrics_test "Script tag injection rejected" "true" "script injection" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task '<script>alert(1)</script>'

# Test: JavaScript URL rejected
run_metrics_test "JavaScript URL rejected" "true" "script injection" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task 'Click javascript:alert(1)'

# Test: Safe shell-like text allowed
run_metrics_test "Safe text with dollar signs allowed" "false" "" \
    --start --agent "test" --model "haiku" --phase "other" \
    --task 'Fix bug #123 worth $500'

# -----------------------------------------------------------------------------
print_header "4. MODEL ENUM VALIDATION"
# -----------------------------------------------------------------------------

# Test: Valid models accepted
run_metrics_test "Model 'haiku' accepted" "false" "" \
    --start --agent "test" --model "haiku" --phase "other"

run_metrics_test "Model 'sonnet' accepted" "false" "" \
    --start --agent "test" --model "sonnet" --phase "other"

run_metrics_test "Model 'opus' accepted" "false" "" \
    --start --agent "test" --model "opus" --phase "other"

# Test: Invalid model rejected
run_metrics_test "Invalid model 'gpt-4' rejected" "true" "must be one of: haiku, sonnet, opus" \
    --start --agent "test" --model "gpt-4" --phase "other"

run_metrics_test "Invalid model 'claude-3' rejected" "true" "must be one of" \
    --start --agent "test" --model "claude-3" --phase "other"

# -----------------------------------------------------------------------------
print_header "5. COMMIT HASH VALIDATION"
# -----------------------------------------------------------------------------

# Test: Valid short hash accepted
ID=$("$SCRIPT_DIR/metrics-log.sh" --start --agent "test" --model "haiku" --phase "other" 2>/dev/null)
run_metrics_test "Short commit hash (7 chars) accepted" "false" "" \
    --end --id "$ID" --status "completed" --commit "abc1234"

# Test: Valid full hash accepted
ID=$("$SCRIPT_DIR/metrics-log.sh" --start --agent "test" --model "haiku" --phase "other" 2>/dev/null)
run_metrics_test "Full commit hash (40 chars) accepted" "false" "" \
    --end --id "$ID" --status "completed" --commit "abc123def456789012345678901234567890abcd"

# Test: Invalid hash rejected
ID=$("$SCRIPT_DIR/metrics-log.sh" --start --agent "test" --model "haiku" --phase "other" 2>/dev/null)
run_metrics_test "Invalid commit hash rejected" "true" "valid git hash" \
    --end --id "$ID" --status "completed" --commit "not-a-hash!"

# Test: Too short hash rejected
ID=$("$SCRIPT_DIR/metrics-log.sh" --start --agent "test" --model "haiku" --phase "other" 2>/dev/null)
run_metrics_test "Too short hash (6 chars) rejected" "true" "valid git hash" \
    --end --id "$ID" --status "completed" --commit "abc123"

# -----------------------------------------------------------------------------
print_header "6. READ-TIME SANITIZATION"
# -----------------------------------------------------------------------------

if [ "$QUICK_MODE" = "false" ]; then
    # Create metrics file with valid and corrupt entries
    echo '{"agent":"test","model":"haiku","phase":"other","status":"completed"}' > "$CLAUDE_METRICS_FILE"
    echo 'this is not valid json' >> "$CLAUDE_METRICS_FILE"
    echo '{"agent":"test2","model":"sonnet","phase":"test","status":"completed"}' >> "$CLAUDE_METRICS_FILE"

    # Test: Query handles corrupt entries
    RESULT=$("$SCRIPT_DIR/metrics-query.sh" --json 2>&1)
    if echo "$RESULT" | jq -e . >/dev/null 2>&1; then
        test_pass "Query handles corrupt JSONL entries gracefully"
    else
        test_fail "Query handles corrupt JSONL entries gracefully"
    fi

    # Test: Corrupt line skipped (should have 2 entries, not 3)
    COUNT=$(echo "$RESULT" | jq -r '.total_invocations // 0')
    if [ "$COUNT" -eq 2 ]; then
        test_pass "Corrupt entry skipped (2 valid entries counted)"
    else
        test_fail "Corrupt entry skipped (expected 2, got $COUNT)"
    fi

    # Clean up test file
    rm -f "$CLAUDE_METRICS_FILE"
fi

# -----------------------------------------------------------------------------
print_header "7. --LOG ACTION VALIDATION"
# -----------------------------------------------------------------------------

# Test: Valid JSON via --log accepted
echo '{"agent":"test","model":"haiku","phase":"other","task_description":"Test"}' | \
    "$SCRIPT_DIR/metrics-log.sh" --log 2>/dev/null
if [ $? -eq 0 ]; then
    test_pass "Valid JSON via --log accepted"
else
    test_fail "Valid JSON via --log accepted"
fi

# Test: Invalid model in JSON rejected
RESULT=$(echo '{"agent":"test","model":"invalid","phase":"other"}' | "$SCRIPT_DIR/metrics-log.sh" --log 2>&1)
if [[ "$RESULT" == *"must be one of"* ]]; then
    test_pass "Invalid model in JSON via --log rejected"
else
    test_fail "Invalid model in JSON via --log rejected (output: $RESULT)"
fi

# Test: Secret in JSON task_description rejected
RESULT=$(echo '{"agent":"test","model":"haiku","task_description":"Use AKIAIOSFODNN7EXAMPLE"}' | "$SCRIPT_DIR/metrics-log.sh" --log 2>&1)
if [[ "$RESULT" == *"AWS access key"* ]]; then
    test_pass "Secret in JSON task_description rejected"
else
    test_fail "Secret in JSON task_description rejected (output: $RESULT)"
fi

# -----------------------------------------------------------------------------
print_header "8. SDLC PHASE ENUM VALIDATION (Issue #833)"
# -----------------------------------------------------------------------------

# Test: All valid SDLC phases accepted
for valid_phase in spec design implement test docs review deploy other; do
    run_metrics_test "Phase '$valid_phase' accepted" "false" "" \
        --start --agent "test" --model "haiku" --phase "$valid_phase"
done

# Test: Invalid phases rejected
run_metrics_test "Invalid phase 'dev' rejected" "true" "must be one of" \
    --start --agent "test" --model "haiku" --phase "dev"

run_metrics_test "Invalid phase 'testing' rejected" "true" "must be one of" \
    --start --agent "test" --model "haiku" --phase "testing"

run_metrics_test "Invalid phase 'agent-invocation' rejected" "true" "must be one of" \
    --start --agent "test" --model "haiku" --phase "agent-invocation"

run_metrics_test "Invalid phase 'qa' rejected" "true" "must be one of" \
    --start --agent "test" --model "haiku" --phase "qa"

# =============================================================================
# SUMMARY
# =============================================================================

print_header "TEST SUMMARY"
echo ""
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [ $TESTS_FAILED -gt 0 ]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
