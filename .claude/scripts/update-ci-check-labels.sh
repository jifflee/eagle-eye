#!/usr/bin/env bash
# =============================================================================
# update-ci-check-labels.sh - Update CHECK_PASS/CHECK_FAIL labels (Issue #432)
# =============================================================================
# Usage: ./update-ci-check-labels.sh <PR_NUMBER> <STATUS> [--issue]
#
# STATUS can be: pass, fail
#
# This script updates the CHECK_PASS/CHECK_FAIL labels on PRs/issues after
# local CI validation completes. These labels replace GitHub Actions status
# and provide visibility into validation state.
#
# Label State Machine:
#   (no label)   -> CHECK_FAIL   (validation fails)
#   (no label)   -> CHECK_PASS   (validation passes)
#   CHECK_FAIL   -> CHECK_PASS   (fixes applied, re-validated)
#   CHECK_PASS   -> CHECK_FAIL   (new changes break validation)
#
# Related:
#   - Issue #432 - Add CHECK_PASS/CHECK_FAIL labels
#   - Issue #369 - Deprecated GitHub Actions
#   - Issue #371 - PR creation hook with validation
# =============================================================================

set -euo pipefail

# Label constants
LABEL_PASS="CHECK_PASS"
LABEL_FAIL="CHECK_FAIL"
ALL_CHECK_LABELS=("$LABEL_PASS" "$LABEL_FAIL")

usage() {
    echo "Usage: $0 <NUMBER> <STATUS> [--issue]"
    echo ""
    echo "STATUS: pass | fail"
    echo ""
    echo "Examples:"
    echo "  $0 123 pass                    # PR passed validation"
    echo "  $0 123 fail                    # PR failed validation"
    echo "  $0 456 pass --issue            # Issue validation passed"
    exit 1
}

# Parse arguments
if [ $# -lt 2 ]; then
    usage
fi

NUMBER="$1"
STATUS="$2"
IS_ISSUE=false

shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --issue)
            IS_ISSUE=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate status
case "$STATUS" in
    pass)
        TARGET_LABEL="$LABEL_PASS"
        REMOVE_LABEL="$LABEL_FAIL"
        ;;
    fail)
        TARGET_LABEL="$LABEL_FAIL"
        REMOVE_LABEL="$LABEL_PASS"
        ;;
    *)
        echo "ERROR: Invalid status '$STATUS'"
        echo "Valid statuses: pass, fail"
        exit 1
        ;;
esac

# Determine type
TYPE="pr"
GH_CMD="gh pr"
if [ "$IS_ISSUE" = true ]; then
    TYPE="issue"
    GH_CMD="gh issue"
fi

# Validate PR/issue exists
if ! $GH_CMD view "$NUMBER" --json number >/dev/null 2>&1; then
    echo "ERROR: ${TYPE^} #$NUMBER not found"
    exit 1
fi

# Get current labels
CURRENT_LABELS=$($GH_CMD view "$NUMBER" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

# Check if label already set correctly
if echo "$CURRENT_LABELS" | grep -q "^${TARGET_LABEL}$"; then
    echo "${TYPE^} #$NUMBER already has label $TARGET_LABEL"
    exit 0
fi

# Remove opposite label if present
if echo "$CURRENT_LABELS" | grep -q "^${REMOVE_LABEL}$"; then
    echo "Removing label: $REMOVE_LABEL from ${TYPE} #$NUMBER"
    $GH_CMD edit "$NUMBER" --remove-label "$REMOVE_LABEL" 2>/dev/null || true
fi

# Add new label
echo "Adding label: $TARGET_LABEL to ${TYPE} #$NUMBER"
$GH_CMD edit "$NUMBER" --add-label "$TARGET_LABEL" 2>/dev/null || {
    echo "ERROR: Failed to add label $TARGET_LABEL"
    echo "Ensure the label exists in the repository"
    echo "Run: gh label create \"$TARGET_LABEL\" --color <color> --description \"<desc>\""
    exit 1
}

echo "Done: ${TYPE^} #$NUMBER now has label $TARGET_LABEL"

# Output JSON for scripting
echo ""
echo "JSON_OUTPUT={\"${TYPE}\":$NUMBER,\"status\":\"$STATUS\",\"label\":\"$TARGET_LABEL\"}"
