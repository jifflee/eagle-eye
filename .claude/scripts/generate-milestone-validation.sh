#!/bin/bash
set -euo pipefail
# generate-milestone-validation.sh
# Auto-generates a validation issue for milestone closure verification
#
# Usage:
#   ./scripts/generate-milestone-validation.sh                      # Generate for active milestone
#   ./scripts/generate-milestone-validation.sh "sprint-1/13"        # Generate for specific milestone
#   ./scripts/generate-milestone-validation.sh --dry-run            # Preview without creating issue
#   ./scripts/generate-milestone-validation.sh --force              # Recreate even if exists
#
# Returns:
#   0 - Success (validation issue created or already exists)
#   1 - Validation failed (no closed issues, milestone not found, etc.)
#   2 - Error (API failure, script error)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared logging utilities
if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
  source "${SCRIPT_DIR}/lib/common.sh"
else
  # Fallback logging functions if common.sh doesn't exist
  log_info() { echo "[INFO] $*"; }
  log_success() { echo "[SUCCESS] $*"; }
  log_warn() { echo "[WARN] $*"; }
  log_error() { echo "[ERROR] $*" >&2; }
fi

MILESTONE_NAME=""
DRY_RUN=false
FORCE=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      MILESTONE_NAME="$1"
      shift
      ;;
  esac
done

# Function to get milestone data
get_milestone() {
  local name="$1"

  if [ -n "$name" ]; then
    # Get specific milestone
    gh api repos/:owner/:repo/milestones --jq ".[] | select(.title==\"$name\")"
  else
    # Get first open milestone by due date
    gh api repos/:owner/:repo/milestones --jq '[.[] | select(.state=="open")] | sort_by(.due_on) | .[0]'
  fi
}

# Function to check if validation issue already exists
check_existing_validation() {
  local milestone_title="$1"
  local validation_title="Pre-Close Validation: $milestone_title"

  gh issue list \
    --label "milestone-validation" \
    --search "\"$validation_title\" in:title" \
    --json number,title,state \
    --jq '.[] | select(.title == "'"$validation_title"'") | .number' \
    2>/dev/null || echo ""
}

# Function to extract acceptance criteria from issue body
extract_acceptance_criteria() {
  local issue_number="$1"

  # Get issue body and extract lines with checkboxes
  gh issue view "$issue_number" --json body --jq '.body' 2>/dev/null | \
    grep -E '^\s*- \[[x ]\]' || echo ""
}

# Function to get linked PR for an issue
get_linked_pr() {
  local issue_number="$1"

  # Search for PRs that close this issue
  gh pr list --state all --search "closes:#$issue_number OR fixes:#$issue_number OR resolves:#$issue_number" \
    --json number,state,title --jq '.[0] // empty' 2>/dev/null || echo ""
}

# Main execution
log_info "Gathering milestone data..."

milestone_data=$(get_milestone "$MILESTONE_NAME")

if [ -z "$milestone_data" ] || [ "$milestone_data" = "null" ]; then
  log_error "No milestone found"
  exit 1
fi

# Extract milestone info
MILESTONE_TITLE=$(echo "$milestone_data" | jq -r '.title')
MILESTONE_NUMBER=$(echo "$milestone_data" | jq -r '.number')
MILESTONE_STATE=$(echo "$milestone_data" | jq -r '.state')

log_info "Processing milestone: $MILESTONE_TITLE (#$MILESTONE_NUMBER)"

# Check if validation issue already exists
EXISTING_ISSUE=$(check_existing_validation "$MILESTONE_TITLE")

if [ -n "$EXISTING_ISSUE" ] && [ "$FORCE" != true ]; then
  log_warn "Validation issue already exists: #$EXISTING_ISSUE"
  log_info "Use --force to recreate, or close the existing issue first"
  echo ""
  echo "Existing validation issue: #$EXISTING_ISSUE"
  echo "URL: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/issues/$EXISTING_ISSUE"
  exit 0
fi

# Get all closed issues in the milestone
log_info "Fetching closed issues from milestone..."
CLOSED_ISSUES=$(gh issue list \
  --milestone "$MILESTONE_TITLE" \
  --state closed \
  --json number,title,labels \
  --jq '.[]' 2>/dev/null)

if [ -z "$CLOSED_ISSUES" ] || [ "$CLOSED_ISSUES" = "null" ]; then
  log_warn "No closed issues found in milestone $MILESTONE_TITLE"
  log_info "Cannot create validation issue for empty milestone"
  exit 1
fi

# Count closed issues
CLOSED_COUNT=$(echo "$CLOSED_ISSUES" | jq -s 'length')
log_info "Found $CLOSED_COUNT closed issues"

# Build validation issue body
log_info "Generating validation checklist..."

ISSUE_BODY="## Pre-Close Validation: ${MILESTONE_TITLE}

This issue tracks validation of all completed work before milestone closure.

### Standard Checks
- [ ] \`git pull origin dev\` — clean pull, no conflicts
- [ ] \`./scripts/generate-manifest.sh\` — no errors
- [ ] \`./scripts/manifest-sync.sh --force\` — no errors
- [ ] \`/local:health\` — no critical issues
- [ ] All PRs merged to dev branch
- [ ] CI passing on dev branch

### Issue Deliverable Verification

"

# Process each closed issue
echo "$CLOSED_ISSUES" | jq -c '.' | while IFS= read -r issue_json; do
  ISSUE_NUM=$(echo "$issue_json" | jq -r '.number')
  ISSUE_TITLE=$(echo "$issue_json" | jq -r '.title')

  # Get linked PR
  LINKED_PR=$(get_linked_pr "$ISSUE_NUM")
  if [ -n "$LINKED_PR" ]; then
    PR_NUM=$(echo "$LINKED_PR" | jq -r '.number')
    PR_STATE=$(echo "$LINKED_PR" | jq -r '.state')
    PR_STATUS="PR: #$PR_NUM ($PR_STATE)"
  else
    PR_STATUS="PR: none found"
  fi

  # Get acceptance criteria
  ACCEPTANCE_CRITERIA=$(extract_acceptance_criteria "$ISSUE_NUM")

  # Add issue section to body
  echo "#### #${ISSUE_NUM} — ${ISSUE_TITLE}"
  echo "$PR_STATUS"

  if [ -n "$ACCEPTANCE_CRITERIA" ]; then
    # Convert checked boxes to unchecked for validation
    echo "$ACCEPTANCE_CRITERIA" | sed 's/- \[x\]/- [ ]/g' | sed 's/- \[ \]/- [ ]/g'
  else
    # No explicit acceptance criteria, add a generic verification checkbox
    echo "- [ ] Deliverable verified and functional"
  fi

  echo ""
done >> /tmp/milestone-validation-$$.txt

# Append the per-issue sections
ISSUE_BODY="${ISSUE_BODY}$(cat /tmp/milestone-validation-$$.txt)"

# Add final sign-off section
ISSUE_BODY="${ISSUE_BODY}
### Final Sign-Off
- [ ] All standard checks pass
- [ ] All deliverable checks pass
- [ ] No regressions identified
- [ ] Ready for milestone close

---

**Generated by:** \`scripts/generate-milestone-validation.sh\`
**Milestone:** ${MILESTONE_TITLE} (#${MILESTONE_NUMBER})
**Generated at:** $(date -u +%Y-%m-%dT%H:%M:%SZ)
"

# Clean up temp file
rm -f /tmp/milestone-validation-$$.txt

# Create the validation issue
VALIDATION_TITLE="Pre-Close Validation: ${MILESTONE_TITLE}"

if [ "$DRY_RUN" = true ]; then
  log_info "[DRY RUN] Would create validation issue with title:"
  echo "  $VALIDATION_TITLE"
  echo ""
  log_info "[DRY RUN] Issue body preview:"
  echo "----------------------------------------"
  echo "$ISSUE_BODY"
  echo "----------------------------------------"
  exit 0
fi

log_info "Creating validation issue..."

# If an existing issue was found and --force is set, close it first
if [ -n "$EXISTING_ISSUE" ] && [ "$FORCE" = true ]; then
  log_info "Closing existing validation issue #$EXISTING_ISSUE (--force mode)"
  gh issue close "$EXISTING_ISSUE" --comment "Superseded by regenerated validation issue" 2>/dev/null || true
fi

# Create the issue
ISSUE_URL=$(gh issue create \
  --title "$VALIDATION_TITLE" \
  --body "$ISSUE_BODY" \
  --label "milestone-validation,feature,backlog" \
  --milestone "$MILESTONE_TITLE" 2>&1)

if [ $? -eq 0 ]; then
  ISSUE_NUM=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$')
  log_success "Validation issue created: #$ISSUE_NUM"
  echo ""
  echo "=========================================="
  echo "  Validation Issue Created"
  echo "=========================================="
  echo ""
  echo "Issue: #$ISSUE_NUM"
  echo "URL:   $ISSUE_URL"
  echo "Title: $VALIDATION_TITLE"
  echo ""
  echo "Complete the validation checklist before closing milestone $MILESTONE_TITLE"
  exit 0
else
  log_error "Failed to create validation issue"
  echo "$ISSUE_URL" >&2
  exit 2
fi
