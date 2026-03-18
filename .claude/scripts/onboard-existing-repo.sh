#!/usr/bin/env bash
#
# onboard-existing-repo.sh
# Phase 1-4: Onboarding orchestration for existing repos
# Handles reconciliation, installation, validation, and recommendations
#
# Usage:
#   ./scripts/onboard-existing-repo.sh                  # Interactive onboarding
#   ./scripts/onboard-existing-repo.sh --auto-yes       # Non-interactive (yes to all)
#   ./scripts/onboard-existing-repo.sh --dry-run        # Show what would happen
#   ./scripts/onboard-existing-repo.sh --skip-backup    # Skip backup creation
#
# Prerequisites:
#   - Must run discover-existing-repo.sh first
#   - Framework must be installed at .claude-sync/ or $CLAUDE_FRAMEWORK_DIR
#
# Exit codes:
#   0 - Onboarding complete
#   1 - Error during onboarding
#   2 - Prerequisites not met

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
AUTO_YES=false
DRY_RUN=false
SKIP_BACKUP=false
DISCOVERY_FILE=".claude-tastic-discovery.json"
BACKUP_DIR=".claude-tastic-backup"
MANIFEST_FILE=".claude-tastic-manifest.json"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --auto-yes|-y)
            AUTO_YES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --skip-backup)
            SKIP_BACKUP=true
            shift
            ;;
        --discovery)
            DISCOVERY_FILE="$2"
            shift 2
            ;;
        --help|-h)
            cat <<'USAGE'
Usage: onboard-existing-repo.sh [OPTIONS]

Orchestrate framework onboarding for existing repositories.
Handles reconciliation, installation, validation, and recommendations.

Options:
  --auto-yes, -y      Accept all prompts automatically (non-interactive)
  --dry-run           Show what would happen without making changes
  --skip-backup       Skip backup creation (not recommended)
  --discovery FILE    Use alternate discovery file (default: .claude-tastic-discovery.json)
  --help              Show this help

Prerequisites:
  1. Run ./scripts/discover-existing-repo.sh first
  2. Framework installed at .claude-sync/ or $CLAUDE_FRAMEWORK_DIR

Examples:
  ./scripts/onboard-existing-repo.sh
  ./scripts/onboard-existing-repo.sh --dry-run
  ./scripts/onboard-existing-repo.sh --auto-yes
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
    local errors=0

    # Check discovery file
    if [ ! -f "$DISCOVERY_FILE" ]; then
        log_error "Discovery file not found: $DISCOVERY_FILE"
        echo "  Run: ./scripts/discover-existing-repo.sh first"
        errors=1
    fi

    # Check framework source
    FRAMEWORK_DIR=""
    if [ -n "${CLAUDE_FRAMEWORK_DIR:-}" ] && [ -d "$CLAUDE_FRAMEWORK_DIR/core/agents" ]; then
        FRAMEWORK_DIR="$CLAUDE_FRAMEWORK_DIR"
    elif [ -d ".claude-sync/core/agents" ]; then
        FRAMEWORK_DIR="$(pwd)/.claude-sync"
    elif [ -d "$HOME/Repos/claude-agents/core/agents" ]; then
        FRAMEWORK_DIR="$HOME/Repos/claude-agents"
    else
        log_error "Framework source not found"
        echo "  Run: ./scripts/load-claude-tastic.sh first"
        errors=1
    fi

    # Check jq
    if ! command -v jq &>/dev/null; then
        log_error "jq not found. Install jq before running."
        errors=1
    fi

    return $errors
}

# Phase 1: Interactive Reconciliation
reconcile_conflicts() {
    log_info "Phase 1: Interactive Reconciliation"
    echo ""

    # Load discovery data
    local is_existing=$(jq -r '.is_existing_repo' "$DISCOVERY_FILE")

    if [ "$is_existing" != "true" ]; then
        log_info "New repository detected — no conflicts to reconcile"
        return 0
    fi

    # Display existing assets
    echo "Found existing assets:"
    echo ""

    # CLAUDE.md
    local has_claude_md=$(jq -r '.existing_assets.claude_md' "$DISCOVERY_FILE")
    local claude_md_lines=$(jq -r '.existing_assets.claude_md_lines' "$DISCOVERY_FILE")
    if [ "$has_claude_md" = "true" ]; then
        echo "  CLAUDE.md ($claude_md_lines lines) — has custom instructions"
    fi

    # Git hooks
    local hooks=$(jq -r '.existing_assets.hooks[]' "$DISCOVERY_FILE" 2>/dev/null || echo "")
    if [ -n "$hooks" ]; then
        echo "  Git hooks: $hooks"
    fi

    # CI scripts
    local ci_count=$(jq -r '.existing_assets.ci_scripts | length' "$DISCOVERY_FILE")
    if [ "$ci_count" -gt 0 ]; then
        echo "  scripts/ci/ ($ci_count scripts)"
    fi

    # Tests
    local test_count=$(jq -r '.existing_assets.test_file_count' "$DISCOVERY_FILE")
    local test_framework=$(jq -r '.existing_assets.test_framework' "$DISCOVERY_FILE")
    if [ "$test_count" -gt 0 ]; then
        echo "  tests/ ($test_count test files, $test_framework framework)"
    fi

    echo ""
    echo "Framework will add:"
    echo "  + 30+ agent definitions"
    echo "  + 60+ skills (/sprint-work, /capture, /repo-audit-complete, etc.)"
    echo "  + 20+ CI scripts (security scan, validation gates, etc.)"
    echo "  + Enhanced git hooks (security checks, validation)"
    echo "  + Config templates (repo-profile, agent-permissions)"
    echo ""

    # Check for conflicts
    local conflicts=$(jq -r '.conflicts[]' "$DISCOVERY_FILE" 2>/dev/null || echo "")
    if [ -n "$conflicts" ]; then
        echo -e "${YELLOW}Conflicts to resolve:${NC}"
        echo ""

        # Handle CLAUDE.md conflict
        if echo "$conflicts" | grep -q "claude_md"; then
            echo "  ! CLAUDE.md — merge framework instructions with your existing ones?"
            if [ "$AUTO_YES" = false ] && [ "$DRY_RUN" = false ]; then
                read -p "    [m]erge  [k]eep mine  [r]eplace with framework: " claude_md_choice
                CLAUDE_MD_ACTION="${claude_md_choice:-m}"
            else
                CLAUDE_MD_ACTION="m"
                echo "    Auto: merge"
            fi
        else
            CLAUDE_MD_ACTION="install"
        fi

        # Handle git hooks conflict
        if echo "$conflicts" | grep -q "git_hooks"; then
            echo "  ! Git hooks — add framework checks alongside your existing hooks?"
            if [ "$AUTO_YES" = false ] && [ "$DRY_RUN" = false ]; then
                read -p "    [m]erge  [k]eep mine  [r]eplace with framework: " hooks_choice
                HOOKS_ACTION="${hooks_choice:-m}"
            else
                HOOKS_ACTION="m"
                echo "    Auto: merge"
            fi
        else
            HOOKS_ACTION="install"
        fi

        # Handle settings.json conflict
        if echo "$conflicts" | grep -q "claude_settings"; then
            echo "  ! .claude/settings.json — merge with framework settings?"
            if [ "$AUTO_YES" = false ] && [ "$DRY_RUN" = false ]; then
                read -p "    [m]erge  [k]eep mine  [r]eplace with framework: " settings_choice
                SETTINGS_ACTION="${settings_choice:-m}"
            else
                SETTINGS_ACTION="m"
                echo "    Auto: merge"
            fi
        else
            SETTINGS_ACTION="install"
        fi
    else
        CLAUDE_MD_ACTION="install"
        HOOKS_ACTION="install"
        SETTINGS_ACTION="install"
    fi

    echo ""
    if [ "$DRY_RUN" = false ]; then
        if [ "$AUTO_YES" = false ]; then
            read -p "Proceed with installation? [y/N]: " proceed
            if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
                log_warn "Installation cancelled by user"
                exit 0
            fi
        fi
    else
        log_info "DRY RUN - Would proceed with installation"
    fi

    echo ""
}

# Phase 2: Safe Installation
install_framework() {
    log_info "Phase 2: Safe Installation"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - Would install framework components"
        return 0
    fi

    # Create backup
    if [ "$SKIP_BACKUP" = false ]; then
        log_info "Creating backup..."
        mkdir -p "$BACKUP_DIR"

        # Backup existing files that will be modified
        [ -f "CLAUDE.md" ] && cp "CLAUDE.md" "$BACKUP_DIR/CLAUDE.md.backup"
        [ -f ".claude/settings.json" ] && cp ".claude/settings.json" "$BACKUP_DIR/settings.json.backup"
        [ -d ".claude/agents" ] && cp -r ".claude/agents" "$BACKUP_DIR/agents.backup"
        [ -d ".claude/commands" ] && cp -r ".claude/commands" "$BACKUP_DIR/commands.backup"

        # Save pre-install manifest
        if [ -f "$DISCOVERY_FILE" ]; then
            cp "$DISCOVERY_FILE" "$BACKUP_DIR/manifest-pre-install.json"
        fi

        log_success "Backup created at: $BACKUP_DIR"
    fi

    # Install core framework components
    log_info "Installing framework components..."

    # 1. Install agents
    mkdir -p .claude/agents
    if [ -d "$FRAMEWORK_DIR/core/agents" ]; then
        cp "$FRAMEWORK_DIR"/core/agents/*.md .claude/agents/ 2>/dev/null || true
        log_success "  Installed core agents"
    fi

    # 2. Install commands/skills
    mkdir -p .claude/commands
    if [ -d "$FRAMEWORK_DIR/core/commands" ]; then
        cp "$FRAMEWORK_DIR"/core/commands/*.md .claude/commands/ 2>/dev/null || true
        log_success "  Installed core commands/skills"
    fi

    # 3. Install packs (if present)
    if [ -d "$FRAMEWORK_DIR/packs" ]; then
        for pack_dir in "$FRAMEWORK_DIR"/packs/*/; do
            [ ! -d "$pack_dir" ] && continue
            [ -d "$pack_dir/agents" ] && cp "$pack_dir/agents/"*.md .claude/agents/ 2>/dev/null || true
            [ -d "$pack_dir/commands" ] && cp "$pack_dir/commands/"*.md .claude/commands/ 2>/dev/null || true
        done
        log_success "  Installed packs"
    fi

    # 4. Handle CLAUDE.md based on conflict resolution
    case "$CLAUDE_MD_ACTION" in
        m|merge)
            if [ -f "CLAUDE.md" ]; then
                log_info "  Merging CLAUDE.md with framework version..."
                if [ -f "$FRAMEWORK_DIR/CLAUDE.md" ]; then
                    # Create merged version
                    {
                        echo "# Project Instructions"
                        echo ""
                        echo "## Existing Project Instructions"
                        echo ""
                        cat CLAUDE.md
                        echo ""
                        echo "---"
                        echo ""
                        echo "## Framework Instructions"
                        echo ""
                        tail -n +2 "$FRAMEWORK_DIR/CLAUDE.md"
                    } > CLAUDE.md.new
                    mv CLAUDE.md.new CLAUDE.md
                    log_success "  Merged CLAUDE.md"
                fi
            else
                [ -f "$FRAMEWORK_DIR/CLAUDE.md" ] && cp "$FRAMEWORK_DIR/CLAUDE.md" CLAUDE.md
                log_success "  Installed CLAUDE.md"
            fi
            ;;
        k|keep)
            log_info "  Keeping existing CLAUDE.md"
            ;;
        r|replace)
            [ -f "$FRAMEWORK_DIR/CLAUDE.md" ] && cp "$FRAMEWORK_DIR/CLAUDE.md" CLAUDE.md
            log_success "  Replaced CLAUDE.md with framework version"
            ;;
        install)
            [ -f "$FRAMEWORK_DIR/CLAUDE.md" ] && cp "$FRAMEWORK_DIR/CLAUDE.md" CLAUDE.md
            log_success "  Installed CLAUDE.md"
            ;;
    esac

    # 5. Install hooks (if present)
    if [ -d "$FRAMEWORK_DIR/.claude/hooks" ]; then
        mkdir -p .claude/hooks
        cp -r "$FRAMEWORK_DIR/.claude/hooks/"* .claude/hooks/ 2>/dev/null || true
        log_success "  Installed hooks"
    fi

    # 6. Install CI scripts (skip duplicates, add new)
    if [ -d "$FRAMEWORK_DIR/scripts/ci" ]; then
        mkdir -p scripts/ci
        # Copy only new scripts
        for script in "$FRAMEWORK_DIR"/scripts/ci/*.sh; do
            script_name=$(basename "$script")
            if [ ! -f "scripts/ci/$script_name" ]; then
                cp "$script" "scripts/ci/$script_name"
            fi
        done
        log_success "  Installed CI scripts (skipped duplicates)"
    fi

    # 7. Install config templates
    if [ -d "$FRAMEWORK_DIR/config" ]; then
        mkdir -p config
        # Merge with existing if present
        for config_file in "$FRAMEWORK_DIR"/config/*.{yaml,yml,json} 2>/dev/null; do
            [ ! -f "$config_file" ] && continue
            config_name=$(basename "$config_file")
            if [ ! -f "config/$config_name" ]; then
                cp "$config_file" "config/$config_name"
            fi
        done
        log_success "  Installed config templates"
    fi

    # 8. Handle settings.json based on conflict resolution
    case "$SETTINGS_ACTION" in
        m|merge|install)
            if [ ! -f ".claude/settings.json" ]; then
                # Create default settings.json
                cat > .claude/settings.json <<'SETTINGS'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/dynamic-loader.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/block-secrets.py"
          }
        ]
      }
    ]
  }
}
SETTINGS
                log_success "  Created .claude/settings.json"
            else
                log_info "  Keeping existing .claude/settings.json"
            fi
            ;;
        k|keep)
            log_info "  Keeping existing .claude/settings.json"
            ;;
        r|replace)
            # Replace with framework version (same as install for now)
            cat > .claude/settings.json <<'SETTINGS'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/dynamic-loader.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/block-secrets.py"
          }
        ]
      }
    ]
  }
}
SETTINGS
            log_success "  Replaced .claude/settings.json"
            ;;
    esac

    # 9. Generate manifest
    log_info "  Generating manifest..."
    cat > "$MANIFEST_FILE" <<EOF
{
  "installation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "framework_source": "$FRAMEWORK_DIR",
  "framework_version": "$(cat "$FRAMEWORK_DIR/.version" 2>/dev/null || echo "unknown")",
  "backup_location": "$BACKUP_DIR",
  "reconciliation": {
    "claude_md": "$CLAUDE_MD_ACTION",
    "hooks": "$HOOKS_ACTION",
    "settings": "$SETTINGS_ACTION"
  },
  "installed_components": {
    "agents": $(find .claude/agents -name "*.md" 2>/dev/null | wc -l | tr -d ' '),
    "commands": $(find .claude/commands -name "*.md" 2>/dev/null | wc -l | tr -d ' '),
    "hooks": $(find .claude/hooks -type f 2>/dev/null | wc -l | tr -d ' ')
  }
}
EOF
    log_success "  Generated $MANIFEST_FILE"

    # Ensure .gitignore includes framework files
    if [ -f ".gitignore" ]; then
        if ! grep -q ".claude-tastic-" .gitignore 2>/dev/null; then
            echo "" >> .gitignore
            echo "# Claude-tastic framework" >> .gitignore
            echo ".claude-tastic-discovery.json" >> .gitignore
            echo ".claude-tastic-manifest.json" >> .gitignore
            echo ".claude-tastic-backup/" >> .gitignore
        fi
    fi

    echo ""
    log_success "Framework installation complete"
}

# Phase 3: Post-Install Validation
validate_installation() {
    log_info "Phase 3: Post-Install Validation"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        log_info "DRY RUN - Would validate installation"
        return 0
    fi

    local validation_errors=0

    # Check framework files
    if [ ! -d ".claude/agents" ]; then
        log_error "  Validation failed: .claude/agents/ not found"
        validation_errors=$((validation_errors + 1))
    else
        local agent_count=$(find .claude/agents -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        log_success "  Agents installed: $agent_count"
    fi

    if [ ! -d ".claude/commands" ]; then
        log_error "  Validation failed: .claude/commands/ not found"
        validation_errors=$((validation_errors + 1))
    else
        local command_count=$(find .claude/commands -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        log_success "  Commands installed: $command_count"
    fi

    # Run existing tests if present (non-blocking)
    local has_tests=$(jq -r '.existing_assets.test_file_count' "$DISCOVERY_FILE" 2>/dev/null || echo "0")
    if [ "$has_tests" != "0" ] && [ "$has_tests" != "null" ]; then
        log_info "  Running existing tests..."

        # Detect test framework and run
        local test_framework=$(jq -r '.existing_assets.test_framework' "$DISCOVERY_FILE")
        local test_passed=true

        case "$test_framework" in
            jest)
                if command -v npm &>/dev/null && [ -f "package.json" ]; then
                    if npm test 2>&1 | tee /tmp/test-output.log | tail -1 | grep -q "PASS"; then
                        log_success "  Tests passed"
                    else
                        log_warn "  Tests failed or skipped — review recommended"
                        test_passed=false
                    fi
                fi
                ;;
            pytest)
                if command -v pytest &>/dev/null; then
                    if pytest 2>&1 | tee /tmp/test-output.log | tail -1 | grep -q "passed"; then
                        log_success "  Tests passed"
                    else
                        log_warn "  Tests failed or skipped — review recommended"
                        test_passed=false
                    fi
                fi
                ;;
            *)
                log_info "  Test framework: $test_framework (skipping auto-run)"
                ;;
        esac

        if [ "$test_passed" = false ]; then
            log_warn "  Tests may need updates for framework compatibility"
            log_warn "  Check: /tmp/test-output.log for details"
        fi
    fi

    # Check manifest
    if [ ! -f "$MANIFEST_FILE" ]; then
        log_error "  Validation failed: manifest not generated"
        validation_errors=$((validation_errors + 1))
    else
        log_success "  Manifest generated"
    fi

    echo ""
    if [ $validation_errors -eq 0 ]; then
        log_success "Validation passed"
        return 0
    else
        log_error "Validation failed with $validation_errors error(s)"
        echo ""
        echo "To rollback: ./scripts/rollback-claude-tastic.sh"
        return 1
    fi
}

# Phase 4: First-Run Recommendations
show_recommendations() {
    log_info "Phase 4: First-Run Recommendations"
    echo ""

    echo "================================================"
    echo "  Installation Complete"
    echo "================================================"
    echo ""

    # Load gaps from discovery
    local missing_sdlc=$(jq -r '.gaps.missing_sdlc_workflow' "$DISCOVERY_FILE")
    local missing_security=$(jq -r '.gaps.missing_security_hooks' "$DISCOVERY_FILE")
    local missing_pr_gates=$(jq -r '.gaps.missing_pr_gates' "$DISCOVERY_FILE")

    echo "Recommended First Actions (in order):"
    echo ""
    echo "1. /repo-audit-complete — Full health check with framework analysis"
    echo "2. /repo-structure — Analyze repository structure"
    echo "3. /repo-code — Analyze code quality and patterns"
    echo "4. /capture — Start capturing existing known issues"
    echo "5. /sprint-status — Set up sprint tracking"
    echo ""

    echo "Suggested Improvements Found:"
    echo ""
    if [ "$missing_security" = "true" ]; then
        echo "- No security scanning — framework added pre-commit security hook"
    fi
    if [ "$missing_pr_gates" = "true" ]; then
        echo "- No PR validation gate — framework added pr-validation-gate.sh"
    fi

    local test_count=$(jq -r '.existing_assets.test_file_count' "$DISCOVERY_FILE" 2>/dev/null || echo "0")
    if [ "$test_count" != "0" ] && [ "$test_count" != "null" ]; then
        echo "- Tests exist but coverage tracking may be incomplete"
    fi

    local branch_strategy=$(jq -r '.existing_assets.branch_strategy' "$DISCOVERY_FILE")
    if [ "$branch_strategy" = "main-only" ]; then
        echo "- Single branch (main) — consider dev/qa/main strategy"
        echo "  Run: ./scripts/init-repo.sh --branch to create dev branch"
    fi

    echo ""
    echo "Framework files installed:"
    local agent_count=$(jq -r '.installed_components.agents' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    local command_count=$(jq -r '.installed_components.commands' "$MANIFEST_FILE" 2>/dev/null || echo "0")
    echo "  - $agent_count agents"
    echo "  - $command_count commands/skills"
    echo "  - Hooks and CI scripts"
    echo ""

    echo "Backup created at: $BACKUP_DIR"
    echo "  To rollback: ./scripts/rollback-claude-tastic.sh"
    echo ""
    echo "================================================"
    echo ""
}

# Main execution
main() {
    echo ""
    echo "================================================"
    echo "  Existing Repo Onboarding"
    echo "================================================"
    echo ""

    # Check prerequisites
    if ! check_prerequisites; then
        exit 2
    fi

    log_success "Prerequisites checked"
    log_info "Framework source: $FRAMEWORK_DIR"
    log_info "Discovery file: $DISCOVERY_FILE"
    echo ""

    # Execute phases
    reconcile_conflicts
    install_framework

    if ! validate_installation; then
        log_error "Installation validation failed"
        echo ""
        echo "Review errors above and run rollback if needed:"
        echo "  ./scripts/rollback-claude-tastic.sh"
        exit 1
    fi

    show_recommendations

    exit 0
}

main
