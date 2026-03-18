#!/bin/bash
set -euo pipefail
# branch-audit.sh
# Audit and optionally prune stale remote branches that have been merged
#
# Usage:
#   ./scripts/branch-audit.sh              # Audit only (JSON output)
#   ./scripts/branch-audit.sh --prune      # Prune stale branches
#   ./scripts/branch-audit.sh --dry-run    # Preview what would be pruned
#
# Protected branches: main, dev, qa, release/*
# Pruneable prefixes: feat/*, fix/*, chore/*, docs/*, refactor/*

set -e

# Ensure we're in the repo root
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo '{"error": "Not in a git repository"}' >&2
  exit 1
}

MODE="audit"  # audit, prune, dry-run

# Parse arguments
for arg in "$@"; do
  case $arg in
    --prune) MODE="prune" ;;
    --dry-run) MODE="dry-run" ;;
    --audit) MODE="audit" ;;
    *) ;;
  esac
done

# Protected branch patterns (never delete these)
PROTECTED_PATTERNS=(
  "^origin/main$"
  "^origin/dev$"
  "^origin/qa$"
  "^origin/release/"
  "^origin/HEAD$"
)

# Pruneable branch prefixes
PRUNEABLE_PREFIXES=(
  "origin/feat/"
  "origin/fix/"
  "origin/chore/"
  "origin/docs/"
  "origin/refactor/"
)

# Function to check if branch is protected
is_protected() {
  local branch="$1"
  for pattern in "${PROTECTED_PATTERNS[@]}"; do
    if echo "$branch" | grep -qE "$pattern"; then
      return 0  # Protected
    fi
  done
  return 1  # Not protected
}

# Function to check if branch is pruneable prefix
is_pruneable_prefix() {
  local branch="$1"
  for prefix in "${PRUNEABLE_PREFIXES[@]}"; do
    if [[ "$branch" == "$prefix"* ]]; then
      return 0  # Pruneable
    fi
  done
  return 1  # Not pruneable
}

# Fetch latest remote refs
git fetch --prune origin >/dev/null 2>&1 || true

# Get all remote branches
ALL_REMOTE_BRANCHES=$(git branch -r | grep -v '\->' | sed 's/^ *//' || true)

# Get merged branches (merged into origin/dev)
MERGED_BRANCHES=$(git branch -r --merged origin/dev | grep -v '\->' | sed 's/^ *//' || true)

# Initialize arrays
TOTAL_REMOTE=0
PROTECTED=()
MERGED_STALE=()
UNMERGED_ACTIVE=()
OPEN_PR_BRANCHES=()

# Get all open PRs and their head branches
OPEN_PR_HEADS=$(gh pr list --state open --json headRefName --jq '.[] | "origin/" + .headRefName' 2>/dev/null || echo "")

# Analyze each remote branch
while IFS= read -r branch; do
  [ -z "$branch" ] && continue

  TOTAL_REMOTE=$((TOTAL_REMOTE + 1))

  # Check if protected
  if is_protected "$branch"; then
    PROTECTED+=("$branch")
    continue
  fi

  # Check if branch has an open PR
  if echo "$OPEN_PR_HEADS" | grep -qF "$branch"; then
    OPEN_PR_BRANCHES+=("$branch")
    continue
  fi

  # Check if merged
  if echo "$MERGED_BRANCHES" | grep -qF "$branch"; then
    # Only consider pruneable if it matches our prefixes
    if is_pruneable_prefix "$branch"; then
      MERGED_STALE+=("$branch")
    else
      PROTECTED+=("$branch")
    fi
  else
    UNMERGED_ACTIVE+=("$branch")
  fi
done <<< "$ALL_REMOTE_BRANCHES"

# Build JSON output
build_json_output() {
  local stale_json="[]"
  local protected_json="[]"
  local active_json="[]"
  local open_pr_json="[]"

  # Convert MERGED_STALE to JSON array
  if [ ${#MERGED_STALE[@]} -gt 0 ]; then
    stale_json=$(printf '%s\n' "${MERGED_STALE[@]}" | jq -R . | jq -s .)
  fi

  # Convert PROTECTED to JSON array
  if [ ${#PROTECTED[@]} -gt 0 ]; then
    protected_json=$(printf '%s\n' "${PROTECTED[@]}" | jq -R . | jq -s .)
  fi

  # Convert UNMERGED_ACTIVE to JSON array
  if [ ${#UNMERGED_ACTIVE[@]} -gt 0 ]; then
    active_json=$(printf '%s\n' "${UNMERGED_ACTIVE[@]}" | jq -R . | jq -s .)
  fi

  # Convert OPEN_PR_BRANCHES to JSON array
  if [ ${#OPEN_PR_BRANCHES[@]} -gt 0 ]; then
    open_pr_json=$(printf '%s\n' "${OPEN_PR_BRANCHES[@]}" | jq -R . | jq -s .)
  fi

  jq -n \
    --argjson total "$TOTAL_REMOTE" \
    --argjson stale_count "${#MERGED_STALE[@]}" \
    --argjson protected_count "${#PROTECTED[@]}" \
    --argjson active_count "${#UNMERGED_ACTIVE[@]}" \
    --argjson open_pr_count "${#OPEN_PR_BRANCHES[@]}" \
    --argjson stale_branches "$stale_json" \
    --argjson protected_branches "$protected_json" \
    --argjson active_branches "$active_json" \
    --argjson open_pr_branches "$open_pr_json" \
    '{
      total_remote_branches: $total,
      stale_merged_branches: {
        count: $stale_count,
        branches: $stale_branches
      },
      protected_branches: {
        count: $protected_count,
        branches: $protected_branches
      },
      active_unmerged_branches: {
        count: $active_count,
        branches: $active_branches
      },
      open_pr_branches: {
        count: $open_pr_count,
        branches: $open_pr_branches
      },
      recommendation: (
        if $stale_count > 0 then
          "Run ./scripts/branch-audit.sh --prune to delete \($stale_count) stale merged branch(es)"
        elif $stale_count == 0 and $total > 0 then
          "No stale branches found. Repository is clean."
        else
          "No remote branches to audit."
        end
      )
    }'
}

# Execute based on mode
case "$MODE" in
  audit)
    # Output JSON for consumption by sprint-status
    build_json_output
    ;;

  dry-run)
    echo "=== Branch Audit (Dry Run) ===" >&2
    echo "" >&2
    echo "Total remote branches: $TOTAL_REMOTE" >&2
    echo "Protected branches: ${#PROTECTED[@]}" >&2
    echo "Active unmerged: ${#UNMERGED_ACTIVE[@]}" >&2
    echo "Open PR branches: ${#OPEN_PR_BRANCHES[@]}" >&2
    echo "Stale merged branches: ${#MERGED_STALE[@]}" >&2
    echo "" >&2

    if [ ${#MERGED_STALE[@]} -gt 0 ]; then
      echo "Would delete the following branches:" >&2
      printf '  - %s\n' "${MERGED_STALE[@]}" >&2
      echo "" >&2
      echo "Run with --prune to actually delete these branches." >&2
    else
      echo "✓ No stale branches to prune." >&2
    fi
    ;;

  prune)
    echo "=== Pruning Stale Branches ===" >&2
    echo "" >&2

    if [ ${#MERGED_STALE[@]} -eq 0 ]; then
      echo "✓ No stale branches to prune." >&2
      exit 0
    fi

    echo "Deleting ${#MERGED_STALE[@]} stale merged branch(es)..." >&2

    DELETED=0
    FAILED=0

    for branch in "${MERGED_STALE[@]}"; do
      # Extract branch name without origin/ prefix
      branch_name="${branch#origin/}"

      # Delete from remote
      if git push origin --delete "$branch_name" >/dev/null 2>&1; then
        echo "✓ Deleted: $branch" >&2
        DELETED=$((DELETED + 1))
      else
        echo "✗ Failed to delete: $branch" >&2
        FAILED=$((FAILED + 1))
      fi
    done

    echo "" >&2
    echo "=== Summary ===" >&2
    echo "Deleted: $DELETED" >&2
    echo "Failed: $FAILED" >&2
    echo "Protected (kept): ${#PROTECTED[@]}" >&2
    echo "Active (kept): ${#UNMERGED_ACTIVE[@]}" >&2
    echo "Open PR (kept): ${#OPEN_PR_BRANCHES[@]}" >&2

    # Output final JSON
    build_json_output
    ;;
esac
