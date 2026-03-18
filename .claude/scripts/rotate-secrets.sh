#!/usr/bin/env bash
# Secret Rotation Script
# Rotates database credentials and updates both Infisical and running services

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Generate secure password
generate_password() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# Rotate database password
rotate_db_password() {
    local env="${1:-dev}"

    info "Rotating database password for environment: $env"

    # Generate new password
    local new_password=$(generate_password)

    # Update Infisical
    info "Updating secret in Infisical..."
    if ! infisical secrets set DB_PASSWORD "$new_password" --env="$env" --silent; then
        error "Failed to update secret in Infisical"
    fi
    success "Secret updated in Infisical"

    # Update database user password
    info "Updating database user password..."
    # This is environment-specific - adjust for your database setup
    warn "Manual step required: Update database user password"
    echo "  New password: $new_password"
    echo "  Command: ALTER USER <username> WITH PASSWORD '$new_password';"

    # Update running services
    info "Restarting services to pick up new password..."
    warn "Manual step required: Restart services that use DB_PASSWORD"

    success "Database password rotation complete"
}

# Rotate API token
rotate_api_token() {
    local token_name="$1"
    local env="${2:-dev}"

    info "Rotating $token_name for environment: $env"

    warn "Token rotation requires regenerating the token in the source service"
    echo "  1. Generate new token in the service UI"
    echo "  2. Update Infisical:"
    echo "     infisical secrets set $token_name '<new-token>' --env=$env"
    echo "  3. Restart services that use $token_name"
}

# Main menu
show_menu() {
    echo ""
    echo "======================================================================"
    echo "Secret Rotation Tool"
    echo "======================================================================"
    echo ""
    echo "Select secret to rotate:"
    echo "  1) Database Password (DB_PASSWORD)"
    echo "  2) N8N API Key (N8N_API_KEY)"
    echo "  3) Context7 API Key (CONTEXT7_API_KEY)"
    echo "  4) GitHub Token (GITHUB_TOKEN)"
    echo "  5) All Secrets (guided rotation)"
    echo "  0) Exit"
    echo ""
    read -p "Enter choice [0-5]: " -n 1 -r choice
    echo

    local env="${1:-dev}"

    case $choice in
        1) rotate_db_password "$env" ;;
        2) rotate_api_token "N8N_API_KEY" "$env" ;;
        3) rotate_api_token "CONTEXT7_API_KEY" "$env" ;;
        4) rotate_api_token "GITHUB_TOKEN" "$env" ;;
        5) rotate_all_secrets "$env" ;;
        0) exit 0 ;;
        *) error "Invalid choice" ;;
    esac
}

# Rotate all secrets with guidance
rotate_all_secrets() {
    local env="$1"

    info "Starting guided rotation for all secrets in environment: $env"
    echo ""

    warn "This is a guided process. You will need to:"
    echo "  - Access service UIs to regenerate tokens"
    echo "  - Update database passwords manually"
    echo "  - Restart services after rotation"
    echo ""

    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi

    rotate_db_password "$env"
    echo ""
    rotate_api_token "N8N_API_KEY" "$env"
    echo ""
    rotate_api_token "CONTEXT7_API_KEY" "$env"
    echo ""
    rotate_api_token "GITHUB_TOKEN" "$env"

    success "All secrets rotation guidance complete"
}

# Main execution
main() {
    local env="${1:-dev}"

    if ! command -v infisical &> /dev/null; then
        error "Infisical CLI not found. Install with: brew install infisical/get-cli/infisical"
    fi

    if [[ ! -f "$HOME/.infisical.json" ]]; then
        error "Infisical CLI not configured. Run: infisical login"
    fi

    show_menu "$env"
}

main "$@"
