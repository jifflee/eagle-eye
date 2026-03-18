#!/usr/bin/env python3
"""PreToolUse hook to block access to sensitive files.

This is Layer 2 (ENFORCEMENT) of defense-in-depth security strategy.
CLAUDE.md rules are suggestions; hooks are enforcement - they always run.

Exit codes:
  0 - Success, allow operation
  1 - Error (shown to user only)
  2 - Block operation, feed stderr to Claude
"""
import json
import sys
from pathlib import Path

# Sensitive file patterns to block
SENSITIVE_PATTERNS = {
    # Environment files
    '.env', '.env.local', '.env.production', '.env.development',
    '.env.staging', '.env.test',
    # Secret files
    'secrets.json', 'secrets.yaml', 'secrets.yml',
    # SSH keys
    'id_rsa', 'id_ed25519', 'id_ecdsa', 'id_dsa',
    # Package manager credentials
    '.npmrc', '.pypirc',
    # Cloud credentials
    'credentials.json', 'credentials.yaml',
    '.netrc',
    # API keys
    'apikeys.json', 'api_keys.json',
}

# Directory patterns that indicate sensitive content
SENSITIVE_DIRS = {
    '.aws',
    '.ssh',
    '.gnupg',
    '.config/gcloud',
}


def is_sensitive_path(file_path: str) -> tuple[bool, str]:
    """Check if a file path is sensitive.

    Returns:
        Tuple of (is_sensitive, reason)
    """
    if not file_path:
        return False, ""

    path = Path(file_path)

    # Check exact filename matches
    if path.name in SENSITIVE_PATTERNS:
        return True, f"'{path.name}' is a known sensitive file pattern"

    # Check .env* pattern (catches .env.anything)
    # Allow .env.example - contains only placeholder values, not real secrets
    if path.name.startswith('.env') and path.name != '.env.example':
        return True, f"'{path.name}' matches .env* pattern"

    # Check if path contains sensitive directories
    path_str = str(path)
    for sensitive_dir in SENSITIVE_DIRS:
        if f'/{sensitive_dir}/' in path_str or path_str.endswith(f'/{sensitive_dir}'):
            return True, f"path contains sensitive directory '{sensitive_dir}'"

    return False, ""


def main():
    """Main hook entry point."""
    try:
        # Read hook input from stdin
        data = json.load(sys.stdin)
        tool_input = data.get('tool_input', {})

        # Extract file path from various tool input formats
        file_path = (
            tool_input.get('file_path') or
            tool_input.get('path') or
            tool_input.get('command', '')  # For Bash commands that might access files
        )

        if not file_path:
            sys.exit(0)

        is_sensitive, reason = is_sensitive_path(file_path)

        if is_sensitive:
            print(f"BLOCKED: Access denied - {reason}", file=sys.stderr)
            print("Security policy: Use environment variables instead of reading secrets directly.", file=sys.stderr)
            sys.exit(2)  # Exit 2 = block and feed stderr to Claude

        sys.exit(0)  # Allow operation

    except json.JSONDecodeError:
        # Invalid input, fail open to not break Claude
        sys.exit(0)
    except Exception as e:
        # Fail open on unexpected errors
        print(f"Hook error (failing open): {e}", file=sys.stderr)
        sys.exit(0)


if __name__ == '__main__':
    main()
