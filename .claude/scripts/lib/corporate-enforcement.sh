#!/usr/bin/env bash
# corporate-enforcement.sh
# Feature #686: Corporate mode enforcement library
#
# This library provides functions to check and enforce corporate mode restrictions
# Philosophy: Deny by default. Minimal surface. Skills can extend.

set -euo pipefail

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/common.sh" 2>/dev/null || true

# Corporate mode configuration
CORPORATE_CONFIG="${CORPORATE_CONFIG:-./config/corporate-mode.yaml}"
AUDIT_LOG_DIR="${HOME}/.claude-tastic/corporate-audit"

# Initialize corporate mode
init_corporate_mode() {
    # Create audit log directory if it doesn't exist
    mkdir -p "${AUDIT_LOG_DIR}"
}

# Check if corporate mode is enabled
is_corporate_mode_enabled() {
    if [[ ! -f "${CORPORATE_CONFIG}" ]]; then
        return 1
    fi

    # Parse YAML to check if corporate mode is enabled
    local enabled
    enabled=$(grep -A 5 "^corporate_mode:" "${CORPORATE_CONFIG}" | grep "enabled:" | awk '{print $2}')

    if [[ "${enabled}" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

# Log operation (allowed or blocked)
log_operation() {
    local operation_type="$1"
    local operation_name="$2"
    local status="$3"  # "allowed" or "blocked"
    local reason="$4"

    if ! is_corporate_mode_enabled; then
        return 0
    fi

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_file="${AUDIT_LOG_DIR}/audit-$(date -u +"%Y-%m-%d").log"

    # Log entry in structured format
    cat >> "${log_file}" <<-EOF
	{
	  "timestamp": "${timestamp}",
	  "operation_type": "${operation_type}",
	  "operation_name": "${operation_name}",
	  "status": "${status}",
	  "reason": "${reason}",
	  "user": "${USER}",
	  "session_id": "${CLAUDE_SESSION_ID:-unknown}"
	}
	EOF
}

# Check if tool is approved
is_tool_approved() {
    local tool_name="$1"

    if ! is_corporate_mode_enabled; then
        log_operation "tool" "${tool_name}" "allowed" "Corporate mode disabled"
        return 0
    fi

    # Check if tool is in approved list
    if grep -A 20 "approved:" "${CORPORATE_CONFIG}" | grep -q "- ${tool_name}"; then
        log_operation "tool" "${tool_name}" "allowed" "Tool in approved list"
        return 0
    fi

    # Check if tool is in blocked list
    if grep -A 5 "blocked:" "${CORPORATE_CONFIG}" | grep -q "- ${tool_name}"; then
        log_operation "tool" "${tool_name}" "blocked" "Tool in blocked list (egress risk)"
        return 1
    fi

    # Check dynamic approvals
    if grep -A 100 "dynamic_approvals:" "${CORPORATE_CONFIG}" | grep -A 50 "tools:" | grep -q "target: \"${tool_name}\""; then
        log_operation "tool" "${tool_name}" "allowed" "Tool dynamically approved"
        return 0
    fi

    # Default deny
    log_operation "tool" "${tool_name}" "blocked" "Tool not in approved list (default deny)"
    return 1
}

# Check if MCP server is approved
is_mcp_server_approved() {
    local server_name="$1"

    if ! is_corporate_mode_enabled; then
        log_operation "mcp" "${server_name}" "allowed" "Corporate mode disabled"
        return 0
    fi

    # Check dynamic approvals
    if grep -A 100 "dynamic_approvals:" "${CORPORATE_CONFIG}" | grep -A 50 "mcp_servers:" | grep -q "target: \"${server_name}\""; then
        log_operation "mcp" "${server_name}" "allowed" "MCP server dynamically approved"
        return 0
    fi

    # Default deny (MCP servers must be explicitly approved)
    log_operation "mcp" "${server_name}" "blocked" "MCP server not approved (default deny)"
    return 1
}

# Check if network host is approved
is_network_host_approved() {
    local host="$1"

    if ! is_corporate_mode_enabled; then
        log_operation "network" "${host}" "allowed" "Corporate mode disabled"
        return 0
    fi

    # GitHub API always approved for configured repos
    if [[ "${host}" == *"api.github.com"* ]]; then
        log_operation "network" "${host}" "allowed" "GitHub API (configured repo)"
        return 0
    fi

    # Check dynamic approvals
    if grep -A 100 "dynamic_approvals:" "${CORPORATE_CONFIG}" | grep -A 50 "network_hosts:" | grep -q "target: \"${host}\""; then
        log_operation "network" "${host}" "allowed" "Network host dynamically approved"
        return 0
    fi

    # Default deny (all other hosts blocked)
    log_operation "network" "${host}" "blocked" "Network host not approved (egress risk)"
    return 1
}

# Check if script command is approved
is_script_command_approved() {
    local command="$1"

    if ! is_corporate_mode_enabled; then
        log_operation "script" "${command}" "allowed" "Corporate mode disabled"
        return 0
    fi

    # Check for blocked network commands
    local blocked_commands=("curl" "wget" "nc" "telnet" "ssh" "scp" "rsync" "ftp")
    for blocked_cmd in "${blocked_commands[@]}"; do
        if [[ "${command}" == *"${blocked_cmd}"* ]]; then
            log_operation "script" "${command}" "blocked" "Script contains blocked network command: ${blocked_cmd}"
            return 1
        fi
    done

    log_operation "script" "${command}" "allowed" "Script command approved"
    return 0
}

# Check if git remote is approved
is_git_remote_approved() {
    local remote="$1"

    if ! is_corporate_mode_enabled; then
        log_operation "git" "${remote}" "allowed" "Corporate mode disabled"
        return 0
    fi

    # Get current repository remote
    local current_remote
    current_remote=$(git remote get-url origin 2>/dev/null || echo "")

    if [[ "${remote}" == "${current_remote}" ]]; then
        log_operation "git" "${remote}" "allowed" "Current repository remote"
        return 0
    fi

    # Check framework repository remote
    local framework_repo
    framework_repo=$(grep "framework_repo:" "${CORPORATE_CONFIG}" | awk '{print $2}' | tr -d '"' || echo "")

    if [[ -n "${framework_repo}" ]] && [[ "${remote}" == *"${framework_repo}"* ]]; then
        log_operation "git" "${remote}" "allowed" "Framework repository remote"
        return 0
    fi

    # Check dynamic approvals
    if grep -A 100 "dynamic_approvals:" "${CORPORATE_CONFIG}" | grep -A 50 "git_remotes:" | grep -q "target: \"${remote}\""; then
        log_operation "git" "${remote}" "allowed" "Git remote dynamically approved"
        return 0
    fi

    # Default deny
    log_operation "git" "${remote}" "blocked" "Git remote not approved (default deny)"
    return 1
}

# Block operation with reason
block_operation() {
    local operation_type="$1"
    local operation_name="$2"
    local reason="$3"

    echo "❌ BLOCKED: ${operation_type} operation '${operation_name}'" >&2
    echo "Reason: ${reason}" >&2
    echo "" >&2
    echo "This operation is blocked by corporate mode policy." >&2
    echo "To approve this operation, use: /approve-method --type ${operation_type} --target '${operation_name}'" >&2

    log_operation "${operation_type}" "${operation_name}" "blocked" "${reason}"

    return 1
}

# Enforce tool usage
enforce_tool_usage() {
    local tool_name="$1"

    if ! is_tool_approved "${tool_name}"; then
        block_operation "tool" "${tool_name}" "Tool not in approved list (egress risk)"
        return 1
    fi

    return 0
}

# Enforce MCP server usage
enforce_mcp_server_usage() {
    local server_name="$1"

    if ! is_mcp_server_approved "${server_name}"; then
        block_operation "mcp" "${server_name}" "MCP server not approved (must be explicitly approved)"
        return 1
    fi

    return 0
}

# Enforce network access
enforce_network_access() {
    local host="$1"

    if ! is_network_host_approved "${host}"; then
        block_operation "network" "${host}" "Network host not approved (egress risk)"
        return 1
    fi

    return 0
}

# Enforce script execution
enforce_script_execution() {
    local script_path="$1"

    # Read script content
    if [[ ! -f "${script_path}" ]]; then
        block_operation "script" "${script_path}" "Script file not found"
        return 1
    fi

    # Check for blocked commands in script
    local script_content
    script_content=$(cat "${script_path}")

    if ! is_script_command_approved "${script_content}"; then
        return 1
    fi

    return 0
}

# Enforce git remote operations
enforce_git_remote_operation() {
    local remote="$1"

    if ! is_git_remote_approved "${remote}"; then
        block_operation "git" "${remote}" "Git remote not approved (default deny)"
        return 1
    fi

    return 0
}

# Get audit log summary
get_audit_summary() {
    local date_filter="${1:-$(date -u +"%Y-%m-%d")}"

    if [[ ! -d "${AUDIT_LOG_DIR}" ]]; then
        echo "No audit logs found"
        return
    fi

    local log_file="${AUDIT_LOG_DIR}/audit-${date_filter}.log"

    if [[ ! -f "${log_file}" ]]; then
        echo "No audit logs for date: ${date_filter}"
        return
    fi

    echo "Corporate Mode Audit Summary - ${date_filter}"
    echo "=========================================="
    echo ""

    # Count allowed operations
    local allowed_count
    allowed_count=$(grep -c '"status": "allowed"' "${log_file}" || echo "0")
    echo "Allowed operations: ${allowed_count}"

    # Count blocked operations
    local blocked_count
    blocked_count=$(grep -c '"status": "blocked"' "${log_file}" || echo "0")
    echo "Blocked operations: ${blocked_count}"

    echo ""
    echo "Blocked operations by type:"
    grep '"status": "blocked"' "${log_file}" | grep -o '"operation_type": "[^"]*"' | sort | uniq -c || true

    echo ""
    echo "Most recent blocked operations:"
    grep '"status": "blocked"' "${log_file}" | tail -5 || true
}

# Initialize on source
init_corporate_mode
