#!/bin/bash
set -euo pipefail
# sprint-orchestrator.sh
# Autonomous sprint execution orchestrator
# size-ok: multi-issue orchestration with mode detection, token loading, and continuous execution
#
# This script continuously works through backlog issues, automatically
# determining execution mode (worktree vs container) and running the
# full SDLC for each issue.
#
# Usage:
#   ./scripts/sprint-orchestrator.sh                    # Run until backlog empty
#   ./scripts/sprint-orchestrator.sh --max-issues 5     # Process max 5 issues
#   ./scripts/sprint-orchestrator.sh --dry-run          # Show what would be done
#   ./scripts/sprint-orchestrator.sh --milestone "sprint-1/13"  # Specific milestone

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Script metadata
SCRIPT_NAME="sprint-orchestrator.sh"
VERSION="1.0.0"

# Custom status logging
log_status() {
    echo -e "${BLUE:-}[STATUS]${NC:-} $1"
}

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Autonomous sprint execution orchestrator

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --max-issues <N>      Maximum number of issues to process (default: unlimited)
    --milestone <name>    Specific milestone to work on (default: active milestone)
    --dry-run             Show what would be done without executing
    --delay <seconds>     Delay between issues (default: 5)
    --priority <P0-P3>    Only process issues with this priority or higher
    --debug               Enable debug output
    -h, --help            Show this help

ENVIRONMENT VARIABLES:
    GITHUB_TOKEN              GitHub authentication (auto-loaded from keychain)
    CLAUDE_CODE_OAUTH_TOKEN   Claude authentication (auto-loaded from keychain)

EXAMPLES:
    # Work through all backlog issues
    $SCRIPT_NAME

    # Process max 3 issues from sprint-1/13
    $SCRIPT_NAME --max-issues 3 --milestone "sprint-1/13"

    # Dry run to see what would be processed
    $SCRIPT_NAME --dry-run

NOTES:
    - Automatically loads tokens from macOS Keychain if not set
    - Detects execution mode (worktree vs container) per issue
    - Stops when backlog is empty or max issues reached
    - Creates summary report upon completion
EOF
    exit 0
}

# Parse arguments
MAX_ISSUES=0  # 0 = unlimited
MILESTONE=""
DRY_RUN=false
DELAY=5
PRIORITY_FILTER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --max-issues)
            MAX_ISSUES="$2"
            shift 2
            ;;
        --milestone)
            MILESTONE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        --priority)
            PRIORITY_FILTER="$2"
            shift 2
            ;;
        --debug)
            DEBUG=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Load tokens from keychain if needed (macOS)
load_tokens() {
    if command -v security &> /dev/null; then
        # Load GitHub token
        if [ -z "$GITHUB_TOKEN" ]; then
            GITHUB_TOKEN=$(security find-generic-password -a "$USER" -s "github-container-token" -w 2>/dev/null) || true
            if [ -n "$GITHUB_TOKEN" ]; then
                export GITHUB_TOKEN
                export GH_TOKEN="$GITHUB_TOKEN"
                log_debug "Loaded GITHUB_TOKEN from keychain"
            else
                # Try gh auth token
                GITHUB_TOKEN=$(gh auth token 2>/dev/null) || true
                if [ -n "$GITHUB_TOKEN" ]; then
                    export GITHUB_TOKEN
                    export GH_TOKEN="$GITHUB_TOKEN"
                    log_debug "Loaded GITHUB_TOKEN from gh auth"
                fi
            fi
        fi

        # Load Claude token
        if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
            CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -a "$USER" -s "claude-oauth-token" -w 2>/dev/null) || true
            if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
                export CLAUDE_CODE_OAUTH_TOKEN
                log_debug "Loaded CLAUDE_CODE_OAUTH_TOKEN from keychain"
            fi
        fi
    fi
}

# Validate required tokens
validate_tokens() {
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN not found. Set up with:"
        log_error "  ./scripts/load-container-tokens.sh setup"
        exit 1
    fi

    if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        log_warn "CLAUDE_CODE_OAUTH_TOKEN not found - Claude may prompt for auth"
    fi

    log_info "Tokens validated"
}

# Get active milestone
get_active_milestone() {
    if [ -n "$MILESTONE" ]; then
        echo "$MILESTONE"
        return
    fi

    # Get first open milestone
    gh api repos/{owner}/{repo}/milestones --jq '.[] | select(.state=="open") | .title' | head -1
}

# Get next backlog issue
get_next_issue() {
    local milestone="$1"

    # Priority labels in order
    local priority_order="P0 P1 P2 P3"

    # If priority filter specified, only look for that and higher
    if [ -n "$PRIORITY_FILTER" ]; then
        case "$PRIORITY_FILTER" in
            P0) priority_order="P0" ;;
            P1) priority_order="P0 P1" ;;
            P2) priority_order="P0 P1 P2" ;;
            P3) priority_order="P0 P1 P2 P3" ;;
        esac
    fi

    # Search by priority, type, then age
    for priority in $priority_order; do
        # Bug first, then feature, then others
        for type in bug feature tech-debt docs; do
            local issue=$(gh issue list \
                --milestone "$milestone" \
                --label "backlog" \
                --label "$priority" \
                --label "$type" \
                --json number,title,labels \
                --jq '.[0] | select(.number != null)' 2>/dev/null)

            if [ -n "$issue" ]; then
                echo "$issue"
                return
            fi
        done

        # Any type with this priority
        local issue=$(gh issue list \
            --milestone "$milestone" \
            --label "backlog" \
            --label "$priority" \
            --json number,title,labels \
            --jq '.[0] | select(.number != null)' 2>/dev/null)

        if [ -n "$issue" ]; then
            echo "$issue"
            return
        fi
    done

    # Fallback: any backlog issue in milestone
    gh issue list \
        --milestone "$milestone" \
        --label "backlog" \
        --json number,title,labels \
        --jq '.[0] | select(.number != null)' 2>/dev/null
}

# Get execution mode for issue
# Container is the default since #531
get_execution_mode() {
    local issue_number="$1"

    if [ -x "$SCRIPT_DIR/detect-execution-mode.sh" ]; then
        "$SCRIPT_DIR/detect-execution-mode.sh" "$issue_number" 2>/dev/null || echo '{"mode": "container"}'
    else
        echo '{"mode": "container"}'
    fi
}

# Execute issue (worktree or container)
execute_issue() {
    local issue_number="$1"
    local mode="$2"

    log_info "Executing issue #$issue_number in $mode mode"

    if [ "$mode" = "container" ]; then
        # Get repo info
        local repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)

        # Launch container
        "$SCRIPT_DIR/container-launch.sh" \
            --issue "$issue_number" \
            --repo "$repo" \
            --cmd "claude /sprint-work --issue $issue_number"
    else
        # Use sprint-work preflight for worktree
        "$SCRIPT_DIR/sprint-work-preflight.sh" "$issue_number"
    fi
}

# Main orchestration loop
main() {
    log_status "Sprint Orchestrator v$VERSION starting"
    echo ""

    # Load tokens
    load_tokens
    validate_tokens

    # Get milestone
    local milestone=$(get_active_milestone)
    if [ -z "$milestone" ]; then
        log_error "No active milestone found"
        exit 1
    fi
    log_info "Working on milestone: $milestone"

    # Stats
    local processed=0
    local succeeded=0
    local failed=0
    local start_time=$(date +%s)

    # Main loop
    while true; do
        # Check max issues
        if [ "$MAX_ISSUES" -gt 0 ] && [ "$processed" -ge "$MAX_ISSUES" ]; then
            log_info "Reached max issues limit ($MAX_ISSUES)"
            break
        fi

        # Get next issue
        local issue_json=$(get_next_issue "$milestone")
        if [ -z "$issue_json" ]; then
            log_info "No more backlog issues in milestone"
            break
        fi

        local issue_number=$(echo "$issue_json" | jq -r '.number')
        local issue_title=$(echo "$issue_json" | jq -r '.title')

        echo ""
        log_status "═══════════════════════════════════════════════════════════════"
        log_status "Issue #$issue_number: $issue_title"
        log_status "═══════════════════════════════════════════════════════════════"

        # Get execution mode
        local mode_json=$(get_execution_mode "$issue_number")
        local mode=$(echo "$mode_json" | jq -r '.mode // "worktree"')
        local mode_reason=$(echo "$mode_json" | jq -r '.reason // "default"')

        log_info "Execution mode: $mode ($mode_reason)"

        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY RUN] Would process issue #$issue_number in $mode mode"
            processed=$((processed + 1))
            continue
        fi

        # Update work state: starting
        if [ -x "$SCRIPT_DIR/update-work-state.sh" ]; then
            "$SCRIPT_DIR/update-work-state.sh" --start "$issue_number" 2>/dev/null || true
        fi
        local issue_start_time=$(date +%s)

        # Execute issue
        local issue_result="success"
        if execute_issue "$issue_number" "$mode"; then
            succeeded=$((succeeded + 1))
            log_info "Issue #$issue_number completed successfully"
        else
            failed=$((failed + 1))
            issue_result="failure"
            log_warn "Issue #$issue_number failed or needs attention"
        fi

        # Update work state: completed
        if [ -x "$SCRIPT_DIR/update-work-state.sh" ]; then
            local issue_end_time=$(date +%s)
            local issue_duration=$((issue_end_time - issue_start_time))
            "$SCRIPT_DIR/update-work-state.sh" --complete "$issue_number" --result "$issue_result" --duration "$issue_duration" 2>/dev/null || true
        fi

        # ── Framework auto-update check (Issue #1329) ──────────────────────
        # After each container run, check if a framework update was queued
        # by the 25th-run check in sprint-work-preflight.sh. If queued, run
        # repo:framework-update NOW before picking up the next issue.
        if [ -x "$SCRIPT_DIR/framework-update-check.sh" ] && \
           [ "${SPRINT_UPDATE_CHECK_DISABLE:-}" != "true" ]; then
            "$SCRIPT_DIR/framework-update-check.sh" trigger-if-queued 2>&1 || true
        fi

        # ── Auto triage-bulk check (Issue #1332) ───────────────────────────
        # After each issue completion, check if auto-triage was queued by the
        # Nth-run check in sprint-work-preflight.sh. If queued, run
        # triage-bulk --apply + retroactive context review before next issue.
        if [ -x "$SCRIPT_DIR/triage-bulk-check.sh" ] && \
           [ "${SPRINT_TRIAGE_CHECK_DISABLE:-}" != "true" ]; then
            "$SCRIPT_DIR/triage-bulk-check.sh" trigger-if-queued 2>&1 || true
        fi

        processed=$((processed + 1))

        # Delay between issues
        if [ "$DELAY" -gt 0 ]; then
            log_debug "Waiting $DELAY seconds before next issue..."
            sleep "$DELAY"
        fi
    done

    # Summary
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    log_status "═══════════════════════════════════════════════════════════════"
    log_status "ORCHESTRATION COMPLETE"
    log_status "═══════════════════════════════════════════════════════════════"
    echo ""
    log_info "Milestone: $milestone"
    log_info "Issues processed: $processed"
    log_info "Succeeded: $succeeded"
    log_info "Failed: $failed"
    log_info "Duration: ${duration}s"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "(Dry run - no actual changes made)"
    fi
}

# Run main
main
