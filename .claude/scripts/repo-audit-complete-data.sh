#!/bin/bash
set -euo pipefail
# repo-audit-complete-data.sh
# Lightweight repository audit data gathering
set -e

# Quick checks
HAS_README=$([[ -f "README.md" ]] && echo "true" || echo "false")
HAS_CONTRIBUTING=$([[ -f "CONTRIBUTING.md" ]] && echo "true" || echo "false")
HAS_GITHUB_ACTIONS=$([[ -d ".github/workflows" ]] && echo "true" || echo "false")
HAS_GITIGNORE=$([[ -f ".gitignore" ]] && echo "true" || echo "false")

# File counts (limited to avoid hangs)
TEST_FILES=$(find . -maxdepth 3 -name "*.test.*" -o -name "*.spec.*" 2>/dev/null | wc -l | tr -d ' ')
WORKFLOW_COUNT=0
[[ -d ".github/workflows" ]] && WORKFLOW_COUNT=$(ls -1 .github/workflows/*.{yml,yaml} 2>/dev/null | wc -l | tr -d ' ')

echo "{\"has_readme\":$HAS_README,\"has_contributing\":$HAS_CONTRIBUTING,\"has_github_actions\":$HAS_GITHUB_ACTIONS,\"has_gitignore\":$HAS_GITIGNORE,\"test_files\":$TEST_FILES,\"workflow_count\":$WORKFLOW_COUNT}"
