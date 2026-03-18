#!/usr/bin/env bash
set -euo pipefail
#
# Install git hooks for the repository
# Usage: ./scripts/hooks/install-hooks.sh
#

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/../.." && pwd )"
GIT_HOOKS_DIR="$REPO_DIR/.git/hooks"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Installing git hooks..."

# Create hooks directory if it doesn't exist
mkdir -p "$GIT_HOOKS_DIR"

# Install pre-commit hook
if [ -f "$GIT_HOOKS_DIR/pre-commit" ]; then
  echo -e "${YELLOW}⚠${NC} Existing pre-commit hook found. Backing up to pre-commit.bak"
  mv "$GIT_HOOKS_DIR/pre-commit" "$GIT_HOOKS_DIR/pre-commit.bak"
fi

cp "$SCRIPT_DIR/pre-commit" "$GIT_HOOKS_DIR/pre-commit"
chmod +x "$GIT_HOOKS_DIR/pre-commit"

echo -e "${GREEN}✓${NC} Installed pre-commit hook"

# Install post-merge hook (worktree cleanup detection)
if [ -f "$GIT_HOOKS_DIR/post-merge" ]; then
  echo -e "${YELLOW}⚠${NC} Existing post-merge hook found. Backing up to post-merge.bak"
  mv "$GIT_HOOKS_DIR/post-merge" "$GIT_HOOKS_DIR/post-merge.bak"
fi

cp "$SCRIPT_DIR/post-merge" "$GIT_HOOKS_DIR/post-merge"
chmod +x "$GIT_HOOKS_DIR/post-merge"

echo -e "${GREEN}✓${NC} Installed post-merge hook"

# Install post-commit hook (metrics capture)
if [ -f "$GIT_HOOKS_DIR/post-commit" ]; then
  echo -e "${YELLOW}⚠${NC} Existing post-commit hook found. Backing up to post-commit.bak"
  mv "$GIT_HOOKS_DIR/post-commit" "$GIT_HOOKS_DIR/post-commit.bak"
fi

cp "$SCRIPT_DIR/post-commit" "$GIT_HOOKS_DIR/post-commit"
chmod +x "$GIT_HOOKS_DIR/post-commit"

echo -e "${GREEN}✓${NC} Installed post-commit hook"

echo ""
echo -e "${YELLOW}Note:${NC} For full hook setup (security + naming), use:"
echo "  ./scripts/setup-sync-hooks.sh"
echo ""
echo "Hooks installed:"
echo "  - pre-commit: Naming convention checks + documentation sync"
echo "  - post-merge: Worktree cleanup detection (prompts after PR merge)"
echo "  - post-commit: Repository metrics capture (runs async)"
echo ""
echo "Documentation sync configuration:"
echo "  - Map file: config/repo/doc-sync-map.json"
echo "  - Documentation: docs/PRE_COMMIT_DOC_SYNC.md"
echo "  - Skip per-commit: add [skip-doc-sync] to commit message"
echo "  - Skip always: DOC_SYNC_SKIP=1 git commit"
echo ""
echo "To uninstall:"
echo "  rm $GIT_HOOKS_DIR/pre-commit"
echo "  rm $GIT_HOOKS_DIR/post-merge"
echo "  rm $GIT_HOOKS_DIR/post-commit"
