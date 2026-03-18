#!/usr/bin/env bash
# ============================================================
# Script: setup-hooks.sh
# Purpose: Install git hooks for pre-commit validation
# Usage: ./scripts/dev/setup-hooks.sh
# ============================================================

set -euo pipefail

HOOKS_DIR=".git/hooks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "Setting up git hooks..."

# Ensure hooks directory exists
mkdir -p "$HOOKS_DIR"

# Create pre-commit hook
cat > "$HOOKS_DIR/pre-commit" << 'EOF'
#!/usr/bin/env bash
# Pre-commit hook: Validate standards before commit

set -e

echo "Running pre-commit checks..."

# Check for staged .env files
if git diff --cached --name-only | grep -E "^\.env$|^\.env\.local$"; then
  echo "ERROR: Attempting to commit .env file"
  echo "Remove from staging: git reset HEAD .env"
  exit 1
fi

# Check for potential secrets in staged files
if git diff --cached --diff-filter=ACM | grep -E "(password|api_key|secret|token)\s*=\s*['\"][^'\"]{8,}['\"]" | grep -v "example\|placeholder\|test"; then
  echo "WARNING: Potential secrets detected in staged changes"
  echo "Review your changes carefully"
  # Don't block, just warn
fi

# Run naming convention check on staged scripts
STAGED_SCRIPTS=$(git diff --cached --name-only --diff-filter=ACM | grep "scripts/.*\.sh$" || true)
if [ -n "$STAGED_SCRIPTS" ]; then
  echo "Checking script naming conventions..."
  for script in $STAGED_SCRIPTS; do
    basename=$(basename "$script")
    if [[ ! "$basename" =~ ^[a-z][a-z0-9-]*\.sh$ ]]; then
      echo "ERROR: Script naming violation: $script"
      echo "Expected: lowercase with hyphens (e.g., my-script.sh)"
      exit 1
    fi
  done
fi

echo "Pre-commit checks passed"
EOF

chmod +x "$HOOKS_DIR/pre-commit"
echo "Installed: pre-commit hook"

# Create pre-push hook
cat > "$HOOKS_DIR/pre-push" << 'EOF'
#!/usr/bin/env bash
# Pre-push hook: Run validation before pushing

set -e

echo "Running pre-push checks..."

# Run script size check (warning only)
if [ -f "scripts/ci/check-script-sizes.sh" ]; then
  ./scripts/ci/check-script-sizes.sh 2>/dev/null || {
    echo "WARNING: Script size issues detected"
    echo "Review output and consider splitting large scripts"
  }
fi

echo "Pre-push checks completed"
EOF

chmod +x "$HOOKS_DIR/pre-push"
echo "Installed: pre-push hook"

echo ""
echo "Git hooks installed successfully!"
echo ""
echo "Hooks will run automatically on:"
echo "  - git commit (pre-commit)"
echo "  - git push (pre-push)"
echo ""
echo "To bypass hooks (not recommended):"
echo "  git commit --no-verify"
echo "  git push --no-verify"
