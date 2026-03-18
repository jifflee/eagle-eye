#!/bin/bash
set -euo pipefail
# orchestrator-schedule.sh
# Install/uninstall scheduling for the LLM orchestrator
# Part of Feature #752 (Epic #263)
#
# Usage:
#   ./scripts/orchestrator-schedule.sh --install           # Install scheduling
#   ./scripts/orchestrator-schedule.sh --uninstall         # Uninstall scheduling
#   ./scripts/orchestrator-schedule.sh --status            # Check scheduling status
#   ./scripts/orchestrator-schedule.sh --logs              # View orchestrator logs
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or error

set -e

# Script metadata
SCRIPT_NAME="orchestrator-schedule.sh"
VERSION="1.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Configuration
CONFIG_DIR="${HOME}/.claude-tastic"
LOG_DIR="${CONFIG_DIR}/logs"
LOG_FILE="${LOG_DIR}/orchestrator.log"
ORCHESTRATOR_SCRIPT="${SCRIPT_DIR}/llm-orchestrator.sh"

# Platform-specific paths
LAUNCHD_LABEL="com.claude-tastic.orchestrator"
LAUNCHD_PLIST="${HOME}/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
CRON_MARKER="# claude-tastic-orchestrator"

# Default interval in minutes
DEFAULT_INTERVAL=10

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - LLM Orchestrator Scheduler

USAGE:
    $SCRIPT_NAME --install [OPTIONS]    Install scheduling (cron/launchd)
    $SCRIPT_NAME --uninstall            Uninstall scheduling
    $SCRIPT_NAME --status               Check scheduling status
    $SCRIPT_NAME --logs                 View orchestrator logs
    $SCRIPT_NAME --help                 Show this help

INSTALL OPTIONS:
    --interval <minutes>    Scheduling interval (default: $DEFAULT_INTERVAL minutes)
    --debug                 Enable debug logging in scheduled runs

DESCRIPTION:
    Installs automatic scheduling for the LLM orchestrator to run at regular
    intervals. Uses launchd on macOS and cron on Linux.

    All scheduled runs are logged to: $LOG_FILE

EXAMPLES:
    # Install with default 10-minute interval
    $SCRIPT_NAME --install

    # Install with custom 5-minute interval
    $SCRIPT_NAME --install --interval 5

    # Check if scheduling is active
    $SCRIPT_NAME --status

    # View recent logs
    $SCRIPT_NAME --logs

    # Uninstall scheduling
    $SCRIPT_NAME --uninstall

PLATFORM SUPPORT:
    macOS:  Uses launchd (~/Library/LaunchAgents/${LAUNCHD_LABEL}.plist)
    Linux:  Uses cron (adds entry to user crontab)

SEE ALSO:
    - llm-orchestrator.sh: The orchestrator being scheduled
    - Issue #752: Add cron/launchd scheduling for LLM orchestrator
    - Epic #263: Multi-LLM orchestration architecture
EOF
}

# Ensure log directory exists
ensure_log_dir() {
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
        log_info "Created log directory: $LOG_DIR"
    fi
}

# Detect platform
detect_platform() {
    if [ "$(uname)" = "Darwin" ]; then
        echo "macos"
    elif [ "$(uname)" = "Linux" ]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# Create launchd plist file
create_launchd_plist() {
    local interval_seconds="$1"
    local debug_flag="$2"

    log_info "Creating launchd plist: $LAUNCHD_PLIST"

    # Create LaunchAgents directory if it doesn't exist
    local launchd_dir="${HOME}/Library/LaunchAgents"
    if [ ! -d "$launchd_dir" ]; then
        mkdir -p "$launchd_dir"
        log_info "Created LaunchAgents directory"
    fi

    # Build program arguments
    local program_args="
        <string>${ORCHESTRATOR_SCRIPT}</string>
        <string>--run</string>"

    if [ "$debug_flag" = "true" ]; then
        program_args="${program_args}
        <string>--debug</string>"
    fi

    # Create plist file
    cat > "$LAUNCHD_PLIST" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHD_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
${program_args}
    </array>

    <key>StartInterval</key>
    <integer>${interval_seconds}</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>StandardOutPath</key>
    <string>${LOG_FILE}</string>

    <key>StandardErrorPath</key>
    <string>${LOG_FILE}</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}/..</string>
</dict>
</plist>
EOF

    log_success "Created launchd plist"
}

# Install launchd scheduling (macOS)
install_launchd() {
    local interval_minutes="$1"
    local debug_flag="$2"
    local interval_seconds=$((interval_minutes * 60))

    log_info "Installing launchd scheduling (interval: ${interval_minutes} minutes)"

    # Create plist
    create_launchd_plist "$interval_seconds" "$debug_flag"

    # Unload existing if present
    if launchctl list | grep -q "$LAUNCHD_LABEL"; then
        log_info "Unloading existing launchd job..."
        launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
    fi

    # Load the plist
    launchctl load "$LAUNCHD_PLIST" || {
        log_error "Failed to load launchd plist"
        return 1
    }

    log_success "Launchd scheduling installed successfully"
    log_info "The orchestrator will run every ${interval_minutes} minutes"
    log_info "Logs will be written to: $LOG_FILE"
    log_info ""
    log_info "To manually trigger: launchctl start $LAUNCHD_LABEL"
    log_info "To view status: launchctl list | grep $LAUNCHD_LABEL"
}

# Uninstall launchd scheduling (macOS)
uninstall_launchd() {
    log_info "Uninstalling launchd scheduling..."

    if [ ! -f "$LAUNCHD_PLIST" ]; then
        log_warn "Launchd plist not found: $LAUNCHD_PLIST"
        return 0
    fi

    # Unload
    if launchctl list | grep -q "$LAUNCHD_LABEL"; then
        launchctl unload "$LAUNCHD_PLIST" || {
            log_error "Failed to unload launchd job"
            return 1
        }
        log_info "Unloaded launchd job"
    fi

    # Remove plist
    rm -f "$LAUNCHD_PLIST"
    log_success "Removed launchd plist"
    log_success "Launchd scheduling uninstalled successfully"
}

# Install cron scheduling (Linux)
install_cron() {
    local interval_minutes="$1"
    local debug_flag="$2"

    log_info "Installing cron scheduling (interval: ${interval_minutes} minutes)"

    # Build cron command
    local cron_cmd="$ORCHESTRATOR_SCRIPT --run"
    if [ "$debug_flag" = "true" ]; then
        cron_cmd="$cron_cmd --debug"
    fi
    cron_cmd="$cron_cmd >> $LOG_FILE 2>&1"

    # Determine cron schedule expression
    local cron_schedule
    if [ "$interval_minutes" -lt 60 ]; then
        # Sub-hourly: */N * * * *
        cron_schedule="*/$interval_minutes * * * *"
    elif [ "$interval_minutes" -eq 60 ]; then
        # Hourly: 0 * * * *
        cron_schedule="0 * * * *"
    else
        # Multi-hour: 0 */N * * *
        local interval_hours=$((interval_minutes / 60))
        cron_schedule="0 */$interval_hours * * *"
    fi

    # Create cron entry
    local cron_entry="$cron_schedule $cron_cmd $CRON_MARKER"

    # Get current crontab (may be empty)
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || echo "")

    # Remove existing orchestrator entries
    local new_crontab
    new_crontab=$(echo "$current_crontab" | grep -v "$CRON_MARKER" || true)

    # Add new entry
    new_crontab="${new_crontab}
${cron_entry}"

    # Install new crontab
    echo "$new_crontab" | crontab - || {
        log_error "Failed to install crontab"
        return 1
    }

    log_success "Cron scheduling installed successfully"
    log_info "The orchestrator will run every ${interval_minutes} minutes"
    log_info "Logs will be written to: $LOG_FILE"
    log_info ""
    log_info "To view crontab: crontab -l"
}

# Uninstall cron scheduling (Linux)
uninstall_cron() {
    log_info "Uninstalling cron scheduling..."

    # Get current crontab
    local current_crontab
    current_crontab=$(crontab -l 2>/dev/null || echo "")

    if ! echo "$current_crontab" | grep -q "$CRON_MARKER"; then
        log_warn "No orchestrator cron entry found"
        return 0
    fi

    # Remove orchestrator entries
    local new_crontab
    new_crontab=$(echo "$current_crontab" | grep -v "$CRON_MARKER" || true)

    # Install new crontab
    if [ -z "$new_crontab" ]; then
        # Remove crontab entirely if empty
        crontab -r 2>/dev/null || true
        log_info "Removed empty crontab"
    else
        echo "$new_crontab" | crontab - || {
            log_error "Failed to update crontab"
            return 1
        }
        log_info "Removed orchestrator cron entry"
    fi

    log_success "Cron scheduling uninstalled successfully"
}

# Check scheduling status
check_status() {
    local platform=$(detect_platform)

    echo ""
    log_info "Platform: $platform"
    log_info "Log file: $LOG_FILE"
    echo ""

    if [ "$platform" = "macos" ]; then
        log_info "Launchd Status:"
        echo ""

        if [ -f "$LAUNCHD_PLIST" ]; then
            echo "  Plist file: $LAUNCHD_PLIST"
            echo "  Status: Installed"
            echo ""

            if launchctl list | grep -q "$LAUNCHD_LABEL"; then
                echo "  Running: YES"
                echo ""
                launchctl list | grep "$LAUNCHD_LABEL" | awk '{print "  PID: " $1 "\n  Status: " $2 "\n  Label: " $3}'
            else
                echo "  Running: NO"
                echo "  (Plist exists but job not loaded)"
            fi
        else
            echo "  Status: Not installed"
        fi

    elif [ "$platform" = "linux" ]; then
        log_info "Cron Status:"
        echo ""

        local cron_entry
        cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_MARKER" || true)

        if [ -n "$cron_entry" ]; then
            echo "  Status: Installed"
            echo "  Entry: $cron_entry"
        else
            echo "  Status: Not installed"
        fi
    else
        log_error "Unsupported platform"
        return 1
    fi

    echo ""

    # Check log file
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(wc -c < "$LOG_FILE")
        local log_lines=$(wc -l < "$LOG_FILE")
        log_info "Log file exists: $log_lines lines, $log_size bytes"
    else
        log_info "Log file does not exist yet"
    fi
}

# View logs
view_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        log_warn "Log file not found: $LOG_FILE"
        log_info "The orchestrator hasn't run yet or logging hasn't been configured"
        return 0
    fi

    log_info "Showing recent orchestrator logs from: $LOG_FILE"
    echo ""
    echo "─────────────────────────────────────────────────────────────────"
    tail -n 50 "$LOG_FILE"
    echo "─────────────────────────────────────────────────────────────────"
    echo ""
    log_info "Use 'tail -f $LOG_FILE' to follow logs in real-time"
}

# Install scheduling
cmd_install() {
    local interval_minutes="$1"
    local debug_flag="$2"

    # Validate orchestrator script exists
    if [ ! -x "$ORCHESTRATOR_SCRIPT" ]; then
        log_error "Orchestrator script not found or not executable: $ORCHESTRATOR_SCRIPT"
        return 1
    fi

    # Ensure log directory exists
    ensure_log_dir

    # Detect platform and install
    local platform=$(detect_platform)

    log_info "Installing scheduling for platform: $platform"
    echo ""

    case "$platform" in
        macos)
            install_launchd "$interval_minutes" "$debug_flag"
            ;;
        linux)
            install_cron "$interval_minutes" "$debug_flag"
            ;;
        *)
            log_error "Unsupported platform: $(uname)"
            log_error "This script supports macOS and Linux only"
            return 1
            ;;
    esac
}

# Uninstall scheduling
cmd_uninstall() {
    local platform=$(detect_platform)

    log_info "Uninstalling scheduling for platform: $platform"
    echo ""

    case "$platform" in
        macos)
            uninstall_launchd
            ;;
        linux)
            uninstall_cron
            ;;
        *)
            log_error "Unsupported platform: $(uname)"
            return 1
            ;;
    esac
}

# Main function
main() {
    local action=""
    local interval_minutes=$DEFAULT_INTERVAL
    local debug_flag="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --install)
                action="install"
                shift
                ;;
            --uninstall)
                action="uninstall"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            --logs)
                action="logs"
                shift
                ;;
            --interval)
                interval_minutes="$2"
                shift 2
                ;;
            --debug)
                debug_flag="true"
                shift
                ;;
            --help|-h)
                usage
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

    # Validate interval
    if [ "$action" = "install" ]; then
        if ! [[ "$interval_minutes" =~ ^[0-9]+$ ]] || [ "$interval_minutes" -lt 1 ]; then
            log_error "Invalid interval: $interval_minutes (must be a positive integer)"
            exit 1
        fi
    fi

    # Execute action
    case "$action" in
        install)
            cmd_install "$interval_minutes" "$debug_flag"
            ;;
        uninstall)
            cmd_uninstall
            ;;
        status)
            check_status
            ;;
        logs)
            view_logs
            ;;
        *)
            log_error "Invalid action: $action"
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
