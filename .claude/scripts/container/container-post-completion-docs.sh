#!/bin/bash
set -euo pipefail
# container-post-completion-docs.sh
# Trigger documentation agents after container work completes (Issue #1331)
# size-ok: post-completion doc review with PR diff analysis and targeted agent invocation
#
# This script runs as a post-completion sub-process after a container creates a PR.
# It invokes documentation agents to review the PR diff and update relevant docs:
#   - ARCHITECTURE.md  — if new files/modules were added or moved
#   - Skill READMEs    — if skill behavior changed
#   - CLAUDE.md        — if agent capabilities or workflow changed
#   - API docs         — if endpoints or interfaces changed
#   - Configuration docs — if new config options were introduced
#
# This script is designed to run:
#   - As a background sub-process inside the container (non-blocking)
#   - On the host after container completes (triggered by cleanup pipeline)
#
# Usage:
#   ./scripts/container/container-post-completion-docs.sh --pr <N> --issue <N>
#   ./scripts/container/container-post-completion-docs.sh --pr <N> --issue <N> --skip-docs
#
# Options:
#   --pr <N>            PR number (required)
#   --issue <N>         Issue number (required)
#   --repo <owner/repo> Repository (default: auto-detected from git remote)
#   --branch <name>     PR branch to push doc updates to (default: feature branch)
#   --follow-up-pr      Create a follow-up PR for doc changes instead of updating current PR
#   --skip-docs         Skip documentation review — exit 0 immediately
#   --dry-run           Fetch diff and build prompt but do NOT invoke Claude
#   --timeout <N>       Claude invocation timeout in seconds (default: 900)
#   --help              Show this help message
#
# Environment variables:
#   SKIP_DOCS                  Set to "true" to skip doc review (same as --skip-docs)
#   GITHUB_TOKEN               GitHub token for API access
#   CLAUDE_CODE_OAUTH_TOKEN    Claude API token
#   DOC_REVIEW_TIMEOUT         Override default Claude timeout
#
# Exit codes:
#   0 — Success or skipped (--skip-docs / SKIP_DOCS=true)
#   1 — Error (missing required args, Claude failure, push failure)
#   2 — No documentation changes needed (diff did not affect doc-relevant files)

SCRIPT_NAME="container-post-completion-docs.sh"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Shared utilities ────────────────────────────────────────────────────────

for _common_path in "${SCRIPT_DIR}/../lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$_common_path" ]; then
        # shellcheck source=/dev/null
        source "$_common_path"
        break
    fi
done

# Fallback minimal logging if common.sh not found
if ! command -v log_info &>/dev/null 2>&1; then
    log_info()  { echo "[INFO]  $*" >&2; }
    log_warn()  { echo "[WARN]  $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# ─── Argument defaults ───────────────────────────────────────────────────────

PR=""
ISSUE=""
REPO=""
BRANCH=""
FOLLOW_UP_PR=false
SKIP_DOCS="${SKIP_DOCS:-false}"
DRY_RUN=false
TIMEOUT="${DOC_REVIEW_TIMEOUT:-900}"

# ─── Usage ───────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
$SCRIPT_NAME v$VERSION — Post-completion documentation agent trigger

USAGE:
    $SCRIPT_NAME --pr <N> --issue <N> [OPTIONS]

OPTIONS:
    --pr <N>            PR number that was created (required)
    --issue <N>         Issue number that was worked on (required)
    --repo <owner/repo> Repository in owner/repo format (default: auto-detected)
    --branch <name>     Branch to push doc updates to (default: feat/issue-<N>)
    --follow-up-pr      Create a follow-up PR for doc changes instead of updating current PR
    --skip-docs         Skip documentation review and exit 0 immediately
    --dry-run           Fetch diff and build prompt, but do NOT invoke Claude
    --timeout <N>       Claude invocation timeout in seconds (default: 900)
    --help              Show this help message

ENVIRONMENT:
    SKIP_DOCS                  Skip doc review when set to "true"
    DOC_REVIEW_TIMEOUT         Override default Claude timeout
    GITHUB_TOKEN               GitHub access token
    CLAUDE_CODE_OAUTH_TOKEN    Claude API token

DESCRIPTION:
    Invoked after a container sprint workflow creates a PR.
    Fetches the PR diff, identifies documentation that may need updating,
    and runs a focused Claude documentation agent to apply corrections.

    Documentation targets reviewed:
      ARCHITECTURE.md     — new files, modules, or structural changes
      Skill READMEs       — skill behaviour or interface changes
      CLAUDE.md           — agent capabilities or workflow changes
      API docs            — new/changed endpoints or interfaces
      Config docs         — new configuration options

    Doc updates are pushed to the same PR branch by default, or to a
    new follow-up PR when --follow-up-pr is specified.

EXAMPLES:
    # Standard invocation after PR #456 for issue #107
    $SCRIPT_NAME --pr 456 --issue 107

    # Skip doc review
    $SCRIPT_NAME --pr 456 --issue 107 --skip-docs

    # Dry-run: build prompt without invoking Claude
    $SCRIPT_NAME --pr 456 --issue 107 --dry-run

    # Push doc fixes to a follow-up PR
    $SCRIPT_NAME --pr 456 --issue 107 --follow-up-pr
EOF
}

# ─── Argument parsing ────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
    case "$1" in
        --pr)         PR="$2";          shift 2 ;;
        --issue)      ISSUE="$2";       shift 2 ;;
        --repo)       REPO="$2";        shift 2 ;;
        --branch)     BRANCH="$2";      shift 2 ;;
        --follow-up-pr) FOLLOW_UP_PR=true; shift ;;
        --skip-docs)  SKIP_DOCS=true;   shift ;;
        --dry-run)    DRY_RUN=true;     shift ;;
        --timeout)    TIMEOUT="$2";     shift 2 ;;
        --help|-h)    usage; exit 0 ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ─── Skip guard ──────────────────────────────────────────────────────────────

if [ "$SKIP_DOCS" = "true" ]; then
    log_info "Post-completion doc review skipped (--skip-docs / SKIP_DOCS=true)"
    exit 0
fi

# ─── Validation ──────────────────────────────────────────────────────────────

if [ -z "$PR" ]; then
    log_error "--pr is required"
    usage
    exit 1
fi

if [ -z "$ISSUE" ]; then
    log_error "--issue is required"
    usage
    exit 1
fi

# Auto-detect repo from git remote if not provided
if [ -z "$REPO" ]; then
    REPO=$(git remote get-url origin 2>/dev/null \
        | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|' \
        || echo "")
    if [ -z "$REPO" ]; then
        log_error "Could not auto-detect repository. Pass --repo owner/repo"
        exit 1
    fi
fi

# Default branch to feature branch for the issue
if [ -z "$BRANCH" ]; then
    BRANCH="feat/issue-${ISSUE}"
fi

log_info "Post-completion doc review triggered for PR #${PR} (issue #${ISSUE})"
log_info "Repository: $REPO | Branch: $BRANCH | Follow-up PR: $FOLLOW_UP_PR"

# ─── Fetch PR diff ───────────────────────────────────────────────────────────

log_info "Fetching diff for PR #${PR}..."

PR_DIFF=""
PR_DIFF=$(gh pr diff "$PR" --repo "$REPO" 2>/dev/null || echo "")

if [ -z "$PR_DIFF" ]; then
    log_warn "Could not fetch diff for PR #${PR} — skipping doc review"
    exit 2
fi

# Count changed files
CHANGED_FILES=$(gh pr view "$PR" --repo "$REPO" \
    --json files --jq '[.files[].path] | join("\n")' 2>/dev/null || echo "")

CHANGED_FILE_COUNT=$(echo "$CHANGED_FILES" | grep -c . 2>/dev/null || echo "0")
log_info "PR #${PR} changed ${CHANGED_FILE_COUNT} file(s)"

# ─── Heuristic: decide if doc review is warranted ───────────────────────────
# Skip doc review if changes are trivially documentation-only or test-only files
# (avoid infinite loops where doc agent triggers another doc agent).

NON_DOC_CHANGES=$(echo "$CHANGED_FILES" | grep -vE '\.(md|txt|rst|adoc)$' | grep -c . 2>/dev/null || echo "0")

if [ "$NON_DOC_CHANGES" -eq 0 ] && [ "$CHANGED_FILE_COUNT" -gt 0 ]; then
    log_info "PR #${PR} only modifies documentation files — skipping recursive doc review"
    exit 2
fi

# ─── Build documentation agent prompt ────────────────────────────────────────

PR_URL="https://github.com/${REPO}/pull/${PR}"

# Truncate diff to avoid token limits (first 8000 chars is usually enough for context)
DIFF_PREVIEW="${PR_DIFF:0:8000}"
if [ "${#PR_DIFF}" -gt 8000 ]; then
    DIFF_PREVIEW="${DIFF_PREVIEW}
... (diff truncated, ${#PR_DIFF} total chars)"
fi

DOC_AGENT_PROMPT="TASK: Post-completion documentation review for PR #${PR}

A container sprint workflow just completed implementing issue #${ISSUE} and created PR #${PR}.
Your job is to review the changes and update any documentation that is now stale or incomplete.

## Changed Files in PR #${PR}
${CHANGED_FILES}

## PR Diff (preview)
\`\`\`diff
${DIFF_PREVIEW}
\`\`\`

## Documentation Targets to Review

Check each of the following and update if the PR changes affect them:

1. **ARCHITECTURE.md** — Update if new scripts, modules, agents, or directories were added/moved
2. **Skill READMEs / .claude/skills/** — Update if skill behavior, options, or triggers changed
3. **CLAUDE.md** — Update if agent capabilities, workflow steps, or integration points changed
4. **API docs (docs/api/, api/)** — Update if new endpoints, interfaces, or configs were introduced
5. **Config docs** — Update if new environment variables or configuration options were added
6. **scripts/README.md** — Update if new scripts were added or existing ones changed significantly

## Instructions

1. Use Read tool to examine current documentation files for each target above
2. Use Grep/Glob tools to find relevant documentation files
3. Compare documentation against the PR diff to identify gaps or stale content
4. Use Edit tool to update documentation that is incomplete or incorrect
5. After making changes, commit with: git add -A && git commit -m 'docs: update documentation for PR #${PR} (issue #${ISSUE})'

## Constraints

- Only update documentation — do NOT modify source code, scripts, or tests
- Keep documentation changes minimal and accurate — don't over-document
- If no documentation needs updating, explain why and do NOT create empty commits
- Use the PR diff as the source of truth for what changed

## PR Reference

PR URL: ${PR_URL}
Branch: ${BRANCH}

Start by reading ARCHITECTURE.md and CLAUDE.md to understand current state, then review the changed files."

# ─── Dry-run mode ────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = "true" ]; then
    log_info "DRY RUN — documentation agent prompt generated (not invoking Claude)"
    log_info "Prompt length: ${#DOC_AGENT_PROMPT} chars"
    echo ""
    echo "--- DOC AGENT PROMPT ---"
    echo "$DOC_AGENT_PROMPT"
    echo "--- END PROMPT ---"
    exit 0
fi

# ─── Ensure we are on the correct branch before running agent ─────────────────

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    log_info "Switching to branch: $BRANCH"
    git checkout "$BRANCH" 2>/dev/null || {
        log_warn "Could not switch to branch $BRANCH — doc review will run on current branch ($CURRENT_BRANCH)"
    }
fi

# ─── Invoke Claude documentation agent ───────────────────────────────────────

log_info "Invoking documentation agent for PR #${PR}..."

# Write prompt to temp file (avoids stdin pipe issues, see Issue #476)
PROMPT_FILE=$(mktemp /tmp/doc-agent-prompt.XXXXXX)
echo "$DOC_AGENT_PROMPT" > "$PROMPT_FILE"
trap 'rm -f "$PROMPT_FILE"' EXIT

# System prompt focused on documentation accuracy
DOC_SYSTEM_PROMPT="You are a documentation specialist. Your job is to keep project documentation
accurate and up-to-date with code changes.

RULES:
1. ALWAYS read existing documentation before making changes.
2. ONLY update documentation — never modify source code or tests.
3. Keep changes minimal, accurate, and focused on what actually changed.
4. If no documentation needs updating, say so explicitly — do NOT create empty commits.
5. Use Edit tool for updating existing docs, Write tool only for new doc files."

# Claude settings path
CLAUDE_SETTINGS="/home/claude/.claude/settings.json"

DOC_EXIT=0
if [ -f "$CLAUDE_SETTINGS" ]; then
    timeout "$TIMEOUT" claude -p \
        --permission-mode bypassPermissions \
        --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
        --system-prompt "$DOC_SYSTEM_PROMPT" \
        --settings "$CLAUDE_SETTINGS" \
        < "$PROMPT_FILE" || DOC_EXIT=$?
else
    timeout "$TIMEOUT" claude -p \
        --permission-mode bypassPermissions \
        --allowedTools "Read,Edit,Write,Glob,Grep,Bash" \
        --system-prompt "$DOC_SYSTEM_PROMPT" \
        < "$PROMPT_FILE" || DOC_EXIT=$?
fi

if [ "$DOC_EXIT" -eq 124 ]; then
    log_warn "Documentation agent timed out after ${TIMEOUT}s (non-fatal)"
    exit 1
elif [ "$DOC_EXIT" -ne 0 ]; then
    log_warn "Documentation agent exited with code $DOC_EXIT (non-fatal)"
    exit 1
fi

# ─── Check if agent made any documentation changes ───────────────────────────

DOC_CHANGES=$(git diff --name-only 2>/dev/null | grep -E '\.(md|txt|rst|adoc)$' | wc -l | tr -d ' ')
STAGED_DOC_CHANGES=$(git diff --staged --name-only 2>/dev/null | grep -E '\.(md|txt|rst|adoc)$' | wc -l | tr -d ' ')
TOTAL_DOC_CHANGES=$((DOC_CHANGES + STAGED_DOC_CHANGES))

# Also check if agent already committed
HEAD_BEFORE_PUSH=$(git rev-parse HEAD 2>/dev/null || echo "")

if [ "$TOTAL_DOC_CHANGES" -gt 0 ]; then
    log_info "Documentation agent made $TOTAL_DOC_CHANGES change(s) — staging and committing..."
    git add -A
    git commit -m "docs: update documentation for PR #${PR} (issue #${ISSUE})

Post-completion documentation review triggered by container-post-completion-docs.sh.
Changes reflect implementation in PR #${PR}.

Co-Authored-By: Claude <noreply@anthropic.com>" || true
fi

# ─── Push documentation changes ──────────────────────────────────────────────

HEAD_AFTER_PUSH=$(git rev-parse HEAD 2>/dev/null || echo "")

if [ "$HEAD_BEFORE_PUSH" = "$HEAD_AFTER_PUSH" ]; then
    log_info "No documentation changes were needed for PR #${PR}"
    exit 0
fi

log_info "Pushing documentation updates to branch: $BRANCH"

if [ "$FOLLOW_UP_PR" = "true" ]; then
    # Create a follow-up PR for doc changes on a new branch
    DOC_BRANCH="docs/pr-${PR}-followup"
    git checkout -b "$DOC_BRANCH" 2>/dev/null || git checkout "$DOC_BRANCH"
    git push -u origin "$DOC_BRANCH" --force-with-lease || {
        log_warn "Failed to push doc follow-up branch $DOC_BRANCH"
        exit 1
    }

    # Create follow-up PR
    gh pr create \
        --repo "$REPO" \
        --base "$BRANCH" \
        --head "$DOC_BRANCH" \
        --title "docs: documentation updates for PR #${PR}" \
        --body "## Summary

Post-completion documentation review for PR #${PR} (issue #${ISSUE}).

This follow-up PR contains documentation updates identified by the
documentation agent after reviewing the changes in PR #${PR}.

## Documentation Updated

$(git diff HEAD~1..HEAD --name-only 2>/dev/null | grep -E '\.(md|txt|rst|adoc)$' || echo "See diff for details")

Triggered by: container-post-completion-docs.sh" 2>/dev/null \
    && log_info "Follow-up doc PR created for PR #${PR}" \
    || log_warn "Failed to create follow-up doc PR (non-fatal)"
else
    # Push doc updates to the same PR branch
    git push origin "$BRANCH" --force-with-lease || {
        log_warn "Failed to push documentation updates to branch $BRANCH"
        exit 1
    }
    log_info "Documentation updates pushed to PR #${PR} branch ($BRANCH)"
fi

log_info "Post-completion doc review complete for PR #${PR}"
exit 0
