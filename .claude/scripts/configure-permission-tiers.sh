#!/usr/bin/env bash
#
# configure-permission-tiers.sh
# Check if CLAUDE.md contains a permission tier section (T0/T1/T2/T3)
# and append the standard tier definitions if missing.
#
# Called by repo:init-framework during Step 5 (Deploy Framework Files)
# and by generate-claude-md.sh during merge operations.
#
# Usage:
#   ./scripts/configure-permission-tiers.sh [CLAUDE_MD_PATH]
#
# Arguments:
#   CLAUDE_MD_PATH  Path to the CLAUDE.md file to check/update (default: ./CLAUDE.md)
#
# Exit codes:
#   0 - Permission tiers already present OR successfully added
#   1 - Error (e.g. file not found)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Determine target file
TARGET="${1:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/CLAUDE.md}"

if [ ! -f "$TARGET" ]; then
    log_error "CLAUDE.md not found: $TARGET"
    exit 1
fi

log_info "Checking permission tiers in: $TARGET"

# ──────────────────────────────────────────────────────────────────────────────
# Detection: does the file already define permission tiers?
# We look for T0/T1/T2/T3 tier definitions (any of these patterns)
# ──────────────────────────────────────────────────────────────────────────────
has_permission_tiers() {
    local file="$1"
    # Match common tier section headings or explicit tier definitions
    grep -qiE "(permission tier|T0.*read.only|T1.*safe write|T2.*reversible|T3.*destructive)" "$file" 2>/dev/null
}

if has_permission_tiers "$TARGET"; then
    log_success "Permission tiers already defined in $TARGET — no changes needed"
    exit 0
fi

log_warn "Permission tier section not found — appending standard T0/T1/T2/T3 definitions"

# ──────────────────────────────────────────────────────────────────────────────
# Append the standard permission tier section
# ──────────────────────────────────────────────────────────────────────────────
cat >> "$TARGET" <<'TIERS_SECTION'

---

## Permission Tiers (T0/T1/T2/T3)

All agent and skill operations are classified by risk tier.
This section is auto-configured by `/repo:init-framework` and used by
`audit:config`, `ops:actions`, `ops:skill-deps`, and `validate:framework`.

### Tier Overview

| Tier | Risk Level | Approval Mode | Description |
|------|------------|---------------|-------------|
| **T0** | None | Auto-allow | Read-only operations — search, read, glob, grep |
| **T1** | Low | Auto-allow | Safe local writes — edit/write files, create branches |
| **T2** | Medium | Session-once | Reversible state changes — git commit, push, PR creation |
| **T3** | High | Always prompt | Destructive or irreversible — merges, deployments, deletions |

### Tool-to-Tier Mapping

#### T0 — Read-Only (auto-allowed)

- `Read`, `Glob`, `Grep` tools
- `git status`, `git log`, `git diff`, `git show`
- `gh issue list`, `gh pr list`, `gh api` (GET)
- `cat`, `ls`, `find`, `grep`, HTTP GET

#### T1 — Safe Write (auto-allowed)

- `Edit`, `Write` tools (new or local files)
- `git add`, `git stash`, `git checkout -b`
- `gh label create`, `gh issue edit --add-label`
- `mkdir`, `cp`, `touch`

#### T2 — Reversible Write (session-once prompt)

- `git commit`, `git merge`, `git push`, `git rebase`
- `gh issue create`, `gh pr create`
- `npm install`, `pip install`, `docker run`
- HTTP POST/PUT/PATCH

#### T3 — Destructive (always prompt)

- `git push --force`, `git reset --hard`, `git clean -fd`
- `gh pr merge`, `gh issue close`, `gh repo delete`
- `rm -rf`, `DROP TABLE`
- External webhooks, email/notification sends

### Quick Classification Test

```
Is the operation read-only (no state change)?    → T0
Can it be undone in <1 minute with one command?  → T1
Is it reversible but takes effort (5-30 min)?   → T2
Is it irreversible or affects shared systems?   → T3
```

See `/docs/PERMISSION_TIERS.md` for the complete classification guide.

TIERS_SECTION

log_success "Permission tiers appended to $TARGET"
echo ""
echo "  Added standard T0/T1/T2/T3 permission tier definitions."
echo "  Review the new section and customize for your project needs."
echo ""
exit 0
