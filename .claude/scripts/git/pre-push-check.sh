#!/usr/bin/env bash
#
# pre-push-check.sh - Git pre-push hook wrapper
#
# Purpose:
#   Run local validations before pushing to remote.
#   Uses --quick mode by default to keep push times fast.
#   Can be installed as a Git hook or run manually.
#
# Usage:
#   ./scripts/pre-push-check.sh              # Run quick validation
#   ./scripts/pre-push-check.sh --full       # Run full validation
#   ./scripts/pre-push-check.sh --install    # Install as Git hook
#   ./scripts/pre-push-check.sh --uninstall  # Remove Git hook
#
# Installation:
#   ./scripts/pre-push-check.sh --install
#
# As Git hook:
#   This script is called by Git before push with:
#     pre-push <remote-name> <remote-url>
#   Reads from stdin: <local-ref> <local-sha> <remote-ref> <remote-sha>
#
# Exit codes:
#   0 - Validations passed (push continues)
#   1 - Validations failed (push blocked)
#
# Related: Issue #362 - Add local validation suite
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HOOK_FILE="$REPO_ROOT/.git/hooks/pre-push"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
FULL_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --full|-f)
      FULL_MODE=true
      shift
      ;;
    --install)
      install_hook
      exit 0
      ;;
    --uninstall)
      uninstall_hook
      exit 0
      ;;
    --help|-h)
      echo "Usage: $0 [--full] [--install] [--uninstall] [--help]"
      echo ""
      echo "Git pre-push hook wrapper for local validations."
      echo ""
      echo "Options:"
      echo "  --full, -f       Run full validation (includes slow checks)"
      echo "  --install        Install as Git pre-push hook"
      echo "  --uninstall      Remove Git pre-push hook"
      echo "  --help, -h       Show this help message"
      echo ""
      echo "By default, runs quick validation to keep push times fast."
      exit 0
      ;;
    *)
      # When called by Git as hook, first arg is remote name
      # Just ignore it and continue
      shift
      ;;
  esac
done

# Function to install hook
install_hook() {
  local hooks_dir="$REPO_ROOT/.git/hooks"

  # Ensure hooks directory exists
  mkdir -p "$hooks_dir"

  # Check if hook already exists
  if [[ -f "$HOOK_FILE" ]]; then
    # Check if it's our hook
    if grep -q "pre-push-check.sh" "$HOOK_FILE" 2>/dev/null; then
      echo -e "${YELLOW}Hook already installed${NC}"
      exit 0
    else
      echo -e "${YELLOW}Existing pre-push hook found${NC}"
      echo "Backing up to: ${HOOK_FILE}.backup"
      mv "$HOOK_FILE" "${HOOK_FILE}.backup"
    fi
  fi

  # Create hook script
  cat > "$HOOK_FILE" << 'HOOK_CONTENT'
#!/usr/bin/env bash
#
# Git pre-push hook - runs local validation before push
# Installed by: ./scripts/pre-push-check.sh --install
#

# Get the script directory
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Run pre-push check
exec "$REPO_ROOT/scripts/pre-push-check.sh" "$@"
HOOK_CONTENT

  chmod +x "$HOOK_FILE"

  echo -e "${GREEN}Pre-push hook installed!${NC}"
  echo ""
  echo "The hook will run quick validations before each push."
  echo "To skip the hook temporarily, use: git push --no-verify"
  echo "To uninstall: ./scripts/pre-push-check.sh --uninstall"
}

# Function to uninstall hook
uninstall_hook() {
  if [[ -f "$HOOK_FILE" ]]; then
    # Check if it's our hook
    if grep -q "pre-push-check.sh" "$HOOK_FILE" 2>/dev/null; then
      rm "$HOOK_FILE"
      echo -e "${GREEN}Pre-push hook removed${NC}"

      # Restore backup if exists
      if [[ -f "${HOOK_FILE}.backup" ]]; then
        mv "${HOOK_FILE}.backup" "$HOOK_FILE"
        echo "Restored previous hook from backup"
      fi
    else
      echo -e "${YELLOW}Hook exists but was not installed by this script${NC}"
      echo "Remove manually: rm $HOOK_FILE"
      exit 1
    fi
  else
    echo "No pre-push hook installed"
  fi
}

# Function to check if we should validate this push
should_validate() {
  # When called by Git, stdin has: local-ref local-sha remote-ref remote-sha
  # We could filter here (e.g., only validate pushes to main/dev)
  # For now, validate all pushes
  return 0
}

# Main validation
main() {
  echo ""
  echo -e "${YELLOW}Pre-push validation running...${NC}"
  echo ""

  local validate_args=""

  if $FULL_MODE; then
    echo "Mode: full (includes slow checks)"
  else
    echo "Mode: quick (use --full for complete validation)"
    validate_args="--quick"
  fi

  echo ""

  # Run validation
  if ! "$SCRIPT_DIR/validate-local.sh" $validate_args; then
    echo ""
    echo -e "${RED}Pre-push validation failed!${NC}"
    echo ""
    echo "Options:"
    echo "  1. Fix the issues and try again"
    echo "  2. Run full validation: ./scripts/validate-local.sh --verbose"
    echo "  3. Skip hook (not recommended): git push --no-verify"
    echo ""
    exit 1
  fi

  echo ""
  echo -e "${GREEN}Pre-push validation passed!${NC}"
  echo ""
}

# Check if install/uninstall was handled (functions call exit)
# Otherwise run main
main
