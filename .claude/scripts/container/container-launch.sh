#!/bin/bash
set -euo pipefail
# container-launch.sh
# Wrapper script for container lifecycle management
# SECURITY: Enforces isolation - no volume mounts, tokens via env vars only
# size-ok: container lifecycle management with multiple execution modes and error recovery

set -e

# Script metadata
SCRIPT_NAME="container-launch.sh"
VERSION="1.3.0"
DEFAULT_IMAGE="claude-dev-env:latest"
DEFAULT_TIMEOUT="1800"  # 30 minutes default for autonomous mode

# Get script directory for sourcing audit library
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Source audit logging library
if [ -f "${SCRIPT_DIR}/container-audit.sh" ]; then
    source "${SCRIPT_DIR}/container-audit.sh"
    AUDIT_ENABLED=true
else
    AUDIT_ENABLED=false
fi

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Container lifecycle management for Claude agents

USAGE:
    $SCRIPT_NAME --issue <N> --repo <owner/repo> [OPTIONS]
    $SCRIPT_NAME --epic <N> --repo <owner/repo> [OPTIONS]
    $SCRIPT_NAME --list
    $SCRIPT_NAME --stop <N>
    $SCRIPT_NAME --cleanup

COMMANDS:
    --issue <N>     Launch container for issue number N
    --epic <N>      Launch container for epic's children (shows child selection)
    --list          List running containers
    --stop <N>      Stop container for issue N
    --cleanup       Stop all claude-tastic containers

OPTIONS:
    --repo <owner/repo>     Repository to clone (required with --issue/--epic)
    --branch <branch>       Branch to checkout (default: repo's default branch, auto-detected)
    --batch-branch <name>   Use batch branch for PR targeting (for parallel execution)
    --child <N>             Specific child of epic to work on (with --epic)
    --cmd <command>         Command to execute (default: interactive shell)
    --image <image>         Docker image to use (default: $DEFAULT_IMAGE)
    --role <role>           Container role (orchestrator, implementation, code_review,
                            documentation, security_review, test_runner)
    --detach                Run container in background (default for --sprint-work)
    --sync                  Run container synchronously (foreground, blocks terminal)
    --foreground            Alias for --sync
    --no-tty                Run without TTY (for CI/CD)
    --interactive           Human-supervised mode with permission prompts (foreground)
    --skip-preflight        Skip dependency/epic preflight checks
    --force                 Force launch despite preflight warnings
    --no-monitor            Disable dynamic requirement monitoring
    --monitor-interval <N>  Issue monitoring interval in seconds (default: 60)
    --debug                 Enable debug logging

AUTONOMOUS OPTIONS (for automated/unattended execution):
    --autonomous            Run in autonomous mode (non-interactive, with timeout)
    --timeout <sec>         Container timeout in seconds (default: 1800 = 30 min)
    --auto-tokens           Auto-load tokens from macOS Keychain
    --exec-mode <mode>      Execution mode: 'simple' (sync, for quick tasks) or
                            'complex' (detached with polling, for long tasks)
                            Default: simple
    --poll-interval <sec>   Polling interval for complex mode (default: 30)
    --heartbeat-timeout <s> Max seconds without heartbeat before considered hung (default: 300)
    --sprint-work           Shorthand for: --autonomous --auto-tokens --detach
                            (runs in background by default, use --sync to override)
    --fire-and-forget       Deprecated alias for --sprint-work (same behavior)

REMOTE OPTIONS (SSH-based remote Docker execution):
    --remote [host]         Launch on remote Docker host via SSH (default: docker-workers)
                            Remote host: docker-workers (10.69.5.11) via SSH
    --remote-host <host>    Override remote host (default: docker-workers)
    --remote-key <path>     SSH key path (default: ~/.ssh/id_ed25519_proxmox_bootstrap)
    --remote-user <user>    SSH username (default: ubuntu)
    --remote-env <path>     Remote env file with tokens (default: /opt/apps/claude-workers/.env)
    --fallback-local        Fall back to local Docker if SSH connection fails

CLOUD OPTIONS (optional - local Docker is default):
    --cloud <provider>      Use cloud infrastructure instead of local Docker
                            Providers: gcp-cloudrun, github-actions
    --project <id>          GCP project ID (for gcp-cloudrun)
    --region <region>       GCP region (default: us-central1)
    --memory <size>         Memory allocation (default: 2Gi)
    --cpu <count>           CPU allocation (default: 2)
    --cloud-timeout <sec>   Max cloud execution time (default: 3600)

ENVIRONMENT VARIABLES:
    GITHUB_TOKEN              GitHub authentication token (required)
    CLAUDE_CODE_OAUTH_TOKEN   Claude Code OAuth token
    ANTHROPIC_API_KEY         Alternative API key for Claude
    CLAUDE_FRAMEWORK_REPO     Framework repo for bootstrap in consumer repos (default: jifflee/claude-tastic)

    Watchdog Configuration (Issue #509):
    PHASE_TIMEOUT             Max seconds per Claude invocation phase (default: 600)
    TOTAL_TIMEOUT             Max seconds total for all phases (default: 3600)
    HEARTBEAT_MAX_AGE         Max seconds without heartbeat update (default: 120)
    WATCHDOG_CHECK_INTERVAL   Seconds between watchdog checks (default: 10)
    WATCHDOG_DISABLED         Set to 'true' to disable watchdog (default: false)

    Container-internal (set automatically):
    SPRINT_STATE_B64          Base64-encoded sprint state JSON (generated by this script)
    EPIC_NUMBER               Epic number (if working on epic child)
    EPIC_CONTEXT_B64          Base64-encoded epic context JSON (children status)

EXAMPLES:
    # Launch container for issue 107 (runs in background by default with --sprint-work)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work

    # Launch with specific command (interactive, foreground)
    $SCRIPT_NAME --issue 107 --repo owner/repo --cmd "claude /sprint-work"

    # Run in foreground (synchronous, blocks terminal)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --sync

    # Explicitly run in background (same as default for --sprint-work)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --detach

    # Launch for epic (shows child selection menu)
    $SCRIPT_NAME --epic 128 --repo owner/repo

    # Launch for specific epic child
    $SCRIPT_NAME --epic 128 --child 132 --repo owner/repo

    # List all running containers
    $SCRIPT_NAME --list

    # Stop specific container
    $SCRIPT_NAME --stop 107

    # Cleanup all containers
    $SCRIPT_NAME --cleanup

AUTONOMOUS EXAMPLES (for unattended execution):
    # Run sprint-work autonomously (loads tokens, runs detached by default)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work

    # Run sprint-work synchronously (blocks until complete)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --sync

    # Autonomous with custom timeout (1 hour)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --timeout 3600

REMOTE EXAMPLES (SSH-based remote Docker):
    # Launch on docker-workers (default remote host)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --remote

    # Launch on specific remote host
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --remote --remote-host myhost

    # Check remote capacity before launching
    $SCRIPT_NAME --remote --check-capacity

    # List containers on remote host
    $SCRIPT_NAME --list --remote

    # Launch with local fallback if SSH fails
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --remote --fallback-local

CLOUD EXAMPLES (optional):
    # Launch on GCP Cloud Run (instead of local Docker)
    $SCRIPT_NAME --issue 107 --repo owner/repo --cloud gcp-cloudrun --project my-project

    # Generate GitHub Actions workflow
    $SCRIPT_NAME --issue 107 --repo owner/repo --cloud github-actions

    # Cloud with custom resources
    $SCRIPT_NAME --issue 107 --repo owner/repo --cloud gcp-cloudrun --memory 4Gi --cpu 4

    # Show cloud cost estimation
    cloud-container-launch.sh --cost-estimate

RESOURCE LIMIT OVERRIDES (via environment variables):
    CONTAINER_MEMORY              Memory limit (default: 2g)
    CONTAINER_CPUS                CPU limit (default: 2)
    CONTAINER_PIDS                PID limit (default: 256)

SECURITY:
    This script enforces isolation - NO volume mounts are used.
    Tokens are passed via environment variables only.
    Container has NO access to host filesystem.
    Containers run as non-root user (UID 1000).
    All Linux capabilities are dropped.
    Privilege escalation is prevented (no-new-privileges).
    Root filesystem is read-only (tmpfs for /tmp, /home/claude, /workspace).
EOF
}

# Detect the default branch of a repository via GitHub API
# Usage: detect_default_branch <owner/repo>
# Falls back to "main" if detection fails (gh not available, no token, etc.)
detect_default_branch() {
    local repo="${1:-}"
    if [ -z "$repo" ]; then
        echo "main"
        return
    fi
    local default_branch
    default_branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "")
    if [ -n "$default_branch" ]; then
        echo "$default_branch"
    else
        echo "main"
    fi
}

# Load tokens from macOS Keychain if not in environment
# This enables automatic token loading without manual eval step
load_tokens_from_keychain() {
    # Only attempt on macOS with security command
    if ! command -v security &> /dev/null; then
        log_debug "Keychain not available (not macOS or security command missing)"
        return 0
    fi

    local loaded=0

    # Load GitHub token if not set
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        local gh_token
        gh_token=$(security find-generic-password -a "$USER" -s "github-container-token" -w 2>/dev/null) || true
        if [ -n "$gh_token" ]; then
            export GITHUB_TOKEN="$gh_token"
            export GH_TOKEN="$gh_token"
            log_info "Loaded GITHUB_TOKEN from keychain"
            loaded=1
        else
            # Fallback: try gh auth token
            gh_token=$(gh auth token 2>/dev/null) || true
            if [ -n "$gh_token" ]; then
                export GITHUB_TOKEN="$gh_token"
                export GH_TOKEN="$gh_token"
                log_info "Loaded GITHUB_TOKEN from gh auth"
                loaded=1
            fi
        fi
    fi

    # Load Claude OAuth token if not set
    if [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
        local claude_token
        claude_token=$(security find-generic-password -a "$USER" -s "claude-oauth-token" -w 2>/dev/null) || true
        if [ -n "$claude_token" ]; then
            export CLAUDE_CODE_OAUTH_TOKEN="$claude_token"
            log_info "Loaded CLAUDE_CODE_OAUTH_TOKEN from keychain"
            loaded=1
        fi
    fi

    if [ $loaded -eq 0 ]; then
        log_debug "No tokens loaded from keychain (already set or not found)"
    fi

    return 0
}

# Validate tokens are available (from environment only)
validate_tokens() {
    # First, attempt to load from keychain if not already set
    load_tokens_from_keychain

    local missing=0

    if [ -z "${GITHUB_TOKEN:-}" ]; then
        log_error "GITHUB_TOKEN environment variable is required"
        log_error "Set up tokens with: ./scripts/load-container-tokens.sh setup"
        missing=1
    fi

    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        log_warn "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set"
        log_warn "Claude Code features will be limited"
    fi

    if [ $missing -eq 1 ]; then
        log_error "Missing required tokens. Set them in your environment."
        log_error "Do NOT pass tokens as command line arguments or via files."
        return 1
    fi

    log_debug "Token validation passed"
    return 0
}

# Auto-load tokens from macOS Keychain (for --auto-tokens flag)
# This allows automated workflows without manual token export
auto_load_tokens() {
    log_info "Auto-loading tokens from keychain..."

    # Check if we're on macOS
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "Auto-token loading is only supported on macOS (uses Keychain)"
        return 1
    fi

    # Check if security command is available
    if ! command -v security &> /dev/null; then
        log_error "macOS 'security' command not found"
        return 1
    fi

    # Load GitHub token if not already set
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        local gh_token
        gh_token=$(security find-generic-password -a "$USER" -s "github-container-token" -w 2>/dev/null) || true
        if [ -n "$gh_token" ]; then
            export GITHUB_TOKEN="$gh_token"
            log_info "Loaded GITHUB_TOKEN from keychain"
        else
            log_warn "Could not load GITHUB_TOKEN from keychain"
            log_warn "Run: ./scripts/load-container-tokens.sh setup"
        fi
    else
        log_debug "GITHUB_TOKEN already set in environment"
    fi

    # Load Claude OAuth token if not already set
    if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        local claude_token
        claude_token=$(security find-generic-password -a "$USER" -s "claude-oauth-token" -w 2>/dev/null) || true
        if [ -n "$claude_token" ]; then
            # Check for session token (not valid for CLI)
            if [[ "$claude_token" =~ ^sk-ant-sid[0-9]*- ]]; then
                log_error "Session token detected in keychain (not valid for container/CLI use)"
                log_error ""
                log_error "Token prefix: ${claude_token:0:15}..."
                log_error ""
                log_error "You have a browser SESSION token stored in keychain."
                log_error "Session tokens are NOT valid for Claude Code CLI operations."
                log_error ""
                log_error "══════════════════════════════════════════════════════════"
                log_error "To fix this:"
                log_error ""
                log_error "  1. Generate a proper OAuth token:"
                log_error "     claude setup-token"
                log_error ""
                log_error "  2. Update keychain with the new token:"
                log_error "     security delete-generic-password -a \"\$USER\" -s \"claude-oauth-token\""
                log_error "     security add-generic-password -a \"\$USER\" -s \"claude-oauth-token\" -w \"sk-ant-oat01-...\""
                log_error "══════════════════════════════════════════════════════════"
                return 1
            fi
            export CLAUDE_CODE_OAUTH_TOKEN="$claude_token"
            log_info "Loaded CLAUDE_CODE_OAUTH_TOKEN from keychain"
        else
            log_warn "Could not load CLAUDE_CODE_OAUTH_TOKEN from keychain"
        fi
    else
        log_debug "Claude token already set in environment"
        # Also validate tokens that are already in environment
        if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] && [[ "$CLAUDE_CODE_OAUTH_TOKEN" =~ ^sk-ant-sid[0-9]*- ]]; then
            log_error "Session token detected in CLAUDE_CODE_OAUTH_TOKEN (not valid for CLI)"
            log_error "Run: claude setup-token"
            return 1
        fi
    fi

    return 0
}

# Detect and validate container runtime (Docker Desktop)
detect_runtime() {
    if command -v docker &> /dev/null && docker info &> /dev/null; then
        log_info "Using Docker Desktop"
        return 0
    fi

    log_error "Docker Desktop is not available"
    log_error "Options:"
    log_error "  1. Install Docker Desktop: brew install --cask docker"
    log_error "  2. Start Docker Desktop if already installed"
    log_error "  3. See docs/CONTAINER_SETUP.md for setup guide"
    return 1
}

# Check if Docker is available (legacy - now uses detect_runtime)
check_docker() {
    detect_runtime
}

# Check if image exists
check_image() {
    local image="$1"

    if ! docker image inspect "$image" &> /dev/null; then
        log_error "Docker image '$image' not found"
        log_error "Build it first with: docker build -f docker/Dockerfile.sprint-worker -t $image ."
        return 1
    fi

    log_debug "Image '$image' found"
    return 0
}

# Generate sprint state and encode as base64
# This runs on the host before container launch, avoiding API calls inside container
generate_sprint_state() {
    local issue="$1"
    local repo="$2"
    local branch="$3"

    log_info "Generating sprint state for issue #$issue..."

    # Get script directory
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"

    # Check if generate-sprint-state.sh exists
    if [ ! -x "$script_dir/generate-sprint-state.sh" ]; then
        log_warn "generate-sprint-state.sh not found, skipping state generation"
        return 0
    fi

    # Generate state JSON
    local state_json
    state_json=$("$script_dir/generate-sprint-state.sh" "$issue" --base-branch "$branch" 2>/dev/null) || {
        log_warn "Failed to generate sprint state, container will fetch on demand"
        return 0
    }

    # Encode as base64 for safe transport via environment variable
    # Using single-line base64 to avoid newline issues
    local state_b64
    state_b64=$(echo "$state_json" | base64 | tr -d '\n')

    # Check size - environment variables have practical limits (~128KB safe)
    local size=${#state_b64}
    if [ "$size" -gt 131072 ]; then
        log_warn "Sprint state too large ($size bytes), skipping injection"
        return 0
    fi

    log_debug "Sprint state generated ($size bytes base64)"
    echo "$state_b64"
}

# Generate container name from issue number
container_name() {
    local issue="$1"
    echo "${CONTAINER_PREFIX}-${issue}"
}

# Check if container is already running
is_container_running() {
    local name="$1"
    docker ps --filter "name=^${name}$" --format '{{.Names}}' | grep -q "^${name}$"
}

# Run preflight checks before launching container
run_preflight() {
    local issue="$1"
    local epic="$2"
    local skip_preflight="$3"
    local force="$4"

    if [ "$skip_preflight" = "true" ]; then
        log_info "Skipping preflight checks (--skip-preflight)"
        return 0
    fi

    local preflight_script="${SCRIPT_DIR}/container-preflight.sh"
    if [ ! -x "$preflight_script" ]; then
        log_warn "Preflight script not found, skipping checks"
        return 0
    fi

    log_info "Running preflight checks..."

    local preflight_args=("--json")
    if [ -n "$issue" ]; then
        preflight_args+=("--issue" "$issue")
    fi
    if [ -n "$epic" ]; then
        preflight_args+=("--epic" "$epic")
    fi
    if [ "$force" = "true" ]; then
        preflight_args+=("--force")
    fi

    local preflight_result
    preflight_result=$("$preflight_script" "${preflight_args[@]}" 2>/dev/null)

    if [ -z "$preflight_result" ]; then
        log_warn "Preflight returned empty result, proceeding anyway"
        return 0
    fi

    local action
    action=$(echo "$preflight_result" | jq -r '.action')

    case "$action" in
        continue)
            log_info "Preflight passed"
            ;;
        warn)
            log_warn "Preflight detected warnings:"
            echo "$preflight_result" | jq -r '.warnings[]' 2>/dev/null | while read -r warning; do
                log_warn "  - $warning"
            done
            if [ "$force" != "true" ]; then
                log_info "Proceeding with warnings (use --force to suppress)"
            fi
            ;;
        block)
            log_error "Preflight BLOCKED launch:"
            echo "$preflight_result" | jq -r '.blockers[]' 2>/dev/null | while read -r blocker; do
                log_error "  - $blocker"
            done
            if [ "$force" = "true" ]; then
                log_warn "Force flag set, proceeding despite blockers"
            else
                return 1
            fi
            ;;
        error)
            log_error "Preflight error: $(echo "$preflight_result" | jq -r '.error // "Unknown error"')"
            return 1
            ;;
    esac

    # Return the preflight result for further processing (e.g., epic context)
    echo "$preflight_result"
    return 0
}

# Run capacity check before container launch
# Returns 0 if capacity available, 1 if blocked
_check_container_capacity() {
    local skip_preflight="$1"
    local force="$2"

    if [ "$skip_preflight" != "true" ] && [ "$force" != "true" ]; then
        log_info "Checking container capacity (token utilization + resources)..."

        local capacity_check_script="${SCRIPT_DIR}/check-container-capacity.sh"
        if [ -x "$capacity_check_script" ]; then
            local capacity_result
            capacity_result=$("$capacity_check_script" 2>&1) || {
                log_warn "Capacity check script failed, proceeding anyway"
                capacity_result=""
            }

            if [ -n "$capacity_result" ]; then
                local can_spawn
                can_spawn=$(echo "$capacity_result" | jq -r '.can_spawn // false')

                if [ "$can_spawn" = "false" ]; then
                    local reason
                    reason=$(echo "$capacity_result" | jq -r '.reason // "Unknown reason"')
                    local failed_check
                    failed_check=$(echo "$capacity_result" | jq -r '.failed_check // "unknown"')

                    log_error "CAPACITY CHECK FAILED: Cannot spawn container"
                    log_error "Reason: $reason"
                    log_error "Failed check: $failed_check"
                    log_error ""
                    log_error "Current capacity status:"
                    echo "$capacity_result" | jq -r '.checks' 2>/dev/null | while IFS= read -r line; do
                        log_error "  $line"
                    done
                    log_error ""
                    log_error "Use --force to override capacity checks (not recommended)"
                    log_error "Or wait for capacity to become available and retry"

                    # Auto-escalate capacity blocker to infra repo (feature #1338)
                    local escalate_script="${SCRIPT_DIR}/../infra/auto-escalate-infra.sh"
                    if [ -x "$escalate_script" ] && [ -n "${issue:-}" ]; then
                        log_info "Escalating capacity blocker to infra repo..."
                        "$escalate_script" \
                            --issue "$issue" \
                            --error "CAPACITY CHECK FAILED: $reason (failed_check: $failed_check)" \
                            --context "Capacity check output: $(echo "$capacity_result" | jq -c '.' 2>/dev/null || echo "$capacity_result")" \
                            --threshold medium \
                            2>/dev/null || true
                    fi

                    return 1
                else
                    local reason
                    reason=$(echo "$capacity_result" | jq -r '.reason // "Capacity available"')
                    log_info "✓ Capacity check passed: $reason"
                fi
            fi
        else
            log_warn "Capacity check script not found, skipping capacity checks"
        fi
    elif [ "$force" = "true" ]; then
        log_warn "Force flag set, skipping capacity checks"
    fi

    return 0
}

# Run preflight validation checks
# Outputs: preflight_result JSON on stdout
# Returns: 0 on success/warn, 1 on block
_run_preflight_validation() {
    local issue="$1"
    local epic="$2"
    local skip_preflight="$3"
    local force="$4"

    local preflight_result=""
    if [ "$skip_preflight" != "true" ]; then
        preflight_result=$(run_preflight "$issue" "$epic" "$skip_preflight" "$force") || {
            log_error "Preflight checks failed. Use --force to override."
            return 1
        }
    fi

    echo "$preflight_result"
    return 0
}

# Build Docker run arguments array
# Sets global docker_args array
_setup_docker_args() {
    local name="$1"
    local repo_url="$2"
    local repo="$3"
    local branch="$4"
    local batch_branch="$5"
    local issue="$6"
    local image="$7"
    local sprint_state_b64="$8"
    local epic="$9"
    local epic_context_b64="${10}"
    local role="${11}"
    local interactive_mode="${12}"
    local detach="${13}"
    local no_tty="${14}"
    local cmd="${15}"

    # Ensure shared network exists (compose creates it, but container may launch first)
    if ! docker network inspect n8n-shared &>/dev/null 2>&1; then
        docker network create n8n-shared 2>/dev/null || true
    fi

    docker_args=(
        "run"
        "--name" "$name"
        # Network configuration (Issue #726)
        # Connect to shared network for n8n communication
        "--network" "n8n-shared"
        # Security hardening
        "--cap-drop" "ALL"                          # Drop all Linux capabilities
        "--security-opt" "no-new-privileges:true"   # Prevent privilege escalation
        "--read-only"                               # Read-only root filesystem
        "--tmpfs" "/tmp:rw,noexec,nosuid,size=100m" # Writable /tmp (no exec)
        "--tmpfs" "/home/claude:rw,exec,mode=1777,size=512m"  # Writable home for Claude CLI (debug logs can exceed 400MB)
        "--tmpfs" "/root:rw,exec,size=100m"         # Writable root home (fallback for images running as root)
        "--tmpfs" "/workspace:rw,exec,mode=1777,size=1g"  # Writable workspace for repo clone (world-writable like /tmp)
        # Resource limits
        "--memory" "${CONTAINER_MEMORY:-2g}"        # Memory limit (default 2GB)
        "--cpus" "${CONTAINER_CPUS:-2}"             # CPU limit (default 2 cores)
        "--pids-limit" "${CONTAINER_PIDS:-256}"     # PID limit (prevent fork bombs)
        # Environment variables
        "-e" "GITHUB_TOKEN"
        "-e" "REPO_URL=$repo_url"
        "-e" "REPO_FULL_NAME=$repo"
        "-e" "BRANCH=$branch"
        "-e" "BATCH_BRANCH=$batch_branch"
        "-e" "ISSUE=$issue"
        # Fix for Claude CLI hang (Issue #492): Set HOME explicitly
        # When container runs as root with read-only rootfs, Claude needs
        # a writable home directory for config/cache. Without this, Claude
        # silently exits with code 0 and no output.
        "-e" "HOME=/home/claude"
        # Disable Claude debug logs (Issue #621): Prevent tmpfs overflow
        # Debug logs can exceed 400MB in containers. Since containers are
        # ephemeral and output is captured via docker logs, disable debug
        # logging to prevent filling tmpfs.
        "-e" "CLAUDE_DEBUG=0"
    )

    # Add sprint state if generated successfully
    if [ -n "$sprint_state_b64" ]; then
        docker_args+=("-e" "SPRINT_STATE_B64=$sprint_state_b64")
        log_info "Sprint state will be injected into container"
    fi

    # Add epic context if available
    if [ -n "$epic" ]; then
        docker_args+=("-e" "EPIC_NUMBER=$epic")
        log_info "Epic context: working on child of epic #$epic"
    fi
    if [ -n "$epic_context_b64" ]; then
        docker_args+=("-e" "EPIC_CONTEXT_B64=$epic_context_b64")
        log_info "Epic status will be injected into container"
    fi

    # Add container role if specified (Issue #154)
    if [ -n "$role" ]; then
        docker_args+=("-e" "CONTAINER_ROLE=$role")
        docker_args+=("-e" "CLAUDE_CONTAINER_MODE=true")
        log_info "Container role: $role"

        # Set permission scope based on role
        case "$role" in
            orchestrator|code_review|security_review|test_runner)
                docker_args+=("-e" "PERMISSION_SCOPE=read_only")
                ;;
            implementation)
                docker_args+=("-e" "PERMISSION_SCOPE=write_full")
                ;;
            documentation)
                docker_args+=("-e" "PERMISSION_SCOPE=write_docs")
                ;;
        esac
    fi

    # Issue monitoring for containers (Issue #166)
    # Container entrypoint will start background monitor if enabled
    if [ "${ISSUE_MONITOR_ENABLED:-true}" = "true" ]; then
        docker_args+=("-e" "ISSUE_MONITOR_ENABLED=true")
        docker_args+=("-e" "ISSUE_MONITOR_INTERVAL=${ISSUE_MONITOR_INTERVAL:-60}")
        log_debug "Issue monitoring enabled (interval: ${ISSUE_MONITOR_INTERVAL:-60}s)"
    else
        docker_args+=("-e" "ISSUE_MONITOR_ENABLED=false")
        log_debug "Issue monitoring disabled (--no-monitor)"
    fi

    # Watchdog configuration for Claude invocation monitoring (Issue #509)
    # Set timeout thresholds based on issue requirements
    docker_args+=("-e" "PHASE_TIMEOUT=${PHASE_TIMEOUT:-600}")           # 10 min per phase
    docker_args+=("-e" "TOTAL_TIMEOUT=${TOTAL_TIMEOUT:-3600}")          # 60 min total
    docker_args+=("-e" "HEARTBEAT_MAX_AGE=${HEARTBEAT_MAX_AGE:-120}")   # 2 min stale heartbeat
    docker_args+=("-e" "WATCHDOG_CHECK_INTERVAL=${WATCHDOG_CHECK_INTERVAL:-10}")
    log_debug "Watchdog timeouts: phase=${PHASE_TIMEOUT:-600}s, total=${TOTAL_TIMEOUT:-3600}s, heartbeat=${HEARTBEAT_MAX_AGE:-120}s"

    # Interactive mode for human-supervised execution (permission prompts enabled)
    if [ "$interactive_mode" = "true" ]; then
        docker_args+=("-e" "INTERACTIVE_MODE=true")
        log_info "Interactive mode: Claude will prompt for permission decisions"
    fi

    # Add Claude tokens if available
    if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
        docker_args+=("-e" "CLAUDE_CODE_OAUTH_TOKEN")
    fi
    if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
        docker_args+=("-e" "ANTHROPIC_API_KEY")
    fi

    # Pass framework repo override for consumer repo bootstrap (Issue #1285)
    # Allows specifying a custom framework source for manifest-sync bootstrap
    if [ -n "${CLAUDE_FRAMEWORK_REPO:-}" ]; then
        docker_args+=("-e" "CLAUDE_FRAMEWORK_REPO")
        log_info "Using custom framework repo for bootstrap: $CLAUDE_FRAMEWORK_REPO"
    fi

    # Add detach flag if requested
    if [ "$detach" = "true" ]; then
        docker_args+=("-d")
        log_info "Running in detached mode"
    fi

    # Add TTY flags based on availability and settings
    # -i (interactive) keeps stdin open
    # -t (tty) allocates a pseudo-TTY (requires actual TTY on host)
    if [ "$no_tty" != "true" ] && [ "$detach" != "true" ]; then
        # Always add -i for interactive stdin
        docker_args+=("-i")
        # Only add -t if we actually have a TTY (fails in Claude Code, CI, etc.)
        if [ -t 0 ]; then
            docker_args+=("-t")
        else
            log_debug "No TTY available, running without -t flag"
        fi
    fi

    # Add image
    docker_args+=("$image")

    # Add command if specified
    if [ -n "$cmd" ]; then
        # Wrap command in bash -c to handle complex commands with &&, |, etc.
        docker_args+=("bash" "-c" "$cmd")
    fi

    log_debug "Docker command: docker ${docker_args[*]}"
    log_info "Container has NO host filesystem access (isolation enforced)"
}

# Execute container in autonomous mode (non-interactive with timeout)
# Returns: container exit code
_execute_autonomous() {
    local name="$1"
    local issue="$2"
    local image="$3"
    local timeout_secs="$4"
    local exec_mode="$5"
    local poll_interval="$6"
    local heartbeat_timeout="$7"
    local tokens_present="$8"
    shift 8
    local docker_args=("$@")

    log_info "Autonomous mode: exec_mode=${exec_mode}, timeout=${timeout_secs}s"

    # Track start time for duration calculation
    if [ "$AUDIT_ENABLED" = "true" ]; then
        start_duration_timer
        ISSUE="$issue" CONTAINER_ID="$name" \
            audit_container_start "$image" "$tokens_present" "autonomous=true,exec_mode=${exec_mode},timeout=${timeout_secs}"
    fi

    local exit_code=0
    trap '_handle_container_exit "$?" "$name" "$issue"' EXIT

    if [ "$exec_mode" = "simple" ]; then
        # Simple mode: synchronous execution with timeout
        log_info "Simple mode: synchronous execution with ${timeout_secs}s timeout"

        # Use timeout command to enforce time limit
        # timeout returns 124 if the command times out
        timeout "$timeout_secs" docker "${docker_args[@]}" || exit_code=$?

        if [ $exit_code -eq 124 ]; then
            log_error "Container timed out after ${timeout_secs} seconds"
            docker stop "$name" 2>/dev/null || docker kill "$name" 2>/dev/null || true
        elif [ $exit_code -ne 0 ]; then
            log_error "Container exited with code $exit_code"

            # Capture diagnostics for non-zero exit (Issue #610)
            if [ -x "${SCRIPT_DIR}/container-diagnostic-capture.sh" ]; then
                log_info "Capturing diagnostic logs..."
                "${SCRIPT_DIR}/container-diagnostic-capture.sh" \
                    --container "$name" \
                    --log-lines 100 \
                    ${DEBUG:+--debug} || true
            fi
        else
            log_info "Container completed successfully"
        fi

    else
        # Complex mode: detached execution with polling and heartbeat monitoring
        log_info "Complex mode: detached with polling (interval=${poll_interval}s, heartbeat_timeout=${heartbeat_timeout}s)"

        # Launch detached
        local container_id
        docker_args_detached=("${docker_args[@]}")
        # Remove -it if present, add -d
        # NOTE: --rm removed (Issue #540) - containers persist for inspection
        docker_args_detached=("run" "-d" "--name" "$name")
        # Copy environment and other args (skip run, --name, and container name)
        for arg in "${docker_args[@]:3}"; do
            docker_args_detached+=("$arg")
        done

        container_id=$(docker "${docker_args_detached[@]}") || {
            log_error "Failed to start container"
            return 1
        }
        log_info "Container started in detached mode: ${container_id:0:12}"

        # Poll for completion with heartbeat monitoring
        local start_time last_activity_time current_time elapsed no_activity_time
        start_time=$(date +%s)
        last_activity_time=$start_time

        while true; do
            sleep "$poll_interval"
            current_time=$(date +%s)
            elapsed=$((current_time - start_time))

            # Check if container is still running
            local status
            status=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || status="removed"

            if [ "$status" != "running" ]; then
                log_info "Container finished (status: $status) after ${elapsed}s"
                # Get exit code
                exit_code=$(docker inspect "$name" --format '{{.State.ExitCode}}' 2>/dev/null) || exit_code=1

                # Premature exit detection (Issue #610)
                if [ $elapsed -lt 30 ] && [ $exit_code -eq 0 ]; then
                    log_warn "Container exited prematurely (${elapsed}s runtime, exit code 0)"
                    log_info "This may indicate a transient failure - capturing diagnostics..."

                    if [ -x "${SCRIPT_DIR}/container-diagnostic-capture.sh" ]; then
                        "${SCRIPT_DIR}/container-diagnostic-capture.sh" \
                            --container "$name" \
                            --auto-restart \
                            --log-lines 100 \
                            ${DEBUG:+--debug} || true

                        # Check if container was restarted
                        status=$(docker inspect "$name" --format '{{.State.Status}}' 2>/dev/null) || status="exited"
                        if [ "$status" = "running" ]; then
                            log_info "Container auto-restarted, resuming monitoring..."
                            # Reset timers
                            start_time=$(date +%s)
                            last_activity_time=$start_time
                            continue
                        fi
                    fi
                elif [ $exit_code -ne 0 ]; then
                    # Capture diagnostics for failed container
                    log_error "Container failed with exit code $exit_code"
                    if [ -x "${SCRIPT_DIR}/container-diagnostic-capture.sh" ]; then
                        "${SCRIPT_DIR}/container-diagnostic-capture.sh" \
                            --container "$name" \
                            --log-lines 100 \
                            ${DEBUG:+--debug} || true
                    fi
                fi

                break
            fi

            # Check for timeout
            if [ $elapsed -ge "$timeout_secs" ]; then
                log_error "Container timed out after ${timeout_secs} seconds"
                docker stop "$name" 2>/dev/null || docker kill "$name" 2>/dev/null || true
                exit_code=124
                break
            fi

            # Check for heartbeat (new log output)
            local last_log_time
            last_log_time=$(docker logs --tail 1 --timestamps "$name" 2>/dev/null | cut -d' ' -f1 | head -1)
            if [ -n "$last_log_time" ]; then
                # Parse timestamp and check if recent
                local log_epoch
                log_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_log_time%%.*}" +%s 2>/dev/null) || log_epoch=$last_activity_time
                if [ "$log_epoch" -gt "$last_activity_time" ]; then
                    last_activity_time=$log_epoch
                    log_debug "Heartbeat detected at ${last_log_time}"
                fi
            fi

            # Check heartbeat timeout
            no_activity_time=$((current_time - last_activity_time))
            if [ $no_activity_time -ge "$heartbeat_timeout" ]; then
                log_error "Container appears hung (no activity for ${no_activity_time}s)"
                docker stop "$name" 2>/dev/null || docker kill "$name" 2>/dev/null || true
                exit_code=125  # Custom code for hung container
                break
            fi

            log_debug "Polling: elapsed=${elapsed}s, no_activity=${no_activity_time}s"
        done

        # Capture final logs
        log_info "=== Container Output ==="
        docker logs "$name" 2>&1 || true
        log_info "=== End Container Output ==="
    fi

    if [ $exit_code -eq 0 ]; then
        log_info "Container completed successfully"
    elif [ $exit_code -eq 124 ]; then
        log_error "Container timed out"
    elif [ $exit_code -eq 125 ]; then
        log_error "Container detected as hung"
    else
        log_error "Container exited with code $exit_code"
    fi

    return $exit_code
}

# Execute container in interactive mode (foreground)
# Returns: container exit code
_execute_interactive() {
    local name="$1"
    local issue="$2"
    local image="$3"
    local timeout="$4"
    local tokens_present="$5"
    shift 5
    local docker_args=("$@")

    # Track start time for duration calculation
    if [ "$AUDIT_ENABLED" = "true" ]; then
        start_duration_timer
        ISSUE="$issue" CONTAINER_ID="$name" \
            audit_container_start "$image" "$tokens_present" "detached=false"
    fi

    # Run interactively - trap to handle cleanup and audit stop
    trap '_handle_container_exit "$?" "$name" "$issue"' EXIT

    # Apply timeout if specified for non-autonomous mode
    if [ "$timeout" != "$DEFAULT_TIMEOUT" ] && [ "$timeout" -gt 0 ] 2>/dev/null; then
        log_info "Container timeout: ${timeout}s"
        timeout "$timeout" docker "${docker_args[@]}" || {
            local tc=$?
            if [ $tc -eq 124 ]; then
                log_error "Container timed out after ${timeout} seconds"
            fi
            exit $tc
        }
    else
        docker "${docker_args[@]}"
    fi
}

# Launch container for an issue
# Refactored from monolithic 498-line function into smaller focused functions
launch_container() {
    local issue="$1"
    local repo="$2"
    local branch="${3:-}"
    # Detect default branch dynamically if not specified
    if [ -z "$branch" ]; then
        branch=$(detect_default_branch "$repo")
        log_info "Detected default branch: $branch"
    fi
    local cmd="$4"
    local image="${5:-$DEFAULT_IMAGE}"
    local detach="${6:-false}"
    local no_tty="${7:-false}"
    local skip_preflight="${8:-false}"
    local force="${9:-false}"
    local epic="${10:-}"
    local epic_context_b64="${11:-}"
    local autonomous="${12:-false}"
    local timeout_secs="${13:-$DEFAULT_TIMEOUT}"
    local exec_mode="${14:-simple}"
    local poll_interval="${15:-30}"
    local heartbeat_timeout="${16:-300}"

    local name
    name=$(container_name "$issue")

    log_info "Launching container '$name' for issue #$issue"

    # Check if already running
    if is_container_running "$name"; then
        log_error "Container '$name' is already running"
        log_error "Stop it first with: $SCRIPT_NAME --stop $issue"
        return 1
    fi

    # Run capacity check
    _check_container_capacity "$skip_preflight" "$force" || return 1

    # Validate inputs
    if [ -z "$repo" ]; then
        log_error "--repo is required when launching a container"
        return 1
    fi

    # Validate tokens first (required for preflight and launch)
    validate_tokens || return 1

    # Run preflight validation
    local preflight_result
    preflight_result=$(_run_preflight_validation "$issue" "$epic" "$skip_preflight" "$force") || {
        log_error "Preflight checks failed. Use --force to override."
        return 1
    }

    # Extract epic context from preflight if available
    if [ -n "$preflight_result" ] && [ -z "$epic_context_b64" ]; then
        local epic_ctx
        epic_ctx=$(echo "$preflight_result" | jq -c '.epic_context // {}')
        if [ -n "$epic_ctx" ] && [ "$epic_ctx" != "{}" ] && [ "$epic_ctx" != "null" ]; then
            epic_context_b64=$(echo "$epic_ctx" | base64 | tr -d '\n')
            epic=$(echo "$preflight_result" | jq -r '.epic_number // empty')
        fi
    fi

    # Check Docker and image
    check_docker || return 1
    check_image "$image" || return 1

    # Generate sprint state on host (reduces API calls inside container)
    local sprint_state_b64
    sprint_state_b64=$(generate_sprint_state "$issue" "$repo" "$branch")

    # Build docker run command arguments
    local repo_url="https://github.com/${repo}.git"
    local docker_args
    _setup_docker_args "$name" "$repo_url" "$repo" "$branch" "$batch_branch" "$issue" "$image" \
        "$sprint_state_b64" "$epic" "$epic_context_b64" "$role" "$interactive_mode" "$detach" "$no_tty" "$cmd"

    # Determine if tokens are present (for audit logging)
    local tokens_present="false"
    if [ -n "$CLAUDE_CODE_OAUTH_TOKEN" ] || [ -n "$ANTHROPIC_API_KEY" ]; then
        tokens_present="true"
    fi

    # Execute container based on mode
    if [ "$detach" = "true" ]; then
        # Detached mode: fire and forget
        local container_id
        container_id=$(docker "${docker_args[@]}")
        log_info "Container started: $container_id"
        log_info "View logs: docker logs -f $name"
        log_info "Get result: ./scripts/container-result.sh $issue"
        log_info "Stop: $SCRIPT_NAME --stop $issue"

        # Audit log: container start
        if [ "$AUDIT_ENABLED" = "true" ]; then
            ISSUE="$issue" CONTAINER_ID="${container_id:0:12}" \
                audit_container_start "$image" "$tokens_present" "detached=true"
        fi

        # Premature exit detection (Issue #610)
        sleep 10
        local status
        status=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null || echo "unknown")

        if [ "$status" != "running" ]; then
            local exit_code
            exit_code=$(docker inspect --format '{{.State.ExitCode}}' "$name" 2>/dev/null || echo "1")
            log_error "Container exited prematurely (runtime < 10s, exit code: $exit_code)"
            log_error "Capturing diagnostic logs..."

            if [ -x "${SCRIPT_DIR}/container-diagnostic-capture.sh" ]; then
                "${SCRIPT_DIR}/container-diagnostic-capture.sh" \
                    --container "$name" \
                    --log-lines 100 \
                    ${DEBUG:+--debug} || true
            else
                docker logs --tail 100 "$name" 2>&1 || true
            fi
        fi
    elif [ "$autonomous" = "true" ]; then
        # Autonomous mode: run with timeout and monitoring
        _execute_autonomous "$name" "$issue" "$image" "$timeout_secs" "$exec_mode" \
            "$poll_interval" "$heartbeat_timeout" "$tokens_present" "${docker_args[@]}"
        return $?
    else
        # Interactive mode: foreground execution
        _execute_interactive "$name" "$issue" "$image" "$timeout" "$tokens_present" "${docker_args[@]}"
    fi
}

# Handle container exit for audit logging
_handle_container_exit() {
    local exit_code="$1"
    local name="$2"
    local issue="$3"

    log_info "Container stopped"

    if [ "$AUDIT_ENABLED" = "true" ]; then
        local duration
        duration=$(get_duration)
        ISSUE="$issue" CONTAINER_ID="$name" \
            audit_container_stop "$exit_code" "$duration"
    fi
}

# Launch container for epic mode (shows child selection or launches specific child)
launch_epic_container() {
    local epic="$1"
    local child="$2"
    local repo="$3"
    local branch="${4:-}"
    # Detect default branch dynamically if not specified
    if [ -z "$branch" ]; then
        branch=$(detect_default_branch "$repo")
        log_info "Detected default branch: $branch"
    fi
    local cmd="$5"
    local image="${6:-$DEFAULT_IMAGE}"
    local detach="${7:-false}"
    local no_tty="${8:-false}"
    local skip_preflight="${9:-false}"
    local force="${10:-false}"
    local autonomous="${11:-false}"
    local timeout_secs="${12:-$DEFAULT_TIMEOUT}"
    local exec_mode="${13:-simple}"
    local poll_interval="${14:-30}"
    local heartbeat_timeout="${15:-300}"

    log_info "Epic mode: working on epic #$epic"

    # Validate inputs
    if [ -z "$repo" ]; then
        log_error "--repo is required when launching an epic container"
        return 1
    fi

    # Get epic children info
    local epic_script="${SCRIPT_DIR}/detect-epic-children.sh"
    if [ ! -x "$epic_script" ]; then
        log_error "detect-epic-children.sh not found"
        return 1
    fi

    # Check for last-check timestamp file
    local epic_check_file="${SCRIPT_DIR}/../.epic-${epic}-check"
    local epic_args=("$epic")
    if [ -f "$epic_check_file" ]; then
        epic_args+=("--since-file" "$epic_check_file")
    fi

    local epic_data
    epic_data=$("$epic_script" "${epic_args[@]}" 2>/dev/null)

    if [ -z "$epic_data" ]; then
        log_error "Failed to get epic data for #$epic"
        return 1
    fi

    # Check if it's actually an epic
    local is_epic
    is_epic=$(echo "$epic_data" | jq -r '.is_epic')
    if [ "$is_epic" != "true" ]; then
        log_error "Issue #$epic is not an epic (missing 'epic' label)"
        return 1
    fi

    # Display epic status
    local epic_title total_children open_children closed_children percent_complete new_children
    epic_title=$(echo "$epic_data" | jq -r '.epic_title')
    total_children=$(echo "$epic_data" | jq -r '.children.total')
    open_children=$(echo "$epic_data" | jq -r '.children.open')
    closed_children=$(echo "$epic_data" | jq -r '.children.closed')
    percent_complete=$(echo "$epic_data" | jq -r '.children.percent_complete')
    new_children=$(echo "$epic_data" | jq -r '.children.new_since_check')

    echo ""
    echo -e "${BLUE}=== Epic #$epic: $epic_title ===${NC}"
    echo -e "Progress: ${GREEN}$closed_children/$total_children${NC} children closed (${percent_complete}%)"

    if [ "$new_children" -gt 0 ]; then
        echo -e "${YELLOW}! $new_children new child issue(s) since last check${NC}"
    fi
    echo ""

    # If specific child provided, launch it
    if [ -n "$child" ]; then
        log_info "Launching container for child issue #$child"

        # Encode epic context for injection
        local epic_context_b64
        epic_context_b64=$(echo "$epic_data" | base64 | tr -d '\n')

        launch_container "$child" "$repo" "$branch" "$cmd" "$image" "$detach" "$no_tty" "$skip_preflight" "$force" "$epic" "$epic_context_b64" "$autonomous" "$timeout_secs" "$exec_mode" "$poll_interval" "$heartbeat_timeout"
        return $?
    fi

    # No specific child - show selection menu
    local open_issues
    open_issues=$(echo "$epic_data" | jq -r '.children.items | map(select(.state == "OPEN")) | sort_by(.number)')

    if [ -z "$open_issues" ] || [ "$open_issues" = "[]" ]; then
        log_info "All children are closed! Epic is complete."
        return 0
    fi

    # Display open children with priority info
    echo "Open children:"
    echo ""
    printf "  %-6s %-10s %-10s %s\n" "#" "Priority" "Type" "Title"
    printf "  %-6s %-10s %-10s %s\n" "---" "--------" "----" "-----"

    echo "$open_issues" | jq -r '.[] |
        (.labels | map(select(startswith("P"))) | .[0] // "P3") as $prio |
        (.labels | map(select(. == "bug" or . == "feature" or . == "tech-debt" or . == "docs")) | .[0] // "other") as $type |
        "  \(.number | tostring | .[0:6])   \($prio | .[0:10])   \($type | .[0:10])   \(.title | .[0:50])"
    '

    echo ""

    # Prompt for selection
    read -r -p "Enter issue number to work on (or 'q' to quit): " selection

    if [ "$selection" = "q" ] || [ -z "$selection" ]; then
        log_info "Cancelled"
        return 0
    fi

    # Validate selection is in open children
    local valid
    valid=$(echo "$open_issues" | jq -r --arg sel "$selection" '.[] | select(.number == ($sel | tonumber)) | .number')

    if [ -z "$valid" ]; then
        log_error "Invalid selection: #$selection is not an open child of this epic"
        return 1
    fi

    log_info "Launching container for child issue #$selection"

    # Encode epic context for injection
    local epic_context_b64
    epic_context_b64=$(echo "$epic_data" | base64 | tr -d '\n')

    launch_container "$selection" "$repo" "$branch" "$cmd" "$image" "$detach" "$no_tty" "$skip_preflight" "$force" "$epic" "$epic_context_b64" "$autonomous" "$timeout_secs" "$exec_mode" "$poll_interval" "$heartbeat_timeout"
}

# List running containers
list_containers() {
    log_info "Running claude-tastic containers:"
    echo ""

    local containers
    containers=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}\t{{.Status}}\t{{.Image}}')

    if [ -z "$containers" ]; then
        echo "  No containers running"
        return 0
    fi

    printf "  %-30s %-30s %s\n" "NAME" "STATUS" "IMAGE"
    printf "  %-30s %-30s %s\n" "----" "------" "-----"

    while IFS=$'\t' read -r name status image; do
        printf "  %-30s %-30s %s\n" "$name" "$status" "$image"
    done <<< "$containers"
}

# Stop container for an issue
stop_container() {
    local issue="$1"
    local name
    name=$(container_name "$issue")

    if ! is_container_running "$name"; then
        log_warn "Container '$name' is not running"
        return 0
    fi

    log_info "Stopping container '$name'..."

    local exit_code=0
    if docker stop "$name" &> /dev/null; then
        log_info "Container '$name' stopped successfully"
    else
        log_error "Failed to stop container '$name'"
        log_warn "Attempting force kill..."
        docker kill "$name" 2>/dev/null || true
        exit_code=137  # Killed
    fi

    # Audit log: container stop (from host-initiated stop)
    if [ "$AUDIT_ENABLED" = "true" ]; then
        ISSUE="$issue" CONTAINER_ID="$name" \
            audit_container_stop "$exit_code" "host-initiated"
    fi
}

# Cleanup all containers
cleanup_all() {
    log_info "Stopping all claude-tastic containers..."

    local containers
    containers=$(docker ps --filter "name=${CONTAINER_PREFIX}" --format '{{.Names}}')

    if [ -z "$containers" ]; then
        log_info "No containers to cleanup"
        return 0
    fi

    local count=0
    while IFS= read -r name; do
        log_info "Stopping $name..."
        docker stop "$name" &> /dev/null || docker kill "$name" 2>/dev/null || true
        ((count++))
    done <<< "$containers"

    log_info "Stopped $count container(s)"

    # Check for any orphaned containers (exited but not removed)
    local orphans
    orphans=$(docker ps -a --filter "name=${CONTAINER_PREFIX}" --filter "status=exited" --format '{{.Names}}')

    if [ -n "$orphans" ]; then
        log_warn "Found orphaned containers, removing..."
        while IFS= read -r name; do
            docker rm "$name" 2>/dev/null || true
        done <<< "$orphans"
    fi
}

# Parse command-line arguments
# Sets global variables for action, issue, repo, etc.
parse_arguments() {
    # Initialize all variables as globals (used by execute_action)
    action=""
    issue=""
    epic=""
    child=""
    repo=""
    branch=""  # Detected dynamically from repo's default branch if not specified
    batch_branch=""  # Optional batch branch for parallel execution
    cmd=""
    image="$DEFAULT_IMAGE"
    detach="false"
    sync_mode="false"  # Explicit sync/foreground flag
    no_tty="false"
    interactive_mode="false"  # Human-supervised mode with permission prompts
    skip_preflight="false"
    force="false"
    role=""  # Container role (orchestrator, implementation, code_review, etc.)
    # Remote SSH options (optional - local Docker is default)
    remote_mode="false"
    remote_host="${REMOTE_DOCKER_HOST:-docker-workers}"
    remote_key="${REMOTE_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_bootstrap}"
    remote_user="${REMOTE_SSH_USER:-ubuntu}"
    remote_env_file="${REMOTE_ENV_FILE:-/opt/apps/claude-workers/.env}"
    fallback_local="false"
    # Cloud options (optional - local Docker is default)
    cloud_provider=""
    cloud_project=""
    cloud_region="us-central1"
    cloud_memory="2Gi"
    cloud_cpu="2"
    cloud_timeout="3600"
    # Autonomous mode options (for unattended execution)
    autonomous="false"
    timeout="$DEFAULT_TIMEOUT"
    auto_tokens="false"
    sprint_work_mode="false"
    exec_mode="simple"  # simple or complex
    poll_interval="30"
    heartbeat_timeout="300"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                action="launch"
                issue="$2"
                shift 2
                ;;
            --epic)
                action="epic"
                epic="$2"
                shift 2
                ;;
            --child)
                child="$2"
                shift 2
                ;;
            --repo)
                repo="$2"
                shift 2
                ;;
            --branch)
                branch="$2"
                shift 2
                ;;
            --batch-branch)
                batch_branch="$2"
                shift 2
                ;;
            --cmd)
                cmd="$2"
                shift 2
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            --detach)
                detach="true"
                shift
                ;;
            --sync|--foreground)
                sync_mode="true"
                shift
                ;;
            --no-tty)
                no_tty="true"
                shift
                ;;
            --interactive)
                # Human-supervised mode: allocates TTY, enables permission prompts
                interactive_mode="true"
                no_tty="false"  # Need TTY for interactive prompts
                detach="false"  # Must run in foreground
                shift
                ;;
            --skip-preflight)
                skip_preflight="true"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            --no-monitor)
                export ISSUE_MONITOR_ENABLED="false"
                shift
                ;;
            --monitor-interval)
                export ISSUE_MONITOR_INTERVAL="$2"
                shift 2
                ;;
            --role)
                role="$2"
                shift 2
                ;;
            --remote)
                remote_mode="true"
                # Optional: --remote <host> allows specifying host inline
                if [ -n "${2:-}" ] && [[ ! "$2" =~ ^-- ]]; then
                    remote_host="$2"
                    shift 2
                else
                    shift
                fi
                ;;
            --remote-host)
                remote_host="$2"
                shift 2
                ;;
            --remote-key)
                remote_key="$2"
                shift 2
                ;;
            --remote-user)
                remote_user="$2"
                shift 2
                ;;
            --remote-env)
                remote_env_file="$2"
                shift 2
                ;;
            --fallback-local)
                fallback_local="true"
                shift
                ;;
            --check-capacity)
                # Handled in action routing below
                action="check_capacity"
                shift
                ;;
            --cloud)
                cloud_provider="$2"
                shift 2
                ;;
            --project)
                cloud_project="$2"
                shift 2
                ;;
            --region)
                cloud_region="$2"
                shift 2
                ;;
            --memory)
                cloud_memory="$2"
                shift 2
                ;;
            --cpu)
                cloud_cpu="$2"
                shift 2
                ;;
            --cloud-timeout)
                cloud_timeout="$2"
                shift 2
                ;;
            --autonomous)
                autonomous="true"
                no_tty="true"  # Autonomous mode implies no TTY
                shift
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --auto-tokens)
                auto_tokens="true"
                shift
                ;;
            --sprint-work)
                # Shorthand for common sprint-work autonomous execution
                # Runs detached by default (use --sync to override)
                sprint_work_mode="true"
                autonomous="false"  # Detach mode is default
                detach="true"      # Default to detached for sprint-work
                auto_tokens="true"
                no_tty="true"
                shift
                ;;
            --fire-and-forget)
                # Deprecated alias for --sprint-work (same behavior now)
                sprint_work_mode="true"
                autonomous="false"
                detach="true"
                auto_tokens="true"
                no_tty="true"
                shift
                ;;
            --exec-mode)
                exec_mode="$2"
                if [[ "$exec_mode" != "simple" && "$exec_mode" != "complex" ]]; then
                    log_error "Invalid exec-mode: $exec_mode (must be 'simple' or 'complex')"
                    exit 1
                fi
                shift 2
                ;;
            --poll-interval)
                poll_interval="$2"
                shift 2
                ;;
            --heartbeat-timeout)
                heartbeat_timeout="$2"
                shift 2
                ;;
            --list)
                action="list"
                shift
                ;;
            --stop)
                action="stop"
                issue="$2"
                shift 2
                ;;
            --cleanup)
                action="cleanup"
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

    # Handle --sync flag override for --sprint-work
    if [ "$sync_mode" = "true" ]; then
        detach="false"
        autonomous="true"  # Sync mode uses autonomous with blocking execution
        log_info "Synchronous mode: container will run in foreground"
    elif [ "$sprint_work_mode" = "true" ] && [ "$detach" = "true" ]; then
        log_info "Detached mode: container will run in background (default for --sprint-work)"
    fi
}

# Validate required inputs for the specified action
# Returns 0 on success, exits on validation failure
validate_inputs() {
    case "$action" in
        launch)
            if [ -z "$issue" ]; then
                log_error "--issue is required"
                usage
                exit 1
            fi
            ;;
        epic)
            if [ -z "$epic" ]; then
                log_error "--epic is required"
                usage
                exit 1
            fi
            ;;
        stop)
            if [ -z "$issue" ]; then
                log_error "Issue number required for --stop"
                exit 1
            fi
            ;;
        "")
            log_error "No action specified"
            usage
            exit 1
            ;;
    esac
}

# Execute the requested action
# Uses global variables set by parse_arguments
execute_action() {
    case "$action" in
        launch)
            # Auto-load tokens from keychain if requested
            if [ "$auto_tokens" = "true" ]; then
                auto_load_tokens || {
                    log_error "Failed to auto-load tokens"
                    exit 1
                }
            fi

            # Set up sprint-work command if --sprint-work mode
            if [ "$sprint_work_mode" = "true" ]; then
                # Use optimized workflow script instead of piping full /sprint-work to Claude
                # This reduces token usage by ~50-70%:
                # - Before: Claude loads 800-line sprint-work.md and reasons through every step
                # - After: Script handles pre/post-work, Claude only does implementation
                #
                # The workflow script is at /workspace/scripts/container-sprint-workflow.sh
                # after the repo is cloned by the entrypoint
                cmd="./scripts/container-sprint-workflow.sh"
                log_info "Sprint-work mode: using optimized workflow (token-efficient)"
            fi

            # Validate tokens are available
            validate_tokens || exit 1

            # Auto-start n8n if sprint-work mode (runs on HOST before container spawn)
            # n8n is required for PR automation pipeline (#715, #716)
            if [ "$sprint_work_mode" = "true" ]; then
                local n8n_health_script="${SCRIPT_DIR}/../n8n/n8n-health.sh"
                local n8n_start_script="${SCRIPT_DIR}/../n8n/n8n-start.sh"
                local n8n_workflow_health_script="${SCRIPT_DIR}/../n8n/n8n-workflow-health.sh"

                # Check if n8n container is running
                if [ -x "$n8n_health_script" ]; then
                    if ! "$n8n_health_script" --quiet 2>/dev/null; then
                        log_info "n8n not running - auto-starting for PR automation pipeline..."
                        if [ -x "$n8n_start_script" ] && "$n8n_start_script" --wait 2>/dev/null; then
                            log_info "n8n started successfully"
                        else
                            log_warn "n8n auto-start failed - PR automation may not work"
                            log_warn "Start manually: ./scripts/n8n-start.sh"
                        fi
                    fi

                    # Run workflow health check (warn, don't block)
                    # Feature #724: continuous workflow health monitoring
                    if [ -x "$n8n_workflow_health_script" ]; then
                        log_info "Checking n8n workflow health before container spawn..."
                        if ! "$n8n_workflow_health_script" --quiet 2>/dev/null; then
                            log_warn "n8n workflow health check failed - some workflows may be unhealthy"
                            log_warn "Review workflow status: ./scripts/n8n-workflow-health.sh"
                            log_warn "Continuing container launch anyway..."
                        else
                            log_info "n8n workflows healthy"
                        fi
                    fi
                fi
            fi

            # Check if remote mode specified - delegate to remote launcher
            if [ "$remote_mode" = "true" ]; then
                log_info "Remote mode: delegating to remote-container-launch.sh (host: ${remote_host})"
                local remote_script="${SCRIPT_DIR}/remote-container-launch.sh"
                if [ ! -x "$remote_script" ]; then
                    log_error "remote-container-launch.sh not found or not executable"
                    log_error "Remote support requires remote-container-launch.sh"
                    exit 1
                fi
                local remote_args=(
                    --issue "$issue"
                    --repo "$repo"
                    --branch "$branch"
                    --image "$image"
                    --host "$remote_host"
                    --ssh-key "$remote_key"
                    --ssh-user "$remote_user"
                    --env-file "$remote_env_file"
                    --timeout "$timeout"
                )
                [ -n "$cmd" ] && remote_args+=(--cmd "$cmd")
                [ "$sprint_work_mode" = "true" ] && remote_args+=(--sprint-work)
                [ "$force" = "true" ] && remote_args+=(--force)
                [ "$fallback_local" = "true" ] && remote_args+=(--fallback-local)
                [ "$skip_preflight" = "true" ] && remote_args+=(--skip-capacity-check)
                [ -n "${DEBUG:-}" ] && remote_args+=(--debug)
                exec "$remote_script" "${remote_args[@]}"
            fi
            # Check if cloud provider specified - delegate to cloud launcher
            if [ -n "$cloud_provider" ]; then
                log_info "Cloud mode: delegating to cloud-container-launch.sh"
                local cloud_script="${SCRIPT_DIR}/cloud-container-launch.sh"
                if [ ! -x "$cloud_script" ]; then
                    log_error "cloud-container-launch.sh not found or not executable"
                    log_error "Cloud support requires cloud-container-launch.sh"
                    exit 1
                fi
                exec "$cloud_script" \
                    --provider "$cloud_provider" \
                    --issue "$issue" \
                    --repo "$repo" \
                    --branch "$branch" \
                    --image "$image" \
                    --project "$cloud_project" \
                    --region "$cloud_region" \
                    --memory "$cloud_memory" \
                    --cpu "$cloud_cpu" \
                    --timeout "$cloud_timeout" \
                    ${DEBUG:+--debug}
            fi
            # Default: local Docker
            launch_container "$issue" "$repo" "$branch" "$cmd" "$image" "$detach" "$no_tty" "$skip_preflight" "$force" "" "" "$autonomous" "$timeout" "$exec_mode" "$poll_interval" "$heartbeat_timeout"
            ;;
        epic)
            # Cloud mode for epics - delegate to cloud launcher
            if [ -n "$cloud_provider" ]; then
                log_info "Cloud mode: delegating to cloud-container-launch.sh"
                local cloud_script="${SCRIPT_DIR}/cloud-container-launch.sh"
                if [ ! -x "$cloud_script" ]; then
                    log_error "cloud-container-launch.sh not found or not executable"
                    exit 1
                fi
                # For epic mode, require --child to be specified for cloud
                if [ -z "$child" ]; then
                    log_error "Cloud mode for epics requires --child <N> to specify which child to work on"
                    log_error "Interactive epic selection is only available with local Docker"
                    exit 1
                fi
                exec "$cloud_script" \
                    --provider "$cloud_provider" \
                    --issue "$child" \
                    --repo "$repo" \
                    --branch "$branch" \
                    --image "$image" \
                    --project "$cloud_project" \
                    --region "$cloud_region" \
                    --memory "$cloud_memory" \
                    --cpu "$cloud_cpu" \
                    --timeout "$cloud_timeout" \
                    ${DEBUG:+--debug}
            fi
            # Default: local Docker with interactive selection
            launch_epic_container "$epic" "$child" "$repo" "$branch" "$cmd" "$image" "$detach" "$no_tty" "$skip_preflight" "$force" "$autonomous" "$timeout" "$exec_mode" "$poll_interval" "$heartbeat_timeout"
            ;;
        list)
            # For remote, delegate to remote script
            if [ "$remote_mode" = "true" ]; then
                local remote_script="${SCRIPT_DIR}/remote-container-launch.sh"
                if [ -x "$remote_script" ]; then
                    exec "$remote_script" --list \
                        --host "$remote_host" \
                        --ssh-key "$remote_key" \
                        --ssh-user "$remote_user"
                fi
            fi
            # For cloud, delegate to cloud script
            if [ -n "$cloud_provider" ]; then
                local cloud_script="${SCRIPT_DIR}/cloud-container-launch.sh"
                if [ -x "$cloud_script" ]; then
                    exec "$cloud_script" --provider "$cloud_provider" --list --project "$cloud_project" --region "$cloud_region"
                fi
            fi
            list_containers
            ;;
        stop)
            # For remote, delegate to remote script
            if [ "$remote_mode" = "true" ]; then
                local remote_script="${SCRIPT_DIR}/remote-container-launch.sh"
                if [ -x "$remote_script" ]; then
                    exec "$remote_script" --stop "$issue" \
                        --host "$remote_host" \
                        --ssh-key "$remote_key" \
                        --ssh-user "$remote_user"
                fi
            fi
            # For cloud, delegate to cloud script
            if [ -n "$cloud_provider" ]; then
                local cloud_script="${SCRIPT_DIR}/cloud-container-launch.sh"
                if [ -x "$cloud_script" ]; then
                    exec "$cloud_script" --provider "$cloud_provider" --stop "${CONTAINER_PREFIX}-${issue}" --project "$cloud_project" --region "$cloud_region"
                fi
            fi
            stop_container "$issue"
            ;;
        check_capacity)
            # Check remote capacity if remote mode
            if [ "$remote_mode" = "true" ]; then
                local remote_script="${SCRIPT_DIR}/remote-container-launch.sh"
                if [ -x "$remote_script" ]; then
                    exec "$remote_script" --check-capacity \
                        --host "$remote_host" \
                        --ssh-key "$remote_key" \
                        --ssh-user "$remote_user"
                fi
            fi
            # For local capacity check
            local capacity_script="${SCRIPT_DIR}/check-container-capacity.sh"
            if [ -x "$capacity_script" ]; then
                exec "$capacity_script" --verbose
            fi
            log_error "Capacity check script not found"
            exit 1
            ;;
        cleanup)
            cleanup_all
            ;;
        *)
            log_error "No action specified"
            usage
            exit 1
            ;;
    esac
}

# Main function - orchestrates argument parsing, validation, and action execution
# Refactored from monolithic 493-line function into three focused phases
main() {
    parse_arguments "$@"
    validate_inputs
    # Detect default branch dynamically if not explicitly set via --branch
    if [ -z "$branch" ] && [ -n "$repo" ]; then
        branch=$(detect_default_branch "$repo")
        log_info "Detected default branch: $branch"
    elif [ -z "$branch" ]; then
        branch="main"
    fi
    execute_action
}

# Run main with all arguments
main "$@"
