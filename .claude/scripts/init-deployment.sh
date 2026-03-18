#!/usr/bin/env bash
#
# init-deployment.sh
# Initialize $FRAMEWORK_DIR directory structure for configuration sync
# Default: ~/.claude-agent/ (set FRAMEWORK_NAME=claude-tastic to preserve ~/.claude-tastic/)
# size-ok: deployment initialization with directory creation and permissions management
#
# Usage:
#   ./init-deployment.sh              # Interactive initialization
#   ./init-deployment.sh --check      # Check only, don't create
#   ./init-deployment.sh --force      # Force re-initialization
#   ./init-deployment.sh --detect     # Output JSON detection result
#
# Exit codes:
#   0 - Success (or already initialized with --check)
#   1 - Error during initialization
#   2 - Not initialized (with --check)
#

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    # Minimal fallback if common.sh not available
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
fi

# Source framework config to get FRAMEWORK_DIR (default: ~/.claude-agent)
source "${SCRIPT_DIR}/lib/framework-config.sh"

# Configuration
CLAUDE_AGENTS_DIR="${FRAMEWORK_DIR}"
SYNC_STATE_FILE="${CLAUDE_AGENTS_DIR}/.sync-state.json"

# Version tracking
readonly SCHEMA_VERSION="1.0"
readonly SCRIPT_VERSION="1.0.0"

# Parse arguments
CHECK_ONLY=false
FORCE=false
DETECT_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --detect)
            DETECT_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [--check|--force|--detect|--help]"
            echo ""
            echo "Options:"
            echo "  --check   Check if initialized, don't modify"
            echo "  --force   Force re-initialization"
            echo "  --detect  Output JSON detection result"
            echo "  --help    Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Migration: move existing ~/.claude-tastic/ data to new FRAMEWORK_DIR if needed
# Skip migration if FRAMEWORK_NAME=claude-tastic (preserves ~/.claude-tastic/)
LEGACY_DIR="${HOME}/.claude-tastic"
if [ "$CLAUDE_AGENTS_DIR" != "$LEGACY_DIR" ] && [ -d "$LEGACY_DIR" ] && [ ! -d "$CLAUDE_AGENTS_DIR" ]; then
    log_info "Migrating existing data from $LEGACY_DIR to $CLAUDE_AGENTS_DIR"
    mv "$LEGACY_DIR" "$CLAUDE_AGENTS_DIR"
    log_success "Migration complete: $LEGACY_DIR -> $CLAUDE_AGENTS_DIR"
fi

# Define directory structure with permissions (in creation order)
# Format: "directory:permissions"
DIRECTORY_LIST=(
    "${CLAUDE_AGENTS_DIR}:755"
    "${CLAUDE_AGENTS_DIR}/credentials:700"
    "${CLAUDE_AGENTS_DIR}/overrides:755"
    "${CLAUDE_AGENTS_DIR}/overrides/agents:755"
    "${CLAUDE_AGENTS_DIR}/overrides/n8n-workflows:755"
    "${CLAUDE_AGENTS_DIR}/state:755"
)

# Define credential placeholder files
CREDENTIAL_FILES=(
    "github-token"
    "claude-oauth"
    "n8n-api-key"
)

# Get file permissions (cross-platform)
get_permissions() {
    local path="$1"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        stat -f "%OLp" "$path" 2>/dev/null || echo "000"
    else
        stat -c "%a" "$path" 2>/dev/null || echo "000"
    fi
}

# Check if already initialized
is_initialized() {
    [ -d "$CLAUDE_AGENTS_DIR" ] && [ -f "$SYNC_STATE_FILE" ]
}

# Check directory structure
check_structure() {
    local missing=()
    local wrong_perms=()

    for entry in "${DIRECTORY_LIST[@]}"; do
        local dir="${entry%%:*}"
        local expected_perm="${entry##*:}"

        if [ ! -d "$dir" ]; then
            missing+=("$dir")
        else
            local actual_perm
            actual_perm=$(get_permissions "$dir")
            if [ "$actual_perm" != "$expected_perm" ]; then
                wrong_perms+=("$dir:expected=$expected_perm,actual=$actual_perm")
            fi
        fi
    done

    if [ ${#missing[@]} -gt 0 ] || [ ${#wrong_perms[@]} -gt 0 ]; then
        echo "missing:${missing[*]:-none}"
        echo "wrong_perms:${wrong_perms[*]:-none}"
        return 1
    fi
    return 0
}

# Create initial sync state file
create_sync_state() {
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local hostname
    hostname=$(hostname 2>/dev/null || echo "unknown")
    local platform
    case "$OSTYPE" in
        darwin*) platform="darwin" ;;
        linux*) platform="linux" ;;
        msys*|cygwin*) platform="windows" ;;
        *) platform="unknown" ;;
    esac

    cat > "$SYNC_STATE_FILE" << EOF
{
  "schema_version": "$SCHEMA_VERSION",
  "initialized_at": "$timestamp",
  "last_sync": null,
  "applied_versions": {
    "agents": null,
    "n8n-workflows": null,
    "settings": null
  },
  "sync_enabled": false,
  "metadata": {
    "hostname": "$hostname",
    "init_script_version": "$SCRIPT_VERSION",
    "platform": "$platform"
  }
}
EOF
}

# Create credential placeholders
create_credential_placeholders() {
    local cred_dir="${CLAUDE_AGENTS_DIR}/credentials"
    for cred in "${CREDENTIAL_FILES[@]}"; do
        local cred_file="${cred_dir}/${cred}"
        if [ ! -f "$cred_file" ]; then
            cat > "$cred_file" << EOF
# ${cred}
# Add your ${cred} here
# This file should contain ONLY the token/key value
EOF
            chmod 600 "$cred_file"
        fi
    done
}

# Create default settings override
create_default_settings() {
    local settings_file="${CLAUDE_AGENTS_DIR}/overrides/settings.yaml"
    if [ ! -f "$settings_file" ]; then
        cat > "$settings_file" << 'EOF'
# User-specific settings overrides
# These settings take precedence over repository defaults
#
# Example:
# default_model: haiku
# container_execution: true
# auto_commit: false
EOF
    fi
}

# Detect mode - output JSON
if $DETECT_MODE; then
    initialized=$(is_initialized && echo "true" || echo "false")
    has_credentials="false"
    if [ -f "${CLAUDE_AGENTS_DIR}/credentials/github-token" ]; then
        content=$(cat "${CLAUDE_AGENTS_DIR}/credentials/github-token" 2>/dev/null || echo "")
        if [ -n "$content" ] && ! echo "$content" | grep -q "^#"; then
            has_credentials="true"
        fi
    fi

    echo "{"
    echo "  \"initialized\": $initialized,"
    echo "  \"directory\": \"$CLAUDE_AGENTS_DIR\","
    echo "  \"has_credentials\": $has_credentials,"
    echo "  \"schema_version\": \"$SCHEMA_VERSION\""
    echo "}"
    exit 0
fi

# Check mode
if $CHECK_ONLY; then
    if is_initialized; then
        log_success "Deployment is initialized at $CLAUDE_AGENTS_DIR"
        check_structure || log_warn "Some directories need attention"
        exit 0
    else
        log_warn "Deployment not initialized"
        exit 2
    fi
fi

# Main initialization
log_info "Initializing deployment at $CLAUDE_AGENTS_DIR"

# Check if already initialized
if is_initialized && ! $FORCE; then
    log_info "Already initialized. Use --force to re-initialize."
    exit 0
fi

# Create directories with proper permissions (in order)
for entry in "${DIRECTORY_LIST[@]}"; do
    dir="${entry%%:*}"
    perms="${entry##*:}"

    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log_info "Created: $dir"
    fi
    chmod "$perms" "$dir"
done

# Create sync state file
if [ ! -f "$SYNC_STATE_FILE" ] || $FORCE; then
    create_sync_state
    log_info "Created sync state file"
fi

# Create credential placeholders
create_credential_placeholders
log_info "Created credential placeholders"

# Create default settings
create_default_settings
log_info "Created default settings override"

# Create empty state files
touch "${CLAUDE_AGENTS_DIR}/state/sprint-state.json"
touch "${CLAUDE_AGENTS_DIR}/state/container-registry.json"

log_success "Deployment initialized successfully"
echo ""
echo "Next steps:"
echo "  1. Add your credentials to ${CLAUDE_AGENTS_DIR}/credentials/"
echo "     - github-token: Your GitHub personal access token"
echo "     - claude-oauth: Your Claude OAuth token"
echo "     - n8n-api-key: Your n8n API key (if using n8n)"
echo ""
echo "  2. Customize settings in ${CLAUDE_AGENTS_DIR}/overrides/settings.yaml"
echo ""
echo "  3. Run validate-deployment.sh to verify setup"
