#!/usr/bin/env bash
# =============================================================================
# ci-label-update.sh - Update CI status labels on PRs (Issue #543)
# =============================================================================
# Usage: ./ci-label-update.sh <PR_NUMBER> <STATUS> [--reason "message"]
#
# STATUS can be: pending, running, passed, failed, blocked
#
# This script is designed to be called by external CI watchers (n8n, GitHub
# Actions, webhooks) to update the CI status labels on a PR.
#
# Label State Machine:
#   ci:pending  -> ci:running  (CI watcher picks up)
#   ci:running  -> ci:passed   (all checks pass)
#   ci:running  -> ci:failed   (some checks fail)
#   ci:running  -> ci:blocked  (merge conflicts, security issues)
#   ci:failed   -> ci:pending  (container pushes fix, resets for re-check)
#
# =============================================================================

set -euo pipefail

# All CI labels - exactly one should be present at a time
CI_LABELS=("ci:pending" "ci:running" "ci:passed" "ci:failed" "ci:blocked")

usage() {
    echo "Usage: $0 <PR_NUMBER> <STATUS> [--reason \"message\"]"
    echo ""
    echo "STATUS: pending | running | passed | failed | blocked"
    echo ""
    echo "Examples:"
    echo "  $0 123 running                    # CI watcher started"
    echo "  $0 123 passed                     # All checks passed"
    echo "  $0 123 failed --reason 'lint failed'  # Checks failed"
    echo "  $0 123 blocked --reason 'conflicts'   # Needs human review"
    exit 1
}

# Parse arguments
if [ $# -lt 2 ]; then
    usage
fi

PR_NUMBER="$1"
STATUS="$2"
REASON=""

shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --reason)
            REASON="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate status
case "$STATUS" in
    pending|running|passed|failed|blocked)
        TARGET_LABEL="ci:$STATUS"
        ;;
    *)
        echo "ERROR: Invalid status '$STATUS'"
        echo "Valid statuses: pending, running, passed, failed, blocked"
        exit 1
        ;;
esac

# Validate PR exists
if ! gh pr view "$PR_NUMBER" --json number >/dev/null 2>&1; then
    echo "ERROR: PR #$PR_NUMBER not found"
    exit 1
fi

# Get current labels
CURRENT_LABELS=$(gh pr view "$PR_NUMBER" --json labels --jq '.labels[].name' 2>/dev/null || echo "")

# Build remove list (all CI labels except target)
REMOVE_LABELS=""
for label in "${CI_LABELS[@]}"; do
    if [ "$label" != "$TARGET_LABEL" ] && echo "$CURRENT_LABELS" | grep -q "^${label}$"; then
        if [ -n "$REMOVE_LABELS" ]; then
            REMOVE_LABELS="$REMOVE_LABELS,$label"
        else
            REMOVE_LABELS="$label"
        fi
    fi
done

# Apply label changes
echo "Updating PR #$PR_NUMBER: status -> $STATUS"

# Remove old CI labels
if [ -n "$REMOVE_LABELS" ]; then
    echo "  Removing: $REMOVE_LABELS"
    gh pr edit "$PR_NUMBER" --remove-label "$REMOVE_LABELS" 2>/dev/null || true
fi

# Add new label
echo "  Adding: $TARGET_LABEL"
gh pr edit "$PR_NUMBER" --add-label "$TARGET_LABEL" 2>/dev/null || {
    echo "ERROR: Failed to add label $TARGET_LABEL"
    echo "Ensure the label exists in the repository"
    exit 1
}

# Add comment if reason provided
if [ -n "$REASON" ]; then
    COMMENT="**CI Status Update:** \`$STATUS\`

$REASON

---
_Updated by ci-label-update.sh_"

    gh pr comment "$PR_NUMBER" --body "$COMMENT"
    echo "  Added comment with reason"
fi

echo "Done: PR #$PR_NUMBER now has label $TARGET_LABEL"

# Output JSON for scripting
echo ""
echo "JSON_OUTPUT={\"pr\":$PR_NUMBER,\"status\":\"$STATUS\",\"label\":\"$TARGET_LABEL\"}"
