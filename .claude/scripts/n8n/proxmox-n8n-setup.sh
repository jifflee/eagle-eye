#!/bin/bash
set -euo pipefail
# proxmox-n8n-setup.sh
# Configure n8n on Proxmox to integrate with remote docker-workers containers
# Issue #819: Integrate n8n webhooks with remote Proxmox containers
#
# This script:
#   1. Configures n8n environment variables for Proxmox networking
#   2. Imports the Proxmox-specific n8n workflows
#   3. Sets up SSH connectivity to docker-workers
#   4. Configures container→n8n webhook callbacks
#   5. Validates the full integration setup
#
# Usage:
#   ./scripts/proxmox-n8n-setup.sh [OPTIONS]
#
# Options:
#   --n8n-host <ip>         n8n VM IP (default: 10.69.5.20)
#   --docker-workers-ip <ip> docker-workers IP (default: 10.69.5.11)
#   --obs-ip <ip>           Observability VM IP (default: 10.69.5.10)
#   --ssh-key <path>        SSH key for docker-workers (default: ~/.ssh/id_ed25519_proxmox_bootstrap)
#   --ssh-user <user>       SSH user for docker-workers (default: ubuntu)
#   --n8n-port <port>       n8n port (default: 5678)
#   --import-workflows      Import Proxmox n8n workflows
#   --validate              Validate setup without making changes
#   --dry-run               Show what would be done without executing
#   --debug                 Enable debug output
#   --help                  Show this help

set -e

# Script metadata
SCRIPT_NAME="proxmox-n8n-setup.sh"
VERSION="1.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source common utilities if available
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*"; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_debug() { [ "${DEBUG:-0}" = "1" ] && echo "[DEBUG] $*" || true; }
fi

# Default configuration
N8N_HOST="${N8N_HOST:-10.69.5.20}"
DOCKER_WORKERS_IP="${DOCKER_WORKERS_IP:-10.69.5.11}"
OBS_IP="${OBS_IP:-10.69.5.10}"
SSH_KEY="${PROXMOX_SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_bootstrap}"
SSH_USER="${REMOTE_SSH_USER:-ubuntu}"
N8N_PORT="${N8N_PORT:-5678}"
IMPORT_WORKFLOWS="false"
VALIDATE_ONLY="false"
DRY_RUN="false"

# Proxmox-specific workflow files
PROXMOX_WORKFLOWS=(
    "proxmox-remote-container-trigger.json"
    "proxmox-container-status-receiver.json"
)

usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Configure n8n on Proxmox for remote container integration

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --n8n-host <ip>              n8n VM IP address (default: $N8N_HOST)
    --docker-workers-ip <ip>     docker-workers VM IP (default: $DOCKER_WORKERS_IP)
    --obs-ip <ip>                Observability VM IP for Grafana/Loki (default: $OBS_IP)
    --ssh-key <path>             SSH key for docker-workers (default: $SSH_KEY)
    --ssh-user <user>            SSH user for docker-workers (default: $SSH_USER)
    --n8n-port <port>            n8n listening port (default: $N8N_PORT)
    --import-workflows           Import Proxmox n8n workflows after configuration
    --validate                   Validate setup without making changes
    --dry-run                    Show what would be done without executing
    --debug                      Enable debug logging
    --help                       Show this help

ENVIRONMENT VARIABLES:
    N8N_HOST                     Override n8n VM IP
    DOCKER_WORKERS_IP            Override docker-workers IP
    PROXMOX_SSH_KEY              Override SSH key path
    REMOTE_SSH_USER              Override SSH user

EXAMPLES:
    # Full setup with workflow import
    $SCRIPT_NAME --import-workflows

    # Validate existing setup
    $SCRIPT_NAME --validate

    # Configure with custom IPs
    $SCRIPT_NAME --n8n-host 10.69.5.20 --docker-workers-ip 10.69.5.11

    # Dry run to preview changes
    $SCRIPT_NAME --dry-run --import-workflows

WHAT THIS CONFIGURES:
    1. n8n environment: WEBHOOK_URL pointing to Proxmox n8n VM IP
    2. Container env: N8N_PROXMOX_URL for callbacks from docker-workers containers
    3. SSH access: Verifies n8n can SSH to docker-workers for container launches
    4. Proxmox workflows: Imports trigger and status-receiver workflows
    5. WEBHOOK_URL in /opt/apps/claude-workers/.env on docker-workers

EOF
}

# Check SSH connectivity to docker-workers
check_ssh_to_docker_workers() {
    log_info "Checking SSH connectivity to docker-workers (${SSH_USER}@${DOCKER_WORKERS_IP})..."

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would test: ssh -i ${SSH_KEY} ${SSH_USER}@${DOCKER_WORKERS_IP} 'docker info'"
        return 0
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log_warn "SSH key not found: ${SSH_KEY}"
        log_warn "Container launching from n8n will fail without SSH access"
        return 1
    fi

    if ssh -i "${SSH_KEY}" \
           -o StrictHostKeyChecking=no \
           -o ConnectTimeout=10 \
           -o BatchMode=yes \
           "${SSH_USER}@${DOCKER_WORKERS_IP}" \
           "docker info > /dev/null 2>&1" 2>/dev/null; then
        log_info "✓ SSH to docker-workers confirmed"
        return 0
    else
        log_warn "✗ Cannot SSH to docker-workers at ${DOCKER_WORKERS_IP}"
        log_warn "Container launching from n8n will not work"
        log_warn "Check: ssh -i ${SSH_KEY} ${SSH_USER}@${DOCKER_WORKERS_IP}"
        return 1
    fi
}

# Configure WEBHOOK_URL on docker-workers so containers call back to Proxmox n8n
configure_webhook_url_on_workers() {
    local webhook_url="http://${N8N_HOST}:${N8N_PORT}"
    log_info "Configuring WEBHOOK_URL on docker-workers to point to Proxmox n8n..."
    log_info "  WEBHOOK_URL=${webhook_url}"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would update /opt/apps/claude-workers/.env on ${DOCKER_WORKERS_IP}"
        log_info "[DRY-RUN] Would set WEBHOOK_URL=${webhook_url}"
        log_info "[DRY-RUN] Would set N8N_PROXMOX_URL=${webhook_url}"
        return 0
    fi

    if [ ! -f "$SSH_KEY" ]; then
        log_warn "SSH key not found, skipping remote configuration"
        return 1
    fi

    local env_file="/opt/apps/claude-workers/.env"
    local ssh_cmd="ssh -i ${SSH_KEY} -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${SSH_USER}@${DOCKER_WORKERS_IP}"

    # Check if env file exists
    if ! $ssh_cmd "test -f '${env_file}'" 2>/dev/null; then
        log_warn "Environment file not found on docker-workers: ${env_file}"
        log_warn "Creating with webhook configuration..."
        $ssh_cmd "sudo mkdir -p /opt/apps/claude-workers && sudo touch '${env_file}' && sudo chmod 640 '${env_file}'" 2>/dev/null || true
    fi

    # Update or add WEBHOOK_URL
    $ssh_cmd "
        set -e
        ENV_FILE='${env_file}'
        WEBHOOK_URL='${webhook_url}'
        N8N_PROXMOX_URL='${webhook_url}'

        # Update WEBHOOK_URL if it exists, otherwise append
        if grep -q '^WEBHOOK_URL=' \"\$ENV_FILE\" 2>/dev/null; then
            sudo sed -i \"s|^WEBHOOK_URL=.*|WEBHOOK_URL=\${WEBHOOK_URL}|\" \"\$ENV_FILE\"
        else
            echo \"WEBHOOK_URL=\${WEBHOOK_URL}\" | sudo tee -a \"\$ENV_FILE\" > /dev/null
        fi

        # Update or add N8N_PROXMOX_URL
        if grep -q '^N8N_PROXMOX_URL=' \"\$ENV_FILE\" 2>/dev/null; then
            sudo sed -i \"s|^N8N_PROXMOX_URL=.*|N8N_PROXMOX_URL=\${N8N_PROXMOX_URL}|\" \"\$ENV_FILE\"
        else
            echo \"N8N_PROXMOX_URL=\${N8N_PROXMOX_URL}\" | sudo tee -a \"\$ENV_FILE\" > /dev/null
        fi

        echo 'WEBHOOK_URL and N8N_PROXMOX_URL configured on docker-workers'
    " 2>&1 | while IFS= read -r line; do
        log_info "  docker-workers: ${line}"
    done

    log_info "✓ WEBHOOK_URL configured on docker-workers: ${webhook_url}"
}

# Import Proxmox-specific n8n workflows
import_proxmox_workflows() {
    log_info "Importing Proxmox n8n workflows..."

    local n8n_workflows_dir="${REPO_ROOT}/n8n-workflows"
    local import_script="${SCRIPT_DIR}/n8n-import-workflows.sh"

    if [ ! -x "$import_script" ]; then
        log_warn "n8n-import-workflows.sh not found or not executable"
        log_warn "Import workflows manually: n8n import:workflow --input=<workflow.json>"
        return 1
    fi

    local imported=0
    local failed=0

    for workflow_file in "${PROXMOX_WORKFLOWS[@]}"; do
        local full_path="${n8n_workflows_dir}/${workflow_file}"

        if [ ! -f "$full_path" ]; then
            log_warn "Workflow file not found: ${full_path}"
            failed=$((failed + 1))
            continue
        fi

        if [ "$DRY_RUN" = "true" ]; then
            log_info "[DRY-RUN] Would import: ${workflow_file}"
            imported=$((imported + 1))
            continue
        fi

        log_info "Importing: ${workflow_file}"
        if "$import_script" --file "$full_path" 2>/dev/null; then
            log_info "✓ Imported: ${workflow_file}"
            imported=$((imported + 1))
        else
            log_warn "✗ Failed to import: ${workflow_file}"
            failed=$((failed + 1))
        fi
    done

    log_info "Workflow import: ${imported} succeeded, ${failed} failed"
    [ "$failed" -eq 0 ] && return 0 || return 1
}

# Check n8n health on Proxmox
check_n8n_health() {
    local n8n_url="http://localhost:${N8N_PORT}"
    log_info "Checking n8n health at ${n8n_url}..."

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would check: ${n8n_url}/healthz"
        return 0
    fi

    if curl -sf --max-time 5 "${n8n_url}/healthz" > /dev/null 2>&1; then
        log_info "✓ n8n is healthy at ${n8n_url}"
        return 0
    else
        log_warn "✗ n8n not reachable at ${n8n_url}"
        log_warn "Start n8n with: ./scripts/n8n-start.sh"
        return 1
    fi
}

# Configure n8n environment for Proxmox
configure_n8n_env() {
    log_info "Configuring n8n environment for Proxmox integration..."

    # Check for n8n config location
    local n8n_env_file=""
    local candidates=(
        "/opt/apps/n8n/.env"
        "${REPO_ROOT}/.env.n8n"
        "${HOME}/.n8n/.env"
    )

    for candidate in "${candidates[@]}"; do
        if [ -f "$candidate" ]; then
            n8n_env_file="$candidate"
            break
        fi
    done

    if [ -z "$n8n_env_file" ]; then
        log_warn "No n8n .env file found. Proxmox-specific settings may need manual configuration."
        log_warn "Expected locations: ${candidates[*]}"
        return 0
    fi

    log_info "Found n8n config: ${n8n_env_file}"

    local webhook_url="http://${N8N_HOST}:${N8N_PORT}"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY-RUN] Would set in ${n8n_env_file}:"
        log_info "[DRY-RUN]   WEBHOOK_URL=${webhook_url}"
        log_info "[DRY-RUN]   DOCKER_WORKERS_IP=${DOCKER_WORKERS_IP}"
        log_info "[DRY-RUN]   PROXMOX_SSH_KEY=${SSH_KEY}"
        return 0
    fi

    # Update or add WEBHOOK_URL in n8n config
    if grep -q '^WEBHOOK_URL=' "$n8n_env_file" 2>/dev/null; then
        sed -i "s|^WEBHOOK_URL=.*|WEBHOOK_URL=${webhook_url}|" "$n8n_env_file"
    else
        echo "WEBHOOK_URL=${webhook_url}" >> "$n8n_env_file"
    fi

    # Add Proxmox-specific variables if not present
    local vars=(
        "DOCKER_WORKERS_IP=${DOCKER_WORKERS_IP}"
        "PROXMOX_SSH_KEY=${SSH_KEY}"
        "REMOTE_SSH_USER=${SSH_USER}"
    )

    for var in "${vars[@]}"; do
        local key="${var%%=*}"
        if ! grep -q "^${key}=" "$n8n_env_file" 2>/dev/null; then
            echo "${var}" >> "$n8n_env_file"
        fi
    done

    log_info "✓ n8n environment configured"
}

# Validate the full integration setup
validate_setup() {
    log_info "Validating Proxmox n8n integration setup..."
    echo ""

    local passed=0
    local failed=0
    local warnings=0

    # Check 1: SSH to docker-workers
    echo "=== SSH Connectivity ==="
    if check_ssh_to_docker_workers; then
        passed=$((passed + 1))
    else
        warnings=$((warnings + 1))
    fi
    echo ""

    # Check 2: n8n health
    echo "=== n8n Health ==="
    if check_n8n_health; then
        passed=$((passed + 1))
    else
        warnings=$((warnings + 1))
    fi
    echo ""

    # Check 3: Proxmox workflow files exist
    echo "=== Proxmox Workflow Files ==="
    for workflow_file in "${PROXMOX_WORKFLOWS[@]}"; do
        local full_path="${REPO_ROOT}/n8n-workflows/${workflow_file}"
        if [ -f "$full_path" ]; then
            log_info "✓ Found: ${workflow_file}"
            passed=$((passed + 1))
        else
            log_error "✗ Missing: ${workflow_file}"
            failed=$((failed + 1))
        fi
    done
    echo ""

    # Check 4: container-proxmox-webhook.sh exists
    echo "=== Container Webhook Script ==="
    local webhook_script="${SCRIPT_DIR}/container-proxmox-webhook.sh"
    if [ -f "$webhook_script" ] && [ -x "$webhook_script" ]; then
        log_info "✓ container-proxmox-webhook.sh is executable"
        passed=$((passed + 1))
    elif [ -f "$webhook_script" ]; then
        log_warn "⚠ container-proxmox-webhook.sh exists but is not executable"
        warnings=$((warnings + 1))
    else
        log_error "✗ container-proxmox-webhook.sh not found"
        failed=$((failed + 1))
    fi
    echo ""

    # Check 5: SSH key exists
    echo "=== SSH Key ==="
    if [ -f "$SSH_KEY" ]; then
        log_info "✓ SSH key found: ${SSH_KEY}"
        passed=$((passed + 1))
    else
        log_warn "⚠ SSH key not found: ${SSH_KEY}"
        warnings=$((warnings + 1))
    fi
    echo ""

    # Summary
    echo "=== Validation Summary ==="
    echo "  Passed:   ${passed}"
    echo "  Warnings: ${warnings}"
    echo "  Failed:   ${failed}"
    echo ""

    if [ "$failed" -gt 0 ]; then
        log_error "Validation FAILED (${failed} critical issue(s))"
        return 1
    elif [ "$warnings" -gt 0 ]; then
        log_warn "Validation passed with ${warnings} warning(s)"
        return 0
    else
        log_info "✓ All validation checks passed"
        return 0
    fi
}

# Print summary of what was configured
print_summary() {
    cat << EOF

=== Proxmox n8n Integration Summary ===

Configuration:
  n8n VM IP:         ${N8N_HOST}
  docker-workers IP: ${DOCKER_WORKERS_IP}
  Observability IP:  ${OBS_IP}
  n8n Port:          ${N8N_PORT}
  SSH Key:           ${SSH_KEY}
  SSH User:          ${SSH_USER}

Webhook URLs (n8n on Proxmox):
  Container Trigger:  http://${N8N_HOST}:${N8N_PORT}/webhook/proxmox-container-trigger
  Status Callback:    http://${N8N_HOST}:${N8N_PORT}/webhook/container-status
  Heartbeat:          http://${N8N_HOST}:${N8N_PORT}/webhook/container-heartbeat
  Completion:         http://${N8N_HOST}:${N8N_PORT}/webhook/container-complete

Proxmox Workflows:
  - proxmox-remote-container-trigger.json
  - proxmox-container-status-receiver.json

Container Callback Script:
  scripts/container-proxmox-webhook.sh

Next Steps:
  1. Activate workflows in n8n UI: http://${N8N_HOST}:${N8N_PORT}
  2. Test container launch: curl -X POST http://${N8N_HOST}:${N8N_PORT}/webhook/proxmox-container-trigger \\
       -H 'Content-Type: application/json' \\
       -d '{"issue": 1, "repo": "owner/repo"}'
  3. Monitor in Grafana: http://${OBS_IP}:3000

EOF
}

# Main function
main() {
    local do_validate="false"
    local do_import="false"

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --n8n-host)
                N8N_HOST="$2"
                shift 2
                ;;
            --docker-workers-ip)
                DOCKER_WORKERS_IP="$2"
                shift 2
                ;;
            --obs-ip)
                OBS_IP="$2"
                shift 2
                ;;
            --ssh-key)
                SSH_KEY="$2"
                shift 2
                ;;
            --ssh-user)
                SSH_USER="$2"
                shift 2
                ;;
            --n8n-port)
                N8N_PORT="$2"
                shift 2
                ;;
            --import-workflows)
                do_import="true"
                shift
                ;;
            --validate)
                do_validate="true"
                shift
                ;;
            --dry-run)
                DRY_RUN="true"
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

    log_info "=== Proxmox n8n Integration Setup v${VERSION} ==="
    [ "$DRY_RUN" = "true" ] && log_warn "DRY-RUN mode: no changes will be made"
    echo ""

    if [ "$do_validate" = "true" ]; then
        validate_setup
        exit $?
    fi

    # Run setup steps
    local exit_code=0

    # Step 1: Configure n8n environment
    configure_n8n_env || true

    # Step 2: Check SSH connectivity and configure docker-workers
    if check_ssh_to_docker_workers; then
        configure_webhook_url_on_workers || {
            log_warn "Failed to configure WEBHOOK_URL on docker-workers"
            exit_code=1
        }
    else
        log_warn "Skipping docker-workers configuration (SSH unavailable)"
        exit_code=1
    fi

    # Step 3: Import workflows if requested
    if [ "$do_import" = "true" ]; then
        import_proxmox_workflows || {
            log_warn "Workflow import had failures (check logs above)"
            exit_code=1
        }
    fi

    # Step 4: Validate the full setup
    echo ""
    validate_setup || exit_code=$?

    # Print summary
    print_summary

    if [ $exit_code -eq 0 ]; then
        log_info "✓ Proxmox n8n integration setup completed successfully"
    else
        log_warn "Setup completed with warnings/errors. Review output above."
    fi

    return $exit_code
}

# Run main with all arguments
main "$@"
