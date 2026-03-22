#!/bin/bash
# retroactive-context-review.sh
# Analyzes recently closed issues to extract decisions, context shifts, and patterns.
# Applies relevant insights to open pipeline issues as comments and label updates.
#
# Usage:
#   ./retroactive-context-review.sh                    # Review last 5 completed issues
#   ./retroactive-context-review.sh --limit N          # Review last N completed issues
#   ./retroactive-context-review.sh --milestone "name" # Restrict to specific milestone
#   ./retroactive-context-review.sh --dry-run          # Preview without applying changes
#
# What it does:
#   1. Fetches the last N closed issues (with their comments/bodies)
#   2. Extracts: decisions made, context shifts, patterns, blockers resolved
#   3. Matches insights to open pipeline issues using keyword/dependency analysis
#   4. Adds comments to relevant open issues explaining the impact
#   5. Applies needs-review label if completed work may make issue obsolete/changed
#   6. Applies context-updated label to all issues that received updates
#
# Output: Summary JSON with matches found and actions taken

set -euo pipefail

# Ensure we're in the repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo '{"error": "Not in a git repository"}'
    exit 1
}

LOG_PREFIX="[retroactive-context-review]"
log_info()  { echo "${LOG_PREFIX} $*" >&2; }
log_warn()  { echo "${LOG_PREFIX} WARN: $*" >&2; }
log_error() { echo "${LOG_PREFIX} ERROR: $*" >&2; }

# ─── Argument Parsing ─────────────────────────────────────────────────────────

LIMIT=5
MILESTONE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit)
            LIMIT="$2"
            shift 2
            ;;
        --milestone)
            MILESTONE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Ensure context-updated label exists in the repo
ensure_label() {
    local name="$1"
    local color="$2"
    local description="$3"

    gh label list --json name --jq '.[].name' 2>/dev/null | grep -q "^${name}$" && return 0
    gh label create "$name" --color "$color" --description "$description" 2>/dev/null || true
}

# Extract keywords from text for matching
extract_keywords() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | \
        grep -oE '[a-z][a-z0-9_-]{3,}' | \
        grep -v -E '^(this|that|with|from|have|been|will|were|they|their|also|when|then|than|just|into|over|after|before|should|would|could|about|which|where|there|these|those|other|some|more|most|only|very|such|each|much|many|both|even|well|back|down|need|make|take|work|look|good|long|time|year|way|use|can|may|all|new|part|get|how|its|too|she|him|had|has|his|her|our|was|the|and|for|are|but|not|you|all|can|had|her|was|one|our|out|day|get|has|him|how|its|let|may|nor|now|off|old|per|put|ran|say|set|so|too|try|two|use|way|yes|yet|you)$'
}

# ─── Step 1: Fetch Recently Closed Issues ────────────────────────────────────

log_info "Fetching last ${LIMIT} closed issues..."

MILESTONE_FILTER=""
if [ -n "$MILESTONE" ]; then
    MILESTONE_FILTER="--milestone \"$MILESTONE\""
fi

# Fetch closed issues with body and labels
CLOSED_ISSUES=$(gh issue list \
    --state closed \
    --limit "$LIMIT" \
    --json number,title,body,labels,closedAt,comments \
    ${MILESTONE_FILTER} 2>/dev/null || echo "[]")

if [ -z "$CLOSED_ISSUES" ] || [ "$CLOSED_ISSUES" = "[]" ]; then
    log_info "No recently closed issues found — skipping retroactive review"
    echo '{"status": "skipped", "reason": "no_closed_issues", "matches": []}'
    exit 0
fi

CLOSED_COUNT=$(echo "$CLOSED_ISSUES" | jq 'length')
log_info "Found ${CLOSED_COUNT} closed issues to analyze"

# ─── Step 2: Fetch Open Pipeline Issues ──────────────────────────────────────

log_info "Fetching open pipeline issues..."

OPEN_MILESTONE=""
if [ -z "$MILESTONE" ]; then
    OPEN_MILESTONE=$(gh api repos/:owner/:repo/milestones \
        --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0].title // empty' \
        2>/dev/null || echo "")
else
    OPEN_MILESTONE="$MILESTONE"
fi

if [ -n "$OPEN_MILESTONE" ]; then
    OPEN_ISSUES=$(gh issue list \
        --milestone "$OPEN_MILESTONE" \
        --state open \
        --json number,title,body,labels \
        --limit 100 \
        2>/dev/null || echo "[]")
else
    OPEN_ISSUES=$(gh issue list \
        --state open \
        --json number,title,body,labels \
        --limit 100 \
        2>/dev/null || echo "[]")
fi

OPEN_COUNT=$(echo "$OPEN_ISSUES" | jq 'length')
log_info "Found ${OPEN_COUNT} open issues to check for context relevance"

if [ "$OPEN_COUNT" -eq 0 ]; then
    log_info "No open issues — nothing to update"
    echo '{"status": "skipped", "reason": "no_open_issues", "matches": []}'
    exit 0
fi

# ─── Step 3: Extract Insights from Closed Issues ─────────────────────────────

log_info "Analyzing closed issues for decisions, context shifts, and patterns..."

# Build insight data per closed issue:
# - decision signals: "switched", "changed", "decided", "replaced", "migrated", "deprecated"
# - blocker resolved: "resolved", "unblocked", "fixed", "closed", "addressed"
# - dependency added: "requires", "depends on", "needs redis", "must have", "prerequisite"
# - scope change: "no longer", "obsolete", "not needed", "removed", "dropped", "out of scope"
INSIGHTS=$(echo "$CLOSED_ISSUES" | jq '
[.[] | {
    number: .number,
    title: .title,
    closed_at: .closedAt,
    body: (.body // ""),
    labels: [.labels[].name],
    comments: [.comments[]?.body // ""],
    full_text: ((.title + " " + (.body // "") + " " + ([.comments[]?.body // ""] | join(" "))) | ascii_downcase),
    signals: {
        decision: (
            (.title + " " + (.body // "")) | ascii_downcase |
            test("switch|switched|changed|decided|chose|replaced|migrated|deprecated|moved from|now using|instead of|adopt")
        ),
        blocker_resolved: (
            (.title + " " + (.body // "")) | ascii_downcase |
            test("resolved|unblocked|fixed|closed|addressed|no longer blocked|dependency met|available now")
        ),
        dependency_added: (
            (.title + " " + (.body // "")) | ascii_downcase |
            test("requires|depends on|needs|must have|prerequisite|before deploying|before merging|redis|postgres|kafka|elasticsearch|must install")
        ),
        scope_change: (
            (.title + " " + (.body // "")) | ascii_downcase |
            test("no longer|obsolete|not needed|removed|dropped|out of scope|wont fix|wont do|cancelled|duplicate approach")
        )
    }
}]
')

# ─── Step 4: Match Insights to Open Pipeline Issues ──────────────────────────

log_info "Matching insights to open pipeline issues..."

# For each pair (closed_issue, open_issue), compute relevance
MATCHES=$(echo "$INSIGHTS" "$OPEN_ISSUES" | jq -s '
.[0] as $closed |
.[1] as $open |

# Helper: extract significant words (length > 3, no common stop words)
def sig_words:
    ascii_downcase |
    gsub("[^a-z0-9 ]"; " ") |
    split(" ") |
    map(select(length > 3)) |
    map(select(. != "this" and . != "that" and . != "with" and . != "from"
               and . != "have" and . != "been" and . != "will" and . != "were"
               and . != "they" and . != "their" and . != "also" and . != "when"
               and . != "then" and . != "than" and . != "just" and . != "into"
               and . != "over" and . != "after" and . != "should" and . != "would"
               and . != "could" and . != "about" and . != "which" and . != "where"
               and . != "there" and . != "these" and . != "those" and . != "other"
               and . != "some" and . != "more" and . != "most" and . != "only"
               and . != "issue" and . != "feature" and . != "task" and . != "todo"));

# Helper: compute overlap %
def overlap($a; $b):
    if ($a | length) == 0 or ($b | length) == 0 then 0
    else
        ([$a[] | select(. as $w | $b | index($w))] | length) as $common |
        ($common / ([($a | length), ($b | length)] | min) * 100 | floor)
    end;

[
    $closed[] as $c |
    $open[] as $o |
    # Skip if open issue is the same number as closed
    select($c.number != $o.number) |
    # Compute keyword overlap between closed and open issue
    ($c.full_text | sig_words) as $c_words |
    (($o.title + " " + ($o.body // "")) | sig_words) as $o_words |
    overlap($c_words; $o_words) as $relevance |
    # Only report matches with meaningful overlap
    select($relevance >= 25 or $c.signals.dependency_added or $c.signals.scope_change) |
    {
        closed_number: $c.number,
        closed_title: $c.title,
        closed_at: $c.closed_at,
        open_number: $o.number,
        open_title: $o.title,
        relevance: $relevance,
        signals: $c.signals,
        # Determine impact type
        impact: (
            if $c.signals.scope_change then "scope_change"
            elif $c.signals.dependency_added and $relevance >= 20 then "dependency"
            elif $c.signals.decision and $relevance >= 30 then "decision"
            elif $c.signals.blocker_resolved and $relevance >= 25 then "blocker_resolved"
            elif $relevance >= 40 then "related_context"
            else "weak_link"
            end
        ),
        # Generate comment text
        comment: (
            if $c.signals.scope_change and $relevance >= 25 then
                ("**Context update from #" + ($c.number | tostring) + ":** \"" + $c.title +
                 "\"\n\nThe work in #" + ($c.number | tostring) + " may have changed the scope of this issue. " +
                 "Please verify this issue is still needed and the approach is still valid.\n\n" +
                 "> Auto-generated by retroactive context review (sprint-work auto-triage)")
            elif $c.signals.dependency_added and $relevance >= 20 then
                ("**Dependency note from #" + ($c.number | tostring) + ":** \"" + $c.title + "\"\n\n" +
                 "Issue #" + ($c.number | tostring) + " introduced a new dependency or requirement. " +
                 "Ensure any prerequisites from that work are in place before starting this issue.\n\n" +
                 "> Auto-generated by retroactive context review (sprint-work auto-triage)")
            elif $c.signals.decision and $relevance >= 30 then
                ("**Decision context from #" + ($c.number | tostring) + ":** \"" + $c.title + "\"\n\n" +
                 "An architectural or approach decision was made in #" + ($c.number | tostring) + " that may affect this issue. " +
                 "Review that issue before proceeding to ensure alignment.\n\n" +
                 "> Auto-generated by retroactive context review (sprint-work auto-triage)")
            elif $c.signals.blocker_resolved and $relevance >= 25 then
                ("**Blocker resolved in #" + ($c.number | tostring) + ":** \"" + $c.title + "\"\n\n" +
                 "A blocker or dependency relevant to this issue was resolved in #" + ($c.number | tostring) + ". " +
                 "This issue may now be unblocked or the approach may need updating.\n\n" +
                 "> Auto-generated by retroactive context review (sprint-work auto-triage)")
            else
                ("**Related context from #" + ($c.number | tostring) + ":** \"" + $c.title + "\"\n\n" +
                 "Recently completed issue #" + ($c.number | tostring) + " is related to this work (" + ($relevance | tostring) + "% keyword overlap). " +
                 "Review it for context that may affect this issue.\n\n" +
                 "> Auto-generated by retroactive context review (sprint-work auto-triage)")
            end
        ),
        # Determine labels to add
        add_labels: (
            if $c.signals.scope_change and $relevance >= 25 then
                ["needs-review", "context-updated"]
            elif $c.signals.dependency_added and $relevance >= 20 then
                ["context-updated"]
            elif $relevance >= 30 then
                ["context-updated"]
            else
                []
            end
        )
    }
] |
# Deduplicate: for each open issue, keep only the strongest match per closed issue
# (avoid spamming an issue with many weak matches from the same closed issue)
group_by(.open_number) |
map(
    . as $group |
    # Sort by relevance descending within each open issue
    sort_by(-.relevance) |
    # Keep top 3 matches per open issue (avoid spam)
    .[0:3]
) |
flatten
')

MATCH_COUNT=$(echo "$MATCHES" | jq 'length')
log_info "Found ${MATCH_COUNT} relevant insight-to-issue matches"

if [ "$MATCH_COUNT" -eq 0 ]; then
    log_info "No relevant context matches found — no pipeline issues need updating"
    echo '{"status": "complete", "matches_found": 0, "issues_updated": 0, "dry_run": false}'
    exit 0
fi

# ─── Step 5: Ensure Labels Exist ─────────────────────────────────────────────

if [ "$DRY_RUN" = "false" ]; then
    log_info "Ensuring required labels exist..."
    ensure_label "context-updated" "0075ca" "Issue body or context updated by retroactive review" || true
    ensure_label "needs-review"    "e4e669" "Issue needs manual review due to context change"    || true
fi

# ─── Step 6: Apply Comments and Labels to Open Issues ────────────────────────

ISSUES_UPDATED=0
COMMENTS_ADDED=0

# Get unique open issue numbers that have matches
OPEN_ISSUE_NUMBERS=$(echo "$MATCHES" | jq -r '[.[].open_number] | unique[]')

for open_num in $OPEN_ISSUE_NUMBERS; do
    # Get all matches for this open issue
    ISSUE_MATCHES=$(echo "$MATCHES" | jq --argjson n "$open_num" '[.[] | select(.open_number == $n)]')
    ISSUE_TITLE=$(echo "$ISSUE_MATCHES" | jq -r '.[0].open_title')

    log_info "Processing open issue #${open_num}: ${ISSUE_TITLE}"

    # Collect all labels to add across all matches
    LABELS_TO_ADD=$(echo "$ISSUE_MATCHES" | jq -r '[.[].add_labels[]] | unique[]' 2>/dev/null || echo "")

    if [ "$DRY_RUN" = "true" ]; then
        echo "[DRY RUN] Would update issue #${open_num}: ${ISSUE_TITLE}"
        echo "$ISSUE_MATCHES" | jq -r '.[] | "  - From #\(.closed_number): \(.closed_title) (impact: \(.impact), relevance: \(.relevance)%)"'
        if [ -n "$LABELS_TO_ADD" ]; then
            echo "  Labels to add: $(echo "$LABELS_TO_ADD" | tr '\n' ' ')"
        fi
        continue
    fi

    # Add a comment for each match (skip weak_link impacts with <35% relevance to reduce noise)
    COMMENT_ADDED=false
    while IFS= read -r match_json; do
        local_impact=$(echo "$match_json" | jq -r '.impact')
        local_relevance=$(echo "$match_json" | jq -r '.relevance')
        local_comment=$(echo "$match_json" | jq -r '.comment')
        local_closed=$(echo "$match_json" | jq -r '.closed_number')

        # Skip very weak links unless they have a specific signal
        if [ "$local_impact" = "weak_link" ] && [ "$local_relevance" -lt 35 ]; then
            log_info "  Skipping weak match with #${local_closed} (${local_relevance}% relevance)"
            continue
        fi

        log_info "  Adding comment from #${local_closed} (impact: ${local_impact}, relevance: ${local_relevance}%)"
        if gh issue comment "$open_num" --body "$local_comment" 2>/dev/null; then
            COMMENT_ADDED=true
            COMMENTS_ADDED=$(( COMMENTS_ADDED + 1 ))
        else
            log_warn "  Failed to add comment to #${open_num} — continuing"
        fi
    done < <(echo "$ISSUE_MATCHES" | jq -c '.[]')

    # Apply labels if any comments were added or there are labels to add
    if [ -n "$LABELS_TO_ADD" ] && [ "$COMMENT_ADDED" = "true" ]; then
        for label in $LABELS_TO_ADD; do
            log_info "  Adding label '${label}' to #${open_num}"
            gh issue edit "$open_num" --add-label "$label" 2>/dev/null || \
                log_warn "  Could not add label '${label}' to #${open_num}"
        done
    fi

    if [ "$COMMENT_ADDED" = "true" ]; then
        ISSUES_UPDATED=$(( ISSUES_UPDATED + 1 ))
    fi
done

# ─── Step 7: Summary ─────────────────────────────────────────────────────────

log_info "Retroactive context review complete"
log_info "  Closed issues analyzed: ${CLOSED_COUNT}"
log_info "  Open issues checked:    ${OPEN_COUNT}"
log_info "  Matches found:          ${MATCH_COUNT}"
log_info "  Issues updated:         ${ISSUES_UPDATED}"
log_info "  Comments added:         ${COMMENTS_ADDED}"

jq -n \
    --argjson closed "$CLOSED_COUNT" \
    --argjson open "$OPEN_COUNT" \
    --argjson matches "$MATCH_COUNT" \
    --argjson updated "$ISSUES_UPDATED" \
    --argjson comments "$COMMENTS_ADDED" \
    --argjson dry_run "$DRY_RUN" \
    '{
        status: "complete",
        closed_issues_analyzed: $closed,
        open_issues_checked: $open,
        matches_found: $matches,
        issues_updated: $updated,
        comments_added: $comments,
        dry_run: $dry_run,
        generated_at: (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
    }'
