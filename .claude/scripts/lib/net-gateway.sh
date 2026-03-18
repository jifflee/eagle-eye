#!/usr/bin/env bash
# Network Gateway - Central egress control for all outbound network calls
# Routes all network traffic through approval and audit mechanisms

set -euo pipefail

# Default paths
GATEWAY_LOG="${GATEWAY_LOG:-logs/network-audit.log}"
NETWORK_MANIFESTS_DIR="${NETWORK_MANIFESTS_DIR:-scripts/network-manifests}"
APPROVED_HOSTS_CONFIG="${APPROVED_HOSTS_CONFIG:-.config/approved-hosts.json}"
PROJECT_CONFIG="${PROJECT_CONFIG:-.claude/project-config.json}"

# Ensure log directory exists
mkdir -p "$(dirname "$GATEWAY_LOG")"

# Load project config for GitHub repo scoping
load_project_config() {
    if [[ -f "$PROJECT_CONFIG" ]] && command -v jq &>/dev/null; then
        GITHUB_REPO=$(jq -r '.github_repo // ""' "$PROJECT_CONFIG" 2>/dev/null || echo "")
        FRAMEWORK_REPO=$(jq -r '.framework_repo // ""' "$PROJECT_CONFIG" 2>/dev/null || echo "")
        export GITHUB_REPO
        export FRAMEWORK_REPO
    fi
}

# Initialize project config
load_project_config

# Log network call attempt
log_network_call() {
    local status="$1"
    local tool="$2"
    local host="$3"
    local command="$4"
    local reason="${5:-}"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local log_entry="$timestamp $status $tool $host \"$command\""
    if [[ -n "$reason" ]]; then
        log_entry="$log_entry reason=\"$reason\""
    fi

    echo "$log_entry" >> "$GATEWAY_LOG"
}

# Extract host from command
extract_host() {
    local tool="$1"
    shift
    local args=("$@")

    case "$tool" in
        gh)
            # GitHub CLI always uses api.github.com
            echo "api.github.com"
            ;;
        claude)
            # Claude CLI uses Anthropic API
            echo "api.anthropic.com"
            ;;
        curl|wget)
            # Extract URL from arguments
            local url=""
            for arg in "${args[@]}"; do
                if [[ "$arg" =~ ^https?:// ]]; then
                    url="$arg"
                    break
                fi
            done
            if [[ -z "$url" ]]; then
                echo "unknown"
                return 1
            fi
            # Extract host from URL
            echo "$url" | sed -E 's|^https?://([^/]+).*|\1|'
            ;;
        git)
            # Check if it's a network operation
            if [[ "${args[0]:-}" =~ ^(push|pull|fetch|clone)$ ]]; then
                # Try to extract from git config or arguments
                local remote_url=""
                if [[ "${args[0]}" == "clone" && -n "${args[1]:-}" ]]; then
                    remote_url="${args[1]}"
                else
                    # Get remote URL from git config
                    remote_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
                fi

                if [[ "$remote_url" =~ github\.com ]]; then
                    echo "github.com"
                elif [[ "$remote_url" =~ ^https?://([^/]+) ]]; then
                    echo "${BASH_REMATCH[1]}"
                elif [[ "$remote_url" =~ @([^:]+): ]]; then
                    echo "${BASH_REMATCH[1]}"
                else
                    echo "unknown"
                fi
            else
                # Not a network operation
                echo "local"
            fi
            ;;
        docker)
            # Check if it's a pull/push operation
            if [[ "${args[0]:-}" =~ ^(pull|push)$ ]]; then
                # Extract registry from image name
                local image="${args[1]:-}"
                if [[ "$image" =~ ^([^/]+)/.*$ ]]; then
                    echo "${BASH_REMATCH[1]}"
                else
                    echo "docker.io"  # Default Docker Hub
                fi
            else
                echo "local"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

# Check if host is approved
is_host_approved() {
    local host="$1"

    # Special case: local operations always approved
    if [[ "$host" == "local" ]]; then
        return 0
    fi

    # If no config file exists, allow in non-corporate mode
    if [[ ! -f "$APPROVED_HOSTS_CONFIG" ]]; then
        return 0
    fi

    # Check if host is in approved list
    if command -v jq &>/dev/null; then
        local approved
        approved=$(jq -r --arg host "$host" '.approved_hosts // [] | map(select(. == $host or ($host | test("(^|\\.)"+.+"$")))) | length' "$APPROVED_HOSTS_CONFIG" 2>/dev/null || echo "0")
        [[ "$approved" -gt 0 ]]
    else
        # Fallback without jq - check if host appears in file
        grep -q "\"$host\"" "$APPROVED_HOSTS_CONFIG" 2>/dev/null
    fi
}

# Check if corporate mode is enabled
is_corporate_mode() {
    if [[ ! -f "$APPROVED_HOSTS_CONFIG" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        local corporate
        corporate=$(jq -r '.corporate_mode // false' "$APPROVED_HOSTS_CONFIG" 2>/dev/null || echo "false")
        [[ "$corporate" == "true" ]]
    else
        grep -q '"corporate_mode"[[:space:]]*:[[:space:]]*true' "$APPROVED_HOSTS_CONFIG" 2>/dev/null
    fi
}

# Validate GitHub repository scope for gh commands
validate_github_repo_scope() {
    local args=("$@")

    # Skip validation if no repos configured
    if [[ -z "$GITHUB_REPO" ]] && [[ -z "$FRAMEWORK_REPO" ]]; then
        return 0
    fi

    # Check if command specifies a repo
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ "${args[$i]}" == "-R" ]] || [[ "${args[$i]}" == "--repo" ]]; then
            local specified_repo="${args[$i+1]:-}"

            # Check if specified repo matches allowed repos
            if [[ -n "$GITHUB_REPO" ]] && [[ "$specified_repo" == "$GITHUB_REPO" ]]; then
                return 0
            fi
            if [[ -n "$FRAMEWORK_REPO" ]] && [[ "$specified_repo" == "$FRAMEWORK_REPO" ]]; then
                return 0
            fi

            # Repo specified but not in allowed list
            echo "ERROR: GitHub repository scope violation" >&2
            echo "  Specified repo: $specified_repo" >&2
            echo "  Allowed repos: ${GITHUB_REPO:-none}${FRAMEWORK_REPO:+, $FRAMEWORK_REPO}" >&2
            return 1
        fi
    done

    # No repo specified - will use current repo, which is acceptable
    return 0
}

# Main gateway function
net_call() {
    if [[ $# -eq 0 ]]; then
        echo "Error: net_call requires at least one argument" >&2
        return 1
    fi

    local tool="$1"
    shift
    local args=("$@")

    # Extract target host
    local host
    host=$(extract_host "$tool" "${args[@]}")
    local extract_status=$?

    if [[ $extract_status -ne 0 ]]; then
        log_network_call "ERROR" "$tool" "unknown" "$tool ${args[*]}" "failed to extract host"
        echo "Error: Could not determine target host for command: $tool ${args[*]}" >&2
        return 1
    fi

    # Build full command string for logging
    local full_command="$tool ${args[*]}"

    # Validate GitHub repo scope for gh commands in corporate mode
    if is_corporate_mode && [[ "$tool" == "gh" ]]; then
        if ! validate_github_repo_scope "${args[@]}"; then
            log_network_call "BLOCK" "$tool" "$host" "$full_command" "repository scope violation"
            return 1
        fi
    fi

    # Check approval
    local approved=false
    if is_host_approved "$host"; then
        approved=true
    fi

    # Enforce corporate mode restrictions
    if is_corporate_mode && [[ "$approved" == "false" ]] && [[ "$host" != "local" ]]; then
        log_network_call "BLOCK" "$tool" "$host" "$full_command" "host not in approved list"
        echo "ERROR: Network call blocked by corporate policy" >&2
        echo "  Command: $full_command" >&2
        echo "  Target host: $host" >&2
        echo "  Reason: Host not in approved list ($APPROVED_HOSTS_CONFIG)" >&2
        echo "" >&2
        echo "To resolve:" >&2
        echo "  1. Request approval for '$host' from your security team" >&2
        echo "  2. Add '$host' to approved_hosts in $APPROVED_HOSTS_CONFIG" >&2
        return 1
    fi

    # Log and execute
    log_network_call "ALLOW" "$tool" "$host" "$full_command"

    # Execute the actual command
    command "$tool" "${args[@]}"
}

# Network audit preview function
net_audit_preview() {
    local script_name="${1:-current operation}"

    echo "Network calls for $script_name:"
    echo ""

    # Look for network manifest
    local manifest_file=""
    if [[ -f "$NETWORK_MANIFESTS_DIR/$(basename "$script_name" .sh).json" ]]; then
        manifest_file="$NETWORK_MANIFESTS_DIR/$(basename "$script_name" .sh).json"
    fi

    if [[ -n "$manifest_file" ]] && [[ -f "$manifest_file" ]]; then
        if command -v jq &>/dev/null; then
            jq -r '.network_calls[] | "  \(.host) - \(.purpose) (approved: \(if .required then "✓" else "?" end))"' "$manifest_file"
        else
            echo "  (Network manifest found but jq not available for parsing)"
            cat "$manifest_file"
        fi
    else
        echo "  No network manifest found for this script"
        echo "  Expected location: $manifest_file"
    fi

    echo ""

    # Show corporate mode status
    if is_corporate_mode; then
        echo "Corporate mode: ENABLED (unapproved hosts will be blocked)"
    else
        echo "Corporate mode: DISABLED (all hosts allowed, calls logged)"
    fi

    echo ""
}

# Check if --network-audit flag is present in script arguments
check_network_audit_flag() {
    for arg in "$@"; do
        if [[ "$arg" == "--network-audit" ]]; then
            return 0
        fi
    done
    return 1
}

# Export functions for use in other scripts
export -f net_call
export -f net_audit_preview
export -f check_network_audit_flag
export -f is_corporate_mode
export -f is_host_approved
