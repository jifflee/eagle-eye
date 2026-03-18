#!/usr/bin/env bash
# ============================================================
# Script: validate-repo-naming.sh
# Purpose: Validate repository naming convention enforcement
#
# Validates that repository names follow the visibility-based convention:
#   - Private (internal) repos: source-{repo-name}
#   - Public (external) repos: external-{repo-name}
#
# Usage:
#   ./scripts/ci/validate-repo-naming.sh [OPTIONS]
#
# Options:
#   --repo-profile FILE  Path to repo-profile.yaml (default: config/repo-profile.yaml)
#   --auto-fix           Update repo-profile.yaml if drift detected
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  Naming convention valid
#   1  Naming convention violation detected
#   2  Error (missing config, invalid options, etc.)
#
# Integration:
#   - Called during /repo-init to validate naming
#   - Called by drift detection (#940) to check for mismatches
#   - Configured in config/repo-profile.yaml
#
# Related: Issue #934 (public/private repo detection)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO_PROFILE="${REPO_PROFILE:-config/repo-profile.yaml}"
AUTO_FIX=false
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-profile) REPO_PROFILE="$2"; shift 2 ;;
    --auto-fix)     AUTO_FIX=true; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --help|-h)      show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq is required for YAML parsing" >&2
  echo "  Install: brew install yq (macOS) or snap install yq (Linux)" >&2
  exit 2
fi

if ! command -v gh &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} gh CLI is required" >&2
  echo "  Install from: https://cli.github.com/" >&2
  exit 2
fi

# ─── Get Repository Information ──────────────────────────────────────────────

get_repo_name() {
  # Get repository name from GitHub remote
  if git remote get-url origin &>/dev/null; then
    git remote get-url origin | sed -E 's#.*/([^/]+/[^/]+)\.git$#\1#' | cut -d'/' -f2
  else
    echo "unknown"
  fi
}

get_repo_full_name() {
  # Get full owner/repo name
  if git remote get-url origin &>/dev/null; then
    git remote get-url origin | sed -E 's#.*/([^/]+/[^/]+)\.git$#\1#'
  else
    echo "unknown/unknown"
  fi
}

# ─── Naming Convention Rules ──────────────────────────────────────────────────

check_naming_convention() {
  local visibility="$1"
  local repo_name="$2"

  case "$visibility" in
    private)
      # Private repos must start with "source-"
      if [[ "$repo_name" =~ ^source- ]]; then
        return 0  # Valid
      else
        return 1  # Invalid
      fi
      ;;
    public)
      # Public repos must start with "external-"
      if [[ "$repo_name" =~ ^external- ]]; then
        return 0  # Valid
      else
        return 1  # Invalid
      fi
      ;;
    *)
      echo -e "${RED}[ERROR]${NC} Unknown visibility type: $visibility" >&2
      return 2
      ;;
  esac
}

get_expected_prefix() {
  local visibility="$1"

  case "$visibility" in
    private)  echo "source-" ;;
    public)   echo "external-" ;;
    *)        echo "unknown-" ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}Repository Naming Convention Validation${NC}"
  echo "────────────────────────────────────────────────────────────"

  # Get current repo name
  REPO_NAME=$(get_repo_name)
  REPO_FULL_NAME=$(get_repo_full_name)

  if [[ "$REPO_NAME" == "unknown" ]]; then
    echo -e "${RED}[ERROR]${NC} Could not determine repository name" >&2
    echo "  Ensure you are in a git repository with a remote 'origin'" >&2
    exit 2
  fi

  echo -e "Repository: ${YELLOW}$REPO_FULL_NAME${NC}"
  echo -e "Name:       ${YELLOW}$REPO_NAME${NC}"
  echo ""

  # Check if repo profile exists
  if [[ ! -f "$REPO_ROOT/$REPO_PROFILE" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Repo profile not found: $REPO_PROFILE"
    echo "  Run /repo-init to create repo profile"
    echo "  Skipping validation (profile required)"
    exit 0
  fi

  # Get visibility from repo profile
  VISIBILITY=$(yq eval '.visibility.type' "$REPO_ROOT/$REPO_PROFILE" 2>/dev/null || echo "unknown")

  if [[ "$VISIBILITY" == "unknown" ]] || [[ -z "$VISIBILITY" ]] || [[ "$VISIBILITY" == "null" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Visibility not configured in repo profile"
    echo "  Run /repo-init to configure visibility"
    echo "  Skipping validation (visibility required)"
    exit 0
  fi

  echo -e "Visibility: ${YELLOW}$VISIBILITY${NC}"
  echo ""

  # Get expected prefix
  EXPECTED_PREFIX=$(get_expected_prefix "$VISIBILITY")
  echo -e "Expected prefix: ${BLUE}${EXPECTED_PREFIX}*${NC}"
  echo ""

  # Check naming convention
  if check_naming_convention "$VISIBILITY" "$REPO_NAME"; then
    echo -e "${GREEN}✓ Naming convention VALID${NC}"
    echo "  Repository name follows the $VISIBILITY naming convention"
    echo "  Pattern: ${EXPECTED_PREFIX}*"
    exit 0
  else
    echo -e "${RED}✗ Naming convention VIOLATION${NC}"
    echo ""
    echo -e "${YELLOW}Issue:${NC}"
    echo "  Repository is configured as: $VISIBILITY"
    echo "  Expected naming pattern: ${EXPECTED_PREFIX}*"
    echo "  Actual repository name: $REPO_NAME"
    echo ""
    echo -e "${YELLOW}Required action:${NC}"

    if [[ "$VISIBILITY" == "private" ]]; then
      echo "  Private (internal) repositories must use: source-{repo-name}"
      echo "  Example: source-${REPO_NAME#source-}"
      echo ""
      echo "  Options:"
      echo "    1. Rename this repo to: source-${REPO_NAME}"
      echo "    2. Update visibility in $REPO_PROFILE to 'public'"
    else
      echo "  Public (external) repositories must use: external-{repo-name}"
      echo "  Example: external-${REPO_NAME#external-}"
      echo ""
      echo "  Options:"
      echo "    1. Rename this repo to: external-${REPO_NAME}"
      echo "    2. Update visibility in $REPO_PROFILE to 'private'"
    fi

    echo ""
    echo -e "${BLUE}How to rename a GitHub repository:${NC}"
    echo "  1. Go to: https://github.com/$REPO_FULL_NAME/settings"
    echo "  2. Under 'Repository name', enter the new name"
    echo "  3. Click 'Rename'"
    echo "  4. Update your local git remote:"
    echo "     git remote set-url origin <new-url>"

    if [[ "$AUTO_FIX" == "true" ]]; then
      echo ""
      echo -e "${BLUE}[AUTO-FIX]${NC} Updating repo profile..."
      # Update the current_name in repo profile to reflect actual state
      yq eval -i ".naming.current_name = \"$REPO_NAME\"" "$REPO_ROOT/$REPO_PROFILE"
      yq eval -i ".naming.naming_valid = false" "$REPO_ROOT/$REPO_PROFILE"
      yq eval -i ".naming.expected_pattern = \"${EXPECTED_PREFIX}*\"" "$REPO_ROOT/$REPO_PROFILE"
      yq eval -i ".naming.last_validated = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$REPO_ROOT/$REPO_PROFILE"
      echo "  Updated $REPO_PROFILE with validation status"
    fi

    exit 1
  fi
}

main "$@"
