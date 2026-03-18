#!/usr/bin/env bash
# size-ok: Pre-commit documentation sync hook - coordinates multiple phases and cannot be split
#
# Pre-commit Documentation Sync Hook (Issue #844)
# ================================================
# Reviews and flags documentation that may be stale relative to staged code changes.
#
# Usage:
#   Called automatically by the pre-commit hook, or run directly:
#   ./scripts/hooks/pre-commit-doc-sync.sh [--mode flag|warn|report] [--map config/repo/doc-sync-map.json]
#
# Modes:
#   flag   (default) - Warn about stale docs but allow commit
#   warn   - Same as flag (alias)
#   report - Print a detailed report to .doc-sync/last-report.txt and exit 0
#
# Bypass:
#   git commit --no-verify          (skips all hooks)
#   DOC_SYNC_SKIP=1 git commit      (skips only doc sync)
#   Commit message containing "[skip-doc-sync]" also bypasses
#
# Configuration: config/repo/doc-sync-map.json
#
# Exit codes:
#   0  - No stale docs detected, or mode is warn/report
#   1  - Fatal error (bad config, missing jq)
#

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Use the git repo root of the current working directory when possible,
# falling back to the script's parent repo. This ensures the hook works
# correctly when run in a different git repo (e.g., during tests).
GIT_REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "$GIT_REPO_ROOT" ]]; then
  REPO_ROOT="$GIT_REPO_ROOT"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
DEFAULT_MAP="$REPO_ROOT/config/repo/doc-sync-map.json"
REPORT_DIR="$REPO_ROOT/.doc-sync"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Parse arguments ──────────────────────────────────────────────────────────

MODE="flag"
MAP_FILE="$DEFAULT_MAP"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --map)
      MAP_FILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--mode flag|warn|report] [--map <path-to-map.json>]"
      echo ""
      echo "Modes:"
      echo "  flag    Warn about stale docs, but allow commit (default)"
      echo "  warn    Alias for flag"
      echo "  report  Write a report to .doc-sync/last-report.txt and exit 0"
      echo ""
      echo "Environment variables:"
      echo "  DOC_SYNC_SKIP=1        Skip all checks"
      echo "  DOC_SYNC_MODE=<mode>   Override mode"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# Allow env override of mode
if [[ -n "${DOC_SYNC_MODE:-}" ]]; then
  MODE="$DOC_SYNC_MODE"
fi

# ─── Early exits ──────────────────────────────────────────────────────────────

# Skip if explicitly disabled
if [[ "${DOC_SYNC_SKIP:-0}" == "1" ]]; then
  exit 0
fi

# Skip if map file does not exist (graceful degradation)
if [[ ! -f "$MAP_FILE" ]]; then
  exit 0
fi

# Require jq
if ! command -v jq &>/dev/null; then
  echo -e "${YELLOW}⚠${NC} doc-sync: jq not found, skipping documentation sync check" >&2
  exit 0
fi

# ─── Functions ────────────────────────────────────────────────────────────────

# Match a file path against a glob-like pattern.
# Supports ** (any path segments), * (within a segment), and suffix/*
# Returns 0 if match, 1 if no match.
matches_pattern() {
  local file="$1"
  local pattern="$2"

  # Convert glob pattern to an extended regex using awk for single-pass processing.
  # Rules (applied in order, no re-processing):
  #   .    -> \\.    (literal dot)
  #   **   -> GLOBSTAR placeholder -> .*
  #   *    -> [^/]*  (any chars in one path segment)
  local regex
  regex="$(printf '%s' "$pattern" \
    | sed 's/\./DOTPLACEHOLDER/g' \
    | sed 's/\*\*/DOUBLESTAR/g' \
    | sed 's/\*/[^\/]*/g' \
    | sed 's/DOUBLESTAR/.*/g' \
    | sed 's/DOTPLACEHOLDER/\\./g')"
  regex="^${regex}$"

  if echo "$file" | grep -qE "$regex" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Check if a file path matches any excluded pattern from the map config.
is_excluded() {
  local file="$1"
  local excludes
  excludes="$(jq -r '._threshold.excluded_patterns // [] | .[]' "$MAP_FILE" 2>/dev/null || true)"

  while IFS= read -r pattern; do
    [[ -z "$pattern" ]] && continue
    if matches_pattern "$file" "$pattern"; then
      return 0
    fi
  done <<< "$excludes"
  return 1
}

# Check whether the file has been significantly changed (above threshold).
# Returns 0 (changed enough), 1 (below threshold / trivial change).
is_significant_change() {
  local file="$1"
  local min_lines
  min_lines="$(jq -r '._threshold.min_changed_lines // 5' "$MAP_FILE" 2>/dev/null || echo 5)"

  # Count added/removed lines in staged diff for this file
  local changed_lines=0
  changed_lines="$(git diff --cached --numstat -- "$file" 2>/dev/null \
    | awk '{print $1+$2}' \
    | head -1 \
    || echo 0)"

  # If we can't measure (e.g., new binary file), treat as significant
  if [[ -z "$changed_lines" ]] || [[ "$changed_lines" == "" ]]; then
    changed_lines=999
  fi

  if [[ "$changed_lines" -ge "$min_lines" ]]; then
    return 0
  fi
  return 1
}

# Given a source file, return the related doc files from the mapping.
# Prints one doc path per line.
get_related_docs() {
  local file="$1"
  local count
  count="$(jq '.mappings | length' "$MAP_FILE" 2>/dev/null || echo 0)"

  for i in $(seq 0 $((count - 1))); do
    local pattern
    pattern="$(jq -r ".mappings[$i].pattern" "$MAP_FILE" 2>/dev/null || true)"
    [[ -z "$pattern" ]] && continue

    if matches_pattern "$file" "$pattern"; then
      jq -r ".mappings[$i].docs[]" "$MAP_FILE" 2>/dev/null || true
    fi
  done | sort -u
}

# Determine if a doc file is likely stale relative to the changed source file.
# Uses git log to compare timestamps.
# Returns 0 if stale (doc older than source change), 1 if not stale.
is_doc_stale() {
  local source_file="$1"
  local doc_file="$2"

  # If doc doesn't exist, it's definitely stale (missing) — handled at call site
  if [[ ! -f "$REPO_ROOT/$doc_file" ]]; then
    return 0
  fi

  # If doc was touched in current staged changes, it's already being updated — not stale
  if git diff --cached --name-only 2>/dev/null | grep -qF "$doc_file"; then
    return 1
  fi

  # Compare the last commit date of source vs doc
  local source_date doc_date
  source_date="$(git log -1 --format="%ct" -- "$source_file" 2>/dev/null || true)"
  doc_date="$(git log -1 --format="%ct" -- "$doc_file" 2>/dev/null || true)"

  # If doc was never committed (new file being staged), treat as fresh
  # (it will be committed together with the source)
  if [[ -z "$doc_date" ]]; then
    return 1
  fi

  # If source has never been committed (brand new), no historical comparison possible
  if [[ -z "$source_date" ]]; then
    return 1
  fi

  # Stale if doc is older than source by more than 1 day (86400 seconds)
  local diff=$(( source_date - doc_date ))
  if [[ "$diff" -gt 86400 ]]; then
    return 0
  fi

  return 1
}

# ─── Main logic ───────────────────────────────────────────────────────────────

main() {
  # Get staged files (added, copied, modified only)
  local staged_files
  staged_files="$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)"

  if [[ -z "$staged_files" ]]; then
    exit 0
  fi

  # Check for skip marker in commit message (from COMMIT_EDITMSG)
  # GIT_DIR may be set by git itself when calling hooks; fall back to .git subdir
  local git_dir="${GIT_DIR:-$REPO_ROOT/.git}"
  local commit_msg_file="$git_dir/COMMIT_EDITMSG"
  if [[ -f "$commit_msg_file" ]]; then
    if grep -qF "[skip-doc-sync]" "$commit_msg_file" 2>/dev/null; then
      exit 0
    fi
  fi

  # Collect stale/missing doc findings as newline-delimited "doc:source" records
  local stale_records=""    # lines of "doc::source"
  local missing_records=""  # lines of "doc::source"

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    # Skip excluded patterns
    if is_excluded "$file"; then
      continue
    fi

    # Skip if below change threshold
    if ! is_significant_change "$file"; then
      continue
    fi

    # Get related docs for this file
    local related_docs
    related_docs="$(get_related_docs "$file")"

    if [[ -z "$related_docs" ]]; then
      continue
    fi

    while IFS= read -r doc; do
      [[ -z "$doc" ]] && continue

      if [[ ! -f "$REPO_ROOT/$doc" ]]; then
        # Doc file is missing entirely
        missing_records="${missing_records}${doc}::${file}"$'\n'
      elif is_doc_stale "$file" "$doc"; then
        # Doc exists but appears stale
        stale_records="${stale_records}${doc}::${file}"$'\n'
      fi
    done <<< "$related_docs"
  done <<< "$staged_files"

  # Deduplicate and count unique doc entries
  local stale_docs_list missing_docs_list stale_count missing_count total_count
  stale_docs_list="$(echo "$stale_records" | grep -v '^$' | awk -F'::' '{print $1}' | sort -u 2>/dev/null || true)"
  missing_docs_list="$(echo "$missing_records" | grep -v '^$' | awk -F'::' '{print $1}' | sort -u 2>/dev/null || true)"

  stale_count=0
  if [[ -n "$stale_docs_list" ]]; then
    stale_count="$(echo "$stale_docs_list" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')"
  fi
  missing_count=0
  if [[ -n "$missing_docs_list" ]]; then
    missing_count="$(echo "$missing_docs_list" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')"
  fi
  total_count=$(( stale_count + missing_count ))

  # Write report to disk if requested or for reference
  mkdir -p "$REPORT_DIR"
  local report_file="$REPORT_DIR/last-report.txt"
  {
    echo "# Documentation Sync Report"
    echo "# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "# Staged files: $(echo "$staged_files" | wc -l | tr -d ' ')"
    echo ""
    if [[ "$total_count" -gt 0 ]]; then
      echo "## Stale Documentation Detected ($total_count item(s))"
      echo ""
      while IFS= read -r doc; do
        [[ -z "$doc" ]] && continue
        local sources
        sources="$(echo "$stale_records" | grep -F "${doc}::" | awk -F'::' '{print $2}' | tr '\n' ',' | sed 's/,$//' || true)"
        echo "  STALE:   $doc"
        echo "  Changed: $sources"
        echo ""
      done <<< "$stale_docs_list"
      while IFS= read -r doc; do
        [[ -z "$doc" ]] && continue
        local sources
        sources="$(echo "$missing_records" | grep -F "${doc}::" | awk -F'::' '{print $2}' | tr '\n' ',' | sed 's/,$//' || true)"
        echo "  MISSING: $doc"
        echo "  Changed: $sources"
        echo ""
      done <<< "$missing_docs_list"
    else
      echo "## No stale documentation detected."
    fi
  } > "$report_file"

  # Exit if no findings
  if [[ "$total_count" -eq 0 ]]; then
    if [[ "${DOC_SYNC_VERBOSE:-0}" == "1" ]]; then
      echo -e "${GREEN}✓${NC} doc-sync: All related documentation appears up to date."
    fi
    exit 0
  fi

  # Print findings
  echo ""
  echo -e "${YELLOW}${BOLD}Documentation Sync Check${NC}"
  echo -e "${YELLOW}The following documentation may need updating:${NC}"
  echo ""

  while IFS= read -r doc; do
    [[ -z "$doc" ]] && continue
    local sources
    sources="$(echo "$stale_records" | grep -F "${doc}::" | awk -F'::' '{print $2}' | tr '\n' ',' | sed 's/,$//' || true)"
    echo -e "  ${CYAN}[STALE]${NC}   $doc"
    echo -e "            ↑ changed by: $sources"
  done <<< "$stale_docs_list"

  while IFS= read -r doc; do
    [[ -z "$doc" ]] && continue
    local sources
    sources="$(echo "$missing_records" | grep -F "${doc}::" | awk -F'::' '{print $2}' | tr '\n' ',' | sed 's/,$//' || true)"
    echo -e "  ${RED}[MISSING]${NC} $doc"
    echo -e "            ↑ needed by: $sources"
  done <<< "$missing_docs_list"

  echo ""
  echo -e "  ${BOLD}$total_count documentation file(s) may need attention.${NC}"
  echo ""
  echo -e "  ${YELLOW}Options:${NC}"
  echo    "    1. Update the listed documentation files and re-stage them"
  echo    "    2. Add [skip-doc-sync] to your commit message to bypass this check"
  echo    "    3. git commit --no-verify to bypass all hooks"
  echo    "    4. See report: .doc-sync/last-report.txt"
  echo ""

  # In report mode, always succeed
  if [[ "$MODE" == "report" ]]; then
    exit 0
  fi

  # In flag/warn mode, warn but do not block (exit 0)
  # This keeps the workflow fast; stale docs are warnings, not blockers
  exit 0
}

main "$@"
