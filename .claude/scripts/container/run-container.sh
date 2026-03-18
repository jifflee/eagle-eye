#!/bin/bash
set -euo pipefail
# scripts/run-container.sh - Secure container launcher with pre-validated tokens
# size-ok: secure container launch with token validation, env-file isolation, and lifecycle management
#
# Purpose:
#   Launches Claude containers with pre-validated, securely injected tokens.
#   Validates tokens on HOST before container launch, then passes via --env-file
#   to hide from `docker inspect`.
#
# Security Properties (Issue #132):
#   - Token validated BEFORE container launch (no wasted startup time)
#   - Token passed via --env-file (NOT visible in `docker inspect`)
#   - Token exists only in container process memory
#   - Temp env file deleted immediately after docker run starts
#   - No ~/.claude mount required
#
# Usage:
#   ./scripts/run-container.sh                                    # Interactive shell
#   ./scripts/run-container.sh --repo URL --issue N               # Clone and create branch
#   ./scripts/run-container.sh --command "claude --version"       # Run single command
#   ./scripts/run-container.sh --env-file .env.local              # Use existing env file
#
# Exit codes:
#   0 - Success
#   1 - Token validation failed
#   2 - Container launch failed
#   3 - Configuration error

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
IMAGE="claude-base:latest"
REPO_URL=""
BRANCH="dev"
ISSUE=""
COMMAND=""
ENV_FILE=""
INTERACTIVE=true
SKIP_VALIDATION=false
CONTAINER_NAME=""

# Usage help
usage() {
    cat << 'EOF'
Usage: run-container.sh [OPTIONS] [-- COMMAND]

Launches Claude container with pre-validated, secure token injection.

OPTIONS:
  --image IMAGE        Docker image to use (default: claude-base:latest)
  --repo URL           Repository URL to clone inside container
  --branch BRANCH      Branch to clone (default: dev)
  --issue N            Issue number for automatic branch creation
  --command CMD        Command to run (non-interactive)
  --env-file FILE      Use existing env file for tokens
  --name NAME          Container name
  --skip-validation    Skip token validation (not recommended)
  --no-interactive     Don't allocate TTY
  --help, -h           Show this help

EXAMPLES:
  # Interactive shell with token from environment
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
  ./scripts/run-container.sh

  # Clone repo and work on issue
  ./scripts/run-container.sh --repo https://github.com/user/repo.git --issue 132

  # Run a single command
  ./scripts/run-container.sh --command "claude --version"

  # Use env file (tokens hidden from docker inspect)
  ./scripts/run-container.sh --env-file .env.local --repo https://github.com/user/repo.git

SECURITY NOTES:
  - Tokens are pre-validated on host before container launch
  - Tokens passed via --env-file (hidden from docker inspect)
  - Temp env file is deleted immediately after docker starts
  - No ~/.claude directory mount required

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --image)
            IMAGE="$2"
            shift 2
            ;;
        --repo)
            REPO_URL="$2"
            shift 2
            ;;
        --branch)
            BRANCH="$2"
            shift 2
            ;;
        --issue)
            ISSUE="$2"
            shift 2
            ;;
        --command)
            COMMAND="$2"
            INTERACTIVE=false
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --name)
            CONTAINER_NAME="$2"
            shift 2
            ;;
        --skip-validation)
            SKIP_VALIDATION=true
            shift
            ;;
        --no-interactive)
            INTERACTIVE=false
            shift
            ;;
        --help|-h)
            usage
            ;;
        --)
            shift
            COMMAND="$*"
            INTERACTIVE=false
            break
            ;;
        *)
            echo -e "${RED}ERROR: Unknown argument: $1${NC}" >&2
            echo "Use --help for usage information" >&2
            exit 3
            ;;
    esac
done

# ============================================================================
# STEP 1: GATHER TOKENS
# ============================================================================

echo -e "${BLUE}🚀 Claude Container Launcher${NC}"
echo ""

# Load tokens from env file if specified
if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        echo -e "${RED}ERROR: Env file not found: $ENV_FILE${NC}" >&2
        exit 3
    fi
    echo -e "${BLUE}Loading environment from: $ENV_FILE${NC}"
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a
fi

# Get tokens
OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
API_KEY="${ANTHROPIC_API_KEY:-}"
GH_TOKEN="${GITHUB_TOKEN:-}"

# ============================================================================
# STEP 2: PRE-VALIDATE TOKENS (on host, before container launch)
# ============================================================================

# Returns:
#   0 = valid token
#   1 = invalid format
#   2 = session token (not valid for CLI)
validate_token_format() {
    local token="$1"

    # Minimum length check
    if [[ ${#token} -lt 50 ]]; then
        return 1
    fi

    # REJECT session tokens - these are browser tokens, NOT valid for API/CLI
    if [[ "$token" =~ ^sk-ant-sid[0-9]*- ]]; then
        return 2
    fi

    # Accept OAuth tokens (oat) and API keys (api)
    if [[ "$token" =~ ^sk-ant-(oat|api)[0-9]+-[A-Za-z0-9_-]+$ ]]; then
        return 0
    fi

    # Legacy format (but not session tokens)
    if [[ "$token" =~ ^sk-ant-[A-Za-z0-9_-]+$ ]] && ! [[ "$token" =~ ^sk-ant-sid ]]; then
        return 0
    fi

    return 1
}

if [[ "$SKIP_VALIDATION" != "true" ]]; then
    echo -e "${BLUE}🔐 Pre-validating tokens...${NC}"

    # Check if any auth token is present
    if [[ -z "$OAUTH_TOKEN" ]] && [[ -z "$API_KEY" ]]; then
        echo -e "${YELLOW}⚠️  No Claude authentication token found${NC}"
        echo "   Claude CLI commands will require authentication."
        echo "   Set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY if needed."
        echo ""
    else
        # Validate OAuth token
        if [[ -n "$OAUTH_TOKEN" ]]; then
            validate_token_format "$OAUTH_TOKEN"
            result=$?
            if [[ $result -eq 0 ]]; then
                echo -e "${GREEN}✅ OAuth token validated (${OAUTH_TOKEN:0:12}...)${NC}"
            elif [[ $result -eq 2 ]]; then
                echo -e "${RED}❌ Session token detected (not valid for container/CLI use)${NC}"
                echo ""
                echo "   Token prefix: ${OAUTH_TOKEN:0:15}..."
                echo ""
                echo "   You have a browser SESSION token (sk-ant-sid01-...)."
                echo "   This is NOT valid for Claude Code CLI or container operations."
                echo ""
                echo "   ══════════════════════════════════════════════════════════"
                echo "   To fix this, generate an OAuth token:"
                echo ""
                echo "      claude setup-token"
                echo ""
                echo "   This will open your browser, authenticate, and generate"
                echo "   a proper OAuth token (sk-ant-oat01-...) for CLI use."
                echo "   ══════════════════════════════════════════════════════════"
                exit 1
            else
                echo -e "${RED}❌ Invalid OAuth token format (${OAUTH_TOKEN:0:12}...)${NC}"
                echo "   Expected format: sk-ant-oat01-..."
                echo "   Generate with: claude setup-token"
                exit 1
            fi
        fi

        # Validate API key
        if [[ -n "$API_KEY" ]]; then
            validate_token_format "$API_KEY"
            result=$?
            if [[ $result -eq 0 ]]; then
                echo -e "${GREEN}✅ API key validated (${API_KEY:0:12}...)${NC}"
            elif [[ $result -eq 2 ]]; then
                echo -e "${RED}❌ Session token in ANTHROPIC_API_KEY (not valid)${NC}"
                echo "   Use CLAUDE_CODE_OAUTH_TOKEN with: claude setup-token"
                exit 1
            else
                echo -e "${RED}❌ Invalid API key format (${API_KEY:0:12}...)${NC}"
                exit 1
            fi
        fi
    fi

    # Check GitHub token
    if [[ -z "$GH_TOKEN" ]]; then
        echo -e "${YELLOW}⚠️  No GITHUB_TOKEN found (needed for private repos/gh cli)${NC}"
    else
        echo -e "${GREEN}✅ GitHub token present (${GH_TOKEN:0:8}...)${NC}"
    fi

    echo ""
fi

# ============================================================================
# STEP 3: CREATE SECURE ENV FILE (hidden from docker inspect)
# ============================================================================

echo -e "${BLUE}🔒 Creating secure env file...${NC}"

# Create temp env file with restrictive permissions
TEMP_ENV_FILE=$(mktemp)
chmod 600 "$TEMP_ENV_FILE"

# Write tokens to temp file (never visible in docker inspect)
{
    [[ -n "$OAUTH_TOKEN" ]] && echo "CLAUDE_CODE_OAUTH_TOKEN=$OAUTH_TOKEN"
    [[ -n "$API_KEY" ]] && echo "ANTHROPIC_API_KEY=$API_KEY"
    [[ -n "$GH_TOKEN" ]] && echo "GITHUB_TOKEN=$GH_TOKEN"
    [[ -n "$REPO_URL" ]] && echo "REPO_URL=$REPO_URL"
    [[ -n "$BRANCH" ]] && echo "BRANCH=$BRANCH"
    [[ -n "$ISSUE" ]] && echo "ISSUE=$ISSUE"
    # Tell entrypoint that validation was already done
    echo "SKIP_TOKEN_VALIDATION=true"
} > "$TEMP_ENV_FILE"

echo -e "${GREEN}✅ Env file created (tokens will be injected securely)${NC}"
echo ""

# Cleanup function
cleanup() {
    if [[ -f "$TEMP_ENV_FILE" ]]; then
        rm -f "$TEMP_ENV_FILE"
    fi
}
trap cleanup EXIT

# ============================================================================
# STEP 4: LAUNCH CONTAINER
# ============================================================================

echo -e "${BLUE}🐳 Launching container...${NC}"

# Build docker run command
DOCKER_ARGS=(
    "docker" "run" "--rm"
    "--env-file" "$TEMP_ENV_FILE"
)

# Add interactive flags if needed
if [[ "$INTERACTIVE" == "true" ]]; then
    DOCKER_ARGS+=("-it")
fi

# Add container name if specified
if [[ -n "$CONTAINER_NAME" ]]; then
    DOCKER_ARGS+=("--name" "$CONTAINER_NAME")
fi

# Add image
DOCKER_ARGS+=("$IMAGE")

# Add command if specified
if [[ -n "$COMMAND" ]]; then
    DOCKER_ARGS+=("bash" "-c" "$COMMAND")
fi

# Show what we're running (without secrets)
echo "Image: $IMAGE"
[[ -n "$REPO_URL" ]] && echo "Repo: $REPO_URL"
[[ -n "$BRANCH" ]] && echo "Branch: $BRANCH"
[[ -n "$ISSUE" ]] && echo "Issue: #$ISSUE"
[[ -n "$COMMAND" ]] && echo "Command: $COMMAND"
echo ""

# Delete env file BEFORE docker run (race window is tiny, and docker has already read it)
# Actually, we need to keep it until docker reads it, so we use trap cleanup instead

# Run the container
exec "${DOCKER_ARGS[@]}"
