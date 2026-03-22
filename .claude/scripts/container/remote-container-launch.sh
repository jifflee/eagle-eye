#!/bin/bash
set -euo pipefail
# remote-container-launch.sh
# Launch sprint-work containers on remote Docker hosts via SSH
# Supports docker-workers (10.69.5.11) and other Proxmox VMs
# SECURITY: Tokens loaded from Ansible Vault secrets on remote host
# size-ok: remote Docker execution via SSH with capacity checking and fallback

set -e

# Script metadata
SCRIPT_NAME="remote-container-launch.sh"
VERSION="1.0.0"
DEFAULT_IMAGE="claude-dev-env:latest"
DEFAULT_TIMEOUT="1800"  # 30 minutes default

# Remote host defaults
DEFAULT_REMOTE_HOST="docker-workers"
DEFAULT_REMOTE_IP="10.69.5.11"
DEFAULT_SSH_KEY="$HOME/.ssh/id_ed25519_proxmox_bootstrap"
DEFAULT_SSH_USER="ubuntu"
REMOTE_ENV_FILE="/opt/apps/claude-workers/.env"

# Remote capacity limits (docker-workers: 4 cores, 8GB RAM)
REMOTE_MAX_CONTAINERS=3

# Get script directory for sourcing utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/framework-config.sh"

# Usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Launch containers on remote Docker host via SSH

USAGE:
    $SCRIPT_NAME --issue <N> --repo <owner/repo> [OPTIONS]
    $SCRIPT_NAME --list
    $SCRIPT_NAME --stop <N>
    $SCRIPT_NAME --cleanup
    $SCRIPT_NAME --check-capacity
    $SCRIPT_NAME --build-image

COMMANDS:
    --issue <N>         Launch container for issue number N on remote host
    --list              List running containers on remote host
    --stop <N>          Stop container for issue N on remote host
    --cleanup           Stop all claude-tastic containers on remote host
    --check-capacity    Check remote host capacity without launching
    --build-image       Build claude-dev-env image on remote host

OPTIONS:
    --repo <owner/repo>     Repository to clone (required with --issue)
    --branch <branch>       Branch to checkout (default: dev)
    --cmd <command>         Command to execute (default: sprint-work workflow)
    --image <image>         Docker image to use (default: $DEFAULT_IMAGE)
    --host <host>           Remote host (default: $DEFAULT_REMOTE_HOST)
    --host-ip <ip>          Remote host IP (default: $DEFAULT_REMOTE_IP)
    --ssh-key <path>        SSH key path (default: $DEFAULT_SSH_KEY)
    --ssh-user <user>       SSH username (default: $DEFAULT_SSH_USER)
    --timeout <sec>         Container timeout in seconds (default: $DEFAULT_TIMEOUT)
    --env-file <path>       Remote env file with tokens (default: $REMOTE_ENV_FILE)
    --fallback-local        Fall back to local Docker if SSH fails
    --no-fallback           Fail immediately if SSH fails (default: no fallback)
    --sprint-work           Shorthand for sprint-work autonomous execution
    --detach                Run container in background (default)
    --sync                  Run container synchronously (foreground)
    --force                 Force launch despite capacity warnings
    --skip-capacity-check   Skip remote capacity check
    --debug                 Enable debug logging

ENVIRONMENT VARIABLES:
    REMOTE_DOCKER_HOST      Override default remote host
    REMOTE_SSH_KEY          Override default SSH key path
    REMOTE_SSH_USER         Override default SSH user
    REMOTE_ENV_FILE         Override default remote env file path

EXAMPLES:
    # Launch sprint-work container on docker-workers (default)
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work

    # Launch on specific remote host
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --host myhost

    # List containers on remote host
    $SCRIPT_NAME --list

    # Check remote capacity before launching
    $SCRIPT_NAME --check-capacity

    # Build image on remote host
    $SCRIPT_NAME --build-image

    # Launch with local fallback if SSH fails
    $SCRIPT_NAME --issue 107 --repo owner/repo --sprint-work --fallback-local

REMOTE SETUP:
    The remote host must have:
    1. Docker installed and running
    2. SSH access via key: $DEFAULT_SSH_KEY
    3. Tokens at: $REMOTE_ENV_FILE
       Format: GITHUB_TOKEN=... and CLAUDE_CODE_OAUTH_TOKEN=...
    4. claude-dev-env Docker image built (or use --build-image)

    To set up tokens on remote host (via Ansible Vault):
    ansible-playbook playbooks/deploy-claude-tokens.yml

SECURITY:
    - SSH key authentication only (no passwords)
    - Tokens sourced from /opt/apps/claude-workers/.env on remote host
    - macOS Keychain NOT used on remote Linux hosts
    - Container isolation enforced on remote host same as local
EOF
}

# Build SSH command prefix for remote execution
build_ssh_cmd() {
    local host="${1:-$remote_host}"
    local ssh_key="${2:-$ssh_key_path}"
    local ssh_user="${3:-$ssh_user}"

    echo "ssh -i ${ssh_key} -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes ${ssh_user}@${host}"
}

# Test SSH connectivity to remote host
check_ssh_connectivity() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"

    log_info "Testing SSH connectivity to ${ssh_user}@${host}..."

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    if $ssh_cmd "docker info > /dev/null 2>&1" 2>/dev/null; then
        log_info "SSH connectivity confirmed - Docker available on remote host"
        return 0
    else
        log_error "SSH connection failed or Docker not available on ${host}"
        log_error "SSH key: ${ssh_key}"
        log_error "Check: ssh -i ${ssh_key} ${ssh_user}@${host} 'docker info'"
        return 1
    fi
}

# Check if remote env file exists and has required tokens
check_remote_tokens() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"
    local env_file="${4:-$REMOTE_ENV_FILE}"

    log_info "Checking remote token file: ${env_file}"

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    # Check file exists
    if ! $ssh_cmd "test -f '${env_file}'" 2>/dev/null; then
        log_error "Remote env file not found: ${env_file}"
        log_error "Set up tokens on remote host with Ansible:"
        log_error "  ansible-playbook playbooks/deploy-claude-tokens.yml"
        return 1
    fi

    # Check for required tokens (without revealing values)
    local has_github
    has_github=$($ssh_cmd "grep -c '^GITHUB_TOKEN=' '${env_file}' 2>/dev/null || echo 0")
    local has_claude
    has_claude=$($ssh_cmd "grep -c '^CLAUDE_CODE_OAUTH_TOKEN=\|^ANTHROPIC_API_KEY=' '${env_file}' 2>/dev/null || echo 0")

    if [ "$has_github" -eq 0 ]; then
        log_error "GITHUB_TOKEN not found in ${env_file}"
        return 1
    fi

    if [ "$has_claude" -eq 0 ]; then
        log_warn "Neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY found in ${env_file}"
        log_warn "Claude Code features may be limited"
    fi

    log_info "Remote tokens verified"
    return 0
}

# Check remote Docker image availability
check_remote_image() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"
    local image="${4:-$DEFAULT_IMAGE}"

    log_info "Checking if image '${image}' exists on ${host}..."

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    if $ssh_cmd "docker image inspect '${image}' > /dev/null 2>&1" 2>/dev/null; then
        log_info "Image '${image}' found on remote host"
        return 0
    else
        log_warn "Image '${image}' NOT found on remote host"
        log_warn "Build it with: $SCRIPT_NAME --build-image"
        return 1
    fi
}

# Check remote container capacity
# docker-workers: 4 cores, 8GB RAM - max 3 concurrent containers
check_remote_capacity() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"
    local max_containers="${4:-$REMOTE_MAX_CONTAINERS}"

    log_info "Checking remote capacity on ${host}..."

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    # Count running containers with our prefix
    local running_count
    running_count=$($ssh_cmd "docker ps --filter 'name=${CONTAINER_PREFIX}' --format '{{.Names}}' 2>/dev/null | wc -l | tr -d ' '" 2>/dev/null || echo "0")

    # Get CPU and memory usage
    local cpu_usage mem_usage mem_total
    cpu_usage=$($ssh_cmd "top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1 || echo '0'" 2>/dev/null || echo "0")
    mem_usage=$($ssh_cmd "free -m 2>/dev/null | awk '/^Mem:/{printf \"%.0f\", (\$3/\$2)*100}' || echo '0'" 2>/dev/null || echo "0")
    mem_total=$($ssh_cmd "free -m 2>/dev/null | awk '/^Mem:/{print \$2}' || echo '8192'" 2>/dev/null || echo "8192")

    log_debug "Remote status: ${running_count} containers, CPU: ${cpu_usage}%, Mem: ${mem_usage}%"

    # Check container count limit
    if [ "$running_count" -ge "$max_containers" ]; then
        log_error "Remote capacity FULL: ${running_count}/${max_containers} containers running"
        jq -cn \
            --arg host "$host" \
            --argjson running "$running_count" \
            --argjson max "$max_containers" \
            --arg cpu_usage "$cpu_usage" \
            --arg mem_usage "$mem_usage" \
            '{
                has_capacity: false,
                reason: "Max containers reached (\(. as $r | $running)/\($max))",
                remote_host: $host,
                running_containers: $running,
                max_containers: $max,
                resources: {
                    cpu_usage_pct: ($cpu_usage | tonumber),
                    memory_usage_pct: ($mem_usage | tonumber)
                }
            }'
        return 1
    fi

    # Check CPU (warn at 75%)
    local cpu_int
    cpu_int=$(echo "$cpu_usage" | cut -d'.' -f1)
    if [ "${cpu_int:-0}" -gt 75 ]; then
        log_warn "Remote CPU usage high: ${cpu_usage}%"
    fi

    # Check memory (warn at 80%)
    if [ "${mem_usage:-0}" -gt 80 ]; then
        log_warn "Remote memory usage high: ${mem_usage}%"
    fi

    jq -cn \
        --arg host "$host" \
        --argjson running "$running_count" \
        --argjson max "$max_containers" \
        --arg cpu_usage "${cpu_usage:-0}" \
        --arg mem_usage "${mem_usage:-0}" \
        --argjson mem_total "${mem_total:-8192}" \
        '{
            has_capacity: true,
            reason: "Remote capacity available (\($running)/\($max) containers)",
            remote_host: $host,
            running_containers: $running,
            max_containers: $max,
            resources: {
                cpu_usage_pct: ($cpu_usage | tonumber),
                memory_usage_pct: ($mem_usage | tonumber),
                memory_total_mb: $mem_total
            }
        }'
    return 0
}

# Build claude-dev-env image on remote host
build_remote_image() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"
    local image="${4:-$DEFAULT_IMAGE}"

    log_info "Building '${image}' on remote host ${host}..."

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    # Check if docker/Dockerfile.sprint-worker exists on remote
    if ! $ssh_cmd "test -f /opt/apps/claude-workers/docker/Dockerfile.sprint-worker" 2>/dev/null; then
        log_warn "docker/Dockerfile.sprint-worker not found on remote host"
        log_info "Attempting to copy Dockerfile from local host..."

        # Copy Dockerfile to remote
        local dockerfile_path="${SCRIPT_DIR}/../docker/Dockerfile.sprint-worker"
        if [ -f "$dockerfile_path" ]; then
            scp -i "$ssh_key" -o StrictHostKeyChecking=no \
                "$dockerfile_path" \
                "${ssh_user}@${host}:/opt/apps/claude-workers/docker/Dockerfile.sprint-worker" 2>/dev/null || {
                log_error "Failed to copy Dockerfile to remote host"
                log_error "Manually copy with: scp -i ${ssh_key} docker/Dockerfile.sprint-worker ${ssh_user}@${host}:/opt/apps/claude-workers/"
                return 1
            }
            log_info "Dockerfile copied to remote host"
        else
            log_error "docker/Dockerfile.sprint-worker not found locally either"
            log_error "Please ensure docker/Dockerfile.sprint-worker exists in repo root"
            return 1
        fi
    fi

    # Build image on remote host
    log_info "Starting image build on ${host} (this may take several minutes)..."
    $ssh_cmd "cd /opt/apps/claude-workers && docker build -f docker/Dockerfile.sprint-worker -t '${image}' . 2>&1" || {
        log_error "Image build failed on remote host"
        return 1
    }

    log_info "Image '${image}' built successfully on ${host}"
    return 0
}

# Generate container name
container_name() {
    local issue="$1"
    echo "${CONTAINER_PREFIX}-${issue}"
}

# Check if container is running on remote host
is_remote_container_running() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"
    local name="$4"

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    $ssh_cmd "docker ps --filter 'name=^${name}$' --format '{{.Names}}' 2>/dev/null | grep -q '^${name}$'" 2>/dev/null
}

# Launch container on remote host via SSH
launch_remote_container() {
    local issue="$1"
    local repo="$2"
    local branch="${3:-dev}"
    local cmd="$4"
    local image="${5:-$DEFAULT_IMAGE}"
    local detach="${6:-true}"
    local host="$7"
    local ssh_key="$8"
    local ssh_user="$9"
    local env_file="${10:-$REMOTE_ENV_FILE}"
    local timeout_secs="${11:-$DEFAULT_TIMEOUT}"
    local force="${12:-false}"
    local skip_capacity="${13:-false}"

    local name
    name=$(container_name "$issue")

    log_info "Launching remote container '${name}' on ${host} for issue #${issue}"

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    # Check if already running
    if is_remote_container_running "$host" "$ssh_key" "$ssh_user" "$name"; then
        log_error "Container '${name}' is already running on ${host}"
        log_error "Stop it first: $SCRIPT_NAME --stop ${issue}"
        return 1
    fi

    # Capacity check
    if [ "$skip_capacity" != "true" ] && [ "$force" != "true" ]; then
        local capacity_json
        capacity_json=$(check_remote_capacity "$host" "$ssh_key" "$ssh_user" "$REMOTE_MAX_CONTAINERS") || {
            log_error "Remote capacity check failed"
            return 1
        }

        local has_capacity
        has_capacity=$(echo "$capacity_json" | jq -r '.has_capacity')
        if [ "$has_capacity" != "true" ]; then
            local reason
            reason=$(echo "$capacity_json" | jq -r '.reason')
            log_error "Remote capacity FULL: ${reason}"
            log_error "Use --force to override (not recommended)"
            return 1
        fi
        local capacity_reason
        capacity_reason=$(echo "$capacity_json" | jq -r '.reason')
        log_info "✓ Remote capacity OK: ${capacity_reason}"
    elif [ "$force" = "true" ]; then
        log_warn "Force flag set, skipping capacity check"
    fi

    # Verify image exists
    if ! check_remote_image "$host" "$ssh_key" "$ssh_user" "$image"; then
        log_error "Image not available on remote host"
        log_error "Build it first: $SCRIPT_NAME --build-image"
        return 1
    fi

    # Set default command for sprint-work
    if [ -z "$cmd" ]; then
        cmd="./scripts/container-sprint-workflow.sh"
    fi

    local repo_url="https://github.com/${repo}.git"

    # Build the docker run command to execute on remote
    # Tokens are sourced from env file on remote host
    # SECURITY: env-file on remote host, not passed over SSH
    local docker_run_script
    docker_run_script=$(cat << REMOTE_SCRIPT
#!/bin/bash
set -e

# Source tokens from Ansible Vault secrets
if [ -f '${env_file}' ]; then
    set -a
    source '${env_file}'
    set +a
else
    echo "ERROR: Token file not found: ${env_file}" >&2
    exit 1
fi

# Ensure shared network exists
docker network inspect n8n-shared >/dev/null 2>&1 || docker network create n8n-shared 2>/dev/null || true

# Launch the container
docker run \\
    --name '${name}' \\
    --network n8n-shared \\
    --cap-drop ALL \\
    --security-opt no-new-privileges:true \\
    --read-only \\
    --tmpfs /tmp:rw,noexec,nosuid,size=100m \\
    --tmpfs /home/claude:rw,exec,mode=1777,size=512m \\
    --tmpfs /root:rw,exec,size=100m \\
    --tmpfs /workspace:rw,exec,mode=1777,size=1g \\
    --memory 2g \\
    --cpus 2 \\
    --pids-limit 256 \\
    -e GITHUB_TOKEN \\
    -e CLAUDE_CODE_OAUTH_TOKEN \\
    -e ANTHROPIC_API_KEY \\
    -e REPO_URL='${repo_url}' \\
    -e REPO_FULL_NAME='${repo}' \\
    -e BRANCH='${branch}' \\
    -e ISSUE='${issue}' \\
    -e HOME=/home/claude \\
    -e CLAUDE_DEBUG=0 \\
    -e ISSUE_MONITOR_ENABLED=true \\
    -e ISSUE_MONITOR_INTERVAL=60 \\
    -e PHASE_TIMEOUT=600 \\
    -e TOTAL_TIMEOUT=3600 \\
    -e HEARTBEAT_MAX_AGE=120 \\
    -e WATCHDOG_CHECK_INTERVAL=10 \\
    -d \\
    '${image}' \\
    bash -c '${cmd}'

echo "Container ${name} launched on remote host"
REMOTE_SCRIPT
)

    # Execute on remote host
    log_info "Executing docker run on ${host}..."
    local launch_result
    if launch_result=$(echo "$docker_run_script" | $ssh_cmd "bash -s" 2>&1); then
        log_info "Remote container launched successfully"
        log_info "Container ID / output: ${launch_result}"
        log_info ""
        log_info "Remote management commands:"
        log_info "  View logs:    ssh -i ${ssh_key} ${ssh_user}@${host} 'docker logs -f ${name}'"
        log_info "  Status:       $SCRIPT_NAME --list"
        log_info "  Get result:   $SCRIPT_NAME --result ${issue}"
        log_info "  Stop:         $SCRIPT_NAME --stop ${issue}"

        # Detached: wait briefly and verify it's still running
        if [ "$detach" = "true" ]; then
            sleep 5
            local status
            if is_remote_container_running "$host" "$ssh_key" "$ssh_user" "$name"; then
                log_info "✓ Container confirmed running on ${host}"
            else
                log_error "Container exited prematurely on remote host"
                log_error "Check logs: ssh -i ${ssh_key} ${ssh_user}@${host} 'docker logs ${name}'"
                return 1
            fi
        fi
        return 0
    else
        log_error "Failed to launch container on remote host"
        log_error "SSH output: ${launch_result}"
        return 1
    fi
}

# List containers on remote host
list_remote_containers() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"

    log_info "Running containers on ${host}:"
    echo ""

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    local containers
    containers=$($ssh_cmd "docker ps -a --filter 'name=${CONTAINER_PREFIX}' --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null" 2>/dev/null || echo "")

    if [ -z "$containers" ]; then
        echo "  No containers found on ${host}"
        return 0
    fi

    printf "  %-30s %-30s %s\n" "NAME" "STATUS" "IMAGE"
    printf "  %-30s %-30s %s\n" "----" "------" "-----"

    while IFS=$'\t' read -r name status image; do
        printf "  %-30s %-30s %s\n" "$name" "$status" "$image"
    done <<< "$containers"

    echo ""
    echo "  Host: ${ssh_user}@${host}"
}

# Stop container on remote host
stop_remote_container() {
    local issue="$1"
    local host="$2"
    local ssh_key="$3"
    local ssh_user="$4"

    local name
    name=$(container_name "$issue")

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    log_info "Stopping remote container '${name}' on ${host}..."

    if ! is_remote_container_running "$host" "$ssh_key" "$ssh_user" "$name"; then
        log_warn "Container '${name}' is not running on ${host}"
        return 0
    fi

    if $ssh_cmd "docker stop '${name}'" 2>/dev/null; then
        log_info "Container '${name}' stopped on ${host}"
    else
        log_warn "docker stop failed, trying docker kill..."
        $ssh_cmd "docker kill '${name}'" 2>/dev/null || true
    fi
}

# Cleanup all containers on remote host
cleanup_remote_containers() {
    local host="$1"
    local ssh_key="$2"
    local ssh_user="$3"

    log_info "Stopping all claude-tastic containers on ${host}..."

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    local containers
    containers=$($ssh_cmd "docker ps --filter 'name=${CONTAINER_PREFIX}' --format '{{.Names}}' 2>/dev/null" 2>/dev/null || echo "")

    if [ -z "$containers" ]; then
        log_info "No running containers on ${host}"
        return 0
    fi

    local count=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        log_info "Stopping ${name}..."
        $ssh_cmd "docker stop '${name}' 2>/dev/null || docker kill '${name}' 2>/dev/null || true" 2>/dev/null || true
        count=$((count + 1))
    done <<< "$containers"

    log_info "Stopped ${count} container(s) on ${host}"

    # Remove exited containers
    local orphans
    orphans=$($ssh_cmd "docker ps -a --filter 'name=${CONTAINER_PREFIX}' --filter 'status=exited' --format '{{.Names}}' 2>/dev/null" 2>/dev/null || echo "")
    if [ -n "$orphans" ]; then
        log_info "Removing exited containers..."
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            $ssh_cmd "docker rm '${name}' 2>/dev/null || true" 2>/dev/null || true
        done <<< "$orphans"
    fi
}

# Get result from remote container
get_remote_result() {
    local issue="$1"
    local host="$2"
    local ssh_key="$3"
    local ssh_user="$4"

    local name
    name=$(container_name "$issue")

    local ssh_cmd
    ssh_cmd=$(build_ssh_cmd "$host" "$ssh_key" "$ssh_user")

    # Check if container exists
    if ! $ssh_cmd "docker ps -a --filter 'name=^${name}$' --format '{{.Names}}' 2>/dev/null | grep -q '^${name}$'" 2>/dev/null; then
        echo "{\"status\":\"not_found\",\"issue\":${issue},\"host\":\"${host}\"}"
        return 1
    fi

    # Get status
    local status exit_code
    status=$($ssh_cmd "docker inspect '${name}' --format '{{.State.Status}}' 2>/dev/null || echo 'unknown'" 2>/dev/null)
    exit_code=$($ssh_cmd "docker inspect '${name}' --format '{{.State.ExitCode}}' 2>/dev/null || echo '-1'" 2>/dev/null)

    if [ "$status" = "running" ]; then
        echo "{\"status\":\"running\",\"issue\":${issue},\"host\":\"${host}\"}"
        return 0
    fi

    # Extract sprint result from logs
    local result
    result=$($ssh_cmd "docker logs '${name}' 2>&1 | grep '^SPRINT_RESULT=' | tail -1 | cut -d'=' -f2-" 2>/dev/null || echo "")

    if [ -n "$result" ]; then
        echo "$result"
    else
        echo "{\"status\":\"completed\",\"issue\":${issue},\"exit_code\":${exit_code},\"host\":\"${host}\",\"message\":\"No structured result found\"}"
    fi
}

# Main function
main() {
    local action=""
    local issue=""
    local repo=""
    local branch="dev"
    local cmd=""
    local image="$DEFAULT_IMAGE"
    local detach="true"
    local force="false"
    local skip_capacity="false"
    local sprint_work_mode="false"
    local fallback_local="false"
    local timeout="$DEFAULT_TIMEOUT"

    # Remote connection settings (configurable via env or args)
    local remote_host="${REMOTE_DOCKER_HOST:-$DEFAULT_REMOTE_HOST}"
    local ssh_key_path="${REMOTE_SSH_KEY:-$DEFAULT_SSH_KEY}"
    local ssh_user="${REMOTE_SSH_USER:-$DEFAULT_SSH_USER}"
    local env_file="${REMOTE_ENV_FILE:-/opt/apps/claude-workers/.env}"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --issue)
                action="launch"
                issue="$2"
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
            --cmd)
                cmd="$2"
                shift 2
                ;;
            --image)
                image="$2"
                shift 2
                ;;
            --host)
                remote_host="$2"
                shift 2
                ;;
            --host-ip)
                # Allow IP override (updates host to use IP directly)
                remote_host="$2"
                shift 2
                ;;
            --ssh-key)
                ssh_key_path="$2"
                shift 2
                ;;
            --ssh-user)
                ssh_user="$2"
                shift 2
                ;;
            --env-file)
                env_file="$2"
                shift 2
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --detach)
                detach="true"
                shift
                ;;
            --sync)
                detach="false"
                shift
                ;;
            --force)
                force="true"
                shift
                ;;
            --skip-capacity-check)
                skip_capacity="true"
                shift
                ;;
            --sprint-work)
                sprint_work_mode="true"
                detach="true"
                shift
                ;;
            --fallback-local)
                fallback_local="true"
                shift
                ;;
            --no-fallback)
                fallback_local="false"
                shift
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
            --check-capacity)
                action="check_capacity"
                shift
                ;;
            --build-image)
                action="build_image"
                shift
                ;;
            --result)
                action="result"
                issue="$2"
                shift 2
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

    # Validate SSH key exists
    if [ ! -f "$ssh_key_path" ]; then
        log_error "SSH key not found: ${ssh_key_path}"
        log_error "Create or specify with: --ssh-key <path>"
        exit 1
    fi

    # Set sprint-work command if mode enabled
    if [ "$sprint_work_mode" = "true" ] && [ -z "$cmd" ]; then
        cmd="./scripts/container-sprint-workflow.sh"
        log_info "Sprint-work mode: using optimized workflow"
    fi

    # Execute action
    case "$action" in
        launch)
            if [ -z "$issue" ] || [ -z "$repo" ]; then
                log_error "--issue and --repo are required"
                usage
                exit 1
            fi

            # Test SSH connectivity first
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user"; then
                # Auto-escalate SSH/host-unreachable blocker to infra repo (feature #1338)
                local escalate_script="${SCRIPT_DIR}/../infra/auto-escalate-infra.sh"
                if [ -x "$escalate_script" ] && [ -n "${issue:-}" ]; then
                    log_info "Escalating SSH connectivity blocker to infra repo..."
                    "$escalate_script" \
                        --issue "$issue" \
                        --error "SSH connection failed to Proxmox/docker-workers host: ${remote_host} (${ssh_user}@${remote_host}, key: ${ssh_key_path})" \
                        --context "Remote host: ${remote_host}\nSSH user: ${ssh_user}\nSSH key: ${ssh_key_path}\nIssue: #${issue}" \
                        --threshold medium \
                        2>/dev/null || true
                fi

                if [ "$fallback_local" = "true" ]; then
                    log_warn "SSH failed - falling back to local Docker"
                    exec "${SCRIPT_DIR}/container-launch.sh" \
                        --issue "$issue" \
                        --repo "$repo" \
                        --branch "$branch" \
                        ${cmd:+--cmd "$cmd"} \
                        --image "$image" \
                        --sprint-work \
                        ${force:+--force} \
                        ${DEBUG:+--debug}
                else
                    log_error "SSH connection failed. Use --fallback-local to fall back to local Docker."
                    exit 1
                fi
            fi

            # Verify remote tokens
            if ! check_remote_tokens "$remote_host" "$ssh_key_path" "$ssh_user" "$env_file"; then
                log_error "Remote token verification failed"
                exit 1
            fi

            # Launch container
            launch_remote_container \
                "$issue" \
                "$repo" \
                "$branch" \
                "$cmd" \
                "$image" \
                "$detach" \
                "$remote_host" \
                "$ssh_key_path" \
                "$ssh_user" \
                "$env_file" \
                "$timeout" \
                "$force" \
                "$skip_capacity"
            ;;

        list)
            # Test SSH first
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            list_remote_containers "$remote_host" "$ssh_key_path" "$ssh_user"
            ;;

        stop)
            if [ -z "$issue" ]; then
                log_error "--stop requires issue number"
                exit 1
            fi
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            stop_remote_container "$issue" "$remote_host" "$ssh_key_path" "$ssh_user"
            ;;

        cleanup)
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            cleanup_remote_containers "$remote_host" "$ssh_key_path" "$ssh_user"
            ;;

        check_capacity)
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            check_remote_capacity "$remote_host" "$ssh_key_path" "$ssh_user" "$REMOTE_MAX_CONTAINERS"
            ;;

        build_image)
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            build_remote_image "$remote_host" "$ssh_key_path" "$ssh_user" "$image"
            ;;

        result)
            if [ -z "$issue" ]; then
                log_error "--result requires issue number"
                exit 1
            fi
            if ! check_ssh_connectivity "$remote_host" "$ssh_key_path" "$ssh_user" 2>/dev/null; then
                log_error "Cannot connect to ${remote_host}"
                exit 1
            fi
            get_remote_result "$issue" "$remote_host" "$ssh_key_path" "$ssh_user"
            ;;

        *)
            log_error "No action specified"
            usage
            exit 1
            ;;
    esac
}

# Run main with all arguments
main "$@"
