#!/usr/bin/env bash
#
# diff-command.sh
# Show differences between local and upstream version of a file
# Called by: npx claude-tastic diff <file>
#
# This script:
#   - Downloads latest package version
#   - Compares specified file with upstream
#   - Shows colored diff output

set -euo pipefail

# Get script directory and package root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print colored output
info() { echo -e "${BLUE}[diff]${NC} $*"; }
success() { echo -e "${GREEN}[diff]${NC} $*"; }
warn() { echo -e "${YELLOW}[diff]${NC} $*"; }
error() { echo -e "${RED}[diff]${NC} $*" >&2; }

# Load manifest
load_manifest() {
  local manifest_file=".claude-tastic-manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    error "Framework not initialized"
    exit 1
  fi
  cat "$manifest_file"
}

# Download latest package version
download_latest_package() {
  local temp_dir="$1"

  # Use npm pack to download the package
  npm pack @jifflee/claude-tastic --pack-destination "$temp_dir" &>/dev/null

  # Extract the tarball
  local tarball
  tarball=$(find "$temp_dir" -name "*.tgz" | head -1)

  if [[ -z "$tarball" ]]; then
    return 1
  fi

  tar -xzf "$tarball" -C "$temp_dir" 2>/dev/null

  echo "$temp_dir/package"
}

# Show diff for a file
show_diff() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    exit 1
  fi

  info "Comparing $file with upstream..."
  echo ""

  # Download latest package
  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf '$temp_dir'" EXIT

  local upstream_dir
  upstream_dir=$(download_latest_package "$temp_dir")

  if [[ $? -ne 0 ]] || [[ ! -d "$upstream_dir" ]]; then
    error "Failed to download latest package"
    exit 1
  fi

  local upstream_file="$upstream_dir/$file"

  if [[ ! -f "$upstream_file" ]]; then
    warn "File does not exist in upstream version (may be new locally or removed upstream)"
    exit 1
  fi

  # Show diff with colors
  echo -e "${BOLD}Diff: Local vs Upstream${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Use git diff for nice colored output if available
  if command -v git &>/dev/null; then
    git diff --no-index --color=always "$file" "$upstream_file" || true
  else
    diff -u "$file" "$upstream_file" || true
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Options:"
  echo "  npx claude-tastic accept $file  - Use upstream version"
  echo "  npx claude-tastic keep $file    - Keep local version"
  echo "  npx claude-tastic merge $file   - Attempt 3-way merge"
  echo ""
}

# Main
main() {
  if [[ $# -eq 0 ]]; then
    error "Usage: npx claude-tastic diff <file>"
    exit 1
  fi

  local file="$1"

  show_diff "$file"
}

# Run main
main "$@"
