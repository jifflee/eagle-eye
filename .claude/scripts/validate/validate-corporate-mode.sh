#!/usr/bin/env bash
# validate-corporate-mode.sh
# Validate corporate mode configuration and implementation
#
# Feature #686: Corporate mode - approved methods and restrictions

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "${SCRIPT_DIR}")"

# Validation results
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNING=0

# Helper functions
pass() {
    echo -e "${GREEN}✓${NC} $1"
    CHECKS_PASSED=$((CHECKS_PASSED + 1))
}

fail() {
    echo -e "${RED}✗${NC} $1"
    CHECKS_FAILED=$((CHECKS_FAILED + 1))
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
    CHECKS_WARNING=$((CHECKS_WARNING + 1))
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

# Check if file exists
check_file_exists() {
    local file="$1"
    local description="$2"

    if [[ -f "${PROJECT_ROOT}/${file}" ]]; then
        pass "${description}: ${file}"
        return 0
    else
        fail "${description}: ${file} (missing)"
        return 1
    fi
}

# Check if directory exists
check_dir_exists() {
    local dir="$1"
    local description="$2"

    if [[ -d "${PROJECT_ROOT}/${dir}" ]]; then
        pass "${description}: ${dir}"
        return 0
    else
        fail "${description}: ${dir} (missing)"
        return 1
    fi
}

# Check if script is executable
check_executable() {
    local script="$1"
    local description="$2"

    if [[ -x "${PROJECT_ROOT}/${script}" ]]; then
        pass "${description}: ${script}"
        return 0
    else
        fail "${description}: ${script} (not executable)"
        return 1
    fi
}

# Main validation
main() {
    echo "Corporate Mode Validation"
    echo "========================="
    echo ""

    # Check configuration files
    info "Checking configuration files..."
    check_file_exists "config/corporate-mode.yaml" "Corporate mode config"
    echo ""

    # Check enforcement library
    info "Checking enforcement library..."
    check_file_exists "scripts/lib/corporate-enforcement.sh" "Enforcement library"
    echo ""

    # Check skills
    info "Checking skills..."
    check_dir_exists "core/skills/approve-method" "Approve method skill directory"
    check_file_exists "core/skills/approve-method/SKILL.md" "Approve method skill documentation"
    check_file_exists "core/skills/approve-method/approve-method.sh" "Approve method script"
    check_executable "core/skills/approve-method/approve-method.sh" "Approve method script executable"
    echo ""

    check_dir_exists "core/skills/capture-framework" "Capture framework skill directory"
    check_file_exists "core/skills/capture-framework/SKILL.md" "Capture framework skill documentation"
    check_file_exists "core/skills/capture-framework/capture-framework.sh" "Capture framework script"
    check_executable "core/skills/capture-framework/capture-framework.sh" "Capture framework script executable"
    echo ""

    # Check documentation
    info "Checking documentation..."
    check_file_exists "docs/features/CORPORATE_MODE.md" "Corporate mode feature documentation"
    check_file_exists "README-CORPORATE-MODE.md" "Corporate mode quick start"
    echo ""

    # Check tests
    info "Checking tests..."
    check_dir_exists "tests/corporate-mode" "Corporate mode test directory"
    check_file_exists "tests/corporate-mode/test-enforcement.sh" "Enforcement test suite"
    check_executable "tests/corporate-mode/test-enforcement.sh" "Enforcement test suite executable"
    echo ""

    # Check configuration structure
    info "Checking configuration structure..."

    if grep -q "corporate_mode:" "${PROJECT_ROOT}/config/corporate-mode.yaml"; then
        pass "Corporate mode section exists in config"
    else
        fail "Corporate mode section missing in config"
    fi

    if grep -q "enabled:" "${PROJECT_ROOT}/config/corporate-mode.yaml"; then
        pass "Enabled flag exists in config"
    else
        fail "Enabled flag missing in config"
    fi

    if grep -q "framework_repo:" "${PROJECT_ROOT}/config/corporate-mode.yaml"; then
        pass "Framework repo field exists in config"
    else
        fail "Framework repo field missing in config"
    fi

    if grep -q "approved_methods:" "${PROJECT_ROOT}/config/corporate-mode.yaml"; then
        pass "Approved methods section exists in config"
    else
        fail "Approved methods section missing in config"
    fi

    if grep -q "dynamic_approvals:" "${PROJECT_ROOT}/config/corporate-mode.yaml"; then
        pass "Dynamic approvals section exists in config"
    else
        fail "Dynamic approvals section missing in config"
    fi

    echo ""

    # Check enforcement library functions
    info "Checking enforcement library functions..."

    if grep -q "is_corporate_mode_enabled()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "is_corporate_mode_enabled() function exists"
    else
        fail "is_corporate_mode_enabled() function missing"
    fi

    if grep -q "is_tool_approved()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "is_tool_approved() function exists"
    else
        fail "is_tool_approved() function missing"
    fi

    if grep -q "is_mcp_server_approved()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "is_mcp_server_approved() function exists"
    else
        fail "is_mcp_server_approved() function missing"
    fi

    if grep -q "is_network_host_approved()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "is_network_host_approved() function exists"
    else
        fail "is_network_host_approved() function missing"
    fi

    if grep -q "log_operation()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "log_operation() function exists"
    else
        fail "log_operation() function missing"
    fi

    echo ""

    # Check audit directory creation
    info "Checking audit trail setup..."

    if grep -q "init_corporate_mode()" "${PROJECT_ROOT}/scripts/lib/corporate-enforcement.sh"; then
        pass "init_corporate_mode() function exists"
    else
        fail "init_corporate_mode() function missing"
    fi

    # Check reference in main config
    info "Checking main configuration references..."

    if grep -q "corporate-mode.yaml" "${PROJECT_ROOT}/.claude-tastic.config.yml"; then
        pass "Corporate mode reference in .claude-tastic.config.yml"
    else
        warn "Corporate mode not referenced in .claude-tastic.config.yml"
    fi

    echo ""

    # Summary
    echo "========================="
    echo "Validation Summary"
    echo "========================="
    echo -e "${GREEN}Passed: ${CHECKS_PASSED}${NC}"
    echo -e "${RED}Failed: ${CHECKS_FAILED}${NC}"
    echo -e "${YELLOW}Warnings: ${CHECKS_WARNING}${NC}"
    echo ""

    if [[ ${CHECKS_FAILED} -eq 0 ]]; then
        echo -e "${GREEN}✓ Corporate mode implementation is valid${NC}"
        echo ""
        echo "Next steps:"
        echo "  1. Review configuration: cat config/corporate-mode.yaml"
        echo "  2. Run tests: ./tests/corporate-mode/test-enforcement.sh"
        echo "  3. Read documentation: docs/features/CORPORATE_MODE.md"
        exit 0
    else
        echo -e "${RED}✗ Corporate mode implementation has errors${NC}"
        echo ""
        echo "Please fix the errors listed above before enabling corporate mode."
        exit 1
    fi
}

main "$@"
