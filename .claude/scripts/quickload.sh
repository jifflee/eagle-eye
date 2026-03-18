#!/usr/bin/env bash
#
# quickload.sh
# External quickloader for deploying the claude-agents framework onto any owned repo.
# Implements Feature #1232 — callable via raw GitHub URL (curl-pipe-bash pattern).
#
# Usage (remote):
#   curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash
#   curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --update
#   curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --init
#   curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --check
#   curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --version v1.2.0
#
# Usage (local):
#   ./scripts/quickload.sh           # Auto-detect init or update
#   ./scripts/quickload.sh --init    # Force init mode
#   ./scripts/quickload.sh --update  # Force update mode
#   ./scripts/quickload.sh --check   # Preview changes (dry-run)
#   ./scripts/quickload.sh --version TAG  # Pin to specific version
#   ./scripts/quickload.sh --non-interactive  # Skip prompts, use defaults
#
# Auto-detection:
#   - If .claude/ exists with .manifest.json or agents/ → UPDATE mode
#   - Otherwise → INIT mode
#
# Exit codes:
#   0 - Success
#   1 - Error
#   2 - Already up to date (update mode, no changes)

set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────

FRAMEWORK_REPO="jifflee/claude-tastic"
FRAMEWORK_BRANCH="main"
FRAMEWORK_URL_HTTPS="https://github.com/${FRAMEWORK_REPO}.git"
FRAMEWORK_DIR_DEFAULT="$HOME/Repos/claude-agents"
QUICKLOAD_VERSION="1.0.0"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${BOLD}▶ $*${NC}"; }

# ─── Argument Parsing ──────────────────────────────────────────────────────────

MODE=""           # "" = auto-detect, "init", "update"
VERSION_TAG=""
CHECK_MODE=false
NON_INTERACTIVE=false
FRAMEWORK_DIR=""
SKIP_LABELS=false
SKIP_MILESTONE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --init)
            MODE="init"
            shift
            ;;
        --update)
            MODE="update"
            shift
            ;;
        --check|--dry-run)
            CHECK_MODE=true
            shift
            ;;
        --version)
            VERSION_TAG="${2:-}"
            shift; shift
            ;;
        --framework-dir)
            FRAMEWORK_DIR="${2:-}"
            shift; shift
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            shift
            ;;
        --skip-labels)
            SKIP_LABELS=true
            shift
            ;;
        --skip-milestone)
            SKIP_MILESTONE=true
            shift
            ;;
        --help|-h)
            cat <<'USAGE'
quickload.sh — Claude Agent Framework quickloader

USAGE (remote):
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- [OPTIONS]

USAGE (local):
  ./scripts/quickload.sh [OPTIONS]

OPTIONS:
  (no flags)              Auto-detect: init if new repo, update if framework exists
  --init                  Force init mode (first-time deployment)
  --update                Force update mode (pull latest framework changes)
  --check                 Dry-run: preview changes without applying
  --version TAG           Pin to a specific version tag (e.g., v1.2.0)
  --framework-dir PATH    Use a local framework source instead of cloning
  --non-interactive       Skip all prompts, use sensible defaults
  --skip-labels           Skip creating GitHub labels (init mode)
  --skip-milestone        Skip creating initial milestone (init mode)
  --help                  Show this help

EXAMPLES:
  # One-liner deploy to a new repo:
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash

  # Update an existing deployment:
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --update

  # Preview what would change (no writes):
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --check

  # Pin to a specific version:
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --version v1.2.0

  # Non-interactive (CI/automation):
  curl -sSL https://raw.githubusercontent.com/jifflee/claude-tastic/main/scripts/quickload.sh | bash -s -- --non-interactive

DETECTION LOGIC:
  Framework is considered "installed" if any of these exist:
    - .claude/.manifest.json
    - .claude/agents/  (non-empty)
    - .claude-tastic.config.yml

USAGE
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            echo "Run with --help for usage information."
            exit 1
            ;;
    esac
done

# ─── Banner ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       Claude Agent Framework — Quickloader v${QUICKLOAD_VERSION}    ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

# ─── Prerequisites ─────────────────────────────────────────────────────────────

check_prerequisites() {
    log_step "Checking prerequisites"
    local missing=()

    command -v git &>/dev/null || missing+=("git")
    command -v jq  &>/dev/null || missing+=("jq")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        echo "Install missing tools:"
        for tool in "${missing[@]}"; do
            case "$tool" in
                git)
                    echo "  git:  macOS: xcode-select --install | Linux: sudo apt install git" ;;
                jq)
                    echo "  jq:   macOS: brew install jq       | Linux: sudo apt install jq" ;;
            esac
        done
        exit 1
    fi

    # gh CLI: optional but helpful
    if ! command -v gh &>/dev/null; then
        log_warn "gh CLI not found — GitHub labels/milestones will be skipped"
        log_warn "Install: https://cli.github.com/"
        SKIP_LABELS=true
        SKIP_MILESTONE=true
    elif ! gh auth status &>/dev/null 2>&1; then
        log_warn "gh CLI not authenticated — GitHub labels/milestones will be skipped"
        log_warn "Run: gh auth login"
        SKIP_LABELS=true
        SKIP_MILESTONE=true
    fi

    # Must be inside a git repo
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        log_error "Not inside a git repository."
        echo "  cd into your target repo first, then re-run."
        exit 1
    fi

    log_ok "Prerequisites satisfied"
}

# ─── Framework Detection ───────────────────────────────────────────────────────

detect_mode() {
    if [[ -n "$MODE" ]]; then
        log_info "Mode forced: ${MODE}"
        return
    fi

    log_step "Auto-detecting mode"

    local framework_present=false

    # Check for installed framework markers
    if [[ -f ".claude/.manifest.json" ]]; then
        log_info "Detected: .claude/.manifest.json → framework installed"
        framework_present=true
    elif [[ -d ".claude/agents" ]] && [[ -n "$(ls -A .claude/agents 2>/dev/null)" ]]; then
        log_info "Detected: .claude/agents/ (non-empty) → framework installed"
        framework_present=true
    elif [[ -f ".claude-tastic.config.yml" ]]; then
        log_info "Detected: .claude-tastic.config.yml → framework installed"
        framework_present=true
    fi

    if $framework_present; then
        MODE="update"
        log_ok "Mode: UPDATE (framework already deployed)"
    else
        MODE="init"
        log_ok "Mode: INIT (fresh deployment)"
    fi
}

# ─── Framework Source ──────────────────────────────────────────────────────────

locate_or_clone_framework() {
    log_step "Locating framework source"

    # Priority 1: Explicit --framework-dir flag
    if [[ -n "$FRAMEWORK_DIR" ]]; then
        if [[ -d "$FRAMEWORK_DIR/core/agents" ]]; then
            log_ok "Using provided framework dir: $FRAMEWORK_DIR"
            return 0
        else
            log_error "--framework-dir '$FRAMEWORK_DIR' does not contain core/agents/"
            exit 1
        fi
    fi

    # Priority 2: CLAUDE_FRAMEWORK_DIR env var
    if [[ -n "${CLAUDE_FRAMEWORK_DIR:-}" ]] && [[ -d "${CLAUDE_FRAMEWORK_DIR}/core/agents" ]]; then
        FRAMEWORK_DIR="$CLAUDE_FRAMEWORK_DIR"
        log_ok "Using \$CLAUDE_FRAMEWORK_DIR: $FRAMEWORK_DIR"
        return 0
    fi

    # Priority 3: .claude-sync/ (installed by load-claude-tastic.sh)
    if [[ -d ".claude-sync/core/agents" ]]; then
        FRAMEWORK_DIR="$(pwd)/.claude-sync"
        log_ok "Using .claude-sync/: $FRAMEWORK_DIR"
        return 0
    fi

    # Priority 4: ~/Repos/claude-agents (developer checkout)
    if [[ -d "$FRAMEWORK_DIR_DEFAULT/core/agents" ]]; then
        FRAMEWORK_DIR="$FRAMEWORK_DIR_DEFAULT"
        log_ok "Using ~/Repos/claude-agents: $FRAMEWORK_DIR"
        return 0
    fi

    # Fallback: Clone from GitHub
    log_info "Framework not found locally — cloning from GitHub..."
    _clone_framework "$FRAMEWORK_DIR_DEFAULT"
    FRAMEWORK_DIR="$FRAMEWORK_DIR_DEFAULT"
}

_clone_framework() {
    local target="$1"
    local clone_ok=false
    local clone_err=""

    mkdir -p "$(dirname "$target")"

    # Try gh CLI first (handles private repo auth)
    if command -v gh &>/dev/null; then
        log_info "Trying gh repo clone..."
        if clone_err=$(gh repo clone "$FRAMEWORK_REPO" "$target" 2>&1); then
            clone_ok=true
        else
            log_warn "gh clone failed: $clone_err"
        fi
    fi

    # Fallback: HTTPS clone
    if ! $clone_ok; then
        log_info "Trying HTTPS clone..."
        if clone_err=$(git clone "$FRAMEWORK_URL_HTTPS" "$target" 2>&1); then
            clone_ok=true
        else
            log_warn "HTTPS clone failed: $clone_err"
        fi
    fi

    # Fallback: HTTPS with GITHUB_TOKEN
    if ! $clone_ok && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        log_info "Trying HTTPS with GITHUB_TOKEN..."
        local token_url="https://${GITHUB_TOKEN}@github.com/${FRAMEWORK_REPO}.git"
        if clone_err=$(git clone "$token_url" "$target" 2>&1); then
            clone_ok=true
        else
            log_warn "Token clone failed: $clone_err"
        fi
    fi

    if ! $clone_ok; then
        log_error "Failed to clone framework repository."
        echo ""
        echo "Troubleshooting:"
        echo "  1. Authenticate gh CLI:   gh auth login"
        echo "  2. Set GITHUB_TOKEN:      export GITHUB_TOKEN=ghp_..."
        echo "  3. Manual clone:          git clone $FRAMEWORK_URL_HTTPS $target"
        echo "  4. Set env var:           export CLAUDE_FRAMEWORK_DIR=/path/to/framework"
        exit 1
    fi

    log_ok "Framework cloned to: $target"
}

_update_framework_source() {
    log_info "Updating framework source at: $FRAMEWORK_DIR"

    if [[ ! -d "$FRAMEWORK_DIR/.git" ]]; then
        log_warn "Framework source is not a git repo (offline install?) — skipping pull"
        return 0
    fi

    local original_dir="$PWD"
    cd "$FRAMEWORK_DIR"

    git fetch origin --tags --quiet 2>/dev/null || {
        log_warn "Could not fetch from origin (offline?) — using cached source"
        cd "$original_dir"
        return 0
    }

    if [[ -n "$VERSION_TAG" ]]; then
        log_info "Checking out version: $VERSION_TAG"
        if ! git checkout "$VERSION_TAG" --quiet 2>/dev/null; then
            log_error "Version tag '$VERSION_TAG' not found."
            echo ""
            echo "Available tags:"
            git tag -l 'v*' | sort -V | tail -10
            cd "$original_dir"
            exit 1
        fi
    else
        log_info "Pulling latest from ${FRAMEWORK_BRANCH}..."
        git checkout "$FRAMEWORK_BRANCH" --quiet 2>/dev/null || \
            git checkout master --quiet 2>/dev/null || true
        git pull origin HEAD --quiet 2>/dev/null || \
            log_warn "Pull failed — using current local state"
    fi

    CURRENT_FRAMEWORK_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)
    cd "$original_dir"
    log_ok "Framework source at version: $CURRENT_FRAMEWORK_VERSION"
}

# ─── Manifest ─────────────────────────────────────────────────────────────────

regenerate_manifest() {
    if [[ -f "$FRAMEWORK_DIR/scripts/generate-manifest.sh" ]]; then
        log_info "Regenerating manifest..."
        "$FRAMEWORK_DIR/scripts/generate-manifest.sh" 2>/dev/null || \
            log_warn "generate-manifest.sh failed — continuing with existing manifest"
    else
        log_warn "generate-manifest.sh not found — skipping manifest regeneration"
    fi
}

# ─── Init Mode ─────────────────────────────────────────────────────────────────

run_init() {
    log_step "Deploying framework (INIT mode)"

    if $CHECK_MODE; then
        log_info "[DRY-RUN] Would deploy framework from: $FRAMEWORK_DIR"
        log_info "[DRY-RUN] Would create: .claude/agents/, .claude/commands/, .claude/hooks/"
        log_info "[DRY-RUN] Would create: .claude/settings.json, .claude/.manifest.json"
        [[ "$SKIP_LABELS"    == false ]] && log_info "[DRY-RUN] Would create standard GitHub labels"
        [[ "$SKIP_MILESTONE" == false ]] && log_info "[DRY-RUN] Would create initial milestone"
        echo ""
        log_ok "Dry-run complete. Re-run without --check to apply."
        return 0
    fi

    # Deploy via manifest-sync
    if [[ -f "$FRAMEWORK_DIR/scripts/manifest-sync.sh" ]]; then
        log_info "Running manifest-sync (force deploy)..."
        "$FRAMEWORK_DIR/scripts/manifest-sync.sh" --target ".claude/" --force
        log_ok "Framework files deployed"
    else
        log_error "manifest-sync.sh not found at $FRAMEWORK_DIR/scripts/"
        exit 1
    fi

    # Create .claude/settings.json if missing
    _ensure_settings_json

    # Update .gitignore
    _update_gitignore

    # Generate/merge CLAUDE.md
    _ensure_claude_md

    # GitHub setup (labels + milestone) via init-repo.sh
    if [[ "$SKIP_LABELS" == false ]] || [[ "$SKIP_MILESTONE" == false ]]; then
        _run_github_init
    fi

    echo ""
    log_ok "Init complete!"
    _show_init_summary
}

# ─── Update Mode ───────────────────────────────────────────────────────────────

run_update() {
    log_step "Updating framework (UPDATE mode)"

    local target_dir=".claude/"

    if [[ ! -d "$target_dir" ]]; then
        log_error ".claude/ not found — cannot update. Run without --update to do a fresh init."
        exit 1
    fi

    # Get current installed version
    local prev_version="unknown"
    if [[ -f ".claude/.manifest.json" ]]; then
        prev_version=$(jq -r '.framework_version // "unknown"' .claude/.manifest.json 2>/dev/null || echo "unknown")
    fi

    if $CHECK_MODE; then
        log_info "Current installed version: $prev_version"
        if [[ -f "$FRAMEWORK_DIR/scripts/manifest-sync.sh" ]]; then
            log_info "[DRY-RUN] Running manifest-sync in check mode..."
            "$FRAMEWORK_DIR/scripts/manifest-sync.sh" --target "$target_dir" --check || true
        else
            log_warn "[DRY-RUN] manifest-sync.sh not found — cannot show diff"
        fi
        echo ""
        log_ok "Dry-run complete. Re-run without --check to apply."
        return 0
    fi

    # Apply sync
    if [[ -f "$FRAMEWORK_DIR/scripts/manifest-sync.sh" ]]; then
        log_info "Running manifest-sync..."
        "$FRAMEWORK_DIR/scripts/manifest-sync.sh" --target "$target_dir"
        log_ok "Framework files updated"
    else
        log_error "manifest-sync.sh not found at $FRAMEWORK_DIR/scripts/"
        exit 1
    fi

    # Refresh settings.json hooks if it was missing
    _ensure_settings_json

    echo ""
    log_ok "Update complete!"
    _show_update_summary "$prev_version"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

_ensure_settings_json() {
    local settings=".claude/settings.json"
    if [[ ! -f "$settings" ]]; then
        mkdir -p .claude
        cat > "$settings" << 'SETTINGS'
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
        log_ok "Created .claude/settings.json with standard hooks"
    else
        log_info ".claude/settings.json already exists (not overwriting)"
    fi
}

_update_gitignore() {
    local gitignore=".gitignore"

    # Entries to ensure are present
    local entries=(
        ".claude/.manifest.json"
    )

    for entry in "${entries[@]}"; do
        if [[ ! -f "$gitignore" ]] || ! grep -qF "$entry" "$gitignore" 2>/dev/null; then
            echo "$entry" >> "$gitignore"
            log_info "Added '$entry' to .gitignore"
        fi
    done
}

_ensure_claude_md() {
    if [[ -f "$FRAMEWORK_DIR/scripts/generate-claude-md.sh" ]]; then
        log_info "Generating/merging CLAUDE.md..."
        "$FRAMEWORK_DIR/scripts/generate-claude-md.sh" \
            --framework-dir "$FRAMEWORK_DIR" \
            --merge 2>/dev/null || \
            log_warn "generate-claude-md.sh failed — CLAUDE.md not updated"
    else
        log_warn "generate-claude-md.sh not found — skipping CLAUDE.md generation"
    fi
}

_run_github_init() {
    local init_script="$FRAMEWORK_DIR/scripts/init-repo.sh"

    if [[ ! -f "$init_script" ]]; then
        log_warn "init-repo.sh not found at $FRAMEWORK_DIR/scripts/ — skipping GitHub setup"
        return 0
    fi

    local extra_flags=()
    $NON_INTERACTIVE  && extra_flags+=("--non-interactive")
    $SKIP_LABELS      && extra_flags+=()   # init-repo.sh --all covers labels; no per-flag skip supported
    $SKIP_MILESTONE   && extra_flags+=()

    if $NON_INTERACTIVE; then
        log_info "Running init-repo.sh --all (non-interactive)..."
        "$init_script" --all "${extra_flags[@]}" 2>/dev/null || \
            log_warn "init-repo.sh exited with errors (GitHub setup may be partial)"
    else
        log_info "Running init-repo.sh --labels and --branch..."
        "$init_script" --labels 2>/dev/null || true
        "$init_script" --branch 2>/dev/null || true
    fi
}

_show_init_summary() {
    local agent_count cmd_count hook_count
    agent_count=$(find .claude/agents   -name '*.md'  2>/dev/null | wc -l | tr -d ' ')
    cmd_count=$(  find .claude/commands -name '*.md'  2>/dev/null | wc -l | tr -d ' ')
    hook_count=$(  find .claude/hooks   -type f        2>/dev/null | wc -l | tr -d ' ')

    echo ""
    echo "  ┌──────────────────────────────────────────────────┐"
    echo "  │  Framework Deployed                              │"
    echo "  ├──────────────────────────────────────────────────┤"
    printf "  │  %-20s  %-25s│\n" "Agents:"   "$agent_count files"
    printf "  │  %-20s  %-25s│\n" "Commands:" "$cmd_count files"
    printf "  │  %-20s  %-25s│\n" "Hooks:"    "$hook_count files"
    printf "  │  %-20s  %-25s│\n" "Source:"   "$(basename "$FRAMEWORK_DIR")"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  Next steps:"
    echo "    1. Open Claude Code in this repo"
    echo "    2. Agents and skills are now available"
    echo "    3. Create an issue:   gh issue create"
    echo "    4. Start sprinting:   /sprint:work-auto"
    echo ""
    echo "  To update later:"
    echo "    curl -sSL https://raw.githubusercontent.com/${FRAMEWORK_REPO}/main/scripts/quickload.sh | bash -s -- --update"
    echo ""
}

_show_update_summary() {
    local prev_version="${1:-unknown}"
    local new_version
    new_version=$(jq -r '.framework_version // "unknown"' .claude/.manifest.json 2>/dev/null || echo "unknown")

    echo "  ┌──────────────────────────────────────────────────┐"
    echo "  │  Framework Updated                               │"
    echo "  ├──────────────────────────────────────────────────┤"
    printf "  │  %-20s  %-25s│\n" "Previous:"  "$prev_version"
    printf "  │  %-20s  %-25s│\n" "Current:"   "$new_version"
    printf "  │  %-20s  %-25s│\n" "Source:"    "$(basename "$FRAMEWORK_DIR")"
    echo "  └──────────────────────────────────────────────────┘"
    echo ""
    echo "  Commit the changes:"
    echo "    git add .claude/"
    echo "    git commit -m \"chore: update claude-agents framework to ${new_version}\""
    echo "    git push"
    echo ""
}

# ─── Main ──────────────────────────────────────────────────────────────────────

main() {
    check_prerequisites
    detect_mode
    locate_or_clone_framework
    _update_framework_source
    regenerate_manifest

    case "$MODE" in
        init)   run_init   ;;
        update) run_update ;;
        *)
            log_error "Unknown mode: $MODE"
            exit 1
            ;;
    esac
}

main "$@"
