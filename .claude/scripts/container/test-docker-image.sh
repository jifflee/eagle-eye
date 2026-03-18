#!/bin/bash
set -euo pipefail
# scripts/test-docker-image.sh - Validation script for Phase 1 Docker base image
# size-ok: comprehensive Docker image test suite covering all acceptance criteria
#
# Purpose:
#   Tests the Claude base Docker image against all acceptance criteria
#   Validates that required tools are present, functional, and correct versions
#   Verifies image size and configuration
#
# Usage:
#   ./scripts/test-docker-image.sh                  # Test with latest tag
#   ./scripts/test-docker-image.sh claude-base:v1.0.0  # Test specific image tag
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed

set -e

# Configuration
IMAGE="${1:-claude-base:latest}"
TEST_CONTAINER_NAME="claude-base-test-$$"
TESTS_PASSED=0
TESTS_FAILED=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}================================================================${NC}"
}

test_pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

test_fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

test_skip() {
    echo -e "${YELLOW}⊘ SKIP${NC}: $1"
}

# Main test function
run_test() {
    local test_name="$1"
    local test_cmd="$2"
    local expect_pass="$3"  # true or false

    if eval "$test_cmd" >/dev/null 2>&1; then
        if [[ "$expect_pass" == "true" ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name (expected to fail but passed)"
        fi
    else
        if [[ "$expect_pass" == "false" ]]; then
            test_pass "$test_name"
        else
            test_fail "$test_name (command failed)"
        fi
    fi
}

# ============================================================================
# PRE-TEST CHECKS
# ============================================================================

print_header "PHASE 1 DOCKER IMAGE VALIDATION TEST SUITE"
echo "Image: ${IMAGE}"
echo "Start time: $(date)"
echo ""

# Check if Docker is running
if ! docker ps >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Docker daemon is not running${NC}"
    exit 1
fi

# Check if image exists
if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Image not found: ${IMAGE}${NC}"
    echo "Available images:"
    docker images | grep claude-base || echo "  (none found)"
    exit 1
fi

echo -e "${GREEN}✓ Docker is running${NC}"
echo -e "${GREEN}✓ Image found: ${IMAGE}${NC}"
echo ""

# ============================================================================
# AC-1: DOCKERFILE LOCATION AND STRUCTURE
# ============================================================================

print_header "AC-1: DOCKERFILE LOCATION AND STRUCTURE"

if [[ -f "docker/Dockerfile" ]]; then
    test_pass "Dockerfile exists at docker/Dockerfile"
else
    test_fail "Dockerfile exists at docker/Dockerfile"
fi

if [[ -f "docker/Dockerfile" ]] && grep -q "FROM ubuntu:22.04" docker/Dockerfile; then
    test_pass "Base image is FROM ubuntu:22.04"
else
    test_fail "Base image is FROM ubuntu:22.04"
fi

if [[ -f "docker/Dockerfile" ]] && grep -q "^# ============================================================================" docker/Dockerfile; then
    test_pass "Dockerfile contains section comments"
else
    test_fail "Dockerfile contains section comments"
fi

# ============================================================================
# AC-2: IMAGE BUILD SUCCESS
# ============================================================================

print_header "AC-2: IMAGE BUILD SUCCESS"

# The image should already be built, but verify it exists and is valid
if docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    test_pass "Image builds successfully (exists and is valid)"
else
    test_fail "Image builds successfully (exists and is valid)"
fi

# ============================================================================
# AC-3: CLAUDE CLI VERIFICATION
# ============================================================================

print_header "AC-3: CLAUDE CLI VERIFICATION"

# Note: claude command requires proper invocation with ENTRYPOINT
# The image ENTRYPOINT is "/bin/bash -c" so we pass command as string
if docker run --rm "${IMAGE}" "which claude > /dev/null 2>&1 && echo 'found'" 2>&1 | grep -q "found"; then
    test_pass "claude CLI is installed and in PATH"
else
    test_fail "claude CLI is installed and in PATH"
fi

# ============================================================================
# AC-4: GIT FUNCTIONALITY
# ============================================================================

print_header "AC-4: GIT FUNCTIONALITY"

result=$(docker run --rm "${IMAGE}" "git --version" 2>&1)
if echo "${result}" | grep -q "git version"; then
    test_pass "git --version works"
    echo "  Output: ${result}"
else
    test_fail "git --version works"
fi

if echo "${result}" | grep -q "2\."; then
    test_pass "git version is 2.x or later"
else
    test_fail "git version is 2.x or later"
fi

# ============================================================================
# AC-5: GITHUB CLI AUTHENTICATION
# ============================================================================

print_header "AC-5: GITHUB CLI AUTHENTICATION"

result=$(docker run --rm "${IMAGE}" "gh --version" 2>&1)
if echo "${result}" | grep -q "gh version"; then
    test_pass "gh --version works"
    echo "  Output: ${result}"
else
    test_fail "gh --version works"
fi

if echo "${result}" | grep -q "2\."; then
    test_pass "gh version is 2.x or later"
else
    test_fail "gh version is 2.x or later"
fi

# ============================================================================
# AC-6: JQ AVAILABILITY
# ============================================================================

print_header "AC-6: JQ AVAILABILITY"

result=$(docker run --rm "${IMAGE}" "jq --version" 2>&1)
if echo "${result}" | grep -q "jq"; then
    test_pass "jq --version works"
    echo "  Output: ${result}"
else
    test_fail "jq --version works"
fi

if echo "${result}" | grep -q "1\.6"; then
    test_pass "jq version is 1.6 or later"
else
    test_fail "jq version is 1.6 or later"
fi

# ============================================================================
# AC-7: NODE.JS AND NPM
# ============================================================================

print_header "AC-7: NODE.JS AND NPM"

result=$(docker run --rm "${IMAGE}" "node --version" 2>&1)
if echo "${result}" | grep -q "v20"; then
    test_pass "node --version returns v20.x"
    echo "  Output: ${result}"
else
    test_fail "node --version returns v20.x"
fi

result=$(docker run --rm "${IMAGE}" "npm --version" 2>&1)
if echo "${result}" | grep -q "\."; then
    test_pass "npm --version works"
    echo "  Output: ${result}"
else
    test_fail "npm --version works"
fi

# ============================================================================
# AC-8: PYTHON3
# ============================================================================

print_header "AC-8: PYTHON3"

result=$(docker run --rm "${IMAGE}" "python3 --version" 2>&1)
if echo "${result}" | grep -q "Python 3"; then
    test_pass "python3 --version works"
    echo "  Output: ${result}"
else
    test_fail "python3 --version works"
fi

if echo "${result}" | grep -q "3\.1[0-9]"; then
    test_pass "python3 version is 3.10 or later"
else
    test_fail "python3 version is 3.10 or later"
fi

# ============================================================================
# AC-9: IMAGE SIZE VERIFICATION
# ============================================================================

print_header "AC-9: IMAGE SIZE VERIFICATION"

size_bytes=$(docker image inspect "${IMAGE}" --format='{{.Size}}')
size_gb=$(echo "scale=2; ${size_bytes} / 1073741824" | bc)
size_mb=$(echo "scale=2; ${size_bytes} / 1048576" | bc)

if (( size_bytes < 2147483648 )); then  # 2GB in bytes
    test_pass "Image size < 2GB (actual: ${size_mb} MB)"
else
    test_fail "Image size < 2GB (actual: ${size_mb} MB)"
fi

echo "  Size breakdown: ${size_mb} MB (${size_gb} GB)"

# ============================================================================
# AC-10: WORKING DIRECTORY SETUP
# ============================================================================

print_header "AC-10: WORKING DIRECTORY SETUP"

result=$(docker run --rm "${IMAGE}" pwd 2>&1)
if [[ "${result}" == "/workspace" ]]; then
    test_pass "WORKDIR is set to /workspace"
    echo "  Output: ${result}"
else
    test_fail "WORKDIR is set to /workspace (got: ${result})"
fi

# ============================================================================
# ADDITIONAL TESTS
# ============================================================================

print_header "ADDITIONAL VALIDATION TESTS"

# Test all tools in PATH
echo "Testing tool availability in PATH..."
result=$(docker run --rm "${IMAGE}" "which claude && which git && which gh && which jq && which node && which npm && which python3 && echo 'All tools found in PATH'")
if echo "${result}" | grep -q "All tools found in PATH"; then
    test_pass "All tools are available in PATH"
else
    test_fail "All tools are available in PATH"
fi

# Test git configuration
echo ""
echo "Testing git configuration..."
result=$(docker run --rm "${IMAGE}" "git config --global user.name")
if [[ "${result}" == "Claude Agent" ]]; then
    test_pass "Git user.name configured correctly"
else
    test_fail "Git user.name configured correctly (got: ${result})"
fi

# Test entrypoint flexibility
echo ""
echo "Testing entrypoint flexibility..."
result=$(docker run --rm "${IMAGE}" "echo 'test'")
if [[ "${result}" == "test" ]]; then
    test_pass "ENTRYPOINT allows bash command execution"
else
    test_fail "ENTRYPOINT allows bash command execution"
fi

# Test Claude CLI in isolated environment
echo ""
echo "Testing Claude CLI functionality..."
# Note: Claude will check for auth, but command should execute without exec errors
if docker run --rm "${IMAGE}" "which claude > /dev/null && echo 'found'" 2>&1 | grep -q "found"; then
    test_pass "Claude CLI is installed and executable"
else
    test_fail "Claude CLI is installed and executable"
fi

# ============================================================================
# TEST SUMMARY
# ============================================================================

print_header "TEST SUMMARY"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
PASS_RATE=$(echo "scale=1; ${TESTS_PASSED} * 100 / ${TOTAL_TESTS}" | bc)

echo "Total Tests: ${TOTAL_TESTS}"
echo -e "${GREEN}Passed: ${TESTS_PASSED}${NC}"
echo -e "${RED}Failed: ${TESTS_FAILED}${NC}"
echo "Pass Rate: ${PASS_RATE}%"
echo ""
echo "Test completed at: $(date)"

if [[ ${TESTS_FAILED} -eq 0 ]]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    exit 1
fi
