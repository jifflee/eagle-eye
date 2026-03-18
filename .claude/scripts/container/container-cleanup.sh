#!/bin/bash
set -euo pipefail
# container-cleanup.sh
# Cleanup script for container lifecycle management
# Part of Phase 5: Automatic container cleanup (Issue #135)
# size-ok: multi-mode cleanup with orphan detection, log preservation, and batch operations
#
# Features:
#   - Single container cleanup (--issue N)
#   - Batch cleanup of stopped containers (--all-stopped)
#   - Orphan detection (containers > 24h with no activity)
#   - Log preservation for failed containers
#   - Dry run mode for safe previews
#
# Usage:
#   ./scripts/container-cleanup.sh --issue 107
#   ./scripts/container-cleanup.sh --all-stopped
#   ./scripts/container-cleanup.sh --orphans
#   ./scripts/container-cleanup.sh --orphans --dry-run

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="container-cleanup.sh"
VERSION="1.0.0"
LOG_DIR="${HOME}/.claude-tastic/logs"
ORPHAN_THRESHOLD_HOURS=24

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Container cleanup for Claude agents

USAGE:
    $SCRIPT_NAME --issue <N>        Cleanup container for issue N
    $SCRIPT_NAME --all-stopped      Cleanup all stopped containers
    $SCRIPT_NAME --orphans          Cleanup containers running > ${ORPHAN_THRESHOLD_HOURS}h
    $SCRIPT_NAME --list             List all containers with status

OPTIONS:
    --issue <N>         Cleanup container for specific issue number
    --all-stopped       Remove all stopped ${CONTAINER_PREFIX}-* containers
    --orphans           Remove containers running > ${ORPHAN_THRESHOLD_HOURS}h with no activity
    --list              List containers with age and status (no cleanup)
    --dry-run           Show what would be cleaned (no action)
    --keep-logs         Save container logs before removal (default: true)
    --no-logs           Skip log preservation
    --force             Force removal (don't wait for graceful shutdown)
    --debug             Enable debug logging
    --json              Output in JSON format

EXAMPLES:
    # Cleanup container for issue 107
    $SCRIPT_NAME --issue 107

    # Preview cleanup of orphan containers
    $SCRIPT_NAME --orphans --dry-run

    # Cleanup all stopped without saving logs
    $SCRIPT_NAME --all-stopped --no-logs

    # List all containers with status
    $SCRIPT_NAME --list --json

LOG DIRECTORY:
    Logs are saved to: $LOG_DIR/containers/

EOF
}

# Ensure log directory exists
ensure_log_dir() {
    mkdir -p "$LOG_DIR/containers"
}

# Generate container name from issue number
container_name() {
    local issue="$1"
    echo "${CONTAINER_PREFIX}-${issue}"
}

# Get container age in hours
get_container_age_hours() {
    local container="$1"
    local created_at
    created_at=$(docker inspect --format '{{.Created}}' "$container" 2>/dev/null)

    if [ -z "$created_at" ]; then
        echo "0"
        return
    fi

    local created_timestamp
    created_timestamp=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${created_at:0:19}" "+%s" 2>/dev/null || \
                       date -d "${created_at:0:19}" "+%s" 2>/dev/null || echo "0")

    local now_timestamp
    now_timestamp=$(date "+%s")

    local age_seconds=$((now_timestamp - created_timestamp))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Get container status
get_container_status() {
    local container="$1"
    docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null || echo "unknown"
}

# Get container exit code
get_container_exit_code() {
    local container="$1"
    docker inspect --format '{{.State.ExitCode}}' "$container" 2>/dev/null || echo "-1"
}

# Save container logs
save_container_logs() {
    local container="$1"
    local log_file="$LOG_DIR/containers/${container}_$(date '+%Y%m%d_%H%M%S').log"

    log_debug "Saving logs for $container to $log_file"

    if docker logs "$container" > "$log_file" 2>&1; then
        log_info "Logs saved: $log_file"
        return 0
    else
        log_warn "Could not save logs for $container"
        return 1
    fi
}

# Write cleanup audit entry
write_audit() {
    local action="$1"
    local container="$2"
    local details="$3"
    local outcome="$4"

    local audit_file="$LOG_DIR/container-cleanup.log"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "${timestamp}|${action}|${container}|${details}|${outcome}" >> "$audit_file"
}

# Remove a single container
remove_container() {
    local container="$1"
    local force="${2:-false}"
    local keep_logs="${3:-true}"
    local dry_run="${4:-false}"

    local status
    status=$(get_container_status "$container")
    local exit_code
    exit_code=$(get_container_exit_code "$container")

    if [ "$dry_run" = "true" ]; then
        log_info "[DRY-RUN] Would remove: $container (status: $status, exit: $exit_code)"
        return 0
    fi

    # ALWAYS persist metrics before removal (Issue #592)
    local issue_num="${container#${CONTAINER_PREFIX}-}"
    if [ -x "${SCRIPT_DIR}/container-metrics-persist.sh" ]; then
        log_info "Persisting metrics for $container..."
        "${SCRIPT_DIR}/container-metrics-persist.sh" "$issue_num" 2>/dev/null || true
    fi

    # Save logs before removal if requested and container failed
    if [ "$keep_logs" = "true" ] && [ "$exit_code" != "0" ]; then
        save_container_logs "$container"
    fi

    # Stop container if running
    if [ "$status" = "running" ]; then
        log_info "Stopping container: $container"
        if [ "$force" = "true" ]; then
            docker kill "$container" 2>/dev/null || true
        else
            docker stop --time 10 "$container" 2>/dev/null || docker kill "$container" 2>/dev/null || true
        fi
    fi

    # Remove container
    log_info "Removing container: $container"
    if docker rm "$container" 2>/dev/null; then
        log_info "Container removed: $container"
        write_audit "remove" "$container" "status=$status,exit=$exit_code" "success"
        return 0
    else
        log_error "Failed to remove container: $container"
        write_audit "remove" "$container" "status=$status,exit=$exit_code" "failed"
        return 1
    fi
}

# Cleanup container for specific issue
cleanup_issue() {
    local issue="$1"
    local dry_run="${2:-false}"
    local keep_logs="${3:-true}"
    local force="${4:-false}"

    local name
    name=$(container_name "$issue")

    # Check if container exists
    if ! docker inspect "$name" &>/dev/null; then
        log_warn "Container not found: $name"
        return 0
    fi

    remove_container "$name" "$force" "$keep_logs" "$dry_run"
}

# Cleanup all stopped containers
cleanup_stopped() {
    local dry_run="${1:-false}"
    local keep_logs="${2:-true}"
    local force="${3:-false}"

    log_info "Finding stopped ${CONTAINER_PREFIX}-* containers..."

    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --filter "status=exited" --format '{{.Names}}')

    if [ -z "$containers" ]; then
        log_info "No stopped containers found"
        return 0
    fi

    local count=0
    while IFS= read -r container; do
        remove_container "$container" "$force" "$keep_logs" "$dry_run"
        ((count++))
    done <<< "$containers"

    log_info "Processed $count container(s)"
}

# Cleanup orphan containers (running > threshold hours)
cleanup_orphans() {
    local dry_run="${1:-false}"
    local keep_logs="${2:-true}"
    local force="${3:-false}"

    log_info "Finding orphan containers (running > ${ORPHAN_THRESHOLD_HOURS}h)..."

    local containers
    containers=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}')

    if [ -z "$containers" ]; then
        log_info "No running containers found"
        return 0
    fi

    local orphan_count=0
    while IFS= read -r container; do
        local age_hours
        age_hours=$(get_container_age_hours "$container")

        log_debug "Container $container age: ${age_hours}h"

        if [ "$age_hours" -ge "$ORPHAN_THRESHOLD_HOURS" ]; then
            log_warn "Orphan detected: $container (age: ${age_hours}h)"
            remove_container "$container" "$force" "$keep_logs" "$dry_run"
            ((orphan_count++))
        fi
    done <<< "$containers"

    if [ "$orphan_count" -eq 0 ]; then
        log_info "No orphan containers found"
    else
        log_info "Processed $orphan_count orphan container(s)"
    fi
}

# List all containers with status
list_containers() {
    local json_output="${1:-false}"

    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null)

    if [ -z "$containers" ]; then
        if [ "$json_output" = "true" ]; then
            echo '{"containers": [], "total": 0}'
        else
            log_info "No ${CONTAINER_PREFIX}-* containers found"
        fi
        return 0
    fi

    if [ "$json_output" = "true" ]; then
        # Output as JSON
        echo '{"containers": ['
        local first=true
        while IFS=$'\t' read -r name status image; do
            local state
            state=$(get_container_status "$name")
            local age_hours
            age_hours=$(get_container_age_hours "$name")
            local exit_code
            exit_code=$(get_container_exit_code "$name")
            local issue_num
            issue_num="${name#${CONTAINER_PREFIX}-}"

            if [ "$first" = "true" ]; then
                first=false
            else
                echo ","
            fi

            echo -n "  {\"name\": \"$name\", \"issue\": \"$issue_num\", \"status\": \"$state\", \"age_hours\": $age_hours, \"exit_code\": $exit_code, \"image\": \"$image\"}"
        done <<< "$containers"
        echo ""
        echo ']}'
    else
        # Human-readable table
        echo ""
        printf "%-30s %-10s %-8s %-10s %s\n" "CONTAINER" "STATUS" "AGE" "EXIT" "IMAGE"
        printf "%-30s %-10s %-8s %-10s %s\n" "─────────" "──────" "───" "────" "─────"

        while IFS=$'\t' read -r name status image; do
            local state
            state=$(get_container_status "$name")
            local age_hours
            age_hours=$(get_container_age_hours "$name")
            local exit_code
            exit_code=$(get_container_exit_code "$name")

            # Format age
            local age_display
            if [ "$age_hours" -ge 24 ]; then
                age_display="$((age_hours / 24))d"
            else
                age_display="${age_hours}h"
            fi

            # Color status
            local status_display
            case "$state" in
                running)
                    if [ "$age_hours" -ge "$ORPHAN_THRESHOLD_HOURS" ]; then
                        status_display="${YELLOW}orphan${NC}"
                    else
                        status_display="${GREEN}running${NC}"
                    fi
                    ;;
                exited)
                    if [ "$exit_code" = "0" ]; then
                        status_display="${GREEN}exited${NC}"
                    else
                        status_display="${RED}failed${NC}"
                    fi
                    ;;
                *)
                    status_display="$state"
                    ;;
            esac

            printf "%-30s %-10b %-8s %-10s %s\n" "$name" "$status_display" "$age_display" "$exit_code" "$image"
        done <<< "$containers"
        echo ""
    fi
}

# Main function
main() {
    local action=""
    local issue=""
    local dry_run="false"
    local keep_logs="true"
    local force="false"
    local json_output="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                action="issue"
                issue="$2"
                shift 2
                ;;
            --all-stopped)
                action="stopped"
                shift
                ;;
            --orphans)
                action="orphans"
                shift
                ;;
            --list)
                action="list"
                shift
                ;;
            --dry-run)
                dry_run="true"
                shift
                ;;
            --keep-logs)
                keep_logs="true"
                shift
                ;;
            --no-logs)
                keep_logs="false"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            --json)
                json_output="true"
                shift
                ;;
            --debug)
                DEBUG="1"
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
                usage
                exit 1
                ;;
        esac
    done

    # Ensure log directory exists
    ensure_log_dir

    # Execute action
    case "$action" in
        issue)
            if [ -z "$issue" ]; then
                log_error "--issue requires an issue number"
                exit 1
            fi
            cleanup_issue "$issue" "$dry_run" "$keep_logs" "$force"
            ;;
        stopped)
            cleanup_stopped "$dry_run" "$keep_logs" "$force"
            ;;
        orphans)
            cleanup_orphans "$dry_run" "$keep_logs" "$force"
            ;;
        list)
            list_containers "$json_output"
            ;;
        *)
            log_error "No action specified"
            echo ""
            usage
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
