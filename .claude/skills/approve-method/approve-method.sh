#!/usr/bin/env bash
# approve-method.sh
# Feature #686: Approve additional methods for corporate mode
#
# This script manages the approved methods list in corporate mode

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${SCRIPT_DIR}")/../scripts/lib/common.sh" 2>/dev/null || true

# Source corporate enforcement
# shellcheck source=scripts/lib/corporate-enforcement.sh
source "$(dirname "${SCRIPT_DIR}")/../scripts/lib/corporate-enforcement.sh" 2>/dev/null || true

# Configuration
CORPORATE_CONFIG="${CORPORATE_CONFIG:-./config/corporate-mode.yaml}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Usage information
usage() {
    cat <<EOF
Usage: approve-method.sh [OPTIONS]

Approve or revoke methods in corporate mode.

OPTIONS:
    --type TYPE         Type of method: mcp, tool, network, git
    --target TARGET     Target to approve/revoke (e.g., "WebSearch", "context7")
    --reason REASON     Reason for approval (required for approvals)
    --list              List current approvals
    --revoke            Revoke an approval
    -h, --help          Show this help message

EXAMPLES:
    # Approve an MCP server
    approve-method.sh --type mcp --target "context7" --reason "Docs lookup"

    # Approve a tool
    approve-method.sh --type tool --target "WebSearch" --reason "Research tasks"

    # List current approvals
    approve-method.sh --list

    # Revoke an approval
    approve-method.sh --revoke --type mcp --target "context7"

EOF
    exit 0
}

# Parse arguments
TYPE=""
TARGET=""
REASON=""
LIST_MODE=false
REVOKE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)
            TYPE="$2"
            shift 2
            ;;
        --target)
            TARGET="$2"
            shift 2
            ;;
        --reason)
            REASON="$2"
            shift 2
            ;;
        --list)
            LIST_MODE=true
            shift
            ;;
        --revoke)
            REVOKE_MODE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Check if corporate mode config exists
if [[ ! -f "${CORPORATE_CONFIG}" ]]; then
    echo -e "${RED}❌ Error: Corporate mode configuration not found: ${CORPORATE_CONFIG}${NC}" >&2
    exit 1
fi

# Function to list approvals
list_approvals() {
    echo "Corporate Mode Approved Methods"
    echo "================================"
    echo ""

    # Get max limits
    local max_mcp max_tools max_network max_git
    max_mcp=$(grep -A 5 "max_dynamic_approvals:" "${CORPORATE_CONFIG}" | grep "mcp_servers:" | awk '{print $2}')
    max_tools=$(grep -A 5 "max_dynamic_approvals:" "${CORPORATE_CONFIG}" | grep "tools:" | awk '{print $2}')
    max_network=$(grep -A 5 "max_dynamic_approvals:" "${CORPORATE_CONFIG}" | grep "network_hosts:" | awk '{print $2}')
    max_git=$(grep -A 5 "max_dynamic_approvals:" "${CORPORATE_CONFIG}" | grep "git_remotes:" | awk '{print $2}')

    # Count current approvals (placeholder - real implementation would parse YAML properly)
    local count_mcp=0
    local count_tools=0
    local count_network=0
    local count_git=0

    # Filter by type if specified
    if [[ -n "${TYPE}" ]]; then
        case "${TYPE}" in
            mcp)
                echo "MCP Servers (${count_mcp}/${max_mcp}):"
                echo "  (Implementation pending - will show approved MCP servers)"
                ;;
            tool)
                echo "Tools (${count_tools}/${max_tools}):"
                echo "  (Implementation pending - will show approved tools)"
                ;;
            network)
                echo "Network Hosts (${count_network}/${max_network}):"
                echo "  (Implementation pending - will show approved network hosts)"
                ;;
            git)
                echo "Git Remotes (${count_git}/${max_git}):"
                echo "  (Implementation pending - will show approved git remotes)"
                ;;
            *)
                echo -e "${RED}❌ Invalid type: ${TYPE}${NC}" >&2
                echo "Valid types: mcp, tool, network, git"
                exit 1
                ;;
        esac
    else
        # Show all types
        echo "MCP Servers (${count_mcp}/${max_mcp}):"
        echo "  (none)"
        echo ""
        echo "Tools (${count_tools}/${max_tools}):"
        echo "  (none)"
        echo ""
        echo "Network Hosts (${count_network}/${max_network}):"
        echo "  (none)"
        echo ""
        echo "Git Remotes (${count_git}/${max_git}):"
        echo "  (none)"
    fi

    echo ""
    echo "Note: Full YAML parsing implementation pending. Use this interface to define approvals."
}

# Function to approve a method
approve_method() {
    # Validate inputs
    if [[ -z "${TYPE}" ]]; then
        echo -e "${RED}❌ Error: --type is required${NC}" >&2
        exit 1
    fi

    if [[ -z "${TARGET}" ]]; then
        echo -e "${RED}❌ Error: --target is required${NC}" >&2
        exit 1
    fi

    if [[ -z "${REASON}" ]]; then
        echo -e "${RED}❌ Error: --reason is required for approvals${NC}" >&2
        exit 1
    fi

    # Validate type
    case "${TYPE}" in
        mcp|tool|network|git)
            ;;
        *)
            echo -e "${RED}❌ Invalid type: ${TYPE}${NC}" >&2
            echo "Valid types: mcp, tool, network, git"
            exit 1
            ;;
    esac

    # Get current user and timestamp
    local user="${USER}@$(hostname)"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Log the approval
    echo -e "${GREEN}✅ Approved: ${TYPE} '${TARGET}'${NC}"
    echo "Reason: ${REASON}"
    echo "Approved by: ${user}"
    echo "Approved at: ${timestamp}"
    echo ""

    # Note: Full implementation would update YAML file
    echo -e "${YELLOW}Note: YAML update implementation pending.${NC}"
    echo "This approval would be added to ${CORPORATE_CONFIG}"
    echo ""

    # Show approval structure
    cat <<EOF
Approval structure:
  - type: ${TYPE}
    target: "${TARGET}"
    reason: "${REASON}"
    approved_by: "${user}"
    approved_at: "${timestamp}"
    expires_at: null

EOF

    # Log in audit trail
    log_operation "${TYPE}" "${TARGET}" "approved" "${REASON}" 2>/dev/null || true

    echo "Current approvals:"
    echo "  - MCP servers: 0/10"
    echo "  - Tools: 0/5"
    echo "  - Network hosts: 0/5"
    echo "  - Git remotes: 0/3"
}

# Function to revoke a method
revoke_method() {
    # Validate inputs
    if [[ -z "${TYPE}" ]]; then
        echo -e "${RED}❌ Error: --type is required${NC}" >&2
        exit 1
    fi

    if [[ -z "${TARGET}" ]]; then
        echo -e "${RED}❌ Error: --target is required${NC}" >&2
        exit 1
    fi

    # Note: Full implementation would remove from YAML file
    echo -e "${GREEN}✅ Revoked: ${TYPE} '${TARGET}'${NC}"
    echo ""
    echo -e "${YELLOW}Note: YAML update implementation pending.${NC}"
    echo "This approval would be removed from ${CORPORATE_CONFIG}"
    echo ""

    # Log in audit trail
    log_operation "${TYPE}" "${TARGET}" "revoked" "User requested revocation" 2>/dev/null || true

    echo "Current approvals:"
    echo "  - MCP servers: 0/10"
    echo "  - Tools: 0/5"
    echo "  - Network hosts: 0/5"
    echo "  - Git remotes: 0/3"
}

# Main logic
if ${LIST_MODE}; then
    list_approvals
elif ${REVOKE_MODE}; then
    revoke_method
else
    approve_method
fi
