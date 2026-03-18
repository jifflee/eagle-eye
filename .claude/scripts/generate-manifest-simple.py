#!/usr/bin/env python3
"""Simple manifest generator for renamed skills."""

import json
import hashlib
from pathlib import Path
from datetime import datetime
import subprocess

def calculate_hash(file_path):
    """Calculate SHA256 hash of a file."""
    sha256 = hashlib.sha256()
    with open(file_path, 'rb') as f:
        while chunk := f.read(8192):
            sha256.update(chunk)
    return sha256.hexdigest()

def main():
    repo_root = Path(__file__).parent.parent
    manifest_file = repo_root / ".claude" / ".manifest.json"

    # Get git info
    try:
        git_commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo_root).decode().strip()
    except:
        git_commit = "unknown"

    try:
        git_tag = subprocess.check_output(['git', 'describe', '--tags', '--abbrev=0'], cwd=repo_root, stderr=subprocess.DEVNULL).decode().strip()
    except:
        git_tag = "dev"

    # Scan directories
    files_dict = {}

    scan_dirs = [
        ("core/agents", "agents", "agents/"),
        ("core/commands", "commands", "commands/"),
        ("core/skills", "skills", "skills/"),
        (".claude/hooks", "hooks", "hooks/"),
        ("scripts", "scripts", "scripts/"),
        ("config", "config", "config/"),
        ("schemas", "schemas", "schemas/"),
        ("manifests", "manifests", "manifests/"),
    ]

    for src_dir, category, target_prefix in scan_dirs:
        src_path = repo_root / src_dir
        if not src_path.exists():
            continue

        for file_path in sorted(src_path.rglob("*")):
            if not file_path.is_file():
                continue
            if file_path.name in ['.DS_Store', '*.pyc']:
                continue
            if '__pycache__' in file_path.parts:
                continue

            rel_path = file_path.relative_to(repo_root).as_posix()
            suffix = file_path.relative_to(src_path).as_posix()
            target_path = f"{target_prefix}{suffix}"

            file_hash = calculate_hash(file_path)
            file_size = file_path.stat().st_size

            files_dict[rel_path] = {
                "target": target_path,
                "category": category,
                "hash": file_hash,
                "size": file_size
            }

    # Build manifest
    manifest = {
        "$schema": "https://github.com/jifflee/claude-agents/schemas/framework-manifest.schema.json",
        "manifest_version": "2.0.0",
        "framework_version": git_tag,
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "git_commit": git_commit,
        "file_count": len(files_dict),
        "files": files_dict
    }

    # Write manifest
    manifest_file.parent.mkdir(parents=True, exist_ok=True)
    with open(manifest_file, 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"Generated manifest: {manifest_file}")
    print(f"  Framework version: {git_tag}")
    print(f"  Files tracked: {len(files_dict)}")
    print(f"  Git commit: {git_commit[:8]}")

if __name__ == "__main__":
    main()
