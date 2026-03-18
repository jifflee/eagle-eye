#!/bin/bash
set -euo pipefail
# container-cleanup-sweep.sh
# Sweep and cleanup ALL stopped containers whose issues/PRs are merged or closed
# Part of fix for Issue #1032: /pr-merge cleanup misses containers from previously-merged PRs
# size-ok: sweep-based cleanup with issue/PR state verification
#
# This script complements container-cleanup.sh by checking ALL stopped containers
# (not just those in the current merge session) and removing them if their
# associated issue is closed or their PR is merged.
#
# Usage:
#   ./scripts/container-cleanup-sweep.sh
#   ./scripts/container-cleanup-sweep.sh --dry-run
#   ./scripts/container-cleanup-sweep.sh --force

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Script metadata
SCRIPT_NAME="container-cleanup-sweep.sh"
VERSION="1.0.0"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Sweep cleanup for containers with merged/closed issues

USAGE:
    $SCRIPT_NAME [OPTIONS]

DESCRIPTION:
    This script finds ALL stopped ${CONTAINER_PREFIX}-* containers, extracts their
    issue numbers, and checks if the issue is CLOSED or has a merged PR.
    If so, the container is cleaned up (with log preservation for failures).

    This complements /pr-merge container cleanup by catching containers whose
    PRs were merged outside the current /pr-merge session.

OPTIONS:
    --dry-run           Show what would be cleaned (no action)
    --force             Skip confirmation prompts
    --keep-logs         Save container logs before removal (default: true)
    --no-logs           Skip log preservation
    --debug             Enable debug logging
    --help, -h          Show this help

EXAMPLES:
    # Preview cleanup
    $SCRIPT_NAME --dry-run

    # Cleanup with prompts
    $SCRIPT_NAME

    # Cleanup without prompts
    $SCRIPT_NAME --force

    # Cleanup without saving logs
    $SCRIPT_NAME --no-logs

INTEGRATION:
    This script is called by /pr-merge after the targeted cleanup step
    to catch containers from previously-merged PRs.

ISSUE:
    Issue #1032 - /pr-merge cleanup misses containers from previously-merged PRs

EOF
}

# Check if an issue is closed
# Args: issue_number
# Returns: 0 if closed, 1 if open or error
is_issue_closed() {
    local issue="$1"

    if ! command -v gh &> /dev/null; then
        log_warn "gh CLI not available - cannot check issue status"
        return 1
    fi

    local state
    state=$(gh issue view "$issue" --json state --jq '.state' 2>/dev/null || echo "")

    if [ "$state" = "CLOSED" ]; then
        return 0
    fi

    return 1
}

# Check if an issue has a merged PR
# Args: issue_number
# Returns: 0 if has merged PR, 1 otherwise
has_merged_pr() {
    local issue="$1"

    if ! command -v gh &> /dev/null; then
        log_warn "gh CLI not available - cannot check PR status"
        return 1
    fi

    # Search for PRs that reference this issue
    local prs
    prs=$(gh pr list --search "Fixes #$issue OR Closes #$issue OR Resolves #$issue" --state merged --json number --jq '.[].number' 2>/dev/null || echo "")

    if [ -n "$prs" ]; then
        return 0
    fi

    # Also check PRs with matching branch name (feat/issue-N)
    local branch="feat/issue-$issue"
    prs=$(gh pr list --head "$branch" --state merged --json number --jq '.[].number' 2>/dev/null || echo "")

    if [ -n "$prs" ]; then
        return 0
    fi

    return 1
}

# Check if a container should be cleaned up
# Args: container_name issue_number
# Returns: 0 if should cleanup, 1 otherwise
should_cleanup_container() {
    local container="$1"
    local issue="$2"

    # Check if issue is closed
    if is_issue_closed "$issue"; then
        log_debug "Issue #$issue is closed"
        return 0
    fi

    # Check if issue has a merged PR
    if has_merged_pr "$issue"; then
        log_debug "Issue #$issue has a merged PR"
        return 0
    fi

    return 1
}

# Main sweep function
sweep_cleanup() {
    local dry_run="${1:-false}"
    local keep_logs="${2:-true}"
    local force="${3:-false}"

    log_info "Starting container cleanup sweep..."

    # Find all stopped containers
    local containers
    containers=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --filter "status=exited" --format '{{.Names}}' 2>/dev/null || echo "")

    if [ -z "$containers" ]; then
        log_info "No stopped containers found"
        return 0
    fi

    local total=0
    local to_clean=0
    local cleaned=0
    local skipped=0

    # First pass: identify containers to clean
    local cleanup_list=""
    while IFS= read -r container; do
        ((total++))

        # Extract issue number from container name
        local issue="${container#${CONTAINER_PREFIX}-}"

        if [ "$issue" = "$container" ]; then
            log_warn "Could not extract issue number from: $container"
            ((skipped++))
            continue
        fi

        log_debug "Checking container: $container (issue #$issue)"

        if should_cleanup_container "$container" "$issue"; then
            cleanup_list="${cleanup_list}${container}|${issue}\n"
            ((to_clean++))
        fi
    done <<< "$containers"

    if [ "$to_clean" -eq 0 ]; then
        log_info "No containers eligible for cleanup (checked $total containers)"
        return 0
    fi

    # Display summary
    echo ""
    log_info "Found $to_clean container(s) to cleanup (out of $total stopped):"
    echo ""
    printf "%-35s %-10s %-15s\n" "CONTAINER" "ISSUE" "REASON"
    printf "%-35s %-10s %-15s\n" "─────────" "─────" "──────"

    echo -e "$cleanup_list" | while IFS='|' read -r container issue; do
        [ -z "$container" ] && continue

        local reason=""
        if is_issue_closed "$issue"; then
            reason="Issue closed"
        elif has_merged_pr "$issue"; then
            reason="PR merged"
        fi

        printf "%-35s %-10s %-15s\n" "$container" "#$issue" "$reason"
    done
    echo ""

    # Prompt for confirmation unless dry-run or force
    if [ "$dry_run" = "false" ] && [ "$force" = "false" ]; then
        echo -n "Proceed with cleanup? [y/N] "
        read -r response </dev/tty
        if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
            log_info "Cleanup cancelled"
            return 0
        fi
    fi

    # Second pass: cleanup containers
    echo ""
    echo -e "$cleanup_list" | while IFS='|' read -r container issue; do
        [ -z "$container" ] && continue

        if [ "$dry_run" = "true" ]; then
            log_info "[DRY-RUN] Would cleanup: $container (issue #$issue)"
        else
            # Use the existing container-cleanup.sh script for actual cleanup
            # This ensures metrics persistence, log preservation, etc.
            if [ -x "${SCRIPT_DIR}/container-cleanup.sh" ]; then
                local cleanup_args=("--issue" "$issue")
                if [ "$keep_logs" = "false" ]; then
                    cleanup_args+=("--no-logs")
                fi

                "${SCRIPT_DIR}/container-cleanup.sh" "${cleanup_args[@]}" && ((cleaned++)) || true
            else
                log_error "container-cleanup.sh not found - cannot cleanup $container"
            fi
        fi
    done

    echo ""
    if [ "$dry_run" = "true" ]; then
        log_info "Dry-run complete: would cleanup $to_clean container(s)"
    else
        log_success "Cleanup complete: removed $cleaned container(s)"
    fi
}

# Main function
main() {
    local dry_run="false"
    local keep_logs="true"
    local force="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
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

    # Run sweep cleanup
    sweep_cleanup "$dry_run" "$keep_logs" "$force"
}

# Run main with all arguments
main "$@"
