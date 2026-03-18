#!/usr/bin/env bash
#
# init-repo.sh
# Initialize a repository for use with the Claude Agent Framework
# size-ok: multi-mode repo initialization with detection, labels, branches, and interactive setup
#
# Usage:
#   ./repo-init.sh                    # Full interactive setup
#   ./repo-init.sh --detect           # Detection only (JSON output)
#   ./repo-init.sh --labels           # Create labels only
#   ./repo-init.sh --branch           # Create dev branch only
#   ./repo-init.sh --milestone NAME   # Create milestone only
#   ./repo-init.sh --all              # Apply all changes non-interactively
#
# This script:
#   - Detects existing vs missing components
#   - Creates dev branch from main
#   - Creates standard GitHub labels
#   - Creates first milestone if none exists
#   - Is idempotent (safe to run multiple times)

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/config.sh"

# Standard labels
STANDARD_LABELS=(
    "in-progress:FFA500:Actively being worked on"
    "backlog:D3D3D3:Planned but not started"
    "blocked:FF0000:Waiting on dependency"
    "bug:d73a4a:Something isn't working"
    "feature:00FF00:New functionality"
    "docs:0075ca:Documentation task"
    "tech-debt:FFA500:Refactoring or cleanup"
    "needs-attention:FF6600:Requires immediate attention"
    "execution:container:0E8A16:Force Docker/container execution mode"
    "execution:worktree:1D76DB:Force worktree execution mode"
    "execution:n8n:5319E7:Force n8n automation execution mode"
)

#------------------------------------------------------------------------------
# Utility functions
#------------------------------------------------------------------------------

print_error() { log_error "$@"; }
print_success() { echo -e "${GREEN:-}OK:${NC:-} $1"; }
print_info() { log_info "$@"; }
print_warning() { log_warn "$@"; }

#------------------------------------------------------------------------------
# Pre-flight checks
#------------------------------------------------------------------------------

check_prerequisites() {
    local errors=0

    if ! command -v gh &> /dev/null; then
        print_error "gh CLI not found. Install from: https://cli.github.com/"
        errors=1
    fi

    if ! gh auth status &> /dev/null 2>&1; then
        print_error "gh CLI not authenticated. Run: gh auth login"
        errors=1
    fi

    if ! git rev-parse --git-dir &> /dev/null 2>&1; then
        print_error "Not in a git repository"
        errors=1
    fi

    if ! git remote get-url origin &> /dev/null 2>&1; then
        print_error "No git remote 'origin'. Push to GitHub first."
        errors=1
    fi

    return $errors
}

#------------------------------------------------------------------------------
# Detection functions
#------------------------------------------------------------------------------

detect_dev_branch() {
    if git ls-remote --heads origin dev 2>/dev/null | grep -q dev; then
        echo "EXISTS"
    else
        echo "MISSING"
    fi
}

detect_labels() {
    local existing_labels
    existing_labels=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

    local count=0
    local missing=()

    for item in "${STANDARD_LABELS[@]}"; do
        local name
        name=$(echo "$item" | cut -d: -f1)
        if echo "$existing_labels" | grep -q "^${name}$"; then
            ((count++))
        else
            missing+=("$name")
        fi
    done

    echo "$count"
}

detect_labels_missing() {
    local existing_labels
    existing_labels=$(gh label list --json name --jq '.[].name' 2>/dev/null || echo "")

    local missing=()

    for item in "${STANDARD_LABELS[@]}"; do
        local name
        name=$(echo "$item" | cut -d: -f1)
        if ! echo "$existing_labels" | grep -q "^${name}$"; then
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "${missing[*]}"
    else
        echo ""
    fi
}

detect_milestone() {
    local milestone
    milestone=$(gh api repos/:owner/:repo/milestone-list --jq '.[] | select(.state=="open") | .title' 2>/dev/null | head -1 || echo "")

    if [[ -n "$milestone" ]]; then
        echo "$milestone"
    else
        echo "MISSING"
    fi
}

detect_branch_protection() {
    local protection
    protection=$(gh api repos/:owner/:repo/branches/main/protection 2>/dev/null || echo "")

    if [[ -n "$protection" && "$protection" != "null" ]]; then
        echo "ENABLED"
    else
        echo "DISABLED"
    fi
}

detect_all() {
    local dev_branch labels_count milestone protection labels_missing

    dev_branch=$(detect_dev_branch)
    labels_count=$(detect_labels)
    labels_missing=$(detect_labels_missing)
    milestone=$(detect_milestone)
    protection=$(detect_branch_protection)

    # JSON output for skill consumption
    cat <<EOF
{
  "dev_branch": "$dev_branch",
  "labels": {
    "count": $labels_count,
    "total": 11,
    "missing": "$labels_missing"
  },
  "milestone": "$milestone",
  "branch_protection": "$protection"
}
EOF
}

#------------------------------------------------------------------------------
# Action functions
#------------------------------------------------------------------------------

create_dev_branch() {
    print_info "Creating dev branch..."

    if git ls-remote --heads origin dev 2>/dev/null | grep -q dev; then
        print_info "Dev branch already exists"
        return 0
    fi

    # Fetch latest main
    git fetch origin main 2>/dev/null || true

    # Create and push dev branch
    git checkout -b dev origin/main 2>/dev/null || git checkout dev
    git push -u origin dev 2>/dev/null

    print_success "Created dev branch from main"
}

create_labels() {
    print_info "Creating standard labels..."

    local created=0
    local skipped=0

    for item in "${STANDARD_LABELS[@]}"; do
        local name color desc
        name=$(echo "$item" | cut -d: -f1)
        color=$(echo "$item" | cut -d: -f2)
        desc=$(echo "$item" | cut -d: -f3)

        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            print_success "  Created: $name"
            ((created++))
        else
            print_info "  Exists: $name"
            ((skipped++))
        fi
    done

    print_info "Labels: $created created, $skipped already existed"
}

create_milestone() {
    local name="${1:-MVP}"

    print_info "Creating milestone: $name..."

    # Check if milestone already exists
    local existing
    existing=$(gh api repos/:owner/:repo/milestone-list --jq ".[] | select(.title==\"$name\") | .title" 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        print_info "Milestone already exists: $name"
        return 0
    fi

    # Calculate due date (30 days from now)
    local due_date
    if date -v+30d +%Y-%m-%dT00:00:00Z &>/dev/null; then
        due_date=$(date -v+30d +%Y-%m-%dT00:00:00Z)
    else
        due_date=$(date -d "+30 days" +%Y-%m-%dT00:00:00Z)
    fi

    if gh api repos/:owner/:repo/milestone-list -X POST \
        -f title="$name" \
        -f state="open" \
        -f description="Sprint milestone created by init-repo.sh" \
        -f due_on="$due_date" &>/dev/null; then
        print_success "Created milestone: $name (due: $(echo "$due_date" | cut -dT -f1))"
    else
        print_error "Failed to create milestone: $name"
        return 1
    fi
}

configure_execution_mode() {
    local mode="${1:-}"
    local interactive="${2:-true}"

    echo ""
    echo -e "${BOLD}Execution Mode Configuration${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # If mode not provided and interactive, prompt user
    if [[ -z "$mode" && "$interactive" == "true" ]]; then
        echo "Choose your preferred execution mode for sprint work:"
        echo ""
        echo "1. Docker (container-first)"
        echo "   - Isolated execution in Docker containers"
        echo "   - Requires: Docker installed and running"
        echo "   - Best for: Reproducible builds, team consistency"
        echo ""
        echo "2. Worktree (local-first)"
        echo "   - Execution using git worktrees"
        echo "   - Requires: Git only"
        echo "   - Best for: Fast iteration, no Docker overhead"
        echo ""
        echo "3. n8n (automation-first)"
        echo "   - Workflows triggered via n8n webhooks"
        echo "   - Requires: n8n running locally or remotely"
        echo "   - Best for: Complex automation workflows"
        echo ""
        echo "4. Hybrid (auto-detect)"
        echo "   - Automatically selects Docker or worktree"
        echo "   - Prefers Docker, falls back to worktree"
        echo "   - Best for: Flexible environments"
        echo ""

        # Detect available modes
        local docker_available=false
        local worktree_available=false
        local n8n_available=false

        if check_docker_available; then
            docker_available=true
        fi
        if check_worktree_available; then
            worktree_available=true
        fi
        if check_n8n_available; then
            n8n_available=true
        fi

        echo -e "${BLUE}Available on your system:${NC}"
        [[ "$docker_available" == "true" ]] && echo "  ✓ Docker"
        [[ "$docker_available" == "false" ]] && echo "  ✗ Docker (not available)"
        [[ "$worktree_available" == "true" ]] && echo "  ✓ Worktree"
        [[ "$worktree_available" == "false" ]] && echo "  ✗ Worktree (not available)"
        [[ "$n8n_available" == "true" ]] && echo "  ✓ n8n"
        [[ "$n8n_available" == "false" ]] && echo "  ✗ n8n (not available)"
        echo ""

        read -p "Select mode [1-4] (default: 2): " choice
        case "$choice" in
            1)
                mode="docker"
                ;;
            2|"")
                mode="worktree"
                ;;
            3)
                mode="n8n"
                ;;
            4)
                mode="hybrid"
                ;;
            *)
                print_warning "Invalid choice, defaulting to worktree"
                mode="worktree"
                ;;
        esac
    elif [[ -z "$mode" ]]; then
        # Non-interactive, use default
        mode="worktree"
    fi

    # Validate dependencies if validation is enabled
    if is_dependency_validation_enabled; then
        print_info "Validating dependencies for mode: $mode..."
        if ! validate_execution_mode_dependencies "$mode"; then
            if [[ "$interactive" == "true" ]]; then
                echo ""
                read -p "Dependencies not met. Continue anyway? [y/N]: " continue_choice
                if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                    print_warning "Configuration cancelled"
                    return 1
                fi
            else
                print_warning "Dependencies not met, but continuing in non-interactive mode"
            fi
        else
            print_success "Dependencies validated successfully"
        fi
    fi

    # Update configuration
    print_info "Updating configuration..."
    if set_execution_mode_default "$mode"; then
        echo ""
        print_success "Execution mode configured: $mode"
        echo ""
        print_info "Configuration saved to: .claude-agents.config.yml"
        echo ""

        # Show next steps based on mode
        case "$mode" in
            docker)
                echo "Next steps for Docker mode:"
                echo "  - Ensure Docker daemon is running"
                echo "  - Pull required image: docker pull $(get_docker_image)"
                echo "  - Test: /sprint-work --issue N"
                ;;
            worktree)
                echo "Next steps for Worktree mode:"
                echo "  - Create an issue: gh issue create"
                echo "  - Start working: /sprint-work"
                ;;
            n8n)
                echo "Next steps for n8n mode:"
                echo "  - Ensure n8n is running at: $(get_n8n_webhook_url)"
                echo "  - Configure n8n workflows"
                echo "  - Test: /sprint-work --issue N"
                ;;
            hybrid)
                echo "Next steps for Hybrid mode:"
                echo "  - System will auto-detect Docker or worktree"
                echo "  - Create an issue: gh issue create"
                echo "  - Start working: /sprint-work"
                ;;
        esac
        echo ""

        # Show override information
        echo "Per-issue overrides:"
        echo "  - Use label 'execution:container' to force container mode"
        echo "  - Use label 'execution:worktree' to force worktree mode"
        echo "  - Use CLI flag: /sprint-work --issue N --container"
        echo ""

        return 0
    else
        print_error "Failed to update configuration"
        return 1
    fi
}

reconfigure_execution_mode() {
    echo ""
    echo -e "${BOLD}Reconfigure Execution Mode${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local current_mode
    current_mode=$(get_execution_mode_default)
    echo "Current execution mode: ${GREEN}$current_mode${NC}"
    echo ""

    read -p "Do you want to change the execution mode? [y/N]: " change_choice
    if [[ ! "$change_choice" =~ ^[Yy]$ ]]; then
        print_info "Configuration unchanged"
        return 0
    fi

    configure_execution_mode "" "true"
}

apply_all() {
    local milestone_name="${1:-MVP}"
    local skip_exec_mode="${2:-false}"

    echo ""
    echo -e "${BOLD}Repository Initialization${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    create_dev_branch
    echo ""
    create_labels
    echo ""
    create_milestone "$milestone_name"

    # Check if execution mode is already configured
    if [[ "$skip_exec_mode" != "true" ]]; then
        local current_mode
        current_mode=$(get_execution_mode_default)

        # Only configure if not already set (first run)
        if [[ -z "$current_mode" || "$current_mode" == "worktree" ]]; then
            echo ""
            configure_execution_mode "" "false"  # Non-interactive with default
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Repository initialized!"
    echo ""
    print_info "Next steps:"
    echo "  1. Create your first issue: gh issue create"
    echo "  2. Assign to milestone: gh issue edit 1 --milestone \"$milestone_name\""
    echo "  3. Start working: /sprint-work"
    echo ""
}

#------------------------------------------------------------------------------
# Display functions
#------------------------------------------------------------------------------

display_status() {
    local dev_branch labels_count milestone protection labels_missing exec_mode

    dev_branch=$(detect_dev_branch)
    labels_count=$(detect_labels)
    labels_missing=$(detect_labels_missing)
    milestone=$(detect_milestone)
    protection=$(detect_branch_protection)
    exec_mode=$(get_execution_mode_default)

    echo ""
    echo -e "${BOLD}Repository Status${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Dev branch
    if [[ "$dev_branch" == "EXISTS" ]]; then
        echo -e "Dev branch:        ${GREEN}EXISTS${NC}"
    else
        echo -e "Dev branch:        ${YELLOW}MISSING${NC}"
    fi

    # Labels
    if [[ "$labels_count" -eq 11 ]]; then
        echo -e "Standard labels:   ${GREEN}$labels_count/11${NC}"
    else
        echo -e "Standard labels:   ${YELLOW}$labels_count/11${NC} (missing: $labels_missing)"
    fi

    # Milestone
    if [[ "$milestone" != "MISSING" ]]; then
        echo -e "Active milestone:  ${GREEN}$milestone${NC}"
    else
        echo -e "Active milestone:  ${YELLOW}MISSING${NC}"
    fi

    # Execution mode
    echo -e "Execution mode:    ${GREEN}$exec_mode${NC}"

    # Branch protection
    if [[ "$protection" == "ENABLED" ]]; then
        echo -e "Branch protection: ${GREEN}ENABLED${NC}"
    else
        echo -e "Branch protection: ${YELLOW}DISABLED${NC}"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Recommendations
    local needs_action=false
    if [[ "$dev_branch" == "MISSING" || "$labels_count" -lt 8 || "$milestone" == "MISSING" ]]; then
        needs_action=true
        echo ""
        print_info "Recommendations:"
        [[ "$dev_branch" == "MISSING" ]] && echo "  - Create dev branch: ./scripts/repo-init.sh --branch"
        [[ "$labels_count" -lt 8 ]] && echo "  - Create labels: ./scripts/repo-init.sh --labels"
        [[ "$milestone" == "MISSING" ]] && echo "  - Create milestone: ./scripts/repo-init.sh --milestone MVP"
        echo ""
        echo "  Or apply all: ./scripts/init-repo.sh --all"
        echo "  To reconfigure execution mode: ./scripts/init-repo.sh --reconfigure"
    else
        echo ""
        print_success "Repository is fully configured!"
        echo "  To reconfigure execution mode: ./scripts/init-repo.sh --reconfigure"
    fi
    echo ""
}

#------------------------------------------------------------------------------
# Main
#------------------------------------------------------------------------------

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --detect              Output detection results as JSON"
    echo "  --status              Display human-readable status"
    echo "  --branch              Create dev branch from main"
    echo "  --labels              Create standard labels"
    echo "  --milestone NAME      Create milestone with given name"
    echo "  --all [NAME]          Apply all changes (milestone name optional)"
    echo "  --configure-exec-mode Configure execution mode interactively"
    echo "  --reconfigure         Reconfigure execution mode"
    echo "  --set-exec-mode MODE  Set execution mode (docker|worktree|n8n|hybrid)"
    echo "  -h, --help            Show this help message"
    echo ""
    exit 0
}

main() {
    local action=""
    local milestone_name="MVP"
    local exec_mode=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --detect)
                action="detect"
                shift
                ;;
            --status)
                action="status"
                shift
                ;;
            --branch)
                action="branch"
                shift
                ;;
            --labels)
                action="labels"
                shift
                ;;
            --milestone)
                action="milestone"
                milestone_name="${2:-MVP}"
                shift
                [[ "${1:-}" != --* && -n "${1:-}" ]] && { milestone_name="$1"; shift; }
                ;;
            --all)
                action="all"
                shift
                [[ "${1:-}" != --* && -n "${1:-}" ]] && { milestone_name="$1"; shift; }
                ;;
            --configure-exec-mode)
                action="configure-exec-mode"
                shift
                ;;
            --reconfigure)
                action="reconfigure"
                shift
                ;;
            --set-exec-mode)
                action="set-exec-mode"
                exec_mode="${2:-}"
                shift
                [[ "${1:-}" != --* && -n "${1:-}" ]] && { exec_mode="$1"; shift; }
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Default to status display
    if [[ -z "$action" ]]; then
        action="status"
    fi

    # Check prerequisites (except for detect which may be used for diagnostics)
    if [[ "$action" != "detect" ]]; then
        if ! check_prerequisites; then
            exit 1
        fi
    else
        check_prerequisites 2>/dev/null || true
    fi

    # Execute action
    case "$action" in
        detect)
            detect_all
            ;;
        status)
            display_status
            ;;
        branch)
            create_dev_branch
            ;;
        labels)
            create_labels
            ;;
        milestone)
            create_milestone "$milestone_name"
            ;;
        all)
            apply_all "$milestone_name"
            ;;
        configure-exec-mode)
            configure_execution_mode "" "true"
            ;;
        reconfigure)
            reconfigure_execution_mode
            ;;
        set-exec-mode)
            if [[ -z "$exec_mode" ]]; then
                print_error "Execution mode required"
                usage
            fi
            configure_execution_mode "$exec_mode" "false"
            ;;
    esac
}

main "$@"
