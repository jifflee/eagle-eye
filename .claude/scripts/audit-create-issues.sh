#!/usr/bin/env bash
#
# audit-create-issues.sh
# Generic script to create GitHub issues from audit skill recommendations
#
# Usage:
#   ./audit-create-issues.sh [OPTIONS] < recommendations.json
#   ./audit-create-issues.sh [OPTIONS] --input recommendations.json
#
# Options:
#   --dry-run           Preview issues without creating them
#   --milestone NAME    Assign to specific milestone (defaults to active)
#   --skill NAME        Name of the source audit skill (e.g., "/audit:milestone")
#   --input FILE        Read recommendations from file instead of stdin
#   --min-severity LVL  Minimum severity to create issues (critical|high|medium|low)
#
# Input JSON format:
#   {
#     "recommendations": [
#       {
#         "id": "rec-001",
#         "action": "Short action title",
#         "severity": "high",
#         "description": "Detailed description of what needs to be done",
#         "type": "cleanup|quality|security|tech-debt|docs",
#         "item_reference": "#123"  // optional: issue/PR reference
#       }
#     ]
#   }
#
# Exit codes:
#   0 - Success
#   1 - Invalid arguments or input
#   2 - gh CLI error
#   3 - No recommendations in input

set -euo pipefail

DRY_RUN=false
MILESTONE=""
SKILL_NAME="audit"
INPUT_FILE=""
MIN_SEVERITY="low"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
success() { echo -e "${GREEN}✓${NC} $1"; }
info() { echo -e "${BLUE}ℹ${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
highlight() { echo -e "${CYAN}$1${NC}"; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --milestone)
            [[ -z "${2:-}" ]] && { error "Missing value for --milestone"; exit 1; }
            MILESTONE="$2"
            shift 2
            ;;
        --skill)
            [[ -z "${2:-}" ]] && { error "Missing value for --skill"; exit 1; }
            SKILL_NAME="$2"
            shift 2
            ;;
        --input)
            [[ -z "${2:-}" ]] && { error "Missing value for --input"; exit 1; }
            INPUT_FILE="$2"
            shift 2
            ;;
        --min-severity)
            [[ -z "${2:-}" ]] && { error "Missing value for --min-severity"; exit 1; }
            MIN_SEVERITY="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--milestone NAME] [--skill NAME] [--input FILE] [--min-severity LEVEL]"
            echo ""
            echo "Create GitHub issues from audit skill recommendations."
            echo ""
            echo "Input: JSON with 'recommendations' array (from stdin or --input file)"
            echo "Format: { recommendations: [{ id, action, severity, description, type, item_reference? }] }"
            echo ""
            echo "Severity levels: critical, high, medium, low"
            echo "Priority mapping: critical→P0, high→P1, medium→P2, low→P3"
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check gh CLI
if ! command -v gh &>/dev/null; then
    error "gh CLI not found"
    exit 2
fi
if ! gh auth status &>/dev/null; then
    error "gh CLI not authenticated"
    exit 2
fi

# Read input
INPUT_JSON=""
if [[ -n "$INPUT_FILE" ]]; then
    if [[ ! -f "$INPUT_FILE" ]]; then
        error "Input file not found: $INPUT_FILE"
        exit 1
    fi
    INPUT_JSON=$(cat "$INPUT_FILE")
else
    # Read from stdin (with timeout fallback)
    if [[ -t 0 ]]; then
        error "No input provided. Pipe JSON or use --input FILE"
        exit 1
    fi
    INPUT_JSON=$(cat)
fi

# Validate input JSON
if ! echo "$INPUT_JSON" | jq empty 2>/dev/null; then
    error "Invalid JSON input"
    exit 1
fi

# Extract recommendations
RECOMMENDATIONS=$(echo "$INPUT_JSON" | jq '.recommendations // []')
REC_COUNT=$(echo "$RECOMMENDATIONS" | jq 'length')

if [[ "$REC_COUNT" -eq 0 ]]; then
    info "No recommendations in input. Nothing to create."
    exit 3
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

# Severity ordering for filtering
severity_rank() {
    case "$1" in
        critical) echo 4 ;;
        high)     echo 3 ;;
        medium)   echo 2 ;;
        low|info) echo 1 ;;
        *)        echo 1 ;;
    esac
}

MIN_RANK=$(severity_rank "$MIN_SEVERITY")

# Severity to priority label mapping
severity_to_priority() {
    case "$1" in
        critical) echo "P0" ;;
        high)     echo "P1" ;;
        medium)   echo "P2" ;;
        low|info) echo "P3" ;;
        *)        echo "P2" ;;
    esac
}

# Type to category label mapping
type_to_label() {
    case "$1" in
        security)           echo "bug,security" ;;
        tech-debt|code)     echo "tech-debt" ;;
        docs)               echo "docs" ;;
        cleanup|structure)  echo "tech-debt" ;;
        quality)            echo "tech-debt" ;;
        *)                  echo "tech-debt" ;;
    esac
}

# Check for duplicate issues
check_duplicate() {
    local title="$1"
    local similar
    similar=$(./scripts/search-similar-issues.sh "$title" 3 2>/dev/null || echo "[]")
    echo "$similar"
}

echo ""
highlight "═══════════════════════════════════════════════════════════"
highlight "  Audit Issue Generator: $SKILL_NAME"
highlight "═══════════════════════════════════════════════════════════"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    highlight "DRY RUN MODE - Previewing issues (will not create)"
    echo ""
fi

CREATED_COUNT=0
SKIPPED_COUNT=0
FILTERED_COUNT=0

# Process each recommendation
while IFS= read -r rec; do
    rec_id=$(echo "$rec" | jq -r '.id // "rec-unknown"')
    action=$(echo "$rec" | jq -r '.action // "Audit finding"')
    severity=$(echo "$rec" | jq -r '.severity // "medium"')
    description=$(echo "$rec" | jq -r '.description // ""')
    type=$(echo "$rec" | jq -r '.type // "tech-debt"')
    item_ref=$(echo "$rec" | jq -r '.item_reference // ""')

    # Filter by minimum severity
    rec_rank=$(severity_rank "$severity")
    if [[ "$rec_rank" -lt "$MIN_RANK" ]]; then
        FILTERED_COUNT=$((FILTERED_COUNT + 1))
        continue
    fi

    # Build issue title
    issue_title="[Audit] $action"
    if [[ -n "$item_ref" ]]; then
        issue_title="[Audit] $action ($item_ref)"
    fi

    # Check for duplicates
    duplicates=$(check_duplicate "$issue_title")
    dup_count=$(echo "$duplicates" | jq 'length')

    if [[ "$dup_count" -gt 0 ]]; then
        warn "Skipping (similar issue exists): $issue_title"
        echo "$duplicates" | jq -r '.[] | "  - #\(.number): \(.title)"' >&2
        SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
        continue
    fi

    # Build labels
    priority=$(severity_to_priority "$severity")
    category_label=$(type_to_label "$type")
    labels="$category_label,backlog,priority:$priority"

    # Build issue body
    item_section=""
    if [[ -n "$item_ref" ]]; then
        item_section="
**Related:** $item_ref"
    fi

    body="## Summary

$description$item_section

## Context

- **Source:** $SKILL_NAME
- **Finding ID:** $rec_id
- **Severity:** $severity
- **Type:** $type
- **Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")

## Acceptance Criteria

- [ ] Issue identified by audit has been resolved
- [ ] Root cause addressed (not just symptoms)
- [ ] Changes verified and tested
- [ ] Documentation updated if applicable

## Notes

This issue was automatically generated from audit recommendations.
Run \`$SKILL_NAME\` to refresh findings after resolving."

    # Preview or create
    if [[ "$DRY_RUN" == "true" ]]; then
        highlight "───────────────────────────────────────────────────────────"
        echo "Title:     $issue_title"
        echo "Labels:    $labels"
        echo "Milestone: ${MILESTONE:-none}"
        echo "Severity:  $severity → priority:$priority"
        echo ""
        echo "$body"
        highlight "───────────────────────────────────────────────────────────"
        echo ""
        CREATED_COUNT=$((CREATED_COUNT + 1))
    else
        info "Creating: $issue_title"

        create_args=(
            --title "$issue_title"
            --body "$body"
            --label "$labels"
        )
        if [[ -n "$MILESTONE" ]]; then
            create_args+=(--milestone "$MILESTONE")
        fi

        issue_number=$(gh issue create "${create_args[@]}" --json number -q .number 2>/dev/null || echo "")

        if [[ -n "$issue_number" ]]; then
            issue_url=$(gh issue view "$issue_number" --json url -q .url 2>/dev/null || echo "")
            success "Created #$issue_number: $issue_title"
            [[ -n "$issue_url" ]] && echo "  URL: $issue_url"
            CREATED_COUNT=$((CREATED_COUNT + 1))
        else
            error "Failed to create issue: $issue_title"
        fi
    fi

done < <(echo "$RECOMMENDATIONS" | jq -c '.[]')

echo ""
highlight "═══════════════════════════════════════════════════════════"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN Summary:"
    echo "  Would create:  $CREATED_COUNT issues"
    echo "  Skipped (dup): $SKIPPED_COUNT"
    echo "  Filtered:      $FILTERED_COUNT (below --min-severity $MIN_SEVERITY)"
    echo ""
    info "Run without --dry-run to create issues."
else
    echo "Issue Creation Summary:"
    echo "  Created:       $CREATED_COUNT issues"
    echo "  Skipped (dup): $SKIPPED_COUNT"
    echo "  Filtered:      $FILTERED_COUNT (below --min-severity $MIN_SEVERITY)"
fi
highlight "═══════════════════════════════════════════════════════════"
