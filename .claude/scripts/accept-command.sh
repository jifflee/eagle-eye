#!/usr/bin/env bash
#
# accept-command.sh
# Accept upstream version of a conflicted file
# Called by: npx claude-tastic accept <file>
#
# This script:
#   - Downloads latest package version
#   - Replaces local file with upstream version
#   - Updates manifest to track the change

set -euo pipefail

# Get script directory and package root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print colored output
info() { echo -e "${BLUE}[accept]${NC} $*"; }
success() { echo -e "${GREEN}[accept]${NC} $*"; }
warn() { echo -e "${YELLOW}[accept]${NC} $*"; }
error() { echo -e "${RED}[accept]${NC} $*" >&2; }

# Load manifest
load_manifest() {
  local manifest_file=".claude-tastic-manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    error "Framework not initialized"
    exit 1
  fi
  cat "$manifest_file"
}

# Save manifest
save_manifest() {
  local content="$1"
  echo "$content" > .claude-tastic-manifest.json
}

# Remove customization flag
remove_customization() {
  local file="$1"

  local manifest
  manifest=$(load_manifest)

  manifest=$(echo "$manifest" | jq "del(.customizations.\"$file\")")
  save_manifest "$manifest"
}

# Download latest package version
download_latest_package() {
  local temp_dir="$1"

  npm pack @jifflee/claude-tastic --pack-destination "$temp_dir" &>/dev/null

  local tarball
  tarball=$(find "$temp_dir" -name "*.tgz" | head -1)

  if [[ -z "$tarball" ]]; then
    return 1
  fi

  tar -xzf "$tarball" -C "$temp_dir" 2>/dev/null
  echo "$temp_dir/package"
}

# Accept upstream version
accept_file() {
  local file="$1"

  info "Accepting upstream version of: $file"
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
    error "File does not exist in upstream version: $file"
    exit 1
  fi

  # Create directory if needed
  mkdir -p "$(dirname "$file")"

  # Copy upstream version
  cp "$upstream_file" "$file"

  # Remove customization flag if it exists
  remove_customization "$file"

  success "Accepted upstream version: $file"
  echo ""
  info "File has been replaced with upstream version"
  info "Customization flag removed from manifest"
}

# Main
main() {
  if [[ $# -eq 0 ]]; then
    error "Usage: npx claude-tastic accept <file>"
    exit 1
  fi

  local file="$1"

  accept_file "$file"
}

# Run main
main "$@"
