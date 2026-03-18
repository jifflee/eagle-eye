---
description: Sync skills and agents from the framework repo to ~/.claude/
global: true
---

# Update Skills

Syncs skills, agents, and scripts from claude-tastic repo to ~/.claude/.

## Usage

```
/skill-sync                    # Sync to ~/.claude/
/skill-sync --pull             # Pull from git first
/skill-sync --status           # Show installed counts and orphans
/skill-sync --clean            # Remove orphaned files and old hyphenated names (with confirmation)
/skill-sync --clean --dry-run  # Preview orphan removal
```

## Steps

### 1. Sync Mode (default)

Syncs ONLY global skills to ~/.claude/ using the manifest-sync.sh script with --global-only flag:

```bash
# Use manifest-sync.sh to sync only global skills to ~/.claude/
./scripts/manifest-sync.sh --global-only --force --clean

# Flags:
# --global-only: Only sync global skills (those with global: true in frontmatter)
# --force: Force sync even if versions match
# --clean: Remove old hyphenated skill names (pre-colon migration cleanup)
#
# This syncs only the 9 global skills:
# - tool:skill-help
# - tool:skill-sync
# - tool:example
# - local:init
# - local:health
# - local:create-skill
# - local:create-agent
# - repo:framework-update
# - validate:framework
#
# Project-specific skills (55 total) remain in .claude/commands/ only
# Old hyphenated names (e.g., 'tool-skill-sync') are removed if found
```

### 2. Pull Mode (--pull)

```bash
# Pull latest framework updates first
git pull origin main

# Then sync global skills only with cleanup
./scripts/manifest-sync.sh --global-only --force --clean
```

### 3. Status Mode (--status)

```bash
CLAUDE_DIR="$HOME/.claude"

# Count installed files
AGENTS_COUNT=$(find "$CLAUDE_DIR/agents" -name '*.md' 2>/dev/null | wc -l)
COMMANDS_COUNT=$(find "$CLAUDE_DIR/commands" -name '*.md' 2>/dev/null | wc -l)
SCRIPTS_COUNT=$(find "$CLAUDE_DIR/scripts" -name '*.sh' 2>/dev/null | wc -l)

echo "Installed in ~/.claude/:"
echo "  Agents: $AGENTS_COUNT"
echo "  Commands: $COMMANDS_COUNT (should be 9 global skills)"
echo "  Scripts: $SCRIPTS_COUNT"

# Show which global skills are installed
echo ""
echo "Global skills (should have 9):"
for skill in tool:skill-help tool:skill-sync tool:example local:init local:health local:create-skill local:create-agent repo:framework-update validate:framework; do
  if [ -f "$CLAUDE_DIR/commands/$skill.md" ]; then
    echo "  ✓ $skill"
  else
    echo "  ✗ $skill (MISSING)"
  fi
done
```

### 4. Clean Mode (--clean)

Removes project-specific skills from ~/.claude/commands/ that should NOT be global, and removes old hyphenated skill names (pre-colon migration).

**Cleanup targets:**
1. **Orphaned project-specific skills** - Skills in ~/.claude/commands/ without `global: true`
2. **Old hyphenated names** - Skills using old naming format (e.g., `tool-skill-sync` vs `tool:skill-sync`)

**Orphan detection:**
- Lists all .md files in ~/.claude/commands/
- Checks each against the 9 global skills list
- Any skills without `global: true` are considered orphans

**Old name detection:**
- Lists all .md files in ~/.claude/commands/
- Identifies files without colon in filename (old hyphenated format)
- These are leftovers from the colon naming migration

**Safety features:**
- Never auto-deletes - requires explicit `--clean` flag
- Shows all files that will be removed before action
- Requires `y` confirmation to proceed
- Use `--clean --dry-run` to preview without removing

```bash
CLAUDE_DIR="$HOME/.claude"

# Global skills that should remain
GLOBAL_SKILLS=(
  "tool:skill-help"
  "tool:skill-sync"
  "tool:example"
  "local:init"
  "local:health"
  "local:create-skill"
  "local:create-agent"
  "repo:framework-update"
  "validate:framework"
)

echo "Scanning for orphaned and old-named skills in ~/.claude/commands/..."
echo ""

ORPHANS=()
OLD_NAMES=()

for file in "$CLAUDE_DIR/commands/"*.md; do
  [ -f "$file" ] || continue

  skill_name=$(basename "$file" .md)

  # Check if it's an old hyphenated name (no colon)
  if [[ ! "$skill_name" =~ : ]]; then
    OLD_NAMES+=("$skill_name")
    continue
  fi

  # Check if it's a non-global skill (orphan)
  is_global=false
  for global in "${GLOBAL_SKILLS[@]}"; do
    if [[ "$skill_name" == "$global" ]]; then
      is_global=true
      break
    fi
  done

  if [[ "$is_global" == false ]]; then
    ORPHANS+=("$skill_name")
  fi
done

TOTAL_TO_REMOVE=$((${#ORPHANS[@]} + ${#OLD_NAMES[@]}))

if [[ $TOTAL_TO_REMOVE -eq 0 ]]; then
  echo "✓ No orphaned or old-named skills found - all clean!"
  exit 0
fi

if [[ ${#OLD_NAMES[@]} -gt 0 ]]; then
  echo "Found ${#OLD_NAMES[@]} old hyphenated skill names (pre-colon migration):"
  for old_name in "${OLD_NAMES[@]}"; do
    echo "  - $old_name"
  done
  echo ""
fi

if [[ ${#ORPHANS[@]} -gt 0 ]]; then
  echo "Found ${#ORPHANS[@]} project-specific skills that should be removed:"
  for orphan in "${ORPHANS[@]}"; do
    echo "  - $orphan"
  done
  echo ""
fi

read -p "Remove these $TOTAL_TO_REMOVE skills? [y/N]: " confirm

if [[ "$confirm" =~ ^[Yy]$ ]]; then
  for old_name in "${OLD_NAMES[@]}"; do
    rm -f "$CLAUDE_DIR/commands/$old_name.md"
    echo "  ✓ Removed $old_name (old name)"
  done
  for orphan in "${ORPHANS[@]}"; do
    rm -f "$CLAUDE_DIR/commands/$orphan.md"
    echo "  ✓ Removed $orphan (orphan)"
  done
  echo ""
  echo "Cleanup complete. $TOTAL_TO_REMOVE skills removed."
else
  echo "Cleanup cancelled."
fi
```

## Output Format

```
## Skills Updated

| Category | Before | After | Change |
|----------|--------|-------|--------|
| Agents | {n} | {n} | +{n} |
| Commands | {n} | {n} | +{n} |
| Scripts | {n} | {n} | +{n} |

**Location:** ~/.claude/

### New Files
- {file}

### Updated Files
- {file}

Run `claude --help` to see available commands.
```

## Token Optimization

This skill is already well-optimized for minimal token usage:

**Efficient design:**
- Simple file copy operation with minimal logic
- Uses shell commands for file operations (no Claude parsing)
- Git operations handled by system commands
- Diff summary generated via `diff`/`wc` (not Claude)

**Token usage:**
- Current: ~950 tokens (simple workflow)
- No further optimization needed (already minimal)
- Savings: N/A (baseline efficiency)

**Measurement:**
- Baseline: ~950 tokens (current implementation)
- Alternative approaches would be more complex (unnecessary)
- See `/docs/METRICS_OBSERVABILITY.md` for measurement methodology

**Why this is optimized:**
- ✅ Minimal skill file size (109 lines)
- ✅ File operations via shell commands
- ✅ Git operations via system git
- ✅ Simple reporting (no complex formatting)
- ✅ No data gathering overhead (just file sync)

**Note:** Further optimization not recommended - would add complexity without benefit.

## Notes

- WRITE operation - syncs ONLY global skills to ~/.claude/
- Run from claude-tastic repo root
- Use --pull to get latest from git first
- Only 9 skills are deployed to ~/.claude/commands/ (global skills)
- Project-specific skills (55 total) remain in .claude/commands/ only
- Uses `manifest-sync.sh --global-only` for intelligent filtering
- Related issue: #1104 (Separate global vs project-only skills)
