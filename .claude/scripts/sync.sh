#!/bin/bash
set -euo pipefail

# Claude Configs Sync Script
# Syncs configurations between this repo and ~/.claude/
# Supports pack-based architecture with core + packs + domains
# NOW INTEGRATED with sync-configs.sh for unified sync system (Feature #517)
# size-ok: pack-based sync with core, packs, domains, and conflict resolution

set -e

# Get repo root (parent of scripts/)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
CLAUDE_DIR="$HOME/.claude"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Aliases for print_* naming convention
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN:-}✓${NC:-} $1"; }
print_warning() { log_warn "$@"; }
print_error() { log_error "$@"; }

# List available packs
list_packs() {
    print_info "Available packs:"
    for pack_dir in "$REPO_DIR"/packs/*/; do
        if [ -d "$pack_dir" ]; then
            pack=$(basename "$pack_dir")
            count=$(find "$pack_dir/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $pack ($count agents)"
        fi
    done
}

# List available domains
list_domains() {
    print_info "Available domains:"
    for domain_dir in "$REPO_DIR"/domains/*/; do
        if [ -d "$domain_dir" ]; then
            domain=$(basename "$domain_dir")
            count=$(find "$domain_dir/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $domain ($count agents)"
        fi
    done
}

# Sync agents from a directory (recursively, copying flat to agents/)
sync_agents() {
    local src_dir="$1"
    local label="$2"

    if [ -d "$src_dir" ]; then
        local count=$(find "$src_dir" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            # Use find to recursively discover all .md files in subdirectories
            # and copy them flat into $CLAUDE_DIR/agents/
            while IFS= read -r agent_file; do
                cp "$agent_file" "$CLAUDE_DIR/agents/" 2>/dev/null || true
            done < <(find "$src_dir" -name "*.md" -type f)
            print_success "Synced $label ($count agents)"
        fi
    fi
}

# Install: Copy from repo to ~/.claude/
# Usage: install [packs...] [domains...]
# Special values: all, standard, minimal
install() {
    local args=("$@")
    local install_packs=()
    local install_domains=()

    # Parse arguments
    for arg in "${args[@]}"; do
        if [ -d "$REPO_DIR/packs/$arg" ]; then
            install_packs+=("$arg")
        elif [ -d "$REPO_DIR/domains/$arg" ]; then
            install_domains+=("$arg")
        elif [ "$arg" = "all" ]; then
            # All packs and domains
            for pack_dir in "$REPO_DIR"/packs/*/; do
                [ -d "$pack_dir" ] && install_packs+=("$(basename "$pack_dir")")
            done
            for domain_dir in "$REPO_DIR"/domains/*/; do
                [ -d "$domain_dir" ] && install_domains+=("$(basename "$domain_dir")")
            done
        elif [ "$arg" = "standard" ]; then
            install_packs=("specs" "quality" "data" "security" "devops")
        elif [ "$arg" = "minimal" ]; then
            install_packs=()
        else
            print_warning "Unknown pack/domain: $arg"
        fi
    done

    print_info "Installing Claude configs to ~/.claude/..."

    # Create directories
    mkdir -p "$CLAUDE_DIR/agents"
    mkdir -p "$CLAUDE_DIR/commands"
    mkdir -p "$CLAUDE_DIR/skills"

    # Always install core
    print_info "Installing core agents..."
    sync_agents "$REPO_DIR/core/agents" "core"

    # Install global CLAUDE.md (security gatekeeper - loads before project CLAUDE.md)
    if [ -f "$REPO_DIR/core/CLAUDE.md" ]; then
        if [ -f "$CLAUDE_DIR/CLAUDE.md" ]; then
            print_warning "Global CLAUDE.md already exists, backing up to CLAUDE.md.bak"
            cp "$CLAUDE_DIR/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md.bak"
        fi
        cp "$REPO_DIR/core/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
        print_success "Installed global CLAUDE.md (security gatekeeper)"
    fi

    # Install core commands/skills
    if [ -d "$REPO_DIR/core/commands" ]; then
        cp -r "$REPO_DIR/core/commands/"* "$CLAUDE_DIR/commands/" 2>/dev/null || true
    fi
    if [ -d "$REPO_DIR/core/skills" ]; then
        cp -r "$REPO_DIR/core/skills/"* "$CLAUDE_DIR/skills/" 2>/dev/null || true
    fi

    # Install selected packs
    for pack in "${install_packs[@]}"; do
        print_info "Installing $pack pack..."
        sync_agents "$REPO_DIR/packs/$pack/agents" "$pack"

        # Pack commands/skills
        if [ -d "$REPO_DIR/packs/$pack/commands" ]; then
            cp -r "$REPO_DIR/packs/$pack/commands/"* "$CLAUDE_DIR/commands/" 2>/dev/null || true
        fi
        if [ -d "$REPO_DIR/packs/$pack/skills" ]; then
            cp -r "$REPO_DIR/packs/$pack/skills/"* "$CLAUDE_DIR/skills/" 2>/dev/null || true
        fi
    done

    # Install selected domains
    for domain in "${install_domains[@]}"; do
        print_info "Installing $domain domain..."
        sync_agents "$REPO_DIR/domains/$domain/agents" "$domain"

        # Domain commands/skills
        if [ -d "$REPO_DIR/domains/$domain/commands" ]; then
            cp -r "$REPO_DIR/domains/$domain/commands/"* "$CLAUDE_DIR/commands/" 2>/dev/null || true
        fi
        if [ -d "$REPO_DIR/domains/$domain/skills" ]; then
            cp -r "$REPO_DIR/domains/$domain/skills/"* "$CLAUDE_DIR/skills/" 2>/dev/null || true
        fi
    done

    # Install GitHub convention tools
    print_info "Installing GitHub convention tools..."
    mkdir -p "$CLAUDE_DIR/scripts"

    # Copy validation scripts
    if [ -f "$REPO_DIR/scripts/validate/validate-github-conventions.sh" ]; then
        cp "$REPO_DIR/scripts/validate/validate-github-conventions.sh" "$CLAUDE_DIR/scripts/"
        chmod +x "$CLAUDE_DIR/scripts/validate/validate-github-conventions.sh"
    fi

    if [ -f "$REPO_DIR/scripts/init-github-conventions.sh" ]; then
        cp "$REPO_DIR/scripts/init-github-conventions.sh" "$CLAUDE_DIR/scripts/"
        chmod +x "$CLAUDE_DIR/scripts/init-github-conventions.sh"
    fi

    if [ -f "$REPO_DIR/scripts/repo-init.sh" ]; then
        cp "$REPO_DIR/scripts/repo-init.sh" "$CLAUDE_DIR/scripts/"
        chmod +x "$CLAUDE_DIR/scripts/repo-init.sh"
    fi

    # Copy GitHub issue templates (for downstream projects)
    if [ -d "$REPO_DIR/.github/ISSUE_TEMPLATE" ]; then
        mkdir -p "$CLAUDE_DIR/.github/ISSUE_TEMPLATE"
        cp -r "$REPO_DIR/.github/ISSUE_TEMPLATE/"* "$CLAUDE_DIR/.github/ISSUE_TEMPLATE/" 2>/dev/null || true
        print_success "GitHub issue templates installed"
    fi

    print_success "GitHub convention tools installed"

    # Summary
    local total=$(find "$CLAUDE_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    print_success "Installation complete! ($total agents installed)"
    print_warning "Restart Claude Code to apply changes."
}

# Status: Show what's installed
status() {
    print_info "Claude Agent Framework Status"
    echo ""

    print_info "Repository: $REPO_DIR"
    print_info "Claude directory: $CLAUDE_DIR"
    echo ""

    # Core
    local core_count=$(find "$REPO_DIR/core/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "Core: $core_count agents"

    # Packs
    print_info "Packs:"
    for pack_dir in "$REPO_DIR"/packs/*/; do
        if [ -d "$pack_dir" ]; then
            pack=$(basename "$pack_dir")
            count=$(find "$pack_dir/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  $pack: $count agents"
        fi
    done

    # Domains
    print_info "Domains:"
    for domain_dir in "$REPO_DIR"/domains/*/; do
        if [ -d "$domain_dir" ]; then
            domain=$(basename "$domain_dir")
            count=$(find "$domain_dir/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
            echo "  $domain: $count agents"
        fi
    done

    # Installed
    echo ""
    print_info "Installed in ~/.claude/:"
    local installed=$(find "$CLAUDE_DIR/agents" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
    echo "  agents: $installed"
}

# Pull latest and reinstall
pull() {
    local args=("$@")

    print_info "Pulling latest changes from GitHub..."
    cd "$REPO_DIR"
    git pull origin main

    print_info "Re-installing..."
    install "${args[@]}"

    # Run sync-configs.sh if available for unified sync
    if [ -f "${SCRIPT_DIR}/sync-configs.sh" ]; then
        print_info "Running configuration sync..."
        "${SCRIPT_DIR}/sync-configs.sh" --auto || print_warning "Config sync encountered issues"
    fi
}

# Interactive mode
interactive() {
    echo ""
    print_info "Claude Agent Framework"
    echo ""
    echo "1) Interactive Setup (wizard)"
    echo "2) Quick Install (standard packs)"
    echo "3) Install All"
    echo "4) Status"
    echo "5) List Packs & Domains"
    echo "6) Pull Latest"
    echo "7) Exit"
    echo ""
    read -p "Select option: " choice

    case $choice in
        1) "$SCRIPT_DIR/setup.sh" ;;
        2) install standard ;;
        3) install all ;;
        4) status ;;
        5)
            list_packs
            echo ""
            list_domains
            ;;
        6) pull standard ;;
        7) exit 0 ;;
        *) print_error "Invalid option" ;;
    esac
}

# Show help
show_help() {
    echo "Usage: $0 <command> [packs/domains...]"
    echo ""
    echo "Commands:"
    echo "  install [items]  - Install core + specified packs/domains"
    echo "  pull [items]     - Pull from GitHub and reinstall"
    echo "  status           - Show installation status"
    echo "  packs            - List available packs"
    echo "  domains          - List available domains"
    echo "  setup            - Run interactive setup wizard"
    echo "  (no args)        - Interactive menu"
    echo ""
    echo "Special values:"
    echo "  all              - All packs and domains"
    echo "  standard         - Standard packs (specs, quality, data, security, devops)"
    echo "  minimal          - Core only (no packs)"
    echo ""
    echo "Examples:"
    echo "  $0 install                      # Core only"
    echo "  $0 install standard             # Core + standard packs"
    echo "  $0 install quality security     # Core + specific packs"
    echo "  $0 install standard finance     # Standard + finance domain"
    echo "  $0 install all                  # Everything"
    echo "  $0 setup                        # Interactive wizard"
}

# Main
case "${1:-}" in
    install)
        shift
        install "$@"
        ;;
    pull)
        shift
        pull "$@"
        ;;
    status)
        status
        ;;
    packs)
        list_packs
        ;;
    domains)
        list_domains
        ;;
    setup)
        "$SCRIPT_DIR/setup.sh"
        ;;
    --help|-h)
        show_help
        ;;
    *)
        interactive
        ;;
esac
