#!/usr/bin/env bash
# ============================================================
# Script: load-dir-config.sh
# Purpose: Load and merge directory-scoped .ci-config.json overrides
#          into the active CI configuration.
#
# Usage:
#   source scripts/ci/load-dir-config.sh  # or call directly
#   load_dir_config <changed_files_list> <root_config_path>
#
# Outputs (when called as a function):
#   Prints a merged JSON config to stdout combining root config with
#   any per-directory .ci-config.json overrides found in changed dirs.
#
# Directory override format (.ci-config.json in a subdirectory):
#   {
#     "_scope": "scripts",
#     "version": "1.0",
#     "overrides": {
#       "pre-commit": {
#         "timeout_seconds": 60,
#         "additional_checks": [...]
#       }
#     },
#     "thresholds": { ... },
#     "test_mappings": { ... }
#   }
#
# Exit codes:
#   0  Success (merged config written to stdout)
#   1  Error loading config files
#   2  Missing dependencies (jq required)
# ============================================================

set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Dependencies ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  echo "[load-dir-config] ERROR: jq is required" >&2
  exit 2
fi

# ─── find_dir_configs ─────────────────────────────────────────────────────────
#
# Find all .ci-config.json files in directories touched by the changed files.
# Args:
#   $1  Comma or newline separated list of changed file paths (relative to repo root)
#   $2  Root directory to search from (default: repo root)
#
# Outputs each found directory config path on a separate line.
#
find_dir_configs() {
  local changed_files="$1"
  local search_root="${2:-$REPO_ROOT}"

  # Collect unique directories from changed files
  local -A seen_dirs=()
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    local dir
    dir=$(dirname "$file")
    # Walk up directory tree looking for .ci-config.json (stop at repo root)
    local current="$dir"
    while [[ "$current" != "." ]] && [[ "$current" != "/" ]]; do
      if [[ -z "${seen_dirs[$current]:-}" ]]; then
        seen_dirs["$current"]=1
        local config_path="$search_root/$current/.ci-config.json"
        if [[ -f "$config_path" ]]; then
          echo "$config_path"
        fi
      fi
      current=$(dirname "$current")
    done
  done < <(echo "$changed_files" | tr ',' '\n')
}

# ─── merge_dir_config ─────────────────────────────────────────────────────────
#
# Merge a directory-scoped config into a base config for a specific mode.
# Args:
#   $1  Base config JSON (as string)
#   $2  Directory config file path
#   $3  CI mode (pre-commit, pre-pr, pre-merge, pre-release)
#
# Outputs merged JSON to stdout.
#
merge_dir_config() {
  local base_config="$1"
  local dir_config_path="$2"
  local mode="$3"

  if [[ ! -f "$dir_config_path" ]]; then
    echo "$base_config"
    return
  fi

  # Validate it's valid JSON
  if ! jq empty "$dir_config_path" 2>/dev/null; then
    echo "[load-dir-config] WARNING: Invalid JSON in $dir_config_path, skipping" >&2
    echo "$base_config"
    return
  fi

  # Extract override for this mode
  local mode_override
  mode_override=$(jq -r ".overrides.\"$mode\" // empty" "$dir_config_path" 2>/dev/null || true)

  if [[ -z "$mode_override" ]]; then
    # No override for this mode, return base unchanged
    echo "$base_config"
    return
  fi

  # Apply timeout override if specified
  local merged
  merged=$(echo "$base_config" | jq \
    --argjson override "$mode_override" \
    --arg mode "$mode" \
    --arg dir_config "$dir_config_path" \
    '
    # Apply timeout override
    if $override | has("timeout_seconds") then
      .modes[$mode].timeout_seconds = ($override.timeout_seconds)
    else . end |
    # Append additional_checks if specified
    if $override | has("additional_checks") then
      .modes[$mode].checks = (.modes[$mode].checks + $override.additional_checks)
    else . end |
    # Track which directory configs were applied
    if has("_applied_dir_configs") then
      ._applied_dir_configs += [$dir_config]
    else
      . + {"_applied_dir_configs": [$dir_config]}
    end
    ' 2>/dev/null || echo "$base_config")

  echo "$merged"
}

# ─── collect_test_mappings ────────────────────────────────────────────────────
#
# Collect test_mappings from all relevant directory configs for changed files.
# Outputs a JSON object mapping source file paths to test file arrays.
#
collect_test_mappings() {
  local changed_files="$1"
  local search_root="${2:-$REPO_ROOT}"

  local combined_mappings="{}"

  while IFS= read -r config_path; do
    [[ -z "$config_path" ]] && continue

    local config_dir
    config_dir=$(dirname "$config_path")
    local rel_config_dir="${config_dir#$search_root/}"

    # Extract test_mappings from directory config
    local mappings
    mappings=$(jq -r '.test_mappings // empty' "$config_path" 2>/dev/null || true)
    [[ -z "$mappings" ]] && continue

    # Prefix keys with relative directory path
    combined_mappings=$(echo "$combined_mappings" | jq \
      --argjson new_mappings "$mappings" \
      --arg prefix "$rel_config_dir/" \
      '
      . as $base |
      $new_mappings | to_entries |
      map(select(.key | startswith("_") | not)) |
      map({key: ($prefix + .key), value: .value}) |
      from_entries |
      $base + .
      ' 2>/dev/null || echo "$combined_mappings")
  done < <(find_dir_configs "$changed_files" "$search_root")

  echo "$combined_mappings"
}

# ─── load_and_merge ───────────────────────────────────────────────────────────
#
# Main entry point: load root config, find dir overrides, merge and output.
# Args:
#   $1  Changed files (comma or newline separated)
#   $2  Root config path
#   $3  CI mode
#
load_and_merge() {
  local changed_files="$1"
  local root_config="$2"
  local mode="$3"

  if [[ ! -f "$root_config" ]]; then
    echo "[load-dir-config] ERROR: Root config not found: $root_config" >&2
    exit 1
  fi

  local base_config
  base_config=$(cat "$root_config")

  # Find and apply all directory configs
  local merged="$base_config"
  while IFS= read -r dir_config; do
    [[ -z "$dir_config" ]] && continue
    merged=$(merge_dir_config "$merged" "$dir_config" "$mode")
  done < <(find_dir_configs "$changed_files" "$(dirname "$root_config")")

  echo "$merged"
}

# ─── get_changed_dirs_summary ─────────────────────────────────────────────────
#
# Summarize which directories were affected and what overrides were found.
# Useful for reporting/debugging.
#
get_changed_dirs_summary() {
  local changed_files="$1"
  local search_root="${2:-$REPO_ROOT}"

  local config_count=0
  local configs=()

  while IFS= read -r config_path; do
    [[ -z "$config_path" ]] && continue
    config_count=$((config_count + 1))
    local rel_path="${config_path#$search_root/}"
    configs+=("$rel_path")
  done < <(find_dir_configs "$changed_files" "$search_root")

  jq -n \
    --argjson count "$config_count" \
    --argjson configs "$(printf '%s\n' "${configs[@]}" | jq -R . | jq -s .)" \
    '{
      dir_config_count: $count,
      dir_configs_applied: $configs
    }' 2>/dev/null || echo '{"dir_config_count": 0, "dir_configs_applied": []}'
}

# ─── CLI entry point ──────────────────────────────────────────────────────────

# When called directly (not sourced), provide CLI interface
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  CHANGED_FILES=""
  ROOT_CONFIG="$REPO_ROOT/.state/.ci-config.json"
  MODE="pre-commit"
  CMD="merge"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --changed)   CHANGED_FILES="$2"; shift 2 ;;
      --config)    ROOT_CONFIG="$2"; shift 2 ;;
      --mode)      MODE="$2"; shift 2 ;;
      --mappings)  CMD="mappings"; shift ;;
      --summary)   CMD="summary"; shift ;;
      --help|-h)
        grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
        exit 0
        ;;
      *)
        echo "ERROR: Unknown option: $1" >&2
        exit 2
        ;;
    esac
  done

  case "$CMD" in
    merge)
      load_and_merge "$CHANGED_FILES" "$ROOT_CONFIG" "$MODE"
      ;;
    mappings)
      collect_test_mappings "$CHANGED_FILES" "$(dirname "$ROOT_CONFIG")"
      ;;
    summary)
      get_changed_dirs_summary "$CHANGED_FILES" "$(dirname "$ROOT_CONFIG")"
      ;;
  esac
fi
