#!/usr/bin/env bash
# Infisical Setup Script
# Sets up Infisical self-hosted instance and configures initial secrets

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Check prerequisites
check_prerequisites() {
    info "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed. Please install Docker first."
    fi

    if ! command -v docker-compose &> /dev/null; then
        error "Docker Compose is not installed. Please install Docker Compose first."
    fi

    success "Prerequisites check passed"
}

# Generate secure random string
generate_secret() {
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32
}

# Store secret in macOS Keychain
store_in_keychain() {
    local key="$1"
    local value="$2"

    if [[ "$(uname)" == "Darwin" ]]; then
        security add-generic-password -a "$USER" -s "$key" -w "$value" -U 2>/dev/null || \
        security delete-generic-password -s "$key" 2>/dev/null && \
        security add-generic-password -a "$USER" -s "$key" -w "$value" -U
        info "Stored $key in macOS Keychain"
    fi
}

# Setup Infisical bootstrap secrets
setup_bootstrap_secrets() {
    info "Setting up Infisical bootstrap secrets..."

    local env_file="$PROJECT_ROOT/.env.infisical"

    if [[ -f "$env_file" ]]; then
        warn "Found existing .env.infisical file"
        read -p "Do you want to regenerate secrets? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Keeping existing secrets"
            return 0
        fi
    fi

    info "Generating new secrets..."

    local db_password=$(generate_secret)
    local encryption_key=$(generate_secret)
    local auth_secret=$(generate_secret)

    # Store in Keychain
    store_in_keychain "INFISICAL_DB_PASSWORD" "$db_password"
    store_in_keychain "INFISICAL_ENCRYPTION_KEY" "$encryption_key"
    store_in_keychain "INFISICAL_AUTH_SECRET" "$auth_secret"

    # Create .env.infisical file
    cat > "$env_file" <<EOF
# Infisical Self-Hosted Configuration
# Generated on $(date)
# Secrets are stored in macOS Keychain

INFISICAL_DB_PASSWORD=$db_password
INFISICAL_ENCRYPTION_KEY=$encryption_key
INFISICAL_AUTH_SECRET=$auth_secret
INFISICAL_SITE_URL=http://localhost:8080
HTTPS_ENABLED=false
TELEMETRY_ENABLED=false
EOF

    chmod 600 "$env_file"
    success "Bootstrap secrets generated and stored in Keychain"
}

# Start Infisical services
start_infisical() {
    info "Starting Infisical services..."

    cd "$PROJECT_ROOT"

    if [[ ! -f "docker/docker-compose.infisical.yml" ]]; then
        error "docker/docker-compose.infisical.yml not found"
    fi

    docker-compose -f docker/docker-compose.infisical.yml up -d

    info "Waiting for Infisical to be ready..."
    local max_attempts=30
    local attempt=0

    while [[ $attempt -lt $max_attempts ]]; do
        if curl -sf http://localhost:8080/api/status > /dev/null 2>&1; then
            success "Infisical is ready!"
            break
        fi
        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    if [[ $attempt -eq $max_attempts ]]; then
        error "Infisical failed to start within expected time"
    fi

    echo ""
    success "Infisical is running at http://localhost:8080"
}

# Display next steps
show_next_steps() {
    echo ""
    echo "======================================================================"
    echo -e "${GREEN}Infisical Setup Complete!${NC}"
    echo "======================================================================"
    echo ""
    echo "Next steps:"
    echo "  1. Open http://localhost:8080 in your browser"
    echo "  2. Create an admin account"
    echo "  3. Create a project (e.g., 'mcp-agent-router')"
    echo "  4. Create environments: dev, qa, prod"
    echo "  5. Install Infisical CLI:"
    echo "     brew install infisical/get-cli/infisical"
    echo "  6. Login to Infisical CLI:"
    echo "     infisical login"
    echo "  7. Migrate existing secrets using scripts/migrate-secrets.sh"
    echo ""
    echo "Documentation: docs/security/secrets-management-implementation-guide.md"
    echo "======================================================================"
}

# Main execution
main() {
    info "Starting Infisical setup..."

    check_prerequisites
    setup_bootstrap_secrets
    start_infisical
    show_next_steps
}

main "$@"
