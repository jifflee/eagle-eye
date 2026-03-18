#!/bin/bash
set -euo pipefail
# epic-decompose.sh
# Parse epic issue body and create child issues for each phase/section
# size-ok: epic decomposition with phase detection, child creation, and parent updates
#
# Usage:
#   ./scripts/epic-decompose.sh <epic_number>
#   ./scripts/epic-decompose.sh <epic_number> --dry-run
#
# Phase Detection Patterns (in priority order):
#   1. ## Phase N: Title - Explicit phases
#   2. ### N. Title - Numbered sections
#   3. ## Implementation sections with ### sub-headers
#   4. - [ ] Major task - Top-level checklist items (if no other patterns found)
#
# Exit codes:
#   0 = Success
#   1 = Invalid arguments
#   2 = Epic not found or not an epic
#   3 = No phases detected

set -e

# Source common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
    source "$SCRIPT_DIR/lib/common.sh"
else
    # Fallback logging
    log_info() { echo "[INFO] $*"; }
    log_warn() { echo "[WARN] $*" >&2; }
    log_error() { echo "[ERROR] $*" >&2; }
fi

# Parse arguments
EPIC_NUMBER=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -*)
            log_error "Unknown flag: $1"
            exit 1
            ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]] && [ -z "$EPIC_NUMBER" ]; then
                EPIC_NUMBER="$1"
            fi
            shift
            ;;
    esac
done

if [ -z "$EPIC_NUMBER" ]; then
    log_error "Usage: $0 <epic_number> [--dry-run]"
    exit 1
fi

# Fetch epic details
log_info "Fetching epic #$EPIC_NUMBER..."
EPIC_JSON=$(gh issue view "$EPIC_NUMBER" --json title,body,labels,milestone,state 2>/dev/null || echo "")

if [ -z "$EPIC_JSON" ] || [ "$EPIC_JSON" = "null" ]; then
    log_error "Epic #$EPIC_NUMBER not found"
    exit 2
fi

# Validate it's an epic
EPIC_LABELS=$(echo "$EPIC_JSON" | jq -r '.labels[].name' 2>/dev/null | tr '\n' ' ')
if ! echo "$EPIC_LABELS" | grep -qw "epic"; then
    log_error "Issue #$EPIC_NUMBER is not an epic (missing 'epic' label)"
    exit 2
fi

EPIC_TITLE=$(echo "$EPIC_JSON" | jq -r '.title // empty')
EPIC_BODY=$(echo "$EPIC_JSON" | jq -r '.body // empty')
EPIC_MILESTONE=$(echo "$EPIC_JSON" | jq -r '.milestone.title // empty')
EPIC_STATE=$(echo "$EPIC_JSON" | jq -r '.state // empty')

log_info "Epic: #$EPIC_NUMBER - $EPIC_TITLE"
log_info "Milestone: ${EPIC_MILESTONE:-none}"

if [ "$EPIC_STATE" = "CLOSED" ]; then
    log_warn "Epic is already closed"
fi

# Check for existing children
EXISTING_CHILDREN=$(gh issue list --label "parent:$EPIC_NUMBER" --json number,title,state 2>/dev/null || echo "[]")
EXISTING_COUNT=$(echo "$EXISTING_CHILDREN" | jq 'length')

if [ "$EXISTING_COUNT" -gt 0 ]; then
    log_warn "Epic already has $EXISTING_COUNT child issues:"
    echo "$EXISTING_CHILDREN" | jq -r '.[] | "  #\(.number): \(.title) [\(.state)]"'
    echo ""
fi

# Detect phases from body
log_info "Detecting phases..."

# Create temp file for phases
PHASES_FILE=$(mktemp)
trap "rm -f $PHASES_FILE" EXIT

# Pattern 1: ## Phase N: Title (explicit phases)
echo "$EPIC_BODY" | grep -E "^## Phase [0-9]+:" | while read -r line; do
    PHASE_NUM=$(echo "$line" | sed -E 's/^## Phase ([0-9]+):.*/\1/')
    PHASE_TITLE=$(echo "$line" | sed -E 's/^## Phase [0-9]+: *//')
    echo "explicit|$PHASE_NUM|$PHASE_TITLE" >> "$PHASES_FILE"
done

# If no explicit phases, try Pattern 2: ### N. Title (numbered sections)
if [ ! -s "$PHASES_FILE" ]; then
    echo "$EPIC_BODY" | grep -E "^### [0-9]+\." | while read -r line; do
        PHASE_NUM=$(echo "$line" | sed -E 's/^### ([0-9]+)\..*/\1/')
        PHASE_TITLE=$(echo "$line" | sed -E 's/^### [0-9]+\. *//')
        echo "numbered|$PHASE_NUM|$PHASE_TITLE" >> "$PHASES_FILE"
    done
fi

# If still no phases, try Pattern 3: ## Implementation with ### sub-headers
if [ ! -s "$PHASES_FILE" ]; then
    PHASE_NUM=0
    IN_IMPLEMENTATION=false
    while IFS= read -r line; do
        if echo "$line" | grep -qE "^## Implementation"; then
            IN_IMPLEMENTATION=true
            continue
        fi
        if [ "$IN_IMPLEMENTATION" = true ]; then
            if echo "$line" | grep -qE "^## "; then
                IN_IMPLEMENTATION=false
                continue
            fi
            if echo "$line" | grep -qE "^### "; then
                PHASE_NUM=$((PHASE_NUM + 1))
                PHASE_TITLE=$(echo "$line" | sed 's/^### *//')
                echo "implementation|$PHASE_NUM|$PHASE_TITLE" >> "$PHASES_FILE"
            fi
        fi
    done <<< "$EPIC_BODY"
fi

# If still no phases, try Pattern 4: Top-level checklist items
if [ ! -s "$PHASES_FILE" ]; then
    PHASE_NUM=0
    echo "$EPIC_BODY" | grep -E "^- \[ \] " | head -10 | while read -r line; do
        PHASE_NUM=$((PHASE_NUM + 1))
        PHASE_TITLE=$(echo "$line" | sed 's/^- \[ \] *//')
        echo "checklist|$PHASE_NUM|$PHASE_TITLE" >> "$PHASES_FILE"
    done
fi

# Count detected phases
PHASE_COUNT=$(wc -l < "$PHASES_FILE" | tr -d ' ')

if [ "$PHASE_COUNT" -eq 0 ]; then
    log_error "No phases detected in epic body"
    log_info "Supported patterns:"
    log_info "  - ## Phase N: Title"
    log_info "  - ### N. Title"
    log_info "  - ## Implementation with ### sub-headers"
    log_info "  - [ ] Top-level checklist items"
    exit 3
fi

log_info "Detected $PHASE_COUNT phases"

# Display detected phases
echo ""
echo "Phases to create:"
echo "─────────────────────────────────────────"
cat "$PHASES_FILE" | while IFS='|' read -r TYPE NUM TITLE; do
    echo "  Phase $NUM: $TITLE (detected via: $TYPE)"
done
echo "─────────────────────────────────────────"
echo ""

if [ "$DRY_RUN" = true ]; then
    log_info "DRY RUN - No issues will be created"
    echo ""
    echo "Would create $PHASE_COUNT child issues:"

    cat "$PHASES_FILE" | while IFS='|' read -r TYPE NUM TITLE; do
        echo "  - \"$EPIC_TITLE - Phase $NUM: $TITLE\""
        echo "    Labels: parent:$EPIC_NUMBER, phase:$NUM, feature, backlog"
        [ -n "$EPIC_MILESTONE" ] && echo "    Milestone: $EPIC_MILESTONE"
    done

    # Output JSON for programmatic use
    echo ""
    echo "JSON Output:"
    jq -n \
        --arg epic "$EPIC_NUMBER" \
        --arg title "$EPIC_TITLE" \
        --argjson count "$PHASE_COUNT" \
        --argjson existing "$EXISTING_COUNT" \
        '{
            epic: ($epic | tonumber),
            title: $title,
            phases_detected: $count,
            existing_children: $existing,
            dry_run: true,
            children_created: []
        }'
    exit 0
fi

# Create parent label if it doesn't exist
log_info "Ensuring parent:$EPIC_NUMBER label exists..."
gh label create "parent:$EPIC_NUMBER" --description "Child of epic #$EPIC_NUMBER" --color "0E8A16" 2>/dev/null || true

# Create phase labels if they don't exist
cat "$PHASES_FILE" | while IFS='|' read -r TYPE NUM TITLE; do
    gh label create "phase:$NUM" --description "Phase $NUM of epic" --color "1D76DB" 2>/dev/null || true
done

# Create child issues
CREATED_CHILDREN="[]"

cat "$PHASES_FILE" | while IFS='|' read -r TYPE NUM TITLE; do
    CHILD_TITLE="$EPIC_TITLE - Phase $NUM: $TITLE"

    log_info "Creating: $CHILD_TITLE"

    # Build child issue body
    CHILD_BODY="## Summary

Implement Phase $NUM of epic #$EPIC_NUMBER.

**Parent:** #$EPIC_NUMBER

## Context

This is part of the epic: **$EPIC_TITLE**

Phase $NUM focuses on: $TITLE

## Acceptance Criteria

- [ ] Phase $NUM implementation complete
- [ ] Tests added for new functionality
- [ ] Documentation updated if needed

---

*Created by /epic-decompose from epic #$EPIC_NUMBER*"

    # Build labels
    LABELS="parent:$EPIC_NUMBER,phase:$NUM,feature,backlog"

    # Create issue
    CREATE_ARGS=(--title "$CHILD_TITLE" --body "$CHILD_BODY" --label "$LABELS")

    if [ -n "$EPIC_MILESTONE" ]; then
        CREATE_ARGS+=(--milestone "$EPIC_MILESTONE")
    fi

    CHILD_URL=$(gh issue create "${CREATE_ARGS[@]}" 2>/dev/null)
    CHILD_NUM=$(echo "$CHILD_URL" | grep -oE '[0-9]+$')

    if [ -n "$CHILD_NUM" ]; then
        log_info "Created #$CHILD_NUM: $CHILD_TITLE"

        # Accumulate created children for JSON output
        CREATED_CHILDREN=$(echo "$CREATED_CHILDREN" | jq \
            --arg num "$CHILD_NUM" \
            --arg phase "$NUM" \
            --arg title "$TITLE" \
            '. + [{number: ($num | tonumber), phase: ($phase | tonumber), title: $title}]')
    else
        log_error "Failed to create child for Phase $NUM"
    fi
done

# Update epic body with child links
log_info "Updating epic with child links..."

# Build child issues section
CHILD_SECTION="## Child Issues

| Phase | Issue | Title | Status |
|-------|-------|-------|--------|"

# Re-read phases and add rows
cat "$PHASES_FILE" | while IFS='|' read -r TYPE NUM TITLE; do
    # Find the created child issue
    CHILD_ISSUE=$(gh issue list --label "parent:$EPIC_NUMBER" --label "phase:$NUM" --json number,state --jq '.[0] | "#\(.number) | \(.state)"' 2>/dev/null || echo "pending")
    CHILD_SECTION="$CHILD_SECTION
| $NUM | #TBD | $TITLE | Open |"
done

# Check if epic body already has Child Issues section
if echo "$EPIC_BODY" | grep -q "## Child Issues"; then
    log_info "Epic already has Child Issues section - adding comment instead"
    gh issue comment "$EPIC_NUMBER" --body "## Decomposition Complete

Created $PHASE_COUNT child issues for this epic.

Use \`/sprint-work --epic $EPIC_NUMBER\` to work through children in order."
else
    log_info "Would update epic body with child links (skipping to avoid body corruption)"
fi

# Output final JSON
echo ""
echo "═══════════════════════════════════════════"
echo "Decomposition Complete"
echo "═══════════════════════════════════════════"
echo ""

# Get actual created children
FINAL_CHILDREN=$(gh issue list --label "parent:$EPIC_NUMBER" --json number,title,state --jq '[.[] | {number, title, state}]' 2>/dev/null || echo "[]")
FINAL_COUNT=$(echo "$FINAL_CHILDREN" | jq 'length')

jq -n \
    --arg epic "$EPIC_NUMBER" \
    --arg title "$EPIC_TITLE" \
    --argjson detected "$PHASE_COUNT" \
    --argjson existing "$EXISTING_COUNT" \
    --argjson children "$FINAL_CHILDREN" \
    '{
        epic: ($epic | tonumber),
        title: $title,
        phases_detected: $detected,
        existing_children_before: $existing,
        total_children_after: ($children | length),
        dry_run: false,
        children: $children
    }'

log_info "Done! Use '/sprint-work --epic $EPIC_NUMBER' to work through children"
