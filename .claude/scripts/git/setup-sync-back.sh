#!/bin/bash
set -euo pipefail

# Setup Script for Sync-Back PAT
# Guides user through PAT creation and secret storage
# Does NOT store PAT in code (security best practice)

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Custom header function
print_header() {
    echo ""
    echo -e "${BLUE:-}═══════════════════════════════════════════════════${NC:-}"
    echo -e "${BLUE:-}$1${NC:-}"
    echo -e "${BLUE:-}═══════════════════════════════════════════════════${NC:-}"
    echo ""
}

# Aliases for print_* naming convention
print_info() { log_info "$@"; }
print_success() { echo -e "${GREEN:-}✓${NC:-} $1"; }
print_warning() { log_warn "$@"; }
print_error() { log_error "$@"; }

print_step() {
    echo -e "${GREEN:-}➜${NC:-} $1"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    if ! command -v gh &> /dev/null; then
        print_error "GitHub CLI (gh) is not installed"
        echo ""
        echo "Install it:"
        echo "  macOS:   brew install gh"
        echo "  Linux:   See https://cli.github.com/manual/installation"
        echo ""
        exit 1
    fi
    print_success "GitHub CLI installed"

    # Check if authenticated
    if ! gh auth status &> /dev/null; then
        print_error "Not authenticated with GitHub CLI"
        echo ""
        echo "Run: gh auth login"
        echo ""
        exit 1
    fi
    print_success "GitHub CLI authenticated"

    # Check if in correct repo
    if [ ! -f "claude.md" ]; then
        print_error "Must run from claude-tastic repository root"
        exit 1
    fi
    print_success "In claude-tastic repository"

    echo ""
}

# Guide user through PAT creation
create_pat() {
    print_header "Step 1: Create Personal Access Token (PAT)"

    echo "We'll create a PAT using GitHub CLI (secure method)."
    echo ""

    print_step "Creating PAT with required scopes..."
    echo ""

    # Create PAT using gh CLI
    # This is secure because:
    # 1. PAT stays in memory only
    # 2. Immediately saved to GitHub Secrets
    # 3. Never written to disk

    PAT_NAME="claude-tastic-sync-back-$(date +%Y%m%d-%H%M%S)"

    echo "PAT name: $PAT_NAME"
    echo "Scopes: repo (full control of private repositories)"
    echo ""

    read -p "Create PAT? (y/n) " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warning "Setup cancelled"
        exit 0
    fi

    # Use gh CLI to create token
    print_info "Creating token via GitHub CLI..."

    # Note: gh auth token returns the current token, but we need to create a new one
    # We'll guide user to create it via web UI but use gh to set the secret

    echo ""
    print_warning "GitHub CLI cannot create PATs automatically (security restriction)"
    echo ""
    echo "Please follow these steps to create a PAT:"
    echo ""
    echo "1. Open: https://github.com/settings/tokens/new"
    echo "2. Note: $PAT_NAME"
    echo "3. Expiration: Choose (e.g., 90 days)"
    echo "4. Scopes: Check 'repo' (full control)"
    echo "5. Click 'Generate token'"
    echo "6. Copy the token (you'll paste it below)"
    echo ""

    read -p "Press Enter when ready to paste token..."
    echo ""

    # Read PAT securely (no echo)
    print_info "Paste your PAT (input will be hidden):"
    read -s PAT_TOKEN
    echo ""

    if [ -z "$PAT_TOKEN" ]; then
        print_error "No token provided"
        exit 1
    fi

    print_success "Token received"
    echo ""
}

# Save PAT to repository secret
save_to_secret() {
    print_header "Step 2: Save PAT to Repository Secret"

    # Get current repo
    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
    print_info "Repository: $REPO"

    # Check if secret already exists
    if gh secret list --repo "$REPO" 2>/dev/null | grep -q "SYNC_BACK_PAT"; then
        print_warning "SYNC_BACK_PAT already exists"
        read -p "Overwrite? (y/n) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Keeping existing secret"
            return
        fi
    fi

    # Save token as secret
    print_info "Saving token as SYNC_BACK_PAT..."

    echo "$PAT_TOKEN" | gh secret set SYNC_BACK_PAT --repo "$REPO"

    print_success "Secret saved to repository!"

    # Clear token from memory
    unset PAT_TOKEN

    echo ""
}

# Verify setup
verify_setup() {
    print_header "Step 3: Verify Setup"

    REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

    # Check if secret exists
    if gh secret list --repo "$REPO" | grep -q "SYNC_BACK_PAT"; then
        print_success "SYNC_BACK_PAT secret exists"
    else
        print_error "SYNC_BACK_PAT secret not found"
        return 1
    fi

    # Check if workflow exists
    if [ -f ".github/workflows/sync-back.yml" ]; then
        print_success "Sync-back workflow exists"
    else
        print_warning "Sync-back workflow not found"
    fi

    # Check if script exists
    if [ -x "./sync-back.sh" ]; then
        print_success "sync-back.sh script exists and is executable"
    else
        print_warning "sync-back.sh not found or not executable"
    fi

    echo ""
}

# Show usage instructions
show_instructions() {
    print_header "Setup Complete!"

    cat << 'EOF'
You can now use sync-back in two ways:

📱 Method 1: GitHub Actions (Automated)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
1. Go to: https://github.com/jifflee/claude-tastic/actions
2. Select "Sync Back to Template" workflow
3. Click "Run workflow"
4. Fill in:
   - source_repo: your-username/options-wizards
   - source_branch: main
5. Click "Run workflow"
6. Review the created PR

💻 Method 2: Manual Script
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Dry run (preview changes)
./sync-back.sh --source-repo /path/to/options-wizards --dry-run

# Sync and create PR
./sync-back.sh --source-repo /path/to/options-wizards --create-pr

📚 Documentation
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
See SYNC-BACK.md for complete guide

🔐 Security Notes
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
- PAT is stored securely in GitHub Secrets
- PAT is never committed to the repository
- PAT is not visible in Actions logs
- Remember to rotate your PAT periodically

EOF
}

# Main execution
main() {
    print_header "Sync-Back Setup - Claude Agents"

    echo "This script will help you set up sync-back functionality."
    echo "It will guide you through creating a PAT and saving it securely."
    echo ""

    check_prerequisites
    create_pat
    save_to_secret
    verify_setup
    show_instructions

    print_success "All done! 🎉"
    echo ""
}

# Run main
main
