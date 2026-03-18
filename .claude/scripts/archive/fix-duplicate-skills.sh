#!/usr/bin/env bash
#
# Fix duplicate skills with user/project tags (Issue #1134)
#
# This script removes global skills from project-level .claude/commands/
# to prevent duplicates when they're also synced to ~/.claude/commands/
#
# Global skills (with global: true frontmatter) should ONLY exist in:
#   ~/.claude/commands/  (user-level)
#
# Project-specific skills should ONLY exist in:
#   .claude/commands/    (project-level)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Fixing duplicate skills (Issue #1134)${NC}"
echo ""

# List of global skills that should be removed from project-level
GLOBAL_SKILLS=(
  "tool:skill-help"
  "tool:skill-sync"
  "tool:example"
  "local:init"
  "local:health"
  "local:create-skill"
  "local:create-agent"
  "validate:framework"
)

PROJECT_COMMANDS_DIR="$REPO_DIR/.claude/commands"

if [ ! -d "$PROJECT_COMMANDS_DIR" ]; then
  echo -e "${GREEN}No .claude/commands/ directory found - nothing to fix${NC}"
  exit 0
fi

REMOVED_COUNT=0
BACKUP_DIR="$REPO_DIR/.claude/.sync-backup/$(date +%Y%m%d)-dedupe"

for skill in "${GLOBAL_SKILLS[@]}"; do
  skill_file="$PROJECT_COMMANDS_DIR/$skill.md"

  if [ -f "$skill_file" ]; then
    # Backup before removing
    mkdir -p "$BACKUP_DIR/commands"
    mv "$skill_file" "$BACKUP_DIR/commands/"
    echo -e "  ${YELLOW}REMOVED${NC}: $skill (backed up to .sync-backup/)"
    REMOVED_COUNT=$((REMOVED_COUNT + 1))
  fi
done

echo ""
if [ "$REMOVED_COUNT" -eq 0 ]; then
  echo -e "${GREEN}✓ No duplicate global skills found - already clean!${NC}"
else
  echo -e "${GREEN}✓ Removed $REMOVED_COUNT global skills from project-level${NC}"
  echo -e "  Backups saved to: ${BACKUP_DIR}"
  echo ""
  echo -e "These skills are now only available from ~/.claude/commands/"
  echo -e "Run ${BLUE}/tool:skill-sync${NC} to ensure they're in your user directory"
fi

exit 0
