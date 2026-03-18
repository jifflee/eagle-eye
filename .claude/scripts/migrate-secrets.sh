#!/usr/bin/env bash
# Migrate existing secrets to Infisical
# Reads secrets from Keychain/env and uploads to Infisical

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check if Infisical CLI is installed and configured
check_infisical_cli() {
    if ! command -v infisical &> /dev/null; then
        error "Infisical CLI not found. Install with: brew install infisical/get-cli/infisical"
    fi

    if [[ ! -f "$HOME/.infisical.json" ]]; then
        error "Infisical CLI not configured. Run: infisical login"
    fi

    success "Infisical CLI is ready"
}

# Get secret from Keychain
get_keychain_secret() {
    local key="$1"

    if [[ "$(uname)" == "Darwin" ]]; then
        security find-generic-password -s "$key" -w 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Set secret in Infisical
set_infisical_secret() {
    local key="$1"
    local value="$2"
    local env="${3:-dev}"

    if [[ -z "$value" ]]; then
        warn "Skipping $key (empty value)"
        return 1
    fi

    info "Migrating $key to Infisical ($env)..."

    if infisical secrets set "$key" "$value" --env="$env" --silent 2>/dev/null; then
        success "Migrated $key"
        return 0
    else
        warn "Failed to migrate $key"
        return 1
    fi
}

# Main migration logic
migrate_secrets() {
    local env="${1:-dev}"

    info "Starting secrets migration to environment: $env"
    echo ""

    # Define secrets to migrate
    local -A secrets=(
        ["N8N_API_KEY"]=""
        ["CONTEXT7_API_KEY"]=""
        ["DB_PASSWORD"]=""
        ["GITHUB_TOKEN"]=""
        ["WEBHOOK_SECRET"]=""
        ["SLACK_WEBHOOK_URL"]=""
        ["OPENAI_API_KEY"]=""
    )

    # Try to get values from Keychain
    for key in "${!secrets[@]}"; do
        local value=$(get_keychain_secret "$key")
        if [[ -z "$value" ]]; then
            # Try environment variable
            value="${!key:-}"
        fi
        secrets["$key"]="$value"
    done

    # Display summary
    echo "======================================================================"
    echo "Secrets to migrate:"
    echo "======================================================================"
    for key in "${!secrets[@]}"; do
        if [[ -n "${secrets[$key]}" ]]; then
            echo -e "  ${GREEN}✓${NC} $key (found)"
        else
            echo -e "  ${YELLOW}○${NC} $key (not found - will skip)"
        fi
    done
    echo "======================================================================"
    echo ""

    read -p "Proceed with migration to '$env' environment? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        info "Migration cancelled"
        exit 0
    fi

    # Migrate secrets
    local success_count=0
    local skip_count=0

    for key in "${!secrets[@]}"; do
        if set_infisical_secret "$key" "${secrets[$key]}" "$env"; then
            success_count=$((success_count + 1))
        else
            skip_count=$((skip_count + 1))
        fi
    done

    echo ""
    echo "======================================================================"
    success "Migration complete!"
    echo "  Migrated: $success_count"
    echo "  Skipped: $skip_count"
    echo "======================================================================"
}

# Main execution
main() {
    local env="${1:-dev}"

    info "Infisical Secrets Migration Tool"
    echo ""

    check_infisical_cli
    migrate_secrets "$env"
}

# Show usage if --help
if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    echo "Usage: migrate-secrets.sh [environment]"
    echo ""
    echo "Arguments:"
    echo "  environment    Target environment (default: dev)"
    echo "                 Options: dev, qa, prod"
    echo ""
    echo "Examples:"
    echo "  migrate-secrets.sh dev"
    echo "  migrate-secrets.sh prod"
    exit 0
fi

main "$@"
