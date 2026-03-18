#!/usr/bin/env bash
#
# init-github-conventions.sh
# Initialize a GitHub repository with standard labels and milestone
#
# Usage:
#   ./init-github-conventions.sh              # Creates default "MVP" milestone
#   ./init-github-conventions.sh "Phase 1"    # Creates custom milestone name
#
# This script creates:
#   - 8 standard labels (in-progress, backlog, blocked, bug, feature, docs, tech-debt, needs-attention)
#   - Initial milestone with 30-day due date
#
# Prerequisites:
#   - gh CLI installed and authenticated
#   - Run from within a git repository connected to GitHub

set -euo pipefail

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Aliases for print_* naming convention
print_error() { log_error "$@"; }
print_success() { echo -e "${GREEN:-}SUCCESS:${NC:-} $1"; }
print_info() { log_info "$@"; }
print_warning() { log_warn "$@"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v gh &> /dev/null; then
        print_error "gh CLI not found. Install from: https://cli.github.com/"
        exit 1
    fi

    if ! gh auth status &> /dev/null; then
        print_error "gh CLI not authenticated. Run: gh auth login"
        exit 1
    fi

    if ! git rev-parse --git-dir &> /dev/null; then
        print_error "Not in a git repository"
        exit 1
    fi

    # Check if remote exists
    if ! git remote get-url origin &> /dev/null; then
        print_error "No git remote 'origin' found. Push your repo to GitHub first."
        exit 1
    fi
}

# Create standard labels
create_labels() {
    print_info "Creating standard labels..."

    # Label format: name:color:description
    local labels=(
        "in-progress:FFA500:Actively being worked on"
        "backlog:D3D3D3:Planned but not started"
        "blocked:FF0000:Waiting on dependency"
        "bug:d73a4a:Something isn't working"
        "feature:00FF00:New functionality"
        "docs:0075ca:Documentation task"
        "tech-debt:FFA500:Refactoring or cleanup"
        "needs-attention:FF6600:Requires immediate attention"
    )

    local created=0
    local skipped=0

    for item in "${labels[@]}"; do
        local name color desc
        name=$(echo "$item" | cut -d: -f1)
        color=$(echo "$item" | cut -d: -f2)
        desc=$(echo "$item" | cut -d: -f3)

        if gh label create "$name" --color "$color" --description "$desc" 2>/dev/null; then
            print_success "  Created label: $name"
            ((created++))
        else
            print_info "  Label exists: $name"
            ((skipped++))
        fi
    done

    echo ""
    print_info "Labels: $created created, $skipped already existed"
}

# Create initial milestone
create_milestone() {
    local name="${1:-MVP}"

    print_info "Creating milestone: $name..."

    # Calculate due date (30 days from now)
    # Try macOS date syntax first, then GNU date
    local due_date
    if date -v+30d +%Y-%m-%dT00:00:00Z &>/dev/null; then
        due_date=$(date -v+30d +%Y-%m-%dT00:00:00Z)
    else
        due_date=$(date -d "+30 days" +%Y-%m-%dT00:00:00Z)
    fi

    # Check if milestone already exists
    local existing
    existing=$(gh api repos/:owner/:repo/milestone-list --jq ".[] | select(.title==\"$name\") | .title" 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        print_info "  Milestone already exists: $name"
        return 0
    fi

    if gh api repos/:owner/:repo/milestone-list -X POST \
        -f title="$name" \
        -f state="open" \
        -f description="Sprint milestone created by init-github-conventions.sh" \
        -f due_on="$due_date" &>/dev/null; then
        print_success "  Created milestone: $name (due: $(echo "$due_date" | cut -dT -f1))"
    else
        print_error "  Failed to create milestone: $name"
        return 1
    fi
}

# Main
main() {
    local milestone_name="${1:-MVP}"

    echo ""
    echo "GitHub Conventions Initializer"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    check_prerequisites

    create_labels
    echo ""
    create_milestone "$milestone_name"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_success "Repository initialized with GitHub conventions!"
    echo ""
    print_info "Next steps:"
    echo "  1. Verify setup: ./scripts/validate/validate-github-conventions.sh --check"
    echo "  2. Create your first issue using the templates"
    echo "  3. Assign issues to the '$milestone_name' milestone"
    echo ""
}

main "$@"
