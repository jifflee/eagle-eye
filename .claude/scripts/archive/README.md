# scripts/archive/

This directory contains completed one-time migration scripts that are no longer needed for normal operations but are preserved for historical reference.

## Scripts

### fix-duplicate-skills.sh
**Completed**: Issue #1134
Removed global skills from project-level `.claude/commands/` to prevent duplicates when they are also synced to `~/.claude/commands/`. Global skills (with `global: true` frontmatter) should only exist at the user level.

### rename-skills-to-colon-format.sh
**Completed**: Colon naming migration
Renamed all skills from hyphenated format (`issue-capture.md`) to colon-separated format (`issue:capture.md`) in `core/commands/` and updated all cross-references.

### verify-skill-rename.sh
**Completed**: Colon naming migration verification
Verified that the colon rename migration (`rename-skills-to-colon-format.sh`) completed successfully across all skill files.

## Policy

Scripts in this directory should **not** be run against the current repository — they have already been applied. They exist solely for audit trail and documentation purposes.

If a script here needs to be re-applied to a fresh environment, review it carefully before running as the repo state may have evolved.
