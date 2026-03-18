#!/usr/bin/env bash
#
# load-claude-tastic.sh
# Bootstrap the claude-tastic framework into a consumer repository
# Implements Feature #689 - Consumer repo quickstart and deployment scripts
#
# Usage:
#   ./load-claude-tastic.sh                    # Interactive setup
#   ./load-claude-tastic.sh --version v1.0.0   # Pin to specific version
#   ./load-claude-tastic.sh --sync             # Also sync to ~/.claude/
#   ./load-claude-tastic.sh --check            # Check existing installation
#   ./load-claude-tastic.sh --update           # Update installation
#   ./load-claude-tastic.sh --offline --source <path>  # Offline installation
#   ./load-claude-tastic.sh --uninstall        # Remove installation
#
# Exit codes:
#   0 - Success
#   1 - Error
#   2 - Already installed (with --check)

set -euo pipefail

# Configuration
TEMPLATE_REPO="jifflee/claude-tastic"
TEMPLATE_URL_SSH="git@github.com:${TEMPLATE_REPO}.git"
TEMPLATE_URL_HTTPS="https://github.com/${TEMPLATE_REPO}.git"
DEFAULT_INSTALL_DIR=".claude-sync"
FRAMEWORK_CONFIG_VERSION="1.0"

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
VERSION=""
SYNC_TO_HOME=false
CHECK_ONLY=false
UPDATE_MODE=false
USE_HTTPS=false
INSTALL_DIR="$DEFAULT_INSTALL_DIR"
OFFLINE_MODE=false
SOURCE_PATH=""
UNINSTALL_MODE=false
RUN_TESTS=false
INTERACTIVE=true

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        --sync)
            SYNC_TO_HOME=true
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --update)
            UPDATE_MODE=true
            shift
            ;;
        --https)
            USE_HTTPS=true
            shift
            ;;
        --dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --offline)
            OFFLINE_MODE=true
            shift
            ;;
        --source)
            SOURCE_PATH="$2"
            shift 2
            ;;
        --uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        --test)
            RUN_TESTS=true
            shift
            ;;
        --non-interactive)
            INTERACTIVE=false
            shift
            ;;
        --help|-h)
            cat <<'USAGE'
Usage: load-claude-tastic.sh [OPTIONS]

Bootstrap the claude-tastic framework into your project.

Deployment Methods:
  1. Online (default)     - Clone from GitHub
  2. Offline              - Install from local source
  3. Git submodule        - Add as submodule (manual)

Options:
  --version TAG           Pin to specific version tag (default: latest main)
  --sync                  Also sync skills/agents to ~/.claude/
  --check                 Check if already installed, show status
  --update                Update existing installation to latest (or pinned version)
  --https                 Use HTTPS instead of SSH for git clone
  --dir DIR               Custom install directory (default: .claude-sync)
  --offline               Offline installation mode (requires --source)
  --source PATH           Path to framework source for offline install
  --uninstall             Remove framework installation
  --test                  Run end-to-end validation after install
  --non-interactive       Run without prompts (use defaults)
  --help                  Show this help

Examples:
  # Online installation
  ./load-claude-tastic.sh                      # Latest version
  ./load-claude-tastic.sh --version v1.0.0     # Pin to v1.0.0
  ./load-claude-tastic.sh --sync               # Setup + sync to ~/.claude/

  # Offline/air-gapped installation
  ./load-claude-tastic.sh --offline --source ./claude-tastic-v1.0.0/

  # Management
  ./load-claude-tastic.sh --check              # Verify installation
  ./load-claude-tastic.sh --update             # Pull latest changes
  ./load-claude-tastic.sh --uninstall          # Remove installation

Versioning:
  Framework uses semantic versioning (v1.0.0, v1.1.0, v2.0.0)
  Pin to specific version for stability
  Update manually or use --update flag

See docs/CONSUMER-QUICKSTART.md for full deployment guide.
USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Determine clone URL
if $USE_HTTPS; then
    CLONE_URL="$TEMPLATE_URL_HTTPS"
else
    CLONE_URL="$TEMPLATE_URL_SSH"
fi

# --- Shared functions ---

# Check prerequisites
check_prerequisites() {
    local missing=()

    if ! command -v git &>/dev/null; then
        missing+=("git")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing prerequisites: ${missing[*]}"
        echo ""
        if printf '%s\n' "${missing[@]}" | grep -q '^git$'; then
            echo "Install git:"
            echo "  macOS: xcode-select --install"
            echo "  Linux: sudo apt install git"
        fi
        if printf '%s\n' "${missing[@]}" | grep -q '^jq$'; then
            echo "Install jq:"
            echo "  macOS: brew install jq"
            echo "  Linux: sudo apt install jq"
            echo "  More:  https://stedolan.github.io/jq/download/"
        fi
        exit 1
    fi

    # gh is optional but recommended
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found (optional but recommended for GitHub features)"
        echo "  Install from: https://cli.github.com/"
    fi
}

# Sync framework files to ~/.claude/
_sync_to_home() {
    local src="$INSTALL_DIR"
    local dest="$HOME/.claude"

    mkdir -p "$dest/agents" "$dest/commands" "$dest/scripts"

    # Build list of expected files from source
    local expected_commands=()
    local expected_agents=()

    # Collect core files
    while IFS= read -r file; do
        expected_commands+=("$(basename "$file")")
    done < <(find "$src/core/commands" -name '*.md' -type f 2>/dev/null)

    while IFS= read -r file; do
        expected_agents+=("$(basename "$file")")
    done < <(find "$src/core/agents" -name '*.md' -type f 2>/dev/null)

    # Collect pack files
    for pack_dir in "$src"/packs/*/; do
        if [ -d "$pack_dir/commands" ]; then
            while IFS= read -r file; do
                expected_commands+=("$(basename "$file")")
            done < <(find "$pack_dir/commands" -name '*.md' -type f 2>/dev/null)
        fi
        if [ -d "$pack_dir/agents" ]; then
            while IFS= read -r file; do
                expected_agents+=("$(basename "$file")")
            done < <(find "$pack_dir/agents" -name '*.md' -type f 2>/dev/null)
        fi
    done

    # Sync core agents and commands
    cp "$src"/core/agents/*.md "$dest/agents/" 2>/dev/null || true
    cp "$src"/core/commands/*.md "$dest/commands/" 2>/dev/null || true

    # Sync packs
    for pack_dir in "$src"/packs/*/; do
        [ -d "$pack_dir/agents" ] && cp "$pack_dir/agents/"*.md "$dest/agents/" 2>/dev/null || true
        [ -d "$pack_dir/commands" ] && cp "$pack_dir/commands/"*.md "$dest/commands/" 2>/dev/null || true
    done

    # Sync scripts
    cp "$src"/scripts/*.sh "$dest/scripts/" 2>/dev/null || true

    # Clean up stale files from ~/.claude/commands and ~/.claude/agents
    local removed_count=0

    # Check commands directory for stale files
    if [ -d "$dest/commands" ]; then
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local filename
            filename=$(basename "$file")

            # Check if this file is in our expected list
            local found=false
            if [ ${#expected_commands[@]} -gt 0 ]; then
                for expected in "${expected_commands[@]}"; do
                    if [ "$filename" = "$expected" ]; then
                        found=true
                        break
                    fi
                done
            fi

            # If not found in expected list, remove it (it's stale)
            if [ "$found" = false ]; then
                rm -f "$file"
                log_info "Removed stale file: commands/$filename"
                ((removed_count++))
            fi
        done < <(find "$dest/commands" -name '*.md' -type f 2>/dev/null)
    fi

    # Check agents directory for stale files
    if [ -d "$dest/agents" ]; then
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            local filename
            filename=$(basename "$file")

            # Check if this file is in our expected list
            local found=false
            if [ ${#expected_agents[@]} -gt 0 ]; then
                for expected in "${expected_agents[@]}"; do
                    if [ "$filename" = "$expected" ]; then
                        found=true
                        break
                    fi
                done
            fi

            # If not found in expected list, remove it (it's stale)
            if [ "$found" = false ]; then
                rm -f "$file"
                log_info "Removed stale file: agents/$filename"
                ((removed_count++))
            fi
        done < <(find "$dest/agents" -name '*.md' -type f 2>/dev/null)
    fi

    local agent_count
    agent_count=$(find "$dest/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    local cmd_count
    cmd_count=$(find "$dest/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

    if [ "$removed_count" -gt 0 ]; then
        log_success "Synced to ~/.claude/ ($agent_count agents, $cmd_count commands, removed $removed_count stale files)"
    else
        log_success "Synced to ~/.claude/ ($agent_count agents, $cmd_count commands)"
    fi
}

# Install from offline source
_install_offline() {
    local src="$SOURCE_PATH"

    if [ ! -d "$src" ]; then
        log_error "Source path does not exist: $src"
        exit 1
    fi

    if [ ! -f "$src/README.md" ] || [ ! -d "$src/core" ]; then
        log_error "Source path does not appear to be a claude-tastic framework"
        exit 1
    fi

    log_info "Installing from offline source: $src"

    # Copy framework files
    mkdir -p "$INSTALL_DIR"
    cp -r "$src"/* "$INSTALL_DIR/" 2>/dev/null || true
    cp -r "$src"/.claude* "$INSTALL_DIR/" 2>/dev/null || true

    # Write version marker
    if [ -f "$src/.version" ]; then
        cp "$src/.version" "$INSTALL_DIR/.version"
    else
        echo "offline-$(date +%Y%m%d)" > "$INSTALL_DIR/.version"
    fi

    log_success "Offline installation complete"
}

# Run configuration flow (Child A)
_run_config_flow() {
    log_info "Running configuration flow..."

    if [ -f "$INSTALL_DIR/scripts/init-repo.sh" ]; then
        if [ "$INTERACTIVE" = true ]; then
            "$INSTALL_DIR/scripts/init-repo.sh" --status
        else
            "$INSTALL_DIR/scripts/init-repo.sh" --all --non-interactive 2>/dev/null || true
        fi
    else
        log_warn "Configuration script not found, skipping"
    fi
}

# Setup network gateway (Child C)
_setup_network_gateway() {
    log_info "Configuring network gateway..."

    # Create network gateway config if it doesn't exist
    if [ ! -f ".config/network-gateway-schema.json" ]; then
        mkdir -p .config
        cat > .config/network-gateway-schema.json <<'EOF'
{
  "corporate_mode": false,
  "approved_hosts": [
    "api.github.com",
    "api.anthropic.com"
  ],
  "network_gateway": {
    "enabled": true,
    "audit_log": "logs/network-audit.log"
  }
}
EOF
        log_success "Created network gateway configuration"
    fi
}

# Validate installation
_validate_install() {
    log_info "Validating installation..."

    local errors=0

    # Check core directories
    [ ! -d "$INSTALL_DIR/core" ] && { log_error "Missing core/ directory"; ((errors++)); }
    [ ! -d "$INSTALL_DIR/scripts" ] && { log_error "Missing scripts/ directory"; ((errors++)); }

    # Check key files
    [ ! -f "$INSTALL_DIR/README.md" ] && { log_error "Missing README.md"; ((errors++)); }
    [ ! -f "$INSTALL_DIR/.version" ] && { log_error "Missing .version marker"; ((errors++)); }

    if [ $errors -gt 0 ]; then
        log_error "Validation failed with $errors errors"
        return 1
    fi

    log_success "Validation passed"
    return 0
}

# Uninstall framework
_uninstall() {
    if [ ! -d "$INSTALL_DIR" ]; then
        log_warn "Framework not installed at $INSTALL_DIR"
        return 0
    fi

    if [ "$INTERACTIVE" = true ]; then
        echo ""
        log_warn "This will remove the framework installation at: $INSTALL_DIR"
        read -p "Continue? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            log_info "Uninstall cancelled"
            return 0
        fi
    fi

    log_info "Uninstalling framework..."

    # Backup before removal
    local backup_dir=".claude-sync-backup-$(date +%Y%m%d-%H%M%S)"
    mv "$INSTALL_DIR" "$backup_dir"
    log_success "Backed up to: $backup_dir"

    # Remove sync script if present
    [ -f "sync-to-template.sh" ] && rm -f sync-to-template.sh

    # Remove from .gitignore
    if [ -f ".gitignore" ]; then
        sed -i.bak "/^${INSTALL_DIR}\//d" .gitignore 2>/dev/null || true
        rm -f .gitignore.bak
    fi

    log_success "Framework uninstalled"
    echo ""
    echo "Backup saved at: $backup_dir"
    echo "To restore: mv $backup_dir $INSTALL_DIR"
}

# --- Uninstall mode ---
if $UNINSTALL_MODE; then
    _uninstall
    exit 0
fi

# --- Check mode ---
if $CHECK_ONLY; then
    if [ ! -d "$INSTALL_DIR" ]; then
        log_warn "Not installed (no $INSTALL_DIR directory)"
        exit 2
    fi

    # Show status
    log_success "Installed at: $INSTALL_DIR"

    # Show version
    if [ -d "$INSTALL_DIR/.git" ]; then
        cd "$INSTALL_DIR"
        current_tag=$(git describe --tags --exact-match 2>/dev/null || echo "none")
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        current_commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        cd - >/dev/null

        echo ""
        echo "  Version tag:  $current_tag"
        echo "  Branch:       $current_branch"
        echo "  Commit:       $current_commit"
    elif [ -f "$INSTALL_DIR/.version" ]; then
        echo ""
        echo "  Version:      $(cat "$INSTALL_DIR/.version")"
        echo "  Source:       Offline installation"
    fi

    # Show what's available
    echo ""
    echo "  Contents:"
    echo "    Agents:   $(find "$INSTALL_DIR/core/agents" "$INSTALL_DIR/packs" -name '*.md' -path '*/agents/*' 2>/dev/null | wc -l | tr -d ' ')"
    echo "    Skills:   $(find "$INSTALL_DIR/core/commands" "$INSTALL_DIR/packs" -name '*.md' -path '*/commands/*' 2>/dev/null | wc -l | tr -d ' ')"
    echo "    Scripts:  $(find "$INSTALL_DIR/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"

    # Validate
    echo ""
    _validate_install
    exit 0
fi

# --- Update mode ---
if $UPDATE_MODE; then
    if [ ! -d "$INSTALL_DIR/.git" ]; then
        log_error "$INSTALL_DIR is not a git repo. Run without --update to install first."
        exit 1
    fi

    log_info "Updating framework in $INSTALL_DIR..."
    cd "$INSTALL_DIR"

    git fetch --tags origin

    if [ -n "$VERSION" ]; then
        log_info "Checking out version $VERSION..."
        git checkout "$VERSION"
    else
        log_info "Pulling latest from main..."
        git checkout main 2>/dev/null || git checkout master
        git pull origin HEAD
    fi

    cd - >/dev/null
    log_success "Framework updated"

    # Optionally sync
    if $SYNC_TO_HOME; then
        log_info "Syncing to ~/.claude/..."
        _sync_to_home
    fi

    exit 0
fi

# --- Install mode ---

# Check if already installed
if [ -d "$INSTALL_DIR" ]; then
    if [ -d "$INSTALL_DIR/.git" ] || [ -f "$INSTALL_DIR/.version" ]; then
        log_warn "Already installed at $INSTALL_DIR"
        echo "  Use --update to update, or --check to see status"
        exit 0
    else
        log_warn "$INSTALL_DIR exists but is not a framework installation"
        echo "  Remove it first or use --dir to specify a different directory"
        exit 1
    fi
fi

check_prerequisites

echo ""
echo "=========================================="
echo "  claude-tastic Framework Setup"
echo "=========================================="
echo ""

if $OFFLINE_MODE; then
    # Offline installation
    if [ -z "$SOURCE_PATH" ]; then
        log_error "Offline mode requires --source <path>"
        exit 1
    fi

    log_info "Mode: Offline installation"
    log_info "Source: $SOURCE_PATH"
    log_info "Target: $INSTALL_DIR"
    echo ""

    _install_offline

else
    # Online installation
    log_info "Mode: Online installation"
    log_info "Installing to: $INSTALL_DIR"
    if [ -n "$VERSION" ]; then
        log_info "Version: $VERSION"
    else
        log_info "Version: latest (main branch)"
    fi
    echo ""

    # Clone the framework
    log_info "Cloning framework repository..."
    local clone_success=false
    local clone_err=""

    # Strategy 1: Try gh CLI first (handles auth for private repos)
    if ! $clone_success && command -v gh &>/dev/null; then
        log_info "Trying gh CLI clone (handles private repo auth)..."
        if clone_err=$(gh repo clone "$TEMPLATE_REPO" "$INSTALL_DIR" 2>&1); then
            clone_success=true
        else
            log_warn "gh clone failed: $clone_err"
        fi
    fi

    # Strategy 2: Try configured clone URL (SSH or HTTPS)
    if ! $clone_success; then
        log_info "Trying git clone ($( $USE_HTTPS && echo 'HTTPS' || echo 'SSH' ))..."
        if clone_err=$(git clone "$CLONE_URL" "$INSTALL_DIR" 2>&1); then
            clone_success=true
        else
            log_warn "Clone failed: $clone_err"
        fi
    fi

    # Strategy 3: If SSH failed, try HTTPS fallback
    if ! $clone_success && ! $USE_HTTPS; then
        log_info "Trying HTTPS fallback..."
        if clone_err=$(git clone "$TEMPLATE_URL_HTTPS" "$INSTALL_DIR" 2>&1); then
            clone_success=true
        else
            log_warn "HTTPS clone failed: $clone_err"
        fi
    fi

    # Strategy 4: Try HTTPS with GITHUB_TOKEN if available
    if ! $clone_success && [ -n "${GITHUB_TOKEN:-}" ]; then
        log_info "Trying HTTPS with GITHUB_TOKEN..."
        local token_url="https://${GITHUB_TOKEN}@github.com/${TEMPLATE_REPO}.git"
        if clone_err=$(git clone "$token_url" "$INSTALL_DIR" 2>&1); then
            clone_success=true
        else
            log_warn "Token-based clone failed: $clone_err"
        fi
    fi

    if ! $clone_success; then
        log_error "Failed to clone repository"
        echo ""
        echo "The repository may be private. Troubleshooting:"
        echo "  1. Install & auth gh CLI: gh auth login"
        echo "  2. Set GITHUB_TOKEN: export GITHUB_TOKEN=ghp_..."
        echo "  3. Check access: gh repo view $TEMPLATE_REPO"
        echo "  4. Check SSH keys: ssh -T git@github.com"
        echo "  5. Try: $0 --https"
        echo "  6. For air-gapped: use --offline --source <path>"
        exit 1
    fi
    log_success "Repository cloned"
fi

# Pin to version if specified (only for online installs)
if [ -n "$VERSION" ] && [ "$OFFLINE_MODE" = false ]; then
    log_info "Pinning to version $VERSION..."
    cd "$INSTALL_DIR"
    if git tag -l "$VERSION" | grep -q "$VERSION"; then
        git checkout "$VERSION" 2>/dev/null
        log_success "Pinned to $VERSION"
    else
        log_error "Version $VERSION not found"
        echo ""
        echo "Available versions:"
        git tag -l 'v*' | sort -V | tail -10
        cd - >/dev/null
        exit 1
    fi
    cd - >/dev/null
fi

# Write version marker (if not already done by offline install)
if [ ! -f "$INSTALL_DIR/.version" ]; then
    if [ -n "$VERSION" ]; then
        echo "$VERSION" > "$INSTALL_DIR/.version"
    elif [ -d "$INSTALL_DIR/.git" ]; then
        echo "main-$(cd "$INSTALL_DIR" && git rev-parse --short HEAD)" > "$INSTALL_DIR/.version"
    fi
fi

# Install sync-to-template script if available
if [ -f "$INSTALL_DIR/.claude/sync-to-template.sh" ]; then
    cp "$INSTALL_DIR/.claude/sync-to-template.sh" ./sync-to-template.sh
    chmod +x ./sync-to-template.sh
    log_success "Installed sync-to-template.sh"
fi

# Add to .gitignore
if [ -f ".gitignore" ]; then
    if ! grep -q "^${INSTALL_DIR}/" .gitignore 2>/dev/null; then
        echo "" >> .gitignore
        echo "# Claude-tastic framework (managed separately)" >> .gitignore
        echo "${INSTALL_DIR}/" >> .gitignore
        log_success "Added $INSTALL_DIR/ to .gitignore"
    fi
else
    cat > .gitignore <<EOF
# Claude-tastic framework (managed separately)
${INSTALL_DIR}/
EOF
    log_success "Created .gitignore with $INSTALL_DIR/"
fi

# Detect existing repo and run onboarding flow
_detect_and_onboard() {
    log_info "Checking for existing repository assets..."

    # Check for signals of existing repo
    local is_existing=false
    [ -f "CLAUDE.md" ] && is_existing=true
    [ -d ".claude/agents" ] && is_existing=true
    [ -d "src" ] || [ -d "lib" ] || [ -d "app" ] && is_existing=true
    [ -d "tests" ] || [ -d "__tests__" ] && is_existing=true

    if [ "$is_existing" = true ]; then
        echo ""
        log_warn "Existing repository detected"
        echo ""
        echo "This repository appears to have existing code, configuration, or framework assets."
        echo "The framework will run discovery and reconciliation to avoid overwriting your work."
        echo ""

        # Run discovery
        if [ -f "$INSTALL_DIR/scripts/discover-existing-repo.sh" ]; then
            log_info "Running discovery analysis..."
            "$INSTALL_DIR/scripts/discover-existing-repo.sh" || {
                log_warn "Discovery failed, continuing with standard setup"
                return 1
            }

            # Show discovery summary
            if [ -f ".claude-tastic-discovery.json" ]; then
                echo ""
                log_info "Discovery complete. Review: cat .claude-tastic-discovery.json"
                echo ""

                # Prompt for onboarding
                if [ "$INTERACTIVE" = true ]; then
                    read -p "Run onboarding flow for conflict resolution? [y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        if [ -f "$INSTALL_DIR/scripts/onboard-existing-repo.sh" ]; then
                            log_info "Starting onboarding flow..."
                            "$INSTALL_DIR/scripts/onboard-existing-repo.sh" || {
                                log_error "Onboarding failed"
                                echo ""
                                echo "To retry: $INSTALL_DIR/scripts/onboard-existing-repo.sh"
                                echo "To rollback: $INSTALL_DIR/scripts/rollback-claude-tastic.sh"
                                return 1
                            }
                            # Skip standard config flow if onboarding succeeded
                            return 0
                        fi
                    else
                        log_info "Skipping onboarding — you can run it later:"
                        echo "  $INSTALL_DIR/scripts/onboard-existing-repo.sh"
                    fi
                else
                    log_info "Non-interactive mode — skipping onboarding"
                    echo "  Run onboarding manually: $INSTALL_DIR/scripts/onboard-existing-repo.sh"
                fi
            fi
        fi
    fi

    # Return 1 to indicate standard config flow should run
    return 1
}

# Try onboarding flow for existing repos
_detect_and_onboard || {
    # Standard configuration flow for new repos
    log_info "Step 2/5: Running configuration..."
    _run_config_flow
}

# Setup network gateway (Child C)
log_info "Step 3/5: Setting up network gateway..."
_setup_network_gateway

# Sync to home if requested
if $SYNC_TO_HOME; then
    log_info "Step 4/5: Syncing to ~/.claude/..."
    _sync_to_home
else
    log_info "Step 4/5: Skipping sync to ~/.claude/ (use --sync to enable)"
fi

# Validate installation
log_info "Step 5/5: Validating installation..."
if ! _validate_install; then
    log_error "Installation validation failed"
    exit 1
fi

# Run tests if requested
if $RUN_TESTS; then
    echo ""
    log_info "Running end-to-end tests..."
    if [ -f "$INSTALL_DIR/tests/test-framework-deployment.sh" ]; then
        "$INSTALL_DIR/tests/test-framework-deployment.sh"
    else
        log_warn "Test script not found, skipping"
    fi
fi

# Summary
echo ""
echo "=========================================="
echo "  Setup Complete"
echo "=========================================="
echo ""
echo "  Installed at:     $INSTALL_DIR"
echo "  Version:          $(cat "$INSTALL_DIR/.version")"
echo "  Config version:   $FRAMEWORK_CONFIG_VERSION"
echo ""
echo "  Next steps:"
echo "    1. Start Claude Code in your project"
echo "    2. Agents and skills are available automatically"
echo "    3. Run /skill-sync to update ~/.claude/ anytime"
echo ""
echo "  Useful commands:"
echo "    $0 --check       # Verify installation"
echo "    $0 --update      # Pull latest changes"
echo "    $0 --uninstall   # Remove installation"
echo "    ./sync-to-template.sh  # Sync improvements back"
echo ""
echo "  Documentation:"
echo "    $INSTALL_DIR/docs/CONSUMER-QUICKSTART.md"
echo "    $INSTALL_DIR/docs/DEPLOYMENT-METHODS.md"
echo "    $INSTALL_DIR/docs/VERSIONING-STRATEGY.md"
echo ""
