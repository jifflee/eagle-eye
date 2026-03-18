#!/usr/bin/env bash
set -euo pipefail
# pr-cross-reference.sh
# Cross-reference open issues after PR creation to prevent duplicate work (Issue #1271)
# size-ok: multi-strategy cross-reference with file overlap, keyword matching, and structured comment posting
#
# PURPOSE:
#   After a PR is created for an issue, scan all open issues to detect overlap:
#     1. File overlap  — PR diff touches files referenced in other issues
#     2. Keyword match — PR title/description words match other issue titles
#     3. Dependencies  — parent/child or blocking label relationships
#     4. Shared components — same scripts/, agents/, skills/ directories
#   For each affected issue, post a structured "Cross-Reference Update" comment.
#
# USAGE:
#   ./scripts/pr-cross-reference.sh --pr <N> --issue <N> [OPTIONS]
#
# OPTIONS:
#   --pr <N>            PR number that was just created (required)
#   --issue <N>         Source issue number the PR resolves (required)
#   --repo <owner/repo> Repository (auto-detected from git remote if not set)
#   --max-updates <N>   Max issues to comment on (default: 10)
#   --dry-run           Print what would be done without posting comments
#   --json              Output results as JSON
#   --no-cross-ref      Skip cross-reference (exit 0 immediately)
#   --debug             Enable debug output
#   --help              Show this help
#
# EXIT CODES:
#   0 - Success (even if no issues affected)
#   1 - Fatal error
#
# ENVIRONMENT:
#   GITHUB_TOKEN        GitHub token for API calls (optional, uses gh auth)
#   REPO_FULL_NAME      owner/repo format (alternative to --repo)
#   NO_CROSS_REF        Set to "true" to skip (same as --no-cross-ref)

SCRIPT_NAME="pr-cross-reference.sh"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
for path in "${SCRIPT_DIR}/lib/common.sh" "/workspace/repo/scripts/lib/common.sh"; do
    if [ -f "$path" ]; then
        source "$path"
        break
    fi
done

# Fallback logging
if ! command -v log_info >/dev/null 2>&1; then
    log_info()    { echo "[INFO] $*" >&2; }
    log_warn()    { echo "[WARN] $*" >&2; }
    log_error()   { echo "[ERROR] $*" >&2; }
    log_success() { echo "[OK] $*" >&2; }
fi

# ─── Defaults ─────────────────────────────────────────────────────────────────

PR_NUMBER=""
SOURCE_ISSUE=""
REPO="${REPO_FULL_NAME:-}"
MAX_UPDATES=10
DRY_RUN=false
JSON_OUTPUT=false
SKIP=false
DEBUG=false

# ─── Argument Parsing ─────────────────────────────────────────────────────────

usage() {
    cat << EOF >&2
$SCRIPT_NAME v$VERSION - Cross-reference open issues after PR creation

USAGE:
    $SCRIPT_NAME --pr <N> --issue <N> [OPTIONS]

OPTIONS:
    --pr <N>            PR number (required)
    --issue <N>         Source issue number (required)
    --repo <owner/repo> Repository (auto-detected if not set)
    --max-updates <N>   Max issues to comment on (default: $MAX_UPDATES)
    --dry-run           Print actions without posting comments
    --json              Output results as JSON
    --no-cross-ref      Skip cross-reference entirely
    --debug             Enable debug output
    --help              Show this help

EXAMPLES:
    $SCRIPT_NAME --pr 456 --issue 123
    $SCRIPT_NAME --pr 456 --issue 123 --dry-run
    $SCRIPT_NAME --pr 456 --issue 123 --max-updates 5
    $SCRIPT_NAME --pr 456 --issue 123 --no-cross-ref
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pr)
            PR_NUMBER="$2"; shift 2 ;;
        --issue)
            SOURCE_ISSUE="$2"; shift 2 ;;
        --repo)
            REPO="$2"; shift 2 ;;
        --max-updates)
            MAX_UPDATES="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=true; shift ;;
        --json)
            JSON_OUTPUT=true; shift ;;
        --no-cross-ref)
            SKIP=true; shift ;;
        --debug)
            DEBUG=true; shift ;;
        --help|-h)
            usage ;;
        *)
            log_error "Unknown option: $1"; usage ;;
    esac
done

# Honour environment-level opt-out
if [ "${NO_CROSS_REF:-}" = "true" ]; then
    SKIP=true
fi

if [ "$SKIP" = "true" ]; then
    log_info "Cross-reference skipped (--no-cross-ref / NO_CROSS_REF=true)"
    exit 0
fi

# Validate required args
if [ -z "$PR_NUMBER" ] || [ -z "$SOURCE_ISSUE" ]; then
    log_error "--pr and --issue are required"
    usage
fi

# Auto-detect repo
if [ -z "$REPO" ]; then
    REPO=$(git remote get-url origin 2>/dev/null \
        | sed -E 's|.*github.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|' \
        || echo "")
fi

if [ -z "$REPO" ]; then
    log_error "Could not determine repository. Set REPO_FULL_NAME or use --repo."
    exit 1
fi

debug() {
    if [ "$DEBUG" = "true" ]; then
        echo "[DEBUG] $*" >&2
    fi
}

log_info "PR Cross-Reference: PR #$PR_NUMBER → Issue #$SOURCE_ISSUE ($REPO)"

# ─── Step 1: Collect PR metadata ──────────────────────────────────────────────

log_info "Fetching PR #$PR_NUMBER metadata..."

PR_JSON=$(gh pr view "$PR_NUMBER" \
    --repo "$REPO" \
    --json number,title,body,files,baseRefName,headRefName \
    2>/dev/null || echo "{}")

PR_TITLE=$(echo "$PR_JSON" | jq -r '.title // ""')
PR_BODY=$(echo "$PR_JSON"  | jq -r '.body  // ""')
PR_BASE=$(echo "$PR_JSON"  | jq -r '.baseRefName // "main"')
PR_HEAD=$(echo "$PR_JSON"  | jq -r '.headRefName // ""')

# Changed files from PR (via gh pr view --json files)
PR_FILES=$(echo "$PR_JSON" | jq -r '.files[].path // empty' 2>/dev/null || echo "")

if [ -z "$PR_FILES" ]; then
    # Fallback: use git diff against base branch
    log_warn "No file list from gh — falling back to git diff"
    PR_FILES=$(git diff --name-only "origin/${PR_BASE}...HEAD" 2>/dev/null || echo "")
fi

debug "PR title: $PR_TITLE"
debug "Changed files: $(echo "$PR_FILES" | wc -l | tr -d ' ')"

# Build keyword set from PR title (words ≥ 4 chars, lower-cased, no duplicates)
PR_KEYWORDS=$(echo "$PR_TITLE $PR_BODY" \
    | tr '[:upper:]' '[:lower:]' \
    | grep -oE '[a-z][a-z0-9_-]{3,}' \
    | sort -u \
    | grep -vE '^(this|that|with|from|have|will|when|then|also|into|some|more|been|were|they|their|what|your|which|should|would|could|after|before|issue|https|http)$' \
    || true)

debug "PR keywords (sample): $(echo "$PR_KEYWORDS" | head -5 | tr '\n' ' ')"

# Shared component directories touched by this PR
PR_DIRS=$(echo "$PR_FILES" | sed 's|/[^/]*$||' | sort -u || true)

# ─── Step 2: Fetch open issues ────────────────────────────────────────────────

log_info "Fetching open issues..."

# Get up to 100 open issues (excluding the source issue)
OPEN_ISSUES=$(gh issue list \
    --repo "$REPO" \
    --state open \
    --limit 100 \
    --json number,title,body,labels \
    2>/dev/null || echo "[]")

ISSUE_COUNT=$(echo "$OPEN_ISSUES" | jq 'length')
log_info "Found $ISSUE_COUNT open issue(s) to scan"

# ─── Step 3: Scoring functions ────────────────────────────────────────────────

# Returns overlap score (0-100) and reason strings separated by newlines.
# Uses process substitution to avoid subshell variable loss.
score_issue() {
    local issue_num="$1"
    local issue_title="$2"
    local issue_body="$3"
    local issue_labels="$4"

    local score=0
    local reasons=()
    local overlapping_files=()

    # ── 3a. File overlap ──────────────────────────────────────────────────────
    # Extract file references from the issue body
    local issue_files
    issue_files=$(echo "$issue_body" \
        | grep -oE '`[^`]+\.(sh|js|ts|tsx|jsx|py|md|json|yaml|yml|go|rb|tf)`' \
        | sed 's/`//g' || true)
    issue_files+=$'\n'$(echo "$issue_body" \
        | grep -oE '[a-zA-Z0-9_/-]+\.(sh|js|ts|tsx|jsx|py|md|json|yaml|yml|go|rb)' \
        || true)
    issue_files+=$'\n'$(echo "$issue_body" \
        | grep -oE '(scripts|docs|src|tests|api|lib|skills|agents|hooks|primitives)/[a-zA-Z0-9_/-]+' \
        || true)

    while IFS= read -r pf; do
        [ -z "$pf" ] && continue
        if echo "$issue_files" | grep -qF "$pf" 2>/dev/null; then
            overlapping_files+=("$pf")
            score=$((score + 20))
        fi
    done <<< "$PR_FILES"

    if [ ${#overlapping_files[@]} -gt 0 ]; then
        reasons+=("File overlap: \`$(printf '%s\`, `' "${overlapping_files[@]}" | sed 's/, `$//')\`")
    fi

    # ── 3b. Directory / component overlap ────────────────────────────────────
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        if echo "$issue_body $issue_title" | grep -qF "$dir" 2>/dev/null; then
            score=$((score + 10))
            reasons+=("Shared directory: \`$dir/\`")
        fi
    done <<< "$PR_DIRS"

    # ── 3c. Keyword overlap ───────────────────────────────────────────────────
    local kw_hits=0
    local kw_sample=()
    local issue_text_lc
    issue_text_lc=$(echo "$issue_title $issue_body" | tr '[:upper:]' '[:lower:]')

    while IFS= read -r kw; do
        [ -z "$kw" ] && continue
        if echo "$issue_text_lc" | grep -qwF "$kw" 2>/dev/null; then
            kw_hits=$((kw_hits + 1))
            if [ ${#kw_sample[@]} -lt 5 ]; then
                kw_sample+=("$kw")
            fi
        fi
    done <<< "$PR_KEYWORDS"

    if [ "$kw_hits" -ge 3 ]; then
        score=$((score + kw_hits * 5))
        reasons+=("Keyword match ($kw_hits hits): $(printf '%s, ' "${kw_sample[@]}" | sed 's/, $//')")
    fi

    # ── 3d. Dependency labels ─────────────────────────────────────────────────
    if echo "$issue_labels" | grep -qiE '(blocked-by|depends-on|parent|child|blocking)'; then
        score=$((score + 15))
        reasons+=("Dependency label detected")
    fi

    # ── 3e. Issue cross-reference in PR body ─────────────────────────────────
    if echo "$PR_BODY" | grep -qE "#${issue_num}([^0-9]|$)"; then
        score=$((score + 30))
        reasons+=("PR body explicitly references this issue")
    fi

    # Cap at 100
    [ "$score" -gt 100 ] && score=100

    echo "$score"
    printf '%s\n' "${reasons[@]}"
}

# ─── Step 4: Scan issues and collect affected ones ────────────────────────────

log_info "Scanning issues for overlap..."

declare -a AFFECTED_ISSUES=()
declare -A ISSUE_SCORES=()
declare -A ISSUE_REASONS=()
declare -A ISSUE_TITLES=()

while IFS= read -r issue_entry; do
    issue_num=$(echo "$issue_entry" | jq -r '.number')
    issue_title=$(echo "$issue_entry" | jq -r '.title // ""')
    issue_body=$(echo "$issue_entry"  | jq -r '.body  // ""')
    issue_labels=$(echo "$issue_entry" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")

    # Skip the source issue itself
    if [ "$issue_num" = "$SOURCE_ISSUE" ]; then
        debug "Skipping source issue #$issue_num"
        continue
    fi

    # Skip issues already worked on by this agent (checked-out / in-progress by same container)
    if echo "$issue_labels" | grep -qE 'wip:checked-out'; then
        debug "Skipping checked-out issue #$issue_num"
        continue
    fi

    # Score this issue
    score_output=$(score_issue "$issue_num" "$issue_title" "$issue_body" "$issue_labels")
    score=$(echo "$score_output" | head -1)
    reasons=$(echo "$score_output" | tail -n +2)

    debug "Issue #$issue_num score=$score title='$issue_title'"

    if [ "$score" -ge 20 ]; then
        AFFECTED_ISSUES+=("$issue_num")
        ISSUE_SCORES["$issue_num"]="$score"
        ISSUE_REASONS["$issue_num"]="$reasons"
        ISSUE_TITLES["$issue_num"]="$issue_title"
    fi
done < <(echo "$OPEN_ISSUES" | jq -c '.[]')

log_info "Found ${#AFFECTED_ISSUES[@]} affected issue(s)"

# Sort by score descending and cap at MAX_UPDATES
if [ ${#AFFECTED_ISSUES[@]} -gt 0 ]; then
    # Sort numerically by score (desc) using a temp array
    sorted_issues=()
    for num in "${AFFECTED_ISSUES[@]}"; do
        echo "${ISSUE_SCORES[$num]} $num"
    done | sort -rn | while read -r s n; do
        echo "$n"
    done > /tmp/pr-xref-sorted-$$.txt

    idx=0
    while IFS= read -r n && [ "$idx" -lt "$MAX_UPDATES" ]; do
        sorted_issues+=("$n")
        idx=$((idx + 1))
    done < /tmp/pr-xref-sorted-$$.txt
    rm -f /tmp/pr-xref-sorted-$$.txt
else
    sorted_issues=()
fi

# ─── Step 5: Build & post cross-reference comments ───────────────────────────

UPDATES_POSTED=0
UPDATES_SKIPPED=0
declare -a POSTED_ISSUES=()

for issue_num in "${sorted_issues[@]}"; do
    issue_title="${ISSUE_TITLES[$issue_num]}"
    score="${ISSUE_SCORES[$issue_num]}"
    reasons="${ISSUE_REASONS[$issue_num]}"

    # Build bullet list of reasons
    reason_bullets=""
    while IFS= read -r r; do
        [ -z "$r" ] && continue
        reason_bullets+="- $r"$'\n'
    done <<< "$reasons"

    # Build comment
    COMMENT_BODY="<!-- pr-cross-ref:pr-$PR_NUMBER:issue-$SOURCE_ISSUE -->
🔗 **Cross-Reference Update** (from PR #${PR_NUMBER} / Issue #${SOURCE_ISSUE})

**Changes that may affect this issue:**
${reason_bullets:-"- Overlap detected (score: $score/100)"}
**PR:** [#${PR_NUMBER}](https://github.com/${REPO}/pull/${PR_NUMBER}) — \`${PR_TITLE}\`
**Source Issue:** #${SOURCE_ISSUE}

**Impact:** Review before starting work — some acceptance criteria may already be met or implementation decisions already made.

<details>
<summary>Changed files in PR #${PR_NUMBER}</summary>

\`\`\`
$(echo "$PR_FILES" | head -30)
\`\`\`

</details>

---
*Auto-generated by \`pr-cross-reference.sh\` — overlap score: ${score}/100*"

    if [ "$DRY_RUN" = "true" ]; then
        log_info "[DRY RUN] Would post cross-ref comment on issue #$issue_num (score: $score)"
        echo "  Title: $issue_title"
        echo "  Reasons:"
        echo "$reasons" | sed 's/^/    - /'
        UPDATES_POSTED=$((UPDATES_POSTED + 1))
        POSTED_ISSUES+=("$issue_num")
        continue
    fi

    log_info "Posting cross-reference comment on issue #$issue_num (score: $score)..."
    if gh issue comment "$issue_num" \
        --repo "$REPO" \
        --body "$COMMENT_BODY" 2>/dev/null; then
        log_info "  Posted comment on #$issue_num: $issue_title"
        UPDATES_POSTED=$((UPDATES_POSTED + 1))
        POSTED_ISSUES+=("$issue_num")
    else
        log_warn "  Failed to post comment on issue #$issue_num (non-fatal)"
        UPDATES_SKIPPED=$((UPDATES_SKIPPED + 1))
    fi

    # Brief pause to respect GitHub API rate limits
    sleep 1
done

# ─── Step 6: Output results ───────────────────────────────────────────────────

if [ "$JSON_OUTPUT" = "true" ]; then
    posted_json=$(printf '%s\n' "${POSTED_ISSUES[@]:-}" | jq -R . | jq -s .)
    cat << EOF
{
  "pr": $PR_NUMBER,
  "source_issue": $SOURCE_ISSUE,
  "repo": "$REPO",
  "affected_issues_found": ${#AFFECTED_ISSUES[@]},
  "updates_posted": $UPDATES_POSTED,
  "updates_skipped": $UPDATES_SKIPPED,
  "posted_issues": $posted_json,
  "dry_run": $DRY_RUN
}
EOF
else
    echo ""
    if [ "$DRY_RUN" = "true" ]; then
        log_info "Cross-reference complete (DRY RUN): $UPDATES_POSTED issue(s) would be notified"
    else
        log_info "Cross-reference complete: $UPDATES_POSTED issue(s) notified, $UPDATES_SKIPPED skipped"
    fi
    if [ ${#sorted_issues[@]} -gt 0 ]; then
        log_info "Affected issues: #$(printf '%s #' "${sorted_issues[@]}" | sed 's/ #$//')"
    fi
fi

exit 0
