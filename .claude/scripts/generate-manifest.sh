#!/usr/bin/env bash
#
# Generate .claude/.manifest.json
# Tracks all framework files (agents, commands, skills, hooks, scripts, configs)
# for total sync operations (add/update/remove).
#
# Usage:
#   ./scripts/generate-manifest.sh              # Generate manifest
#   ./scripts/generate-manifest.sh --check      # Dry run, show what would be generated
#   ./scripts/generate-manifest.sh --output FILE # Write to custom path
#
# Source directories scanned:
#   core/agents/     -> .claude/agents/     (agent definitions)
#   core/commands/   -> .claude/commands/   (skill/command definitions)
#   core/skills/     -> .claude/skills/     (skill directories with SKILL.md)
#   .claude/hooks/   -> .claude/hooks/      (project hooks)
#   scripts/         -> scripts/            (utility scripts)
#   config/          -> config/             (configuration files)
#   schemas/         -> schemas/            (JSON schemas)
#   manifests/       -> manifests/          (agent manifests)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults
MANIFEST_FILE="$REPO_DIR/.claude/.manifest.json"
CHECK_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--dry-run)
      CHECK_MODE=true
      shift
      ;;
    --output)
      MANIFEST_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [--check] [--output FILE]"
      echo ""
      echo "Options:"
      echo "  --check       Dry run, show what would be generated"
      echo "  --output FILE Write manifest to custom path"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Get current git info
GIT_COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_TAG=$(git -C "$REPO_DIR" describe --tags --abbrev=0 2>/dev/null || echo "dev")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MANIFEST_VERSION="2.0.0"

echo -e "${BLUE}Generating framework manifest...${NC}"

# Calculate SHA256 hash (macOS + Linux compatible)
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

# Build file entries using jq for proper JSON
# Collect all files into a temporary jsonl format
TMP_FILES=$(mktemp)
trap "rm -f $TMP_FILES" EXIT

FILE_COUNT=0

# Function to scan a directory and add entries
scan_directory() {
  local src_dir="$1"
  local category="$2"
  local target_prefix="$3"
  local extensions="${4:-*}"

  if [ ! -d "$src_dir" ]; then
    return
  fi

  while IFS= read -r -d '' file; do
    local rel_path="${file#$REPO_DIR/}"
    local suffix="${file#$src_dir}"
    suffix="${suffix#/}"
    local target_path="${target_prefix}${suffix}"
    local hash=$(calculate_hash "$file")
    local size=$(wc -c < "$file" | tr -d ' ')

    echo "{\"path\":\"$rel_path\",\"target\":\"$target_path\",\"category\":\"$category\",\"hash\":\"$hash\",\"size\":$size}" >> "$TMP_FILES"
    ((FILE_COUNT++))
  done < <(find "$src_dir" -type f -not -name '.DS_Store' -not -name '*.pyc' -not -path '*/__pycache__/*' -not -path '*/.git/*' -print0 | sort -z)
}

# Scan agents with flat target paths (subdirectory agents deploy flat to agents/)
echo "  Scanning core/agents/..."
if [ -d "$REPO_DIR/core/agents" ]; then
  while IFS= read -r -d '' file; do
    rel_path="${file#$REPO_DIR/}"
    agent_basename=$(basename "$file")
    agent_target="agents/${agent_basename}"
    agent_hash=$(calculate_hash "$file")
    agent_size=$(wc -c < "$file" | tr -d ' ')

    echo "{\"path\":\"$rel_path\",\"target\":\"$agent_target\",\"category\":\"agents\",\"hash\":\"$agent_hash\",\"size\":$agent_size}" >> "$TMP_FILES"
    ((FILE_COUNT++))
  done < <(find "$REPO_DIR/core/agents" -type f -name "*.md" -not -name '.DS_Store' -print0 | sort -z)
fi

echo "  Scanning core/commands/..."
scan_directory "$REPO_DIR/core/commands" "commands" "commands/"

echo "  Scanning core/skills/..."
scan_directory "$REPO_DIR/core/skills" "skills" "skills/"

echo "  Scanning .claude/hooks/..."
scan_directory "$REPO_DIR/.claude/hooks" "hooks" "hooks/"

echo "  Scanning scripts/..."
scan_directory "$REPO_DIR/scripts" "scripts" "scripts/"

echo "  Scanning config/..."
scan_directory "$REPO_DIR/config" "config" "config/"

echo "  Scanning schemas/..."
scan_directory "$REPO_DIR/schemas" "schemas" "schemas/"

echo "  Scanning manifests/..."
scan_directory "$REPO_DIR/manifests" "manifests" "manifests/"

# Generate summary by category
echo ""
echo -e "${BLUE}Summary:${NC}"
for cat in agents commands skills hooks scripts configs schemas manifests; do
  count=$(grep -c "\"category\":\"$cat\"" "$TMP_FILES" 2>/dev/null || echo "0")
  if [ "$count" -gt 0 ]; then
    echo -e "  ${GREEN}$cat${NC}: $count files"
  fi
done
echo -e "  ${GREEN}Total${NC}: $FILE_COUNT files"

if [ "$CHECK_MODE" = true ]; then
  echo ""
  echo -e "${YELLOW}Dry run mode - no manifest written${NC}"
  exit 0
fi

# Build the final manifest JSON using jq
MANIFEST_JSON=$(jq -n \
  --arg version "$MANIFEST_VERSION" \
  --arg framework_version "$GIT_TAG" \
  --arg generated_at "$TIMESTAMP" \
  --arg git_commit "$GIT_COMMIT" \
  --argjson file_count "$FILE_COUNT" \
  --slurpfile files <(jq -s '
    reduce .[] as $f ({}; . + {($f.path): {
      target: $f.target,
      category: $f.category,
      hash: $f.hash,
      size: $f.size
    }})
  ' "$TMP_FILES") \
  '{
    "$schema": "https://github.com/jifflee/claude-agents/schemas/framework-manifest.schema.json",
    manifest_version: $version,
    framework_version: $framework_version,
    generated_at: $generated_at,
    git_commit: $git_commit,
    file_count: $file_count,
    files: $files[0]
  }')

# Ensure output directory exists
mkdir -p "$(dirname "$MANIFEST_FILE")"

# Write manifest
echo "$MANIFEST_JSON" > "$MANIFEST_FILE"

echo ""
echo -e "${GREEN}Manifest generated:${NC} $MANIFEST_FILE"
echo "  Framework version: $GIT_TAG"
echo "  Files tracked: $FILE_COUNT"
echo "  Git commit: ${GIT_COMMIT:0:8}"

# Validate JSON
if jq empty "$MANIFEST_FILE" 2>/dev/null; then
  echo -e "${GREEN}JSON valid${NC}"
else
  echo -e "${RED}JSON invalid!${NC}" >&2
  exit 1
fi

exit 0
