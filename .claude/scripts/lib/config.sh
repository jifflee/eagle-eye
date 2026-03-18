#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: config.sh
# Purpose: Configuration management for Claude Agent Framework
# Usage: source "$(dirname "$0")/lib/config.sh"
# Dependencies: jq, yq (for YAML parsing)
# ============================================================

# Prevent double-sourcing
if [ -n "${_CONFIG_SH_LOADED:-}" ]; then
  return 0
fi
readonly _CONFIG_SH_LOADED=1

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/common.sh"

# ============================================================
# Configuration File Locations
# ============================================================

readonly PROJECT_CONFIG_FILE=".claude/project-config.json"
readonly CONFIG_FILE=".claude/project-config.json"  # Alias for backward compatibility
readonly AGENTS_CONFIG_FILE="${AGENTS_CONFIG_FILE:-.claude-agents.config.yml}"

# ============================================================
# Project Config Read Functions (JSON-based)
# ============================================================

# Get the full project config as JSON
# Usage: config=$(get_project_config)
get_project_config() {
  local repo_root
  repo_root=$(get_repo_root) || die "Not in a git repository"

  local config_path="$repo_root/$PROJECT_CONFIG_FILE"

  if [ ! -f "$config_path" ]; then
    echo "{}" # Return empty object if config doesn't exist
    return 0
  fi

  cat "$config_path"
}

# Get a specific config value
# Usage: value=$(get_config_value "corporate_managed")
# Returns: The value or empty string if not found
get_config_value() {
  local key="$1"
  local config
  config=$(get_project_config)

  echo "$config" | jq -r --arg key "$key" '.[$key] // empty'
}

# Check if config exists
# Usage: if config_exists; then ...
config_exists() {
  local repo_root
  repo_root=$(get_repo_root) || return 1

  [ -f "$repo_root/$PROJECT_CONFIG_FILE" ]
}

# ============================================================
# Project Config Write Functions (JSON-based)
# ============================================================

# Set a config value
# Usage: set_config_value "corporate_managed" "true"
set_config_value() {
  local key="$1"
  local value="$2"

  local repo_root
  repo_root=$(get_repo_root) || die "Not in a git repository"

  local config_path="$repo_root/$PROJECT_CONFIG_FILE"
  local config

  # Ensure .claude directory exists
  mkdir -p "$(dirname "$config_path")"

  # Load existing config or create new
  if [ -f "$config_path" ]; then
    config=$(cat "$config_path")
  else
    config="{}"
  fi

  # Update the config
  config=$(echo "$config" | jq --arg key "$key" --arg value "$value" '.[$key] = $value')

  # Write back
  echo "$config" | jq '.' > "$config_path"
}

# Set multiple config values at once
# Usage: set_config_values '{"corporate_managed": "true", "github_repo": "owner/repo"}'
set_config_values() {
  local updates="$1"

  local repo_root
  repo_root=$(get_repo_root) || die "Not in a git repository"

  local config_path="$repo_root/$PROJECT_CONFIG_FILE"
  local config

  # Ensure .claude directory exists
  mkdir -p "$(dirname "$config_path")"

  # Load existing config or create new
  if [ -f "$config_path" ]; then
    config=$(cat "$config_path")
  else
    config="{}"
  fi

  # Merge updates
  config=$(echo "$config" | jq --argjson updates "$updates" '. + $updates')

  # Write back
  echo "$config" | jq '.' > "$config_path"
}

# ============================================================
# Validation Functions
# ============================================================

# Validate GitHub repo format (owner/repo)
# Usage: if validate_github_repo "owner/repo"; then ...
validate_github_repo() {
  local repo="$1"
  [[ "$repo" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]
}

# Validate boolean value
# Usage: if validate_boolean "true"; then ...
validate_boolean() {
  local value="$1"
  [[ "$value" == "true" || "$value" == "false" ]]
}

# ============================================================
# Execution Mode Configuration (YAML-based)
# ============================================================

# Get execution mode default from config
# Usage: get_execution_mode_default
# Returns: docker|worktree|n8n|hybrid (defaults to worktree if not set)
get_execution_mode_default() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    echo "worktree"
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    # Fallback if yq not available
    echo "worktree"
    return 0
  fi

  local mode
  mode=$(yq eval '.execution_mode.default // "worktree"' "$AGENTS_CONFIG_FILE" 2>/dev/null)

  # Validate mode
  case "$mode" in
    docker|worktree|n8n|hybrid)
      echo "$mode"
      ;;
    *)
      echo "worktree"
      ;;
  esac
}

# Get Docker image from config
# Usage: get_docker_image
# Returns: Docker image string
get_docker_image() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    echo "ghcr.io/anthropics/claude-code:latest"
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    echo "ghcr.io/anthropics/claude-code:latest"
    return 0
  fi

  yq eval '.execution_mode.docker.image // "ghcr.io/anthropics/claude-code:latest"' "$AGENTS_CONFIG_FILE" 2>/dev/null
}

# Get Docker sync mode from config
# Usage: get_docker_sync_mode
# Returns: detached|sync
get_docker_sync_mode() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    echo "detached"
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    echo "detached"
    return 0
  fi

  yq eval '.execution_mode.docker.sync_mode // "detached"' "$AGENTS_CONFIG_FILE" 2>/dev/null
}

# Get worktree base directory from config
# Usage: get_worktree_base_dir
# Returns: Base directory path for worktrees
get_worktree_base_dir() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    echo "../"
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    echo "../"
    return 0
  fi

  yq eval '.execution_mode.worktree.base_dir // "../"' "$AGENTS_CONFIG_FILE" 2>/dev/null
}

# Get n8n webhook URL from config
# Usage: get_n8n_webhook_url
# Returns: n8n webhook URL
get_n8n_webhook_url() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    echo "http://localhost:5678/webhook"
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    echo "http://localhost:5678/webhook"
    return 0
  fi

  yq eval '.execution_mode.n8n.webhook_url // "http://localhost:5678/webhook"' "$AGENTS_CONFIG_FILE" 2>/dev/null
}

# Check if dependency validation is enabled
# Usage: is_dependency_validation_enabled
# Returns: 0 if enabled, 1 if disabled
is_dependency_validation_enabled() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    return 0  # Enabled by default
  fi

  if ! command -v yq &> /dev/null; then
    return 0  # Enabled by default
  fi

  local enabled
  enabled=$(yq eval '.execution_mode.validate_dependencies // true' "$AGENTS_CONFIG_FILE" 2>/dev/null)

  if [ "$enabled" = "true" ]; then
    return 0
  else
    return 1
  fi
}

# ============================================================
# Dependency Validation Functions
# ============================================================

# Check if Docker is available and running
# Usage: check_docker_available
# Returns: 0 if available, 1 if not
check_docker_available() {
  if ! command -v docker &> /dev/null; then
    return 1
  fi

  if ! docker info &> /dev/null; then
    return 1
  fi

  return 0
}

# Check if git worktree is available
# Usage: check_worktree_available
# Returns: 0 if available, 1 if not
check_worktree_available() {
  if ! command -v git &> /dev/null; then
    return 1
  fi

  if ! git worktree list &> /dev/null; then
    return 1
  fi

  return 0
}

# Check if n8n is available and running
# Usage: check_n8n_available
# Returns: 0 if available, 1 if not
check_n8n_available() {
  local webhook_url
  webhook_url=$(get_n8n_webhook_url)

  # Simple health check - try to reach the webhook endpoint
  if command -v curl &> /dev/null; then
    if curl -s -f "${webhook_url%-*}/health" &> /dev/null; then
      return 0
    fi
  fi

  # Check if n8n process is running
  if pgrep -x n8n &> /dev/null; then
    return 0
  fi

  return 1
}

# Validate dependencies for a given execution mode
# Usage: validate_execution_mode_dependencies MODE
# Arguments:
#   MODE - docker|worktree|n8n|hybrid
# Returns: 0 if dependencies met, 1 if not
validate_execution_mode_dependencies() {
  local mode="$1"

  case "$mode" in
    docker)
      if ! check_docker_available; then
        log_error "Docker is not available or not running"
        log_error "Install Docker from: https://docs.docker.com/get-docker/"
        return 1
      fi
      ;;
    worktree)
      if ! check_worktree_available; then
        log_error "Git worktree is not available"
        log_error "Ensure git is installed and you are in a git repository"
        return 1
      fi
      ;;
    n8n)
      if ! check_n8n_available; then
        log_error "n8n is not available or not running"
        log_error "Start n8n or install from: https://n8n.io/"
        return 1
      fi
      ;;
    hybrid)
      # Hybrid mode requires at least one mode to be available
      if check_docker_available; then
        return 0
      elif check_worktree_available; then
        return 0
      else
        log_error "Neither Docker nor worktree is available"
        log_error "Install Docker or ensure git is available"
        return 1
      fi
      ;;
    *)
      log_error "Unknown execution mode: $mode"
      return 1
      ;;
  esac

  return 0
}

# Get the best available execution mode for hybrid
# Usage: get_hybrid_mode
# Returns: docker|worktree (based on availability and preference)
get_hybrid_mode() {
  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    # Default: try docker, fallback to worktree
    if check_docker_available; then
      echo "docker"
    else
      echo "worktree"
    fi
    return 0
  fi

  if ! command -v yq &> /dev/null; then
    # Fallback without yq
    if check_docker_available; then
      echo "docker"
    else
      echo "worktree"
    fi
    return 0
  fi

  # Get preference order from config
  local preferences
  preferences=$(yq eval '.execution_mode.hybrid.preference_order[]' "$AGENTS_CONFIG_FILE" 2>/dev/null)

  # Try each preference in order
  while IFS= read -r pref; do
    case "$pref" in
      docker)
        if check_docker_available; then
          echo "docker"
          return 0
        fi
        ;;
      worktree)
        if check_worktree_available; then
          echo "worktree"
          return 0
        fi
        ;;
    esac
  done <<< "$preferences"

  # Final fallback
  if check_worktree_available; then
    echo "worktree"
  else
    echo "docker"
  fi
}

# ============================================================
# Configuration Update Functions
# ============================================================

# Update execution mode default in config
# Usage: set_execution_mode_default MODE
# Arguments:
#   MODE - docker|worktree|n8n|hybrid
# Returns: 0 if successful, 1 if failed
set_execution_mode_default() {
  local mode="$1"

  # Validate mode
  case "$mode" in
    docker|worktree|n8n|hybrid)
      ;;
    *)
      log_error "Invalid execution mode: $mode"
      return 1
      ;;
  esac

  if [ ! -f "$AGENTS_CONFIG_FILE" ]; then
    log_error "Config file not found: $AGENTS_CONFIG_FILE"
    return 1
  fi

  if ! command -v yq &> /dev/null; then
    log_error "yq is required to update config"
    log_error "Install from: https://github.com/mikefarah/yq"
    return 1
  fi

  # Update the config file
  yq eval ".execution_mode.default = \"$mode\"" -i "$AGENTS_CONFIG_FILE" 2>/dev/null

  if [ $? -eq 0 ]; then
    log_info "Updated execution mode to: $mode"
    return 0
  else
    log_error "Failed to update execution mode"
    return 1
  fi
}
