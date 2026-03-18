#!/usr/bin/env bash
# ============================================================
# Script: n8n-setup.sh
# Purpose: Prerequisites check and container bootstrap for n8n
# Usage: ./scripts/n8n-setup.sh [--force]
#
# Options:
#   --force          Stop existing container and restart from scratch
#   --validate-only  Run health checks only (skip setup steps)
#   --help           Show this help message
#
# Steps:
#   1. Check Docker running and Docker Compose available
#   2. Check .env.local exists, create from .env.example if missing
#   3. Start n8n container with localhost-only binding and shared network
#   4. Wait for health check (/healthz → 200)
#   5. Create admin account via n8n API (POST /owner/setup)
#   6. Generate API key and store in .env.local
#   7. Configure GitHub integration (GitHub App or Fine-grained PAT)
#   8. Verify running version matches pinned version
#   9. Import and activate all workflows from n8n-workflows/
#
# Dependencies: docker, docker compose, curl, jq
# Issue: #727 - n8n setup wizard: prerequisites check and container bootstrap
# Issue: #721 - n8n setup wizard: admin account creation and API key generation
# Issue: #722 - n8n setup wizard: GitHub App/PAT integration scoped to repo
# Issue: #723 - n8n setup wizard: workflow import, activation, and validation
# Issue: #784 - bug: n8n instance has zero workflows imported - all automation inactive
# Parent: #720 - Network isolation
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Cleanup Handler ──────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  # Clean up any temporary files or resources
  if [[ -n "${TEMP_FILES:-}" ]]; then
    rm -f $TEMP_FILES 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT INT TERM

# Extract repository name for admin account email
REPO_NAME=$(basename "$(cd "$REPO_ROOT" && git rev-parse --show-toplevel 2>/dev/null)" || basename "$REPO_ROOT")

# Source common utilities
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
  source "$SCRIPT_DIR/lib/common.sh"
else
  # Minimal fallback
  log_info() { echo "[INFO] $*" >&2; }
  log_warn() { echo "[WARN] $*" >&2; }
  log_error() { echo "[ERROR] $*" >&2; }
  log_success() { echo "[OK] $*" >&2; }
  die() { log_error "$*"; exit 1; }
fi

# ─── Configuration - Hardcoded Values Extracted ──────────────────────────────

# n8n connection settings
readonly N8N_DEFAULT_PORT="${N8N_PORT:-5678}"
readonly N8N_DEFAULT_HOST="${N8N_HOST:-localhost}"
readonly N8N_DEFAULT_PROTOCOL="${N8N_PROTOCOL:-http}"

# Health check settings
readonly HEALTH_CHECK_TIMEOUT="${HEALTH_CHECK_TIMEOUT:-60}"
readonly HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2}"
readonly HEALTH_CHECK_ENDPOINT="/healthz"

# Admin account settings
readonly ADMIN_EMAIL_DOMAIN="${ADMIN_EMAIL_DOMAIN:-lee-solutionsgroup.com}"
readonly ADMIN_FIRST_NAME="${ADMIN_FIRST_NAME:-N8N}"
readonly ADMIN_LAST_NAME="${ADMIN_LAST_NAME:-Admin}"

# Network settings
readonly SHARED_NETWORK_NAME="${SHARED_NETWORK_NAME:-n8n-shared}"

# Workflow settings
readonly WORKFLOWS_DIR_NAME="${WORKFLOWS_DIR_NAME:-n8n-workflows}"
readonly WORKFLOWS_TEST_FIXTURES_DIR="${WORKFLOWS_TEST_FIXTURES_DIR:-test-fixtures}"

# GitHub API settings
readonly GITHUB_API_BASE_URL="${GITHUB_API_BASE_URL:-https://api.github.com}"
readonly GITHUB_TEST_REPO="${GITHUB_TEST_REPO:-octocat/Hello-World}"

# File paths
COMPOSE_FILE="$REPO_ROOT/deploy/n8n/docker-compose.n8n.yml"
ENV_LOCAL="$REPO_ROOT/.env.local"
ENV_EXAMPLE="$REPO_ROOT/env.example"
STATE_FILE="$REPO_ROOT/.n8n-setup-state.json"

# Runtime settings (can be overridden via flags)
N8N_PORT="$N8N_DEFAULT_PORT"
N8N_URL="${N8N_DEFAULT_PROTOCOL}://localhost:${N8N_PORT}"
HEALTH_TIMEOUT="$HEALTH_CHECK_TIMEOUT"
FORCE_RESTART=false
VALIDATE_ONLY=false
SHARED_NETWORK="$SHARED_NETWORK_NAME"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE_RESTART=true
      shift
      ;;
    --validate-only)
      VALIDATE_ONLY=true
      shift
      ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      die "Unknown option: $1. Use --help for usage information."
      ;;
  esac
done

# ============================================================
# STEP 1: Check Docker and Docker Compose
# ============================================================

step_1_check_docker() {
  log_info "Step 1: Checking Docker prerequisites..."
  echo ""

  # Check if Docker command exists
  if ! command -v docker &>/dev/null; then
    log_error "Docker is not installed"
    echo ""
    echo "Remediation:"
    echo "  - Install Docker Desktop: https://docs.docker.com/desktop/"
    echo "  - Or install via Homebrew: brew install --cask docker"
    echo ""
    exit 1
  fi
  log_success "Docker command found"

  # Check if Docker daemon is running
  if ! docker info &>/dev/null; then
    log_error "Docker daemon is not running"
    echo ""
    echo "Remediation:"
    echo "  - Start Docker Desktop from Applications"
    echo "  - Or start Docker Desktop from Applications"
    echo ""
    exit 1
  fi
  log_success "Docker daemon is running"

  # Check for docker compose (v2)
  if ! docker compose version &>/dev/null; then
    log_error "docker compose (v2) is not available"
    echo ""
    echo "Remediation:"
    echo "  - Update Docker Desktop to latest version"
    echo "  - Or install docker compose v2: https://docs.docker.com/compose/install/"
    echo ""
    exit 1
  fi
  log_success "Docker Compose v2 is available"

  # Check for curl
  if ! command -v curl &>/dev/null; then
    log_error "curl is not installed"
    echo ""
    echo "Remediation:"
    echo "  - macOS: curl is typically pre-installed"
    echo "  - Linux: sudo apt-get install curl (Ubuntu/Debian)"
    echo "  - Or: brew install curl (Homebrew)"
    echo ""
    exit 1
  fi
  log_success "curl is available"

  # Check for jq
  if ! command -v jq &>/dev/null; then
    log_error "jq is not installed"
    echo ""
    echo "Remediation:"
    echo "  - macOS: brew install jq"
    echo "  - Linux: sudo apt-get install jq (Ubuntu/Debian)"
    echo ""
    exit 1
  fi
  log_success "jq is available"

  echo ""
  log_success "Step 1 complete: All prerequisites met"
  echo ""
}

# ============================================================
# STEP 2: Check and setup .env.local
# ============================================================

step_2_check_env() {
  log_info "Step 2: Checking environment configuration..."
  echo ""

  # Check if .env.local exists
  if [ -f "$ENV_LOCAL" ]; then
    log_success ".env.local exists"

    # Validate it has required n8n variables (basic check)
    if grep -q "N8N_" "$ENV_LOCAL" 2>/dev/null || grep -q "^#" "$ENV_LOCAL" 2>/dev/null; then
      log_info "Environment file appears valid"
    else
      log_warn ".env.local exists but may be empty or incomplete"
    fi
  else
    log_warn ".env.local not found"

    # Check if .env.example exists
    if [ -f "$ENV_EXAMPLE" ]; then
      log_info "Creating .env.local from env.example..."
      cp "$ENV_EXAMPLE" "$ENV_LOCAL"
      log_success "Created .env.local from env.example"
    else
      # Create a minimal .env.local for n8n
      log_info "Creating minimal .env.local..."
      cat > "$ENV_LOCAL" << 'EOF'
# n8n Environment Configuration
# Created by n8n-setup.sh

# n8n Configuration
N8N_PORT=5678
N8N_HOST=localhost
N8N_PROTOCOL=http
WEBHOOK_URL=http://localhost:5678

# Security (CHANGE THESE IN PRODUCTION!)
N8N_ENCRYPTION_KEY=dev-encryption-key-change-in-production
N8N_BASIC_AUTH_ACTIVE=false

# Timezone
TZ=America/Los_Angeles

# Optional: Basic Auth (set to true and add credentials for security)
# N8N_BASIC_AUTH_ACTIVE=true
# N8N_BASIC_AUTH_USER=admin
# N8N_BASIC_AUTH_PASSWORD=change-me
EOF
      log_success "Created minimal .env.local"
    fi

    echo ""
    log_warn "Please review and update .env.local with your configuration:"
    echo "  - Edit: $ENV_LOCAL"
    echo "  - Required: N8N_ENCRYPTION_KEY (use a secure random string in production)"
    echo "  - Optional: Enable N8N_BASIC_AUTH for security"
    echo ""
    read -p "Press Enter to continue after reviewing .env.local, or Ctrl+C to exit..."
  fi

  echo ""
  log_success "Step 2 complete: Environment configuration ready"
  echo ""
}

# ============================================================
# STEP 3: Start n8n container
# ============================================================

step_3_start_container() {
  log_info "Step 3: Starting n8n container..."
  echo ""

  # Check for existing container
  if docker ps --format '{{.Names}}' | grep -q '^n8n-local$'; then
    if [ "$FORCE_RESTART" = true ]; then
      log_warn "Existing n8n container found - stopping for fresh restart (--force)"
      docker compose -f "$COMPOSE_FILE" down
      log_success "Stopped existing container"
    else
      log_warn "n8n container is already running"
      log_info "Skipping container start (use --force to restart from scratch)"
      echo ""
      log_info "Container status:"
      docker ps --filter "name=n8n-local" --format "  {{.Names}}: {{.Status}}"
      echo ""

      # Update state file
      save_state "existing"

      # Skip to health check
      return 0
    fi
  fi

  # Check if compose file exists
  if [ ! -f "$COMPOSE_FILE" ]; then
    log_error "Compose file not found: $COMPOSE_FILE"
    echo ""
    echo "Remediation:"
    echo "  - Ensure you're running this script from the repository root"
    echo "  - Check that deploy/n8n/docker-compose.n8n.yml exists"
    echo ""
    exit 1
  fi

  # Network is managed by docker-compose (n8n-shared defined in compose file)
  # No manual network creation needed

  # Start n8n container (localhost-only binding via docker-compose.yml)
  log_info "Starting n8n container with localhost-only binding..."

  # Load .env.local for docker compose
  if [ -f "$ENV_LOCAL" ]; then
    set -a
    source "$ENV_LOCAL"
    set +a
  fi

  docker compose -f "$COMPOSE_FILE" up -d

  log_success "n8n container started"

  # Save state
  save_state "started"

  echo ""
  log_success "Step 3 complete: Container started successfully"
  echo ""
}

# ============================================================
# STEP 4: Wait for health check
# ============================================================

step_4_health_check() {
  log_info "Step 4: Waiting for n8n health check..."
  echo ""

  log_info "Checking /healthz endpoint (timeout: ${HEALTH_TIMEOUT}s)..."

  local count=0
  local dots_printed=0

  while [ $count -lt $HEALTH_TIMEOUT ]; do
    # Check if container is still running (updated to quote grep pattern)
    if ! docker ps --format '{{.Names}}' | grep -q '^n8n-local$'; then
      echo ""
      log_error "n8n container stopped unexpectedly"
      echo ""
      echo "Remediation:"
      echo "  - Check logs: docker logs n8n-local"
      echo "  - Check container status: docker ps -a | grep n8n-local"
      echo "  - Verify compose file: $COMPOSE_FILE"
      echo ""
      exit 1
    fi

    # Check health endpoint
    if curl -sf "${N8N_URL}${HEALTH_CHECK_ENDPOINT}" &>/dev/null; then
      echo ""
      log_success "Health check passed: ${N8N_URL}${HEALTH_CHECK_ENDPOINT} → 200 OK"

      # Save successful state
      save_state "healthy"

      echo ""
      log_success "Step 4 complete: n8n is healthy and ready"
      echo ""
      return 0
    fi

    # Print progress dots
    if [ $((dots_printed % 30)) -eq 0 ]; then
      printf "\n  Waiting: "
    fi
    printf "."
    dots_printed=$((dots_printed + 1))

    sleep 2
    count=$((count + 2))
  done

  # Timeout reached
  echo ""
  log_error "Health check timeout: n8n failed to become healthy within ${HEALTH_TIMEOUT}s"
  echo ""
  echo "Remediation:"
  echo "  - Check logs: docker logs n8n-local"
  echo "  - Verify port not in use: lsof -i :$N8N_PORT"
  echo "  - Check container status: docker ps -a | grep n8n-local"
  echo "  - Try restarting: $0 --force"
  echo ""
  exit 1
}

# ============================================================
# STEP 5: Create admin account
# ============================================================

step_5_create_admin() {
  log_info "Step 5: Setting up admin account..."
  echo ""

  # Generate admin email from repo name
  local admin_email="github.n8n.${REPO_NAME}@${ADMIN_EMAIL_DOMAIN}"
  log_info "Admin email: $admin_email"

  # Check for admin password in .env.local
  local admin_password=""
  if [ -f "$ENV_LOCAL" ]; then
    # Load .env.local to check for N8N_ADMIN_PASSWORD
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e
    admin_password="${N8N_ADMIN_PASSWORD:-}"
  fi

  # Prompt for password if not found
  if [ -z "$admin_password" ]; then
    log_warn "N8N_ADMIN_PASSWORD not found in .env.local"
    echo ""
    read -sp "Enter admin password (requires 1+ uppercase letter, saved to .env.local): " admin_password
    echo ""

    if [ -z "$admin_password" ]; then
      log_error "Password cannot be empty"
      exit 1
    fi

    # Save password to .env.local
    echo "" >> "$ENV_LOCAL"
    echo "# n8n Admin Account (auto-added by n8n-setup.sh)" >> "$ENV_LOCAL"
    echo "N8N_ADMIN_PASSWORD=$admin_password" >> "$ENV_LOCAL"
    log_success "Saved N8N_ADMIN_PASSWORD to .env.local"
  else
    log_success "Found N8N_ADMIN_PASSWORD in .env.local"
  fi

  # Check if owner account already exists
  log_info "Checking if admin account exists..."

  local owner_check
  owner_check=$(curl -sf "$N8N_URL/rest/owner" 2>/dev/null || echo "{}")

  if echo "$owner_check" | jq -e '.data' &>/dev/null; then
    log_warn "Admin account already exists"

    # Validate credentials
    log_info "Validating credentials..."
    local login_response
    login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" 2>/dev/null || echo "")

    if echo "$login_response" | jq -e '.data' &>/dev/null; then
      log_success "Credentials validated successfully"
    else
      log_error "Credential validation failed"
      log_warn "The password in .env.local may not match the existing account"
      echo ""
      echo "Remediation:"
      echo "  - Update N8N_ADMIN_PASSWORD in .env.local with the correct password"
      echo "  - Or reset the n8n container: $0 --force"
      echo ""
      exit 1
    fi

    # Skip to next step
    echo ""
    log_success "Step 5 complete: Admin account verified"
    echo ""
    return 0
  fi

  # Create admin account
  log_info "Creating admin account..."

  local setup_payload
  setup_payload=$(jq -n \
    --arg email "$admin_email" \
    --arg password "$admin_password" \
    --arg firstName "$ADMIN_FIRST_NAME" \
    --arg lastName "$ADMIN_LAST_NAME" \
    '{
      email: $email,
      password: $password,
      firstName: $firstName,
      lastName: $lastName
    }')

  local setup_response
  setup_response=$(curl -sf -X POST "$N8N_URL/rest/owner/setup" \
    -H "Content-Type: application/json" \
    -d "$setup_payload" 2>/dev/null || echo "")

  if echo "$setup_response" | jq -e '.data' &>/dev/null; then
    log_success "Admin account created successfully"
  else
    log_error "Failed to create admin account"
    echo ""
    echo "API Response:"
    echo "$setup_response" | jq . 2>/dev/null || echo "$setup_response"
    echo ""
    echo "Remediation:"
    echo "  - Check n8n logs: docker logs n8n-local"
    echo "  - Verify n8n is healthy: ./scripts/n8n-health.sh"
    echo "  - Try restarting: $0 --force"
    echo ""
    exit 1
  fi

  # Validate credentials work
  log_info "Validating new credentials..."
  local login_response
  login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" 2>/dev/null || echo "")

  if echo "$login_response" | jq -e '.data' &>/dev/null; then
    log_success "Login validation successful"
  else
    log_error "Login validation failed"
    exit 1
  fi

  echo ""
  log_success "Step 5 complete: Admin account created and validated"
  echo ""
}

# ============================================================
# STEP 6: Generate API key
# ============================================================

step_6_generate_api_key() {
  log_info "Step 6: Generating API key..."
  echo ""

  # Check if API key already exists in .env.local
  local existing_api_key=""
  if [ -f "$ENV_LOCAL" ]; then
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e
    existing_api_key="${N8N_API_KEY:-}"
  fi

  if [ -n "$existing_api_key" ]; then
    log_info "API key found in .env.local, validating..."

    # Validate existing API key
    local validate_response
    validate_response=$(curl -sf "$N8N_URL/api/v1/workflows" \
      -H "X-N8N-API-KEY: $existing_api_key" 2>/dev/null || echo "")

    if echo "$validate_response" | jq -e '.data' &>/dev/null; then
      log_success "Existing API key is valid"
      echo ""
      log_success "Step 6 complete: API key validated"
      echo ""
      return 0
    else
      log_warn "Existing API key is invalid, generating new one..."
    fi
  fi

  # Get admin credentials
  local admin_email="github.n8n.${REPO_NAME}@lee-solutionsgroup.com"
  local admin_password=""

  if [ -f "$ENV_LOCAL" ]; then
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e
    admin_password="${N8N_ADMIN_PASSWORD:-}"
  fi

  if [ -z "$admin_password" ]; then
    log_error "N8N_ADMIN_PASSWORD not found in .env.local"
    exit 1
  fi

  # Login to get session cookie
  log_info "Authenticating to generate API key..."
  local cookie_jar=$(mktemp)

  local login_response
  login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
    -c "$cookie_jar" 2>/dev/null || echo "")

  if ! echo "$login_response" | jq -e '.data' &>/dev/null; then
    log_error "Authentication failed"
    rm -f "$cookie_jar"
    exit 1
  fi

  # Generate API key
  log_info "Creating API key..."
  local api_key_response
  api_key_response=$(curl -sf -X POST "$N8N_URL/rest/users/api-key" \
    -H "Content-Type: application/json" \
    -b "$cookie_jar" 2>/dev/null || echo "")

  rm -f "$cookie_jar"

  if ! echo "$api_key_response" | jq -e '.data.apiKey' &>/dev/null; then
    log_error "Failed to generate API key"
    echo ""
    echo "API Response:"
    echo "$api_key_response" | jq . 2>/dev/null || echo "$api_key_response"
    echo ""
    exit 1
  fi

  local new_api_key
  new_api_key=$(echo "$api_key_response" | jq -r '.data.apiKey')

  log_success "API key generated"

  # Store API key in .env.local
  log_info "Storing API key in .env.local..."

  # Remove old N8N_API_KEY if exists
  if grep -q "^N8N_API_KEY=" "$ENV_LOCAL" 2>/dev/null; then
    # Use sed to replace in-place (macOS and Linux compatible)
    if sed --version 2>&1 | grep -q GNU; then
      # GNU sed
      sed -i "s|^N8N_API_KEY=.*|N8N_API_KEY=$new_api_key|" "$ENV_LOCAL"
    else
      # BSD sed (macOS)
      sed -i '' "s|^N8N_API_KEY=.*|N8N_API_KEY=$new_api_key|" "$ENV_LOCAL"
    fi
  else
    # Add new entry
    echo "" >> "$ENV_LOCAL"
    echo "# n8n API Key (auto-generated by n8n-setup.sh)" >> "$ENV_LOCAL"
    echo "N8N_API_KEY=$new_api_key" >> "$ENV_LOCAL"
  fi

  log_success "API key saved to .env.local"

  # Validate API key works
  log_info "Validating API key..."
  local validate_response
  validate_response=$(curl -sf "$N8N_URL/api/v1/workflows" \
    -H "X-N8N-API-KEY: $new_api_key" 2>/dev/null || echo "")

  if echo "$validate_response" | jq -e '.data' &>/dev/null; then
    log_success "API key validation successful"
  else
    log_error "API key validation failed"
    exit 1
  fi

  echo ""
  log_success "Step 6 complete: API key generated and validated"
  echo ""
}

# ============================================================
# STEP 7: Configure GitHub Integration
# ============================================================

step_7_configure_github() {
  log_info "Step 7: Configuring GitHub integration..."
  echo ""

  # Extract repo owner/name from git remote
  local repo_owner=""
  local repo_name=""

  if git remote get-url origin &>/dev/null; then
    local remote_url
    remote_url=$(git remote get-url origin)

    # Parse owner/repo from various formats:
    # - https://github.com/owner/repo.git
    # - git@github.com:owner/repo.git
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/]+)(\.git)?$ ]]; then
      repo_owner="${BASH_REMATCH[1]}"
      repo_name="${BASH_REMATCH[2]%.git}"
    fi
  fi

  if [ -z "$repo_owner" ] || [ -z "$repo_name" ]; then
    log_warn "Could not auto-detect GitHub repository from git remote"
    echo ""
    read -p "Enter GitHub repository owner: " repo_owner
    read -p "Enter GitHub repository name: " repo_name

    if [ -z "$repo_owner" ] || [ -z "$repo_name" ]; then
      log_error "Repository owner and name are required"
      exit 1
    fi
  fi

  log_info "Repository: $repo_owner/$repo_name"
  echo ""

  # Check if GitHub credentials already exist in .env.local
  local has_github_app=false
  local has_github_token=false

  if [ -f "$ENV_LOCAL" ]; then
    if grep -q "^N8N_GITHUB_APP_ID=" "$ENV_LOCAL" 2>/dev/null; then
      has_github_app=true
    fi
    if grep -q "^N8N_GITHUB_TOKEN=" "$ENV_LOCAL" 2>/dev/null; then
      has_github_token=true
    fi
  fi

  if [ "$has_github_app" = true ] || [ "$has_github_token" = true ]; then
    log_info "GitHub credentials found in .env.local"
    echo ""
    read -p "GitHub credentials already configured. Reconfigure? (y/N): " reconfigure

    if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
      log_info "Skipping GitHub configuration"

      # Validate existing credentials
      if ! validate_github_credentials "$repo_owner" "$repo_name"; then
        log_warn "Existing credentials failed validation"
        echo ""
        read -p "Continue setup anyway? (y/N): " continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
          exit 1
        fi
      fi

      echo ""
      log_success "Step 7 complete: GitHub integration verified"
      echo ""
      return 0
    fi
  fi

  # Prompt for authentication method
  echo "Choose GitHub authentication method:"
  echo ""
  echo "  1) GitHub App (Recommended - more secure, fine-grained permissions)"
  echo "  2) Fine-grained Personal Access Token (PAT)"
  echo ""
  read -p "Select option (1 or 2): " auth_choice

  case "$auth_choice" in
    1)
      configure_github_app "$repo_owner" "$repo_name"
      ;;
    2)
      configure_github_pat "$repo_owner" "$repo_name"
      ;;
    *)
      log_error "Invalid choice. Please select 1 or 2"
      exit 1
      ;;
  esac

  # Validate configured credentials
  log_info "Validating GitHub credentials..."
  if validate_github_credentials "$repo_owner" "$repo_name"; then
    log_success "GitHub credentials validated successfully"
  else
    log_error "GitHub credential validation failed"
    echo ""
    echo "Remediation:"
    echo "  - Verify your credentials are correct"
    echo "  - Check token/app has required permissions"
    echo "  - Run setup again: $0"
    echo ""
    exit 1
  fi

  # Configure n8n credentials
  configure_n8n_github_credentials

  echo ""
  log_success "Step 7 complete: GitHub integration configured"
  echo ""
}

# Configure GitHub App authentication
configure_github_app() {
  local repo_owner="$1"
  local repo_name="$2"

  echo ""
  log_info "Configuring GitHub App authentication..."
  echo ""

  cat << 'EOF'
GitHub App Setup Instructions:
===============================

1. Create a new GitHub App:
   https://github.com/settings/apps/new

2. Configure the app:
   - GitHub App name: n8n-integration-YOUR_REPO_NAME
   - Homepage URL: http://localhost:5678
   - Webhook: Uncheck "Active"

3. Set Repository permissions (select "Repository" scope):
   - Pull requests: Read and write
   - Issues: Read and write
   - Contents: Read-only
   - Checks: Read-only
   - Metadata: Read-only (automatically selected)

4. Set Account permissions: None needed

5. Click "Create GitHub App"

6. After creation:
   - Note the "App ID" (shown at top of settings page)
   - Scroll down to "Private keys" section
   - Click "Generate a private key"
   - Save the downloaded .pem file to a secure location

7. Install the app on your repository ONLY:
   - On the app settings page, click "Install App" (left sidebar)
   - Click "Install" next to your account
   - Select "Only select repositories"
   - Choose ONLY the repository: YOUR_OWNER/YOUR_REPO
   - Click "Install"
   - Note the Installation ID from the URL:
     https://github.com/settings/installations/INSTALLATION_ID

EOF

  echo ""
  read -p "Press Enter after completing the GitHub App setup..."
  echo ""

  # Collect App ID
  read -p "Enter GitHub App ID: " app_id
  if [ -z "$app_id" ]; then
    log_error "App ID is required"
    exit 1
  fi

  # Collect Installation ID
  read -p "Enter GitHub App Installation ID: " installation_id
  if [ -z "$installation_id" ]; then
    log_error "Installation ID is required"
    exit 1
  fi

  # Collect private key path
  read -p "Enter path to private key (.pem file): " private_key_path

  # Expand ~ to home directory
  private_key_path="${private_key_path/#\~/$HOME}"

  if [ ! -f "$private_key_path" ]; then
    log_error "Private key file not found: $private_key_path"
    exit 1
  fi

  # Store in .env.local
  log_info "Storing GitHub App credentials in .env.local..."

  # Remove old GitHub credentials if exist
  if [ -f "$ENV_LOCAL" ]; then
    if grep -q "^N8N_GITHUB_" "$ENV_LOCAL" 2>/dev/null; then
      # Create temp file without old GitHub credentials
      grep -v "^N8N_GITHUB_" "$ENV_LOCAL" > "${ENV_LOCAL}.tmp"
      mv "${ENV_LOCAL}.tmp" "$ENV_LOCAL"
    fi
  fi

  # Add new GitHub App credentials
  cat >> "$ENV_LOCAL" << EOF

# GitHub App Integration (auto-added by n8n-setup.sh)
# Scoped to repository: $repo_owner/$repo_name
N8N_GITHUB_APP_ID=$app_id
N8N_GITHUB_APP_INSTALLATION_ID=$installation_id
N8N_GITHUB_APP_PRIVATE_KEY_PATH=$private_key_path
N8N_GITHUB_REPO=$repo_owner/$repo_name
EOF

  log_success "GitHub App credentials saved to .env.local"
}

# Configure Fine-grained PAT authentication
configure_github_pat() {
  local repo_owner="$1"
  local repo_name="$2"

  echo ""
  log_info "Configuring Fine-grained Personal Access Token..."
  echo ""

  cat << EOF
Fine-grained PAT Setup Instructions:
=====================================

1. Create a new fine-grained personal access token:
   https://github.com/settings/tokens?type=beta

2. Configure the token:
   - Token name: n8n-integration-${repo_name}
   - Expiration: Choose appropriate duration (90 days recommended)
   - Description: n8n workflow automation for $repo_owner/$repo_name

3. Repository access:
   - Select "Only select repositories"
   - Choose ONLY: $repo_owner/$repo_name

4. Repository permissions:
   - Pull requests: Read and write
   - Issues: Read and write
   - Contents: Read-only
   - Checks: Read-only
   - Metadata: Read-only (automatically granted)

5. Click "Generate token"

6. COPY THE TOKEN NOW (you won't see it again!)

EOF

  echo ""
  read -p "Press Enter after creating the token..."
  echo ""

  # Collect token (hidden input)
  read -sp "Paste GitHub Personal Access Token: " github_token
  echo ""

  if [ -z "$github_token" ]; then
    log_error "Token is required"
    exit 1
  fi

  # Validate token format (should start with github_pat_ or ghp_)
  if [[ ! "$github_token" =~ ^(github_pat_|ghp_) ]]; then
    log_warn "Token doesn't match expected format (github_pat_* or ghp_*)"
    read -p "Continue anyway? (y/N): " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi

  # Store in .env.local
  log_info "Storing GitHub PAT in .env.local..."

  # Remove old GitHub credentials if exist
  if [ -f "$ENV_LOCAL" ]; then
    if grep -q "^N8N_GITHUB_" "$ENV_LOCAL" 2>/dev/null; then
      # Create temp file without old GitHub credentials
      grep -v "^N8N_GITHUB_" "$ENV_LOCAL" > "${ENV_LOCAL}.tmp"
      mv "${ENV_LOCAL}.tmp" "$ENV_LOCAL"
    fi
  fi

  # Add new GitHub PAT
  cat >> "$ENV_LOCAL" << EOF

# GitHub Personal Access Token (auto-added by n8n-setup.sh)
# Scoped to repository: $repo_owner/$repo_name
N8N_GITHUB_TOKEN=$github_token
N8N_GITHUB_REPO=$repo_owner/$repo_name
EOF

  log_success "GitHub PAT saved to .env.local"
}

# Validate GitHub credentials by making API call
validate_github_credentials() {
  local repo_owner="$1"
  local repo_name="$2"

  # Load credentials from .env.local
  if [ -f "$ENV_LOCAL" ]; then
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e
  fi

  local auth_header=""
  local using_app=false

  # Check for GitHub App credentials
  if [ -n "${N8N_GITHUB_APP_ID:-}" ] && [ -n "${N8N_GITHUB_APP_INSTALLATION_ID:-}" ] && [ -n "${N8N_GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
    log_info "Validating GitHub App credentials..."

    # For GitHub Apps, we need to generate a JWT and exchange it for an installation token
    # This is complex, so we'll do a simpler check: verify the private key file exists
    if [ ! -f "${N8N_GITHUB_APP_PRIVATE_KEY_PATH}" ]; then
      log_error "Private key file not found: ${N8N_GITHUB_APP_PRIVATE_KEY_PATH}"
      return 1
    fi

    log_info "Note: Full GitHub App validation requires JWT generation"
    log_info "Skipping API validation for GitHub App (will validate in n8n)"
    return 0

  # Check for PAT
  elif [ -n "${N8N_GITHUB_TOKEN:-}" ]; then
    log_info "Validating GitHub PAT..."
    auth_header="Authorization: Bearer ${N8N_GITHUB_TOKEN}"
  else
    log_error "No GitHub credentials found in .env.local"
    return 1
  fi

  # Test API access to the specific repository
  local api_url="${GITHUB_API_BASE_URL}/repos/${repo_owner}/${repo_name}"
  local response
  local http_code

  response=$(curl -sf -w "\n%{http_code}" -H "$auth_header" "$api_url" 2>/dev/null || echo "error")
  http_code=$(echo "$response" | tail -1)

  if [ "$http_code" = "200" ]; then
    log_success "API call to $api_url → 200 OK"

    # Check permissions in response headers
    local permissions_check
    permissions_check=$(curl -sI -H "$auth_header" "$api_url" 2>/dev/null | grep -i "x-oauth-scopes" || echo "")

    if [ -n "$permissions_check" ]; then
      log_info "Token scopes: $permissions_check"
    fi

    # Verify token can access PRs endpoint
    local pr_url="${GITHUB_API_BASE_URL}/repos/${repo_owner}/${repo_name}/pulls"
    local pr_response
    pr_response=$(curl -sf -H "$auth_header" "$pr_url" 2>/dev/null || echo "error")

    if [ "$pr_response" != "error" ]; then
      log_success "PR access verified: $pr_url"
    else
      log_warn "Could not verify PR access (may need pull_requests permission)"
    fi

    # Verify token can access issues endpoint
    local issue_url="${GITHUB_API_BASE_URL}/repos/${repo_owner}/${repo_name}/issues"
    local issue_response
    issue_response=$(curl -sf -H "$auth_header" "$issue_url" 2>/dev/null || echo "error")

    if [ "$issue_response" != "error" ]; then
      log_success "Issue access verified: $issue_url"
    else
      log_warn "Could not verify issue access (may need issues permission)"
    fi

    # Test that token is scoped to this repo only (try accessing a different repo)
    log_info "Verifying token is scoped to this repository only..."
    local other_repo_url="${GITHUB_API_BASE_URL}/repos/${GITHUB_TEST_REPO}"
    local other_repo_response
    other_repo_response=$(curl -sf -w "\n%{http_code}" -H "$auth_header" "$other_repo_url" 2>/dev/null || echo -e "error\n403")
    local other_http_code=$(echo "$other_repo_response" | tail -1)

    if [ "$other_http_code" = "404" ] || [ "$other_http_code" = "403" ]; then
      log_success "Token correctly scoped: cannot access other repositories"
    else
      log_warn "Token may have broader scope than intended (can access other repos)"
    fi

    return 0
  elif [ "$http_code" = "404" ]; then
    log_error "Repository not found: $repo_owner/$repo_name (404)"
    log_error "Either the repository doesn't exist or token lacks access"
    return 1
  elif [ "$http_code" = "401" ]; then
    log_error "Authentication failed: Invalid or expired token (401)"
    return 1
  elif [ "$http_code" = "403" ]; then
    log_error "Access forbidden: Token lacks required permissions (403)"
    return 1
  else
    log_error "API call failed with HTTP code: $http_code"
    return 1
  fi
}

# Configure n8n GitHub credentials via API
configure_n8n_github_credentials() {
  log_info "Configuring n8n GitHub credentials..."

  # Load credentials
  if [ -f "$ENV_LOCAL" ]; then
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e
  fi

  # Get admin credentials for authentication
  local admin_email="github.n8n.${REPO_NAME}@lee-solutionsgroup.com"
  local admin_password="${N8N_ADMIN_PASSWORD:-}"

  if [ -z "$admin_password" ]; then
    log_error "N8N_ADMIN_PASSWORD not found in .env.local"
    return 1
  fi

  # Login to get session cookie
  local cookie_jar=$(mktemp)
  local login_response
  login_response=$(curl -sf -X POST "$N8N_URL/rest/login" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$admin_email\",\"password\":\"$admin_password\"}" \
    -c "$cookie_jar" 2>/dev/null || echo "")

  if ! echo "$login_response" | jq -e '.data' &>/dev/null; then
    log_error "Authentication failed for n8n credential creation"
    rm -f "$cookie_jar"
    return 1
  fi

  # Check if GitHub credential already exists
  local existing_creds
  existing_creds=$(curl -sf "$N8N_URL/rest/credentials" \
    -b "$cookie_jar" 2>/dev/null || echo "")

  local github_cred_id=""
  if echo "$existing_creds" | jq -e '.data[] | select(.name == "GitHub Token")' &>/dev/null; then
    github_cred_id=$(echo "$existing_creds" | jq -r '.data[] | select(.name == "GitHub Token") | .id')
    log_info "Found existing GitHub credential (ID: $github_cred_id)"
  fi

  # Prepare credential payload based on auth type
  local cred_payload=""

  if [ -n "${N8N_GITHUB_TOKEN:-}" ]; then
    # Use HTTP Header Auth for PAT
    cred_payload=$(jq -n \
      --arg token "${N8N_GITHUB_TOKEN}" \
      '{
        name: "GitHub Token",
        type: "httpHeaderAuth",
        data: {
          name: "Authorization",
          value: ("Bearer " + $token)
        }
      }')
  elif [ -n "${N8N_GITHUB_APP_ID:-}" ]; then
    log_warn "GitHub App credentials require manual configuration in n8n UI"
    log_info "Please configure GitHub App credentials manually:"
    echo "  1. Open n8n UI: $N8N_URL"
    echo "  2. Go to Credentials > Add Credential"
    echo "  3. Search for 'GitHub' and select 'GitHub App'"
    echo "  4. Enter App ID: ${N8N_GITHUB_APP_ID}"
    echo "  5. Enter Installation ID: ${N8N_GITHUB_APP_INSTALLATION_ID}"
    echo "  6. Upload private key: ${N8N_GITHUB_APP_PRIVATE_KEY_PATH}"
    rm -f "$cookie_jar"
    return 0
  else
    log_error "No GitHub credentials found in .env.local"
    rm -f "$cookie_jar"
    return 1
  fi

  # Create or update credential
  if [ -n "$github_cred_id" ]; then
    log_info "Updating existing GitHub credential..."
    # Note: Update might require special handling, for now we'll skip
    log_warn "Automatic update not implemented - please update manually in n8n UI if needed"
  else
    log_info "Creating new GitHub credential in n8n..."
    local create_response
    create_response=$(curl -sf -X POST "$N8N_URL/rest/credentials" \
      -H "Content-Type: application/json" \
      -b "$cookie_jar" \
      -d "$cred_payload" 2>/dev/null || echo "")

    if echo "$create_response" | jq -e '.data' &>/dev/null; then
      log_success "GitHub credential created in n8n"
    else
      log_warn "Could not create GitHub credential automatically"
      log_info "Please create manually in n8n UI: $N8N_URL/credentials"
    fi
  fi

  rm -f "$cookie_jar"
  return 0
}

# ============================================================
# STEP 8: Verify version pinning
# ============================================================

step_8_verify_version() {
  log_info "Step 7: Verifying n8n version..."
  echo ""

  # Get pinned version from docker-compose file
  local pinned_version
  pinned_version=$(grep -E "image:.*n8n" "$COMPOSE_FILE" | sed 's/.*://g' | tr -d ' ' || echo "")

  if [ -z "$pinned_version" ]; then
    log_warn "Could not extract pinned version from $COMPOSE_FILE"
    echo ""
    log_success "Step 8 complete: Version check skipped"
    echo ""
    return 0
  fi

  log_info "Pinned version: $pinned_version"

  # Get running version from container
  local running_version
  running_version=$(docker exec n8n-local n8n --version 2>/dev/null | head -1 || echo "")

  if [ -z "$running_version" ]; then
    log_warn "Could not get running version from container"
    echo ""
    log_success "Step 8 complete: Version check incomplete"
    echo ""
    return 0
  fi

  log_info "Running version: $running_version"

  # Compare versions (simple string match)
  if echo "$running_version" | grep -q "$pinned_version"; then
    log_success "Version match confirmed"
  else
    log_warn "Version mismatch detected"
    log_warn "  Pinned:  $pinned_version"
    log_warn "  Running: $running_version"
    echo ""
    echo "Remediation:"
    echo "  - Update docker-compose.n8n.yml with correct version"
    echo "  - Or restart with latest: $0 --force"
    echo ""
  fi

  echo ""
  log_success "Step 8 complete: Version verification done"
  echo ""
}

# ============================================================
# STEP 9: Import and activate workflows
# ============================================================

step_9_import_workflows() {
  log_info "Step 9: Importing workflows..."
  echo ""

  # Check if import script exists
  local import_script="${SCRIPT_DIR}/n8n-import-workflows.sh"
  if [ ! -x "$import_script" ]; then
    log_error "n8n-import-workflows.sh not found or not executable"
    echo ""
    echo "Remediation:"
    echo "  - Ensure the import script exists: $import_script"
    echo "  - Make it executable: chmod +x $import_script"
    echo ""
    return 1
  fi

  # Check if workflows directory exists
  local workflows_dir="$REPO_ROOT/${WORKFLOWS_DIR_NAME}"
  if [ ! -d "$workflows_dir" ]; then
    log_warn "Workflows directory not found: $workflows_dir"
    log_info "Skipping workflow import (no workflows to import)"
    echo ""
    log_success "Step 9 complete: No workflows to import"
    echo ""
    return 0
  fi

  # Count workflow files
  local workflow_count
  workflow_count=$(find "$workflows_dir" -name "*.json" -type f -not -path "*/${WORKFLOWS_TEST_FIXTURES_DIR}/*" | wc -l | tr -d ' ')

  if [ "$workflow_count" -eq 0 ]; then
    log_warn "No workflow files found in: $workflows_dir"
    log_info "Skipping workflow import"
    echo ""
    log_success "Step 9 complete: No workflows to import"
    echo ""
    return 0
  fi

  log_info "Found $workflow_count workflow(s) to import"
  echo ""

  # Run import script
  log_info "Running workflow import script..."
  echo ""
  echo "──────────────────────────────────────────────────────────────"
  echo ""

  if "$import_script"; then
    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo ""
    log_success "Workflows imported and activated successfully"
  else
    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo ""
    log_error "Workflow import completed with errors"
    echo ""
    echo "Remediation:"
    echo "  - Check n8n logs: docker logs n8n-local"
    echo "  - Verify API key is valid in .env.local"
    echo "  - Verify GitHub credentials are configured"
    echo "  - Re-run import: $import_script"
    echo ""
    log_warn "Step 9 complete: Workflow import had errors (see above)"
    echo ""
    return 1
  fi

  echo ""
  log_success "Step 9 complete: All workflows imported and activated"
  echo ""
}

# ============================================================
# State Management
# ============================================================

save_state() {
  local status="$1"
  local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat > "$STATE_FILE" << EOF
{
  "status": "$status",
  "timestamp": "$timestamp",
  "container": "n8n-local",
  "network": "$SHARED_NETWORK",
  "port": $N8N_PORT,
  "compose_file": "$COMPOSE_FILE",
  "env_file": "$ENV_LOCAL"
}
EOF
}

load_state() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE"
  else
    echo "{}"
  fi
}

# ============================================================
# Summary
# ============================================================

print_summary() {
  local admin_email="github.n8n.${REPO_NAME}@lee-solutionsgroup.com"

  # Extract pinned version
  local pinned_version
  pinned_version=$(grep -E "image:.*n8n" "$COMPOSE_FILE" | sed 's/.*://g' | tr -d ' ' || echo "unknown")

  # Load GitHub credentials
  local github_auth_type="Not configured"
  local github_repo="Not set"

  if [ -f "$ENV_LOCAL" ]; then
    set +e
    source "$ENV_LOCAL" 2>/dev/null
    set -e

    github_repo="${N8N_GITHUB_REPO:-Not set}"

    if [ -n "${N8N_GITHUB_APP_ID:-}" ]; then
      github_auth_type="GitHub App (ID: ${N8N_GITHUB_APP_ID})"
    elif [ -n "${N8N_GITHUB_TOKEN:-}" ]; then
      github_auth_type="Fine-grained PAT"
    fi
  fi

  echo ""
  echo "=========================================="
  echo "  n8n Setup Complete!"
  echo "=========================================="
  echo ""
  log_success "n8n is running and healthy"
  echo ""
  echo "Access:"
  echo "  UI:        $N8N_URL"
  echo "  Health:    $N8N_URL/healthz"
  echo "  Webhooks:  $N8N_URL/webhook/<workflow-path>"
  echo ""
  echo "Admin Account:"
  echo "  Email:     $admin_email"
  echo "  Password:  (stored in .env.local as N8N_ADMIN_PASSWORD)"
  echo "  API Key:   (stored in .env.local as N8N_API_KEY)"
  echo ""
  echo "GitHub Integration:"
  echo "  Auth Type: $github_auth_type"
  echo "  Repo:      $github_repo"
  echo "  Config:    See .env.local for details"
  echo ""
  echo "Container:"
  echo "  Name:      n8n-local"
  echo "  Version:   $pinned_version"
  echo "  Network:   $SHARED_NETWORK (shared)"
  echo "  Binding:   localhost:$N8N_PORT (localhost-only)"
  echo ""
  echo "Files:"
  echo "  State:     $STATE_FILE"
  echo "  Config:    $ENV_LOCAL"
  echo "  Compose:   $COMPOSE_FILE"
  echo ""
  echo "Workflows:"
  local workflow_count
  workflow_count=$(find "$REPO_ROOT/${WORKFLOWS_DIR_NAME}" -name "*.json" -type f -not -path "*/${WORKFLOWS_TEST_FIXTURES_DIR}/*" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
  echo "  Total:     $workflow_count workflow(s) imported"
  echo "  Import:    ./scripts/n8n-import-workflows.sh"
  echo ""
  echo "Commands:"
  echo "  Stop:      ./scripts/n8n-stop.sh"
  echo "  Logs:      docker logs -f n8n-local"
  echo "  Health:    ./scripts/n8n-health.sh"
  echo "  Restart:   $0 --force"
  echo ""
  echo "=========================================="
  echo ""
}

# ============================================================
# Main
# ============================================================

main() {
  # Handle --validate-only mode
  if [ "$VALIDATE_ONLY" = true ]; then
    echo ""
    echo "=========================================="
    echo "  n8n Health Validation"
    echo "=========================================="
    echo ""

    # Run container health check
    local health_script="${SCRIPT_DIR}/n8n-health.sh"
    if [ ! -x "$health_script" ]; then
      log_error "n8n-health.sh not found"
      exit 1
    fi

    log_info "Running container health check..."
    if ! "$health_script" --include-workflows; then
      log_error "Health check failed"
      exit 1
    fi

    echo ""
    log_success "All health checks passed"
    echo ""
    exit 0
  fi

  # Normal setup mode
  echo ""
  echo "=========================================="
  echo "  n8n Setup Wizard"
  echo "=========================================="
  echo ""

  if [ "$FORCE_RESTART" = true ]; then
    log_info "Force restart mode enabled"
    echo ""
  fi

  # Run setup steps
  step_1_check_docker
  step_2_check_env
  step_3_start_container
  step_4_health_check
  step_5_create_admin
  step_6_generate_api_key
  step_7_configure_github
  step_8_verify_version
  step_9_import_workflows

  # Print summary
  print_summary
}

main
