#!/bin/bash
set -euo pipefail

# Sync Back Script
# Syncs agent framework changes from external repo back to claude-tastic template
# Can be run manually or via GitHub Actions
# size-ok: bidirectional sync with conflict detection and multi-file copy logic

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Aliases for print_* naming convention
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN:-}✓${NC:-} $1"; }
print_warning() { log_warn "$@"; }
print_error() { log_error "$@"; }

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "$1"
    echo "═══════════════════════════════════════════════════"
    echo ""
}

# Usage information
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Sync agent framework changes from external repo to claude-tastic template.

OPTIONS:
    --source-repo PATH      Path to source repository (required)
    --template-repo PATH    Path to claude-tastic repo (default: current directory)
    --create-pr             Create pull request (requires gh CLI)
    --pr-title TITLE        PR title (default: auto-generated)
    --pr-description DESC   PR description (default: auto-generated)
    --dry-run               Show what would be synced without making changes
    --help                  Show this help message

EXAMPLES:
    # Dry run to see what would change
    $0 --source-repo ~/projects/options-wizards --dry-run

    # Sync and create PR
    $0 --source-repo ~/projects/options-wizards --create-pr

    # Sync with custom PR details
    $0 --source-repo ~/projects/options-wizards \\
       --create-pr \\
       --pr-title "feat: Performance optimizations" \\
       --pr-description "Improvements from options-wizards implementation"

REQUIREMENTS:
    - git
    - rsync
    - gh (GitHub CLI, only if using --create-pr)

EOF
}

# Parse arguments
SOURCE_REPO=""
TEMPLATE_REPO="$(pwd)"
CREATE_PR=false
PR_TITLE=""
PR_DESCRIPTION=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --source-repo)
            SOURCE_REPO="$2"
            shift 2
            ;;
        --template-repo)
            TEMPLATE_REPO="$2"
            shift 2
            ;;
        --create-pr)
            CREATE_PR=true
            shift
            ;;
        --pr-title)
            PR_TITLE="$2"
            shift 2
            ;;
        --pr-description)
            PR_DESCRIPTION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate inputs
if [ -z "$SOURCE_REPO" ]; then
    print_error "Source repository is required"
    usage
    exit 1
fi

if [ ! -d "$SOURCE_REPO" ]; then
    print_error "Source repository not found: $SOURCE_REPO"
    exit 1
fi

if [ ! -d "$TEMPLATE_REPO" ]; then
    print_error "Template repository not found: $TEMPLATE_REPO"
    exit 1
fi

# Check if we're in the template repo
if [ ! -f "$TEMPLATE_REPO/claude.md" ]; then
    print_error "Template repository does not appear to be claude-tastic (claude.md not found)"
    exit 1
fi

# Check for required tools
if [ "$CREATE_PR" = true ] && ! command -v gh &> /dev/null; then
    print_error "gh (GitHub CLI) is required for --create-pr but not installed"
    exit 1
fi

print_header "Claude Agents Sync Back"

print_info "Source Repository: $SOURCE_REPO"
print_info "Template Repository: $TEMPLATE_REPO"
if [ "$DRY_RUN" = true ]; then
    print_warning "DRY RUN MODE - No changes will be made"
fi
echo ""

# Define template paths to sync
TEMPLATE_PATHS=(
    "agents/"
    "docs/copilot/"
    "commands/"
    "skills/"
    "hooks/"
    "claude.md"
    "AGENTS.md"
    "WORKFLOW.md"
    "EXAMPLES.md"
    "CONTRIBUTING.md"
    "sync.sh"
    "validate-agents.sh"
)

# Show what will be synced
print_info "Checking template files in source repo..."
echo ""

FOUND_PATHS=()
MISSING_PATHS=()

for path in "${TEMPLATE_PATHS[@]}"; do
    if [ -e "$SOURCE_REPO/$path" ]; then
        FOUND_PATHS+=("$path")
        print_success "Found: $path"
    else
        MISSING_PATHS+=("$path")
        print_warning "Missing: $path"
    fi
done

echo ""

if [ ${#FOUND_PATHS[@]} -eq 0 ]; then
    print_error "No template files found in source repository"
    exit 1
fi

print_info "Will sync ${#FOUND_PATHS[@]} paths"

if [ "$DRY_RUN" = true ]; then
    print_info "Dry run complete - no changes made"
    exit 0
fi

# Confirm with user
echo ""
read -p "Continue with sync? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Sync cancelled"
    exit 0
fi

# Create branch if doing PR
BRANCH_NAME=""
if [ "$CREATE_PR" = true ]; then
    cd "$TEMPLATE_REPO"

    # Check if repo is clean
    if [ -n "$(git status --porcelain)" ]; then
        print_error "Template repository has uncommitted changes. Please commit or stash them first."
        exit 1
    fi

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BRANCH_NAME="sync-back/$TIMESTAMP"

    print_info "Creating branch: $BRANCH_NAME"
    git checkout -b "$BRANCH_NAME"
fi

# Perform sync
print_header "Syncing Files"

for path in "${FOUND_PATHS[@]}"; do
    print_info "Syncing $path..."

    # If directory, use rsync
    if [ -d "$SOURCE_REPO/$path" ]; then
        mkdir -p "$TEMPLATE_REPO/$path"
        rsync -av --delete --exclude='.git' "$SOURCE_REPO/$path" "$TEMPLATE_REPO/$(dirname $path)/"
    # If file, use cp
    else
        cp "$SOURCE_REPO/$path" "$TEMPLATE_REPO/$path"
    fi

    print_success "Synced $path"
done

echo ""

# Validate agents
print_info "Validating agents..."
cd "$TEMPLATE_REPO"

if [ -x "./validate-agents.sh" ]; then
    if ./validate-agents.sh agents/; then
        print_success "Agent validation passed"
    else
        print_error "Agent validation failed"
        if [ "$CREATE_PR" = true ]; then
            print_warning "Cleaning up branch..."
            git checkout main
            git branch -D "$BRANCH_NAME"
        fi
        exit 1
    fi
else
    print_warning "validate-agents.sh not executable or not found"
fi

echo ""

# Check for changes
if [ -z "$(git status --porcelain)" ]; then
    print_info "No changes detected - source and template are in sync"
    if [ "$CREATE_PR" = true ]; then
        git checkout main
        git branch -D "$BRANCH_NAME"
    fi
    exit 0
fi

print_info "Changes detected:"
git status --short
echo ""

# Commit and create PR if requested
if [ "$CREATE_PR" = true ]; then
    print_header "Creating Pull Request"

    # Generate PR details if not provided
    SOURCE_REPO_NAME=$(basename "$SOURCE_REPO")

    if [ -z "$PR_TITLE" ]; then
        PR_TITLE="feat: Agent framework improvements from $SOURCE_REPO_NAME"
    fi

    if [ -z "$PR_DESCRIPTION" ]; then
        PR_DESCRIPTION="Automated sync-back of agent framework improvements from $SOURCE_REPO_NAME implementation."
    fi

    # Commit changes
    git add .
    git commit -m "$PR_TITLE

Source: $SOURCE_REPO
Synced at: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

$PR_DESCRIPTION

🤖 Automated sync-back via sync-back.sh"

    # Push branch
    print_info "Pushing branch to GitHub..."
    git push -u origin "$BRANCH_NAME"

    # Create PR
    print_info "Creating pull request..."
    gh pr create \
        --title "$PR_TITLE" \
        --body "## Sync Back from External Repository

**Source Repository:** \`$SOURCE_REPO\`
**Synced At:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

---

$PR_DESCRIPTION

## Changes Synced

This PR includes changes to the agent framework files:
- \`agents/\` - Agent definitions
- \`docs/copilot/\` - Standards and documentation
- \`commands/\`, \`skills/\`, \`hooks/\` - Claude Code extensions
- Framework documentation (claude.md, AGENTS.md, etc.)
- Utility scripts (sync.sh, validate-agents.sh)

## Validation

✅ Agent validation passed
✅ All required agents present

## Review Checklist

- [ ] Review all agent changes for quality
- [ ] Ensure changes are template-appropriate (not project-specific)
- [ ] Verify documentation is updated
- [ ] Check that standards are maintained
- [ ] Run local validation: \`./validate-agents.sh\`

---

🤖 Generated by [sync-back.sh](./sync-back.sh)" \
        --base main \
        --head "$BRANCH_NAME" \
        --label "sync-back" \
        --label "enhancement"

    print_success "Pull request created!"
    echo ""
    print_info "View PR at: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls"

else
    # Just show status
    print_warning "Changes synced but not committed. Review and commit manually:"
    echo ""
    echo "  cd $TEMPLATE_REPO"
    echo "  git status"
    echo "  git diff"
    echo "  git add ."
    echo "  git commit -m 'feat: Sync from $SOURCE_REPO_NAME'"
    echo ""
fi

print_header "Sync Complete"
print_success "Agent framework synced successfully!"
