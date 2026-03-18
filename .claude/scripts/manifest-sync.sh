#!/usr/bin/env bash
#
# manifest-sync.sh - Total sync using framework manifest
# Performs declarative sync: adds new, updates changed, removes stale files
#
# Usage:
#   ./scripts/manifest-sync.sh                    # Sync to .claude/ in current repo
#   ./scripts/manifest-sync.sh --check            # Dry run showing what would change
#   ./scripts/manifest-sync.sh --target DIR       # Sync to custom target
#   ./scripts/manifest-sync.sh --category agents  # Sync only specific category
#   ./scripts/manifest-sync.sh --force            # Force sync even if versions match
#   ./scripts/manifest-sync.sh --global-only      # Sync only global skills (with global: true frontmatter)
#   ./scripts/manifest-sync.sh --clean            # Remove old hyphenated skill names (pre-colon migration)
#   ./scripts/manifest-sync.sh --force --clean    # Force sync and clean old-named files
#
# Container context usage (framework cloned to /tmp/framework/):
#   bash /tmp/framework/scripts/manifest-sync.sh --target /workspace/repo/.claude/
#   bash /tmp/framework/scripts/manifest-sync.sh --target .claude/
#   bash /tmp/framework/scripts/manifest-sync.sh --manifest /tmp/framework/.claude/.manifest.json --target .claude/

set -euo pipefail

# Resolve script and repo directories robustly.
# BASH_SOURCE[0] is used instead of $0 so this works correctly when called as:
#   bash /tmp/framework/scripts/manifest-sync.sh   (container context)
#   ./scripts/manifest-sync.sh                     (local context)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_FILE="$REPO_DIR/.claude/.manifest.json"

# Defaults
TARGET_DIR=""
CHECK_MODE=false
FORCE=false
CATEGORY_FILTER=""
GLOBAL_ONLY=false
CLEAN_OLD_NAMES=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--dry-run) CHECK_MODE=true; shift ;;
    --force) FORCE=true; shift ;;
    --target) TARGET_DIR="$2"; shift 2 ;;
    --manifest) MANIFEST_FILE="$2"; shift 2 ;;
    --category) CATEGORY_FILTER="$2"; shift 2 ;;
    --global-only) GLOBAL_ONLY=true; shift ;;
    --clean) CLEAN_OLD_NAMES=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--check] [--force] [--target DIR] [--manifest FILE] [--category NAME] [--global-only] [--clean]"
      echo ""
      echo "Options:"
      echo "  --check           Dry run - show what would change without making changes"
      echo "  --force           Force sync even if versions match"
      echo "  --target DIR      Sync to custom target directory (default: .claude/)"
      echo "  --manifest FILE   Use a specific manifest file (default: REPO_DIR/.claude/.manifest.json)"
      echo "                    Useful in container context: --manifest /tmp/framework/.claude/.manifest.json"
      echo "  --category NAME   Sync only specific category (agents, commands, scripts)"
      echo "  --global-only     Sync only global skills (with global: true frontmatter)"
      echo "  --clean           Remove old hyphenated skill names from target directories"
      echo "                    (pre-colon migration cleanup, e.g., 'tool-skill-sync' -> 'tool:skill-sync')"
      echo ""
      echo "Container context example:"
      echo "  bash /tmp/framework/scripts/manifest-sync.sh --target /workspace/repo/.claude/"
      echo ""
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Normalize MANIFEST_FILE to absolute path.
# When called from a container with a relative path, this ensures the manifest
# is resolved correctly regardless of working directory.
if [[ "$MANIFEST_FILE" != /* ]]; then
  MANIFEST_FILE="$(pwd)/$MANIFEST_FILE"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Validate manifest exists
if [ ! -f "$MANIFEST_FILE" ]; then
  echo -e "${RED}Error: Manifest not found at $MANIFEST_FILE${NC}" >&2
  echo "" >&2
  echo "  Framework dir: $REPO_DIR" >&2
  # Detect container context (framework typically cloned to /tmp/)
  if [[ "$REPO_DIR" == /tmp/* ]]; then
    echo "  Container context detected (framework at $REPO_DIR)." >&2
    echo "  Ensure the framework repo was fully cloned and contains .claude/.manifest.json." >&2
    echo "  The manifest is generated as part of the framework release — it should be" >&2
    echo "  present in any tagged version of the framework repository." >&2
  else
    echo "  To generate the manifest, run:" >&2
    echo "    cd \"$REPO_DIR\" && ./scripts/generate-manifest.sh" >&2
  fi
  exit 1
fi

# Normalize TARGET_DIR to absolute path.
# This is critical for container context where --target is passed as a relative
# path (e.g. .claude/) from the consumer repo's working directory.
# Without normalization, internal path operations could fail if CWD changes.
_resolve_target_dir() {
  local dir="$1"
  if [[ "$dir" == /* ]]; then
    # Already absolute
    echo "$dir"
  else
    # Relative path: resolve against current working directory
    echo "$(pwd)/${dir%/}"
  fi
}

# Determine target directory and set exclusion mode
if [ "$GLOBAL_ONLY" = true ]; then
  # Global-only mode: sync to ~/.claude/ (unless custom target specified)
  if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$HOME/.claude"
  fi
else
  # Project-level mode: sync to .claude/ in current repo (unless custom target)
  if [ -z "$TARGET_DIR" ]; then
    TARGET_DIR="$REPO_DIR/.claude"
  fi
  # Global skills are synced to BOTH project-level and ~/.claude/
  # Previously excluded from project-level to "prevent duplicates" but this
  # caused skills to be missing from .claude/commands/ (Issue #1205)
fi

# Normalize TARGET_DIR to absolute path (handles relative paths like .claude/ correctly
# in container context where the script is invoked from a different directory than CWD)
TARGET_DIR="$(_resolve_target_dir "$TARGET_DIR")"

echo -e "${BLUE}Manifest Sync${NC}"
echo "  Source manifest: $MANIFEST_FILE"
echo "  Framework dir:   $REPO_DIR"
echo "  Target:          $TARGET_DIR"
if [ "$GLOBAL_ONLY" = true ]; then
  echo "  Mode: Global skills only"
fi
# Indicate container context for easier debugging
if [[ "$REPO_DIR" == /tmp/* ]]; then
  echo "  Context: container (framework from $REPO_DIR)"
fi
echo ""

# Read manifest metadata
MANIFEST_VERSION=$(jq -r '.manifest_version' "$MANIFEST_FILE")
FRAMEWORK_VERSION=$(jq -r '.framework_version' "$MANIFEST_FILE")
FILE_COUNT=$(jq -r '.file_count' "$MANIFEST_FILE")

echo "  Manifest version: $MANIFEST_VERSION"
echo "  Framework version: $FRAMEWORK_VERSION"
echo "  Files in manifest: $FILE_COUNT"
echo ""

# Check existing installed manifest at target
INSTALLED_MANIFEST="$TARGET_DIR/.manifest.json"
if [ -f "$INSTALLED_MANIFEST" ]; then
  INSTALLED_VERSION=$(jq -r '.framework_version' "$INSTALLED_MANIFEST" 2>/dev/null || echo "unknown")
  echo "  Installed version: $INSTALLED_VERSION"

  if [ "$INSTALLED_VERSION" = "$FRAMEWORK_VERSION" ] && [ "$FORCE" = false ]; then
    echo "  Versions match — checking for file-level changes..."
  fi
else
  echo "  No previous installation found (fresh install)"
fi

echo ""

# Calculate SHA256 hash
calculate_hash() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  else
    echo "unknown"
  fi
}

# Check if a file has global: true in frontmatter
is_global_skill() {
  local file="$1"

  # Only check .md files in commands category
  if [[ ! "$file" =~ \.md$ ]]; then
    return 1
  fi

  # Extract frontmatter and check for global: true
  local in_frontmatter=false
  local frontmatter_count=0

  while IFS= read -r line; do
    if [[ "$line" == "---" ]]; then
      ((frontmatter_count++))
      if [[ $frontmatter_count -eq 1 ]]; then
        in_frontmatter=true
        continue
      elif [[ $frontmatter_count -eq 2 ]]; then
        # End of frontmatter, not found
        return 1
      fi
    fi

    if [[ "$in_frontmatter" == true ]] && [[ "$line" =~ ^global:[[:space:]]*true ]]; then
      return 0
    fi
  done < "$file"

  return 1
}

# Track changes
ADDED=0
UPDATED=0
REMOVED=0
UNCHANGED=0
ERRORS=0

# Phase 1: Process files from manifest (add/update)
echo -e "${BLUE}Phase 1: Add/Update files${NC}"

# Get file list from manifest, optionally filtered by category
if [ -n "$CATEGORY_FILTER" ]; then
  FILES=$(jq -r --arg cat "$CATEGORY_FILTER" '.files | to_entries[] | select(.value.category == $cat) | .key' "$MANIFEST_FILE")
else
  FILES=$(jq -r '.files | keys[]' "$MANIFEST_FILE")
fi

while IFS= read -r src_path; do
  [ -z "$src_path" ] && continue

  target_rel=$(jq -r --arg path "$src_path" '.files[$path].target' "$MANIFEST_FILE")
  expected_hash=$(jq -r --arg path "$src_path" '.files[$path].hash' "$MANIFEST_FILE")
  category=$(jq -r --arg path "$src_path" '.files[$path].category' "$MANIFEST_FILE")

  src_full="$REPO_DIR/$src_path"
  target_full="$TARGET_DIR/$target_rel"

  if [ ! -f "$src_full" ]; then
    echo -e "  ${RED}MISSING${NC}: $src_path (source file not found)"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Filter by global: true if --global-only flag is set
  if [ "$GLOBAL_ONLY" = true ] && [ "$category" = "commands" ]; then
    if ! is_global_skill "$src_full"; then
      UNCHANGED=$((UNCHANGED + 1))
      continue
    fi
  fi

  # Note: global skills are no longer excluded from project-level sync (Issue #1205)

  if [ -f "$target_full" ]; then
    # File exists at target - check if it needs updating
    current_hash=$(calculate_hash "$target_full")
    if [ "$current_hash" = "$expected_hash" ]; then
      UNCHANGED=$((UNCHANGED + 1))
      continue
    fi

    # File changed - update
    if [ "$CHECK_MODE" = true ]; then
      echo -e "  ${YELLOW}UPDATE${NC}: $target_rel ($category)"
    else
      mkdir -p "$(dirname "$target_full")"
      cp "$src_full" "$target_full"
      echo -e "  ${YELLOW}UPDATED${NC}: $target_rel"
    fi
    UPDATED=$((UPDATED + 1))
  else
    # New file - add
    if [ "$CHECK_MODE" = true ]; then
      echo -e "  ${GREEN}ADD${NC}: $target_rel ($category)"
    else
      mkdir -p "$(dirname "$target_full")"
      cp "$src_full" "$target_full"
      echo -e "  ${GREEN}ADDED${NC}: $target_rel"
    fi
    ADDED=$((ADDED + 1))
  fi
done <<< "$FILES"

# Phase 2: Remove stale files (only if we have a previous manifest)
echo ""
echo -e "${BLUE}Phase 2: Remove stale files${NC}"

if [ -f "$INSTALLED_MANIFEST" ]; then
  # Get files from installed manifest that are NOT in current manifest
  STALE_FILES=$(jq -r --slurpfile new "$MANIFEST_FILE" '
    .files | keys[] as $k |
    select($new[0].files[$k] == null) |
    .files[$k].target
  ' "$INSTALLED_MANIFEST" 2>/dev/null || true)

  if [ -n "$STALE_FILES" ]; then
    while IFS= read -r stale_target; do
      [ -z "$stale_target" ] && continue
      stale_full="$TARGET_DIR/$stale_target"

      if [ -f "$stale_full" ]; then
        if [ "$CHECK_MODE" = true ]; then
          echo -e "  ${RED}REMOVE${NC}: $stale_target"
        else
          # Backup before removing
          backup_dir="$TARGET_DIR/.sync-backup/$(date +%Y%m%d)"
          mkdir -p "$backup_dir/$(dirname "$stale_target")"
          mv "$stale_full" "$backup_dir/$stale_target"
          echo -e "  ${RED}REMOVED${NC}: $stale_target (backed up)"
        fi
        REMOVED=$((REMOVED + 1))
      fi
    done <<< "$STALE_FILES"
  fi

  if [ "$REMOVED" -eq 0 ]; then
    echo "  No stale files to remove"
  fi
else
  echo "  Skipping removal (no previous manifest to compare)"
fi

# Phase 3: Clean old hyphenated skill names (if --clean flag set)
if [ "$CLEAN_OLD_NAMES" = true ]; then
  echo ""
  echo -e "${BLUE}Phase 3: Clean old hyphenated skill names${NC}"

  OLD_NAMES_REMOVED=0

  # Build list of expected filenames from manifest
  EXPECTED_FILES=$(jq -r '.files | to_entries[] | select(.value.category == "commands") | .value.target | sub("commands/"; "")' "$MANIFEST_FILE" 2>/dev/null || true)

  # Check commands directory for old-named files (files without colon in name)
  COMMANDS_DIR="$TARGET_DIR/commands"
  if [ -d "$COMMANDS_DIR" ]; then
    while IFS= read -r file; do
      [ -z "$file" ] && continue

      filename=$(basename "$file" .md)
      full_filename=$(basename "$file")

      # Check if filename contains a colon - if not, it might be old format
      if [[ ! "$filename" =~ : ]]; then
        # Check if this file is in the current manifest
        # If it's not in manifest and has no colon, it's a stale old-named file
        if ! echo "$EXPECTED_FILES" | grep -qF "$full_filename"; then
          if [ "$CHECK_MODE" = true ]; then
            echo -e "  ${RED}REMOVE${NC}: commands/$full_filename (old hyphenated name, not in manifest)"
          else
            # Backup before removing
            backup_dir="$TARGET_DIR/.sync-backup/$(date +%Y%m%d)-cleanup"
            mkdir -p "$backup_dir/commands"
            mv "$file" "$backup_dir/commands/"
            echo -e "  ${RED}REMOVED${NC}: commands/$full_filename (old hyphenated name, backed up)"
          fi
          OLD_NAMES_REMOVED=$((OLD_NAMES_REMOVED + 1))
        fi
      fi
    done < <(find "$COMMANDS_DIR" -maxdepth 1 -name '*.md' -type f)
  fi

  if [ "$OLD_NAMES_REMOVED" -eq 0 ]; then
    echo "  No old hyphenated names found - all files use colon format"
  else
    echo ""
    echo "  Cleaned $OLD_NAMES_REMOVED old-named files"
    if [ "$CHECK_MODE" = false ]; then
      echo "  Backups saved to: $backup_dir"
    fi
  fi
fi

# Phase 4: Install manifest at target
if [ "$CHECK_MODE" = false ]; then
  cp "$MANIFEST_FILE" "$INSTALLED_MANIFEST"
fi

# Phase 5: Ensure settings.json exists with required hook entries
echo ""
echo -e "${BLUE}Phase 5: Validate settings.json${NC}"

SETTINGS_FILE="$TARGET_DIR/settings.json"

if [ ! -f "$SETTINGS_FILE" ]; then
  if [ "$CHECK_MODE" = true ]; then
    echo -e "  ${GREEN}CREATE${NC}: settings.json (missing — would create with standard hooks)"
    ADDED=$((ADDED + 1))
  else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" << 'SETTINGS_HEREDOC'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/dynamic-loader.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/block-secrets.py"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {
            "type": "command",
            "command": ".claude/hooks/compliance-capture.sh"
          }
        ]
      }
    ]
  }
}
SETTINGS_HEREDOC
    echo -e "  ${GREEN}CREATED${NC}: settings.json (UserPromptSubmit, PreToolUse, PostToolUse hooks)"
    ADDED=$((ADDED + 1))
  fi
else
  # Validate existing settings.json has required hook sections; merge any missing ones
  _MISSING_HOOKS=""
  jq -e '.hooks.UserPromptSubmit' "$SETTINGS_FILE" > /dev/null 2>&1 || _MISSING_HOOKS="$_MISSING_HOOKS UserPromptSubmit"
  jq -e '.hooks.PreToolUse' "$SETTINGS_FILE" > /dev/null 2>&1 || _MISSING_HOOKS="$_MISSING_HOOKS PreToolUse"
  jq -e '.hooks.PostToolUse' "$SETTINGS_FILE" > /dev/null 2>&1 || _MISSING_HOOKS="$_MISSING_HOOKS PostToolUse"
  _MISSING_HOOKS="${_MISSING_HOOKS# }"  # trim leading space

  if [ -n "$_MISSING_HOOKS" ]; then
    if [ "$CHECK_MODE" = true ]; then
      echo -e "  ${YELLOW}UPDATE${NC}: settings.json (would add missing hooks: $_MISSING_HOOKS)"
      UPDATED=$((UPDATED + 1))
    else
      # Merge missing hook sections into existing settings.json (preserves custom settings)
      _SETTINGS_TMP=$(mktemp)
      cp "$SETTINGS_FILE" "$_SETTINGS_TMP"

      for _HOOK_TYPE in $_MISSING_HOOKS; do
        case "$_HOOK_TYPE" in
          UserPromptSubmit)
            jq '.hooks.UserPromptSubmit = [{"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/dynamic-loader.sh"}]}]' \
              "$_SETTINGS_TMP" > "${_SETTINGS_TMP}.new" 2>/dev/null && mv "${_SETTINGS_TMP}.new" "$_SETTINGS_TMP" || true
            ;;
          PreToolUse)
            jq '.hooks.PreToolUse = [{"matcher": "Read|Edit|Write", "hooks": [{"type": "command", "command": "python3 .claude/hooks/block-secrets.py"}]}]' \
              "$_SETTINGS_TMP" > "${_SETTINGS_TMP}.new" 2>/dev/null && mv "${_SETTINGS_TMP}.new" "$_SETTINGS_TMP" || true
            ;;
          PostToolUse)
            jq '.hooks.PostToolUse = [{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": ".claude/hooks/compliance-capture.sh"}]}]' \
              "$_SETTINGS_TMP" > "${_SETTINGS_TMP}.new" 2>/dev/null && mv "${_SETTINGS_TMP}.new" "$_SETTINGS_TMP" || true
            ;;
        esac
      done

      cp "$_SETTINGS_TMP" "$SETTINGS_FILE"
      rm -f "$_SETTINGS_TMP" "${_SETTINGS_TMP}.new" 2>/dev/null || true
      echo -e "  ${YELLOW}UPDATED${NC}: settings.json (added missing hooks: $_MISSING_HOOKS)"
      UPDATED=$((UPDATED + 1))
    fi
  else
    echo "  settings.json has all required hook entries"
  fi
fi

# Summary
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  ${GREEN}Added${NC}:     $ADDED"
echo -e "  ${YELLOW}Updated${NC}:   $UPDATED"
echo -e "  ${RED}Removed${NC}:   $REMOVED"
if [ "$CLEAN_OLD_NAMES" = true ] && [ -n "${OLD_NAMES_REMOVED:-}" ]; then
  echo -e "  ${RED}Cleaned${NC}:   $OLD_NAMES_REMOVED (old hyphenated names)"
fi
echo "  Unchanged: $UNCHANGED"
if [ "$ERRORS" -gt 0 ]; then
  echo -e "  ${RED}Errors${NC}:    $ERRORS"
fi

if [ "$CHECK_MODE" = true ]; then
  echo ""
  echo -e "${YELLOW}Dry run - no changes made${NC}"
fi

exit 0
