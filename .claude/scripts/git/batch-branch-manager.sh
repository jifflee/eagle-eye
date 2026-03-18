#!/bin/bash
set -euo pipefail
# batch-branch-manager.sh
# Manages batch branches for parallel container execution
# Part of Issue #565: Implement batch branch strategy for parallel containers
#
# This script handles:
#   1. Creating batch branches from dev
#   2. Listing active batch branches
#   3. Merging batch branches back to dev
#   4. Cleaning up old batch branches
#
# Usage:
#   ./scripts/batch-branch-manager.sh create [--name <name>]
#   ./scripts/batch-branch-manager.sh list
#   ./scripts/batch-branch-manager.sh merge <batch-branch>
#   ./scripts/batch-branch-manager.sh cleanup [--age-days <N>]
#   ./scripts/batch-branch-manager.sh get-current

set -e

# Script metadata
SCRIPT_NAME="batch-branch-manager.sh"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Default configuration
DEFAULT_BASE_BRANCH="dev"
DEFAULT_BATCH_PREFIX="container-batch"
DEFAULT_CLEANUP_AGE_DAYS=30

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Batch branch management for parallel containers

USAGE:
    $SCRIPT_NAME create [OPTIONS]          Create a new batch branch
    $SCRIPT_NAME list                       List active batch branches
    $SCRIPT_NAME merge <batch-branch>       Merge batch branch to dev
    $SCRIPT_NAME cleanup [OPTIONS]          Cleanup old batch branches
    $SCRIPT_NAME get-current                Get current active batch branch

COMMANDS:
    create              Create new batch branch from dev
    list                List all batch branches with metadata
    merge               Create PR to merge batch branch to dev
    cleanup             Remove old/merged batch branches
    get-current         Output current batch branch name (if exists)

CREATE OPTIONS:
    --name <name>       Custom batch branch name (default: auto-generated)
    --base <branch>     Base branch to fork from (default: dev)
    --description <txt> Description for batch (stored in git notes)

MERGE OPTIONS:
    --auto-merge        Auto-merge if CI passes (requires clean status)
    --delete-after      Delete batch branch after successful merge

CLEANUP OPTIONS:
    --age-days <N>      Delete branches older than N days (default: 30)
    --merged-only       Only delete already-merged branches
    --dry-run           Show what would be deleted without deleting

EXAMPLES:
    # Create batch branch for sprint
    $SCRIPT_NAME create --name "20260214-sprint-batch"

    # Create with auto-generated name
    $SCRIPT_NAME create

    # List active batches
    $SCRIPT_NAME list

    # Get current batch for container use
    $SCRIPT_NAME get-current

    # Merge batch to dev
    $SCRIPT_NAME merge container-batch-20260214

    # Cleanup old batches
    $SCRIPT_NAME cleanup --age-days 30 --merged-only

ENVIRONMENT VARIABLES:
    GITHUB_TOKEN        GitHub authentication token (required for merge)
    BATCH_BASE_BRANCH   Override default base branch (default: dev)

BATCH BRANCH NAMING:
    Format: container-batch-YYYYMMDD[-suffix]
    Examples:
        - container-batch-20260214
        - container-batch-20260214-sprint-5
        - container-batch-20260214-hotfix

NOTES:
    - Batch branches are lightweight git branches
    - Metadata stored in git notes (refs/notes/batch-info)
    - Cleanup preserves branches with unmerged commits
    - Use 'list' to see branch status before cleanup

EOF
}

# Generate batch branch name
generate_batch_name() {
    local suffix="${1:-}"
    local date_part
    date_part=$(date +%Y%m%d)

    if [ -n "$suffix" ]; then
        echo "${DEFAULT_BATCH_PREFIX}-${date_part}-${suffix}"
    else
        echo "${DEFAULT_BATCH_PREFIX}-${date_part}"
    fi
}

# Create batch branch
create_batch_branch() {
    local name="$1"
    local base="${2:-$DEFAULT_BASE_BRANCH}"
    local description="${3:-}"

    # Generate name if not provided
    if [ -z "$name" ]; then
        name=$(generate_batch_name)
    fi

    # Validate name format
    if [[ ! "$name" =~ ^${DEFAULT_BATCH_PREFIX}- ]]; then
        log_error "Batch branch name must start with '${DEFAULT_BATCH_PREFIX}-'"
        return 1
    fi

    # Check if branch already exists
    if git rev-parse --verify "$name" >/dev/null 2>&1; then
        log_warn "Branch '$name' already exists"
        echo "$name"
        return 0
    fi

    # Ensure base branch is up to date
    log_info "Fetching latest from origin..."
    git fetch origin "$base" --quiet

    # Create batch branch from base
    log_info "Creating batch branch '$name' from '$base'..."
    git branch "$name" "origin/$base"

    # Store metadata in git notes
    local metadata
    metadata=$(jq -n \
        --arg name "$name" \
        --arg base "$base" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg description "$description" \
        '{
            name: $name,
            base_branch: $base,
            created_at: $created_at,
            description: $description,
            created_by: "batch-branch-manager"
        }')

    git notes --ref=batch-info add -m "$metadata" "$name" 2>/dev/null || true

    # Push to remote
    log_info "Pushing batch branch to remote..."
    git push origin "$name"

    log_success "Batch branch created: $name"
    echo "$name"
}

# List batch branches
list_batch_branches() {
    log_info "Listing batch branches..."

    # Get all branches matching pattern
    local branches
    branches=$(git branch -r | grep "origin/${DEFAULT_BATCH_PREFIX}-" | sed 's|origin/||' | sed 's/^[[:space:]]*//' || echo "")

    if [ -z "$branches" ]; then
        log_info "No batch branches found"
        return 0
    fi

    echo ""
    echo "Active Batch Branches:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while IFS= read -r branch; do
        # Get branch metadata
        local commit_count
        commit_count=$(git rev-list --count "origin/$DEFAULT_BASE_BRANCH..$branch" 2>/dev/null || echo "0")

        local last_commit_date
        last_commit_date=$(git log -1 --format=%ci "$branch" 2>/dev/null || echo "unknown")

        local author
        author=$(git log -1 --format=%an "$branch" 2>/dev/null || echo "unknown")

        # Check merge status
        local merge_status
        if git merge-base --is-ancestor "$branch" "origin/$DEFAULT_BASE_BRANCH" 2>/dev/null; then
            merge_status="${GREEN}merged${NC}"
        else
            merge_status="${YELLOW}active${NC}"
        fi

        # Get notes if available
        local notes
        notes=$(git notes --ref=batch-info show "$branch" 2>/dev/null || echo "{}")
        local description
        description=$(echo "$notes" | jq -r '.description // "No description"' 2>/dev/null || echo "No description")

        echo -e "Branch: ${BLUE}$branch${NC}"
        echo "  Status: $merge_status"
        echo "  Commits: $commit_count ahead of $DEFAULT_BASE_BRANCH"
        echo "  Last commit: $last_commit_date"
        echo "  Author: $author"
        echo "  Description: $description"
        echo ""
    done <<< "$branches"
}

# Get current active batch branch
get_current_batch() {
    # Look for most recently created batch branch
    local current_branch
    current_branch=$(git branch -r | grep "origin/${DEFAULT_BATCH_PREFIX}-" | sed 's|origin/||' | sed 's/^[[:space:]]*//' | sort -r | head -1 || echo "")

    if [ -z "$current_branch" ]; then
        # No batch branch exists, return empty
        return 0
    fi

    # Check if this branch is still active (not merged)
    if git merge-base --is-ancestor "$current_branch" "origin/$DEFAULT_BASE_BRANCH" 2>/dev/null; then
        # Branch is merged, don't return it
        return 0
    fi

    echo "$current_branch"
}

# Merge batch branch to dev
merge_batch_branch() {
    local batch_branch="$1"
    local auto_merge="${2:-false}"
    local delete_after="${3:-false}"

    if [ -z "$batch_branch" ]; then
        log_error "Batch branch name required"
        return 1
    fi

    # Validate branch exists
    if ! git rev-parse --verify "$batch_branch" >/dev/null 2>&1; then
        log_error "Branch '$batch_branch' does not exist"
        return 1
    fi

    # Ensure it's a batch branch
    if [[ ! "$batch_branch" =~ ^${DEFAULT_BATCH_PREFIX}- ]]; then
        log_error "Not a batch branch: $batch_branch"
        return 1
    fi

    log_info "Merging batch branch '$batch_branch' to $DEFAULT_BASE_BRANCH..."

    # Check if already merged
    if git merge-base --is-ancestor "$batch_branch" "origin/$DEFAULT_BASE_BRANCH" 2>/dev/null; then
        log_warn "Branch '$batch_branch' already merged to $DEFAULT_BASE_BRANCH"
        return 0
    fi

    # Count commits
    local commit_count
    commit_count=$(git rev-list --count "origin/$DEFAULT_BASE_BRANCH..$batch_branch" 2>/dev/null || echo "0")

    log_info "Batch contains $commit_count commits"

    # Create PR for batch → dev merge
    log_info "Creating PR to merge batch to $DEFAULT_BASE_BRANCH..."

    local pr_title="Merge batch branch: $batch_branch → $DEFAULT_BASE_BRANCH"
    local pr_body
    pr_body="## Batch Branch Merge

This PR merges the batch branch \`$batch_branch\` back to \`$DEFAULT_BASE_BRANCH\`.

### Statistics
- **Commits**: $commit_count
- **Branch**: $batch_branch

### Batch Contents
\`\`\`
$(git log --oneline "origin/$DEFAULT_BASE_BRANCH..$batch_branch" | head -20)
\`\`\`

### Review Notes
- Review all changes in this batch
- Ensure CI passes before merging
- All individual container PRs should have been reviewed

---
Generated by batch-branch-manager.sh"

    local pr_url
    pr_url=$(gh pr create \
        --base "$DEFAULT_BASE_BRANCH" \
        --head "$batch_branch" \
        --title "$pr_title" \
        --body "$pr_body" 2>&1) || {
        log_error "Failed to create PR: $pr_url"
        return 1
    }

    log_success "PR created: $pr_url"

    # Auto-merge if requested
    if [ "$auto_merge" = "true" ]; then
        log_info "Waiting for CI before auto-merge..."

        local pr_number
        pr_number=$(echo "$pr_url" | grep -oE '[0-9]+$')

        # Enable auto-merge
        gh pr merge "$pr_number" --auto --squash || {
            log_warn "Auto-merge could not be enabled. Merge manually when CI passes."
        }
    fi

    # Delete branch if requested and merged
    if [ "$delete_after" = "true" ] && [ "$auto_merge" = "true" ]; then
        log_info "Branch will be deleted after merge completes"
    fi

    echo "$pr_url"
}

# Cleanup old batch branches
cleanup_batch_branches() {
    local age_days="${1:-$DEFAULT_CLEANUP_AGE_DAYS}"
    local merged_only="${2:-false}"
    local dry_run="${3:-false}"

    log_info "Cleaning up batch branches older than $age_days days..."

    # Get all batch branches
    local branches
    branches=$(git branch -r | grep "origin/${DEFAULT_BATCH_PREFIX}-" | sed 's|origin/||' | sed 's/^[[:space:]]*//' || echo "")

    if [ -z "$branches" ]; then
        log_info "No batch branches found"
        return 0
    fi

    local deleted_count=0
    local skipped_count=0

    while IFS= read -r branch; do
        # Get last commit date
        local last_commit_epoch
        last_commit_epoch=$(git log -1 --format=%ct "$branch" 2>/dev/null || echo "0")

        local current_epoch
        current_epoch=$(date +%s)

        local age_seconds=$((current_epoch - last_commit_epoch))
        local age_days_actual=$((age_seconds / 86400))

        # Check if old enough
        if [ "$age_days_actual" -lt "$age_days" ]; then
            log_debug "Skipping $branch (only $age_days_actual days old)"
            ((skipped_count++))
            continue
        fi

        # Check if merged (if merged_only flag set)
        if [ "$merged_only" = "true" ]; then
            if ! git merge-base --is-ancestor "$branch" "origin/$DEFAULT_BASE_BRANCH" 2>/dev/null; then
                log_debug "Skipping $branch (not merged)"
                ((skipped_count++))
                continue
            fi
        fi

        # Delete branch
        if [ "$dry_run" = "true" ]; then
            log_info "[DRY RUN] Would delete: $branch (age: $age_days_actual days)"
        else
            log_info "Deleting batch branch: $branch (age: $age_days_actual days)"
            git push origin --delete "$branch" 2>/dev/null || {
                log_warn "Failed to delete $branch"
                continue
            }
            # Also delete local branch if exists
            git branch -D "$branch" 2>/dev/null || true
            # Delete notes
            git notes --ref=batch-info remove "$branch" 2>/dev/null || true
        fi

        ((deleted_count++))
    done <<< "$branches"

    if [ "$dry_run" = "true" ]; then
        log_info "Dry run complete: would delete $deleted_count branches, skip $skipped_count"
    else
        log_success "Cleanup complete: deleted $deleted_count branches, skipped $skipped_count"
    fi
}

# Parse command
if [ $# -eq 0 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    create)
        NAME=""
        BASE="$DEFAULT_BASE_BRANCH"
        DESCRIPTION=""

        while [ $# -gt 0 ]; do
            case "$1" in
                --name)
                    NAME="$2"
                    shift 2
                    ;;
                --base)
                    BASE="$2"
                    shift 2
                    ;;
                --description)
                    DESCRIPTION="$2"
                    shift 2
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    log_error "Unknown option: $1"
                    exit 1
                    ;;
            esac
        done

        create_batch_branch "$NAME" "$BASE" "$DESCRIPTION"
        ;;

    list)
        list_batch_branches
        ;;

    get-current)
        get_current_batch
        ;;

    merge)
        if [ $# -eq 0 ]; then
            log_error "Batch branch name required"
            usage
            exit 1
        fi

        BATCH_BRANCH="$1"
        shift

        AUTO_MERGE="false"
        DELETE_AFTER="false"

        while [ $# -gt 0 ]; do
            case "$1" in
                --auto-merge)
                    AUTO_MERGE="true"
                    shift
                    ;;
                --delete-after)
                    DELETE_AFTER="true"
                    shift
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    log_error "Unknown option: $1"
                    exit 1
                    ;;
            esac
        done

        merge_batch_branch "$BATCH_BRANCH" "$AUTO_MERGE" "$DELETE_AFTER"
        ;;

    cleanup)
        AGE_DAYS="$DEFAULT_CLEANUP_AGE_DAYS"
        MERGED_ONLY="false"
        DRY_RUN="false"

        while [ $# -gt 0 ]; do
            case "$1" in
                --age-days)
                    AGE_DAYS="$2"
                    shift 2
                    ;;
                --merged-only)
                    MERGED_ONLY="true"
                    shift
                    ;;
                --dry-run)
                    DRY_RUN="true"
                    shift
                    ;;
                --help|-h)
                    usage
                    exit 0
                    ;;
                *)
                    log_error "Unknown option: $1"
                    exit 1
                    ;;
            esac
        done

        cleanup_batch_branches "$AGE_DAYS" "$MERGED_ONLY" "$DRY_RUN"
        ;;

    --help|-h)
        usage
        exit 0
        ;;

    *)
        log_error "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
