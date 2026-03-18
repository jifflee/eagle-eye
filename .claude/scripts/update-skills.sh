#!/bin/bash
set -euo pipefail
# update-skills.sh
# Syncs skills, agents, and scripts from claude-tastic repo to ~/.claude/
#
# Usage:
#   ./scripts/skill-sync.sh                # Sync all
#   ./scripts/skill-sync.sh --pull         # Git pull first, then sync
#   ./scripts/skill-sync.sh --status       # Show counts and orphans
#   ./scripts/skill-sync.sh --clean        # Remove orphaned files (with confirmation)
#   ./scripts/skill-sync.sh --clean --dry-run  # Preview orphan removal

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

# Parse args
PULL=false
STATUS_ONLY=false
CLEAN=false
DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --pull) PULL=true; shift ;;
    --status) STATUS_ONLY=true; shift ;;
    --clean) CLEAN=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

# Function to find orphaned files (in dest but not in source)
find_orphans() {
  local dest_dir="$1"
  local src_dirs="$2"  # Space-separated list of source directories
  local extension="$3"
  local orphans=()

  # Get all files in destination (use nullglob behavior via test)
  for dest_file in "$dest_dir"/*."$extension"; do
    [ -f "$dest_file" ] || continue
    local base
    base=$(basename "$dest_file")
    local found=false

    # Check if file exists in any source directory
    for src_dir in $src_dirs; do
      if [ -f "$src_dir/$base" ]; then
        found=true
        break
      fi
    done

    if [ "$found" = false ]; then
      orphans+=("$dest_file")
    fi
  done

  # Only print if there are orphans
  if [ ${#orphans[@]} -gt 0 ]; then
    printf '%s\n' "${orphans[@]}"
  fi
}

# Function to get source directories for agents
get_agent_sources() {
  local sources="$REPO_DIR/core/agents"
  for pack_dir in "$REPO_DIR/packs/"*/; do
    [ -d "$pack_dir/agents" ] && sources="$sources $pack_dir/agents"
  done
  echo "$sources"
}

# Function to get source directories for commands
get_command_sources() {
  local sources="$REPO_DIR/core/commands"
  for pack_dir in "$REPO_DIR/packs/"*/; do
    [ -d "$pack_dir/commands" ] && sources="$sources $pack_dir/commands"
  done
  echo "$sources"
}

# Function to count orphans
count_orphans() {
  local agent_result command_result script_result
  agent_result=$(find_orphans "$CLAUDE_DIR/agents" "$(get_agent_sources)" "md")
  command_result=$(find_orphans "$CLAUDE_DIR/commands" "$(get_command_sources)" "md")
  script_result=$(find_orphans "$CLAUDE_DIR/scripts" "$REPO_DIR/scripts" "sh")

  local agent_orphans=0 command_orphans=0 script_orphans=0
  [ -n "$agent_result" ] && agent_orphans=$(echo "$agent_result" | wc -l | tr -d ' ')
  [ -n "$command_result" ] && command_orphans=$(echo "$command_result" | wc -l | tr -d ' ')
  [ -n "$script_result" ] && script_orphans=$(echo "$script_result" | wc -l | tr -d ' ')

  echo "$agent_orphans $command_orphans $script_orphans"
}

# Status only
if [ "$STATUS_ONLY" = true ]; then
  echo "Installed in $CLAUDE_DIR:"
  echo "  Agents:   $(find "$CLAUDE_DIR/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  Commands: $(find "$CLAUDE_DIR/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
  echo "  Scripts:  $(find "$CLAUDE_DIR/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')"

  # Check for orphans
  read -r agent_orphans command_orphans script_orphans <<< "$(count_orphans)"
  total_orphans=$((agent_orphans + command_orphans + script_orphans))

  if [ "$total_orphans" -gt 0 ]; then
    echo ""
    echo "Orphans (not in source repo):"
    [ "$agent_orphans" -gt 0 ] && echo "  Agents:   $agent_orphans"
    [ "$command_orphans" -gt 0 ] && echo "  Commands: $command_orphans"
    [ "$script_orphans" -gt 0 ] && echo "  Scripts:  $script_orphans"
    echo ""
    echo "Use --clean to remove orphans, or --clean --dry-run to preview"
  fi
  exit 0
fi

# Clean orphans
if [ "$CLEAN" = true ]; then
  # Collect all orphans
  agent_orphan_list=$(find_orphans "$CLAUDE_DIR/agents" "$(get_agent_sources)" "md")
  command_orphan_list=$(find_orphans "$CLAUDE_DIR/commands" "$(get_command_sources)" "md")
  script_orphan_list=$(find_orphans "$CLAUDE_DIR/scripts" "$REPO_DIR/scripts" "sh")

  # Combine into array
  all_orphans=()
  [ -n "$agent_orphan_list" ] && while IFS= read -r f; do all_orphans+=("$f"); done <<< "$agent_orphan_list"
  [ -n "$command_orphan_list" ] && while IFS= read -r f; do all_orphans+=("$f"); done <<< "$command_orphan_list"
  [ -n "$script_orphan_list" ] && while IFS= read -r f; do all_orphans+=("$f"); done <<< "$script_orphan_list"

  if [ ${#all_orphans[@]} -eq 0 ]; then
    echo "No orphans found."
    exit 0
  fi

  echo "Orphaned files found (${#all_orphans[@]} total):"
  for orphan in "${all_orphans[@]}"; do
    echo "  $orphan"
  done
  echo ""

  if [ "$DRY_RUN" = true ]; then
    echo "[Dry run] Would remove ${#all_orphans[@]} file(s)"
    exit 0
  fi

  # Require confirmation
  echo -n "Remove these ${#all_orphans[@]} file(s)? [y/N] "
  read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    for orphan in "${all_orphans[@]}"; do
      rm "$orphan"
      echo "Removed: $orphan"
    done
    echo ""
    echo "Cleaned ${#all_orphans[@]} orphan(s)"
  else
    echo "Aborted."
  fi
  exit 0
fi

# Pull if requested
if [ "$PULL" = true ]; then
  echo "Pulling latest..."
  git -C "$REPO_DIR" pull origin main
fi

# Create directories
mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/commands" "$CLAUDE_DIR/scripts"

# Count before
agents_before=$(find "$CLAUDE_DIR/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
commands_before=$(find "$CLAUDE_DIR/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
scripts_before=$(find "$CLAUDE_DIR/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')

# Sync core
cp "$REPO_DIR/core/agents/"*.md "$CLAUDE_DIR/agents/" 2>/dev/null || true
cp "$REPO_DIR/core/commands/"*.md "$CLAUDE_DIR/commands/" 2>/dev/null || true

# Sync packs
for pack_dir in "$REPO_DIR/packs/"*/; do
  [ -d "$pack_dir" ] || continue
  [ -d "$pack_dir/agents" ] && cp "$pack_dir/agents/"*.md "$CLAUDE_DIR/agents/" 2>/dev/null || true
  [ -d "$pack_dir/commands" ] && cp "$pack_dir/commands/"*.md "$CLAUDE_DIR/commands/" 2>/dev/null || true
done

# Sync scripts
cp "$REPO_DIR/scripts/"*.sh "$CLAUDE_DIR/scripts/" 2>/dev/null || true

# Count after
agents_after=$(find "$CLAUDE_DIR/agents" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
commands_after=$(find "$CLAUDE_DIR/commands" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
scripts_after=$(find "$CLAUDE_DIR/scripts" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')

# Report
echo "Synced to $CLAUDE_DIR"
echo "  Agents:   $agents_before -> $agents_after"
echo "  Commands: $commands_before -> $commands_after"
echo "  Scripts:  $scripts_before -> $scripts_after"
