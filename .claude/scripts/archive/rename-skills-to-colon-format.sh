#!/usr/bin/env bash
#
# rename-skills-to-colon-format.sh
# Rename all skills from hyphenated (issue-capture.md) to colon-separated (issue:capture.md)
#
# This script:
# 1. Renames files in core/commands/ to category:action.md format using mv (not git mv)
# 2. Updates cross-references in all skill files
# 3. Does NOT touch .claude/commands/ - those will be regenerated via manifest-sync

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_COMMANDS="$REPO_DIR/core/commands"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Renaming skills to colon-separated format${NC}"
echo ""

# Category mapping based on the issue specification
declare -A CATEGORY_MAP=(
    # audit
    ["audit-code"]="audit:code"
    ["audit-config"]="audit:config"
    ["audit-epics"]="audit:epics"
    ["audit-full"]="audit:full"
    ["audit-milestone"]="audit:milestone"
    ["audit-regression"]="audit:regression"
    ["audit-structure"]="audit:structure"
    ["audit-ui-ux"]="audit:ui-ux"

    # issue
    ["issue-capture"]="issue:capture"
    ["issue-checkout"]="issue:checkout"
    ["issue-close"]="issue:close"
    ["issue-create"]="issue:create"
    ["issue-label"]="issue:label"
    ["issue-locks"]="issue:locks"
    ["issue-prioritize-4wm"]="issue:prioritize-4wm"
    ["issue-release"]="issue:release"
    ["issue-triage-bulk"]="issue:triage-bulk"
    ["issue-triage-single"]="issue:triage-single"

    # local
    ["local-create-agent"]="local:create-agent"
    ["local-create-skill"]="local:create-skill"
    ["local-customize"]="local:customize"
    ["local-health"]="local:health"
    ["local-init"]="local:init"
    ["local-review"]="local:review"

    # milestone
    ["milestone-close-safe"]="milestone:close-safe"
    ["milestone-complete-auto"]="milestone:complete-auto"
    ["milestone-create-new"]="milestone:create-new"
    ["milestone-epic-decompose"]="milestone:epic-decompose"
    ["milestone-list-all"]="milestone:list-all"
    ["milestone-update-interactive"]="milestone:update-interactive"

    # ops
    ["ops-actions"]="ops:actions"
    ["ops-agents"]="ops:agents"
    ["ops-metrics"]="ops:metrics"
    ["ops-models"]="ops:models"
    ["ops-skill-deps"]="ops:skill-deps"
    ["ops-skills"]="ops:skills"

    # pr
    ["pr-dep-review-auto"]="pr:dep-review-auto"
    ["pr-iterate-auto"]="pr:iterate-auto"
    ["pr-merge-batch"]="pr:merge-batch"
    ["pr-rebase-dev"]="pr:rebase-dev"
    ["pr-review-local"]="pr:review-local"
    ["pr-route-fixes"]="pr:route-fixes"
    ["pr-status-check"]="pr:status-check"

    # release
    ["release-promote-main"]="release:promote-main"
    ["release-promote-qa"]="release:promote-qa"
    ["release-push"]="release:push"
    ["release-tag"]="release:tag"
    ["release-validate-qa"]="release:validate-qa"

    # repo
    ["repo-framework-update"]="repo:framework-update"
    ["repo-init-framework"]="repo:init-framework"
    ["repo-sync-origin"]="repo:sync-origin"

    # sprint
    ["sprint-dispatch"]="sprint:dispatch"
    ["sprint-refactor"]="sprint:refactor"
    ["sprint-status-pm"]="sprint:status-pm"
    ["sprint-work-auto"]="sprint:work-auto"

    # tool
    ["tool-ci-status"]="tool:ci-status"
    ["tool-example"]="tool:example"
    ["tool-skill-sync"]="tool:skill-sync"
    ["tool-worktree-audit"]="tool:worktree-audit"
    ["tool-worktree-cleanup"]="tool:worktree-cleanup"

    # standalone (categorized for consistency)
    ["delivery-audit"]="delivery:audit"
    ["merge-resolve"]="merge:resolve"
    ["validate-framework"]="validate:framework"
)

# Phase 1: Rename files in core/commands/
echo -e "${BLUE}Phase 1: Renaming files in core/commands/${NC}"
RENAMED_COUNT=0
SKIPPED_COUNT=0

for old_name in "${!CATEGORY_MAP[@]}"; do
    new_name="${CATEGORY_MAP[$old_name]}"
    old_file="$CORE_COMMANDS/${old_name}.md"
    new_file="$CORE_COMMANDS/${new_name}.md"

    if [ -f "$old_file" ]; then
        mv "$old_file" "$new_file"
        echo -e "  ${GREEN}RENAMED${NC}: ${old_name}.md → ${new_name}.md"
        ((RENAMED_COUNT++))
    elif [ -f "$new_file" ]; then
        echo -e "  ${YELLOW}SKIP${NC}: ${new_name}.md (already renamed)"
        ((SKIPPED_COUNT++))
    else
        echo -e "  ${YELLOW}SKIP${NC}: ${old_name}.md (not found)"
    fi
done

echo ""
echo -e "${GREEN}Renamed $RENAMED_COUNT files, skipped $SKIPPED_COUNT${NC}"
echo ""

# Phase 2: Update cross-references in all skill files
echo -e "${BLUE}Phase 2: Updating cross-references${NC}"

# We'll update all references in one pass through all files
UPDATED_FILES=0

while IFS= read -r -d '' file; do
    FILE_MODIFIED=false

    # Create a temp file for modifications
    temp_file=$(mktemp)
    cp "$file" "$temp_file"

    # Apply all substitutions
    for old_name in "${!CATEGORY_MAP[@]}"; do
        new_name="${CATEGORY_MAP[$old_name]}"

        # Pattern 1: `/old-name` -> `/new-name` (in various contexts)
        if grep -q "/${old_name}" "$temp_file" 2>/dev/null; then
            sed -i.bak "s|/${old_name}\`|/${new_name}\`|g" "$temp_file"
            sed -i.bak "s|/${old_name} |/${new_name} |g" "$temp_file"
            sed -i.bak "s|/${old_name}\$|/${new_name}|g" "$temp_file"
            sed -i.bak "s|/${old_name})|/${new_name})|g" "$temp_file"
            sed -i.bak "s|/${old_name},|/${new_name},|g" "$temp_file"
            rm -f "${temp_file}.bak"
            FILE_MODIFIED=true
        fi

        # Pattern 2: `old-name` (in backticks without slash)
        if grep -q "\`${old_name}\`" "$temp_file" 2>/dev/null; then
            sed -i.bak "s|\`${old_name}\`|\`${new_name}\`|g" "$temp_file"
            rm -f "${temp_file}.bak"
            FILE_MODIFIED=true
        fi
    done

    # If file was modified, replace original
    if [ "$FILE_MODIFIED" = true ]; then
        mv "$temp_file" "$file"
        echo -e "  ${YELLOW}UPDATED${NC}: $(basename "$file")"
        ((UPDATED_FILES++))
    else
        rm -f "$temp_file"
    fi
done < <(find "$CORE_COMMANDS" -name "*.md" -type f -print0)

echo ""
echo -e "${GREEN}Updated $UPDATED_FILES files${NC}"
echo ""

# Phase 3: Summary
echo -e "${BLUE}Summary:${NC}"
echo "  Files renamed: $RENAMED_COUNT"
echo "  Files with updated cross-references: $UPDATED_FILES"
echo ""
echo -e "${GREEN}Rename complete!${NC}"
echo ""

exit 0
