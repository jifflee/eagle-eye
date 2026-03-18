#!/usr/bin/env bash
#
# reconfigure-command.sh
# Re-run profile configuration without reinstalling files
# Called by: npx claude-tastic reconfigure
#
# This script:
#   - Prompts for new visibility and execution mode
#   - Validates compatibility with installed packs
#   - Updates .claude-tastic-manifest.json
#   - Suggests pack changes if needed
#   - Does NOT modify installed files

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
info() { echo -e "${BLUE}[reconfigure]${NC} $*"; }
success() { echo -e "${GREEN}[reconfigure]${NC} $*"; }
warn() { echo -e "${YELLOW}[reconfigure]${NC} $*"; }
error() { echo -e "${RED}[reconfigure]${NC} $*" >&2; }

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
Usage: npx claude-tastic reconfigure

Re-run profile configuration to change settings without reinstalling files.

This allows you to:
  - Change repository visibility (public ↔ private)
  - Change execution mode (local ↔ hosted ↔ hybrid)
  - Update branch strategy

Note: This does NOT modify installed files. You may need to add or remove
      packs to match the new profile.

Examples:
  npx claude-tastic reconfigure
EOF
}

# Prompt for visibility
prompt_visibility() {
  local current_visibility="$1"

  echo ""
  echo -e "${BOLD}Repository Visibility${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Current: $current_visibility"
  echo ""
  echo "Is this repository public or private?"
  echo ""
  echo "1. Public"
  echo "   - Minimal agent set (deployment, docs, CI/CD only)"
  echo "   - Main branch only"
  echo "   - Sensitivity scanning enabled"
  echo ""
  echo "2. Private"
  echo "   - Full agent set (30+ agents)"
  echo "   - Dev → QA → Main workflow"
  echo "   - All sprint and audit features"
  echo ""

  local choice
  read -p "Select [1-2] (default: current): " choice

  case "$choice" in
    1)
      echo "public"
      ;;
    2)
      echo "private"
      ;;
    "")
      echo "$current_visibility"
      ;;
    *)
      warn "Invalid choice, keeping current: $current_visibility"
      echo "$current_visibility"
      ;;
  esac
}

# Prompt for execution mode
prompt_execution_mode() {
  local current_mode="$1"

  echo ""
  echo -e "${BOLD}Execution Mode${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Current: $current_mode"
  echo ""
  echo "How should sprint work be executed?"
  echo ""
  echo "1. Local (worktrees)"
  echo "   - Fast, no container overhead"
  echo "   - Requires: Git only"
  echo ""
  echo "2. Hosted (containers)"
  echo "   - Isolated execution environments"
  echo "   - Requires: Docker or remote Proxmox"
  echo ""
  echo "3. Hybrid (auto-detect)"
  echo "   - Prefers containers, falls back to worktrees"
  echo "   - Flexible for mixed environments"
  echo ""

  local choice
  read -p "Select [1-3] (default: current): " choice

  case "$choice" in
    1)
      echo "local"
      ;;
    2)
      echo "hosted"
      ;;
    3)
      echo "hybrid"
      ;;
    "")
      echo "$current_mode"
      ;;
    *)
      warn "Invalid choice, keeping current: $current_mode"
      echo "$current_mode"
      ;;
  esac
}

# Check pack compatibility with new profile
check_pack_compatibility() {
  local visibility="$1"
  local execution_mode="$2"
  local manifest="$3"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  local incompatible_packs=()
  local missing_required_packs=()

  # Check installed packs
  local installed_packs
  installed_packs=$(echo "$manifest" | jq -r '.packs_installed[]')

  while IFS= read -r pack; do
    if [[ -z "$pack" ]]; then
      continue
    fi

    # Check visibility compatibility
    local pack_visibilities
    pack_visibilities=$(echo "$packs_json" | jq -r ".packs.${pack}.visibility[]?" 2>/dev/null || echo "")

    if [[ -n "$pack_visibilities" ]]; then
      if ! echo "$pack_visibilities" | grep -q "^${visibility}$"; then
        incompatible_packs+=("$pack (visibility: $visibility)")
      fi
    fi

    # Check execution mode compatibility
    local pack_exec_modes
    pack_exec_modes=$(echo "$packs_json" | jq -r ".packs.${pack}.execution_mode[]?" 2>/dev/null || echo "")

    if [[ -n "$pack_exec_modes" ]]; then
      if ! echo "$pack_exec_modes" | grep -q "^${execution_mode}$"; then
        incompatible_packs+=("$pack (execution mode: $execution_mode)")
      fi
    fi
  done <<< "$installed_packs"

  # Check if execution mode requires specific packs
  if [[ "$execution_mode" == "hosted" || "$execution_mode" == "hybrid" ]]; then
    local required_packs
    required_packs=$(echo "$packs_json" | jq -r ".execution_mode_filters.${execution_mode}.required_packs[]?" 2>/dev/null || echo "")

    while IFS= read -r required_pack; do
      if [[ -z "$required_pack" ]]; then
        continue
      fi

      if ! echo "$installed_packs" | grep -q "^${required_pack}$"; then
        missing_required_packs+=("$required_pack")
      fi
    done <<< "$required_packs"
  fi

  # Report issues
  if [[ ${#incompatible_packs[@]} -gt 0 ]]; then
    warn "The following installed packs are incompatible with the new profile:"
    for pack in "${incompatible_packs[@]}"; do
      echo "  - $pack"
    done
    echo ""
    warn "You should remove these packs after reconfiguration"
    echo ""
  fi

  if [[ ${#missing_required_packs[@]} -gt 0 ]]; then
    warn "The following packs are required for $execution_mode mode:"
    for pack in "${missing_required_packs[@]}"; do
      echo "  - $pack"
    done
    echo ""
    warn "You should install these packs after reconfiguration"
    echo ""
  fi

  # Return true if there are any issues
  if [[ ${#incompatible_packs[@]} -gt 0 || ${#missing_required_packs[@]} -gt 0 ]]; then
    return 1
  fi

  return 0
}

# Suggest pack changes
suggest_pack_changes() {
  local visibility="$1"
  local execution_mode="$2"
  local manifest="$3"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  # Get default packs for new profile
  local default_packs
  default_packs=$(echo "$packs_json" | jq -r ".visibility_profiles.${visibility}.default_packs[]")

  # Get currently installed packs
  local installed_packs
  installed_packs=$(echo "$manifest" | jq -r '.packs_installed[]')

  # Find packs to add
  local packs_to_add=()
  while IFS= read -r pack; do
    if [[ -z "$pack" ]]; then
      continue
    fi

    if ! echo "$installed_packs" | grep -q "^${pack}$"; then
      packs_to_add+=("$pack")
    fi
  done <<< "$default_packs"

  # Find packs to remove (from excluded list)
  local excluded_packs
  excluded_packs=$(echo "$packs_json" | jq -r ".visibility_profiles.${visibility}.excluded_packs[]?" 2>/dev/null || echo "")

  local packs_to_remove=()
  while IFS= read -r pack; do
    if [[ -z "$pack" ]]; then
      continue
    fi

    if echo "$installed_packs" | grep -q "^${pack}$"; then
      packs_to_remove+=("$pack")
    fi
  done <<< "$excluded_packs"

  # Display suggestions
  if [[ ${#packs_to_add[@]} -gt 0 || ${#packs_to_remove[@]} -gt 0 ]]; then
    echo ""
    info "Suggested pack changes for $visibility repository:"
    echo ""

    if [[ ${#packs_to_add[@]} -gt 0 ]]; then
      echo "Packs to add:"
      for pack in "${packs_to_add[@]}"; do
        local pack_name
        pack_name=$(echo "$packs_json" | jq -r ".packs.${pack}.name // \"$pack\"")
        echo "  npx claude-tastic add-pack $pack    # $pack_name"
      done
      echo ""
    fi

    if [[ ${#packs_to_remove[@]} -gt 0 ]]; then
      echo "Packs to remove:"
      for pack in "${packs_to_remove[@]}"; do
        local pack_name
        pack_name=$(echo "$packs_json" | jq -r ".packs.${pack}.name // \"$pack\"")
        echo "  npx claude-tastic remove-pack $pack    # $pack_name"
      done
      echo ""
    fi
  fi
}

# Update manifest
update_manifest() {
  local visibility="$1"
  local execution_mode="$2"
  local manifest="$3"

  # Determine branch strategy
  local branch_strategy
  if [[ "$visibility" == "public" ]]; then
    branch_strategy="main-only"
  else
    branch_strategy="dev-qa-main"
  fi

  # Update profile
  manifest=$(echo "$manifest" | jq --arg visibility "$visibility" '.profile.visibility = $visibility')
  manifest=$(echo "$manifest" | jq --arg execution_mode "$execution_mode" '.profile.execution_mode = $execution_mode')
  manifest=$(echo "$manifest" | jq --arg branch_strategy "$branch_strategy" '.profile.branch_strategy = $branch_strategy')

  # Update last_updated timestamp
  manifest=$(echo "$manifest" | jq --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.last_updated = $timestamp')

  echo "$manifest"
}

# Main function
main() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" || "${1:-}" == "help" ]]; then
    usage
    exit 0
  fi

  echo ""
  echo -e "${BOLD}Reconfigure Framework Profile${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Pre-flight checks
  check_git_repo

  # Load current manifest
  local manifest
  manifest=$(load_manifest)

  local current_visibility current_mode
  current_visibility=$(echo "$manifest" | jq -r '.profile.visibility')
  current_mode=$(echo "$manifest" | jq -r '.profile.execution_mode')

  info "Current profile: $current_visibility repository, $current_mode execution mode"

  # Interactive prompts
  local new_visibility new_mode
  new_visibility=$(prompt_visibility "$current_visibility")
  new_mode=$(prompt_execution_mode "$current_mode")

  # Check if anything changed
  if [[ "$new_visibility" == "$current_visibility" && "$new_mode" == "$current_mode" ]]; then
    info "No changes to profile"
    exit 0
  fi

  # Show what's changing
  echo ""
  echo -e "${BOLD}Configuration Changes${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  if [[ "$new_visibility" != "$current_visibility" ]]; then
    echo "Visibility:     $current_visibility → $new_visibility"
  fi

  if [[ "$new_mode" != "$current_mode" ]]; then
    echo "Execution Mode: $current_mode → $new_mode"
  fi

  echo ""

  # Check pack compatibility
  if ! check_pack_compatibility "$new_visibility" "$new_mode" "$manifest"; then
    echo ""
    warn "Some installed packs may not be compatible with the new profile"
    read -p "Continue anyway? [y/N]: " continue_anyway
    if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
      info "Reconfiguration cancelled"
      exit 0
    fi
  fi

  # Suggest pack changes
  suggest_pack_changes "$new_visibility" "$new_mode" "$manifest"

  # Confirm changes
  read -p "Apply these changes? [Y/n]: " proceed
  if [[ "$proceed" =~ ^[Nn]$ ]]; then
    info "Reconfiguration cancelled"
    exit 0
  fi

  echo ""

  # Update manifest
  manifest=$(update_manifest "$new_visibility" "$new_mode" "$manifest")
  save_manifest "$manifest"

  success "Profile reconfigured successfully!"
  echo ""

  info "Next steps:"
  echo "  1. Review suggested pack changes above (if any)"
  echo "  2. Add or remove packs as needed"
  echo "  3. Check status: npx claude-tastic status"
  echo "  4. Commit changes: git add .claude-tastic-manifest.json && git commit -m 'chore: reconfigure framework profile'"
  echo ""
}

# Run main
main "$@"
