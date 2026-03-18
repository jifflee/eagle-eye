#!/bin/bash
set -euo pipefail
# llm-orchestrator.sh
# Multi-LLM Task Orchestrator - CLI entry point for autonomous task execution
# Part of Epic #263: Multi-LLM orchestration with availability-based routing
#
# Usage:
#   ./scripts/llm-orchestrator.sh --check           # Check LLM availability
#   ./scripts/llm-orchestrator.sh --run             # Trigger work when capacity available
#   ./scripts/llm-orchestrator.sh --dry-run         # Preview what would happen
#
# Configuration:
#   Reads from $FRAMEWORK_DIR/orchestrator.json (default: ~/.claude-agent/orchestrator.json)
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or configuration error
#   2 - LLM unavailable (for --check)
#   3 - Dependencies missing

set -e

# Script metadata
SCRIPT_NAME="llm-orchestrator.sh"
VERSION="1.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/framework-config.sh"

# Configuration
CONFIG_DIR="${FRAMEWORK_DIR}"
CONFIG_FILE="${CONFIG_DIR}/orchestrator.json"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Multi-LLM Task Orchestrator

USAGE:
    $SCRIPT_NAME --check            Check LLM availability
    $SCRIPT_NAME --run              Trigger work when capacity available
    $SCRIPT_NAME --dry-run          Preview what would happen without executing
    $SCRIPT_NAME --config <file>    Use custom config file
    $SCRIPT_NAME --init             Create default configuration file
    $SCRIPT_NAME --help             Show this help

DESCRIPTION:
    Orchestrates autonomous task execution across multiple LLM providers based
    on availability. Checks capacity limits, resource availability, and triggers
    work when conditions are met.

CONFIGURATION:
    Default config location: $FRAMEWORK_DIR/orchestrator.json (default: ~/.claude-agent/orchestrator.json)

    Configuration schema:
    {
      "providers": {
        "claude": {
          "enabled": true,
          "priority": 1,
          "max_concurrent": 2,
          "health_check": "usage-monitor",
          "executor": "container-launch"
        }
      },
      "task_selection": {
        "strategy": "priority",
        "max_issues": 1,
        "milestone": "auto",
        "priority_filter": "P0"
      },
      "scheduling": {
        "interval_minutes": 10,
        "retry_delay_seconds": 300
      }
    }

OPTIONS:
    --check              Check current LLM availability and capacity
                        Exit code 0 = available, 2 = unavailable

    --run               Trigger task execution when capacity is available
                        Uses container-launch.sh to spawn work containers

    --dry-run           Preview execution without making changes
                        Shows what tasks would be triggered

    --config <file>     Use custom configuration file instead of default

    --init              Create default configuration file with examples

    --debug             Enable debug logging

    --help, -h          Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_TOKEN              GitHub authentication (auto-loaded from keychain)
    CLAUDE_CODE_OAUTH_TOKEN   Claude authentication (auto-loaded from keychain)

EXAMPLES:
    # Check if Claude is available for work
    $SCRIPT_NAME --check

    # Trigger work if capacity available
    $SCRIPT_NAME --run

    # Preview what would be executed
    $SCRIPT_NAME --dry-run

    # Create default configuration
    $SCRIPT_NAME --init

    # Use custom config and enable debug logging
    $SCRIPT_NAME --config ./my-config.json --run --debug

SCHEDULING:
    To run automatically on schedule, use cron or launchd:

    Cron example (every 10 minutes):
        */10 * * * * /path/to/scripts/llm-orchestrator.sh --run

    Launchd example (create ~/Library/LaunchAgents/com.claude-tastic.orchestrator.plist):
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.claude-tastic.orchestrator</string>
            <key>ProgramArguments</key>
            <array>
                <string>/path/to/scripts/llm-orchestrator.sh</string>
                <string>--run</string>
            </array>
            <key>StartInterval</key>
            <integer>600</integer>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>

    Then load with: launchctl load ~/Library/LaunchAgents/com.claude-tastic.orchestrator.plist

DEPENDENCIES:
    - Issue #232: Usage monitoring for availability checks
    - check-resource-capacity.sh: Resource capacity checking
    - check-llm-availability.sh: Standalone LLM availability checker (Issue #750)
    - container-launch.sh: Container execution
    - usage-monitor.sh: Claude usage tracking

SEE ALSO:
    - Epic #263: Multi-LLM orchestration architecture
    - Issue #748: Orchestrator CLI entry point (this script)
    - Issue #750: LLM availability checking and decision logic
EOF
}

# Initialize default configuration file
init_config() {
    log_info "Creating default configuration at $CONFIG_FILE"

    # Create directory if it doesn't exist
    if [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$CONFIG_DIR"
        log_info "Created config directory: $CONFIG_DIR"
    fi

    # Create default configuration
    cat > "$CONFIG_FILE" << 'EOF'
{
  "version": "1.0",
  "description": "Multi-LLM Task Orchestrator Configuration",
  "providers": {
    "claude": {
      "enabled": true,
      "priority": 1,
      "max_concurrent": 2,
      "health_check": "usage-monitor",
      "executor": "container-launch",
      "notes": "Primary LLM provider via Claude Code"
    }
  },
  "task_selection": {
    "strategy": "priority",
    "max_issues": 1,
    "milestone": "auto",
    "priority_filter": "P0",
    "notes": "Select tasks by priority (P0 > P1 > P2 > P3), process 1 at a time"
  },
  "scheduling": {
    "interval_minutes": 10,
    "retry_delay_seconds": 300,
    "notes": "Check every 10 minutes, retry failed tasks after 5 minutes"
  },
  "capacity_checks": {
    "check_token_usage": true,
    "check_resource_usage": true,
    "check_container_count": true,
    "notes": "Enable all capacity checks before spawning containers"
  }
}
EOF

    log_success "Default configuration created: $CONFIG_FILE"
    log_info "Edit this file to customize orchestrator behavior"
    log_info "Then run: $SCRIPT_NAME --check"
}

# Load configuration from file
load_config() {
    local config_file="$1"

    if [ ! -f "$config_file" ]; then
        log_error "Configuration file not found: $config_file"
        log_error "Run '$SCRIPT_NAME --init' to create a default configuration"
        exit 1
    fi

    # Validate JSON syntax
    if ! jq empty "$config_file" 2>/dev/null; then
        log_error "Invalid JSON in configuration file: $config_file"
        exit 1
    fi

    # Read configuration
    CONFIG=$(cat "$config_file")
    log_debug "Configuration loaded from $config_file"
}

# Check if Claude is available (usage limits and health)
check_claude_availability() {
    local usage_monitor="${SCRIPT_DIR}/usage-monitor.sh"

    if [ ! -x "$usage_monitor" ]; then
        log_warn "usage-monitor.sh not found or not executable"
        log_warn "Assuming Claude is available (no usage monitoring)"
        echo '{"available": true, "reason": "no usage monitoring available"}'
        return 0
    fi

    # Get usage status
    local usage_json
    usage_json=$("$usage_monitor" --format json 2>/dev/null) || {
        log_warn "Failed to get usage status, assuming available"
        echo '{"available": true, "reason": "usage check failed"}'
        return 0
    }

    # Check if within limits
    local session_available weekly_available
    session_available=$(echo "$usage_json" | jq -r '.session_window.available // true')
    weekly_available=$(echo "$usage_json" | jq -r '.weekly_window.available // true')

    if [ "$session_available" = "true" ] && [ "$weekly_available" = "true" ]; then
        local session_pct weekly_pct
        session_pct=$(echo "$usage_json" | jq -r '.session_window.usage_percent // 0')
        weekly_pct=$(echo "$usage_json" | jq -r '.weekly_window.usage_percent // 0')

        echo "{\"available\": true, \"reason\": \"within limits\", \"session_usage_pct\": $session_pct, \"weekly_usage_pct\": $weekly_pct}"
        return 0
    else
        local reason="capacity exhausted"
        if [ "$session_available" != "true" ]; then
            reason="session limit exceeded"
        elif [ "$weekly_available" != "true" ]; then
            reason="weekly limit exceeded"
        fi

        echo "{\"available\": false, \"reason\": \"$reason\"}"
        return 2
    fi
}

# Check resource capacity (CPU/memory)
check_resource_capacity() {
    local resource_check="${SCRIPT_DIR}/check-resource-capacity.sh"

    if [ ! -x "$resource_check" ]; then
        log_warn "check-resource-capacity.sh not found or not executable"
        log_warn "Assuming resources are available (no resource monitoring)"
        echo '{"has_capacity": true, "reason": "no resource monitoring available"}'
        return 0
    fi

    # Get resource status
    local resource_json
    resource_json=$("$resource_check" 2>/dev/null) || {
        log_warn "Failed to check resource capacity, assuming available"
        echo '{"has_capacity": true, "reason": "resource check failed"}'
        return 0
    }

    echo "$resource_json"

    # Check if capacity available
    local has_capacity
    has_capacity=$(echo "$resource_json" | jq -r '.has_capacity // true')

    if [ "$has_capacity" = "true" ]; then
        return 0
    else
        return 2
    fi
}

# Check overall availability (combines all checks)
# Note: For a standalone availability checker with enhanced features,
# see check-llm-availability.sh (feature #750)
check_availability() {
    local config_enabled check_tokens check_resources

    # Check if provider is enabled in config
    config_enabled=$(echo "$CONFIG" | jq -r '.providers.claude.enabled // true')
    if [ "$config_enabled" != "true" ]; then
        log_warn "Claude provider is disabled in configuration"
        echo '{"available": false, "reason": "provider disabled in config"}'
        return 2
    fi

    # Get capacity check settings from config
    check_tokens=$(echo "$CONFIG" | jq -r '.capacity_checks.check_token_usage // true')
    check_resources=$(echo "$CONFIG" | jq -r '.capacity_checks.check_resource_usage // true')

    # Check 1: Token usage limits
    local claude_status
    if [ "$check_tokens" = "true" ]; then
        log_debug "Checking Claude usage limits..."
        claude_status=$(check_claude_availability)
        local claude_result=$?

        if [ $claude_result -ne 0 ]; then
            local reason
            reason=$(echo "$claude_status" | jq -r '.reason // "unknown"')
            log_info "Claude unavailable: $reason"
            echo "$claude_status"
            return 2
        fi
        log_debug "Claude usage check passed"
    else
        log_debug "Token usage check disabled"
        claude_status='{"available": true, "reason": "check disabled"}'
    fi

    # Check 2: Resource capacity
    local resource_status
    if [ "$check_resources" = "true" ]; then
        log_debug "Checking resource capacity..."
        resource_status=$(check_resource_capacity)
        local resource_result=$?

        if [ $resource_result -ne 0 ]; then
            local reason
            reason=$(echo "$resource_status" | jq -r '.reason // "unknown"')
            log_info "Resources unavailable: $reason"

            # Combine status
            jq -cn \
                --argjson claude "$claude_status" \
                --argjson resource "$resource_status" \
                '{
                    available: false,
                    reason: "resource capacity exhausted",
                    checks: {
                        claude: $claude,
                        resources: $resource
                    }
                }'
            return 2
        fi
        log_debug "Resource capacity check passed"
    else
        log_debug "Resource capacity check disabled"
        resource_status='{"has_capacity": true, "reason": "check disabled"}'
    fi

    # All checks passed
    log_success "All availability checks passed"
    jq -cn \
        --argjson claude "$claude_status" \
        --argjson resource "$resource_status" \
        '{
            available: true,
            reason: "all checks passed",
            checks: {
                claude: $claude,
                resources: $resource
            }
        }'
    return 0
}

# Get next task to execute based on configuration
get_next_task() {
    local strategy max_issues milestone priority_filter

    strategy=$(echo "$CONFIG" | jq -r '.task_selection.strategy // "priority"')
    max_issues=$(echo "$CONFIG" | jq -r '.task_selection.max_issues // 1')
    milestone=$(echo "$CONFIG" | jq -r '.task_selection.milestone // "auto"')
    priority_filter=$(echo "$CONFIG" | jq -r '.task_selection.priority_filter // ""')

    log_debug "Task selection: strategy=$strategy, max=$max_issues, milestone=$milestone, priority=$priority_filter"

    # Get repository info
    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
        log_error "Failed to get repository information"
        log_error "Make sure you're in a git repository with GitHub remote"
        return 1
    }

    # Get milestone (if auto, use active milestone)
    if [ "$milestone" = "auto" ]; then
        milestone=$(gh api repos/{owner}/{repo}/milestones --jq '.[] | select(.state=="open") | .title' | head -1)
        if [ -z "$milestone" ]; then
            log_warn "No active milestone found"
            return 1
        fi
        log_debug "Using active milestone: $milestone"
    fi

    # Build gh issue list command
    local gh_args=(
        "issue" "list"
        "--milestone" "$milestone"
        "--label" "backlog"
        "--json" "number,title,labels"
        "--limit" "$max_issues"
    )

    # Add priority filter if specified
    if [ -n "$priority_filter" ]; then
        gh_args+=("--label" "$priority_filter")
    fi

    # Get issues
    local issues
    issues=$(gh "${gh_args[@]}" 2>/dev/null) || {
        log_warn "Failed to get issues from GitHub"
        return 1
    }

    # Get first issue
    local issue
    issue=$(echo "$issues" | jq -r '.[0] // empty')

    if [ -z "$issue" ]; then
        log_info "No backlog issues found in milestone: $milestone"
        return 1
    fi

    echo "$issue"
    return 0
}

# Execute task using container-launch.sh
execute_task() {
    local issue_number="$1"
    local dry_run="${2:-false}"

    local repo
    repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
        log_error "Failed to get repository information"
        return 1
    }

    log_info "Executing task: issue #$issue_number"

    if [ "$dry_run" = "true" ]; then
        log_info "[DRY RUN] Would execute: container-launch.sh --issue $issue_number --repo $repo --sprint-work"
        return 0
    fi

    # Execute via container-launch.sh with sprint-work mode
    local container_launch="${SCRIPT_DIR}/container-launch.sh"

    if [ ! -x "$container_launch" ]; then
        log_error "container-launch.sh not found or not executable"
        return 1
    fi

    log_info "Launching container for issue #$issue_number..."
    "$container_launch" \
        --issue "$issue_number" \
        --repo "$repo" \
        --sprint-work || {
            log_error "Container launch failed for issue #$issue_number"
            return 1
        }

    log_success "Container launched successfully for issue #$issue_number"
    return 0
}

# Main command: check availability
cmd_check() {
    log_info "Checking LLM availability..."
    echo ""

    local status
    status=$(check_availability)
    local result=$?

    # Pretty print status
    echo "$status" | jq '.'

    if [ $result -eq 0 ]; then
        echo ""
        log_success "LLM is AVAILABLE for task execution"
        return 0
    else
        echo ""
        log_warn "LLM is UNAVAILABLE"
        local reason
        reason=$(echo "$status" | jq -r '.reason // "unknown"')
        log_warn "Reason: $reason"
        return 2
    fi
}

# Main command: run task
cmd_run() {
    local dry_run="${1:-false}"

    if [ "$dry_run" = "true" ]; then
        log_info "DRY RUN MODE: Preview only, no changes will be made"
        echo ""
    fi

    log_info "Starting orchestrator run..."
    echo ""

    # Step 1: Check availability
    log_info "Step 1/3: Checking availability..."
    local status
    status=$(check_availability)
    local result=$?

    if [ $result -ne 0 ]; then
        local reason
        reason=$(echo "$status" | jq -r '.reason // "unknown"')
        log_warn "LLM unavailable: $reason"
        log_info "Skipping task execution"
        return 0
    fi

    log_success "Availability check passed"
    echo ""

    # Step 2: Get next task
    log_info "Step 2/3: Selecting next task..."
    local task
    task=$(get_next_task) || {
        log_info "No tasks available to execute"
        return 0
    }

    local issue_number issue_title
    issue_number=$(echo "$task" | jq -r '.number')
    issue_title=$(echo "$task" | jq -r '.title')

    log_info "Selected issue #$issue_number: $issue_title"
    echo ""

    # Step 3: Execute task
    log_info "Step 3/3: Executing task..."
    execute_task "$issue_number" "$dry_run" || {
        log_error "Task execution failed"
        return 1
    }

    echo ""
    log_success "Orchestrator run completed successfully"
    return 0
}

# Main function
main() {
    local action=""
    local custom_config=""

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --check)
                action="check"
                shift
                ;;
            --run)
                action="run"
                shift
                ;;
            --dry-run)
                action="dry-run"
                shift
                ;;
            --config)
                custom_config="$2"
                shift 2
                ;;
            --init)
                action="init"
                shift
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --version|-v)
                echo "$SCRIPT_NAME v$VERSION"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo ""
                usage
                exit 1
                ;;
        esac
    done

    # Validate action
    if [ -z "$action" ]; then
        log_error "No action specified"
        echo ""
        usage
        exit 1
    fi

    # Handle init action (doesn't need config)
    if [ "$action" = "init" ]; then
        init_config
        exit 0
    fi

    # Check dependencies
    require_command jq
    require_command gh

    # Load configuration
    local config_path="${custom_config:-$CONFIG_FILE}"
    load_config "$config_path"

    # Execute action
    case "$action" in
        check)
            cmd_check
            ;;
        run)
            cmd_run false
            ;;
        dry-run)
            cmd_run true
            ;;
        *)
            log_error "Invalid action: $action"
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
