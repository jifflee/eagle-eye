#!/bin/bash
set -euo pipefail
# validate-proxmox-setup.sh
# Validates Proxmox configuration for hosted/remote execution mode
# Used by /repo-init and /repo-init-claudetastic during setup
#
# Usage: ./scripts/validate-proxmox-setup.sh [OPTIONS]
#
# Options:
#   --interactive    Interactive mode with user prompts
#   --update-config  Update repo-profile.yaml with validation results
#   --quiet          Suppress informational output
#   --help           Show this help

set -e

# Script metadata
SCRIPT_NAME="validate-proxmox-setup.sh"
VERSION="1.0.0"

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default configuration from repo-profile.yaml or fallback values
REMOTE_HOST="${REMOTE_HOST:-docker-workers}"
REMOTE_IP="${REMOTE_IP:-10.69.5.11}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519_proxmox_bootstrap}"
SSH_USER="${SSH_USER:-ubuntu}"
REMOTE_ENV_FILE="${REMOTE_ENV_FILE:-/opt/apps/claude-workers/.env}"
N8N_HOST="${N8N_HOST:-10.69.5.20}"
N8N_PORT="${N8N_PORT:-5678}"

# Flags
INTERACTIVE=false
UPDATE_CONFIG=false
QUIET=false

# Validation results
VALIDATION_PASSED=true
SSH_ACCESSIBLE=false
DOCKER_ACCESSIBLE=false
CREDENTIALS_CONFIGURED=false
N8N_ACCESSIBLE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    [ "$QUIET" = "false" ] && echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    [ "$QUIET" = "false" ] && echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

usage() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Validate Proxmox configuration for hosted execution

USAGE:
    $SCRIPT_NAME [OPTIONS]

OPTIONS:
    --interactive       Interactive mode with user prompts
    --update-config     Update repo-profile.yaml with validation results
    --quiet             Suppress informational output
    --help              Show this help

ENVIRONMENT VARIABLES:
    REMOTE_HOST         Remote Docker host name (default: docker-workers)
    REMOTE_IP           Remote Docker host IP (default: 10.69.5.11)
    SSH_KEY             SSH key path (default: ~/.ssh/id_ed25519_proxmox_bootstrap)
    SSH_USER            SSH username (default: ubuntu)
    REMOTE_ENV_FILE     Remote env file path (default: /opt/apps/claude-workers/.env)
    N8N_HOST            n8n host IP (default: 10.69.5.20)
    N8N_PORT            n8n port (default: 5678)

EXAMPLES:
    # Basic validation
    $SCRIPT_NAME

    # Interactive validation with config update
    $SCRIPT_NAME --interactive --update-config

    # Quiet validation (exit code only)
    $SCRIPT_NAME --quiet

EXIT CODES:
    0 - All validations passed
    1 - One or more validations failed
    2 - Invalid usage or configuration error
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --interactive)
            INTERACTIVE=true
            shift
            ;;
        --update-config)
            UPDATE_CONFIG=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 2
            ;;
    esac
done

# Load configuration from repo-profile.yaml if available
if [ -f "$REPO_ROOT/config/repo-profile.yaml" ] && command -v yq &> /dev/null; then
    log_info "Loading configuration from repo-profile.yaml..."
    REMOTE_IP=$(yq eval '.execution_mode.hosted.remote_ip // "10.69.5.11"' "$REPO_ROOT/config/repo-profile.yaml" 2>/dev/null)
    SSH_KEY_FROM_CONFIG=$(yq eval '.execution_mode.hosted.ssh_key // ""' "$REPO_ROOT/config/repo-profile.yaml" 2>/dev/null)
    SSH_USER=$(yq eval '.execution_mode.hosted.ssh_user // "ubuntu"' "$REPO_ROOT/config/repo-profile.yaml" 2>/dev/null)
    REMOTE_ENV_FILE=$(yq eval '.execution_mode.hosted.remote_env_file // "/opt/apps/claude-workers/.env"' "$REPO_ROOT/config/repo-profile.yaml" 2>/dev/null)

    # Expand tilde in SSH key path
    if [ -n "$SSH_KEY_FROM_CONFIG" ]; then
        SSH_KEY="${SSH_KEY_FROM_CONFIG/#\~/$HOME}"
    fi
fi

log_info "Validating Proxmox configuration..."
log_info "Remote host: $REMOTE_HOST ($REMOTE_IP)"
log_info "SSH key: $SSH_KEY"
log_info "SSH user: $SSH_USER"
echo ""

# Validation 1: Check SSH key exists
log_info "[1/5] Checking SSH key..."
if [ -f "$SSH_KEY" ]; then
    log_success "SSH key found: $SSH_KEY"

    # Check permissions
    PERMS=$(stat -f %A "$SSH_KEY" 2>/dev/null || stat -c %a "$SSH_KEY" 2>/dev/null)
    if [ "$PERMS" = "600" ] || [ "$PERMS" = "400" ]; then
        log_success "SSH key permissions correct: $PERMS"
    else
        log_warn "SSH key permissions should be 600 or 400 (currently: $PERMS)"
        if [ "$INTERACTIVE" = "true" ]; then
            read -p "Fix permissions? [y/N]: " fix_perms
            if [[ "$fix_perms" =~ ^[Yy]$ ]]; then
                chmod 600 "$SSH_KEY"
                log_success "Permissions updated to 600"
            fi
        fi
    fi
else
    log_error "SSH key not found: $SSH_KEY"
    VALIDATION_PASSED=false

    if [ "$INTERACTIVE" = "true" ]; then
        echo ""
        echo "To create an SSH key for Proxmox:"
        echo "  ssh-keygen -t ed25519 -f $SSH_KEY -C \"proxmox-bootstrap\""
        echo "  ssh-copy-id -i $SSH_KEY ${SSH_USER}@${REMOTE_IP}"
        echo ""
    fi
fi
echo ""

# Validation 2: Test SSH connectivity
log_info "[2/5] Testing SSH connectivity..."
if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
    "${SSH_USER}@${REMOTE_IP}" "echo success" &>/dev/null; then
    log_success "SSH connection successful"
    SSH_ACCESSIBLE=true
else
    log_error "SSH connection failed to ${SSH_USER}@${REMOTE_IP}"
    VALIDATION_PASSED=false

    if [ "$INTERACTIVE" = "true" ]; then
        echo ""
        echo "Troubleshooting steps:"
        echo "  1. Verify the remote host is accessible: ping $REMOTE_IP"
        echo "  2. Check SSH service is running on remote host"
        echo "  3. Copy SSH key to remote host: ssh-copy-id -i $SSH_KEY ${SSH_USER}@${REMOTE_IP}"
        echo "  4. Test manual connection: ssh -i $SSH_KEY ${SSH_USER}@${REMOTE_IP}"
        echo ""
    fi
fi
echo ""

# Validation 3: Test Docker access
log_info "[3/5] Testing Docker access on remote host..."
if [ "$SSH_ACCESSIBLE" = "true" ]; then
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "${SSH_USER}@${REMOTE_IP}" "docker info &>/dev/null && echo success" 2>/dev/null | grep -q success; then
        log_success "Docker accessible on remote host"
        DOCKER_ACCESSIBLE=true
    else
        log_error "Docker not accessible on remote host"
        VALIDATION_PASSED=false

        if [ "$INTERACTIVE" = "true" ]; then
            echo ""
            echo "Possible issues:"
            echo "  1. Docker not installed: ssh ${SSH_USER}@${REMOTE_IP} 'sudo apt install docker.io'"
            echo "  2. User not in docker group: ssh ${SSH_USER}@${REMOTE_IP} 'sudo usermod -aG docker ${SSH_USER}'"
            echo "  3. Docker service not running: ssh ${SSH_USER}@${REMOTE_IP} 'sudo systemctl start docker'"
            echo ""
        fi
    fi
else
    log_warn "Skipping Docker check (SSH not accessible)"
fi
echo ""

# Validation 4: Check remote environment file
log_info "[4/5] Checking remote environment file..."
if [ "$SSH_ACCESSIBLE" = "true" ]; then
    if ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "${SSH_USER}@${REMOTE_IP}" "[ -f $REMOTE_ENV_FILE ] && echo success" 2>/dev/null | grep -q success; then
        log_success "Remote environment file exists: $REMOTE_ENV_FILE"

        # Check for required environment variables
        MISSING_VARS=""
        for var in GITHUB_TOKEN ANTHROPIC_API_KEY; do
            if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
                "${SSH_USER}@${REMOTE_IP}" "grep -q '^${var}=' $REMOTE_ENV_FILE" 2>/dev/null; then
                MISSING_VARS="${MISSING_VARS}${var} "
            fi
        done

        if [ -z "$MISSING_VARS" ]; then
            log_success "Required environment variables configured"
            CREDENTIALS_CONFIGURED=true
        else
            log_warn "Missing environment variables: $MISSING_VARS"
            CREDENTIALS_CONFIGURED=false

            if [ "$INTERACTIVE" = "true" ]; then
                echo ""
                echo "Configure missing variables in: $REMOTE_ENV_FILE"
                echo "Variables should be managed via Ansible Vault for security."
                echo ""
            fi
        fi
    else
        log_error "Remote environment file not found: $REMOTE_ENV_FILE"
        VALIDATION_PASSED=false

        if [ "$INTERACTIVE" = "true" ]; then
            echo ""
            echo "Create the environment file on the remote host:"
            echo "  ssh ${SSH_USER}@${REMOTE_IP} 'sudo mkdir -p $(dirname $REMOTE_ENV_FILE)'"
            echo "  ssh ${SSH_USER}@${REMOTE_IP} 'sudo touch $REMOTE_ENV_FILE'"
            echo "  ssh ${SSH_USER}@${REMOTE_IP} 'sudo chown ${SSH_USER}:${SSH_USER} $REMOTE_ENV_FILE'"
            echo ""
            echo "Add required variables:"
            echo "  GITHUB_TOKEN=your_token"
            echo "  ANTHROPIC_API_KEY=your_key"
            echo ""
        fi
    fi
else
    log_warn "Skipping environment file check (SSH not accessible)"
fi
echo ""

# Validation 5: Test n8n connectivity (optional)
log_info "[5/5] Testing n8n connectivity (optional)..."
if command -v nc &> /dev/null || command -v netcat &> /dev/null; then
    NC_CMD="nc"
    command -v nc &> /dev/null || NC_CMD="netcat"

    if timeout 2 bash -c "echo > /dev/tcp/${N8N_HOST}/${N8N_PORT}" 2>/dev/null; then
        log_success "n8n accessible at ${N8N_HOST}:${N8N_PORT}"
        N8N_ACCESSIBLE=true
    else
        log_warn "n8n not accessible at ${N8N_HOST}:${N8N_PORT} (optional)"
        N8N_ACCESSIBLE=false
    fi
else
    log_info "Skipping n8n check (nc/netcat not available)"
fi
echo ""

# Summary
echo "=========================================="
echo "Validation Summary"
echo "=========================================="
echo "SSH Key Exists:          $([ -f "$SSH_KEY" ] && echo "✓" || echo "✗")"
echo "SSH Accessible:          $([ "$SSH_ACCESSIBLE" = "true" ] && echo "✓" || echo "✗")"
echo "Docker Accessible:       $([ "$DOCKER_ACCESSIBLE" = "true" ] && echo "✓" || echo "✗")"
echo "Credentials Configured:  $([ "$CREDENTIALS_CONFIGURED" = "true" ] && echo "✓" || echo "✗")"
echo "n8n Accessible:          $([ "$N8N_ACCESSIBLE" = "true" ] && echo "✓" || echo "⚠ (optional)")"
echo "=========================================="

# Update config if requested
if [ "$UPDATE_CONFIG" = "true" ] && command -v yq &> /dev/null; then
    log_info "Updating repo-profile.yaml..."

    TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    yq eval -i ".execution_mode.hosted.validation.last_validated = \"$TIMESTAMP\"" "$REPO_ROOT/config/repo-profile.yaml"
    yq eval -i ".execution_mode.hosted.validation.ssh_accessible = $SSH_ACCESSIBLE" "$REPO_ROOT/config/repo-profile.yaml"
    yq eval -i ".execution_mode.hosted.validation.docker_accessible = $DOCKER_ACCESSIBLE" "$REPO_ROOT/config/repo-profile.yaml"
    yq eval -i ".execution_mode.hosted.validation.credentials_configured = $CREDENTIALS_CONFIGURED" "$REPO_ROOT/config/repo-profile.yaml"

    if [ "$VALIDATION_PASSED" = "true" ]; then
        yq eval -i '.execution_mode.hosted.configured = true' "$REPO_ROOT/config/repo-profile.yaml"
        log_success "Configuration updated successfully"
    else
        yq eval -i '.execution_mode.hosted.configured = false' "$REPO_ROOT/config/repo-profile.yaml"
        log_warn "Configuration updated (validation failed - configured=false)"
    fi
fi

# Exit with appropriate code
if [ "$VALIDATION_PASSED" = "true" ]; then
    echo ""
    log_success "All validations passed! Proxmox hosted execution is ready."
    exit 0
else
    echo ""
    log_error "Validation failed. Fix the issues above and re-run."

    if [ "$INTERACTIVE" = "true" ]; then
        echo ""
        echo "For detailed setup instructions, see: docs/PROXMOX_SETUP.md"
        echo ""
    fi

    exit 1
fi
