#!/bin/bash
set -euo pipefail
# rollback-qa.sh
# Rollback qa branch to a previous state
#
# Usage:
#   ./scripts/rollback-qa.sh                    # Interactive mode
#   ./scripts/rollback-qa.sh <commit-sha>       # Rollback to specific commit
#   ./scripts/rollback-qa.sh --last-promotion   # Rollback to state before last promotion
#   ./scripts/rollback-qa.sh --dry-run          # Preview rollback
#
# Related: COMMIT_PROMOTION_STRATEGY.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
DRY_RUN=false
TARGET_COMMIT=""
ROLLBACK_MODE=""
FORCE=false

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --last-promotion)
      ROLLBACK_MODE="last-promotion"
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -*)
      echo "Unknown option: $1"
      exit 1
      ;;
    *)
      TARGET_COMMIT="$1"
      shift
      ;;
  esac
done

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  echo -e "${RED}Error: Not in a git repository${NC}"
  exit 1
fi

# Fetch latest
echo "Fetching latest from origin..."
git fetch origin

# Determine rollback target
if [ "$ROLLBACK_MODE" = "last-promotion" ]; then
  echo ""
  echo "Finding last promotion to qa..."

  # Find last merge commit to qa
  TARGET_COMMIT=$(git log origin/qa --merges --oneline -1 --pretty=format:"%H^" 2>/dev/null || echo "")

  if [ -z "$TARGET_COMMIT" ]; then
    echo -e "${RED}Error: Could not find last promotion merge${NC}"
    exit 1
  fi

  echo "Last promotion found: $TARGET_COMMIT"
elif [ -z "$TARGET_COMMIT" ]; then
  # Interactive mode - show recent qa commits
  echo ""
  echo "Recent commits on qa:"
  echo ""
  git log origin/qa --oneline -10

  echo ""
  read -p "Enter commit SHA to rollback to: " TARGET_COMMIT

  if [ -z "$TARGET_COMMIT" ]; then
    echo -e "${RED}Error: No commit specified${NC}"
    exit 1
  fi
fi

# Validate commit exists
if ! git rev-parse "$TARGET_COMMIT" >/dev/null 2>&1; then
  echo -e "${RED}Error: Invalid commit: $TARGET_COMMIT${NC}"
  exit 1
fi

# Get commit details
COMMIT_MESSAGE=$(git log -1 --pretty=format:"%s" "$TARGET_COMMIT")
COMMIT_DATE=$(git log -1 --pretty=format:"%cd" --date=short "$TARGET_COMMIT")

# Show rollback plan
echo ""
echo "==================================================================="
echo "QA Rollback Plan"
echo "==================================================================="
echo ""
echo "Current qa: $(git rev-parse --short origin/qa)"
echo "Rollback to: $(git rev-parse --short "$TARGET_COMMIT")"
echo "Commit message: $COMMIT_MESSAGE"
echo "Commit date: $COMMIT_DATE"
echo ""

# Show what will be undone
COMMITS_TO_UNDO=$(git rev-list "$TARGET_COMMIT"..origin/qa --count)
echo "Commits to undo: $COMMITS_TO_UNDO"
echo ""

if [ "$COMMITS_TO_UNDO" -gt 0 ]; then
  echo "Commits that will be rolled back:"
  git log --oneline "$TARGET_COMMIT"..origin/qa
  echo ""
fi

# Confirm unless force
if [ "$FORCE" != true ] && [ "$DRY_RUN" != true ]; then
  echo -e "${YELLOW}⚠️  WARNING: This will rewrite qa branch history${NC}"
  echo ""
  read -p "Continue with rollback? (yes/no): " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    echo "Rollback cancelled"
    exit 0
  fi
fi

# Execute rollback
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo -e "${YELLOW}[DRY RUN] Would execute:${NC}"
  echo "git checkout qa"
  echo "git reset --hard $TARGET_COMMIT"
  echo "git push --force origin qa"
  echo ""
  echo "No changes made (dry run mode)"
  exit 0
fi

echo ""
echo "Executing rollback..."

# Checkout qa
git checkout qa 2>/dev/null || git checkout -b qa origin/qa

# Reset to target commit
git reset --hard "$TARGET_COMMIT"

# Push force
echo "Pushing rollback to origin/qa..."
git push --force origin qa

# Verify
CURRENT_QA=$(git rev-parse --short qa)
TARGET_SHORT=$(git rev-parse --short "$TARGET_COMMIT")

if [ "$CURRENT_QA" = "$TARGET_SHORT" ]; then
  echo ""
  echo -e "${GREEN}✅ Rollback successful${NC}"
  echo ""
  echo "qa branch rolled back to: $TARGET_SHORT"
  echo "Undid $COMMITS_TO_UNDO commits"
  echo ""
  echo "Next steps:"
  echo "1. Verify qa environment is healthy"
  echo "2. Notify QA team of rollback"
  echo "3. Create issue for blockers found"
  echo "4. Fix issues on dev, then re-promote"
else
  echo ""
  echo -e "${RED}❌ Rollback failed${NC}"
  echo "Expected: $TARGET_SHORT"
  echo "Current: $CURRENT_QA"
  exit 1
fi
