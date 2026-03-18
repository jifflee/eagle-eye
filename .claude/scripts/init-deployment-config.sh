#!/usr/bin/env bash
# ============================================================
# Script: init-deployment-config.sh
# Purpose: Interactive deployment configuration setup
# Usage:
#   ./init-deployment-config.sh
#   ./init-deployment-config.sh --non-interactive --corporate-managed=false --github-repo=owner/repo --framework-repo=owner/framework
# Feature: #685
# Parent: #678
# ============================================================

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

# ============================================================
# Constants
# ============================================================

readonly FRAMEWORK_DEFAULT_REPO="anthropics/anthropic-quickstarts"

# ============================================================
# Helper Functions
# ============================================================

# Auto-detect current GitHub repository
detect_github_repo() {
  if ! command -v gh &>/dev/null; then
    log_warn "GitHub CLI (gh) not found, cannot auto-detect repository"
    echo ""
    return 1
  fi

  local repo
  repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

  if [ -z "$repo" ]; then
    log_warn "Could not auto-detect GitHub repository"
    echo ""
    return 1
  fi

  echo "$repo"
}

# Ask yes/no question
# Usage: answer=$(ask_yes_no "Question?")
# Returns: "true" or "false"
ask_yes_no() {
  local question="$1"
  local answer

  while true; do
    read -r -p "$question (yes/no): " answer
    case "${answer,,}" in
      yes|y)
        echo "true"
        return 0
        ;;
      no|n)
        echo "false"
        return 0
        ;;
      *)
        log_warn "Please answer 'yes' or 'no'"
        ;;
    esac
  done
}

# Ask for a value with a default
# Usage: answer=$(ask_with_default "Question?" "default_value")
ask_with_default() {
  local question="$1"
  local default="$2"
  local answer

  read -r -p "$question [$default]: " answer

  if [ -z "$answer" ]; then
    echo "$default"
  else
    echo "$answer"
  fi
}

# Validate and ask for GitHub repo
# Usage: repo=$(ask_github_repo "default_value")
ask_github_repo() {
  local default="$1"
  local repo

  while true; do
    if [ -n "$default" ]; then
      repo=$(ask_with_default "Manage repo (owner/repo)" "$default")
    else
      read -r -p "Manage repo (owner/repo): " repo
    fi

    if [ -z "$repo" ]; then
      log_warn "Repository cannot be empty"
      continue
    fi

    if ! validate_github_repo "$repo"; then
      log_warn "Invalid repository format. Expected: owner/repo"
      continue
    fi

    echo "$repo"
    return 0
  done
}

# ============================================================
# Interactive Configuration Flow
# ============================================================

run_interactive_config() {
  log_info "Starting deployment configuration setup..."
  echo ""

  # Question 1: Corporate-managed endpoint
  log_info "Question 1 of 3"
  echo "Corporate-managed endpoints run in restricted mode (deny-all, approve explicitly)."
  echo "Non-corporate endpoints run in flexible mode (user controls everything)."
  echo ""
  local corporate_managed
  corporate_managed=$(ask_yes_no "Is this a corporate-managed endpoint?")
  echo ""

  # Question 2: GitHub repo (auto-detect)
  log_info "Question 2 of 3"
  echo "This is the repository where milestones, issues, and PRs are managed."
  echo ""
  local detected_repo
  detected_repo=$(detect_github_repo)

  local github_repo
  if [ -n "$detected_repo" ]; then
    log_info "Auto-detected repository: $detected_repo"
    github_repo=$(ask_github_repo "$detected_repo")
  else
    github_repo=$(ask_github_repo "")
  fi
  echo ""

  # Question 3: Framework feedback repo
  log_info "Question 3 of 3"
  echo "Where should framework feedback/issues be sent via /capture --framework?"
  echo ""
  local framework_repo
  framework_repo=$(ask_with_default "Framework feedback repo (owner/repo)" "$FRAMEWORK_DEFAULT_REPO")

  if ! validate_github_repo "$framework_repo"; then
    log_warn "Invalid framework repo format, using default: $FRAMEWORK_DEFAULT_REPO"
    framework_repo="$FRAMEWORK_DEFAULT_REPO"
  fi
  echo ""

  # Save configuration
  log_info "Saving configuration to $CONFIG_FILE..."

  local config_json
  config_json=$(jq -n \
    --arg corporate_managed "$corporate_managed" \
    --arg github_repo "$github_repo" \
    --arg framework_repo "$framework_repo" \
    '{
      corporate_managed: $corporate_managed,
      github_repo: $github_repo,
      framework_repo: $framework_repo
    }')

  set_config_values "$config_json"

  log_success "Configuration saved successfully!"
  echo ""
  echo "Configuration:"
  get_project_config | jq '.'
}

# ============================================================
# Non-Interactive Configuration
# ============================================================

run_non_interactive_config() {
  local corporate_managed=""
  local github_repo=""
  local framework_repo="$FRAMEWORK_DEFAULT_REPO"

  # Parse arguments
  for arg in "$@"; do
    case "$arg" in
      --corporate-managed=*)
        corporate_managed="${arg#*=}"
        ;;
      --github-repo=*)
        github_repo="${arg#*=}"
        ;;
      --framework-repo=*)
        framework_repo="${arg#*=}"
        ;;
      --non-interactive)
        # Skip this flag, already handled
        ;;
      *)
        log_error "Unknown argument: $arg"
        die "Usage: $0 --non-interactive --corporate-managed=<true|false> --github-repo=<owner/repo> [--framework-repo=<owner/repo>]"
        ;;
    esac
  done

  # Validate required arguments
  if [ -z "$corporate_managed" ]; then
    die "Missing required argument: --corporate-managed=<true|false>"
  fi

  if ! validate_boolean "$corporate_managed"; then
    die "Invalid value for --corporate-managed. Expected: true or false"
  fi

  if [ -z "$github_repo" ]; then
    die "Missing required argument: --github-repo=<owner/repo>"
  fi

  if ! validate_github_repo "$github_repo"; then
    die "Invalid value for --github-repo. Expected format: owner/repo"
  fi

  if ! validate_github_repo "$framework_repo"; then
    die "Invalid value for --framework-repo. Expected format: owner/repo"
  fi

  # Save configuration
  log_info "Saving configuration to $CONFIG_FILE..."

  local config_json
  config_json=$(jq -n \
    --arg corporate_managed "$corporate_managed" \
    --arg github_repo "$github_repo" \
    --arg framework_repo "$framework_repo" \
    '{
      corporate_managed: $corporate_managed,
      github_repo: $github_repo,
      framework_repo: $framework_repo
    }')

  set_config_values "$config_json"

  log_success "Configuration saved successfully!"
  echo ""
  echo "Configuration:"
  get_project_config | jq '.'
}

# ============================================================
# Main
# ============================================================

main() {
  # Check dependencies
  require_command "jq"

  # Ensure we're in a git repo
  if ! is_git_repo; then
    die "Must be run from within a git repository"
  fi

  # Check if running in non-interactive mode
  local non_interactive=false
  for arg in "$@"; do
    if [ "$arg" == "--non-interactive" ]; then
      non_interactive=true
      break
    fi
  done

  if [ "$non_interactive" == "true" ]; then
    run_non_interactive_config "$@"
  else
    # Warn if config already exists
    if config_exists; then
      log_warn "Configuration file already exists at $CONFIG_FILE"
      echo "Current configuration:"
      get_project_config | jq '.'
      echo ""
      local overwrite
      overwrite=$(ask_yes_no "Do you want to update the configuration?")
      if [ "$overwrite" != "true" ]; then
        log_info "Configuration unchanged."
        exit 0
      fi
      echo ""
    fi

    run_interactive_config
  fi
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
  main "$@"
fi
