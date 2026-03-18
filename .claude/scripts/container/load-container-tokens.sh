#!/bin/bash
set -euo pipefail
# load-container-tokens.sh
# Securely load tokens for container execution
# Tokens are stored in macOS Keychain
# size-ok: multi-source token loading with keychain, env, and fallback strategies

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

KEYCHAIN_SERVICE_CLAUDE="claude-oauth-token"
KEYCHAIN_SERVICE_GITHUB="github-container-token"

usage() {
    cat << EOF
Usage: $0 <command>

Commands:
    setup       Store tokens in keychain (interactive menu)
                - Update GitHub token only
                - Update Claude token only
                - Update both tokens
    load        Export tokens to current shell (use with 'source')
    status      Check if tokens are configured
    clear       Remove tokens from keychain

Examples:
    $0 setup                    # Interactive setup with token selection menu
    source $0 load              # Load tokens before container launch
    eval "\$($0 load)"          # Alternative load method
EOF
}

store_token() {
    local service="$1"
    local prompt="$2"
    local token=""
    local line=""

    echo -e "${YELLOW}$prompt${NC}"
    echo ""
    echo "  Paste your token below. If it spans multiple lines, paste all of it."
    echo "  Press Enter twice (empty line) when done."
    echo ""
    echo -n "Token: "

    # Read lines until we get an empty line
    # This handles tokens that wrap or span multiple lines when pasted
    while IFS= read -r -s line; do
        # Empty line signals end of input
        if [ -z "$line" ]; then
            break
        fi
        # Concatenate lines (remove any whitespace that might have been added)
        token="${token}${line}"
    done
    echo ""

    # Remove any accidental whitespace from the token
    token=$(echo "$token" | tr -d '[:space:]')

    if [ -n "$token" ]; then
        # Validate token format
        local token_len=${#token}
        if [ $token_len -lt 50 ]; then
            echo -e "${RED}✗ Token appears too short ($token_len chars). Expected 50+ chars.${NC}"
            echo -e "${YELLOW}  Make sure you pasted the complete token.${NC}"
            return 1
        fi

        # Show token prefix for verification
        echo -e "  Token prefix: ${token:0:15}..."
        echo -e "  Token length: $token_len characters"
        echo ""

        # Delete existing if present
        security delete-generic-password -a "$USER" -s "$service" 2>/dev/null || true
        # Add new
        security add-generic-password -a "$USER" -s "$service" -w "$token"
        echo -e "${GREEN}✓ Token stored in keychain${NC}"
    else
        echo -e "${RED}✗ No token provided${NC}"
        return 1
    fi
}

get_token() {
    local service="$1"
    security find-generic-password -a "$USER" -s "$service" -w 2>/dev/null
}

check_token_exists() {
    local service="$1"
    get_token "$service" >/dev/null 2>&1
}

show_token_status() {
    echo ""
    echo "Current token status:"
    if check_token_exists "$KEYCHAIN_SERVICE_GITHUB"; then
        echo -e "  GitHub Token:  ${GREEN}✓ Configured${NC}"
    else
        echo -e "  GitHub Token:  ${YELLOW}○ Not configured${NC}"
    fi
    if check_token_exists "$KEYCHAIN_SERVICE_CLAUDE"; then
        echo -e "  Claude Token:  ${GREEN}✓ Configured${NC}"
    else
        echo -e "  Claude Token:  ${YELLOW}○ Not configured${NC}"
    fi
    echo ""
}

setup_github_token() {
    echo ""
    echo "GitHub Token"
    echo "  You can get this from: gh auth token"
    echo "  Or create a PAT at: https://github.com/settings/tokens"
    echo ""
    store_token "$KEYCHAIN_SERVICE_GITHUB" "Enter GitHub Token (scopes: repo, workflow):"
}

setup_claude_token() {
    echo ""
    echo "Claude OAuth Token"
    echo "  Get this by running the OAuth flow and capturing the token."
    echo "  The token starts with 'sk-ant-oat01-' or similar."
    echo ""
    store_token "$KEYCHAIN_SERVICE_CLAUDE" "Enter Claude OAuth Token:"
}

cmd_setup() {
    echo "=== Container Token Setup ==="
    echo ""
    echo "This will store tokens securely in macOS Keychain."

    show_token_status

    echo "Which token(s) would you like to update?"
    echo ""
    echo "  1) GitHub token only"
    echo "  2) Claude token only"
    echo "  3) Both tokens"
    echo "  q) Cancel"
    echo ""
    echo -n "Select option [1/2/3/q]: "
    read -r choice

    case "$choice" in
        1)
            echo ""
            echo -e "${YELLOW}Updating GitHub token only (Claude token preserved)${NC}"
            setup_github_token
            ;;
        2)
            echo ""
            echo -e "${YELLOW}Updating Claude token only (GitHub token preserved)${NC}"
            setup_claude_token
            ;;
        3)
            echo ""
            echo -e "${YELLOW}Updating both tokens${NC}"
            setup_github_token
            echo ""
            setup_claude_token
            ;;
        q|Q)
            echo ""
            echo "Setup cancelled."
            return 0
            ;;
        *)
            echo ""
            echo -e "${RED}Invalid option. Please enter 1, 2, 3, or q.${NC}"
            return 1
            ;;
    esac

    echo ""
    echo -e "${GREEN}=== Setup Complete ===${NC}"
    show_token_status
    echo "To use tokens, run:"
    echo "  source ./scripts/load-container-tokens.sh load"
    echo "  ./scripts/container-launch.sh --issue N --repo owner/repo"
}

mask_token() {
    local token="$1"
    local len=${#token}
    if [ $len -gt 6 ]; then
        echo "${token:0:3}...${token: -3}"
    else
        echo "***"
    fi
}

cmd_load() {
    # Output export commands that can be eval'd or sourced
    # When stdout is a terminal (running directly): show masked tokens only
    # When stdout is piped (eval/source): output real tokens for shell to consume
    local github_token=$(get_token "$KEYCHAIN_SERVICE_GITHUB" 2>/dev/null)
    local claude_token=$(get_token "$KEYCHAIN_SERVICE_CLAUDE" 2>/dev/null)
    local github_source="keychain"
    local is_terminal=false

    # Check if stdout is a terminal (vs being piped to eval/source)
    if [ -t 1 ]; then
        is_terminal=true
    fi

    if [ -z "$github_token" ]; then
        # Fallback to gh auth
        github_token=$(gh auth token 2>/dev/null)
        github_source="gh auth"
    fi

    if [ -n "$github_token" ]; then
        if [ "$is_terminal" = true ]; then
            # Running directly - show masked version
            echo -e "${GREEN}✓ GITHUB_TOKEN${NC} loaded (${github_source}): $(mask_token "$github_token")"
        else
            # Being piped to eval/source - output real export command
            echo "export GITHUB_TOKEN='$github_token'"
            echo "export GH_TOKEN='$github_token'"
            echo -e "${GREEN}✓ GITHUB_TOKEN${NC} loaded (${github_source}): $(mask_token "$github_token")" >&2
        fi
    else
        if [ "$is_terminal" = true ]; then
            echo -e "${RED}✗ GITHUB_TOKEN${NC} not found"
        else
            echo -e "${RED}✗ GITHUB_TOKEN${NC} not found" >&2
        fi
    fi

    if [ -n "$claude_token" ]; then
        # Check for session token (not valid for CLI)
        if [[ "$claude_token" =~ ^sk-ant-sid[0-9]*- ]]; then
            local msg="${RED}✗ CLAUDE_CODE_OAUTH_TOKEN${NC} is a SESSION token (sk-ant-sid01-...)"
            local msg2="  ${RED}Session tokens are NOT valid for container/CLI operations.${NC}"
            local msg3="  ${YELLOW}Run 'claude setup-token' to generate a valid OAuth token.${NC}"
            local msg4="  ${YELLOW}Then update keychain with: $0 setup${NC}"
            if [ "$is_terminal" = true ]; then
                echo -e "$msg"
                echo -e "$msg2"
                echo -e "$msg3"
                echo -e "$msg4"
            else
                echo -e "$msg" >&2
                echo -e "$msg2" >&2
                echo -e "$msg3" >&2
                echo -e "$msg4" >&2
            fi
            # Don't export invalid token
        else
            if [ "$is_terminal" = true ]; then
                # Running directly - show masked version
                echo -e "${GREEN}✓ CLAUDE_CODE_OAUTH_TOKEN${NC} loaded (keychain): $(mask_token "$claude_token")"
            else
                # Being piped to eval/source - output real export command
                echo "export CLAUDE_CODE_OAUTH_TOKEN='$claude_token'"
                echo -e "${GREEN}✓ CLAUDE_CODE_OAUTH_TOKEN${NC} loaded (keychain): $(mask_token "$claude_token")" >&2
            fi
        fi
    else
        if [ "$is_terminal" = true ]; then
            echo -e "${YELLOW}○ CLAUDE_CODE_OAUTH_TOKEN${NC} not configured"
        else
            echo -e "${YELLOW}○ CLAUDE_CODE_OAUTH_TOKEN${NC} not configured" >&2
        fi
    fi

    # Show usage hint when running directly
    if [ "$is_terminal" = true ]; then
        echo ""
        echo "To export tokens to your shell, run:"
        echo "  eval \"\$(./scripts/load-container-tokens.sh load)\""
    fi
}

cmd_status() {
    echo "=== Token Status ==="
    echo ""

    # GitHub
    if get_token "$KEYCHAIN_SERVICE_GITHUB" >/dev/null 2>&1; then
        echo -e "GitHub Token:      ${GREEN}✓ Configured (keychain)${NC}"
    elif gh auth token >/dev/null 2>&1; then
        echo -e "GitHub Token:      ${GREEN}✓ Available (gh auth)${NC}"
    else
        echo -e "GitHub Token:      ${RED}✗ Not configured${NC}"
    fi

    # Claude
    local claude_token=$(get_token "$KEYCHAIN_SERVICE_CLAUDE" 2>/dev/null)
    if [ -n "$claude_token" ]; then
        # Check for session token (not valid for CLI)
        if [[ "$claude_token" =~ ^sk-ant-sid[0-9]*- ]]; then
            echo -e "Claude OAuth:      ${RED}✗ SESSION TOKEN (not valid for CLI)${NC}"
            echo -e "                   ${YELLOW}Run 'claude setup-token' to fix${NC}"
        elif [[ "$claude_token" =~ ^sk-ant-oat[0-9]*- ]]; then
            echo -e "Claude OAuth:      ${GREEN}✓ Configured (keychain) - OAuth token${NC}"
        elif [[ "$claude_token" =~ ^sk-ant-api[0-9]*- ]]; then
            echo -e "Claude OAuth:      ${GREEN}✓ Configured (keychain) - API key${NC}"
        else
            echo -e "Claude OAuth:      ${GREEN}✓ Configured (keychain) - Legacy format${NC}"
        fi
    else
        echo -e "Claude OAuth:      ${YELLOW}○ Not configured${NC}"
    fi

    echo ""
}

cmd_clear() {
    echo "Removing tokens from keychain..."
    security delete-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE_GITHUB" 2>/dev/null && \
        echo -e "${GREEN}✓ GitHub token removed${NC}" || \
        echo -e "${YELLOW}○ GitHub token not found${NC}"
    security delete-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE_CLAUDE" 2>/dev/null && \
        echo -e "${GREEN}✓ Claude token removed${NC}" || \
        echo -e "${YELLOW}○ Claude token not found${NC}"
}

# Main
case "${1:-}" in
    setup)  cmd_setup ;;
    load)   cmd_load ;;
    status) cmd_status ;;
    clear)  cmd_clear ;;
    *)      usage ;;
esac
