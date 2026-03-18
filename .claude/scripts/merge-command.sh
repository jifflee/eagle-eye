#!/usr/bin/env bash
#
# merge-command.sh
# Attempt 3-way merge of a conflicted file
# Called by: npx claude-tastic merge <file>
#
# This script:
#   - Uses git merge-file for 3-way merge
#   - Base version is from the installed framework version
#   - Local version is current file
#   - Upstream version is from latest package

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
info() { echo -e "${BLUE}[merge]${NC} $*"; }
success() { echo -e "${GREEN}[merge]${NC} $*"; }
warn() { echo -e "${YELLOW}[merge]${NC} $*"; }
error() { echo -e "${RED}[merge]${NC} $*" >&2; }

# Load manifest
load_manifest() {
  local manifest_file=".claude-tastic-manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    error "Framework not initialized"
    exit 1
  fi
  cat "$manifest_file"
}

# Download specific package version
download_package_version() {
  local version="$1"
  local temp_dir="$2"

  npm pack "@jifflee/claude-tastic@$version" --pack-destination "$temp_dir" &>/dev/null

  local tarball
  tarball=$(find "$temp_dir" -name "*-$version.tgz" | head -1)

  if [[ -z "$tarball" ]]; then
    tarball=$(find "$temp_dir" -name "*.tgz" | head -1)
  fi

  if [[ -z "$tarball" ]]; then
    return 1
  fi

  local extract_dir="$temp_dir/v$version"
  mkdir -p "$extract_dir"
  tar -xzf "$tarball" -C "$extract_dir" 2>/dev/null

  echo "$extract_dir/package"
}

# Attempt 3-way merge
merge_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    exit 1
  fi

  info "Attempting 3-way merge for: $file"
  echo ""

  local manifest
  manifest=$(load_manifest)

  local installed_version
  installed_version=$(echo "$manifest" | jq -r '.framework_version')

  # Download both versions
  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf '$temp_dir'" EXIT

  info "Downloading base version (v$installed_version)..."
  local base_dir
  base_dir=$(download_package_version "$installed_version" "$temp_dir")

  if [[ $? -ne 0 ]] || [[ ! -d "$base_dir" ]]; then
    error "Failed to download base version"
    exit 1
  fi

  info "Downloading latest version..."
  local latest_version
  latest_version=$(npm view @jifflee/claude-tastic version 2>/dev/null)

  local upstream_dir
  upstream_dir=$(download_package_version "$latest_version" "$temp_dir")

  if [[ $? -ne 0 ]] || [[ ! -d "$upstream_dir" ]]; then
    error "Failed to download latest version"
    exit 1
  fi

  local base_file="$base_dir/$file"
  local upstream_file="$upstream_dir/$file"

  if [[ ! -f "$base_file" ]]; then
    warn "File does not exist in base version"
    warn "Cannot perform 3-way merge without common ancestor"
    echo ""
    info "Try: npx claude-tastic accept $file"
    info "Or:  npx claude-tastic keep $file"
    exit 1
  fi

  if [[ ! -f "$upstream_file" ]]; then
    error "File does not exist in upstream version"
    exit 1
  fi

  # Create backup
  cp "$file" "$file.backup"

  # Attempt merge using git merge-file
  info "Running 3-way merge..."
  echo ""

  if git merge-file "$file" "$base_file" "$upstream_file" 2>/dev/null; then
    # Merge succeeded without conflicts
    success "Merge completed successfully without conflicts!"
    echo ""
    info "Merged file: $file"
    info "Backup saved: $file.backup"
    echo ""
    info "Review the merged file and commit if satisfied"
    info "To restore backup: mv $file.backup $file"

    rm -f "$file.backup"
  else
    # Merge had conflicts
    warn "Merge completed with conflicts"
    echo ""
    warn "The file contains conflict markers:"
    echo ""
    echo "  <<<<<<< (local)"
    echo "  Your changes"
    echo "  ======="
    echo "  Upstream changes"
    echo "  >>>>>>> (upstream)"
    echo ""
    info "Edit $file to resolve conflicts manually"
    info "Backup saved: $file.backup"
    echo ""
    info "After resolving, commit the changes"
    info "To restore backup: mv $file.backup $file"

    exit 1
  fi
}

# Main
main() {
  if [[ $# -eq 0 ]]; then
    error "Usage: npx claude-tastic merge <file>"
    exit 1
  fi

  local file="$1"

  merge_file "$file"
}

# Run main
main "$@"
