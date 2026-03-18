#!/usr/bin/env bash
#
# init-command.sh
# Interactive initialization of claude-tastic framework in a consumer repo
# Called by: npx claude-tastic init
#
# This script:
#   - Prompts for repo visibility (public/private)
#   - Prompts for execution mode (local/hosted/hybrid)
#   - Prompts for pack selection
#   - Copies files based on selections
#   - Generates/merges CLAUDE.md
#   - Creates .claude-tastic-manifest.json
#   - Updates .gitignore

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
info() { echo -e "${BLUE}[init]${NC} $*"; }
success() { echo -e "${GREEN}[init]${NC} $*"; }
warn() { echo -e "${YELLOW}[init]${NC} $*"; }
error() { echo -e "${RED}[init]${NC} $*" >&2; }

# Check if we're in a git repository
check_git_repo() {
  if ! git rev-parse --git-dir &>/dev/null; then
    error "Not in a git repository"
    error "Initialize git first: git init && git remote add origin <url>"
    exit 1
  fi
}

# Check if already initialized
check_already_initialized() {
  if [[ -f ".claude-tastic-manifest.json" ]]; then
    warn "Framework already initialized"
    echo ""
    read -p "Do you want to reconfigure? [y/N]: " reconfigure
    if [[ ! "$reconfigure" =~ ^[Yy]$ ]]; then
      info "Use 'npx claude-tastic reconfigure' to change settings"
      exit 0
    fi
    return 0
  fi
  return 1
}

# Prompt for visibility
prompt_visibility() {
  echo ""
  echo -e "${BOLD}Repository Visibility${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
  read -p "Select [1-2] (default: 2): " choice

  case "$choice" in
    1)
      echo "public"
      ;;
    2|"")
      echo "private"
      ;;
    *)
      warn "Invalid choice, defaulting to private"
      echo "private"
      ;;
  esac
}

# Prompt for execution mode
prompt_execution_mode() {
  echo ""
  echo -e "${BOLD}Execution Mode${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
  read -p "Select [1-3] (default: 1): " choice

  case "$choice" in
    1|"")
      echo "local"
      ;;
    2)
      echo "hosted"
      ;;
    3)
      echo "hybrid"
      ;;
    *)
      warn "Invalid choice, defaulting to local"
      echo "local"
      ;;
  esac
}

# Get default packs for visibility profile
get_default_packs() {
  local visibility="$1"
  local packs_json
  packs_json=$(cat "$PACKAGE_ROOT/packs.json")

  echo "$packs_json" | jq -r ".visibility_profiles.${visibility}.default_packs[]"
}

# Prompt for pack selection
prompt_pack_selection() {
  local visibility="$1"
  local exec_mode="$2"

  echo ""
  echo -e "${BOLD}Pack Selection${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Get default packs
  local default_packs
  default_packs=$(get_default_packs "$visibility")

  info "Default packs for $visibility repository:"
  echo "$default_packs" | while read -r pack; do
    local name desc
    name=$(jq -r ".packs.${pack}.name // \"$pack\"" "$PACKAGE_ROOT/packs.json")
    desc=$(jq -r ".packs.${pack}.description // \"\"" "$PACKAGE_ROOT/packs.json")
    echo "  ✓ $name - $desc"
  done

  echo ""
  read -p "Use default packs? [Y/n]: " use_defaults

  if [[ "$use_defaults" =~ ^[Nn]$ ]]; then
    warn "Custom pack selection not yet implemented"
    info "Using default packs"
  fi

  # Return default packs as newline-separated list
  echo "$default_packs"
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

  while IFS= read -r pattern; do
    # Handle glob patterns
    if [[ "$pattern" == *"*"* ]]; then
      # Expand glob in package root
      while IFS= read -r file; do
        if [[ -f "$PACKAGE_ROOT/$file" ]]; then
          local rel_path="${file#$PACKAGE_ROOT/}"
          local target_file="$target_dir/$rel_path"
          local target_subdir
          target_subdir=$(dirname "$target_file")

          # Create directory if needed
          mkdir -p "$target_subdir"

          # Copy file
          if cp "$PACKAGE_ROOT/$file" "$target_file" 2>/dev/null; then
            ((copied++))
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

        # Copy file (skip if already exists and identical)
        if [[ ! -f "$target_file" ]] || ! cmp -s "$PACKAGE_ROOT/$pattern" "$target_file"; then
          cp "$PACKAGE_ROOT/$pattern" "$target_file"
          ((copied++))
        else
          ((skipped++))
        fi
      fi
    fi
  done <<< "$files"

  if [[ $copied -gt 0 ]]; then
    success "  Copied $copied files"
  fi
  if [[ $skipped -gt 0 ]]; then
    info "  Skipped $skipped files (already up to date)"
  fi
}

# Generate CLAUDE.md from template
generate_claude_md() {
  local visibility="$1"
  local exec_mode="$2"
  local packs="$3"
  local framework_version="$4"

  info "Generating CLAUDE.md..."

  # Read template
  local template
  template=$(cat "$PACKAGE_ROOT/templates/CLAUDE.md.template")

  # Get repo info
  local repo_owner repo_name
  if git remote get-url origin &>/dev/null; then
    local origin
    origin=$(git remote get-url origin)
    repo_owner=$(echo "$origin" | sed -E 's/.*[:/]([^/]+)\/([^/]+)(\.git)?$/\1/')
    repo_name=$(echo "$origin" | sed -E 's/.*[:/]([^/]+)\/([^/]+)(\.git)?$/\2/' | sed 's/\.git$//')
  else
    repo_owner="unknown"
    repo_name="unknown"
  fi

  # Replace variables
  template="${template//\{\{PROJECT_DESCRIPTION\}\}/Project initialized with claude-tastic framework}"
  template="${template//\{\{REPO_OWNER\}\}/$repo_owner}"
  template="${template//\{\{REPO_NAME\}\}/$repo_name}"
  template="${template//\{\{VISIBILITY\}\}/$visibility}"
  template="${template//\{\{EXECUTION_MODE\}\}/$exec_mode}"
  template="${template//\{\{FRAMEWORK_VERSION\}\}/$framework_version}"
  template="${template//\{\{INSTALLED_AT\}\}/$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  template="${template//\{\{GENERATED_AT\}\}/$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

  # Handle conditional sections
  # IF_AGENTS_FULL
  if echo "$packs" | grep -q "agents-full"; then
    template=$(echo "$template" | sed '/{{#IF_AGENTS_FULL}}/,/{{\/IF_AGENTS_FULL}}/s/{{#IF_AGENTS_FULL}}//' | sed '/{{\/IF_AGENTS_FULL}}/d')
    template=$(echo "$template" | sed '/{{#IF_AGENTS_MINIMAL}}/,/{{\/IF_AGENTS_MINIMAL}}/d')
  else
    template=$(echo "$template" | sed '/{{#IF_AGENTS_FULL}}/,/{{\/IF_AGENTS_FULL}}/d')
    template=$(echo "$template" | sed '/{{#IF_AGENTS_MINIMAL}}/,/{{\/IF_AGENTS_MINIMAL}}/s/{{#IF_AGENTS_MINIMAL}}//' | sed '/{{\/IF_AGENTS_MINIMAL}}/d')
  fi

  # IF_PRIVATE
  if [[ "$visibility" == "private" ]]; then
    template=$(echo "$template" | sed '/{{#IF_PRIVATE}}/,/{{\/IF_PRIVATE}}/s/{{#IF_PRIVATE}}//' | sed '/{{\/IF_PRIVATE}}/d')
    template=$(echo "$template" | sed '/{{#IF_PUBLIC}}/,/{{\/IF_PUBLIC}}/d')
  else
    template=$(echo "$template" | sed '/{{#IF_PRIVATE}}/,/{{\/IF_PRIVATE}}/d')
    template=$(echo "$template" | sed '/{{#IF_PUBLIC}}/,/{{\/IF_PUBLIC}}/s/{{#IF_PUBLIC}}//' | sed '/{{\/IF_PUBLIC}}/d')
  fi

  # IF_VISIBILITY_PUBLIC
  if [[ "$visibility" == "public" ]]; then
    template=$(echo "$template" | sed '/{{#IF_VISIBILITY_PUBLIC}}/,/{{\/IF_VISIBILITY_PUBLIC}}/s/{{#IF_VISIBILITY_PUBLIC}}//' | sed '/{{\/IF_VISIBILITY_PUBLIC}}/d')
  else
    template=$(echo "$template" | sed '/{{#IF_VISIBILITY_PUBLIC}}/,/{{\/IF_VISIBILITY_PUBLIC}}/d')
  fi

  # IF_EXECUTION_MODE_*
  case "$exec_mode" in
    local)
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_LOCAL}}/,/{{\/IF_EXECUTION_MODE_LOCAL}}/s/{{#IF_EXECUTION_MODE_LOCAL}}//' | sed '/{{\/IF_EXECUTION_MODE_LOCAL}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HOSTED}}/,/{{\/IF_EXECUTION_MODE_HOSTED}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HYBRID}}/,/{{\/IF_EXECUTION_MODE_HYBRID}}/d')
      ;;
    hosted)
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_LOCAL}}/,/{{\/IF_EXECUTION_MODE_LOCAL}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HOSTED}}/,/{{\/IF_EXECUTION_MODE_HOSTED}}/s/{{#IF_EXECUTION_MODE_HOSTED}}//' | sed '/{{\/IF_EXECUTION_MODE_HOSTED}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HYBRID}}/,/{{\/IF_EXECUTION_MODE_HYBRID}}/d')
      ;;
    hybrid)
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_LOCAL}}/,/{{\/IF_EXECUTION_MODE_LOCAL}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HOSTED}}/,/{{\/IF_EXECUTION_MODE_HOSTED}}/d')
      template=$(echo "$template" | sed '/{{#IF_EXECUTION_MODE_HYBRID}}/,/{{\/IF_EXECUTION_MODE_HYBRID}}/s/{{#IF_EXECUTION_MODE_HYBRID}}//' | sed '/{{\/IF_EXECUTION_MODE_HYBRID}}/d')
      ;;
  esac

  # Handle pack-based conditionals
  for pack_type in "SKILLS_SPRINT" "SKILLS_CAPTURE" "SKILLS_PR" "SKILLS_AUDIT" "SKILLS_RELEASE" "SKILLS_WORKTREE" "SKILLS_MILESTONE" "SKILLS_ISSUE" "SKILLS_REPO" "SCRIPTS_CONTAINER"; do
    local pack_key
    pack_key=$(echo "$pack_type" | tr '[:upper:]' '[:lower:]' | tr '_' '-')

    if echo "$packs" | grep -q "$pack_key"; then
      template=$(echo "$template" | sed "/{{#IF_${pack_type}}}/,/{{\/IF_${pack_type}}}/s/{{#IF_${pack_type}}}//" | sed "/{{\/IF_${pack_type}}}/d")
    else
      template=$(echo "$template" | sed "/{{#IF_${pack_type}}}/,/{{\/IF_${pack_type}}}/d")
    fi
  done

  # Write CLAUDE.md
  if [[ -f "CLAUDE.md" ]]; then
    warn "CLAUDE.md already exists"
    read -p "Overwrite? [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
      info "Keeping existing CLAUDE.md"
      return 0
    fi
  fi

  echo "$template" > CLAUDE.md
  success "Generated CLAUDE.md"
}

# Create manifest file
create_manifest() {
  local visibility="$1"
  local exec_mode="$2"
  local packs="$3"
  local framework_version="$4"

  info "Creating .claude-tastic-manifest.json..."

  # Get repo info
  local repo_owner repo_name
  if git remote get-url origin &>/dev/null; then
    local origin
    origin=$(git remote get-url origin)
    repo_owner=$(echo "$origin" | sed -E 's/.*[:/]([^/]+)\/([^/]+)(\.git)?$/\1/')
    repo_name=$(echo "$origin" | sed -E 's/.*[:/]([^/]+)\/([^/]+)(\.git)?$/\2/' | sed 's/\.git$//')
  else
    repo_owner="unknown"
    repo_name="unknown"
  fi

  # Get current user
  local installed_by
  installed_by=$(git config user.name || echo "unknown")

  # Determine branch strategy
  local branch_strategy
  if [[ "$visibility" == "public" ]]; then
    branch_strategy="main-only"
  else
    branch_strategy="dev-qa-main"
  fi

  # Build packs array
  local packs_array
  packs_array=$(echo "$packs" | jq -R -s -c 'split("\n") | map(select(length > 0))')

  # Create manifest
  cat > .claude-tastic-manifest.json <<EOF
{
  "framework_version": "$framework_version",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "profile": {
    "visibility": "$visibility",
    "execution_mode": "$exec_mode",
    "branch_strategy": "$branch_strategy"
  },
  "packs_installed": $packs_array,
  "packs_skipped": [],
  "customizations": {},
  "last_updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "update_history": [],
  "metadata": {
    "repository": "$repo_owner/$repo_name",
    "installed_by": "$installed_by",
    "init_command": "npx claude-tastic init"
  }
}
EOF

  success "Created .claude-tastic-manifest.json"
}

# Update .gitignore
update_gitignore() {
  info "Updating .gitignore..."

  local entries=(
    "# Claude-tastic framework cache directories"
    ".qa-gate-cache/"
    ".pr-gate-cache/"
    ".claude-tastic-update-cache.json"
    ""
    "# Claude Code session files"
    ".claude-code/"
    ""
  )

  # Check if .gitignore exists
  if [[ ! -f .gitignore ]]; then
    touch .gitignore
  fi

  # Add entries if not already present
  local added=0
  for entry in "${entries[@]}"; do
    if [[ -n "$entry" ]] && ! grep -qF "$entry" .gitignore 2>/dev/null; then
      echo "$entry" >> .gitignore
      ((added++))
    fi
  done

  if [[ $added -gt 0 ]]; then
    success "Added $added entries to .gitignore"
  else
    info ".gitignore already up to date"
  fi
}

# Main initialization flow
main() {
  echo ""
  echo -e "${BOLD}Claude-tastic Framework Initialization${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Pre-flight checks
  check_git_repo

  local is_reconfigure=false
  if check_already_initialized; then
    is_reconfigure=true
  fi

  # Get framework version from package.json
  local framework_version
  framework_version=$(jq -r '.version' "$PACKAGE_ROOT/package.json")

  # Interactive prompts
  local visibility exec_mode packs
  visibility=$(prompt_visibility)
  exec_mode=$(prompt_execution_mode)
  packs=$(prompt_pack_selection "$visibility" "$exec_mode")

  # Installation summary
  echo ""
  echo -e "${BOLD}Installation Summary${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Repository:      $visibility"
  echo "Execution Mode:  $exec_mode"
  echo "Framework:       v$framework_version"
  echo "Packs:           $(echo "$packs" | wc -l | xargs) selected"
  echo ""

  read -p "Proceed with installation? [Y/n]: " proceed
  if [[ "$proceed" =~ ^[Nn]$ ]]; then
    warn "Installation cancelled"
    exit 0
  fi

  echo ""
  info "Installing framework..."
  echo ""

  # Copy files for each pack
  while IFS= read -r pack; do
    if [[ -n "$pack" ]]; then
      copy_pack_files "$pack"
    fi
  done <<< "$packs"

  echo ""

  # Generate CLAUDE.md
  generate_claude_md "$visibility" "$exec_mode" "$packs" "$framework_version"

  # Create manifest
  create_manifest "$visibility" "$exec_mode" "$packs" "$framework_version"

  # Update .gitignore
  update_gitignore

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  success "Framework initialized successfully!"
  echo ""

  info "Next steps:"
  echo "  1. Review generated files (CLAUDE.md, .claude-tastic-manifest.json)"
  echo "  2. Commit changes: git add -A && git commit -m 'chore: initialize claude-tastic framework'"
  echo "  3. Check status: npx claude-tastic status"
  if [[ "$visibility" == "private" ]]; then
    echo "  4. Initialize repo: ./scripts/init-repo.sh --all"
    echo "  5. Create first issue: gh issue create"
  fi
  echo ""
}

# Run main
main "$@"
