#!/usr/bin/env bash
# refactor-stale-check.sh
# Detects stale refactor findings before an agent starts a fix.
#
# DESCRIPTION:
#   Before an agent begins fixing a finding, this script verifies that the files
#   referenced in the finding have not been modified since the scan was performed.
#   This prevents race conditions where:
#     - Agent A and Agent B both have findings touching the same file
#     - Agent A fixes and commits while Agent B is still reading the finding
#     - Agent B then tries to fix a stale finding against code that has already changed
#
#   Stale detection algorithm:
#     1. Read the finding's file_paths
#     2. Compare current git hash of each file to the hash recorded at scan time
#     3. If any file has changed → finding is stale → report and exit non-zero
#
# USAGE:
#   ./scripts/refactor-stale-check.sh [OPTIONS]
#
# OPTIONS:
#   --finding-id ID         Finding ID to check (e.g., RF-001)
#   --findings-file FILE    Path to findings JSON (default: .refactor/findings.json)
#   --scan-baseline FILE    Path to scan baseline hashes (default: .refactor/scan-baseline.json)
#   --update-baseline       Record current file hashes as baseline (run at scan time)
#   --quiet                 Suppress informational output, only exit code
#   --help                  Show this help
#
# EXIT CODES:
#   0  Finding is fresh (files unchanged since scan)
#   1  Finding is stale (one or more files changed since scan)
#   2  Error (finding not found, files missing, etc.)
#
# BASELINE FILE FORMAT:
#   {
#     "scan_id": "scan-2026-02-18T00:00:00Z-abc123",
#     "recorded_at": "2026-02-18T00:00:00Z",
#     "files": {
#       "src/foo.py": "a1b2c3d4",
#       "src/bar.ts": "e5f6a7b8"
#     }
#   }

set -euo pipefail

# ─── Defaults ───────────────────────────────────────────────────────────────

FINDING_ID=""
FINDINGS_FILE="${FINDINGS_FILE:-.refactor/findings.json}"
SCAN_BASELINE="${SCAN_BASELINE:-.refactor/scan-baseline.json}"
UPDATE_BASELINE="${UPDATE_BASELINE:-false}"
QUIET="${QUIET:-false}"

# ─── Argument parsing ────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -40
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --finding-id)       FINDING_ID="$2"; shift 2 ;;
    --findings-file)    FINDINGS_FILE="$2"; shift 2 ;;
    --scan-baseline)    SCAN_BASELINE="$2"; shift 2 ;;
    --update-baseline)  UPDATE_BASELINE="true"; shift ;;
    --quiet|-q)         QUIET="true"; shift ;;
    --help|-h)          show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ───────────────────────────────────────────────────────────────

log() {
  if [[ "$QUIET" != "true" ]]; then
    echo "[refactor-stale-check] $*" >&2
  fi
}

err() {
  echo "[refactor-stale-check] ERROR: $*" >&2
}

# Get the git object hash for a file at HEAD
# Returns empty string if file doesn't exist in git
get_file_git_hash() {
  local file_path="$1"
  # Strip line range suffix if present (e.g., "src/foo.py:45-80" → "src/foo.py")
  file_path="${file_path%%:*}"

  if [[ ! -f "$file_path" ]]; then
    echo ""
    return
  fi

  git hash-object "$file_path" 2>/dev/null || echo ""
}

# ─── Baseline management ─────────────────────────────────────────────────────

# Update the scan baseline with current file hashes for all findings
update_baseline() {
  local findings_file="$1"
  local baseline_file="$2"

  if [[ ! -f "$findings_file" ]]; then
    err "Findings file not found: $findings_file"
    exit 2
  fi

  log "Recording scan baseline from $findings_file"

  # Collect all unique file paths across all findings
  local all_files
  all_files=$(jq -r '
    [.[].file_paths[] | split(":")[0]] | unique | .[]
  ' "$findings_file")

  # Build hash map for each file
  local file_hashes="{}"
  while IFS= read -r file_path; do
    if [[ -z "$file_path" ]]; then continue; fi
    local hash
    hash=$(get_file_git_hash "$file_path")
    if [[ -n "$hash" ]]; then
      file_hashes=$(echo "$file_hashes" | jq \
        --arg path "$file_path" \
        --arg hash "$hash" \
        '. + {($path): $hash}')
    else
      log "WARNING: Could not hash $file_path (file may not exist in git)"
    fi
  done <<< "$all_files"

  local scan_id
  scan_id="scan-$(date -u +%Y-%m-%dT%H:%M:%SZ)-$(git rev-parse --short HEAD 2>/dev/null || echo 'nogit')"

  # Write baseline
  mkdir -p "$(dirname "$baseline_file")"
  jq -n \
    --arg scan_id "$scan_id" \
    --arg recorded_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson files "$file_hashes" \
    '{
      scan_id: $scan_id,
      recorded_at: $recorded_at,
      files: $files
    }' > "$baseline_file"

  local file_count
  file_count=$(echo "$file_hashes" | jq 'length')
  log "Baseline recorded: $file_count files at scan_id=$scan_id"
  log "Baseline written to: $baseline_file"

  echo "$scan_id"
}

# ─── Stale check ─────────────────────────────────────────────────────────────

check_finding_stale() {
  local finding_id="$1"
  local findings_file="$2"
  local baseline_file="$3"

  # Load the finding
  if [[ ! -f "$findings_file" ]]; then
    err "Findings file not found: $findings_file"
    exit 2
  fi

  local finding
  finding=$(jq --arg id "$finding_id" '.[] | select(.id == $id)' "$findings_file")

  if [[ -z "$finding" || "$finding" == "null" ]]; then
    err "Finding not found: $finding_id"
    exit 2
  fi

  # Get file paths from the finding
  local file_paths
  file_paths=$(echo "$finding" | jq -r '.file_paths[] | split(":")[0]')

  if [[ -z "$file_paths" ]]; then
    err "Finding $finding_id has no file_paths"
    exit 2
  fi

  # Check if baseline exists
  if [[ ! -f "$baseline_file" ]]; then
    log "WARNING: No scan baseline found at $baseline_file"
    log "Cannot verify staleness. Treating finding as fresh."
    log "Run with --update-baseline to record file hashes at scan time."
    exit 0
  fi

  local scan_id recorded_at
  scan_id=$(jq -r '.scan_id' "$baseline_file")
  recorded_at=$(jq -r '.recorded_at' "$baseline_file")

  log "Checking finding $finding_id against baseline $scan_id (recorded $recorded_at)"

  local stale_files=()
  local fresh_files=()
  local missing_files=()

  while IFS= read -r file_path; do
    if [[ -z "$file_path" ]]; then continue; fi

    # Get baseline hash
    local baseline_hash
    baseline_hash=$(jq -r --arg path "$file_path" '.files[$path] // ""' "$baseline_file")

    if [[ -z "$baseline_hash" ]]; then
      log "  $file_path: not in baseline (new file or not tracked)"
      missing_files+=("$file_path")
      continue
    fi

    # Get current hash
    local current_hash
    current_hash=$(get_file_git_hash "$file_path")

    if [[ -z "$current_hash" ]]; then
      log "  $file_path: file no longer exists"
      stale_files+=("$file_path (deleted)")
      continue
    fi

    if [[ "$current_hash" != "$baseline_hash" ]]; then
      log "  $file_path: CHANGED (baseline=$baseline_hash, current=$current_hash)"
      stale_files+=("$file_path")
    else
      log "  $file_path: unchanged ✓"
      fresh_files+=("$file_path")
    fi
  done <<< "$file_paths"

  if [[ ${#stale_files[@]} -gt 0 ]]; then
    log ""
    log "STALE: Finding $finding_id is stale. ${#stale_files[@]} file(s) changed since scan:"
    for f in "${stale_files[@]}"; do
      log "  - $f"
    done
    log ""
    log "Action: Skip this finding and re-scan the changed files in the next iteration."
    log "The fix for the file may have already addressed this finding."
    return 1
  fi

  log "FRESH: Finding $finding_id is fresh. All ${#fresh_files[@]} file(s) unchanged since scan."
  return 0
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  # Update baseline mode
  if [[ "$UPDATE_BASELINE" == "true" ]]; then
    update_baseline "$FINDINGS_FILE" "$SCAN_BASELINE"
    exit 0
  fi

  # Check mode requires a finding ID
  if [[ -z "$FINDING_ID" ]]; then
    err "Finding ID required. Use --finding-id RF-NNN or --update-baseline."
    err "Run with --help for usage."
    exit 2
  fi

  check_finding_stale "$FINDING_ID" "$FINDINGS_FILE" "$SCAN_BASELINE"
}

main "$@"
