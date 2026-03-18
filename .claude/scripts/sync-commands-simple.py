#!/usr/bin/env python3
"""Simple sync script to copy renamed commands to .claude/commands/."""

import shutil
from pathlib import Path

def main():
    repo_root = Path(__file__).parent.parent
    source_dir = repo_root / "core" / "commands"
    target_dir = repo_root / ".claude" / "commands"

    # Ensure target exists
    target_dir.mkdir(parents=True, exist_ok=True)

    # Remove old hyphenated files in target
    print("Removing old hyphenated files from .claude/commands/...")
    removed = 0
    for old_file in target_dir.glob("*-*.md"):
        # Check if this is a skill file (not something like "foo-bar-baz.md" that should stay)
        # We'll remove files that match our old naming pattern
        old_name = old_file.stem
        if any(old_name.startswith(prefix) for prefix in [
            "audit-", "issue-", "local-", "milestone-", "ops-",
            "pr-", "release-", "repo-", "sprint-", "tool-",
            "delivery-audit", "merge-resolve", "validate-framework"
        ]):
            print(f"  ✗ {old_file.name}")
            old_file.unlink()
            removed += 1

    print(f"Removed {removed} old files\n")

    # Copy all files from source to target
    print("Copying new colon-separated files...")
    copied = 0
    for source_file in sorted(source_dir.glob("*.md")):
        target_file = target_dir / source_file.name
        shutil.copy2(source_file, target_file)
        print(f"  ✓ {source_file.name}")
        copied += 1

    print(f"\nCopied {copied} files")
    print(f"✓ Sync complete!")

if __name__ == "__main__":
    main()
