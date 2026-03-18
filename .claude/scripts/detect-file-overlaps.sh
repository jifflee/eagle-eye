#!/usr/bin/env bash
set -euo pipefail
# detect-file-overlaps.sh
# Detects file overlaps across active worktrees
#
# DESCRIPTION:
#   Scans all active issue worktrees and compares modified files to identify
#   potential merge conflicts or redundant work. Returns JSON with overlap details.
#
# USAGE:
#   ./scripts/detect-file-overlaps.sh
#
# OUTPUT:
#   JSON object with structure:
#   {
#     "overlaps": [
#       {
#         "file": "path/to/file.ts",
#         "worktrees": [
#           {"issue": 21, "path": "/path/to/repo-issue-21"},
#           {"issue": 30, "path": "/path/to/repo-issue-30"}
#         ]
#       }
#     ],
#     "worktrees_analyzed": 3,
#     "worktree_files": {...}
#   }
#
# NOTES:
#   - Only analyzes worktrees following {repo}-issue-{N} naming convention
#   - Compares against origin/dev to detect changes
#   - Gracefully handles missing worktrees or git errors

set -e

# Get repo name for pattern matching
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
REPO_NAME=$(basename "$REPO_ROOT")
# Handle worktree case: strip -issue-N suffix to get base repo name
REPO_NAME=$(echo "$REPO_NAME" | sed 's/-issue-[0-9]*$//')
PARENT_DIR=$(dirname "$REPO_ROOT")

# Create temp files for processing
TEMP_DIR=$(mktemp -d)
WORKTREE_LIST_FILE="$TEMP_DIR/worktrees.txt"
FILE_ISSUES_FILE="$TEMP_DIR/file_issues.txt"
trap "rm -rf $TEMP_DIR" EXIT

# Parse worktree list
WORKTREE_COUNT=0
while IFS= read -r line; do
  WORKTREE_PATH=$(echo "$line" | awk '{print $1}')
  WORKTREE_DIR=$(basename "$WORKTREE_PATH")

  # Extract issue number from directory name pattern: {repo}-issue-{N}
  if [[ "$WORKTREE_DIR" =~ ${REPO_NAME}-issue-([0-9]+)$ ]]; then
    ISSUE_NUM="${BASH_REMATCH[1]}"
    echo "$ISSUE_NUM:$WORKTREE_PATH" >> "$WORKTREE_LIST_FILE"
    WORKTREE_COUNT=$((WORKTREE_COUNT + 1))
  fi
done < <(git worktree list 2>/dev/null)

# If no issue worktrees found
if [ "$WORKTREE_COUNT" -eq 0 ]; then
  echo '{"overlaps": [], "worktrees_analyzed": 0, "worktree_files": {}}'
  exit 0
fi

# Get modified files for each worktree
WORKTREE_FILES_JSON="{}"
touch "$FILE_ISSUES_FILE"

while IFS= read -r entry; do
  ISSUE_NUM="${entry%%:*}"
  WORKTREE_PATH="${entry#*:}"

  # Get list of modified files in this worktree compared to origin/dev
  MODIFIED_FILES=""
  if [ -d "$WORKTREE_PATH" ]; then
    # Change to worktree and get diff
    MODIFIED_FILES=$(cd "$WORKTREE_PATH" && git diff --name-only origin/dev 2>/dev/null || echo "")
  fi

  # Build file list for this worktree
  if [ -n "$MODIFIED_FILES" ]; then
    FILES_JSON=$(echo "$MODIFIED_FILES" | jq -R . | jq -s '.')
    WORKTREE_FILES_JSON=$(echo "$WORKTREE_FILES_JSON" | jq --arg issue "$ISSUE_NUM" --argjson files "$FILES_JSON" '. + {($issue): $files}')

    # Track which files are touched by which issues
    while IFS= read -r file; do
      if [ -n "$file" ]; then
        echo "$file:$ISSUE_NUM:$WORKTREE_PATH" >> "$FILE_ISSUES_FILE"
      fi
    done <<< "$MODIFIED_FILES"
  else
    WORKTREE_FILES_JSON=$(echo "$WORKTREE_FILES_JSON" | jq --arg issue "$ISSUE_NUM" '. + {($issue): []}')
  fi
done < "$WORKTREE_LIST_FILE"

# Find overlapping files (files touched by more than one worktree)
# Group by file and find those with multiple entries
OVERLAPS="[]"
if [ -s "$FILE_ISSUES_FILE" ]; then
  # Sort by file and find duplicates
  sort "$FILE_ISSUES_FILE" | while IFS=: read -r file issue path; do
    echo "$file"
  done | sort | uniq -d > "$TEMP_DIR/overlap_files.txt"

  # For each overlapping file, collect all worktrees that touch it
  while IFS= read -r overlap_file; do
    if [ -n "$overlap_file" ]; then
      WORKTREES_JSON="[]"
      grep "^$overlap_file:" "$FILE_ISSUES_FILE" | while IFS=: read -r file issue path; do
        echo "{\"issue\": $issue, \"path\": \"$path\"}"
      done | jq -s '.' > "$TEMP_DIR/file_worktrees.json"

      WORKTREES_JSON=$(cat "$TEMP_DIR/file_worktrees.json")
      OVERLAPS=$(echo "$OVERLAPS" | jq --arg file "$overlap_file" --argjson worktrees "$WORKTREES_JSON" '. + [{file: $file, worktrees: $worktrees}]')
    fi
  done < "$TEMP_DIR/overlap_files.txt"
fi

# Sort overlaps by number of worktrees (most overlapped first)
OVERLAPS=$(echo "$OVERLAPS" | jq 'sort_by(.worktrees | length) | reverse')

# Build final output
jq -n \
  --argjson overlaps "$OVERLAPS" \
  --argjson total "$WORKTREE_COUNT" \
  --argjson worktree_files "$WORKTREE_FILES_JSON" \
  '{
    overlaps: $overlaps,
    worktrees_analyzed: $total,
    worktree_files: $worktree_files,
    summary: {
      total_overlapping_files: ($overlaps | length),
      high_risk_files: [$overlaps[] | select(.worktrees | length >= 3) | .file]
    }
  }'
