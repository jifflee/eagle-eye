#!/usr/bin/env bash
# Secrets Abstraction Layer - Dual Source Lookup
# Usage: get-secret.sh <secret-name> [--required]
#
# Lookup order:
#   1. Infisical (if configured)
#   2. macOS Keychain (fallback)
#   3. Environment variable (last resort)

set -euo pipefail

SECRET_NAME="${1:-}"
REQUIRED="${2:-}"

if [[ -z "$SECRET_NAME" ]]; then
    echo "Usage: get-secret.sh <secret-name> [--required]" >&2
    exit 1
fi

# Color output
RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DEBUG]${NC} $*" >&2
    fi
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

success() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
    fi
}

# Check if Infisical is available and configured
check_infisical() {
    if ! command -v infisical &> /dev/null; then
        debug "Infisical CLI not found"
        return 1
    fi

    if [[ ! -f "$HOME/.infisical.json" ]] && [[ -z "${INFISICAL_TOKEN:-}" ]]; then
        debug "Infisical not configured (no ~/.infisical.json or INFISICAL_TOKEN)"
        return 1
    fi

    return 0
}

# Try to get secret from Infisical
get_from_infisical() {
    local secret_name="$1"
    debug "Attempting to fetch '$secret_name' from Infisical..."

    if ! check_infisical; then
        return 1
    fi

    # Try to get the secret
    local secret_value
    if secret_value=$(infisical secrets get "$secret_name" --plain 2>/dev/null); then
        if [[ -n "$secret_value" ]]; then
            success "Retrieved '$secret_name' from Infisical"
            echo "$secret_value"
            return 0
        fi
    fi

    debug "Secret '$secret_name' not found in Infisical"
    return 1
}

# Try to get secret from macOS Keychain
get_from_keychain() {
    local secret_name="$1"
    debug "Attempting to fetch '$secret_name' from macOS Keychain..."

    if [[ "$(uname)" != "Darwin" ]]; then
        debug "Not running on macOS, skipping Keychain"
        return 1
    fi

    # Check if ks wrapper is available
    if command -v ks &> /dev/null; then
        local secret_value
        if secret_value=$(ks get "$secret_name" 2>/dev/null); then
            if [[ -n "$secret_value" ]]; then
                success "Retrieved '$secret_name' from Keychain (via ks)"
                echo "$secret_value"
                return 0
            fi
        fi
    fi

    # Fallback to security command
    local secret_value
    if secret_value=$(security find-generic-password -s "$secret_name" -w 2>/dev/null); then
        if [[ -n "$secret_value" ]]; then
            success "Retrieved '$secret_name' from Keychain (via security)"
            echo "$secret_value"
            return 0
        fi
    fi

    debug "Secret '$secret_name' not found in Keychain"
    return 1
}

# Try to get secret from environment variable
get_from_env() {
    local secret_name="$1"
    debug "Attempting to fetch '$secret_name' from environment..."

    if [[ -n "${!secret_name:-}" ]]; then
        success "Retrieved '$secret_name' from environment"
        echo "${!secret_name}"
        return 0
    fi

    debug "Secret '$secret_name' not found in environment"
    return 1
}

# Main lookup logic
main() {
    local secret_value=""

    # Try Infisical first
    if secret_value=$(get_from_infisical "$SECRET_NAME"); then
        echo "$secret_value"
        return 0
    fi

    # Fallback to Keychain
    if secret_value=$(get_from_keychain "$SECRET_NAME"); then
        echo "$secret_value"
        return 0
    fi

    # Last resort: environment variable
    if secret_value=$(get_from_env "$SECRET_NAME"); then
        echo "$secret_value"
        return 0
    fi

    # Not found anywhere
    if [[ "$REQUIRED" == "--required" ]]; then
        error "Required secret '$SECRET_NAME' not found in any source (Infisical, Keychain, Environment)"
        exit 1
    else
        debug "Optional secret '$SECRET_NAME' not found"
        return 1
    fi
}

main
