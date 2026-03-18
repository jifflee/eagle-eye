#!/bin/bash
set -euo pipefail
# merge-in-container.sh
# Handles PR merges with automatic fallback to container when branch is locked
#
# Usage: ./scripts/merge-in-container.sh <PR_NUMBER> [--squash|--merge|--rebase]
#
# Detects if target branch is locked by another worktree and uses
# containerized merge to avoid "branch already in use" errors.

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"

# Configuration
CONTAINER_IMAGE="${CONTAINER_IMAGE:-sprint-worker:latest}"
MERGE_METHOD="${MERGE_METHOD:-squash}"

# Custom step logging
log_step() { echo -e "${BLUE:-}[STEP]${NC:-} $1"; }

# Parse arguments
PR_NUMBER=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --squash) MERGE_METHOD="squash"; shift ;;
        --merge) MERGE_METHOD="merge"; shift ;;
        --rebase) MERGE_METHOD="rebase"; shift ;;
        --image) CONTAINER_IMAGE="$2"; shift 2 ;;
        -*) log_error "Unknown option: $1"; exit 1 ;;
        *) PR_NUMBER="$1"; shift ;;
    esac
done

if [ -z "$PR_NUMBER" ]; then
    echo "Usage: $0 <PR_NUMBER> [--squash|--merge|--rebase]"
    exit 1
fi

# Get repository information
get_repo_info() {
    REPO_FULL_NAME=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
    if [ -z "$REPO_FULL_NAME" ]; then
        log_error "Could not determine repository. Are you in a git repository?"
        exit 1
    fi
    log_info "Repository: $REPO_FULL_NAME"
}

# Get PR target branch
get_pr_target_branch() {
    TARGET_BRANCH=$(gh pr view "$PR_NUMBER" --json baseRefName -q '.baseRefName' 2>/dev/null)
    if [ -z "$TARGET_BRANCH" ]; then
        log_error "Could not get target branch for PR #$PR_NUMBER"
        exit 1
    fi
    log_info "PR #$PR_NUMBER targets branch: $TARGET_BRANCH"
}

# Check if target branch is locked by another worktree
is_branch_locked() {
    local branch="$1"
    local main_repo_dir

    # Find the main repository directory
    main_repo_dir=$(git rev-parse --git-common-dir 2>/dev/null | sed 's|/.git$||' | sed 's|/worktrees/.*||')

    if [ -z "$main_repo_dir" ] || [ ! -d "$main_repo_dir" ]; then
        # Not in a worktree context, check normally
        main_repo_dir=$(git rev-parse --show-toplevel 2>/dev/null)
    fi

    # List all worktrees and check if any has the target branch checked out
    local worktree_list
    worktree_list=$(git worktree list 2>/dev/null || echo "")

    if echo "$worktree_list" | grep -q "\[$branch\]"; then
        return 0  # Branch is locked
    fi

    return 1  # Branch is not locked
}

# Check if Docker is available
check_docker() {
    if ! command -v docker &>/dev/null; then
        log_warn "Docker not available"
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_warn "Docker daemon not running"
        return 1
    fi

    return 0
}

# Check if container image exists
check_container_image() {
    if docker image inspect "$CONTAINER_IMAGE" &>/dev/null; then
        return 0
    fi

    log_warn "Container image '$CONTAINER_IMAGE' not found"
    log_info "Build it with: docker build -f docker/Dockerfile.sprint-worker -t sprint-worker:latest ."
    return 1
}

# Merge using GitHub API (avoids local git operations entirely)
merge_via_api() {
    log_step "Merging PR #$PR_NUMBER via GitHub API..."

    local merge_response
    local merge_result

    # Use gh api to merge without local git operations
    merge_response=$(gh api \
        -X PUT \
        "repos/$REPO_FULL_NAME/pulls/$PR_NUMBER/merge" \
        -f merge_method="$MERGE_METHOD" \
        2>&1) || true

    # Check if merge was successful
    if echo "$merge_response" | grep -q '"merged": true'; then
        log_info "PR #$PR_NUMBER merged successfully via API"

        # Delete the branch via API
        local head_branch
        head_branch=$(gh pr view "$PR_NUMBER" --json headRefName -q '.headRefName' 2>/dev/null)

        if [ -n "$head_branch" ] && [ "$head_branch" != "$TARGET_BRANCH" ]; then
            log_step "Deleting branch: $head_branch"
            gh api -X DELETE "repos/$REPO_FULL_NAME/git/refs/heads/$head_branch" 2>/dev/null || true
        fi

        return 0
    elif echo "$merge_response" | grep -q "Pull Request is not mergeable"; then
        log_error "PR #$PR_NUMBER has merge conflicts or is not mergeable"
        return 1
    elif echo "$merge_response" | grep -q "already merged"; then
        log_info "PR #$PR_NUMBER was already merged"
        return 0
    else
        log_error "API merge failed: $merge_response"
        return 1
    fi
}

# Merge using local gh pr merge
merge_local() {
    log_step "Merging PR #$PR_NUMBER locally..."

    local merge_flag=""
    case $MERGE_METHOD in
        squash) merge_flag="--squash" ;;
        merge) merge_flag="--merge" ;;
        rebase) merge_flag="--rebase" ;;
    esac

    if gh pr merge "$PR_NUMBER" $merge_flag --delete-branch; then
        log_info "PR #$PR_NUMBER merged successfully"
        return 0
    else
        log_error "Local merge failed"
        return 1
    fi
}

# Merge using container
merge_in_container() {
    log_step "Merging PR #$PR_NUMBER in container..."

    # Validate required tokens
    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN is required for container merge"
        exit 1
    fi

    # Run merge command in container
    docker run --rm \
        -e GITHUB_TOKEN="$GITHUB_TOKEN" \
        -e REPO_FULL_NAME="$REPO_FULL_NAME" \
        "$CONTAINER_IMAGE" \
        gh pr merge "$PR_NUMBER" --squash --delete-branch --repo "$REPO_FULL_NAME"

    if [ $? -eq 0 ]; then
        log_info "PR #$PR_NUMBER merged successfully in container"
        return 0
    else
        log_error "Container merge failed"
        return 1
    fi
}

# Main execution
main() {
    log_info "Starting merge process for PR #$PR_NUMBER"

    # Get repository and PR info
    get_repo_info
    get_pr_target_branch

    # Check if branch is locked
    if is_branch_locked "$TARGET_BRANCH"; then
        log_warn "Branch '$TARGET_BRANCH' is locked by another worktree"

        # Try API merge first (fastest, no local git)
        log_info "Attempting API-only merge..."
        if merge_via_api; then
            exit 0
        fi

        # If API merge failed for non-conflict reasons, try container
        if check_docker && check_container_image; then
            log_info "Falling back to container merge..."
            if merge_in_container; then
                exit 0
            fi
        fi

        log_error "All merge methods failed"
        log_info "Please resolve the conflict manually or close other worktrees"
        exit 1
    else
        # Branch not locked, try local merge first
        log_info "Branch '$TARGET_BRANCH' is not locked, using local merge"

        if merge_local; then
            exit 0
        fi

        # Local failed, try API merge
        log_warn "Local merge failed, trying API merge..."
        if merge_via_api; then
            exit 0
        fi

        log_error "All merge methods failed"
        exit 1
    fi
}

# Run main
main
