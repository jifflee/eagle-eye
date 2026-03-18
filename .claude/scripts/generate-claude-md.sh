#!/usr/bin/env bash
#
# generate-claude-md.sh
# Generate or update CLAUDE.md for new and existing repositories
# Merged from /local:review functionality into repo:init-framework
#
# Usage:
#   ./scripts/generate-claude-md.sh                    # Interactive mode
#   ./scripts/generate-claude-md.sh --force            # Overwrite existing
#   ./scripts/generate-claude-md.sh --merge            # Merge with existing
#   ./scripts/generate-claude-md.sh --check            # Check only, no changes
#
# Exit codes:
#   0 - CLAUDE.md generated or updated successfully
#   1 - Error during generation
#   2 - User cancelled or prerequisite missing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Defaults
MODE="interactive"
FORCE=false
MERGE=false
CHECK_ONLY=false
FRAMEWORK_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            MODE="force"
            shift
            ;;
        --merge)
            MERGE=true
            MODE="merge"
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --framework-dir)
            FRAMEWORK_DIR="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'USAGE'
Usage: generate-claude-md.sh [OPTIONS]

Generate or update CLAUDE.md for repositories.
Handles both new repos (create from template) and existing repos (merge/update).

Options:
  --force             Overwrite existing CLAUDE.md with framework template
  --merge             Merge framework template with existing CLAUDE.md
  --check             Check status only, no changes
  --framework-dir DIR Use specific framework directory
  --help              Show this help

Modes:
  interactive (default)  Prompt user for merge/replace decision
  --force                Replace existing CLAUDE.md
  --merge                Auto-merge with existing CLAUDE.md

Examples:
  ./scripts/generate-claude-md.sh              # Interactive
  ./scripts/generate-claude-md.sh --check       # Status check
  ./scripts/generate-claude-md.sh --merge       # Auto-merge
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 2
            ;;
    esac
done

# Find framework source
find_framework_source() {
    # Option 1: Explicit parameter
    if [ -n "${FRAMEWORK_DIR}" ] && [ -f "$FRAMEWORK_DIR/repo-template/CLAUDE.md" ]; then
        echo "$FRAMEWORK_DIR"
        return 0
    fi

    # Option 2: Env var
    if [ -n "${CLAUDE_FRAMEWORK_DIR:-}" ] && [ -f "$CLAUDE_FRAMEWORK_DIR/repo-template/CLAUDE.md" ]; then
        echo "$CLAUDE_FRAMEWORK_DIR"
        return 0
    fi

    # Option 3: .claude-sync/
    if [ -f ".claude-sync/repo-template/CLAUDE.md" ]; then
        echo "$(pwd)/.claude-sync"
        return 0
    fi

    # Option 4: ~/Repos/claude-agents
    if [ -f "$HOME/Repos/claude-agents/repo-template/CLAUDE.md" ]; then
        echo "$HOME/Repos/claude-agents"
        return 0
    fi

    # Option 5: Current repo (if we're in the framework repo itself)
    if [ -f "repo-template/CLAUDE.md" ]; then
        echo "$(pwd)"
        return 0
    fi

    return 1
}

# Detect framework source
if ! FRAMEWORK_DIR=$(find_framework_source); then
    log_error "Framework source not found"
    echo "  Searched:"
    echo "    1. \$CLAUDE_FRAMEWORK_DIR (${CLAUDE_FRAMEWORK_DIR:-not set})"
    echo "    2. ./.claude-sync/"
    echo "    3. ~/Repos/claude-agents/"
    echo ""
    echo "  Run ./load-claude-tastic.sh or set CLAUDE_FRAMEWORK_DIR"
    exit 2
fi

TEMPLATE_PATH="$FRAMEWORK_DIR/repo-template/CLAUDE.md"
TARGET_PATH="$REPO_ROOT/CLAUDE.md"

log_info "Framework source: $FRAMEWORK_DIR"
log_info "Template: $TEMPLATE_PATH"
log_info "Target: $TARGET_PATH"

# Check if CLAUDE.md exists
EXISTING_CLAUDE_MD=false
if [ -f "$TARGET_PATH" ]; then
    EXISTING_CLAUDE_MD=true
    EXISTING_LINES=$(wc -l < "$TARGET_PATH" 2>/dev/null || echo 0)
    log_info "Existing CLAUDE.md found ($EXISTING_LINES lines)"
else
    log_info "No existing CLAUDE.md found"
fi

# Check-only mode
if [ "$CHECK_ONLY" = true ]; then
    echo ""
    if [ "$EXISTING_CLAUDE_MD" = true ]; then
        # Run quality analysis
        if [ -x "$SCRIPT_DIR/repo-deploy-review-data.sh" ]; then
            log_info "Running quality analysis..."
            ANALYSIS=$("$SCRIPT_DIR/repo-deploy-review-data.sh" "$TARGET_PATH" "$TEMPLATE_PATH" 2>/dev/null || echo '{}')
            QUALITY_SCORE=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.quality_score // 0')
            echo ""
            echo "Quality Score: $QUALITY_SCORE/100"
            echo ""

            # Show gaps
            GAPS=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.gaps[]' 2>/dev/null || echo "")
            if [ -n "$GAPS" ]; then
                echo "Gaps identified:"
                echo "$GAPS" | while read -r gap; do
                    echo "  - $gap"
                done
                echo ""
            fi

            # Show recommendations
            RECOMMENDATIONS=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.recommendations[]' 2>/dev/null || echo "")
            if [ -n "$RECOMMENDATIONS" ]; then
                echo "Recommendations:"
                echo "$RECOMMENDATIONS" | while read -r rec; do
                    echo "  + $rec"
                done
                echo ""
            fi

            echo "Run with --merge to update CLAUDE.md"
        else
            log_warn "Quality analysis script not found, skipping analysis"
        fi
    else
        echo "Status: No CLAUDE.md present"
        echo "Run without --check to generate from template"
    fi
    exit 0
fi

# ==============================================================================
# NEW REPOSITORY: Create from template
# ==============================================================================

if [ "$EXISTING_CLAUDE_MD" = false ]; then
    log_info "Creating CLAUDE.md from framework template..."

    if [ ! -f "$TEMPLATE_PATH" ]; then
        log_error "Template not found: $TEMPLATE_PATH"
        exit 2
    fi

    # Copy template
    cp "$TEMPLATE_PATH" "$TARGET_PATH"
    log_success "Created CLAUDE.md from template"

    # Customize with repo name
    REPO_NAME=$(basename "$(git config --get remote.origin.url 2>/dev/null || echo '')" .git)
    if [ -n "$REPO_NAME" ]; then
        # Update project overview comment
        if grep -q "<!-- Describe your project here -->" "$TARGET_PATH" 2>/dev/null; then
            sed -i.bak "s/<!-- Describe your project here -->/This is the $REPO_NAME project/" "$TARGET_PATH"
            rm -f "$TARGET_PATH.bak"
        fi
    fi

    echo ""
    echo -e "${GREEN}${BOLD}✓ CLAUDE.md created successfully${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Review CLAUDE.md and customize for your project"
    echo "  2. Update agent configurations as needed"
    echo "  3. Add project-specific rules and standards"
    echo ""
    exit 0
fi

# ==============================================================================
# EXISTING REPOSITORY: Merge or replace
# ==============================================================================

log_info "Existing CLAUDE.md detected"

# Backup existing file
BACKUP_PATH="$TARGET_PATH.backup-$(date +%Y%m%d-%H%M%S)"
cp "$TARGET_PATH" "$BACKUP_PATH"
log_info "Backup created: $BACKUP_PATH"

# Determine action
ACTION=""
if [ "$FORCE" = true ]; then
    ACTION="replace"
    log_warn "Force mode: replacing existing CLAUDE.md"
elif [ "$MERGE" = true ]; then
    ACTION="merge"
    log_info "Merge mode: merging with framework template"
elif [ "$MODE" = "interactive" ]; then
    # Run analysis to help user decide
    if [ -x "$SCRIPT_DIR/repo-deploy-review-data.sh" ]; then
        log_info "Analyzing existing CLAUDE.md..."
        ANALYSIS=$("$SCRIPT_DIR/repo-deploy-review-data.sh" "$TARGET_PATH" "$TEMPLATE_PATH" 2>/dev/null || echo '{}')
        QUALITY_SCORE=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.quality_score // 0')
        echo ""
        echo "Current quality score: $QUALITY_SCORE/100"
        echo ""

        # Show key findings
        GAPS_COUNT=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.gaps | length')
        CONFLICTS_COUNT=$(echo "$ANALYSIS" | jq -r '.claude_md_analysis.conflicts | length')

        echo "Analysis:"
        echo "  - Gaps: $GAPS_COUNT areas missing from existing file"
        echo "  - Conflicts: $CONFLICTS_COUNT naming or format conflicts"
        echo ""
    fi

    # Prompt user
    echo "How should we handle your existing CLAUDE.md?"
    echo "  [m] Merge - Add framework content, preserve your customizations (Recommended)"
    echo "  [r] Replace - Use framework template, lose customizations"
    echo "  [k] Keep - Skip update, keep existing file as-is"
    echo ""
    read -p "Choose [m/r/k]: " choice

    case "${choice,,}" in
        m|merge)
            ACTION="merge"
            ;;
        r|replace)
            ACTION="replace"
            ;;
        k|keep)
            log_info "Keeping existing CLAUDE.md unchanged"
            rm -f "$BACKUP_PATH"
            exit 0
            ;;
        *)
            log_error "Invalid choice"
            rm -f "$BACKUP_PATH"
            exit 2
            ;;
    esac
fi

# Execute action
case "$ACTION" in
    replace)
        log_info "Replacing CLAUDE.md with framework template..."
        cp "$TEMPLATE_PATH" "$TARGET_PATH"
        log_success "CLAUDE.md replaced with framework template"
        echo ""
        echo -e "${YELLOW}⚠ Note: Backup saved to $BACKUP_PATH${NC}"
        echo "Review the new CLAUDE.md and restore any custom content from backup if needed."
        ;;

    merge)
        log_info "Merging framework template with existing CLAUDE.md..."

        # Create merged version
        # Strategy: Keep existing content, append missing framework sections with markers
        TEMP_MERGED=$(mktemp)

        # Start with existing content
        cat "$TARGET_PATH" > "$TEMP_MERGED"

        # Add separator
        cat >> "$TEMP_MERGED" <<'EOF'

---

## Framework Integration (Auto-Added)

The following sections were added by the Claude Agent Framework.
Review and merge with your existing content as needed.

EOF

        # Check which sections are missing and add them
        if ! grep -qi "agent framework\|available agents" "$TARGET_PATH"; then
            echo "" >> "$TEMP_MERGED"
            echo "### Agent Framework" >> "$TEMP_MERGED"
            echo "" >> "$TEMP_MERGED"
            sed -n '/^## Agent Framework/,/^## [^#]/p' "$TEMPLATE_PATH" | head -n -1 >> "$TEMP_MERGED"
        fi

        if ! grep -qi "sdlc workflow" "$TARGET_PATH"; then
            echo "" >> "$TEMP_MERGED"
            echo "### SDLC Workflow" >> "$TEMP_MERGED"
            echo "" >> "$TEMP_MERGED"
            sed -n '/^### SDLC Workflow/,/^## [^#]/p' "$TEMPLATE_PATH" | head -n -1 >> "$TEMP_MERGED"
        fi

        if ! grep -qi "repository standards" "$TARGET_PATH"; then
            echo "" >> "$TEMP_MERGED"
            echo "### Repository Standards" >> "$TEMP_MERGED"
            echo "" >> "$TEMP_MERGED"
            sed -n '/^## Repository Standards/,/^## [^#]/p' "$TEMPLATE_PATH" | head -n -1 >> "$TEMP_MERGED"
        fi

        if ! grep -qi "security rules" "$TARGET_PATH"; then
            echo "" >> "$TEMP_MERGED"
            echo "### Security Rules" >> "$TEMP_MERGED"
            echo "" >> "$TEMP_MERGED"
            sed -n '/^## Security Rules/,/^## [^#]/p' "$TEMPLATE_PATH" | head -n -1 >> "$TEMP_MERGED"
        fi

        if ! grep -qiE "(permission tier|T0.*read.only|T1.*safe write|T2.*reversible|T3.*destructive)" "$TARGET_PATH"; then
            echo "" >> "$TEMP_MERGED"
            echo "### Permission Tiers (Auto-Added)" >> "$TEMP_MERGED"
            echo "" >> "$TEMP_MERGED"
            sed -n '/^## Permission Tiers/,/^## [^#]/p' "$TEMPLATE_PATH" | head -n -1 >> "$TEMP_MERGED"
        fi

        # Replace target with merged version
        mv "$TEMP_MERGED" "$TARGET_PATH"

        log_success "CLAUDE.md updated with framework content"
        echo ""
        echo -e "${YELLOW}⚠ Action Required:${NC}"
        echo "  1. Review the 'Framework Integration' section at the end of CLAUDE.md"
        echo "  2. Merge the auto-added sections with your existing content"
        echo "  3. Remove duplicate or conflicting sections"
        echo "  4. Delete the 'Framework Integration' heading once merged"
        echo ""
        echo "  Backup: $BACKUP_PATH"
        ;;

    *)
        log_error "Unknown action: $ACTION"
        rm -f "$BACKUP_PATH"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}${BOLD}✓ CLAUDE.md generation complete${NC}"
echo ""
echo "Run './scripts/validate/validate-claude-md.sh' to validate the updated file"
echo ""

exit 0
