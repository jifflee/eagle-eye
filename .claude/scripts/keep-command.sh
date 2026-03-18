#!/usr/bin/env bash
#
# keep-command.sh
# Keep local version of a conflicted file
# Called by: npx claude-tastic keep <file>
#
# This script:
#   - Marks the file as customized in manifest
#   - Future updates will skip this file

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
info() { echo -e "${BLUE}[keep]${NC} $*"; }
success() { echo -e "${GREEN}[keep]${NC} $*"; }
warn() { echo -e "${YELLOW}[keep]${NC} $*"; }
error() { echo -e "${RED}[keep]${NC} $*" >&2; }

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

# Mark file as customized
mark_customized() {
  local file="$1"

  local manifest
  manifest=$(load_manifest)

  manifest=$(echo "$manifest" | jq ".customizations.\"$file\" = \"modified\"")
  save_manifest "$manifest"
}

# Keep local version
keep_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    error "File not found: $file"
    exit 1
  fi

  info "Keeping local version of: $file"
  echo ""

  # Mark as customized
  mark_customized "$file"

  success "Local version kept: $file"
  echo ""
  info "File marked as customized in manifest"
  info "Future updates will skip this file"
  echo ""
  warn "To allow updates again, remove '$file' from customizations in .claude-tastic-manifest.json"
}

# Main
main() {
  if [[ $# -eq 0 ]]; then
    error "Usage: npx claude-tastic keep <file>"
    exit 1
  fi

  local file="$1"

  keep_file "$file"
}

# Run main
main "$@"
