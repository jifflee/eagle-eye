---
description: Update an already-deployed Claude Agent Framework in a consumer repo to the latest version
argument-hint: "[--check] [--version TAG] [--category NAME] [--force]"
global: true
---

# Framework Update

Updates the Claude Agent Framework files in the current consumer repository by pulling the latest changes from the framework source and running a full manifest-based sync (add/update/remove).

## Usage

```
/framework-update                    # Update to latest (interactive)
/framework-update --check            # Preview changes without applying
/framework-update --version TAG      # Update to specific version/tag
/framework-update --category agents  # Update only a specific category
/framework-update --force            # Force sync even if versions already match
```

## Steps

### Step 1: Parse Arguments

Capture any flags passed by the user:

```bash
CHECK_MODE=false
VERSION_TAG=""
CATEGORY_FILTER=""
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --check|--dry-run) CHECK_MODE=true ;;
    --force) FORCE=true ;;
    --version) shift; VERSION_TAG="$1" ;;
    --category) shift; CATEGORY_FILTER="$1" ;;
  esac
done
```

### Step 2: Locate Framework Source

```bash
FRAMEWORK_DIR="${CLAUDE_FRAMEWORK_DIR:-$HOME/Repos/claude-agents}"

if [ ! -d "$FRAMEWORK_DIR/core/agents" ]; then
  echo "ERROR: Framework source not found at $FRAMEWORK_DIR"
  echo ""
  echo "To fix this, either:"
  echo "  1. Clone the framework repo:  git clone <framework-url> $FRAMEWORK_DIR"
  echo "  2. Set the env var:           export CLAUDE_FRAMEWORK_DIR=/path/to/claude-agents"
  exit 1
fi
```

### Step 3: Fetch Latest Framework

```bash
cd "$FRAMEWORK_DIR"

if [ -n "$VERSION_TAG" ]; then
  # Pin to a specific version/tag
  echo "Fetching version $VERSION_TAG..."
  git fetch origin --tags
  git checkout "$VERSION_TAG"
  CURRENT_FRAMEWORK_VERSION="$VERSION_TAG"
else
  # Pull latest from main
  echo "Pulling latest framework from origin/main..."
  git fetch origin
  git pull origin main
  CURRENT_FRAMEWORK_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short HEAD)
fi

echo "Framework source: $FRAMEWORK_DIR"
echo "Framework version: $CURRENT_FRAMEWORK_VERSION"
```

### Step 4: Regenerate Manifest

Always regenerate the manifest from the freshly pulled source before syncing:

```bash
"$FRAMEWORK_DIR/scripts/generate-manifest.sh"
```

This ensures the manifest reflects the exact files currently in the framework repo.

### Step 4b: Detect Deprecated Artifacts

Before previewing or applying changes, scan for skills/agents that were previously installed from the framework but have since been removed or renamed upstream. Also identify locally-created files so they are protected from deletion:

```bash
TARGET_DIR="$(pwd)/.claude"

"$FRAMEWORK_DIR/scripts/detect-deprecated-artifacts.sh" \
  --target "$TARGET_DIR" \
  --framework-manifest "$FRAMEWORK_DIR/.claude/.manifest.json"
```

This reports:
- **DEPRECATED**: files that were installed from the framework but no longer exist upstream
- **LOCAL**: user-created files not originating from the framework (will be preserved)
- **CURRENT**: files still present in the upstream framework

Origin tracking is maintained in `.claude/.framework-origin.json` by `manifest-sync.sh`. This is the source of truth for distinguishing framework-installed files from locally-created ones.

### Step 5: Preview Changes (always show before applying)

Run manifest-sync in check/dry-run mode to show what would change:

```bash
TARGET_DIR="$(pwd)/.claude"

# Build optional flags
SYNC_ARGS="--target $TARGET_DIR --check"
[ -n "$CATEGORY_FILTER" ] && SYNC_ARGS="$SYNC_ARGS --category $CATEGORY_FILTER"

"$FRAMEWORK_DIR/scripts/manifest-sync.sh" $SYNC_ARGS
```

This shows a diff summary like:

```
Framework Update Preview (v1.0.0 → v1.1.0):
  Added:   3 files (2 agents, 1 command)
  Updated: 5 files (3 commands, 2 hooks)
  Removed: 1 file (1 deprecated alias)

  New:     agents/new-agent.md, commands/new-skill.md, ...
  Changed: commands/sprint-work.md, hooks/block-secrets.py, ...
  Removed: commands/old-alias.md
```

If `--check` was specified, **stop here** and report results. No changes are made.

### Step 6: Confirm and Apply

If not in `--check` mode and there are changes to apply, ask for confirmation:

Use AskUserQuestion to confirm:

**Header:** "Apply Update"

**Options:**
- Apply the framework update (Recommended)
- Cancel - keep current version

If confirmed, apply the sync:

```bash
# Build optional flags
SYNC_ARGS="--target $TARGET_DIR"
[ "$FORCE" = true ] && SYNC_ARGS="$SYNC_ARGS --force"
[ -n "$CATEGORY_FILTER" ] && SYNC_ARGS="$SYNC_ARGS --category $CATEGORY_FILTER"

"$FRAMEWORK_DIR/scripts/manifest-sync.sh" $SYNC_ARGS
```

### Step 7: Validate settings.json and Script Paths

After applying the manifest sync, validate both `.claude/settings.json` hooks and deployed script paths.

**7a. Validate settings.json:**

```bash
# Verify settings.json was created/updated
if [ ! -f ".claude/settings.json" ]; then
  echo "WARNING: .claude/settings.json was not created — hooks will not function"
  echo "Run: /repo:init-framework to initialize settings.json"
else
  # Check all three required hook types are present
  MISSING_HOOKS=""
  jq -e '.hooks.UserPromptSubmit' .claude/settings.json > /dev/null 2>&1 || MISSING_HOOKS="$MISSING_HOOKS UserPromptSubmit"
  jq -e '.hooks.PreToolUse' .claude/settings.json > /dev/null 2>&1 || MISSING_HOOKS="$MISSING_HOOKS PreToolUse"
  jq -e '.hooks.PostToolUse' .claude/settings.json > /dev/null 2>&1 || MISSING_HOOKS="$MISSING_HOOKS PostToolUse"
  MISSING_HOOKS="${MISSING_HOOKS# }"

  if [ -n "$MISSING_HOOKS" ]; then
    echo "WARNING: .claude/settings.json is missing hook sections: $MISSING_HOOKS"
    echo "These are required for dynamic-loader, compliance-capture, and block-secrets to work"
  else
    echo "✓ .claude/settings.json has all required hook entries (UserPromptSubmit, PreToolUse, PostToolUse)"
  fi
fi
```

**7b. Validate deployed script paths (Issue #1275 — path mismatch check):**

Manifest-sync deploys container scripts to `.claude/scripts/` in consumer repos. Validate they are present at the expected location and warn if stale copies exist at the repo-root `./scripts/` that might cause path confusion:

```bash
# Key container scripts that skills depend on
REQUIRED_SCRIPTS=(
  "container-launch.sh"
  "sprint-work-preflight.sh"
  "container-status.sh"
  "detect-infrastructure.sh"
)

echo ""
echo "### Script Path Validation"
SCRIPT_ERRORS=0
for script in "${REQUIRED_SCRIPTS[@]}"; do
  CLAUDE_PATH=".claude/scripts/$script"
  ROOT_PATH="./scripts/$script"

  if [ -f "$CLAUDE_PATH" ]; then
    echo "  ✓ $CLAUDE_PATH"
    # Warn if an old copy also exists at repo root (potential confusion)
    if [ -f "$ROOT_PATH" ]; then
      echo "  ⚠️  Also found at $ROOT_PATH — skills use .claude/scripts/ in consumer repos; root copy may be stale"
    fi
  elif [ -f "$ROOT_PATH" ]; then
    # Framework source repo: scripts live at ./scripts/ (not .claude/scripts/)
    echo "  ✓ $ROOT_PATH (framework source repo)"
  else
    echo "  ✗ MISSING: $CLAUDE_PATH (not found at .claude/scripts/ or ./scripts/)"
    SCRIPT_ERRORS=$((SCRIPT_ERRORS + 1))
  fi
done

if [ "$SCRIPT_ERRORS" -gt 0 ]; then
  echo ""
  echo "  ⚠️  $SCRIPT_ERRORS script(s) missing — sprint:work-auto and sprint:dispatch may fail"
  echo "  Run /repo:framework-update --force to re-sync, or check .claude/.manifest.json for scripts category"
else
  echo "  ✓ All required scripts present at correct paths"
fi
```

### Step 8: Sync Global Skills to ~/.claude/

After updating the repo's `.claude/`, also refresh the global skills in `~/.claude/` so slash commands are available immediately without a separate `/tool:skill-sync` step.

```bash
echo ""
echo "### Syncing global skills to ~/.claude/"

# Sync only global skills (those with global: true in frontmatter)
"$FRAMEWORK_DIR/scripts/manifest-sync.sh" --global-only --force --clean --target "$HOME/.claude/"

echo "✓ Global skills refreshed in ~/.claude/"
```

This ensures global skills like `/repo:init-framework`, `/repo:framework-update`, `/local:init`, etc. are immediately available in all repos after the update.

### Step 9: Show Commit Guidance

After a successful update, display commit instructions:

```
✅ Framework updated to v1.1.0

Global skills refreshed in ~/.claude/ (available in all repos)

Next step - commit the changes to your repo:

  git add .claude/
  git commit -m "chore: update claude-agents framework to v1.1.0"
  git push
```

## Output Format

### Check Mode (`--check`)

```
## Framework Update Preview

**Consumer repo:** {current directory}
**Framework source:** {FRAMEWORK_DIR}
**Current installed:** v1.0.0
**Available version:** v1.1.0

### Changes
| Action    | Count | Details |
|-----------|-------|---------|
| Added     | 3     | agents/new-agent.md, commands/new-skill.md, ... |
| Updated   | 5     | commands/sprint-work.md, hooks/block-secrets.py, ... |
| Removed   | 1     | commands/old-alias.md (deprecated framework artifact) |
| Protected | 2     | commands/my-project:setup.md, agents/my-custom-agent.md (locally created) |
| Unchanged | 48    | |

### Origin Tracking
- .framework-origin.json: 55 files tracked as framework-installed
- 2 files in .claude/ are NOT in origin tracking (locally created — will be preserved)

Run `/framework-update` to apply these changes.
```

### Apply Mode (default)

```
## Framework Update

**Updated to:** v1.1.0
**Previous version:** v1.0.0

### Changes Applied
- Added:      3 files
- Updated:    5 files
- Removed:    1 file (backed up to .claude/.sync-backup/)
- Deprecated: 1 file removed (deprecated framework artifact — backed up)
- Protected:  2 files (locally created — preserved, not touched)

### Deprecated Artifacts Removed
  commands/old-alias.md  → backed up to .claude/.sync-backup/20260101/

### Locally-Created Files Preserved
  commands/my-project:setup.md  (not a framework file — kept)
  agents/my-custom-agent.md     (not a framework file — kept)

### Settings Validation
- ✓ .claude/settings.json has all required hook entries (UserPromptSubmit, PreToolUse, PostToolUse)
- ✓ All required scripts present at correct paths

### Global Skills Synced (~/.claude/)
- Updated: 10 global skills refreshed in ~/.claude/commands/
- Available immediately in all repos

### Next Steps
Commit the changes:
  git add .claude/
  git commit -m "chore: update claude-agents framework to v1.1.0"
  git push
```

### Already Up To Date

```
## Framework Update

✅ Already up to date (v1.1.0)

Use `--force` to re-sync even if versions match.
```

### Missing Framework Source

```
## Framework Update - Error

❌ Framework source not found at ~/Repos/claude-agents

To resolve:
1. Clone the framework repo:
   git clone <url> ~/Repos/claude-agents

2. Or set CLAUDE_FRAMEWORK_DIR:
   export CLAUDE_FRAMEWORK_DIR=/path/to/claude-agents

3. Then re-run: /framework-update
```

## Error Handling

| Condition | Action |
|-----------|--------|
| Framework repo not found | Show error + clone instructions, exit |
| No network access for git pull | Show warning, offer to sync from local cache |
| Consumer `.claude/` not found | Recommend `/repo-init` for initial setup |
| Version/tag not found | Show available tags, exit |
| manifest-sync.sh not found | Show error + point to framework repo |
| No changes (up to date) | Confirm and exit without prompting |
| Global skill-sync fails | Show warning, report which skills failed, continue |
| ~/.claude/ not writable | Show warning with fix instructions, skip global sync |

## Notes

- WRITE operation - modifies `.claude/` files in the current repo
- Safe to run multiple times (idempotent)
- Removed files are backed up to `.claude/.sync-backup/YYYYMMDD/` before deletion
- Use `--check` for safe preview before applying
- Set `CLAUDE_FRAMEWORK_DIR` env var to avoid prompts about framework location
- For initial setup (no `.claude/` exists yet), use `/repo-init` instead
- Category values: `agents`, `commands`, `hooks`, `scripts`, `configs`, `schemas`
- **Origin tracking**: `.claude/.framework-origin.json` records which files were installed from the framework. Files not in this record are treated as locally-created and are never deleted during updates. This file is written/updated by `manifest-sync.sh` on each successful sync.
- **Deprecated artifact detection**: `scripts/detect-deprecated-artifacts.sh` can be run standalone to audit installed files against the current framework manifest without making changes.

## Related Skills

- `/repo:init-framework` - Initial framework deployment (first time setup)
- `/tool:skill-sync` - Manual global sync to `~/.claude/` (auto-invoked by this skill in Step 8)
- `/local:review` - Review and migrate existing CLAUDE.md after update
