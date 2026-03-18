#!/usr/bin/env bash
#
# repo-audit-create-issues.sh
# Create GitHub issues from repo audit findings
#
# Usage:
#   ./repo-audit-create-issues.sh [--dry-run] [--milestone NAME]
#
# Options:
#   --dry-run       Preview issues without creating them
#   --milestone     Milestone to assign (defaults to active milestone)
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments
#   2 - gh CLI error
#   3 - Findings file not found

set -euo pipefail

AUDIT_DIR=".repo-audit"
FINDINGS_FILE="$AUDIT_DIR/findings.json"
DRY_RUN=false
MILESTONE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

error() {
    echo -e "${RED}ERROR:${NC} $1" >&2
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

highlight() {
    echo -e "${CYAN}$1${NC}"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --milestone)
            if [[ -z "${2:-}" ]]; then
                error "Missing value for --milestone"
                exit 1
            fi
            MILESTONE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--milestone NAME]"
            echo ""
            echo "Create GitHub issues from repo audit findings."
            echo ""
            echo "Options:"
            echo "  --dry-run       Preview issues without creating them"
            echo "  --milestone     Milestone to assign (defaults to active milestone)"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check findings file exists
if [[ ! -f "$FINDINGS_FILE" ]]; then
    error "Findings file not found. Run /repo-audit-complete first."
    exit 3
fi

# Check gh CLI
if ! command -v gh &> /dev/null; then
    error "gh CLI not found"
    exit 2
fi

if ! gh auth status &> /dev/null; then
    error "gh CLI not authenticated"
    exit 2
fi

# Determine milestone if not specified
if [[ -z "$MILESTONE" ]]; then
    MILESTONE=$(./scripts/determine-milestone.sh 2>/dev/null || echo "")
    if [[ -z "$MILESTONE" ]]; then
        warn "No active milestone found. Issues will be created without milestone."
    else
        info "Using active milestone: $MILESTONE"
    fi
fi

# Get open findings
OPEN_FINDINGS=$(jq '[.findings[] | select(.status == "open")]' "$FINDINGS_FILE")
FINDING_COUNT=$(echo "$OPEN_FINDINGS" | jq 'length')

if [[ "$FINDING_COUNT" -eq 0 ]]; then
    info "No open findings to create issues for."
    exit 0
fi

echo ""
highlight "═══════════════════════════════════════════════════════════"
highlight "  Repo Audit: Issue Generation"
highlight "═══════════════════════════════════════════════════════════"
echo ""
info "Found $FINDING_COUNT open findings"
echo ""

# Group findings by type and title pattern for batch creation
# Strategy: Group similar findings together (e.g., all "missing set -euo pipefail" in scripts)
declare -A GROUPED_FINDINGS

group_findings() {
    # Get all unique combinations of type + title pattern
    local groups
    groups=$(echo "$OPEN_FINDINGS" | jq -r '.[] | "\(.type)|\(.title)"' | sort -u)

    while IFS='|' read -r type title; do
        # Count how many findings match this pattern
        local count
        count=$(echo "$OPEN_FINDINGS" | jq --arg type "$type" --arg title "$title" \
            '[.[] | select(.type == $type and .title == $title)] | length')

        # Group key
        local group_key="${type}:${title}"
        GROUPED_FINDINGS["$group_key"]="$count"
    done <<< "$groups"
}

# Severity to priority mapping
severity_to_priority() {
    local severity="$1"
    case "$severity" in
        critical) echo "P0" ;;
        high) echo "P1" ;;
        medium) echo "P2" ;;
        low|info) echo "P3" ;;
        *) echo "P2" ;;
    esac
}

# Type to label mapping
type_to_labels() {
    local type="$1"
    case "$type" in
        structure|code) echo "tech-debt" ;;
        security) echo "bug,security" ;;
        docs) echo "docs" ;;
        tests) echo "tech-debt" ;;
        *) echo "tech-debt" ;;
    esac
}

# Check if similar issue already exists
check_duplicate() {
    local title="$1"

    # Search for similar issues using the search-similar-issues script
    local similar
    similar=$(./scripts/search-similar-issues.sh "$title" 3 2>/dev/null || echo "[]")

    # Check if any have high similarity (>80%)
    local has_duplicate
    has_duplicate=$(echo "$similar" | jq 'length > 0')

    if [[ "$has_duplicate" == "true" ]]; then
        echo "$similar"
    else
        echo "[]"
    fi
}

# Create issue from grouped findings
create_issue_for_group() {
    local type="$1"
    local title_pattern="$2"
    local count="$3"

    # Get all findings in this group
    local findings
    findings=$(echo "$OPEN_FINDINGS" | jq --arg type "$type" --arg title "$title_pattern" \
        '[.[] | select(.type == $type and .title == $title)]')

    # Get severity (use highest severity in group)
    local severity
    severity=$(echo "$findings" | jq -r '
        map(.severity) |
        if contains(["critical"]) then "critical"
        elif contains(["high"]) then "high"
        elif contains(["medium"]) then "medium"
        elif contains(["low"]) then "low"
        else "info" end
    ')

    # Generate issue title
    local issue_title
    if [[ "$count" -gt 1 ]]; then
        issue_title="[Audit] $title_pattern ($count instances)"
    else
        issue_title="[Audit] $title_pattern"
    fi

    # Check for duplicates
    local duplicates
    duplicates=$(check_duplicate "$issue_title")
    local dup_count
    dup_count=$(echo "$duplicates" | jq 'length')

    if [[ "$dup_count" -gt 0 ]]; then
        warn "Similar issue(s) found for: $issue_title"
        echo "$duplicates" | jq -r '.[] | "  - #\(.number): \(.title)"' >&2
        return 0
    fi

    # Map severity to priority
    local priority
    priority=$(severity_to_priority "$severity")

    # Map type to labels
    local labels
    labels=$(type_to_labels "$type")
    labels="$labels,backlog"
    if [[ -n "$priority" ]]; then
        labels="$labels,priority:$priority"
    fi

    # Build issue body
    local body
    body="## Summary
Audit finding from /repo-audit-complete: $title_pattern

**Severity:** $severity
**Type:** $type
**Instances:** $count

## Details
"

    # Add details from each finding
    echo "$findings" | jq -r '.[] | "
### Finding \(.id)

\(.description)

**Found:** \(.found_at)
"' | while read -r line; do
        body="${body}${line}"$'\n'
    done

    body="${body}
## Acceptance Criteria
- [ ] All instances of this finding resolved
- [ ] Root cause addressed
- [ ] Changes tested and verified
- [ ] Documentation updated if needed

## Context
- Category: tech-debt
- Component: $(echo "$type" | sed 's/structure/config/;s/code/scripts/')
- Generated from: /repo-audit-complete findings

**Finding IDs:** $(echo "$findings" | jq -r 'map(.id) | join(", ")')
"

    # Preview or create
    if [[ "$DRY_RUN" == "true" ]]; then
        highlight "───────────────────────────────────────────────────────────"
        echo "Title: $issue_title"
        echo "Labels: $labels"
        echo "Milestone: ${MILESTONE:-none}"
        echo ""
        echo "$body"
        highlight "───────────────────────────────────────────────────────────"
        echo ""
    else
        # Create the issue
        info "Creating issue: $issue_title"

        local issue_number
        if [[ -n "$MILESTONE" ]]; then
            issue_number=$(gh issue create \
                --title "$issue_title" \
                --body "$body" \
                --label "$labels" \
                --milestone "$MILESTONE" \
                --json number -q .number 2>/dev/null)
        else
            issue_number=$(gh issue create \
                --title "$issue_title" \
                --body "$body" \
                --label "$labels" \
                --json number -q .number 2>/dev/null)
        fi

        if [[ $? -eq 0 && -n "$issue_number" ]]; then
            success "Created issue #$issue_number"

            # Link all findings to this issue
            echo "$findings" | jq -r '.[] | .id' | while read -r finding_id; do
                ./scripts/repo-audit-findings.sh link-issue "$finding_id" "$issue_number" 2>/dev/null || true
            done

            echo "  URL: $(gh issue view "$issue_number" --json url -q .url)"
        else
            error "Failed to create issue for: $issue_title"
        fi
    fi
}

# Group findings
group_findings

# Process each group
echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    highlight "DRY RUN MODE - Previewing issues (will not create)"
    echo ""
fi

for group_key in "${!GROUPED_FINDINGS[@]}"; do
    IFS=':' read -r type title <<< "$group_key"
    count="${GROUPED_FINDINGS[$group_key]}"

    create_issue_for_group "$type" "$title" "$count"
done

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
    info "Preview complete. Run without --dry-run to create issues."
else
    success "Issue creation complete!"
    info "Run './scripts/repo-audit-findings.sh list' to see updated findings"
fi
