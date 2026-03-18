#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: git-push-with-pr.sh
# Purpose: Wrapper around git push that triggers auto PR creation
# Usage: ./scripts/git-push-with-pr.sh [git push arguments]
#
# This script:
# 1. Runs git push with provided arguments
# 2. If push succeeds, triggers post-push-pr.sh for auto PR creation
#
# Can be aliased for convenience:
#   alias gpush='./scripts/git-push-with-pr.sh'
#
# Issue: #405 - Add automatic PR creation on issue branch commits
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run git push with all provided arguments
echo "Running: git push $*"
git push "$@"

PUSH_EXIT_CODE=$?

if [ $PUSH_EXIT_CODE -ne 0 ]; then
  echo "Git push failed with exit code $PUSH_EXIT_CODE"
  exit $PUSH_EXIT_CODE
fi

# Trigger post-push hook for auto PR creation
echo ""
echo "Push successful. Checking for auto PR creation..."

if [ -x "$SCRIPT_DIR/hooks/post-push-pr.sh" ]; then
  "$SCRIPT_DIR/hooks/post-push-pr.sh"
else
  echo "Warning: post-push-pr.sh not found or not executable"
fi
