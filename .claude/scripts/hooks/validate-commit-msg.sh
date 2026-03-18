#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# validate-commit-msg.sh - Conventional commit message validator
# =============================================================================
# Usage: ./validate-commit-msg.sh <commit-message>
#        ./validate-commit-msg.sh --file <commit-msg-file>
#
# Validates commit messages against Conventional Commits specification:
#   https://www.conventionalcommits.org/
#
# Format: type(scope): description
#
# Valid types: feat, fix, docs, style, refactor, test, chore, ci, perf, build
# Scope: optional, lowercase, alphanumeric with hyphens
# Description: required, lowercase first letter, imperative mood
#
# Exit Codes:
#   0 - Valid commit message
#   1 - Invalid commit message
#   2 - Error
#
# Related:
#   - Issue #1029 - repo-automation-bots pattern evaluation
#   - docs/REPO_AUTOMATION_BOTS_EVALUATION.md
#   - docs/standards/COMMIT_CONVENTIONS.md
# =============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Valid commit types (aligned with Conventional Commits)
VALID_TYPES=(
    "feat"      # New feature
    "fix"       # Bug fix
    "docs"      # Documentation
    "style"     # Code style (formatting, missing semicolons, etc)
    "refactor"  # Code refactoring
    "perf"      # Performance improvement
    "test"      # Adding tests
    "build"     # Build system changes
    "ci"        # CI configuration
    "chore"     # Maintenance tasks
    "revert"    # Revert previous commit
)

usage() {
    echo "Usage: $0 <commit-message>"
    echo "       $0 --file <commit-msg-file>"
    echo ""
    echo "Validates commit message against Conventional Commits specification."
    echo ""
    echo "Format: type(scope): description"
    echo ""
    echo "Valid types: ${VALID_TYPES[*]}"
    echo ""
    echo "Examples:"
    echo "  feat: add auto-merge label support"
    echo "  fix(deps): resolve lodash vulnerability"
    echo "  docs: update PR workflow guide"
    echo "  refactor(api): simplify error handling"
    echo ""
    exit 2
}

# Parse arguments
MESSAGE=""
FROM_FILE=false

if [[ $# -eq 0 ]]; then
    usage
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --file|-f)
            if [[ -z "$2" ]]; then
                echo "Error: --file requires a file path" >&2
                usage
            fi
            if [[ ! -f "$2" ]]; then
                echo "Error: File not found: $2" >&2
                exit 2
            fi
            MESSAGE=$(cat "$2")
            FROM_FILE=true
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$MESSAGE" ]]; then
                MESSAGE="$1"
            else
                echo "Error: Unknown argument: $1" >&2
                usage
            fi
            shift
            ;;
    esac
done

if [[ -z "$MESSAGE" ]]; then
    echo "Error: No commit message provided" >&2
    usage
fi

# Get first line of commit message (ignore subsequent lines)
FIRST_LINE=$(echo "$MESSAGE" | head -n 1)

# Skip validation for merge commits
if [[ "$FIRST_LINE" =~ ^Merge\ (branch|pull\ request|remote-tracking\ branch) ]]; then
    echo -e "${GREEN}✓${NC} Merge commit - skipping validation"
    exit 0
fi

# Skip validation for revert commits
if [[ "$FIRST_LINE" =~ ^Revert\ \" ]]; then
    echo -e "${GREEN}✓${NC} Revert commit - skipping validation"
    exit 0
fi

# Skip validation for Co-authored-by trailers (allow them in multi-line commits)
if [[ "$FIRST_LINE" =~ ^Co-authored-by: ]]; then
    echo -e "${GREEN}✓${NC} Co-authored-by trailer - skipping validation"
    exit 0
fi

# Conventional Commits pattern: type(scope): description
# or: type: description
PATTERN='^([a-z]+)(\([a-z0-9-]+\))?: .+'

if ! [[ "$FIRST_LINE" =~ $PATTERN ]]; then
    echo -e "${RED}✗ Invalid commit message format${NC}" >&2
    echo "" >&2
    echo "Commit message:" >&2
    echo "  $FIRST_LINE" >&2
    echo "" >&2
    echo "Expected format: ${BLUE}type(scope): description${NC}" >&2
    echo "  or: ${BLUE}type: description${NC}" >&2
    echo "" >&2
    echo "Valid types: ${VALID_TYPES[*]}" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  ${GREEN}feat: add auto-merge label support${NC}" >&2
    echo "  ${GREEN}fix(deps): resolve lodash vulnerability${NC}" >&2
    echo "  ${GREEN}docs: update PR workflow guide${NC}" >&2
    echo "  ${GREEN}refactor(api): simplify error handling${NC}" >&2
    echo "" >&2
    echo "See: docs/standards/COMMIT_CONVENTIONS.md" >&2
    echo "" >&2
    exit 1
fi

# Extract type and validate
TYPE=$(echo "$FIRST_LINE" | sed -n 's/^\([a-z]\+\).*/\1/p')

if [[ -z "$TYPE" ]]; then
    echo -e "${RED}✗ Failed to extract commit type${NC}" >&2
    exit 1
fi

# Check if type is valid
VALID=false
for valid_type in "${VALID_TYPES[@]}"; do
    if [[ "$TYPE" == "$valid_type" ]]; then
        VALID=true
        break
    fi
done

if ! $VALID; then
    echo -e "${RED}✗ Invalid commit type: $TYPE${NC}" >&2
    echo "" >&2
    echo "Valid types: ${VALID_TYPES[*]}" >&2
    echo "" >&2
    echo "Did you mean one of these?" >&2
    # Suggest similar types
    case "$TYPE" in
        feature|features) echo "  - ${GREEN}feat${NC} (new feature)" >&2 ;;
        bug|bugfix) echo "  - ${GREEN}fix${NC} (bug fix)" >&2 ;;
        doc|documentation) echo "  - ${GREEN}docs${NC} (documentation)" >&2 ;;
        *) echo "  - See valid types above" >&2 ;;
    esac
    echo "" >&2
    exit 1
fi

# Check for uppercase type (common mistake)
if [[ "$FIRST_LINE" =~ ^[A-Z] ]]; then
    echo -e "${RED}✗ Commit type must be lowercase${NC}" >&2
    echo "  Got: $FIRST_LINE" >&2
    echo "  Fix: ${GREEN}${FIRST_LINE,}${NC}" >&2
    exit 1
fi

# Check for uppercase scope (if present)
if [[ "$FIRST_LINE" =~ \([A-Z] ]]; then
    echo -e "${RED}✗ Scope must be lowercase${NC}" >&2
    echo "  Got: $FIRST_LINE" >&2
    FIXED=$(echo "$FIRST_LINE" | sed 's/(\([^)]*\))/(\L\1)/')
    echo "  Fix: ${GREEN}${FIXED}${NC}" >&2
    exit 1
fi

# Check description length (warn if too short)
DESCRIPTION=$(echo "$FIRST_LINE" | sed -n 's/^[a-z]\+\([^:]*\): \(.*\)/\2/p')

if [[ ${#DESCRIPTION} -lt 10 ]]; then
    echo -e "${YELLOW}⚠ Description is quite short (${#DESCRIPTION} chars)${NC}" >&2
    echo "  Consider providing more context" >&2
    echo "  Got: $DESCRIPTION" >&2
    # This is just a warning, not an error
fi

# Check for period at end (discouraged in Conventional Commits)
if [[ "$DESCRIPTION" =~ \.$ ]]; then
    echo -e "${YELLOW}⚠ Description should not end with a period${NC}" >&2
    echo "  Got: $DESCRIPTION" >&2
    echo "  Fix: ${GREEN}${DESCRIPTION%.}${NC}" >&2
    # This is just a warning, not an error
fi

# All checks passed
echo -e "${GREEN}✓${NC} Valid conventional commit message"
exit 0
