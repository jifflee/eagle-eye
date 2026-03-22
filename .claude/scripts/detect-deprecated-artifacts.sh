#!/usr/bin/env bash
#
# detect-deprecated-artifacts.sh - Scan for deprecated framework artifacts in consumer repos
#
# During a framework update, some skills/agents that were previously part of the
# framework may be removed or renamed. This script identifies:
#   - DEPRECATED: files installed from the framework that are no longer in the upstream
#   - LOCAL:      files in .claude/ not originating from the framework (user-created)
#   - CURRENT:    files still present in the upstream framework (no action needed)
#
# Origin tracking is done via .claude/.framework-origin.json (written by manifest-sync.sh).
# If no origin tracking file exists, falls back to comparing against the installed manifest.
#
# Usage:
#   ./scripts/detect-deprecated-artifacts.sh [OPTIONS]
#
# Options:
#   --target DIR          Target .claude/ directory to scan (default: .claude/)
#   --framework-manifest  Path to current framework .manifest.json
#   --category NAME       Limit scan to category: agents, commands (default: all)
#   --check               Dry-run / report only (default behavior - never deletes)
#   --verbose             Show all files including current/unchanged
#   -h, --help            Show help
#
# Exit codes:
#   0  Scan complete (even if deprecated artifacts found)
#   1  Error (missing required files)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
TARGET_DIR=".claude"
FRAMEWORK_MANIFEST=""
CATEGORY_FILTER=""
VERBOSE=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET_DIR="$2"; shift 2 ;;
    --framework-manifest) FRAMEWORK_MANIFEST="$2"; shift 2 ;;
    --category) CATEGORY_FILTER="$2"; shift 2 ;;
    --check) shift ;;  # default behavior, kept for compatibility
    --verbose) VERBOSE=true; shift ;;
    -h|--help)
      sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | head -30
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Normalize target to absolute path
if [[ "$TARGET_DIR" != /* ]]; then
  TARGET_DIR="$(pwd)/${TARGET_DIR%/}"
fi

# Auto-detect framework manifest if not specified
if [ -z "$FRAMEWORK_MANIFEST" ]; then
  # Try framework source repo manifest
  if [ -f "$REPO_DIR/.claude/.manifest.json" ]; then
    FRAMEWORK_MANIFEST="$REPO_DIR/.claude/.manifest.json"
  else
    echo -e "${RED}Error: No framework manifest found.${NC}" >&2
    echo "  Specify with: --framework-manifest /path/to/.manifest.json" >&2
    exit 1
  fi
fi

if [ ! -f "$FRAMEWORK_MANIFEST" ]; then
  echo -e "${RED}Error: Framework manifest not found: $FRAMEWORK_MANIFEST${NC}" >&2
  exit 1
fi

# Installed manifest (from last sync)
INSTALLED_MANIFEST="$TARGET_DIR/.manifest.json"

# Origin tracking file (written by manifest-sync.sh)
ORIGIN_FILE="$TARGET_DIR/.framework-origin.json"

echo -e "${BLUE}Deprecated Artifact Detector${NC}"
echo "  Target:             $TARGET_DIR"
echo "  Framework manifest: $FRAMEWORK_MANIFEST"
echo "  Origin tracking:    $([ -f "$ORIGIN_FILE" ] && echo "found" || echo "not found (fallback to installed manifest)")"
echo ""

# -------------------------------------------------------------------
# Build lookup maps from manifests
# -------------------------------------------------------------------

# Map of target paths in the CURRENT framework manifest (what should be there)
CURRENT_TARGETS=$(jq -r '.files | to_entries[] | .value.target' "$FRAMEWORK_MANIFEST" 2>/dev/null || echo "")

# Map of target paths tracked as framework-installed (origin tracking)
ORIGIN_TARGETS=""
HAS_ORIGIN_TRACKING=false
if [ -f "$ORIGIN_FILE" ]; then
  ORIGIN_TARGETS=$(jq -r '.files | keys[]' "$ORIGIN_FILE" 2>/dev/null || echo "")
  HAS_ORIGIN_TRACKING=true
fi

# Map of target paths from the INSTALLED manifest (last synced state)
INSTALLED_TARGETS=""
if [ -f "$INSTALLED_MANIFEST" ]; then
  INSTALLED_TARGETS=$(jq -r '.files | to_entries[] | .value.target' "$INSTALLED_MANIFEST" 2>/dev/null || echo "")
fi

# Helper: check if value is in a newline-separated list
in_list() {
  local needle="$1"
  local haystack="$2"
  echo "$haystack" | grep -qxF "$needle"
}

# -------------------------------------------------------------------
# Scan target directories for skills/agents
# -------------------------------------------------------------------

DEPRECATED_COUNT=0
LOCAL_COUNT=0
CURRENT_COUNT=0
DEPRECATED_FILES=()
LOCAL_FILES=()

scan_category() {
  local cat_dir="$TARGET_DIR/$1"
  local cat_name="$1"

  [ -d "$cat_dir" ] || return 0

  while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Get relative target path (e.g., "commands/repo:framework-update.md")
    rel_path="${file#$TARGET_DIR/}"

    # Determine origin of this file
    is_in_current=false
    is_framework_origin=false

    in_list "$rel_path" "$CURRENT_TARGETS" && is_in_current=true

    if [ "$HAS_ORIGIN_TRACKING" = true ]; then
      in_list "$rel_path" "$ORIGIN_TARGETS" && is_framework_origin=true
    else
      # Fallback: if in installed manifest targets, treat as framework-origin
      in_list "$rel_path" "$INSTALLED_TARGETS" && is_framework_origin=true
    fi

    if [ "$is_in_current" = true ]; then
      # File is still in the current framework → current/active
      CURRENT_COUNT=$((CURRENT_COUNT + 1))
      if [ "$VERBOSE" = true ]; then
        echo -e "  ${GREEN}CURRENT${NC}:    $rel_path"
      fi
    elif [ "$is_framework_origin" = true ]; then
      # Was installed from framework but no longer in it → DEPRECATED
      DEPRECATED_COUNT=$((DEPRECATED_COUNT + 1))
      DEPRECATED_FILES+=("$rel_path")
      echo -e "  ${RED}DEPRECATED${NC}: $rel_path"
    else
      # Not from framework → LOCAL (user-created, never touch)
      LOCAL_COUNT=$((LOCAL_COUNT + 1))
      LOCAL_FILES+=("$rel_path")
      echo -e "  ${CYAN}LOCAL${NC}:      $rel_path (preserved — not a framework file)"
    fi
  done < <(find "$cat_dir" -maxdepth 1 -name "*.md" -type f | sort)
}

echo -e "${BLUE}Scanning installed skills/agents...${NC}"
echo ""

if [ -z "$CATEGORY_FILTER" ] || [ "$CATEGORY_FILTER" = "commands" ]; then
  echo -e "${BLUE}Commands/Skills:${NC}"
  scan_category "commands"
  echo ""
fi

if [ -z "$CATEGORY_FILTER" ] || [ "$CATEGORY_FILTER" = "agents" ]; then
  echo -e "${BLUE}Agents:${NC}"
  scan_category "agents"
  echo ""
fi

# -------------------------------------------------------------------
# Summary
# -------------------------------------------------------------------

echo -e "${BLUE}Summary:${NC}"
echo -e "  ${GREEN}Current${NC}:    $CURRENT_COUNT (still in framework)"
echo -e "  ${RED}Deprecated${NC}: $DEPRECATED_COUNT (removed from framework)"
echo -e "  ${CYAN}Local${NC}:      $LOCAL_COUNT (user-created — never removed)"

if [ "$DEPRECATED_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${YELLOW}Deprecated artifacts detected.${NC}"
  echo "  Run a framework update to automatically remove them:"
  echo "    /repo:framework-update"
  echo ""
  echo "  Or remove manually:"
  for f in "${DEPRECATED_FILES[@]}"; do
    echo "    rm \"$TARGET_DIR/$f\""
  done
fi

if [ "$LOCAL_COUNT" -gt 0 ]; then
  echo ""
  echo -e "${GREEN}Locally-created files will be preserved during any framework update:${NC}"
  for f in "${LOCAL_FILES[@]}"; do
    echo "    $TARGET_DIR/$f"
  done
fi

exit 0
