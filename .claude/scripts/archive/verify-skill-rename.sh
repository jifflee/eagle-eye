#!/usr/bin/env bash
#
# verify-skill-rename.sh - Verify skill rename was successful
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Verifying skill rename..."
echo ""

# Test 1: Check for old hyphenated names
echo "Test 1: Checking for old hyphenated skill names..."
OLD_FILES=$(find "$REPO_DIR/core/commands" "$REPO_DIR/.claude/commands" -name "*-*.md" -type f | grep -v ":" || true)
if [ -z "$OLD_FILES" ]; then
    echo -e "  ${GREEN}✓ No old hyphenated files found${NC}"
else
    echo -e "  ${RED}✗ Found old hyphenated files:${NC}"
    echo "$OLD_FILES"
    exit 1
fi

# Test 2: Count colon-separated files
echo ""
echo "Test 2: Counting colon-separated files..."
CORE_COUNT=$(find "$REPO_DIR/core/commands" -name "*:*.md" -type f | wc -l)
CLAUDE_COUNT=$(find "$REPO_DIR/.claude/commands" -name "*:*.md" -type f | wc -l)

echo "  core/commands/: $CORE_COUNT files"
echo "  .claude/commands/: $CLAUDE_COUNT files"

if [ "$CORE_COUNT" -eq 63 ] && [ "$CLAUDE_COUNT" -eq 63 ]; then
    echo -e "  ${GREEN}✓ File counts match expected (63 each)${NC}"
else
    echo -e "  ${RED}✗ File counts don't match expected (63 each)${NC}"
    exit 1
fi

# Test 3: Check for old references in skill files
echo ""
echo "Test 3: Checking for old hyphenated references..."
OLD_REFS=$(grep -r "/issue-\|/pr-\|/release-\|/milestone-\|/ops-\|/audit-\|/local-\|/sprint-\|/tool-\|/repo-" "$REPO_DIR/core/commands" --include="*.md" || true)
if [ -z "$OLD_REFS" ]; then
    echo -e "  ${GREEN}✓ No old hyphenated references found${NC}"
else
    echo -e "  ${YELLOW}⚠ Found some old references (may need review):${NC}"
    echo "$OLD_REFS" | head -10
fi

# Test 4: Verify manifest exists and is valid
echo ""
echo "Test 4: Verifying manifest..."
MANIFEST="$REPO_DIR/.claude/.manifest.json"
if [ -f "$MANIFEST" ]; then
    if jq empty "$MANIFEST" 2>/dev/null; then
        FILE_COUNT=$(jq -r '.file_count' "$MANIFEST")
        echo -e "  ${GREEN}✓ Manifest exists and is valid JSON${NC}"
        echo "  Files tracked: $FILE_COUNT"
    else
        echo -e "  ${RED}✗ Manifest is invalid JSON${NC}"
        exit 1
    fi
else
    echo -e "  ${RED}✗ Manifest not found${NC}"
    exit 1
fi

# Test 5: Sample file checks
echo ""
echo "Test 5: Verifying sample files exist..."
SAMPLE_FILES=(
    "core/commands/issue:capture.md"
    "core/commands/pr:merge-batch.md"
    "core/commands/release:promote-qa.md"
    "core/commands/milestone:create-new.md"
    "core/commands/audit:code.md"
    ".claude/commands/issue:capture.md"
    ".claude/commands/pr:merge-batch.md"
)

ALL_EXIST=true
for file in "${SAMPLE_FILES[@]}"; do
    if [ -f "$REPO_DIR/$file" ]; then
        echo -e "  ${GREEN}✓${NC} $file"
    else
        echo -e "  ${RED}✗${NC} $file (missing)"
        ALL_EXIST=false
    fi
done

if [ "$ALL_EXIST" = true ]; then
    echo -e "  ${GREEN}✓ All sample files exist${NC}"
else
    echo -e "  ${RED}✗ Some sample files are missing${NC}"
    exit 1
fi

# Summary
echo ""
echo "========================================"
echo -e "${GREEN}All verification tests passed!${NC}"
echo "========================================"
echo ""
echo "Skills successfully renamed to colon-separated format."
echo "Example invocations:"
echo "  /issue:capture"
echo "  /pr:merge-batch"
echo "  /release:promote-qa"
echo "  /milestone:create-new"
echo "  /audit:code"
echo ""

exit 0
