#!/bin/bash
set -euo pipefail
# container-entrypoint.sh
# Entrypoint for sprint-worker container
# Handles authentication, repo setup, and command execution

set -e

# Get script directory for sourcing libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
# In container context, try multiple paths (container path first, then repo paths)
COMMON_SOURCED=false
for path in "/usr/local/lib/common.sh" "${SCRIPT_DIR}/../lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        COMMON_SOURCED=true
        break
    fi
done

# Fallback: define minimal logging functions if common.sh not found
if [ "$COMMON_SOURCED" = "false" ]; then
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Source structured logging library if available
STRUCTURED_LOGGING_SCRIPT=""
for path in "${SCRIPT_DIR}/../lib/structured-logging.sh" "/workspace/repo/scripts/lib/structured-logging.sh"; do
    if [ -f "$path" ]; then
        STRUCTURED_LOGGING_SCRIPT="$path"
        break
    fi
done

if [ -n "$STRUCTURED_LOGGING_SCRIPT" ]; then
    source "$STRUCTURED_LOGGING_SCRIPT"
    STRUCTURED_LOGGING_ENABLED=true
    # Initialize structured logging at container start
    init_structured_logging
else
    STRUCTURED_LOGGING_ENABLED=false
fi

# Source audit logging library if available
# In container, it may be at /workspace/repo/scripts or copied to /usr/local/bin
AUDIT_SCRIPT=""
for path in "${SCRIPT_DIR}/container-audit.sh" "/workspace/repo/scripts/container-audit.sh" "/usr/local/bin/container-audit.sh"; do
    if [ -f "$path" ]; then
        AUDIT_SCRIPT="$path"
        break
    fi
done

if [ -n "$AUDIT_SCRIPT" ]; then
    source "$AUDIT_SCRIPT"
    AUDIT_ENABLED=true
    # Start duration timer for container session
    start_duration_timer
else
    AUDIT_ENABLED=false
fi

# Validate required environment variables
validate_env() {
    local missing=0

    if [ -z "$GITHUB_TOKEN" ]; then
        log_error "GITHUB_TOKEN is required"
        missing=1
    fi

    # Either CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY must be set
    if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ] && [ -z "$ANTHROPIC_API_KEY" ]; then
        log_warn "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set"
        log_warn "Claude Code features will not be available"
    fi

    if [ $missing -eq 1 ]; then
        log_error "Missing required environment variables"
        exit 1
    fi
}

# Configure GitHub CLI authentication
setup_gh_auth() {
    log_info "Configuring GitHub CLI authentication..."

    # When GITHUB_TOKEN env var is set, gh auth login --with-token returns exit code 1
    # with a warning message, but authentication still works. We ignore the exit code
    # and verify with gh auth status instead.
    echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null || true

    # Verify authentication
    if gh auth status &>/dev/null; then
        log_info "GitHub CLI authenticated successfully"
    else
        log_error "GitHub CLI authentication failed"
        exit 1
    fi
}

# Configure Claude Code authentication (if token provided)
setup_claude_auth() {
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        log_info "Configuring Claude Code authentication..."
        export CLAUDE_CODE_OAUTH_TOKEN
        # Claude Code will pick up the token from environment
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        log_info "Using ANTHROPIC_API_KEY for Claude Code..."
        export ANTHROPIC_API_KEY
    fi
}

# Clone repository if REPO_FULL_NAME is provided
clone_repo() {
    if [ -n "$REPO_FULL_NAME" ]; then
        log_info "Cloning repository: $REPO_FULL_NAME"

        # Configure git credential helper to use GITHUB_TOKEN
        # This ensures git operations (clone, push, pull) work with token auth
        git config --global credential.helper "!f() { echo username=x-access-token; echo password=\$GITHUB_TOKEN; }; f"

        # Structured log: clone start
        if [ "$STRUCTURED_LOGGING_ENABLED" = "true" ]; then
            local context
            context=$(jq -n --arg repo "$REPO_FULL_NAME" '{repo: $repo, operation: "clone_start"}')
            log_info "git_operation" "$context" "Starting repository clone: $REPO_FULL_NAME"
        fi

        # Shallow clone for speed using HTTPS with token auth
        # Clone the target branch (BRANCH env var, auto-detected if not set) not the default branch
        # This ensures the container runs the latest scripts from the working branch
        local clone_branch="${BRANCH:-}"
        if [ -z "$clone_branch" ]; then
            # Detect the repo's default branch via GitHub API
            clone_branch=$(gh repo view "$REPO_FULL_NAME" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
            [ -z "$clone_branch" ] && clone_branch="main"
            log_info "Detected default branch: $clone_branch"
        fi
        local repo_url="https://github.com/${REPO_FULL_NAME}.git"
        log_info "Cloning branch: $clone_branch"
        if ! git clone --depth 1 -b "$clone_branch" "$repo_url" /workspace/repo; then
            if [ "$AUDIT_ENABLED" = "true" ]; then
                audit_container_error "CLONE_FAILED" "Failed to clone $REPO_FULL_NAME"
            fi
            if [ "$STRUCTURED_LOGGING_ENABLED" = "true" ]; then
                local error_context
                error_context=$(jq -n --arg repo "$REPO_FULL_NAME" '{repo: $repo, operation: "clone"}')
                log_error "git_error" "$error_context" "Failed to clone repository: $REPO_FULL_NAME"
            fi
            return 1
        fi
        cd /workspace/repo

        # Fetch all branches (shallow)
        git fetch --depth 1 origin

        # Get commit SHA for audit logging
        local commit_sha
        commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

        log_info "Repository cloned successfully"

        # Audit log: clone success
        if [ "$AUDIT_ENABLED" = "true" ]; then
            audit_container_clone "$REPO_FULL_NAME" "$clone_branch" "$commit_sha"
        fi

        # Structured log: clone complete
        if [ "$STRUCTURED_LOGGING_ENABLED" = "true" ]; then
            local context
            context=$(jq -n --arg repo "$REPO_FULL_NAME" --arg sha "$commit_sha" '{repo: $repo, commit_sha: $sha, operation: "clone_complete"}')
            log_info "git_operation" "$context" "Repository cloned successfully: $commit_sha"
        fi
    fi
}

# Bootstrap framework scripts for consumer repos deployed via manifest-sync
# When a container clones a consumer repo from GitHub, framework scripts don't exist
# because manifest-sync deploys them locally (untracked). This function detects that
# context and bootstraps the scripts from the framework repo.
bootstrap_framework_scripts() {
    # Check if framework scripts are already present (either native or manifest-sync deployed)
    if [ -f "./scripts/container-sprint-workflow.sh" ] || [ -f ".claude/scripts/container-sprint-workflow.sh" ]; then
        log_info "Framework scripts already present, skipping bootstrap"
        return 0
    fi

    # Scripts not found — this is a consumer repo needing bootstrap
    local framework_repo="${CLAUDE_FRAMEWORK_REPO:-jifflee/claude-tastic}"
    log_info "Framework scripts not found — bootstrapping from framework repo: $framework_repo"

    # Clone framework repo at shallow depth
    if ! git clone --depth 1 "https://github.com/${framework_repo}.git" /tmp/framework 2>/dev/null; then
        log_warn "Failed to clone framework repo $framework_repo — framework scripts unavailable"
        return 0
    fi

    # Run manifest-sync to deploy scripts to .claude/scripts/
    local manifest_sync="/tmp/framework/scripts/manifest-sync.sh"
    if [ -f "$manifest_sync" ] && [ -x "$manifest_sync" ]; then
        log_info "Running manifest-sync to deploy framework scripts..."
        if bash "$manifest_sync" --target .claude/ 2>/dev/null; then
            log_info "Framework scripts bootstrapped successfully to .claude/scripts/"
        else
            log_warn "manifest-sync failed — framework scripts may be incomplete"
        fi
    else
        log_warn "manifest-sync.sh not found in framework repo — bootstrap incomplete"
    fi

    # Cleanup cloned framework repo
    rm -rf /tmp/framework
}

# Sync skills from cloned repo to ~/.claude/commands/
# This makes slash commands like /sprint-work available in the container
sync_skills() {
    local update_script="/workspace/repo/scripts/skill-sync.sh"

    if [ ! -f "$update_script" ]; then
        log_warn "update-skills.sh not found, skills will not be available"
        return 0
    fi

    log_info "Syncing skills to ~/.claude/commands/..."

    # Run the update-skills script
    if bash "$update_script"; then
        log_info "Skills synced successfully"
    else
        log_warn "Failed to sync skills, some slash commands may not work"
    fi
}

# Initialize sprint state from environment variable
# This avoids GitHub API calls during container session
init_sprint_state() {
    if [ -z "$SPRINT_STATE_B64" ]; then
        log_warn "No SPRINT_STATE_B64 provided, state will be fetched on demand"
        return 0
    fi

    log_info "Initializing sprint state from environment..."

    # Decode base64 state
    local state_json
    state_json=$(echo "$SPRINT_STATE_B64" | base64 -d 2>/dev/null) || {
        log_warn "Failed to decode SPRINT_STATE_B64, invalid base64"
        return 0
    }

    # Validate JSON
    if ! echo "$state_json" | jq empty 2>/dev/null; then
        log_warn "SPRINT_STATE_B64 contains invalid JSON"
        return 0
    fi

    # Determine target location based on context
    local state_file
    if [ -d "/workspace/repo" ]; then
        state_file="/workspace/repo/.sprint-state.json"
    else
        state_file="/tmp/.sprint-state.json"
    fi

    # Write state to file
    echo "$state_json" > "$state_file"
    log_info "Sprint state written to $state_file"

    # Also set a marker that state was injected (for refresh logic)
    export SPRINT_STATE_INJECTED="true"
    export SPRINT_STATE_FILE="$state_file"

    # Clear the large env var to save memory (state is now in file)
    unset SPRINT_STATE_B64
}

# Cleanup on exit
cleanup() {
    local exit_code=$?
    log_info "Container cleanup initiated"

    # Audit log: container stop (from inside container)
    if [ "$AUDIT_ENABLED" = "true" ]; then
        local duration
        duration=$(get_duration)
        audit_container_stop "$exit_code" "$duration"
    fi

    # Clear sensitive environment variables from memory
    unset GITHUB_TOKEN
    unset CLAUDE_CODE_OAUTH_TOKEN
    unset ANTHROPIC_API_KEY

    log_info "Container cleanup complete"
}

# Set trap for cleanup
trap cleanup EXIT

# Configure git defaults at runtime
# When running with read-only rootfs and tmpfs home, build-time config is lost
setup_git_config() {
    git config --global user.name "Claude Sprint Worker"
    git config --global user.email "noreply@anthropic.com"
    git config --global init.defaultBranch main
}

# Ensure HOME points to a writable directory (Issue #492 fix)
# When running with read-only rootfs, Claude CLI needs a writable home directory
# for config/cache. Without this, Claude silently exits with code 0 and no output.
fix_home_directory() {
    if [ ! -w "$HOME" ] && [ -w "/home/claude" ]; then
        export HOME="/home/claude"
        log_info "HOME set to /home/claude (writable directory)"
    fi
}

# Main execution
main() {
    log_info "Sprint worker container starting..."

    # Fix HOME directory first (must be writable for git config and Claude)
    fix_home_directory

    # Structured log: container start
    if [ "$STRUCTURED_LOGGING_ENABLED" = "true" ]; then
        local context
        context=$(jq -n --arg issue "${ISSUE:-unknown}" '{issue: $issue}')
        log_info "container_start" "$context" "Container starting for issue ${ISSUE:-unknown}"
    fi

    # Configure git at runtime (tmpfs home loses build-time config)
    setup_git_config

    # Validate environment
    validate_env

    # Setup authentication
    setup_gh_auth
    setup_claude_auth

    # Clone repo if specified
    clone_repo

    # Bootstrap framework scripts for consumer repos (after clone, before skill sync)
    # Consumer repos don't have .claude/scripts/ in git; bootstrap from framework repo
    bootstrap_framework_scripts

    # Sync skills from repo to ~/.claude/ (after clone, so scripts are available)
    sync_skills

    # Initialize sprint state from environment (after repo clone so path is correct)
    init_sprint_state

    # Start heartbeat daemon for liveness monitoring (Issue #508)
    start_heartbeat

    # Execute the provided command
    if [ $# -gt 0 ]; then
        # Resolve script path: external repos using manifest-sync deploy scripts to
        # .claude/scripts/ (not ./scripts/). If the command starts with ./scripts/ and
        # the file doesn't exist there, fall back to .claude/scripts/ to support
        # external repos where manifest-sync deploys under .claude/.
        local cmd_path="$1"
        if [[ "$cmd_path" == ./scripts/* ]] && [ ! -f "$cmd_path" ]; then
            local alt_path=".claude/${cmd_path#./}"
            if [ -f "$alt_path" ]; then
                log_info "Script not found at $cmd_path, resolving to $alt_path (.claude/scripts/ deployment via manifest-sync)"
                shift
                set -- "$alt_path" "$@"
            fi
        fi
        log_info "Executing command: $*"
        exec "$@"
    else
        log_info "No command provided, starting interactive shell"
        exec /bin/bash
    fi
}

# ============================================================================
# HEARTBEAT DAEMON (Issue #508)
# ============================================================================
# Start heartbeat daemon for container liveness monitoring.
# This enables external tools to detect stuck containers.
start_heartbeat() {
    local heartbeat_script="${SCRIPT_DIR}/container-heartbeat.sh"

    # Also check in /workspace/repo for cloned context
    if [ ! -f "$heartbeat_script" ] && [ -f "/workspace/repo/scripts/container-heartbeat.sh" ]; then
        heartbeat_script="/workspace/repo/scripts/container-heartbeat.sh"
    fi

    if [ -f "$heartbeat_script" ] && [ -x "$heartbeat_script" ]; then
        log_info "Starting heartbeat daemon..."
        "$heartbeat_script" start
    else
        log_warn "Heartbeat script not found, container monitoring may be limited"
    fi
}

# Run main with all arguments
main "$@"
