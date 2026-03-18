#!/usr/bin/env bash
set -euo pipefail
#
# enforce-framework-standards.sh - PreToolUse hook to enforce framework artifact standards
# Feature #1021 - Add enforcement guardrails for skills, hooks, and actions
#
# This hook runs before Write/Edit operations on framework artifacts to ensure
# they conform to standards before being committed.
#
# Usage: Called automatically by Claude Code as a PreToolUse hook
#
# Exit codes:
#   0 - Validation passed, allow operation
#   1 - Validation failed, block operation

set -e

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check if this is a Write/Edit operation on framework artifacts
# Input: TOOL_NAME and FILE_PATH from hook environment

# Only validate framework artifact files
if [[ ! "$FILE_PATH" =~ \.claude/(commands|agents|hooks)/.*\.(md|sh|py|js)$ ]] && \
   [[ ! "$FILE_PATH" =~ \.claude/(settings\.json|tier-registry\.json)$ ]]; then
  # Not a framework artifact, allow operation
  exit 0
fi

# Determine what to validate based on the file being modified
VALIDATE_ARGS=""

if [[ "$FILE_PATH" =~ \.claude/commands/.*\.md$ ]]; then
  VALIDATE_ARGS="--skills"
elif [[ "$FILE_PATH" =~ \.claude/hooks/.*\.(sh|py|js)$ ]] || [[ "$FILE_PATH" =~ \.claude/settings\.json$ ]]; then
  VALIDATE_ARGS="--hooks"
elif [[ "$FILE_PATH" =~ \.claude/tier-registry\.json$ ]]; then
  VALIDATE_ARGS="--actions"
fi

# Run validation
if ! "$REPO_ROOT/scripts/validate/validate-framework-artifacts.sh" $VALIDATE_ARGS --json > /tmp/validation-result.json 2>&1; then
  # Validation failed
  echo "⚠️  Framework artifact validation failed for: $FILE_PATH"
  echo ""
  echo "Errors detected:"
  jq -r '.skills[]?, .hooks[]?, .actions[]? | select(.status == "failed") | "  • " + .name + ": " + (.errors | join(", "))' /tmp/validation-result.json 2>/dev/null || echo "  Unable to parse validation errors"
  echo ""
  echo "Run './scripts/validate/validate-framework-artifacts.sh' for details"
  exit 1
fi

# Validation passed
exit 0
