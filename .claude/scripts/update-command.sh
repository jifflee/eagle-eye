#!/usr/bin/env bash
#
# update-command.sh
# Pull latest framework updates and apply non-conflicting changes
# Called by: npx claude-tastic update
#
# This script:
#   - Fetches latest package version from npm
#   - Compares files between installed version and latest version
#   - Auto-applies non-conflicting updates
#   - Reports conflicts for manual resolution
#   - Creates snapshot before updating (for rollback)
#   - Tracks customizations to avoid overwriting them

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
info() { echo -e "${BLUE}[update]${NC} $*"; }
success() { echo -e "${GREEN}[update]${NC} $*"; }
warn() { echo -e "${YELLOW}[update]${NC} $*"; }
error() { echo -e "${RED}[update]${NC} $*" >&2; }

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

# Create snapshot for rollback
create_snapshot() {
  local snapshot_dir=".claude-tastic-snapshot"

  info "Creating snapshot for rollback..."

  # Remove old snapshot if exists
  if [[ -d "$snapshot_dir" ]]; then
    rm -rf "$snapshot_dir"
  fi

  mkdir -p "$snapshot_dir"

  # Copy manifest
  if [[ -f ".claude-tastic-manifest.json" ]]; then
    cp .claude-tastic-manifest.json "$snapshot_dir/"
  fi

  # Copy all framework files (based on packs installed)
  local manifest
  manifest=$(load_manifest)

  local packs
  packs=$(echo "$manifest" | jq -r '.packs_installed[]')

  while IFS= read -r pack; do
    if [[ -z "$pack" ]]; then
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

      # Handle glob patterns
      if [[ "$pattern" == *"*"* ]]; then
        # Find matching files
        while IFS= read -r file; do
          if [[ -f "$file" ]]; then
            local rel_path="${file#./}"
            local target_dir="$snapshot_dir/$(dirname "$rel_path")"
            mkdir -p "$target_dir"
            cp "$file" "$target_dir/" 2>/dev/null || true
          fi
        done < <(find . -path "./$pattern" -type f 2>/dev/null || true)
      else
        # Direct file
        if [[ -f "$pattern" ]]; then
          local target_dir="$snapshot_dir/$(dirname "$pattern")"
          mkdir -p "$target_dir"
          cp "$pattern" "$target_dir/" 2>/dev/null || true
        fi
      fi
    done <<< "$files"
  done <<< "$packs"

  success "Snapshot created at $snapshot_dir"
}

# Restore from snapshot
restore_snapshot() {
  local snapshot_dir=".claude-tastic-snapshot"

  if [[ ! -d "$snapshot_dir" ]]; then
    error "No snapshot found to restore from"
    return 1
  fi

  warn "Restoring from snapshot..."

  # Restore all files
  if [[ -d "$snapshot_dir" ]]; then
    cp -r "$snapshot_dir/"* . 2>/dev/null || true
    success "Snapshot restored"
  fi

  # Clean up snapshot
  rm -rf "$snapshot_dir"
}

# Download latest package version
download_latest_package() {
  local temp_dir="$1"

  info "Downloading latest package version..."

  # Use npm pack to download the package
  local pack_output
  pack_output=$(npm pack @jifflee/claude-tastic --pack-destination "$temp_dir" 2>&1)

  if [[ $? -ne 0 ]]; then
    error "Failed to download package: $pack_output"
    return 1
  fi

  # Extract the tarball
  local tarball
  tarball=$(find "$temp_dir" -name "*.tgz" | head -1)

  if [[ -z "$tarball" ]]; then
    error "Package tarball not found"
    return 1
  fi

  tar -xzf "$tarball" -C "$temp_dir"

  # npm pack creates a 'package' directory
  echo "$temp_dir/package"
}

# Check if file is customized
is_customized() {
  local file="$1"
  local manifest
  manifest=$(load_manifest)

  local customization_type
  customization_type=$(echo "$manifest" | jq -r ".customizations.\"$file\" // \"none\"")

  if [[ "$customization_type" != "none" ]]; then
    return 0  # File is customized
  else
    return 1  # File is not customized
  fi
}

# Mark file as customized
mark_customized() {
  local file="$1"
  local type="${2:-modified}"

  local manifest
  manifest=$(load_manifest)

  manifest=$(echo "$manifest" | jq ".customizations.\"$file\" = \"$type\"")
  save_manifest "$manifest"
}

# Compare files and detect conflicts
compare_files() {
  local upstream_dir="$1"
  local review_mode="${2:-false}"

  local manifest
  manifest=$(load_manifest)

  local packs
  packs=$(echo "$manifest" | jq -r '.packs_installed[]')

  local auto_applied=0
  local conflicts=0
  local skipped=0
  local conflict_files=()

  info "Comparing files with upstream..."
  echo ""

  while IFS= read -r pack; do
    if [[ -z "$pack" ]]; then
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

      # Handle glob patterns
      if [[ "$pattern" == *"*"* ]]; then
        # Find matching files in upstream
        while IFS= read -r upstream_file; do
          if [[ ! -f "$upstream_file" ]]; then
            continue
          fi

          local rel_path="${upstream_file#$upstream_dir/}"
          local local_file="./$rel_path"

          # Process each file
          if [[ ! -f "$local_file" ]]; then
            # New file - auto-apply unless in review mode
            if [[ "$review_mode" == "true" ]]; then
              warn "NEW: $rel_path (requires review)"
              ((conflicts++))
              conflict_files+=("$rel_path")
            else
              mkdir -p "$(dirname "$local_file")"
              cp "$upstream_file" "$local_file"
              success "ADDED: $rel_path"
              ((auto_applied++))
            fi
          elif is_customized "$rel_path"; then
            # File is customized - skip
            info "SKIP: $rel_path (customized)"
            ((skipped++))
          elif cmp -s "$local_file" "$upstream_file"; then
            # Files are identical - skip
            ((skipped++))
          else
            # Files differ - check if customized or conflicting
            if [[ "$review_mode" == "true" ]]; then
              warn "CHANGED: $rel_path (requires review)"
              ((conflicts++))
              conflict_files+=("$rel_path")
            else
              # Auto-apply if not customized
              cp "$upstream_file" "$local_file"
              success "UPDATED: $rel_path"
              ((auto_applied++))
            fi
          fi
        done < <(find "$upstream_dir" -path "$upstream_dir/$pattern" -type f 2>/dev/null || true)
      else
        # Direct file path
        local upstream_file="$upstream_dir/$pattern"
        local local_file="./$pattern"

        if [[ ! -f "$upstream_file" ]]; then
          continue
        fi

        if [[ ! -f "$local_file" ]]; then
          # New file
          if [[ "$review_mode" == "true" ]]; then
            warn "NEW: $pattern (requires review)"
            ((conflicts++))
            conflict_files+=("$pattern")
          else
            mkdir -p "$(dirname "$local_file")"
            cp "$upstream_file" "$local_file"
            success "ADDED: $pattern"
            ((auto_applied++))
          fi
        elif is_customized "$pattern"; then
          # File is customized
          info "SKIP: $pattern (customized)"
          ((skipped++))
        elif cmp -s "$local_file" "$upstream_file"; then
          # Files are identical
          ((skipped++))
        else
          # Files differ
          if [[ "$review_mode" == "true" ]]; then
            warn "CHANGED: $pattern (requires review)"
            ((conflicts++))
            conflict_files+=("$pattern")
          else
            cp "$upstream_file" "$local_file"
            success "UPDATED: $pattern"
            ((auto_applied++))
          fi
        fi
      fi
    done <<< "$files"
  done <<< "$packs"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Update Summary:"
  echo "  Auto-applied:  $auto_applied files"
  echo "  Skipped:       $skipped files (unchanged or customized)"
  echo "  Conflicts:     $conflicts files"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [[ $conflicts -gt 0 ]]; then
    echo "Files requiring manual resolution:"
    for file in "${conflict_files[@]}"; do
      echo "  - $file"
    done
    echo ""
    echo "Use these commands to resolve conflicts:"
    echo "  npx claude-tastic diff <file>    - Show differences"
    echo "  npx claude-tastic accept <file>  - Use upstream version"
    echo "  npx claude-tastic keep <file>    - Keep local version"
    echo "  npx claude-tastic merge <file>   - Attempt 3-way merge"
    echo ""
  fi

  # Return number of conflicts
  return $conflicts
}

# Update manifest with new version
update_manifest() {
  local new_version="$1"
  local old_version="$2"
  local had_conflicts="${3:-false}"

  local manifest
  manifest=$(load_manifest)

  # Update version
  manifest=$(echo "$manifest" | jq ".framework_version = \"$new_version\"")
  manifest=$(echo "$manifest" | jq ".last_updated = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"")

  # Add to update history
  local update_entry
  update_entry=$(jq -n \
    --arg from "$old_version" \
    --arg to "$new_version" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson auto "$([[ "$had_conflicts" == "false" ]] && echo "true" || echo "false")" \
    '{
      from_version: $from,
      to_version: $to,
      updated_at: $date,
      conflicts: [],
      auto_applied: $auto
    }')

  manifest=$(echo "$manifest" | jq ".update_history += [$update_entry]")

  save_manifest "$manifest"
}

# Main update flow
main() {
  local review_mode=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --review)
        review_mode=true
        shift
        ;;
      *)
        error "Unknown option: $1"
        exit 1
        ;;
    esac
  done

  check_git_repo

  echo ""
  echo -e "${BOLD}Framework Update${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local manifest
  manifest=$(load_manifest)

  local installed_version
  installed_version=$(echo "$manifest" | jq -r '.framework_version')

  info "Current version: $installed_version"

  # Check for latest version
  info "Checking for updates..."

  local latest_version
  latest_version=$(npm view @jifflee/claude-tastic version 2>/dev/null || echo "")

  if [[ -z "$latest_version" ]]; then
    error "Failed to check for updates"
    exit 1
  fi

  info "Latest version:  $latest_version"
  echo ""

  # Check if already up to date
  if [[ "$installed_version" == "$latest_version" ]]; then
    success "Framework is already up to date!"
    exit 0
  fi

  # Check for breaking changes
  local installed_major
  installed_major=$(echo "$installed_version" | cut -d. -f1)
  local latest_major
  latest_major=$(echo "$latest_version" | cut -d. -f1)

  local has_breaking_changes=false
  if [[ $latest_major -gt $installed_major ]]; then
    has_breaking_changes=true
    warn "BREAKING CHANGES DETECTED: v$installed_version → v$latest_version"
    warn "This is a major version update with breaking changes"
    echo ""
    info "Release notes: https://github.com/jifflee/claude-tastic/releases/tag/v$latest_version"
    echo ""

    if [[ "$review_mode" != "true" ]]; then
      error "Breaking changes require --review flag"
      info "Run: npx claude-tastic update --review"
      exit 1
    fi
  fi

  # Confirm update
  if [[ "$review_mode" == "true" ]]; then
    info "Review mode: Changes will be shown for manual approval"
    echo ""
  fi

  read -p "Proceed with update? [Y/n]: " proceed
  if [[ "$proceed" =~ ^[Nn]$ ]]; then
    warn "Update cancelled"
    exit 0
  fi

  echo ""

  # Create snapshot for rollback
  create_snapshot

  # Download latest package
  local temp_dir
  temp_dir=$(mktemp -d)

  trap "rm -rf '$temp_dir'" EXIT

  local upstream_dir
  upstream_dir=$(download_latest_package "$temp_dir")

  if [[ $? -ne 0 ]] || [[ ! -d "$upstream_dir" ]]; then
    error "Failed to download package"
    exit 1
  fi

  success "Downloaded v$latest_version"
  echo ""

  # Compare and apply updates
  if compare_files "$upstream_dir" "$review_mode"; then
    # No conflicts
    update_manifest "$latest_version" "$installed_version" "false"

    echo ""
    success "Framework updated to v$latest_version!"
    echo ""
    info "Next steps:"
    echo "  1. Review changes: git status"
    echo "  2. Test your application"
    echo "  3. Commit changes: git add -A && git commit -m 'chore: update claude-tastic to v$latest_version'"
    echo ""

    # Clean up snapshot
    rm -rf .claude-tastic-snapshot
  else
    # Had conflicts
    update_manifest "$latest_version" "$installed_version" "true"

    echo ""
    warn "Update completed with conflicts"
    echo ""
    info "Resolve conflicts, then commit changes"
    echo ""
    info "To rollback: rm -rf .claude-tastic-snapshot"
    echo ""
  fi
}

# Run main
main "$@"
