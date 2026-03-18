#!/bin/bash
set -euo pipefail
# container-preflight.sh
# Pre-launch validation for containers with dependency and epic checks
# size-ok: multi-phase preflight with dependency, overlap, and epic context checks
#
# PURPOSE:
#   Runs on the HOST before launching a container to:
#   - Check for blocking dependencies
#   - Detect active dependencies (work in progress in other containers)
#   - Identify related issues with potential file overlap
#   - Generate epic context if working on epic children
#   - Cache sprint state for container injection
#
# USAGE:
#   ./scripts/container-preflight.sh --issue <N> [OPTIONS]
#   ./scripts/container-preflight.sh --epic <N> [OPTIONS]
#
# OPTIONS:
#   --issue <N>        Issue number to validate
#   --epic <N>         Epic number to get child context
#   --child <N>        Specific child of epic to work on
#   --force            Proceed despite warnings (for meta-fixes)
#   --json             Output JSON only (for scripting)
#   --no-cache         Skip state caching
#
# OUTPUT (JSON):
#   {
#     "action": "continue|warn|block",
#     "issue": {...},
#     "dependencies": {...},
#     "epic_context": {...},
#     "warnings": [...],
#     "blockers": [...],
#     "sprint_state_file": "path/to/.sprint-state.json"
#   }
#
# EXIT CODES:
#   0 - Continue (no blockers)
#   1 - Blocked (user intervention required)
#   2 - Error (invalid arguments, API failure)

set -e

# Script metadata
SCRIPT_NAME="container-preflight.sh"
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
source "${SCRIPT_DIR}/../lib/common.sh"

# Usage
usage() {
    cat << EOF >&2
$SCRIPT_NAME v$VERSION - Pre-launch validation for containers

USAGE:
    $SCRIPT_NAME --issue <N> [OPTIONS]
    $SCRIPT_NAME --epic <N> [OPTIONS]

OPTIONS:
    --issue <N>        Issue number to validate
    --epic <N>         Epic number to get child context
    --child <N>        Specific child of epic to work on
    --force            Proceed despite warnings
    --json             Output JSON only
    --no-cache         Skip state caching

EXAMPLES:
    # Validate issue before container launch
    $SCRIPT_NAME --issue 132

    # Get epic context for container
    $SCRIPT_NAME --epic 128 --child 132

    # Force proceed (for meta-fixes)
    $SCRIPT_NAME --issue 26 --force
EOF
    exit 2
}

# Parse arguments
ISSUE_NUMBER=""
EPIC_NUMBER=""
CHILD_NUMBER=""
FORCE=false
JSON_ONLY=false
NO_CACHE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issue)
            ISSUE_NUMBER="$2"
            shift 2
            ;;
        --epic)
            EPIC_NUMBER="$2"
            shift 2
            ;;
        --child)
            CHILD_NUMBER="$2"
            shift 2
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --json)
            JSON_ONLY=true
            shift
            ;;
        --no-cache)
            NO_CACHE=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate arguments
if [[ -z "$ISSUE_NUMBER" ]] && [[ -z "$EPIC_NUMBER" ]]; then
    log_error "Either --issue or --epic is required"
    usage
fi

# If epic mode with child, use child as issue
if [[ -n "$EPIC_NUMBER" ]] && [[ -n "$CHILD_NUMBER" ]]; then
    ISSUE_NUMBER="$CHILD_NUMBER"
fi

# Initialize result object
WARNINGS=()
BLOCKERS=()
ACTION="continue"

# ============================================================================
# STEP 1: VALIDATE ISSUE EXISTS
# ============================================================================

if [[ -n "$ISSUE_NUMBER" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "Validating issue #$ISSUE_NUMBER..."

    ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --json number,title,state,labels,body 2>/dev/null) || {
        log_error "Issue #$ISSUE_NUMBER not found"
        jq -n --arg issue "$ISSUE_NUMBER" '{
            action: "error",
            error: "Issue not found",
            issue: $issue
        }'
        exit 2
    }

    # Check if issue is closed
    ISSUE_STATE=$(echo "$ISSUE_DATA" | jq -r '.state')
    if [[ "$ISSUE_STATE" == "CLOSED" ]]; then
        log_error "Issue #$ISSUE_NUMBER is already closed"
        BLOCKERS+=("Issue is already closed")
        ACTION="block"
    fi
fi

# ============================================================================
# STEP 2: CHECK DEPENDENCIES
# ============================================================================

DEPS_DATA='{}'
if [[ -n "$ISSUE_NUMBER" ]] && [[ -x "$SCRIPT_DIR/issue-dependencies.sh" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "Checking dependencies..."

    DEPS_DATA=$("$SCRIPT_DIR/issue-dependencies.sh" "$ISSUE_NUMBER" 2>/dev/null) || DEPS_DATA='{}'

    # Check for open dependencies (blocking)
    OPEN_DEPS=$(echo "$DEPS_DATA" | jq -r '.dependencies.depends_on // [] | map(select(.state == "OPEN")) | length' 2>/dev/null || echo "0")
    if [[ "$OPEN_DEPS" -gt 0 ]]; then
        DEP_NUMS=$(echo "$DEPS_DATA" | jq -r '.dependencies.depends_on // [] | map(select(.state == "OPEN")) | map("#\(.number)") | join(", ")' 2>/dev/null)
        WARNINGS+=("Has $OPEN_DEPS open dependency(ies): $DEP_NUMS")
        [[ "$JSON_ONLY" != "true" ]] && log_warn "Open dependencies: $DEP_NUMS"
    fi

    # Check for active dependencies (in-progress in other containers/worktrees)
    # Query for issues with in-progress or wip:checked-out labels
    ACTIVE_ISSUES=$(gh issue list --label "in-progress" --state open --json number --jq '.[].number' 2>/dev/null || echo "")
    CHECKED_OUT=$(gh issue list --label "wip:checked-out" --state open --json number --jq '.[].number' 2>/dev/null || echo "")

    # Check if any dependencies are actively being worked on
    for dep_num in $(echo "$DEPS_DATA" | jq -r '.dependencies.depends_on[]?.number // empty' 2>/dev/null); do
        if echo "$ACTIVE_ISSUES $CHECKED_OUT" | grep -qw "$dep_num"; then
            WARNINGS+=("Dependency #$dep_num is actively being worked on")
            [[ "$JSON_ONLY" != "true" ]] && log_warn "Dependency #$dep_num is in progress"
        fi
    done

    # Check for related issues (potential file overlap)
    RELATED_COUNT=$(echo "$DEPS_DATA" | jq -r '.dependencies.related_to // [] | length' 2>/dev/null || echo "0")
    if [[ "$RELATED_COUNT" -gt 0 ]]; then
        REL_NUMS=$(echo "$DEPS_DATA" | jq -r '.dependencies.related_to // [] | map("#\(.number)") | join(", ")' 2>/dev/null)
        WARNINGS+=("Related issues (may have file overlap): $REL_NUMS")
        [[ "$JSON_ONLY" != "true" ]] && log_warn "Related issues: $REL_NUMS"
    fi
fi

# ============================================================================
# STEP 3: CHECK CONTAINER CONFLICTS
# ============================================================================

[[ "$JSON_ONLY" != "true" ]] && log_info "Checking for container conflicts..."

# Check if a container for this issue is already running
CONTAINER_NAME="claude-tastic-issue-${ISSUE_NUMBER:-$EPIC_NUMBER}"
if docker ps --filter "name=$CONTAINER_NAME" --format '{{.Names}}' 2>/dev/null | grep -q "^$CONTAINER_NAME$"; then
    BLOCKERS+=("Container '$CONTAINER_NAME' is already running")
    ACTION="block"
    [[ "$JSON_ONLY" != "true" ]] && log_error "Container already running: $CONTAINER_NAME"
fi

# STEP 3.5: PREDICT FILE CONFLICTS WITH RUNNING WORK
# ============================================================================

CONFLICT_PREDICTION='{}'
if [[ -n "$ISSUE_NUMBER" ]] && [[ -x "$SCRIPT_DIR/predict-conflicts.sh" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "Predicting potential file conflicts..."

    # Run conflict prediction with recording enabled
    CONFLICT_PREDICTION=$("$SCRIPT_DIR/predict-conflicts.sh" --issue "$ISSUE_NUMBER" --json --record 2>/dev/null) || CONFLICT_PREDICTION='{}'

    # Extract prediction results
    CONFLICT_ACTION=$(echo "$CONFLICT_PREDICTION" | jq -r '.action // "continue"')
    CONFLICT_COUNT=$(echo "$CONFLICT_PREDICTION" | jq -r '.conflicts | length // 0')

    if [[ "$CONFLICT_ACTION" == "block" ]] && [[ "$FORCE" != "true" ]]; then
        # High conflict risk - add blocker
        CONFLICT_RECOMMENDATION=$(echo "$CONFLICT_PREDICTION" | jq -r '.recommendation // "High conflict risk detected"')
        BLOCKERS+=("$CONFLICT_RECOMMENDATION")
        ACTION="block"
        [[ "$JSON_ONLY" != "true" ]] && log_error "Conflict prediction: $CONFLICT_RECOMMENDATION"

        # List conflicting issues
        if [[ "$CONFLICT_COUNT" -gt 0 ]]; then
            echo "$CONFLICT_PREDICTION" | jq -r '.conflicts[] | "  - Issue #\(.issue): \(.title) (score: \(.score))"' 2>/dev/null | while read -r line; do
                [[ "$JSON_ONLY" != "true" ]] && log_error "$line"
            done
        fi
    elif [[ "$CONFLICT_ACTION" == "warn" ]] && [[ "$CONFLICT_COUNT" -gt 0 ]]; then
        # Moderate conflict risk - add warning
        CONFLICT_RECOMMENDATION=$(echo "$CONFLICT_PREDICTION" | jq -r '.recommendation // "Moderate conflict risk detected"')
        WARNINGS+=("$CONFLICT_RECOMMENDATION")
        [[ "$JSON_ONLY" != "true" ]] && log_warn "Conflict prediction: $CONFLICT_RECOMMENDATION"

        # List potentially conflicting issues
        echo "$CONFLICT_PREDICTION" | jq -r '.conflicts[] | "  - Issue #\(.issue): \(.title) (score: \(.score))"' 2>/dev/null | while read -r line; do
            [[ "$JSON_ONLY" != "true" ]] && log_warn "$line"
        done
    else
        [[ "$JSON_ONLY" != "true" ]] && log_info "No significant conflict risk detected"
    fi
fi

# ============================================================================
# STEP 4: ARCHITECTURE VALIDATION (Feature #608)
# ============================================================================

[[ "$JSON_ONLY" != "true" ]] && log_info "Validating architecture alignment..."

# Run architecture validation if available
if [[ -n "$ISSUE_NUMBER" ]] && [[ -x "$SCRIPT_DIR/validate-issue-architecture.sh" ]]; then
    ARCH_VALIDATION=$("$SCRIPT_DIR/validate-issue-architecture.sh" --issue "$ISSUE_NUMBER" --json 2>/dev/null) || {
        log_warn "Architecture validation failed to run"
        ARCH_VALIDATION='{"valid": true, "blockers": [], "warnings": []}'
    }

    # Extract validation results
    ARCH_VALID=$(echo "$ARCH_VALIDATION" | jq -r '.valid // true')
    ARCH_BLOCKERS=$(echo "$ARCH_VALIDATION" | jq -r '.blockers // [] | .[]' 2>/dev/null)
    ARCH_WARNINGS=$(echo "$ARCH_VALIDATION" | jq -r '.warnings // [] | .[]' 2>/dev/null)
    ARCH_SUGGESTIONS=$(echo "$ARCH_VALIDATION" | jq -r '.suggestions // [] | .[]' 2>/dev/null)

    # Add architecture blockers to main blocker list
    if [[ "$ARCH_VALID" == "false" ]]; then
        while IFS= read -r blocker; do
            [[ -n "$blocker" ]] && BLOCKERS+=("ARCHITECTURE: $blocker")
            [[ "$JSON_ONLY" != "true" ]] && log_error "Architecture blocker: $blocker"
        done <<< "$ARCH_BLOCKERS"

        # Add suggestions to warnings for user visibility
        while IFS= read -r suggestion; do
            [[ -n "$suggestion" ]] && WARNINGS+=("SUGGESTION: $suggestion")
            [[ "$JSON_ONLY" != "true" ]] && log_warn "Suggestion: $suggestion"
        done <<< "$ARCH_SUGGESTIONS"
    fi

    # Add architecture warnings
    while IFS= read -r warning; do
        [[ -n "$warning" ]] && WARNINGS+=("ARCHITECTURE: $warning")
        [[ "$JSON_ONLY" != "true" ]] && log_warn "Architecture warning: $warning"
    done <<< "$ARCH_WARNINGS"

    [[ "$JSON_ONLY" != "true" ]] && [[ "$ARCH_VALID" == "true" ]] && log_info "✓ Architecture validation passed"
else
    [[ "$JSON_ONLY" != "true" ]] && log_debug "Skipping architecture validation (not available or no issue number)"
fi

# ============================================================================
# STEP 5: GET EPIC CONTEXT (if applicable)
# ============================================================================

EPIC_CONTEXT='{"is_epic": false}'
if [[ -n "$EPIC_NUMBER" ]] && [[ -x "$SCRIPT_DIR/detect-epic-children.sh" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "Getting epic context for #$EPIC_NUMBER..."

    # Check for last-check timestamp file
    EPIC_CHECK_FILE="${SCRIPT_DIR}/../.epic-${EPIC_NUMBER}-check"

    if [[ -f "$EPIC_CHECK_FILE" ]]; then
        EPIC_CONTEXT=$("$SCRIPT_DIR/detect-epic-children.sh" "$EPIC_NUMBER" --since-file "$EPIC_CHECK_FILE" 2>/dev/null) || EPIC_CONTEXT='{"is_epic": false}'
    else
        EPIC_CONTEXT=$("$SCRIPT_DIR/detect-epic-children.sh" "$EPIC_NUMBER" 2>/dev/null) || EPIC_CONTEXT='{"is_epic": false}'
    fi

    # Check for new children since last check
    NEW_CHILDREN=$(echo "$EPIC_CONTEXT" | jq -r '.children.new_since_check // 0')
    if [[ "$NEW_CHILDREN" -gt 0 ]]; then
        WARNINGS+=("$NEW_CHILDREN new child issue(s) created since last check")
        [[ "$JSON_ONLY" != "true" ]] && log_warn "$NEW_CHILDREN new child issue(s) detected"
    fi

    # Show epic progress
    EPIC_PERCENT=$(echo "$EPIC_CONTEXT" | jq -r '.children.percent_complete // 0')
    EPIC_TOTAL=$(echo "$EPIC_CONTEXT" | jq -r '.children.total // 0')
    EPIC_CLOSED=$(echo "$EPIC_CONTEXT" | jq -r '.children.closed // 0')
    [[ "$JSON_ONLY" != "true" ]] && log_info "Epic progress: $EPIC_CLOSED/$EPIC_TOTAL children closed ($EPIC_PERCENT%)"
fi

# If issue is part of an epic (has parent:N label), get parent epic context
if [[ -n "$ISSUE_NUMBER" ]]; then
    PARENT_LABEL=$(echo "$ISSUE_DATA" | jq -r '.labels[].name' 2>/dev/null | grep "^parent:" | head -1)
    if [[ -n "$PARENT_LABEL" ]]; then
        PARENT_EPIC=$(echo "$PARENT_LABEL" | sed 's/parent://')
        [[ "$JSON_ONLY" != "true" ]] && log_info "Issue is child of epic #$PARENT_EPIC"

        if [[ -z "$EPIC_NUMBER" ]] && [[ -x "$SCRIPT_DIR/detect-epic-children.sh" ]]; then
            EPIC_CONTEXT=$("$SCRIPT_DIR/detect-epic-children.sh" "$PARENT_EPIC" 2>/dev/null) || EPIC_CONTEXT='{"is_epic": false}'
            EPIC_NUMBER="$PARENT_EPIC"
        fi
    fi
fi

# ============================================================================
# STEP 6: CACHE SPRINT STATE
# ============================================================================

SPRINT_STATE_FILE=""
if [[ "$NO_CACHE" != "true" ]] && [[ -n "$ISSUE_NUMBER" ]]; then
    [[ "$JSON_ONLY" != "true" ]] && log_info "Caching sprint state..."

    # Determine output location
    SPRINT_STATE_FILE="${PWD}/.sprint-state.json"

    if [[ -x "$SCRIPT_DIR/generate-sprint-state.sh" ]]; then
        "$SCRIPT_DIR/generate-sprint-state.sh" "$ISSUE_NUMBER" --output "$SPRINT_STATE_FILE" >/dev/null 2>&1 || {
            log_warn "Failed to cache sprint state"
            SPRINT_STATE_FILE=""
        }
    fi
fi

# ============================================================================
# STEP 7: DETERMINE ACTION
# ============================================================================

# If blockers exist and not forced, action is block
if [[ ${#BLOCKERS[@]} -gt 0 ]] && [[ "$FORCE" != "true" ]]; then
    ACTION="block"
elif [[ ${#WARNINGS[@]} -gt 0 ]] && [[ "$FORCE" != "true" ]]; then
    ACTION="warn"
else
    ACTION="continue"
fi

# ============================================================================
# STEP 7: OUTPUT RESULT
# ============================================================================

# Convert bash arrays to JSON
WARNINGS_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s '.')
BLOCKERS_JSON=$(printf '%s\n' "${BLOCKERS[@]}" | jq -R . | jq -s '.')

# Build final JSON output
RESULT=$(jq -n \
    --arg action "$ACTION" \
    --arg issue_number "${ISSUE_NUMBER:-}" \
    --arg epic_number "${EPIC_NUMBER:-}" \
    --arg sprint_state_file "${SPRINT_STATE_FILE:-}" \
    --argjson issue "${ISSUE_DATA:-null}" \
    --argjson dependencies "$DEPS_DATA" \
    --argjson epic_context "$EPIC_CONTEXT" \
    --argjson conflict_prediction "$CONFLICT_PREDICTION" \
    --argjson warnings "$WARNINGS_JSON" \
    --argjson blockers "$BLOCKERS_JSON" \
    '{
        action: $action,
        issue_number: (if $issue_number != "" then ($issue_number | tonumber) else null end),
        epic_number: (if $epic_number != "" then ($epic_number | tonumber) else null end),
        issue: $issue,
        dependencies: $dependencies.dependencies // {},
        epic_context: $epic_context,
        conflict_prediction: $conflict_prediction,
        warnings: ($warnings | map(select(. != ""))),
        blockers: ($blockers | map(select(. != ""))),
        sprint_state_file: (if $sprint_state_file != "" then $sprint_state_file else null end)
    }')

echo "$RESULT"

# ============================================================================
# STEP 8: USER INTERACTION (if warnings/blockers and not JSON-only)
# ============================================================================

if [[ "$JSON_ONLY" != "true" ]]; then
    echo "" >&2

    if [[ "$ACTION" == "block" ]]; then
        log_error "Container launch BLOCKED"
        for blocker in "${BLOCKERS[@]}"; do
            echo -e "  ${RED}✗${NC} $blocker" >&2
        done
        echo "" >&2
        echo -e "Use ${YELLOW}--force${NC} to override (not recommended)" >&2
        exit 1
    elif [[ "$ACTION" == "warn" ]]; then
        log_warn "Warnings detected:"
        for warning in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}!${NC} $warning" >&2
        done
        echo "" >&2
        echo -e "${GREEN}Pre-flight complete. Proceed with container launch.${NC}" >&2
    else
        log_info "Pre-flight complete. No issues detected."
    fi
fi

exit 0
