#!/usr/bin/env bash
# ============================================================
# Script: framework-config.sh
# Purpose: Centralized framework naming configuration
#          Consumer repos can override via environment variable or config file
# Usage: source "$(dirname "$0")/lib/framework-config.sh"
# Dependencies: jq (optional, only needed for config-file override)
# ============================================================

# Prevent double-sourcing
if [ -n "${_FRAMEWORK_CONFIG_SH_LOADED:-}" ]; then
  return 0
fi
readonly _FRAMEWORK_CONFIG_SH_LOADED=1

# ============================================================
# Framework Name Resolution
# Priority: env var > config file > default
# ============================================================

if [ -n "${FRAMEWORK_NAME:-}" ]; then
    # 1. Already set via environment variable — use as-is
    FRAMEWORK_NAME="${FRAMEWORK_NAME}"
elif [ -f "${HOME}/.claude/framework/config.json" ] && command -v jq &>/dev/null; then
    # 2. Config file exists and jq is available — read from it
    FRAMEWORK_NAME=$(jq -r '.framework_name // "claude-agent"' "${HOME}/.claude/framework/config.json")
else
    # 3. Fall back to default
    FRAMEWORK_NAME="${FRAMEWORK_NAME:-claude-agent}"
fi

# ============================================================
# Derived Variables
# ============================================================

CONTAINER_PREFIX="${FRAMEWORK_NAME}-issue"
FRAMEWORK_DIR="${HOME}/.${FRAMEWORK_NAME}"
FRAMEWORK_LOG_DIR="${FRAMEWORK_DIR}/logs"
FRAMEWORK_CONFIG_DIR="${FRAMEWORK_DIR}/config"

export FRAMEWORK_NAME CONTAINER_PREFIX FRAMEWORK_DIR FRAMEWORK_LOG_DIR FRAMEWORK_CONFIG_DIR
