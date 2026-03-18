---
description: Initialize a repository for use with the Claude Agent Framework (claude-tastic consumer repo variant)
argument-hint: "[--check] [--skip-framework] [--clone]"
global: true
---

# Init Repo (claude-tastic)

Initialize a consumer repository with the Claude Agent Framework. This variant automatically detects the framework source installed by `load-claude-tastic.sh` at `.claude-sync/`, with fallback to `~/Repos/claude-agents` and an option to clone automatically.

## Usage

```
/repo-init-claudetastic                    # Interactive setup with auto-detection
/repo-init-claudetastic --check            # Check status only (no changes)
/repo-init-claudetastic --skip-framework   # Skip framework file deployment
/repo-init-claudetastic --clone            # Clone framework from GitHub if not found
```

## How Framework Source Detection Works

This skill uses a multi-location fallback chain to locate the framework:

| Priority | Location | Set By |
|----------|----------|--------|
| 1 | `$CLAUDE_FRAMEWORK_DIR` env var | User-configured |
| 2 | `.claude-sync/` (in current repo) | `load-claude-tastic.sh` |
| 3 | `~/Repos/claude-agents/` | Developer manual clone |
| 4 | Clone from GitHub (with confirmation) | Auto-install fallback |

## Steps

### 1. Pre-flight Checks

Verify prerequisites before proceeding:

```bash
# Check jq (required for manifest and config processing)
if ! command -v jq &> /dev/null; then
  echo "ERROR: jq not found. Install jq before running /repo-init-claudetastic"
  echo "  macOS: brew install jq"
  echo "  Linux: sudo apt install jq"
  echo "  More:  https://stedolan.github.io/jq/download/"
  exit 1
fi

# Check gh CLI
if ! command -v gh &> /dev/null; then
  echo "ERROR: gh CLI not found. Install from: https://cli.github.com/"
  exit 1
fi

# Check authentication
if ! gh auth status &> /dev/null; then
  echo "ERROR: gh CLI not authenticated. Run: gh auth login"
  exit 1
fi

# Check git repo
if ! git rev-parse --git-dir &> /dev/null; then
  echo "ERROR: Not in a git repository"
  exit 1
fi

# Check remote
if ! git remote get-url origin &> /dev/null; then
  echo "ERROR: No git remote 'origin'. Push to GitHub first."
  exit 1
fi
```

### 2. Detect Framework Source

Auto-detect where the Claude Agent Framework is installed using the multi-location fallback chain:

```bash
# Multi-location framework source detection
# Bridges load-claude-tastic.sh (.claude-sync/) and /repo-init (~/Repos/claude-agents)
_find_framework_source() {
  # Option 1: Explicit env var override
  if [ -n "${CLAUDE_FRAMEWORK_DIR:-}" ] && [ -d "$CLAUDE_FRAMEWORK_DIR/core/agents" ]; then
    echo "$CLAUDE_FRAMEWORK_DIR"
    return 0
  fi

  # Option 2: .claude-sync/ - installed by load-claude-tastic.sh
  if [ -d ".claude-sync/core/agents" ]; then
    echo "$(pwd)/.claude-sync"
    return 0
  fi

  # Option 3: ~/Repos/claude-agents - developer manual checkout
  if [ -d "$HOME/Repos/claude-agents/core/agents" ]; then
    echo "$HOME/Repos/claude-agents"
    return 0
  fi

  return 1
}

FRAMEWORK_DIR=""
FRAMEWORK_SOURCE_METHOD=""

if FRAMEWORK_DIR=$(_find_framework_source 2>/dev/null); then
  # Determine which method found the source
  if [ "${CLAUDE_FRAMEWORK_DIR:-}" ] && [[ "$FRAMEWORK_DIR" == "$CLAUDE_FRAMEWORK_DIR" ]]; then
    FRAMEWORK_SOURCE_METHOD="env var \$CLAUDE_FRAMEWORK_DIR"
  elif [[ "$FRAMEWORK_DIR" == "$(pwd)/.claude-sync" ]]; then
    FRAMEWORK_SOURCE_METHOD=".claude-sync/ (load-claude-tastic.sh)"
  else
    FRAMEWORK_SOURCE_METHOD="~/Repos/claude-agents"
  fi
  echo "Framework source detected: $FRAMEWORK_DIR"
  echo "  Method: $FRAMEWORK_SOURCE_METHOD"
else
  echo ""
  echo "WARNING: Framework source not found. Searched:"
  echo "  1. \$CLAUDE_FRAMEWORK_DIR (${CLAUDE_FRAMEWORK_DIR:-not set})"
  echo "  2. $(pwd)/.claude-sync/"
  echo "  3. $HOME/Repos/claude-agents/"
  echo ""
  echo "Resolution options:"
  echo "  A) Run:  ./load-claude-tastic.sh          (installs to .claude-sync/)"
  echo "  B) Set:  export CLAUDE_FRAMEWORK_DIR=/path/to/framework"
  echo "  C) Clone: git clone https://github.com/jifflee/claude-tastic ~/Repos/claude-agents"
  echo ""

  # Auto-clone if --clone flag passed or user confirms
  if [[ "${1:-}" == "--clone" ]] || [[ "${AUTO_CLONE:-false}" == "true" ]]; then
    DO_CLONE=true
  else
    read -p "Clone framework from GitHub automatically? [y/N]: " do_clone_input
    DO_CLONE=false
    [[ "$do_clone_input" =~ ^[Yy]$ ]] && DO_CLONE=true
  fi

  if $DO_CLONE; then
    echo "Cloning framework to ~/Repos/claude-agents..."
    CLONE_TARGET="$HOME/Repos/claude-agents"
    mkdir -p "$(dirname "$CLONE_TARGET")"
    if git clone https://github.com/jifflee/claude-tastic "$CLONE_TARGET"; then
      FRAMEWORK_DIR="$CLONE_TARGET"
      FRAMEWORK_SOURCE_METHOD="~/Repos/claude-agents (just cloned)"
      echo "Cloned successfully: $FRAMEWORK_DIR"
    else
      echo "ERROR: Clone failed."
      echo "  Check network connectivity or clone manually."
      exit 1
    fi
  else
    echo "Cannot proceed without framework source."
    echo "Run ./load-claude-tastic.sh first, then re-run /repo-init-claudetastic"
    exit 1
  fi
fi
```

### 3. Determine Repository Visibility and Naming

**Prompt user for repository visibility** using AskUserQuestion:

**Question:** "Will this repository be shared publicly?"

**Header:** "Repo Visibility"

**Options:**
- Private (internal development - full SDLC pipeline) (Recommended)
- Public (external release - production deployment only)

**Based on the user's selection:**

**If Private (internal):**
- Set visibility type: `private`
- Deployment architecture: Full dev/qa/main pipeline
- Naming convention: `source-{repo-name}`
- Environment tiers: development, validation, production
- Agent categories: All agents and tooling available

**If Public (external):**
- Set visibility type: `public`
- Deployment architecture: Main branch only (production)
- Naming convention: `external-{repo-name}`
- Environment tiers: production only
- Agent categories: Deployment and monitoring only

**Validate repository naming convention:**

```bash
# Get current repo name
REPO_NAME=$(git remote get-url origin | sed -E 's#.*/([^/]+/[^/]+)\.git$#\1#' | cut -d'/' -f2)

# Check naming matches visibility selection
if [[ "$VISIBILITY" == "private" ]]; then
  EXPECTED_PREFIX="source-"
  if [[ ! "$REPO_NAME" =~ ^source- ]]; then
    echo "WARNING: Private repos should follow naming: source-{repo-name}"
    echo "Current name: $REPO_NAME"
    echo "Expected: source-$REPO_NAME"
    echo ""
    echo "You should rename this repository to follow the convention."
    echo "Visit: https://github.com/$(git remote get-url origin | sed -E 's#.*/([^/]+/[^/]+)\.git$#\1#')/settings"
  fi
elif [[ "$VISIBILITY" == "public" ]]; then
  EXPECTED_PREFIX="external-"
  if [[ ! "$REPO_NAME" =~ ^external- ]]; then
    echo "WARNING: Public repos should follow naming: external-{repo-name}"
    echo "Current name: $REPO_NAME"
    echo "Expected: external-$REPO_NAME"
    echo ""
    echo "You should rename this repository to follow the convention."
    echo "Visit: https://github.com/$(git remote get-url origin | sed -E 's#.*/([^/]+/[^/]+)\.git$#\1#')/settings"
  fi
fi
```

**Create or update repo-profile.yaml:**

```bash
# Create config directory if it doesn't exist
mkdir -p config

# Get current user
GH_USER=$(gh api user -q '.login')

# Create repo profile with visibility settings
cat > config/repo-profile.yaml << EOF
# Repository Profile Configuration
# Auto-generated by /repo-init-claudetastic
version: "1.0.0"

visibility:
  type: "$VISIBILITY"
  auto_detected: true
  configured_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  configured_by: "$GH_USER"

naming:
  enforce_convention: true
  current_name: "$REPO_NAME"
  expected_pattern: "${EXPECTED_PREFIX}*"
  naming_valid: $(if [[ "$REPO_NAME" =~ ^${EXPECTED_PREFIX} ]]; then echo "true"; else echo "false"; fi)
  last_validated: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

deployment:
  branches:
    dev:
      enabled: $(if [[ "$VISIBILITY" == "private" ]]; then echo "true"; else echo "false"; fi)
    qa:
      enabled: $(if [[ "$VISIBILITY" == "private" ]]; then echo "true"; else echo "false"; fi)
    main:
      enabled: true

sensitivity_scanning:
  enabled: $(if [[ "$VISIBILITY" == "public" ]]; then echo "true"; else echo "false"; fi)
  blocking: true
  allowlist_file: "config/public-release-allowlist.yaml"

metadata:
  schema_version: "1.0.0"
  created_by: "/repo-init-claudetastic"
  last_updated: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

echo "Created config/repo-profile.yaml with visibility: $VISIBILITY"
```

**If public repo, create allowlist:**

```bash
if [[ "$VISIBILITY" == "public" ]]; then
  # Copy public-release-allowlist.yaml from framework if it doesn't exist
  if [[ ! -f "config/public-release-allowlist.yaml" ]]; then
    if [[ -f "$FRAMEWORK_DIR/config/public-release-allowlist.yaml" ]]; then
      cp "$FRAMEWORK_DIR/config/public-release-allowlist.yaml" config/
      echo "Created config/public-release-allowlist.yaml"
    fi
  fi
fi
```

### 4. Detect Current State

Assess the repository's current status:

```bash
# Check dev branch
if git ls-remote --heads origin dev | grep -q dev; then
  echo "Dev branch: EXISTS"
else
  echo "Dev branch: MISSING"
fi

# Check standard labels
LABEL_COUNT=$(gh label list --json name -q '[.[] | select(.name | test("^(in-progress|backlog|blocked|bug|feature|docs|tech-debt|needs-attention)$"))] | length')
echo "Labels: $LABEL_COUNT/8 present"

# Check active milestone
MILESTONE=$(gh api repos/:owner/:repo/milestones --jq '.[0].title // "MISSING"')
echo "Milestone: $MILESTONE"

# Check framework deployment
if [ -d ".claude/agents" ] && [ -f ".claude/.manifest.json" ]; then
  FRAMEWORK_VERSION=$(jq -r '.framework_version' .claude/.manifest.json 2>/dev/null || echo "unknown")
  echo "Framework: DEPLOYED (version $FRAMEWORK_VERSION)"
else
  echo "Framework: NOT DEPLOYED"
fi

# Show detected framework source
echo "Framework source: $FRAMEWORK_DIR ($FRAMEWORK_SOURCE_METHOD)"
```

Display the detection results to the user before making changes.

### 5. Confirm Actions

Use AskUserQuestion to confirm what actions to take:

**Header:** "Setup Actions"

**Options:**
- Apply all recommended changes (Recommended)
- Select specific changes
- Check status only (no changes)
- Cancel

If "Select specific changes" chosen, present checkboxes for:
- Deploy framework (agents, commands, hooks)
- Create dev branch
- Create standard labels
- Create initial milestone

### 6. Deploy Framework Files

If user approved framework deployment (and not `--skip-framework`):

```bash
# Deploy using manifest-sync from detected source
"$FRAMEWORK_DIR/scripts/manifest-sync.sh" --target .claude/ --force
```

This copies:
- `core/agents/*.md` -> `.claude/agents/`
- `core/commands/*.md` -> `.claude/commands/`
- `.claude/hooks/*` -> `.claude/hooks/`
- Generates `.claude/.manifest.json` for tracking

**Configure settings.json with hooks:**

```bash
if [ ! -f ".claude/settings.json" ]; then
  cat > .claude/settings.json << 'SETTINGS'
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
    ]
  }
}
SETTINGS
  echo "Created .claude/settings.json with standard hooks"
else
  echo ".claude/settings.json already exists (not overwriting)"
fi
```

**Ensure .gitignore includes framework-generated files:**

```bash
if ! grep -q '.claude/.manifest.json' .gitignore 2>/dev/null; then
  echo '.claude/.manifest.json' >> .gitignore
fi
```

**Generate or update CLAUDE.md:**

```bash
# Generate CLAUDE.md for new repos or merge with existing
"$FRAMEWORK_DIR/scripts/generate-claude-md.sh" --framework-dir "$FRAMEWORK_DIR" --merge
```

This will:
- **New repos**: Create CLAUDE.md from framework template
- **Existing repos**: Merge framework sections with existing content, preserving customizations
- Backup existing file before any changes
- Add framework agent definitions, SDLC workflow, and security rules

### 7. Create Dev Branch

**Only for private repos.** Public repos skip dev/qa branches.

If dev branch is missing and user approved and repo visibility is private:

```bash
git fetch origin main

if ! git ls-remote --heads origin dev | grep -q dev; then
  git checkout -b dev origin/main
  git push -u origin dev
  echo "Created dev branch from main"
else
  echo "Dev branch already exists"
fi
```

### 8. Create Standard Labels

Create the 8 standard labels (idempotent - skips existing):

```bash
labels=(
  "in-progress:FFA500:Actively being worked on"
  "backlog:D3D3D3:Planned but not started"
  "blocked:FF0000:Waiting on dependency"
  "bug:d73a4a:Something isn't working"
  "feature:00FF00:New functionality"
  "docs:0075ca:Documentation task"
  "tech-debt:FFA500:Refactoring or cleanup"
  "needs-attention:FF6600:Requires immediate attention"
)

for item in "${labels[@]}"; do
  name=$(echo "$item" | cut -d: -f1)
  color=$(echo "$item" | cut -d: -f2)
  desc=$(echo "$item" | cut -d: -f3)
  gh label create "$name" --color "$color" --description "$desc" 2>/dev/null || true
done
```

### 9. Create Initial Milestone

If no active milestone exists and user approved:

Use AskUserQuestion for milestone name:
- MVP (Recommended)
- Sprint 1
- Phase 1
- v1.0
- Custom name

Then create:

```bash
due_date=$(date -v+30d +%Y-%m-%dT00:00:00Z 2>/dev/null || date -d "+30 days" +%Y-%m-%dT00:00:00Z)

gh api repos/:owner/:repo/milestones -X POST \
  -f title="{name}" \
  -f state="open" \
  -f description="Sprint milestone" \
  -f due_on="$due_date"
```

### 10. Final Verification

```bash
# Use framework-relative path to validate-github-conventions.sh
# $FRAMEWORK_DIR is detected in Step 2 and resolves to the framework source
if [ -x "$FRAMEWORK_DIR/scripts/validate/validate-github-conventions.sh" ]; then
  "$FRAMEWORK_DIR/scripts/validate/validate-github-conventions.sh" --check 2>/dev/null || true
else
  # Inline fallback validation when script is unavailable in consumer repo context
  echo "Running inline validation (framework validation script not found at $FRAMEWORK_DIR/scripts/)..."

  VALIDATION_ERRORS=0

  # Check dev branch
  if git ls-remote --heads origin dev 2>/dev/null | grep -q dev; then
    echo "  [OK] Dev branch exists"
  else
    echo "  [WARN] Dev branch missing"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
  fi

  # Check standard labels
  LABEL_COUNT=$(gh label list --json name -q '[.[] | select(.name | test("^(in-progress|backlog|blocked|bug|feature|docs|tech-debt|needs-attention)$"))] | length' 2>/dev/null || echo 0)
  echo "  [OK] Labels: $LABEL_COUNT/8 present"

  # Check framework deployment
  if [ -d ".claude/agents" ] && [ -f ".claude/.manifest.json" ]; then
    echo "  [OK] Framework deployed"
  else
    echo "  [WARN] Framework not fully deployed"
    VALIDATION_ERRORS=$((VALIDATION_ERRORS + 1))
  fi

  if [ "$VALIDATION_ERRORS" -eq 0 ]; then
    echo "Validation passed"
  else
    echo "Validation completed with $VALIDATION_ERRORS warning(s)"
  fi
fi
```

## Output Format

```
## Repository Initialization (claude-tastic)

**Repository:** {owner}/{repo}
**Visibility:** {private/public}
**Naming:** {valid/WARNING: should be source-*/external-*}

### Framework Source
| Location | Status |
|----------|--------|
| $CLAUDE_FRAMEWORK_DIR | {found/not set} |
| .claude-sync/ | {found/not found} |
| ~/Repos/claude-agents/ | {found/not found} |
| **Using:** | {resolved path} |

### Deployment Architecture
| Configuration | Value |
|---------------|-------|
| Visibility | {private/public} |
| Branches | {dev/qa/main OR main only} |
| Environment tiers | {development, validation, production OR production only} |
| Naming convention | {source-*/external-*} |
| Sensitivity scanning | {enabled/disabled} |

### Current State
| Component | Status |
|-----------|--------|
| Framework | {DEPLOYED vX.X / NOT DEPLOYED} |
| CLAUDE.md | {CREATED / MERGED / EXISTS} |
| Repo profile | {CREATED / EXISTS} |
| Dev branch | {EXISTS/MISSING/SKIPPED (public repo)} |
| Labels | {X}/8 present |
| Milestone | {name/MISSING} |

### Actions Taken
- [x] Detected framework source: {path}
- [x] Configured visibility: {private/public}
- [x] Created config/repo-profile.yaml
- [x] Validated naming convention: {PASS/WARNING}
- [x] Deployed framework (27 agents, 64 commands, 4 hooks)
- [x] Generated .claude/.manifest.json
- [x] Configured .claude/settings.json
- [x] Generated/merged CLAUDE.md with framework standards
- [x] Created dev branch from main (or skipped for public repo)
- [x] Created 8 standard labels (3 new, 5 existed)
- [x] Created milestone: MVP (due: {date})

### Next Steps
1. Review and customize CLAUDE.md for your project
2. [If naming warning] Rename repo to follow convention: {source-*/external-*}
3. Create your first issue: `gh issue create`
4. Assign to milestone: `gh issue edit 1 --milestone "MVP"`
5. Start working: `/sprint-work`
6. Update framework: `./load-claude-tastic.sh --update` or `manifest-sync.sh --target .claude/`
```

## Token Optimization

- **API calls:** Batched detection (branches, labels, milestones)
- **Framework detection:** Fast filesystem checks, no network required until clone fallback
- **Framework deploy:** Uses manifest-sync.sh for efficient file sync

## Notes

- WRITE operation - deploys framework files, creates branches, labels, milestones, repo profile, CLAUDE.md
- Idempotent - safe to run multiple times
- Does not modify existing labels, milestones, or settings.json
- CLAUDE.md generation: creates from template (new repos) or merges with existing (existing repos)
- Use `--check` flag for read-only status report
- Use `--skip-framework` to skip framework file deployment
- Use `--clone` flag to automatically clone the framework from GitHub if not found
- Framework source auto-detected: `$CLAUDE_FRAMEWORK_DIR` > `.claude-sync/` > `~/Repos/claude-agents`
- Consumer repos using `load-claude-tastic.sh` have the framework at `.claude-sync/` (auto-detected)
- If no source found, offers to clone from GitHub automatically
- Framework updates: `./load-claude-tastic.sh --update` or `manifest-sync.sh --target .claude/`
- Difference from `/repo-init`: This variant includes `.claude-sync/` in the detection chain, designed for `load-claude-tastic.sh` users
- **NEW:** Prompts for repository visibility (public/private)
- **NEW:** Enforces naming convention: `source-*` for private, `external-*` for public
- **NEW:** Creates `config/repo-profile.yaml` with deployment architecture
- **NEW:** Public repos skip dev/qa branches and use production-only deployment
- **NEW:** Private repos get full dev/qa/main SDLC pipeline
- **NEW:** CLAUDE.md generation integrated into init flow (create new or merge existing)
- Related issues: #933 (environment-tiered SDLC), #934 (public/private repo detection), #1137 (CLAUDE.md generation)
