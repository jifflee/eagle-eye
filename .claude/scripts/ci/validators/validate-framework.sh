#!/usr/bin/env bash
set -euo pipefail
#
# validate-framework.sh - CI validator for framework artifacts
# Feature #1021 - Add enforcement guardrails for skills, hooks, and actions
#
# This validator runs as part of the local CI pipeline to ensure all
# framework artifacts (skills, hooks, actions) conform to standards.
#
# Usage: Called by CI pipeline
# Exit codes:
#   0 - All validations passed
#   1 - Validation errors found

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Run framework validation
echo "Running framework artifact validation..."

if ! "$REPO_ROOT/scripts/validate/validate-framework-artifacts.sh" --json > /tmp/framework-validation.json; then
  echo "❌ Framework artifact validation failed"
  echo ""

  # Extract and display errors
  jq -r '.skills[]?, .hooks[]?, .actions[]? | select(.status == "failed") |
    "  ❌ " + .name + ":\n" +
    (.errors | map("     • " + .) | join("\n"))' /tmp/framework-validation.json 2>/dev/null || true

  echo ""
  echo "Run './scripts/validate/validate-framework-artifacts.sh' for full details"
  exit 1
fi

echo "✅ Framework artifact validation passed"

# Display warnings if any
WARNING_COUNT=$(jq -r '.summary.total_warnings' /tmp/framework-validation.json 2>/dev/null || echo 0)

if [ "$WARNING_COUNT" -gt 0 ]; then
  echo ""
  echo "⚠️  Validation passed with $WARNING_COUNT warnings:"
  jq -r '.skills[]?, .hooks[]?, .actions[]? | select((.warnings | length) > 0) |
    "  ⚠️  " + .name + ":\n" +
    (.warnings | map("     • " + .) | join("\n"))' /tmp/framework-validation.json 2>/dev/null || true
  echo ""
  echo "Consider addressing these warnings to improve framework quality."
fi

exit 0
