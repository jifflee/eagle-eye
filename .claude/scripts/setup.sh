#!/bin/bash
set -euo pipefail

# Claude Code Agent Framework - Interactive Setup
# Allows users to select which agent packs and domains to install
# size-ok: interactive setup wizard with pack selection and multi-platform support

set -e

# Get repo root
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
CLAUDE_DIR="$HOME/.claude"

# Source shared logging utilities
source "${SCRIPT_DIR}/lib/common.sh"

# Selected items
SELECTED_PACKS=()
SELECTED_DOMAINS=()

# Print functions
print_header() {
    clear
    echo -e "${BLUE:-}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         Claude Code Agent Framework - Setup Wizard           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC:-}"
}

print_section() {
    echo ""
    echo -e "${BLUE:-}$1${NC:-}"
    echo "────────────────────────────────────────────────────────────────"
}

# Aliases for print_* naming convention
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN:-}✓${NC:-}  $1"; }
print_warning() { log_warn "$@"; }

# Yes/No prompt
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n] "
    else
        prompt="$prompt [y/N] "
    fi

    read -p "$prompt" response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy]$ ]]
}

# Multi-select menu
multiselect() {
    local title="$1"
    shift
    local options=("$@")
    local selected=()
    local cursor=0
    local num_options=${#options[@]}

    # Initialize all as unselected
    for ((i=0; i<num_options; i++)); do
        selected+=("false")
    done

    # Parse options - format: "name|description|default"
    local names=()
    local descriptions=()
    for opt in "${options[@]}"; do
        IFS='|' read -r name desc default <<< "$opt"
        names+=("$name")
        descriptions+=("$desc")
        if [ "$default" = "true" ]; then
            selected[$((${#names[@]}-1))]="true"
        fi
    done

    while true; do
        # Clear and redraw
        echo -e "\n${BOLD}$title${NC}"
        echo -e "${CYAN}(Use UP/DOWN arrows, SPACE to toggle, ENTER to confirm)${NC}\n"

        for ((i=0; i<${#names[@]}; i++)); do
            local prefix="  "
            local checkbox="[ ]"

            if [ $i -eq $cursor ]; then
                prefix="${CYAN}► ${NC}"
            fi

            if [ "${selected[$i]}" = "true" ]; then
                checkbox="${GREEN}[✓]${NC}"
            fi

            echo -e "$prefix$checkbox ${BOLD}${names[$i]}${NC}"
            echo -e "      ${descriptions[$i]}"
        done

        # Read single keypress
        read -rsn1 key

        case "$key" in
            A) # Up arrow
                ((cursor--)) || true
                [ $cursor -lt 0 ] && cursor=$((num_options-1))
                ;;
            B) # Down arrow
                ((cursor++)) || true
                [ $cursor -ge $num_options ] && cursor=0
                ;;
            ' ') # Space - toggle
                if [ "${selected[$cursor]}" = "true" ]; then
                    selected[$cursor]="false"
                else
                    selected[$cursor]="true"
                fi
                ;;
            '') # Enter - confirm
                # Return selected items
                MULTISELECT_RESULT=()
                for ((i=0; i<${#names[@]}; i++)); do
                    if [ "${selected[$i]}" = "true" ]; then
                        MULTISELECT_RESULT+=("${names[$i]}")
                    fi
                done
                return
                ;;
        esac

        # Move cursor up to redraw
        for ((i=0; i<${#names[@]}*2+3; i++)); do
            echo -en "\033[A\033[K"
        done
    done
}

# Simple selection (arrow keys not working in all terminals)
simple_select() {
    local title="$1"
    shift
    local options=("$@")

    echo -e "\n${BOLD}$title${NC}\n"

    local names=()
    local descriptions=()
    local defaults=()

    for opt in "${options[@]}"; do
        IFS='|' read -r name desc default <<< "$opt"
        names+=("$name")
        descriptions+=("$desc")
        defaults+=("$default")
    done

    for ((i=0; i<${#names[@]}; i++)); do
        local marker=""
        if [ "${defaults[$i]}" = "true" ]; then
            marker="${GREEN}*${NC}"
        fi
        echo -e "  ${BOLD}$((i+1)))${NC} ${names[$i]} $marker"
        echo -e "      ${descriptions[$i]}"
    done

    echo ""
    echo -e "Enter numbers separated by spaces (e.g., '1 3 4')"
    echo -e "Items marked with ${GREEN}*${NC} are recommended"
    echo -e "Press ENTER for defaults, or 'none' for no selection"
    echo ""
    read -p "Selection: " input

    MULTISELECT_RESULT=()

    if [ -z "$input" ]; then
        # Use defaults
        for ((i=0; i<${#names[@]}; i++)); do
            if [ "${defaults[$i]}" = "true" ]; then
                MULTISELECT_RESULT+=("${names[$i]}")
            fi
        done
    elif [ "$input" = "none" ]; then
        MULTISELECT_RESULT=()
    else
        for num in $input; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -ge 1 ] && [ "$num" -le ${#names[@]} ]; then
                MULTISELECT_RESULT+=("${names[$((num-1))]}")
            fi
        done
    fi
}

# Project type selection
select_project_type() {
    print_section "Step 1: Project Type"

    echo "What type of project are you setting up?"
    echo ""
    echo "  1) Web Application (fullstack)"
    echo "  2) API/Backend Only"
    echo "  3) Frontend Only"
    echo "  4) CLI Tool"
    echo "  5) Data Pipeline"
    echo "  6) Custom (select everything manually)"
    echo ""
    read -p "Selection [1]: " choice
    choice=${choice:-1}

    case $choice in
        1) # Fullstack
            SELECTED_PACKS=("specs" "quality" "data" "security" "devops" "docs")
            ;;
        2) # Backend
            SELECTED_PACKS=("specs" "quality" "data" "security" "devops")
            ;;
        3) # Frontend
            SELECTED_PACKS=("specs" "quality" "docs")
            ;;
        4) # CLI
            SELECTED_PACKS=("specs" "quality" "devops")
            ;;
        5) # Data Pipeline
            SELECTED_PACKS=("specs" "data" "quality" "devops")
            ;;
        6) # Custom
            SELECTED_PACKS=()
            ;;
    esac
}

# Pack selection
select_packs() {
    print_section "Step 2: Agent Packs"

    echo -e "${YELLOW}Core agents (5) are always installed:${NC}"
    echo "  pm-orchestrator, architect, backend-developer, frontend-developer, test-qa"
    echo ""

    if [ ${#SELECTED_PACKS[@]} -gt 0 ]; then
        echo -e "Based on your project type, these packs are pre-selected:"
        for pack in "${SELECTED_PACKS[@]}"; do
            echo -e "  ${GREEN}✓${NC} $pack"
        done
        echo ""
        if confirm "Keep these selections?"; then
            return
        fi
        SELECTED_PACKS=()
    fi

    simple_select "Select agent packs to install:" \
        "specs|Requirements, specs, API design (2 agents)|true" \
        "quality|Code review, bug analysis, refactoring (3 agents)|true" \
        "data|Database design and migrations (2 agents)|true" \
        "security|Security design and pre-PR review (2 agents)|true" \
        "devops|CI/CD, deployment, dependencies (3 agents)|true" \
        "docs|Documentation writing and maintenance (2 agents)|false" \
        "pr-review|Formal PR review agents (4 agents)|false" \
        "governance|Standards enforcement, repo workflow (3 agents)|false"

    SELECTED_PACKS=("${MULTISELECT_RESULT[@]}")
}

# Domain selection
select_domains() {
    print_section "Step 3: Specialized Domains"

    echo "Domains add industry-specific agents."
    echo ""

    simple_select "Select domains (optional):" \
        "finance|Options trading, portfolio management, fintech (4 agents)|false" \
        "ecommerce|E-commerce platform (scaffold - coming soon)|false"

    SELECTED_DOMAINS=("${MULTISELECT_RESULT[@]}")
}

# Advanced options
select_advanced() {
    print_section "Step 4: Advanced Options"

    if confirm "Include PR review agents?" "n"; then
        if [[ ! " ${SELECTED_PACKS[*]} " =~ " pr-review " ]]; then
            SELECTED_PACKS+=("pr-review")
        fi
    fi

    if confirm "Include governance agents (guardrails, repo workflow)?" "n"; then
        if [[ ! " ${SELECTED_PACKS[*]} " =~ " governance " ]]; then
            SELECTED_PACKS+=("governance")
        fi
    fi
}

# Summary and confirmation
show_summary() {
    print_section "Installation Summary"

    # Count agents
    local core_count=5
    local pack_count=0
    local domain_count=0

    echo -e "${GREEN}CORE (always installed):${NC}"
    echo "  pm-orchestrator, architect, backend-developer,"
    echo "  frontend-developer, test-qa"
    echo "  ${CYAN}($core_count agents)${NC}"
    echo ""

    if [ ${#SELECTED_PACKS[@]} -gt 0 ]; then
        echo -e "${GREEN}PACKS:${NC}"
        for pack in "${SELECTED_PACKS[@]}"; do
            local count=$(ls "$REPO_DIR/packs/$pack/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
            pack_count=$((pack_count + count))
            echo "  ✓ $pack ($count agents)"
        done
        echo ""
    fi

    if [ ${#SELECTED_DOMAINS[@]} -gt 0 ]; then
        echo -e "${GREEN}DOMAINS:${NC}"
        for domain in "${SELECTED_DOMAINS[@]}"; do
            local count=$(ls "$REPO_DIR/domains/$domain/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
            domain_count=$((domain_count + count))
            echo "  ✓ $domain ($count agents)"
        done
        echo ""
    fi

    local total=$((core_count + pack_count + domain_count))
    echo -e "${BOLD}Total: $total agents${NC}"
    echo ""
}

# Install function
do_install() {
    print_section "Installing..."

    mkdir -p "$CLAUDE_DIR/agents"

    # Install core
    print_info "Installing core agents..."
    cp "$REPO_DIR/core/agents/"*.md "$CLAUDE_DIR/agents/" 2>/dev/null || true
    print_success "Core agents installed"

    # Install packs
    for pack in "${SELECTED_PACKS[@]}"; do
        print_info "Installing $pack pack..."
        cp "$REPO_DIR/packs/$pack/agents/"*.md "$CLAUDE_DIR/agents/" 2>/dev/null || true
        print_success "$pack pack installed"
    done

    # Install domains
    for domain in "${SELECTED_DOMAINS[@]}"; do
        print_info "Installing $domain domain..."
        cp "$REPO_DIR/domains/$domain/agents/"*.md "$CLAUDE_DIR/agents/" 2>/dev/null || true
        print_success "$domain domain installed"
    done

    # Copy commands if they exist
    if [ -d "$REPO_DIR/core/commands" ]; then
        mkdir -p "$CLAUDE_DIR/commands"
        cp -r "$REPO_DIR/core/commands/"* "$CLAUDE_DIR/commands/" 2>/dev/null || true
    fi

    # Copy skills if they exist
    if [ -d "$REPO_DIR/core/skills" ]; then
        mkdir -p "$CLAUDE_DIR/skills"
        cp -r "$REPO_DIR/core/skills/"* "$CLAUDE_DIR/skills/" 2>/dev/null || true
    fi

    echo ""
    print_success "Installation complete!"
    echo ""
    echo -e "${YELLOW}Restart Claude Code to apply changes.${NC}"
}

# Save configuration
save_config() {
    local config_file="$CLAUDE_DIR/.agent-config"

    cat > "$config_file" <<EOF
# Claude Agent Framework Configuration
# Generated by setup.sh on $(date)

PACKS=(${SELECTED_PACKS[*]})
DOMAINS=(${SELECTED_DOMAINS[*]})
EOF

    print_info "Configuration saved to $config_file"
}

# Quick install (non-interactive)
quick_install() {
    local preset="$1"

    case "$preset" in
        minimal)
            SELECTED_PACKS=()
            SELECTED_DOMAINS=()
            ;;
        standard)
            SELECTED_PACKS=("specs" "quality" "data" "security" "devops")
            SELECTED_DOMAINS=()
            ;;
        full)
            SELECTED_PACKS=("specs" "quality" "data" "security" "devops" "docs" "pr-review" "governance")
            SELECTED_DOMAINS=()
            ;;
        finance)
            SELECTED_PACKS=("specs" "quality" "data" "security" "devops" "docs" "pr-review")
            SELECTED_DOMAINS=("finance")
            ;;
        *)
            echo "Unknown preset: $preset"
            echo "Available presets: minimal, standard, full, finance"
            exit 1
            ;;
    esac

    echo "Quick install: $preset"
    show_summary
    do_install
    save_config
}

# Show help
show_help() {
    echo "Claude Code Agent Framework - Setup"
    echo ""
    echo "Usage: $0 [command] [options]"
    echo ""
    echo "Commands:"
    echo "  (no args)     Interactive setup wizard"
    echo "  --preset X    Quick install with preset (minimal/standard/full/finance)"
    echo "  --list        List available packs and domains"
    echo "  --help        Show this help"
    echo ""
    echo "Examples:"
    echo "  $0                    # Interactive wizard"
    echo "  $0 --preset standard  # Quick install standard packs"
    echo "  $0 --preset finance   # Quick install with finance domain"
}

# List available packs and domains
list_available() {
    echo "Available Packs:"
    for pack_dir in "$REPO_DIR"/packs/*/; do
        if [ -d "$pack_dir" ]; then
            pack=$(basename "$pack_dir")
            count=$(ls "$pack_dir/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $pack ($count agents)"
        fi
    done

    echo ""
    echo "Available Domains:"
    for domain_dir in "$REPO_DIR"/domains/*/; do
        if [ -d "$domain_dir" ]; then
            domain=$(basename "$domain_dir")
            count=$(ls "$domain_dir/agents/"*.md 2>/dev/null | wc -l | tr -d ' ')
            echo "  - $domain ($count agents)"
        fi
    done
}

# Main
main() {
    case "${1:-}" in
        --help|-h)
            show_help
            exit 0
            ;;
        --list)
            list_available
            exit 0
            ;;
        --preset)
            quick_install "$2"
            exit 0
            ;;
        *)
            # Interactive mode
            print_header
            select_project_type
            select_packs
            select_domains

            print_header
            show_summary

            if confirm "Proceed with installation?" "y"; then
                do_install
                save_config
            else
                echo "Installation cancelled."
            fi
            ;;
    esac
}

main "$@"
