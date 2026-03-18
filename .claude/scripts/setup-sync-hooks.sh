#!/usr/bin/env bash
#
# setup-sync-hooks.sh
# Install git hooks for automatic sync (post-merge)
# Feature #517: Git hook integration
# Renamed from setup-hooks.sh to distinguish from scripts/dev/setup-hooks.sh
#
# Usage:
#   ./scripts/setup-sync-hooks.sh           # Install all hooks
#   ./scripts/setup-sync-hooks.sh --check   # Check hook status
#   ./scripts/setup-sync-hooks.sh --remove  # Remove installed hooks
#

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="${REPO_DIR}/.git/hooks"

if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    source "${SCRIPT_DIR}/lib/common.sh"
else
    log_info() { echo "[INFO] $*" >&2; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
fi

# Parse arguments
CHECK_MODE=false
REMOVE_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --check)
            CHECK_MODE=true
            shift
            ;;
        --remove)
            REMOVE_MODE=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check   Check hook installation status"
            echo "  --remove  Remove installed hooks"
            echo "  --help    Show this help"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 2
            ;;
    esac
done

# Check if hook is installed
check_hook() {
    local hook_name="$1"
    local hook_path="${HOOKS_DIR}/${hook_name}"

    if [ ! -f "$hook_path" ]; then
        echo "not installed"
        return 1
    fi

    if [ ! -x "$hook_path" ]; then
        echo "installed (not executable)"
        return 1
    fi

    echo "installed"
    return 0
}

# Remove hook
remove_hook() {
    local hook_name="$1"
    local hook_path="${HOOKS_DIR}/${hook_name}"

    if [ -f "$hook_path" ]; then
        rm "$hook_path"
        log_success "Removed: $hook_name"
    else
        log_info "Not installed: $hook_name"
    fi
}

# Install hook
install_hook() {
    local hook_name="$1"
    local hook_path="${HOOKS_DIR}/${hook_name}"

    # Check if hook already exists
    if [ -f "$hook_path" ]; then
        log_warn "$hook_name already exists"

        # Check if it's our hook
        if grep -q "Feature #517" "$hook_path" 2>/dev/null; then
            log_info "Our hook is already installed: $hook_name"
            return 0
        fi

        # Backup existing hook
        local backup="${hook_path}.backup"
        cp "$hook_path" "$backup"
        log_info "Backed up existing hook to: $(basename "$backup")"
    fi

    # Copy the hook from .git/hooks if it exists, otherwise create it
    if [ "$hook_name" = "post-merge" ]; then
        # post-merge hook should already exist at .git/hooks/post-merge
        # Just make it executable
        if [ -f "$hook_path" ]; then
            chmod +x "$hook_path"
            log_success "Installed: $hook_name"
        else
            log_error "Hook file not found: $hook_path"
            return 1
        fi
    fi
}

# Main
main() {
    # Check if in git repo
    if [ ! -d "${REPO_DIR}/.git" ]; then
        log_error "Not in a git repository"
        exit 1
    fi

    # Ensure hooks directory exists
    mkdir -p "$HOOKS_DIR"

    # List of hooks to manage
    HOOKS=(
        "post-merge"
    )

    if $CHECK_MODE; then
        log_info "Git Hook Status:"
        for hook in "${HOOKS[@]}"; do
            status=$(check_hook "$hook" && echo "installed" || echo "not installed")
            echo "  $hook: $status"
        done
        exit 0
    fi

    if $REMOVE_MODE; then
        log_info "Removing git hooks..."
        for hook in "${HOOKS[@]}"; do
            remove_hook "$hook"
        done
        log_success "Hooks removed"
        exit 0
    fi

    # Install mode (default)
    log_info "Installing git hooks..."
    for hook in "${HOOKS[@]}"; do
        install_hook "$hook"
    done

    echo ""
    log_success "Git hooks installed successfully"
    echo ""
    echo "Installed hooks:"
    for hook in "${HOOKS[@]}"; do
        echo "  - $hook: automatic sync on config changes"
    done
    echo ""
    echo "To remove hooks: $0 --remove"
}

main
