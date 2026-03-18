#!/bin/bash
set -euo pipefail
# scripts/validate-container-token.sh - Token validation before container launch
#
# Purpose:
#   Validates Claude OAuth token format BEFORE launching container.
#   Prevents wasted container startup time with invalid credentials.
#   Part of Phase 2: OAuth token injection and validation (#132)
#
# Usage:
#   ./scripts/validate-container-token.sh                    # Validate from env var
#   ./scripts/validate-container-token.sh --env-file FILE    # Validate from env file
#   ./scripts/validate-container-token.sh --token TOKEN      # Validate specific token
#
# Exit codes:
#   0 - Token is valid (format check passed)
#   1 - Token is missing
#   2 - Token format is invalid
#   3 - Session token detected (not valid for CLI, run: claude setup-token)
#   4 - Configuration error
#
# Security:
#   - Token is NOT printed to stdout (only masked prefix shown)
#   - Validation happens on HOST before container launch
#   - Token passed to container via env var or --env-file

set -e

# Get script directory and source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Defaults
TOKEN=""
ENV_FILE=""
QUIET=false
OUTPUT_FORMAT="text"

# Usage help
usage() {
    cat << 'EOF'
Usage: validate-container-token.sh [OPTIONS]

Validates Claude OAuth token format before container launch.

OPTIONS:
  --token TOKEN      Token to validate (not recommended - visible in ps)
  --env-file FILE    Read token from env file (recommended)
  --quiet, -q        Suppress non-error output
  --json             Output in JSON format
  --help, -h         Show this help message

EXAMPLES:
  # Validate from environment variable
  export CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..."
  ./scripts/validate-container-token.sh

  # Validate from env file (recommended for security)
  ./scripts/validate-container-token.sh --env-file .env.local

  # Quiet mode for scripting
  ./scripts/validate-container-token.sh --quiet && echo "Valid"

EXIT CODES:
  0  Token format is valid
  1  Token is missing
  2  Token format is invalid
  3  Session token detected (not valid for CLI, run: claude setup-token)
  4  Configuration error (bad arguments, missing file)

EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            TOKEN="$2"
            shift 2
            ;;
        --env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        --quiet|-q)
            QUIET=true
            shift
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "ERROR: Unknown argument: $1"
            echo "Use --help for usage information" >&2
            exit 4
            ;;
    esac
done

# JSON output
output_json() {
    local status="$1"
    local message="$2"
    local code="$3"

    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
        cat << EOF
{
  "valid": $([ "$status" == "valid" ] && echo "true" || echo "false"),
  "status": "$status",
  "message": "$message",
  "exit_code": $code
}
EOF
    fi
}

# Load token from env file if specified
if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        log_error "ERROR: Env file not found: $ENV_FILE"
        output_json "error" "Env file not found: $ENV_FILE" 4
        exit 4
    fi

    # Source the env file safely (only export statements)
    # shellcheck source=/dev/null
    set -a
    source "$ENV_FILE"
    set +a

    log_info "Loaded environment from: $ENV_FILE"
fi

# Get token (priority: --token flag > env var)
if [[ -z "$TOKEN" ]]; then
    TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
fi

# Also check ANTHROPIC_API_KEY as alternative
if [[ -z "$TOKEN" ]]; then
    TOKEN="${ANTHROPIC_API_KEY:-}"
fi

# Check if token is present
if [[ -z "$TOKEN" ]]; then
    log_error "ERROR: No authentication token found"
    log_error ""
    log_error "Set one of these environment variables:"
    log_error "  export CLAUDE_CODE_OAUTH_TOKEN=\"sk-ant-oat01-...\""
    log_error "  export ANTHROPIC_API_KEY=\"sk-ant-...\""
    log_error ""
    log_error "Or use --env-file with a file containing the token:"
    log_error "  ./scripts/validate-container-token.sh --env-file .env.local"
    log_error ""
    log_error "To generate an OAuth token:"
    log_error "  claude setup-token"
    output_json "missing" "No authentication token found" 1
    exit 1
fi

# Validate token format
# OAuth tokens: sk-ant-oat01-... (OAuth token format, from claude setup-token)
# API keys: sk-ant-api03-... (API key format, from console.anthropic.com)
# Both are valid for Claude Code authentication
#
# Session tokens: sk-ant-sid01-... (browser session, NOT valid for CLI)
# These are explicitly rejected with exit code 3

validate_token_format() {
    local token="$1"

    # Check minimum length (tokens are typically 90+ characters)
    if [[ ${#token} -lt 50 ]]; then
        return 1
    fi

    # REJECT session tokens - these are browser tokens, NOT valid for API/CLI
    # Session tokens (sk-ant-sid01-...) come from browser login, not claude setup-token
    if [[ "$token" =~ ^sk-ant-sid[0-9]*- ]]; then
        return 3  # Special exit code for session token
    fi

    # Check for valid prefixes
    # OAuth tokens: sk-ant-oat (from claude setup-token)
    # API keys: sk-ant-api (from console.anthropic.com)
    if [[ "$token" =~ ^sk-ant-(oat|api)[0-9]+-[A-Za-z0-9_-]+$ ]]; then
        return 0
    fi

    # Legacy format check (just sk-ant-)
    # But exclude session tokens that might slip through
    if [[ "$token" =~ ^sk-ant-[A-Za-z0-9_-]+$ ]] && ! [[ "$token" =~ ^sk-ant-sid ]]; then
        return 0
    fi

    return 1
}

# Get masked token for display (show first 12 chars + ...)
get_masked_token() {
    local token="$1"
    echo "${token:0:12}..."
}

# Validate token
log_info "Validating token format..."

validate_token_format "$TOKEN"
VALIDATION_RESULT=$?

if [[ $VALIDATION_RESULT -eq 0 ]]; then
    MASKED=$(get_masked_token "$TOKEN")
    log_success "Token format is valid"
    log_info "Token prefix: $MASKED"

    # Determine token type
    if [[ "$TOKEN" =~ ^sk-ant-oat ]]; then
        log_info "Token type: OAuth token"
    elif [[ "$TOKEN" =~ ^sk-ant-api ]]; then
        log_info "Token type: API key"
    else
        log_info "Token type: Legacy format"
    fi

    output_json "valid" "Token format is valid" 0
    exit 0
elif [[ $VALIDATION_RESULT -eq 3 ]]; then
    # Session token detected - provide clear, actionable guidance
    MASKED="${TOKEN:0:15}..."
    log_error "ERROR: Session token detected (not valid for container/CLI use)"
    log_error ""
    log_error "Token prefix: $MASKED"
    log_error ""
    log_error "You have a browser SESSION token (sk-ant-sid01-...)."
    log_error "This token is from logging into claude.ai in your browser."
    log_error "It is NOT valid for Claude Code CLI or container operations."
    log_error ""
    log_error "══════════════════════════════════════════════════════════"
    log_error "To fix this, generate an OAuth token:"
    log_error ""
    log_error "   claude setup-token"
    log_error ""
    log_error "This will open your browser, authenticate, and generate"
    log_error "a proper OAuth token (sk-ant-oat01-...) for CLI use."
    log_error "══════════════════════════════════════════════════════════"
    output_json "session_token" "Session token not valid for CLI - run: claude setup-token" 3
    exit 3
else
    MASKED=$(get_masked_token "$TOKEN")
    log_error "ERROR: Token format is invalid"
    log_error "Token prefix: $MASKED"
    log_error ""
    log_error "Valid token formats:"
    log_error "  OAuth token: sk-ant-oat01-xxxxxxxxxxxx..."
    log_error "  API key:     sk-ant-api03-xxxxxxxxxxxx..."
    log_error ""
    log_error "To generate a valid OAuth token:"
    log_error "  claude setup-token"
    output_json "invalid" "Token format is invalid" 2
    exit 2
fi
