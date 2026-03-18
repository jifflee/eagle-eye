#!/usr/bin/env bash
#
# remove-pack-command.sh
# Remove a feature pack from an existing installation
# Called by: npx claude-tastic remove-pack <pack>
#
# This script:
#   - Validates the pack can be removed
#   - Checks dependent packs
#   - Removes files for the pack
#   - Updates .claude-tastic-manifest.json
#   - Reports removal status

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
info() { echo -e "${BLUE}[remove-pack]${NC} $*"; }
success() { echo -e "${GREEN}[remove-pack]${NC} $*"; }
warn() { echo -e "${YELLOW}[remove-pack]${NC} $*"; }
error() { echo -e "${RED}[remove-pack]${NC} $*" >&2; }

# Check if we're in a git repository
check_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    error "Not in a git repository"
    exit 1
  fi
}

# Load manifest
load_manifest() {
  local manifest_file=".claude-tastic-manifest.json"
  if [[ ! -f "$manifest_file" ]]; then
    error "Framework not initialized. Run: npx claude-tastic init"
    exit 1
  fi
  cat "$manifest_file"
}

# Save manifest
save_manifest() {
  local content="$1"
  echo "$content" > .claude-tastic-manifest.json
}

# Show usage
usage() {
  cat <<EOF
Usage: npx claude-tastic remove-pack <pack>

Remove a feature pack from your installation.

Examples:
  npx claude-tastic remove-pack scripts-container
  npx claude-tastic remove-pack skills-audit

Note: The 'core' pack is always required and cannot be removed.
EOF
}

# Validate pack exists
validate_pack() {
  local pack="$1"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  # Check if pack exists
  if ! echo "$packs_json" | jq -e ".packs.${pack}" &>/dev/null; then
    error "Unknown pack: $pack"
    echo ""
    usage
    exit 1
  fi

  # Check if pack is 'core' or required
  if [[ "$pack" == "core" ]]; then
    error "The 'core' pack is always required and cannot be removed"
    exit 1
  fi

  local is_required
  is_required=$(echo "$packs_json" | jq -r ".packs.${pack}.required // false")

  if [[ "$is_required" == "true" ]]; then
    error "Pack '$pack' is required and cannot be removed"
    exit 1
  fi
}

# Check if pack is installed
is_pack_installed() {
  local pack="$1"
  local manifest="$2"

  echo "$manifest" | jq -e ".packs_installed[] | select(. == \"${pack}\")" &>/dev/null
}

# Check if other packs depend on this pack
check_pack_dependents() {
  local pack="$1"
  local manifest="$2"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  local execution_mode
  execution_mode=$(echo "$manifest" | jq -r '.profile.execution_mode')

  # Check if pack is required for execution mode
  if [[ "$execution_mode" == "hosted" || "$execution_mode" == "hybrid" ]]; then
    local required_packs
    required_packs=$(echo "$packs_json" | jq -r ".execution_mode_filters.${execution_mode}.required_packs[]?" 2>/dev/null || echo "")

    if echo "$required_packs" | grep -q "^${pack}$"; then
      error "Pack '$pack' is required for $execution_mode execution mode"
      info "To remove this pack, first reconfigure to 'local' mode:"
      info "  npx claude-tastic reconfigure"
      exit 1
    fi
  fi
}

# Get list of files for a pack
get_pack_files() {
  local pack="$1"
  local target_dir="${2:-.}"

  local files
  files=$(jq -r ".packs.${pack}.files[]?" "$PACKAGE_ROOT/packs.json")

  if [[ -z "$files" ]]; then
    return
  fi

  while IFS= read -r pattern; do
    # Handle glob patterns
    if [[ "$pattern" == *"*"* ]]; then
      # Find matching files in target directory
      find "$target_dir" -path "$target_dir/$pattern" -type f 2>/dev/null || true
    else
      # Direct file path
      if [[ -f "$target_dir/$pattern" ]]; then
        echo "$target_dir/$pattern"
      fi
    fi
  done <<< "$files"
}

# Check if a file is shared by other installed packs
is_file_shared() {
  local file="$1"
  local pack_to_remove="$2"
  local manifest="$3"

  # Get relative path
  local rel_path="${file#./}"

  # Check all other installed packs
  local installed_packs
  installed_packs=$(echo "$manifest" | jq -r '.packs_installed[]')

  while IFS= read -r pack; do
    if [[ -z "$pack" || "$pack" == "$pack_to_remove" ]]; then
      continue
    fi

    # Get file patterns for this pack
    local files
    files=$(jq -r ".packs.${pack}.files[]?" "$PACKAGE_ROOT/packs.json" 2>/dev/null || echo "")

    if [[ -z "$files" ]]; then
      continue
    fi

    while IFS= read -r pattern; do
      if [[ -z "$pattern" ]]; then
        continue
      fi

      # Check if file matches this pattern
      if [[ "$pattern" == *"*"* ]]; then
        # Glob pattern - use case statement for matching
        case "$rel_path" in
          $pattern)
            return 0  # File is shared
            ;;
        esac
      else
        # Direct match
        if [[ "$rel_path" == "$pattern" ]]; then
          return 0  # File is shared
        fi
      fi
    done <<< "$files"
  done <<< "$installed_packs"

  return 1  # File is not shared
}

# Remove files for a pack
remove_pack_files() {
  local pack="$1"
  local manifest="$2"
  local target_dir="${3:-.}"

  info "Removing files for pack: $pack"

  # Get all files for this pack
  local pack_files
  pack_files=$(get_pack_files "$pack" "$target_dir")

  if [[ -z "$pack_files" ]]; then
    warn "No files to remove for pack: $pack"
    return 0
  fi

  local removed=0
  local shared=0
  local missing=0

  while IFS= read -r file; do
    if [[ -z "$file" || ! -f "$file" ]]; then
      ((missing++))
      continue
    fi

    # Check if file is shared by other packs
    if is_file_shared "$file" "$pack" "$manifest"; then
      info "  Keeping shared file: ${file#./}"
      ((shared++))
    else
      # Check if file is in customizations
      local rel_path="${file#./}"
      local is_customized
      is_customized=$(echo "$manifest" | jq -e ".customizations[\"${rel_path}\"]" &>/dev/null && echo "true" || echo "false")

      if [[ "$is_customized" == "true" ]]; then
        warn "  Keeping customized file: $rel_path"
        ((shared++))
      else
        # Remove file
        if rm "$file" 2>/dev/null; then
          ((removed++))
        fi

        # Remove empty parent directories
        local dir
        dir=$(dirname "$file")
        while [[ "$dir" != "." && "$dir" != "/" ]]; do
          if rmdir "$dir" 2>/dev/null; then
            dir=$(dirname "$dir")
          else
            break
          fi
        done
      fi
    fi
  done <<< "$pack_files"

  if [[ $removed -gt 0 ]]; then
    success "  Removed $removed files"
  fi
  if [[ $shared -gt 0 ]]; then
    info "  Kept $shared shared/customized files"
  fi
  if [[ $missing -gt 0 ]]; then
    info "  $missing files were already removed"
  fi
}

# Remove pack from manifest
remove_pack_from_manifest() {
  local pack="$1"
  local manifest="$2"

  # Remove pack from packs_installed array
  manifest=$(echo "$manifest" | jq --arg pack "$pack" '.packs_installed = (.packs_installed | map(select(. != $pack)))')

  # Add to packs_skipped array
  manifest=$(echo "$manifest" | jq --arg pack "$pack" '.packs_skipped += [$pack] | .packs_skipped |= unique | sort')

  # Update last_updated timestamp
  manifest=$(echo "$manifest" | jq --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_updated = $timestamp')

  echo "$manifest"
}

# Main function
main() {
  local pack="${1:-}"

  if [[ -z "$pack" ]]; then
    error "Missing pack argument"
    echo ""
    usage
    exit 1
  fi

  if [[ "$pack" == "--help" || "$pack" == "-h" || "$pack" == "help" ]]; then
    usage
    exit 0
  fi

  echo ""
  echo -e "${BOLD}Remove Feature Pack${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Pre-flight checks
  check_git_repo

  # Load manifest
  local manifest
  manifest=$(load_manifest)

  # Validate pack
  validate_pack "$pack"

  # Check if installed
  if ! is_pack_installed "$pack" "$manifest"; then
    warn "Pack '$pack' is not installed"
    exit 0
  fi

  # Get pack info
  local pack_name pack_desc
  pack_name=$(jq -r ".packs.${pack}.name" "$PACKAGE_ROOT/packs.json")
  pack_desc=$(jq -r ".packs.${pack}.description" "$PACKAGE_ROOT/packs.json")

  info "Pack: $pack_name"
  info "Description: $pack_desc"
  echo ""

  # Check dependents
  check_pack_dependents "$pack" "$manifest"

  # Warn about removal
  warn "This will remove all files associated with this pack"
  warn "Shared files and customized files will be preserved"
  echo ""

  # Confirm removal
  read -p "Remove this pack? [y/N]: " proceed
  if [[ ! "$proceed" =~ ^[Yy]$ ]]; then
    info "Removal cancelled"
    exit 0
  fi

  echo ""

  # Remove pack files
  remove_pack_files "$pack" "$manifest"

  echo ""

  # Update manifest
  manifest=$(remove_pack_from_manifest "$pack" "$manifest")
  save_manifest "$manifest"

  success "Pack '$pack' removed successfully!"
  echo ""

  info "Next steps:"
  echo "  1. Review removed files: git status"
  echo "  2. Commit changes: git add -A && git commit -m 'chore: remove $pack pack'"
  echo "  3. Check status: npx claude-tastic status"
  echo ""
}

# Run main
main "$@"
