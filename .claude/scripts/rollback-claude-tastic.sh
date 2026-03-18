#!/usr/bin/env bash
#
# rollback-claude-tastic.sh
# Rollback framework installation to pre-install state
# Restores files from .claude-tastic-backup/
#
# Usage:
#   ./scripts/rollback-claude-tastic.sh                 # Interactive rollback
#   ./scripts/rollback-claude-tastic.sh --force         # Non-interactive rollback
#   ./scripts/rollback-claude-tastic.sh --dry-run       # Show what would be rolled back
#
# Exit codes:
#   0 - Rollback complete
#   1 - Error during rollback
#   2 - No backup found

set -euo pipefail

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Defaults
FORCE=false
DRY_RUN=false
BACKUP_DIR=".claude-tastic-backup"
MANIFEST_FILE=".claude-tastic-manifest.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --backup-dir)
            BACKUP_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'USAGE'
Usage: rollback-claude-tastic.sh [OPTIONS]

Rollback framework installation to pre-install state.
Restores original files from backup and removes framework files.

Options:
  --force, -f         Skip confirmation prompts
  --dry-run           Show what would be rolled back without making changes
  --backup-dir DIR    Use alternate backup directory (default: .claude-tastic-backup)
  --help              Show this help

Examples:
  ./scripts/rollback-claude-tastic.sh
  ./scripts/rollback-claude-tastic.sh --dry-run
  ./scripts/rollback-claude-tastic.sh --force
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check prerequisites
check_prerequisites() {
    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "Backup directory not found: $BACKUP_DIR"
        echo ""
        echo "Nothing to rollback. The framework may not have been installed,"
        echo "or the backup was already removed."
        return 1
    fi

    if [ ! -f "$BACKUP_DIR/manifest-pre-install.json" ]; then
        log_warn "Pre-install manifest not found in backup"
        echo "  Backup exists but may be incomplete"
    fi

    return 0
}

# Show rollback plan
show_rollback_plan() {
    echo ""
    echo "================================================"
    echo "  Rollback Plan"
    echo "================================================"
    echo ""

    echo "The following will be rolled back:"
    echo ""

    # Files to restore
    echo "Files to restore from backup:"
    if [ -f "$BACKUP_DIR/CLAUDE.md.backup" ]; then
        echo "  - CLAUDE.md"
    fi
    if [ -f "$BACKUP_DIR/settings.json.backup" ]; then
        echo "  - .claude/settings.json"
    fi
    if [ -d "$BACKUP_DIR/agents.backup" ]; then
        echo "  - .claude/agents/"
    fi
    if [ -d "$BACKUP_DIR/commands.backup" ]; then
        echo "  - .claude/commands/"
    fi
    echo ""

    # Files to remove
    echo "Framework files to remove:"
    if [ -f "$MANIFEST_FILE" ]; then
        local agent_count=$(jq -r '.installed_components.agents' "$MANIFEST_FILE" 2>/dev/null || echo "0")
        local command_count=$(jq -r '.installed_components.commands' "$MANIFEST_FILE" 2>/dev/null || echo "0")
        echo "  - $agent_count agents from .claude/agents/"
        echo "  - $command_count commands from .claude/commands/"
    fi
    echo "  - .claude/hooks/ (framework hooks)"
    echo "  - $MANIFEST_FILE"
    echo ""

    # Backup will be kept
    echo "Backup directory will be renamed to:"
    echo "  $BACKUP_DIR-rollback-$(date +%Y%m%d-%H%M%S)"
    echo ""
}

# Perform rollback
perform_rollback() {
    log_info "Starting rollback..."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - No changes will be made"
        return 0
    fi

    local rollback_errors=0

    # Restore CLAUDE.md
    if [ -f "$BACKUP_DIR/CLAUDE.md.backup" ]; then
        log_info "Restoring CLAUDE.md..."
        if cp "$BACKUP_DIR/CLAUDE.md.backup" CLAUDE.md; then
            log_success "  Restored CLAUDE.md"
        else
            log_error "  Failed to restore CLAUDE.md"
            rollback_errors=$((rollback_errors + 1))
        fi
    fi

    # Restore .claude/settings.json
    if [ -f "$BACKUP_DIR/settings.json.backup" ]; then
        log_info "Restoring .claude/settings.json..."
        if cp "$BACKUP_DIR/settings.json.backup" .claude/settings.json; then
            log_success "  Restored .claude/settings.json"
        else
            log_error "  Failed to restore .claude/settings.json"
            rollback_errors=$((rollback_errors + 1))
        fi
    fi

    # Restore .claude/agents/
    if [ -d "$BACKUP_DIR/agents.backup" ]; then
        log_info "Restoring .claude/agents/..."
        rm -rf .claude/agents
        if cp -r "$BACKUP_DIR/agents.backup" .claude/agents; then
            log_success "  Restored .claude/agents/"
        else
            log_error "  Failed to restore .claude/agents/"
            rollback_errors=$((rollback_errors + 1))
        fi
    else
        # No backup means it didn't exist before — remove it
        if [ -d ".claude/agents" ]; then
            log_info "Removing .claude/agents/ (didn't exist before)..."
            rm -rf .claude/agents
            log_success "  Removed .claude/agents/"
        fi
    fi

    # Restore .claude/commands/
    if [ -d "$BACKUP_DIR/commands.backup" ]; then
        log_info "Restoring .claude/commands/..."
        rm -rf .claude/commands
        if cp -r "$BACKUP_DIR/commands.backup" .claude/commands; then
            log_success "  Restored .claude/commands/"
        else
            log_error "  Failed to restore .claude/commands/"
            rollback_errors=$((rollback_errors + 1))
        fi
    else
        # No backup means it didn't exist before — remove it
        if [ -d ".claude/commands" ]; then
            log_info "Removing .claude/commands/ (didn't exist before)..."
            rm -rf .claude/commands
            log_success "  Removed .claude/commands/"
        fi
    fi

    # Remove framework hooks
    if [ -d ".claude/hooks" ]; then
        log_info "Removing framework hooks..."
        rm -rf .claude/hooks
        log_success "  Removed .claude/hooks/"
    fi

    # Remove manifest
    if [ -f "$MANIFEST_FILE" ]; then
        log_info "Removing manifest..."
        rm -f "$MANIFEST_FILE"
        log_success "  Removed $MANIFEST_FILE"
    fi

    # Remove discovery file if present
    if [ -f ".claude-tastic-discovery.json" ]; then
        log_info "Removing discovery file..."
        rm -f ".claude-tastic-discovery.json"
        log_success "  Removed .claude-tastic-discovery.json"
    fi

    # Rename backup directory
    local backup_archive="$BACKUP_DIR-rollback-$(date +%Y%m%d-%H%M%S)"
    log_info "Archiving backup directory..."
    if mv "$BACKUP_DIR" "$backup_archive"; then
        log_success "  Backup archived to: $backup_archive"
    else
        log_error "  Failed to archive backup"
        rollback_errors=$((rollback_errors + 1))
    fi

    echo ""
    if [ $rollback_errors -eq 0 ]; then
        log_success "Rollback complete"
        echo ""
        echo "Your repository has been restored to its pre-framework state."
        echo ""
        echo "Backup archived at: $backup_archive"
        echo "  (Safe to delete after verifying rollback)"
        echo ""
        return 0
    else
        log_error "Rollback completed with $rollback_errors error(s)"
        echo ""
        echo "Some files may not have been restored correctly."
        echo "Check backup at: $BACKUP_DIR"
        echo ""
        return 1
    fi
}

# Main execution
main() {
    echo ""
    echo "================================================"
    echo "  Claude-tastic Framework Rollback"
    echo "================================================"
    echo ""

    # Check prerequisites
    if ! check_prerequisites; then
        exit 2
    fi

    log_success "Backup found: $BACKUP_DIR"
    echo ""

    # Show rollback plan
    show_rollback_plan

    # Confirm rollback
    if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
        echo "This will restore your repository to its pre-framework state."
        read -p "Continue with rollback? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_warn "Rollback cancelled by user"
            exit 0
        fi
        echo ""
    fi

    # Perform rollback
    if ! perform_rollback; then
        exit 1
    fi

    echo "================================================"
    echo ""

    exit 0
}

main
