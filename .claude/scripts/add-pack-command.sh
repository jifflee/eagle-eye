#!/usr/bin/env bash
#
# add-pack-command.sh
# Add a feature pack to an existing installation
# Called by: npx claude-tastic add-pack <pack>
#
# This script:
#   - Validates the pack exists and is compatible
#   - Checks pack dependencies
#   - Copies files for the pack
#   - Updates .claude-tastic-manifest.json
#   - Reports installation status

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
info() { echo -e "${BLUE}[add-pack]${NC} $*"; }
success() { echo -e "${GREEN}[add-pack]${NC} $*"; }
warn() { echo -e "${YELLOW}[add-pack]${NC} $*"; }
error() { echo -e "${RED}[add-pack]${NC} $*" >&2; }

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
Usage: npx claude-tastic add-pack <pack>

Add a feature pack to your installation.

Available packs:
  agents-full          Full agent set (30+ agents)
  agents-minimal       Minimal agent set (deployment, docs, CI/CD)
  skills-sprint        Sprint management skills
  skills-capture       Capture & triage skills
  skills-pr            PR management skills
  skills-audit         Audit & analysis skills
  skills-release       Release management skills
  skills-worktree      Worktree management skills
  skills-milestone     Milestone management skills
  skills-issue         Issue management skills
  skills-repo          Repository management skills
  scripts-ci           CI/CD scripts
  scripts-container    Container & orchestration scripts
  scripts-validation   Validation scripts
  hooks                Git hooks
  config-templates     Configuration templates

Examples:
  npx claude-tastic add-pack scripts-container
  npx claude-tastic add-pack skills-audit

Note: The 'core' pack is always required and cannot be added/removed.
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

  # Check if pack is 'core'
  if [[ "$pack" == "core" ]]; then
    error "The 'core' pack is always required and cannot be added separately"
    exit 1
  fi
}

# Check if pack is already installed
is_pack_installed() {
  local pack="$1"
  local manifest="$2"

  echo "$manifest" | jq -e ".packs_installed[] | select(. == \"${pack}\")" &>/dev/null
}

# Check pack compatibility with current profile
check_pack_compatibility() {
  local pack="$1"
  local manifest="$2"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  local visibility
  visibility=$(echo "$manifest" | jq -r '.profile.visibility')

  local execution_mode
  execution_mode=$(echo "$manifest" | jq -r '.profile.execution_mode')

  # Check visibility compatibility
  local pack_visibilities
  pack_visibilities=$(echo "$packs_json" | jq -r ".packs.${pack}.visibility[]?" 2>/dev/null || echo "")

  if [[ -n "$pack_visibilities" ]]; then
    if ! echo "$pack_visibilities" | grep -q "^${visibility}$"; then
      error "Pack '$pack' is not compatible with '$visibility' repositories"
      info "This pack requires: $(echo "$pack_visibilities" | tr '\n' ', ' | sed 's/,$//')"
      exit 1
    fi
  fi

  # Check execution mode compatibility
  local pack_exec_modes
  pack_exec_modes=$(echo "$packs_json" | jq -r ".packs.${pack}.execution_mode[]?" 2>/dev/null || echo "")

  if [[ -n "$pack_exec_modes" ]]; then
    if ! echo "$pack_exec_modes" | grep -q "^${execution_mode}$"; then
      error "Pack '$pack' is not compatible with '$execution_mode' execution mode"
      info "This pack requires: $(echo "$pack_exec_modes" | tr '\n' ', ' | sed 's/,$//')"
      exit 1
    fi
  fi

  # Check if pack is in excluded list for this profile
  local excluded_packs
  excluded_packs=$(echo "$packs_json" | jq -r ".visibility_profiles.${visibility}.excluded_packs[]?" 2>/dev/null || echo "")

  if echo "$excluded_packs" | grep -q "^${pack}$"; then
    warn "Pack '$pack' is typically excluded for '$visibility' repositories"
    read -p "Continue anyway? [y/N]: " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
      info "Installation cancelled"
      exit 0
    fi
  fi
}

# Check pack dependencies
check_pack_dependencies() {
  local pack="$1"
  local manifest="$2"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  # Check if pack has dependency on scripts-container for hosted/hybrid modes
  local execution_mode
  execution_mode=$(echo "$manifest" | jq -r '.profile.execution_mode')

  if [[ "$execution_mode" == "hosted" || "$execution_mode" == "hybrid" ]]; then
    local required_packs
    required_packs=$(echo "$packs_json" | jq -r ".execution_mode_filters.${execution_mode}.required_packs[]?" 2>/dev/null || echo "")

    while IFS= read -r required_pack; do
      if [[ -z "$required_pack" ]]; then
        continue
      fi

      if ! is_pack_installed "$required_pack" "$manifest"; then
        error "Pack '$pack' requires '$required_pack' for $execution_mode mode"
        info "Install it first: npx claude-tastic add-pack $required_pack"
        exit 1
      fi
    done <<< "$required_packs"
  fi

  # Special case: agents-full and agents-minimal are mutually exclusive
  if [[ "$pack" == "agents-full" ]]; then
    if is_pack_installed "agents-minimal" "$manifest"; then
      warn "Pack 'agents-minimal' is currently installed"
      warn "It will be replaced by 'agents-full'"
      read -p "Continue? [y/N]: " continue_replace
      if [[ ! "$continue_replace" =~ ^[Yy]$ ]]; then
        info "Installation cancelled"
        exit 0
      fi
    fi
  elif [[ "$pack" == "agents-minimal" ]]; then
    if is_pack_installed "agents-full" "$manifest"; then
      warn "Pack 'agents-full' is currently installed"
      warn "It will be replaced by 'agents-minimal'"
      read -p "Continue? [y/N]: " continue_replace
      if [[ ! "$continue_replace" =~ ^[Yy]$ ]]; then
        info "Installation cancelled"
        exit 0
      fi
    fi
  fi
}

# Copy files for a pack
copy_pack_files() {
  local pack="$1"
  local target_dir="${2:-.}"

  info "Installing pack: $pack"

  # Get file patterns for this pack
  local files
  files=$(jq -r ".packs.${pack}.files[]?" "$PACKAGE_ROOT/packs.json")

  if [[ -z "$files" ]]; then
    warn "No files defined for pack: $pack"
    return 0
  fi

  local copied=0
  local skipped=0
  local updated=0

  while IFS= read -r pattern; do
    # Handle glob patterns
    if [[ "$pattern" == *"*"* ]]; then
      # Expand glob in package root
      while IFS= read -r file; do
        if [[ -f "$file" ]]; then
          local rel_path="${file#$PACKAGE_ROOT/}"
          local target_file="$target_dir/$rel_path"
          local target_subdir
          target_subdir=$(dirname "$target_file")

          # Create directory if needed
          mkdir -p "$target_subdir"

          # Copy file
          if [[ ! -f "$target_file" ]]; then
            if cp "$file" "$target_file" 2>/dev/null; then
              ((copied++))
            fi
          elif ! cmp -s "$file" "$target_file"; then
            if cp "$file" "$target_file" 2>/dev/null; then
              ((updated++))
            fi
          else
            ((skipped++))
          fi
        fi
      done < <(find "$PACKAGE_ROOT" -path "$PACKAGE_ROOT/$pattern" -type f 2>/dev/null || true)
    else
      # Direct file path
      if [[ -f "$PACKAGE_ROOT/$pattern" ]]; then
        local target_file="$target_dir/$pattern"
        local target_subdir
        target_subdir=$(dirname "$target_file")

        # Create directory if needed
        mkdir -p "$target_subdir"

        # Copy file
        if [[ ! -f "$target_file" ]]; then
          cp "$PACKAGE_ROOT/$pattern" "$target_file"
          ((copied++))
        elif ! cmp -s "$PACKAGE_ROOT/$pattern" "$target_file"; then
          cp "$PACKAGE_ROOT/$pattern" "$target_file"
          ((updated++))
        else
          ((skipped++))
        fi
      fi
    fi
  done <<< "$files"

  if [[ $copied -gt 0 ]]; then
    success "  Added $copied new files"
  fi
  if [[ $updated -gt 0 ]]; then
    success "  Updated $updated existing files"
  fi
  if [[ $skipped -gt 0 ]]; then
    info "  Skipped $skipped files (already up to date)"
  fi
}

# Remove mutually exclusive pack
remove_mutually_exclusive_pack() {
  local pack="$1"
  local manifest="$2"

  if [[ "$pack" == "agents-full" ]]; then
    if is_pack_installed "agents-minimal" "$manifest"; then
      info "Removing mutually exclusive pack: agents-minimal"
      # Remove agents-minimal from manifest
      manifest=$(echo "$manifest" | jq '.packs_installed = (.packs_installed | map(select(. != "agents-minimal")))')
      echo "$manifest"
    else
      echo "$manifest"
    fi
  elif [[ "$pack" == "agents-minimal" ]]; then
    if is_pack_installed "agents-full" "$manifest"; then
      info "Removing mutually exclusive pack: agents-full"
      # Remove agents-full from manifest
      manifest=$(echo "$manifest" | jq '.packs_installed = (.packs_installed | map(select(. != "agents-full")))')
      echo "$manifest"
    else
      echo "$manifest"
    fi
  else
    echo "$manifest"
  fi
}

# Add pack to manifest
add_pack_to_manifest() {
  local pack="$1"
  local manifest="$2"

  # Add pack to packs_installed array
  manifest=$(echo "$manifest" | jq --arg pack "$pack" '.packs_installed += [$pack] | .packs_installed |= unique | sort')

  # Remove from packs_skipped if present
  manifest=$(echo "$manifest" | jq --arg pack "$pack" '.packs_skipped = (.packs_skipped | map(select(. != $pack)))')

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
  echo -e "${BOLD}Add Feature Pack${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Pre-flight checks
  check_git_repo

  # Load manifest
  local manifest
  manifest=$(load_manifest)

  # Validate pack
  validate_pack "$pack"

  # Check if already installed
  if is_pack_installed "$pack" "$manifest"; then
    warn "Pack '$pack' is already installed"
    info "To reinstall, remove it first: npx claude-tastic remove-pack $pack"
    exit 0
  fi

  # Get pack info
  local pack_name pack_desc
  pack_name=$(jq -r ".packs.${pack}.name" "$PACKAGE_ROOT/packs.json")
  pack_desc=$(jq -r ".packs.${pack}.description" "$PACKAGE_ROOT/packs.json")

  info "Pack: $pack_name"
  info "Description: $pack_desc"
  echo ""

  # Check compatibility
  check_pack_compatibility "$pack" "$manifest"

  # Check dependencies
  check_pack_dependencies "$pack" "$manifest"

  # Confirm installation
  read -p "Install this pack? [Y/n]: " proceed
  if [[ "$proceed" =~ ^[Nn]$ ]]; then
    warn "Installation cancelled"
    exit 0
  fi

  echo ""

  # Remove mutually exclusive packs if needed
  manifest=$(remove_mutually_exclusive_pack "$pack" "$manifest")

  # Copy pack files
  copy_pack_files "$pack"

  echo ""

  # Update manifest
  manifest=$(add_pack_to_manifest "$pack" "$manifest")
  save_manifest "$manifest"

  success "Pack '$pack' installed successfully!"
  echo ""

  info "Next steps:"
  echo "  1. Review installed files"
  echo "  2. Commit changes: git add -A && git commit -m 'chore: add $pack pack'"
  echo "  3. Check status: npx claude-tastic status"
  echo ""
}

# Run main
main "$@"
