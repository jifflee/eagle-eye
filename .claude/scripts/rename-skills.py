#!/usr/bin/env python3
"""
Rename skills from hyphenated format to colon-separated format.
Example: issue-capture.md -> issue:capture.md
"""

import os
import re
import sys
from pathlib import Path

# Category mapping
CATEGORY_MAP = {
    # audit
    "audit-code": "audit:code",
    "audit-config": "audit:config",
    "audit-epics": "audit:epics",
    "audit-full": "audit:full",
    "audit-milestone": "audit:milestone",
    "audit-regression": "audit:regression",
    "audit-structure": "audit:structure",
    "audit-ui-ux": "audit:ui-ux",

    # issue
    "issue-capture": "issue:capture",
    "issue-checkout": "issue:checkout",
    "issue-close": "issue:close",
    "issue-create": "issue:create",
    "issue-label": "issue:label",
    "issue-locks": "issue:locks",
    "issue-prioritize-4wm": "issue:prioritize-4wm",
    "issue-release": "issue:release",
    "issue-triage-bulk": "issue:triage-bulk",
    "issue-triage-single": "issue:triage-single",

    # local
    "local-create-agent": "local:create-agent",
    "local-create-skill": "local:create-skill",
    "local-customize": "local:customize",
    "local-health": "local:health",
    "local-init": "local:init",
    "local-review": "local:review",

    # milestone
    "milestone-close-safe": "milestone:close-safe",
    "milestone-complete-auto": "milestone:complete-auto",
    "milestone-create-new": "milestone:create-new",
    "milestone-epic-decompose": "milestone:epic-decompose",
    "milestone-list-all": "milestone:list-all",
    "milestone-update-interactive": "milestone:update-interactive",

    # ops
    "ops-actions": "ops:actions",
    "ops-agents": "ops:agents",
    "ops-metrics": "ops:metrics",
    "ops-models": "ops:models",
    "ops-skill-deps": "ops:skill-deps",
    "ops-skills": "ops:skills",

    # pr
    "pr-dep-review-auto": "pr:dep-review-auto",
    "pr-iterate-auto": "pr:iterate-auto",
    "pr-merge-batch": "pr:merge-batch",
    "pr-rebase-dev": "pr:rebase-dev",
    "pr-review-local": "pr:review-local",
    "pr-route-fixes": "pr:route-fixes",
    "pr-status-check": "pr:status-check",

    # release
    "release-promote-main": "release:promote-main",
    "release-promote-qa": "release:promote-qa",
    "release-push": "release:push",
    "release-tag": "release:tag",
    "release-validate-qa": "release:validate-qa",

    # repo
    "repo-framework-update": "repo:framework-update",
    "repo-init-framework": "repo:init-framework",
    "repo-sync-origin": "repo:sync-origin",

    # sprint
    "sprint-dispatch": "sprint:dispatch",
    "sprint-refactor": "sprint:refactor",
    "sprint-status-pm": "sprint:status-pm",
    "sprint-work-auto": "sprint:work-auto",

    # tool
    "tool-ci-status": "tool:ci-status",
    "tool-example": "tool:example",
    "tool-skill-sync": "tool:skill-sync",
    "tool-worktree-audit": "tool:worktree-audit",
    "tool-worktree-cleanup": "tool:worktree-cleanup",

    # standalone
    "delivery-audit": "delivery:audit",
    "merge-resolve": "merge:resolve",
    "validate-framework": "validate:framework",
}

def main():
    repo_root = Path(__file__).parent.parent
    core_commands = repo_root / "core" / "commands"

    print("Phase 1: Renaming files...")
    renamed_count = 0

    # Sort for consistent processing
    for old_name in sorted(CATEGORY_MAP.keys()):
        new_name = CATEGORY_MAP[old_name]
        old_file = core_commands / f"{old_name}.md"
        new_file = core_commands / f"{new_name}.md"

        if old_file.exists():
            old_file.rename(new_file)
            print(f"  ✓ {old_name}.md → {new_name}.md")
            renamed_count += 1
        elif new_file.exists():
            print(f"  - {new_name}.md (already exists)")
        else:
            print(f"  ⚠ {old_name}.md (not found)")

    print(f"\nRenamed {renamed_count} files")

    print("\nPhase 2: Updating cross-references...")
    updated_count = 0

    # Update all markdown files
    for md_file in core_commands.glob("*.md"):
        content = md_file.read_text()
        original_content = content

        # Replace all old references with new ones
        for old_name, new_name in CATEGORY_MAP.items():
            # Pattern 1: `/old-name` -> `/new-name`
            content = re.sub(rf'/{re.escape(old_name)}\b', f'/{new_name}', content)
            # Pattern 2: `old-name` -> `new-name` (in backticks)
            content = re.sub(rf'`{re.escape(old_name)}`', f'`{new_name}`', content)

        if content != original_content:
            md_file.write_text(content)
            print(f"  ✓ {md_file.name}")
            updated_count += 1

    print(f"\nUpdated {updated_count} files")
    print("\n✓ Rename complete!")
    return 0

if __name__ == "__main__":
    sys.exit(main())
