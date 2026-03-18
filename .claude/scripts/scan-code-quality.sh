#!/usr/bin/env bash
# scan-code-quality.sh
# Code quality scanner: modularize, dedup, dead-code, naming dimensions.
#
# DESCRIPTION:
#   READ-ONLY analysis that produces structured findings conforming to
#   refactor-finding.schema.json. Scans source code across four categories:
#
#   1. modularize  - Files/functions exceeding line/complexity thresholds
#   2. dedup       - Near-identical code blocks (copy-paste patterns)
#   3. dead-code   - Unused exports, unreachable code, commented-out blocks
#   4. naming      - Inconsistent conventions, abbreviations, single-letter vars
#
#   Detection is language-aware (Python, JS/TS, Bash at minimum). Scoped
#   scanning is supported via --paths or --changed-files-only.
#
# USAGE:
#   ./scripts/scan-code-quality.sh [OPTIONS]
#
# OPTIONS:
#   --output-file FILE      Path to write findings JSON (default: .refactor/findings-code.json)
#   --paths GLOB            Colon-separated list of paths to scan (default: whole repo)
#   --changed-files-only    Scan only files changed since last git commit
#   --categories LIST       Comma-separated categories to run (default: all)
#                           Values: modularize,dedup,dead-code,naming
#   --max-file-lines N      Modularize: file line threshold (default: 300)
#   --max-fn-lines N        Modularize: function line threshold (default: 50)
#   --max-complexity N      Modularize: cyclomatic complexity threshold (default: 10)
#   --max-methods N         Modularize: methods-per-class threshold (default: 15)
#   --dedup-min-lines N     Dedup: minimum block size to compare (default: 10)
#   --dedup-similarity PCT  Dedup: similarity threshold 0-100 (default: 80)
#   --dead-comment-lines N  Dead code: min commented-out block size (default: 5)
#   --append                Append findings to existing file instead of overwriting
#   --finding-id-start N    Starting RF- number for new findings (default: 1)
#   --dry-run               Print findings to stdout only, do not write file
#   --verbose               Verbose output
#   --help                  Show this help
#
# OUTPUT:
#   JSON array of findings conforming to refactor-finding.schema.json
#   Exit code 0: scan complete, no critical/high findings
#   Exit code 1: scan complete, critical or high findings found
#   Exit code 2: fatal error
#
# SUPPORTED LANGUAGES:
#   Python (.py), JavaScript (.js), TypeScript (.ts, .tsx), Bash (.sh)
#
# NOTES:
#   - Requires: bash 3.2+, jq, git
#   - Optional: wc, grep, awk, find (standard POSIX tools)
#   - READ-ONLY: does not modify any source files

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source shared libraries
source "${SCRIPT_DIR}/lib/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

OUTPUT_FILE="${OUTPUT_FILE:-.refactor/findings-code.json}"
SCAN_PATHS="${SCAN_PATHS:-}"
CHANGED_FILES_ONLY="${CHANGED_FILES_ONLY:-false}"
CATEGORIES="${CATEGORIES:-modularize,dedup,dead-code,naming}"
MAX_FILE_LINES="${MAX_FILE_LINES:-300}"
MAX_FN_LINES="${MAX_FN_LINES:-50}"
MAX_COMPLEXITY="${MAX_COMPLEXITY:-10}"
MAX_METHODS="${MAX_METHODS:-15}"
DEDUP_MIN_LINES="${DEDUP_MIN_LINES:-10}"
DEDUP_SIMILARITY="${DEDUP_SIMILARITY:-80}"
DEAD_COMMENT_LINES="${DEAD_COMMENT_LINES:-5}"
APPEND="${APPEND:-false}"
FINDING_ID_START="${FINDING_ID_START:-1}"
DRY_RUN="${DRY_RUN:-false}"
VERBOSE="${VERBOSE:-false}"

SCANNER_VERSION="1.0.0"

# ─── Argument parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -60
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)        OUTPUT_FILE="$2"; shift 2 ;;
    --paths)              SCAN_PATHS="$2"; shift 2 ;;
    --changed-files-only) CHANGED_FILES_ONLY="true"; shift ;;
    --categories)         CATEGORIES="$2"; shift 2 ;;
    --max-file-lines)     MAX_FILE_LINES="$2"; shift 2 ;;
    --max-fn-lines)       MAX_FN_LINES="$2"; shift 2 ;;
    --max-complexity)     MAX_COMPLEXITY="$2"; shift 2 ;;
    --max-methods)        MAX_METHODS="$2"; shift 2 ;;
    --dedup-min-lines)    DEDUP_MIN_LINES="$2"; shift 2 ;;
    --dedup-similarity)   DEDUP_SIMILARITY="$2"; shift 2 ;;
    --dead-comment-lines) DEAD_COMMENT_LINES="$2"; shift 2 ;;
    --append)             APPEND="true"; shift ;;
    --finding-id-start)   FINDING_ID_START="$2"; shift 2 ;;
    --dry-run)            DRY_RUN="true"; shift ;;
    --verbose)            VERBOSE="true"; shift ;;
    --help|-h)            show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ────────────────────────────────────────────────────────────────
# Note: Using log_info, log_error, log_debug from lib/common.sh

log() {
  log_info "[scan-code-quality] $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    log_debug "[scan-code-quality] $*"
  fi
}

check_deps() {
  local missing=()
  for cmd in jq git awk grep; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required commands: ${missing[*]}"
    exit 2
  fi
}

# Determine language from file extension
get_language() {
  local file="$1"
  local ext="${file##*.}"
  case "$ext" in
    py)          echo "python" ;;
    js)          echo "javascript" ;;
    ts|tsx)      echo "typescript" ;;
    sh|bash)     echo "bash" ;;
    *)           echo "unknown" ;;
  esac
}

# Check if a category is enabled
category_enabled() {
  local cat="$1"
  echo "$CATEGORIES" | tr ',' '\n' | grep -qx "$cat"
}

# Format finding ID
format_id() {
  local n="$1"
  printf "RF-%03d" "$n"
}

# Global finding counter
FINDING_COUNTER="$FINDING_ID_START"
FINDINGS_JSON="[]"

# Append a finding to FINDINGS_JSON
add_finding() {
  local id="$1"
  local category="$2"
  local severity="$3"
  local owning_agent="$4"
  local fallback_agent="$5"
  local file_paths_json="$6"
  local description="$7"
  local suggested_fix="$8"
  local acceptance_criteria_json="$9"

  local finding
  finding=$(jq -n \
    --arg id "$id" \
    --arg category "$category" \
    --arg severity "$severity" \
    --arg owning_agent "$owning_agent" \
    --arg fallback_agent "$fallback_agent" \
    --argjson file_paths "$file_paths_json" \
    --arg description "$description" \
    --arg suggested_fix "$suggested_fix" \
    --argjson acceptance_criteria "$acceptance_criteria_json" \
    --arg scanner_version "$SCANNER_VERSION" \
    --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      id: $id,
      dimension: "code",
      category: $category,
      severity: $severity,
      owning_agent: $owning_agent,
      fallback_agent: $fallback_agent,
      file_paths: $file_paths,
      description: $description,
      suggested_fix: $suggested_fix,
      acceptance_criteria: $acceptance_criteria,
      status: "open",
      metadata: {
        created_at: $created_at,
        scanner_version: $scanner_version
      }
    }')

  FINDINGS_JSON=$(echo "$FINDINGS_JSON" | jq --argjson f "$finding" '. + [$f]')
  FINDING_COUNTER=$((FINDING_COUNTER + 1))
}

# ─── File collection ──────────────────────────────────────────────────────────

# Collect files to scan based on --paths and --changed-files-only
collect_files() {
  local files=()

  if [[ "$CHANGED_FILES_ONLY" == "true" ]]; then
    log "Collecting changed files since last commit"
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] && files+=("$f")
    done < <(git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null; git diff --name-only HEAD~1 HEAD 2>/dev/null | head -100)
    # Deduplicate (POSIX-compatible; mapfile requires bash 4+)
    local sorted_unique
    sorted_unique=$(printf '%s\n' "${files[@]}" | sort -u)
    files=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$f")
    done <<< "$sorted_unique"
  elif [[ -n "$SCAN_PATHS" ]]; then
    log "Scanning specified paths: $SCAN_PATHS"
    local IFS_SAVED="$IFS"
    IFS=':'
    read -ra path_list <<< "$SCAN_PATHS"
    IFS="$IFS_SAVED"
    for p in "${path_list[@]}"; do
      while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] && files+=("$f")
      done < <(find "$p" -type f 2>/dev/null)
    done
  else
    log "Scanning entire repository"
    while IFS= read -r f; do
      [[ -n "$f" && -f "$f" ]] && files+=("$f")
    done < <(git ls-files 2>/dev/null || find . -type f -not -path './.git/*')
  fi

  # Filter to supported source files
  local supported=()
  for f in "${files[@]}"; do
    local lang
    lang=$(get_language "$f")
    if [[ "$lang" != "unknown" ]]; then
      supported+=("$f")
    fi
  done

  printf '%s\n' "${supported[@]}"
}

# ─── Scanner: Modularize ──────────────────────────────────────────────────────

# Detect the owning agent based on file language/path
get_owning_agent() {
  local file="$1"
  local lang
  lang=$(get_language "$file")
  case "$lang" in
    python|bash) echo "backend-developer" ;;
    javascript|typescript)
      # Frontend if in components/pages/ui dir, otherwise backend
      if echo "$file" | grep -qE '(components|pages|ui|frontend|client)'; then
        echo "frontend-developer"
      else
        echo "backend-developer"
      fi
      ;;
    *) echo "refactoring-specialist" ;;
  esac
}

# Count actual lines of code (excluding blank lines and pure comment lines)
count_code_lines() {
  local file="$1"
  local lang
  lang=$(get_language "$file")
  case "$lang" in
    python)
      grep -cv '^\s*\(#.*\)\?$' "$file" 2>/dev/null || wc -l < "$file"
      ;;
    javascript|typescript)
      grep -cv '^\s*\(//.*\)\?$' "$file" 2>/dev/null || wc -l < "$file"
      ;;
    bash)
      grep -cv '^\s*\(#.*\)\?$' "$file" 2>/dev/null || wc -l < "$file"
      ;;
    *)
      wc -l < "$file" 2>/dev/null || echo 0
      ;;
  esac
}

scan_modularize() {
  local files=("$@")
  local found=0

  log "Scanning modularize (${#files[@]} files)..."

  for file in "${files[@]}"; do
    local lang
    lang=$(get_language "$file")
    local total_lines
    total_lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo 0)

    log_verbose "  modularize: $file ($lang, $total_lines lines)"

    # ── File too large ──────────────────────────────────────────────────────
    if [[ "$total_lines" -gt "$MAX_FILE_LINES" ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local agent fallback
      agent=$(get_owning_agent "$file")
      fallback="refactoring-specialist"

      local desc="File exceeds $MAX_FILE_LINES lines ($total_lines total). Large files are harder to navigate, test, and maintain."
      local fix="Split into cohesive sub-modules. Identify logical groupings (data access, business logic, presentation) and extract each into a dedicated file. Keep the original file as a facade if needed for backward compatibility."
      local criteria='["File is split into modules each under '"$MAX_FILE_LINES"' lines","Each module has a single clearly-stated responsibility","All existing imports and usages still work"]'

      add_finding "$id" "modularize" "medium" "$agent" "$fallback" \
        "[\"$file\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: file too large ($total_lines lines)"
    fi

    # ── Long functions ──────────────────────────────────────────────────────
    # Extract function definitions with approximate line ranges
    local fn_findings
    fn_findings=""
    case "$lang" in
      python)
        # Find def/async def, track line numbers, estimate body size
        fn_findings=$(awk '
          /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+[A-Za-z_]/ {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR-1 " " fn_name " " NR-fn_start
            }
            fn_start = NR
            fn_name = $0
            gsub(/^[[:space:]]*(async[[:space:]]+)?def[[:space:]]+/, "", fn_name)
            gsub(/[:(].*/, "", fn_name)
          }
          END {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR " " fn_name " " NR-fn_start
            }
          }
        ' "$file" 2>/dev/null || true)
        ;;
      javascript|typescript)
        fn_findings=$(awk '
          /^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+[A-Za-z_]|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?\(/ {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR-1 " " fn_name " " NR-fn_start
            }
            fn_start = NR
            fn_name = $0
            gsub(/^[[:space:]]*(export[[:space:]]+)?(async[[:space:]]+)?function[[:space:]]+/, "", fn_name)
            gsub(/[( =].*/, "", fn_name)
            gsub(/^[[:space:]]+/, "", fn_name)
          }
          END {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR " " fn_name " " NR-fn_start
            }
          }
        ' "$file" 2>/dev/null || true)
        ;;
      bash)
        fn_findings=$(awk '
          /^[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)[[:space:]]*\{/ {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR-1 " " fn_name " " NR-fn_start
            }
            fn_start = NR
            fn_name = $1
            gsub(/[[:space:]]*\(\).*/, "", fn_name)
          }
          END {
            if (fn_start > 0 && NR - fn_start > '"$MAX_FN_LINES"') {
              print fn_start "-" NR " " fn_name " " NR-fn_start
            }
          }
        ' "$file" 2>/dev/null || true)
        ;;
    esac

    if [[ -n "$fn_findings" ]]; then
      while IFS= read -r fn_line; do
        [[ -z "$fn_line" ]] && continue
        local range fn_nm fn_len
        range=$(echo "$fn_line" | awk '{print $1}')
        fn_nm=$(echo "$fn_line" | awk '{print $2}')
        fn_len=$(echo "$fn_line" | awk '{print $3}')

        local id
        id=$(format_id "$FINDING_COUNTER")
        local agent fallback
        agent=$(get_owning_agent "$file")
        fallback="refactoring-specialist"

        local desc="Function '${fn_nm}' is ${fn_len} lines (threshold: $MAX_FN_LINES). Long functions are hard to test and typically have multiple responsibilities."
        local fix="Break '${fn_nm}' into smaller functions with single responsibilities. Extract cohesive logic blocks into named helpers. Aim for each function to do one thing."
        local criteria='["Function '"${fn_nm}"' is under '"$MAX_FN_LINES"' lines","Each extracted helper has a descriptive name and single responsibility","Existing tests still pass"]'

        add_finding "$id" "modularize" "medium" "$agent" "$fallback" \
          "[\"${file}:${range}\"]" "$desc" "$fix" "$criteria"
        found=$((found + 1))
        log_verbose "    → $id: long function $fn_nm ($fn_len lines)"
      done <<< "$fn_findings"
    fi

    # ── High cyclomatic complexity (approximated via branch counting) ────────
    # Use grep -c carefully: on macOS grep -c returns exit 1 with count "0" when no matches.
    # Strip non-numeric chars and default to 0 to avoid "syntax error in expression".
    local branches=0
    local _branches_raw=0
    case "$lang" in
      python)
        _branches_raw=$(grep -cE '^\s*(if |elif |for |while |except |and |or )' "$file" 2>/dev/null || true)
        ;;
      javascript|typescript)
        _branches_raw=$(grep -cE '\b(if|else if|for|while|catch|&&|\|\|)\b' "$file" 2>/dev/null || true)
        ;;
      bash)
        _branches_raw=$(grep -cE '^\s*(if |elif |for |while |case |&&|\|\|)' "$file" 2>/dev/null || true)
        ;;
    esac
    # Sanitize: keep only the first line and strip non-digit chars
    branches=$(printf '%s' "$_branches_raw" | head -1 | tr -cd '0-9')
    branches="${branches:-0}"

    if [[ "$branches" -gt "$MAX_COMPLEXITY" ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local agent fallback
      agent=$(get_owning_agent "$file")
      fallback="refactoring-specialist"

      local desc="File has approximately $branches branch points (threshold: $MAX_COMPLEXITY), indicating high cyclomatic complexity. Complex files are error-prone and difficult to test exhaustively."
      local fix="Identify the most complex functions (those with deeply nested conditionals or long chains of if/elif). Use early returns, guard clauses, or strategy/command patterns to flatten the logic. Extract complex conditions into named predicate functions."
      local criteria='["No single function exceeds '"$MAX_COMPLEXITY"' branch points","All branches have corresponding tests","Code readability is improved with named predicates"]'

      add_finding "$id" "modularize" "medium" "$agent" "$fallback" \
        "[\"$file\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: high complexity (~$branches branches)"
    fi

    # ── Classes with too many methods ─────────────────────────────────────────
    case "$lang" in
      python)
        # Count methods per class
        local class_data
        class_data=$(awk '
          /^class[[:space:]]+/ {
            if (class_name != "" && method_count > '"$MAX_METHODS"') {
              print class_name " " method_count
            }
            class_name = $2
            gsub(/[:(].*/, "", class_name)
            method_count = 0
          }
          /^[[:space:]]+(async[[:space:]]+)?def[[:space:]]+/ && class_name != "" {
            method_count++
          }
          END {
            if (class_name != "" && method_count > '"$MAX_METHODS"') {
              print class_name " " method_count
            }
          }
        ' "$file" 2>/dev/null || true)

        if [[ -n "$class_data" ]]; then
          while IFS= read -r cls_line; do
            [[ -z "$cls_line" ]] && continue
            local cls_name cls_count
            cls_name=$(echo "$cls_line" | awk '{print $1}')
            cls_count=$(echo "$cls_line" | awk '{print $2}')

            local id
            id=$(format_id "$FINDING_COUNTER")
            local agent fallback
            agent=$(get_owning_agent "$file")
            fallback="refactoring-specialist"

            local desc="Class '${cls_name}' has ${cls_count} methods (threshold: $MAX_METHODS). Classes with many methods often have too many responsibilities (violates Single Responsibility Principle)."
            local fix="Apply the Single Responsibility Principle to '${cls_name}'. Group methods by responsibility and extract each group into a separate class. Use composition or delegation rather than inheritance to share behavior."
            local criteria='["Class '"${cls_name}"' has fewer than '"$MAX_METHODS"' methods","Each extracted class has a clear, single responsibility","All existing functionality is preserved via composition"]'

            add_finding "$id" "modularize" "low" "$agent" "$fallback" \
              "[\"$file\"]" "$desc" "$fix" "$criteria"
            found=$((found + 1))
            log_verbose "    → $id: class $cls_name has $cls_count methods"
          done <<< "$class_data"
        fi
        ;;
      javascript|typescript)
        local class_data
        class_data=$(awk '
          /^[[:space:]]*(export[[:space:]]+)?(abstract[[:space:]]+)?class[[:space:]]+/ {
            if (class_name != "" && method_count > '"$MAX_METHODS"') {
              print class_name " " method_count
            }
            class_name = $0
            gsub(/^[[:space:]]*(export[[:space:]]+)?(abstract[[:space:]]+)?class[[:space:]]+/, "", class_name)
            gsub(/[[:space:]].*/, "", class_name)
            method_count = 0
          }
          /^[[:space:]]+(async[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(/ && class_name != "" {
            # Skip constructor keyword lines that are not methods
            if ($0 !~ /\/\//) method_count++
          }
          END {
            if (class_name != "" && method_count > '"$MAX_METHODS"') {
              print class_name " " method_count
            }
          }
        ' "$file" 2>/dev/null || true)

        if [[ -n "$class_data" ]]; then
          while IFS= read -r cls_line; do
            [[ -z "$cls_line" ]] && continue
            local cls_name cls_count
            cls_name=$(echo "$cls_line" | awk '{print $1}')
            cls_count=$(echo "$cls_line" | awk '{print $2}')

            local id
            id=$(format_id "$FINDING_COUNTER")
            local agent fallback
            agent=$(get_owning_agent "$file")
            fallback="refactoring-specialist"

            local desc="Class '${cls_name}' has ${cls_count} methods (threshold: $MAX_METHODS). Consider splitting into focused, single-responsibility classes."
            local fix="Extract related method groups from '${cls_name}' into separate classes. Use composition or service injection to wire them together."
            local criteria='["Class '"${cls_name}"' has fewer than '"$MAX_METHODS"' methods","Behavior is preserved through refactoring","New classes follow single responsibility"]'

            add_finding "$id" "modularize" "low" "$agent" "$fallback" \
              "[\"$file\"]" "$desc" "$fix" "$criteria"
            found=$((found + 1))
            log_verbose "    → $id: class $cls_name has $cls_count methods"
          done <<< "$class_data"
        fi
        ;;
    esac
  done

  log "Modularize scan complete: $found finding(s)"
}

# ─── Scanner: Dedup ──────────────────────────────────────────────────────────

scan_dedup() {
  local files=("$@")
  local found=0

  log "Scanning dedup (${#files[@]} files)..."

  # Group files by language for within-language comparison
  # Use a temp file for language→files mapping (POSIX-compatible; declare -A requires bash 4+)
  local lang_map_dir
  lang_map_dir=$(mktemp -d)
  trap 'rm -rf "$lang_map_dir"' RETURN

  for file in "${files[@]}"; do
    local lang
    lang=$(get_language "$file")
    if [[ "$lang" != "unknown" ]]; then
      # Append file path to a per-language list file
      printf '%s\n' "$file" >> "$lang_map_dir/$lang.list"
    fi
  done

  # Iterate over each language that has at least one file
  for lang_list_file in "$lang_map_dir"/*.list; do
    [[ -f "$lang_list_file" ]] || continue
    local lang
    lang=$(basename "$lang_list_file" .list)

    local flist=()
    while IFS= read -r f; do
      [[ -n "$f" ]] && flist+=("$f")
    done < "$lang_list_file"
    [[ ${#flist[@]} -lt 2 ]] && continue

    log_verbose "  dedup: comparing ${#flist[@]} $lang files"

    # Extract normalized code blocks (≥ MIN_LINES) from each file into temp dir
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN

    # For each file, extract blocks of DEDUP_MIN_LINES consecutive non-blank lines
    for file in "${flist[@]}"; do
      local safe_name
      safe_name=$(echo "$file" | tr '/' '_')
      local block_file="$tmpdir/${safe_name}.blocks"

      # Extract normalized blocks: strip comments, collapse whitespace
      case "$lang" in
        python)
          awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { if (buf != "") { print buf; buf="" } next }
            { gsub(/[[:space:]]+/, " "); gsub(/^[[:space:]]+/, ""); buf = (buf == "" ? $0 : buf "\n" $0) }
            END { if (buf != "") print buf }
          ' "$file" 2>/dev/null >> "$block_file" || true
          ;;
        javascript|typescript)
          awk '
            /^[[:space:]]*\/\// { next }
            /^[[:space:]]*$/ { if (buf != "") { print buf; buf="" } next }
            { gsub(/[[:space:]]+/, " "); gsub(/^[[:space:]]+/, ""); buf = (buf == "" ? $0 : buf "\n" $0) }
            END { if (buf != "") print buf }
          ' "$file" 2>/dev/null >> "$block_file" || true
          ;;
        bash)
          awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*$/ { if (buf != "") { print buf; buf="" } next }
            { gsub(/[[:space:]]+/, " "); gsub(/^[[:space:]]+/, ""); buf = (buf == "" ? $0 : buf "\n" $0) }
            END { if (buf != "") print buf }
          ' "$file" 2>/dev/null >> "$block_file" || true
          ;;
      esac
    done

    # Compare all pairs of files for identical/near-identical blocks
    local compared=()
    for i in "${!flist[@]}"; do
      for j in "${!flist[@]}"; do
        [[ "$i" -ge "$j" ]] && continue
        local fa="${flist[$i]}"
        local fb="${flist[$j]}"
        local key="${fa}::${fb}"
        # Avoid double-checking pairs
        [[ " ${compared[*]} " =~ " ${key} " ]] && continue
        compared+=("$key")

        local safe_a safe_b
        safe_a=$(echo "$fa" | tr '/' '_')
        safe_b=$(echo "$fb" | tr '/' '_')
        local block_a="$tmpdir/${safe_a}.blocks"
        local block_b="$tmpdir/${safe_b}.blocks"

        [[ ! -f "$block_a" || ! -f "$block_b" ]] && continue

        # Count common lines (a simple but effective similarity check)
        local lines_a lines_b common_lines
        lines_a=$(wc -l < "$block_a" 2>/dev/null | tr -d ' ' || echo 0)
        lines_b=$(wc -l < "$block_b" 2>/dev/null | tr -d ' ' || echo 0)
        [[ "$lines_a" -lt "$DEDUP_MIN_LINES" || "$lines_b" -lt "$DEDUP_MIN_LINES" ]] && continue

        common_lines=$(comm -12 <(sort "$block_a") <(sort "$block_b") 2>/dev/null | wc -l | tr -d ' ' || echo 0)
        local min_lines
        min_lines=$(( lines_a < lines_b ? lines_a : lines_b ))
        [[ "$min_lines" -eq 0 ]] && continue

        # similarity = common_lines / min(lines_a, lines_b) * 100
        local similarity
        similarity=$(( common_lines * 100 / min_lines ))

        log_verbose "    dedup: $fa vs $fb: similarity=$similarity% (common=$common_lines, min=$min_lines)"

        if [[ "$similarity" -ge "$DEDUP_SIMILARITY" ]]; then
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$fa")
          fallback="refactoring-specialist"

          local desc="Files '${fa}' and '${fb}' share approximately ${similarity}% code similarity (${common_lines}/${min_lines} normalized lines). This indicates copy-paste duplication that should be extracted into a shared utility."
          local fix="Identify the common logic between the two files. Extract it into a shared module or utility function. Update both files to import and call the shared implementation. Ensure the abstraction is general enough to cover both use cases without over-engineering."
          local criteria='["Common logic exists in a single shared location","Both '"${fa}"' and '"${fb}"' import from the shared module","No copy-paste duplication remains","All existing tests pass"]'

          add_finding "$id" "dedup" "medium" "$agent" "$fallback" \
            "[\"$fa\",\"$fb\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: dedup $fa <-> $fb ($similarity% similar)"
        fi
      done
    done
  done

  # Intra-file duplication: detect repeated blocks within a single file
  for file in "${files[@]}"; do
    local lang
    lang=$(get_language "$file")
    local total_lines
    total_lines=$(wc -l < "$file" 2>/dev/null | tr -d ' ' || echo 0)
    [[ "$total_lines" -lt $((DEDUP_MIN_LINES * 2)) ]] && continue

    # Detect blocks that appear more than once in the same file
    local repeated
    repeated=$(awk -v min="$DEDUP_MIN_LINES" '
      { lines[NR] = $0 }
      END {
        for (i = 1; i <= NR - min; i++) {
          block = ""
          for (k = i; k < i + min; k++) {
            if (lines[k] !~ /^[[:space:]]*$/ && lines[k] !~ /^[[:space:]]*[#\/\/]/) {
              block = block lines[k] "\n"
            }
          }
          if (length(block) > 20) {
            seen[block]++
            if (seen[block] == 2) print i
          }
        }
      }
    ' "$file" 2>/dev/null | head -5 || true)

    if [[ -n "$repeated" ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local agent fallback
      agent=$(get_owning_agent "$file")
      fallback="refactoring-specialist"

      local desc="File '${file}' contains repeated code blocks (same ${DEDUP_MIN_LINES}+ line patterns appearing multiple times). Internal duplication inflates file size and creates inconsistency risks."
      local fix="Extract the repeated code blocks into a named helper function within the file or a shared utility. Replace all occurrences with calls to the helper. Add a clear docstring to explain the helper's purpose."
      local criteria='["No code block of '"$DEDUP_MIN_LINES"'+ lines is repeated more than once","Extracted helper has a descriptive name","All callers use the helper consistently"]'

      add_finding "$id" "dedup" "low" "$agent" "$fallback" \
        "[\"$file\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: intra-file dedup in $file"
    fi
  done

  log "Dedup scan complete: $found finding(s)"
}

# ─── Scanner: Dead Code ───────────────────────────────────────────────────────

scan_dead_code() {
  local files=("$@")
  local found=0

  log "Scanning dead-code (${#files[@]} files)..."

  for file in "${files[@]}"; do
    local lang
    lang=$(get_language "$file")

    log_verbose "  dead-code: $file ($lang)"

    # ── Unreachable code after return/throw/exit ──────────────────────────────
    # Uses a line-pair approach: read file into array, then check line N+1 after
    # any unconditional return/raise/exit to see if code follows.
    local unreachable
    case "$lang" in
      python)
        unreachable=$(awk '
          { lines[NR] = $0 }
          END {
            for (i = 1; i < NR; i++) {
              line = lines[i]
              if (line ~ /^[[:space:]]*(return|raise)[[:space:]]/ ||
                  line ~ /^[[:space:]]*return$/ ||
                  line ~ /^[[:space:]]*raise$/ ||
                  line ~ /^[[:space:]]*sys[.]exit/) {
                match(line, /^[[:space:]]*/)
                ret_indent = RLENGTH
                nxt = lines[i+1]
                if (nxt != "" && nxt !~ /^[[:space:]]*$/ && nxt !~ /^[[:space:]]*#/) {
                  match(nxt, /^[[:space:]]*/)
                  nxt_indent = RLENGTH
                  if (nxt_indent >= ret_indent &&
                      nxt !~ /^[[:space:]]*(else|elif|except|finally|def |class )/) {
                    print i+1 ": " nxt
                  }
                }
              }
            }
          }
        ' "$file" 2>/dev/null | head -5 || true)
        ;;
      javascript|typescript)
        unreachable=$(awk '
          { lines[NR] = $0 }
          END {
            for (i = 1; i < NR; i++) {
              line = lines[i]
              if (line ~ /^[[:space:]]*(return|throw )[^=]/ ||
                  line ~ /^[[:space:]]*return;$/) {
                nxt = lines[i+1]
                if (nxt != "" && nxt !~ /^[[:space:]]*$/ &&
                    nxt !~ /^[[:space:]]*(\/\/|\/\*)/ &&
                    nxt !~ /^[[:space:]]*[})]/) {
                  print i+1 ": " nxt
                }
              }
            }
          }
        ' "$file" 2>/dev/null | head -5 || true)
        ;;
      bash)
        unreachable=$(awk '
          { lines[NR] = $0 }
          END {
            for (i = 1; i < NR; i++) {
              line = lines[i]
              if (line ~ /^[[:space:]]*(return|exit) [0-9]/ ||
                  line ~ /^[[:space:]]*(return|exit)$/) {
                nxt = lines[i+1]
                if (nxt != "" && nxt !~ /^[[:space:]]*$/ && nxt !~ /^[[:space:]]*#/ &&
                    nxt !~ /^[[:space:]]*(fi|done|esac|})/) {
                  print i+1 ": " nxt
                }
              }
            }
          }
        ' "$file" 2>/dev/null | head -5 || true)
        ;;
    esac

    if [[ -n "$unreachable" ]]; then
      local first_line
      first_line=$(echo "$unreachable" | head -1 | awk -F: '{print $1}' | tr -d ' ')
      local id
      id=$(format_id "$FINDING_COUNTER")
      local agent fallback
      agent=$(get_owning_agent "$file")
      fallback="refactoring-specialist"

      local desc="Unreachable code detected in '${file}' after return/throw/exit statement (around line ${first_line}). Unreachable code creates confusion and may indicate a logic bug."
      local fix="Review the code following each return/throw/exit in '${file}'. If the code is unreachable, remove it. If it should be reachable, fix the control flow (e.g., move it before the return or add conditional branching)."
      local criteria='["No statements appear after unconditional return/throw/exit within the same block","All removed code is either deleted or properly repositioned","Logic intent is preserved"]'

      add_finding "$id" "dead-code" "medium" "$agent" "$fallback" \
        "[\"${file}:${first_line}\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: unreachable code in $file near line $first_line"
    fi

    # ── Commented-out code blocks (≥ DEAD_COMMENT_LINES consecutive lines) ───
    local comment_blocks
    case "$lang" in
      python|bash)
        comment_blocks=$(awk -v min="$DEAD_COMMENT_LINES" '
          /^[[:space:]]*#[^!]/ {
            if (in_block == 0) { block_start = NR }
            in_block++
            next
          }
          {
            if (in_block >= min) {
              print block_start "-" NR-1 " " in_block
            }
            in_block = 0
          }
          END {
            if (in_block >= min) print block_start "-" NR " " in_block
          }
        ' "$file" 2>/dev/null | head -3 || true)
        ;;
      javascript|typescript)
        # Look for consecutive // comment lines that look like code
        comment_blocks=$(awk -v min="$DEAD_COMMENT_LINES" '
          /^[[:space:]]*\/\// {
            if (in_block == 0) { block_start = NR }
            in_block++
            next
          }
          {
            if (in_block >= min) {
              print block_start "-" NR-1 " " in_block
            }
            in_block = 0
          }
          END {
            if (in_block >= min) print block_start "-" NR " " in_block
          }
        ' "$file" 2>/dev/null | head -3 || true)
        ;;
    esac

    if [[ -n "$comment_blocks" ]]; then
      while IFS= read -r block_line; do
        [[ -z "$block_line" ]] && continue
        local range block_size
        range=$(echo "$block_line" | awk '{print $1}')
        block_size=$(echo "$block_line" | awk '{print $2}')

        local id
        id=$(format_id "$FINDING_COUNTER")
        local agent fallback
        agent=$(get_owning_agent "$file")
        fallback="refactoring-specialist"

        local desc="Commented-out code block of ${block_size} lines found in '${file}' at lines ${range}. Commented-out code clutters the codebase and is better tracked via git history."
        local fix="Remove the commented-out code block at lines ${range} in '${file}'. If the code might be needed in the future, create a GitHub issue instead of leaving it commented out. The full history is always available in git."
        local criteria='["Commented-out code block at lines '"${range}"' is removed","No active logic is accidentally removed","File is cleaner and easier to read"]'

        add_finding "$id" "dead-code" "low" "$agent" "$fallback" \
          "[\"${file}:${range}\"]" "$desc" "$fix" "$criteria"
        found=$((found + 1))
        log_verbose "    → $id: commented-out block in $file lines $range ($block_size lines)"
      done <<< "$comment_blocks"
    fi

    # ── Exported symbols never imported elsewhere ─────────────────────────────
    case "$lang" in
      python)
        # Find __all__ exports or top-level def/class
        local exports
        exports=$(grep -nE '^(def |class |[A-Z][A-Z0-9_]+ =)' "$file" 2>/dev/null | \
          awk -F: '{print $2}' | \
          grep -oE '^(def |class )[A-Za-z_][A-Za-z0-9_]*' | \
          sed 's/^def //;s/^class //' | head -20 || true)

        while IFS= read -r sym; do
          [[ -z "$sym" ]] && continue
          # Check if imported anywhere else in the repo
          local import_count
          import_count=$(grep -rn --include='*.py' \
            -E "(from [^[:space:]]+ import .*\b${sym}\b|import .*\b${sym}\b)" \
            "$REPO_ROOT" 2>/dev/null | \
            grep -v "^${file}:" | \
            grep -c . || echo 0)

          if [[ "$import_count" -eq 0 ]]; then
            local sym_line
            sym_line=$(grep -n "^\(def \|class \)${sym}" "$file" 2>/dev/null | head -1 | cut -d: -f1 || echo 1)

            local id
            id=$(format_id "$FINDING_COUNTER")
            local agent fallback
            agent=$(get_owning_agent "$file")
            fallback="refactoring-specialist"

            local desc="Symbol '${sym}' in '${file}' appears to be exported but is not imported by any other file in the repository. It may be dead code."
            local fix="Verify that '${sym}' is intentionally public. If it is not used externally: (1) make it private by prefixing with underscore, or (2) remove it if it serves no purpose. If it is part of a public API, add it to __all__ and document it."
            local criteria='["'"${sym}"' is either removed, made private, or explicitly documented as a public API","No import errors after the change"]'

            add_finding "$id" "dead-code" "low" "$agent" "$fallback" \
              "[\"${file}:${sym_line}\"]" "$desc" "$fix" "$criteria"
            found=$((found + 1))
            log_verbose "    → $id: unused export $sym in $file"
          fi
        done <<< "$exports"
        ;;

      javascript|typescript)
        # Find export statements
        local exports
        exports=$(grep -nE '^export (function |class |const |let |var |default )' "$file" 2>/dev/null | \
          grep -oE '(function |class |const |let |var )[A-Za-z_][A-Za-z0-9_]*' | \
          sed 's/^function //;s/^class //;s/^const //;s/^let //;s/^var //' | \
          head -20 || true)

        while IFS= read -r sym; do
          [[ -z "$sym" ]] && continue
          local import_count
          import_count=$(grep -rn --include='*.ts' --include='*.tsx' --include='*.js' \
            -E "\b${sym}\b" \
            "$REPO_ROOT" 2>/dev/null | \
            grep -v "^${file}:" | \
            grep -c . || echo 0)

          if [[ "$import_count" -eq 0 ]]; then
            local sym_line
            sym_line=$(grep -n "export.*${sym}" "$file" 2>/dev/null | head -1 | cut -d: -f1 || echo 1)

            local id
            id=$(format_id "$FINDING_COUNTER")
            local agent fallback
            agent=$(get_owning_agent "$file")
            fallback="refactoring-specialist"

            local desc="Exported symbol '${sym}' in '${file}' is not referenced by any other file. It may be dead code or an unintentional public export."
            local fix="Check if '${sym}' is used by external consumers outside the repository. If not: remove the export keyword to make it module-private, or delete it entirely if unused. If it is an intentional public API, add JSDoc and document it."
            local criteria='["'"${sym}"' is either removed, unexported, or documented as intentional API","No import errors in dependent files"]'

            add_finding "$id" "dead-code" "low" "$agent" "$fallback" \
              "[\"${file}:${sym_line}\"]" "$desc" "$fix" "$criteria"
            found=$((found + 1))
            log_verbose "    → $id: unused export $sym in $file"
          fi
        done <<< "$exports"
        ;;
    esac

    # ── Files not imported by anything ────────────────────────────────────────
    case "$lang" in
      python)
        local basename_no_ext
        basename_no_ext=$(basename "$file" .py)
        local dir_part
        dir_part=$(dirname "$file")
        # Skip __init__.py, conftest.py, setup.py, main entry points
        if [[ "$basename_no_ext" =~ ^(__init__|conftest|setup|main|manage|wsgi|asgi|app)$ ]]; then
          continue
        fi

        local ref_count
        ref_count=$(grep -rn --include='*.py' \
          -E "(from [^[:space:]]+ import |import )" \
          "$REPO_ROOT" 2>/dev/null | \
          grep -v "^${file}:" | \
          grep -c "$basename_no_ext" || echo 0)

        if [[ "$ref_count" -eq 0 ]]; then
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="refactoring-specialist"

          local desc="Python module '${file}' (${basename_no_ext}) is not imported by any other file in the repository. It may be an unused or orphaned module."
          local fix="Verify if '${file}' is used by external tools, configuration, or as an entry point. If not: (1) remove the file if it is dead code, or (2) document why it is standalone (e.g., script runner, plugin)."
          local criteria='["'"${file}"' is either removed or documented as an intentional standalone module","No broken imports remain after any deletion"]'

          add_finding "$id" "dead-code" "low" "$agent" "$fallback" \
            "[\"$file\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: orphaned module $file"
        fi
        ;;
    esac
  done

  log "Dead-code scan complete: $found finding(s)"
}

# ─── Scanner: Naming ─────────────────────────────────────────────────────────

scan_naming() {
  local files=("$@")
  local found=0

  log "Scanning naming (${#files[@]} files)..."

  for file in "${files[@]}"; do
    local lang
    lang=$(get_language "$file")

    log_verbose "  naming: $file ($lang)"

    # ── Mixed naming conventions ──────────────────────────────────────────────
    case "$lang" in
      python)
        # Python should use snake_case for functions/variables, PascalCase for classes
        local camel_count snake_count
        # camelCase functions: def followed by a name that has lowercase start but contains an uppercase letter
        camel_count=$(grep -cE '^\s*def\s+[a-z][a-zA-Z]*[A-Z][a-zA-Z]*\s*\(' "$file" 2>/dev/null || echo 0)
        snake_count=$(grep -cE '^\s*def[[:space:]]+[a-z][a-z0-9]*_[a-z]' "$file" 2>/dev/null || echo 0)

        if [[ "$camel_count" -gt 0 && "$snake_count" -gt 0 ]]; then
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="code-reviewer"

          local desc="Mixed naming conventions in '${file}': found ${camel_count} camelCase identifier(s) alongside ${snake_count} snake_case identifier(s). Python convention (PEP 8) requires snake_case for functions and variables."
          local fix="Standardize to snake_case for all function and variable names in '${file}'. Use a rename refactoring tool to safely update all references. Ensure tests still pass after renaming."
          local criteria='["All function and variable names use snake_case","No camelCase identifiers remain outside of class names","Existing tests pass after rename"]'

          add_finding "$id" "naming" "low" "$agent" "$fallback" \
            "[\"$file\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: mixed conventions in $file (camel=$camel_count, snake=$snake_count)"
        fi
        ;;

      javascript|typescript)
        # JS/TS: functions/variables should be camelCase, classes PascalCase
        local snake_fn_count camel_fn_count
        snake_fn_count=$(grep -cE '(function|const|let|var)[[:space:]]+[a-z][a-z0-9]*_[a-z]' "$file" 2>/dev/null || echo 0)
        camel_fn_count=$(grep -cE '(function|const|let|var)[[:space:]]+[a-z][a-zA-Z0-9]+[A-Z]' "$file" 2>/dev/null || echo 0)

        if [[ "$snake_fn_count" -gt 0 && "$camel_fn_count" -gt 0 ]]; then
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="code-reviewer"

          local desc="Mixed naming conventions in '${file}': found ${snake_fn_count} snake_case identifier(s) alongside ${camel_fn_count} camelCase identifier(s). JavaScript/TypeScript convention requires camelCase for functions and variables."
          local fix="Standardize to camelCase for all function and variable names in '${file}'. Use IDE rename refactoring to safely update all references. Run type checking and tests to verify no regressions."
          local criteria='["All function and variable names use camelCase","No snake_case identifiers remain except where interfacing with external APIs","TypeScript compilation succeeds","All tests pass"]'

          add_finding "$id" "naming" "low" "$agent" "$fallback" \
            "[\"$file\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: mixed conventions in $file (snake=$snake_fn_count, camel=$camel_fn_count)"
        fi
        ;;

      bash)
        # Bash: functions can use snake_case or kebab-case, variables should be UPPER_CASE
        # for globals. Detect mixed UPPER_CASE and lower_case globals.
        local upper_globals lower_globals
        upper_globals=$(grep -cE '^[A-Z][A-Z0-9_]+=|^declare -[rg]+ [A-Z]' "$file" 2>/dev/null || echo 0)
        lower_globals=$(grep -cE '^[a-z][a-z0-9_]+=[^(]' "$file" 2>/dev/null || echo 0)

        if [[ "$upper_globals" -gt 2 && "$lower_globals" -gt 2 ]]; then
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="code-reviewer"

          local desc="Mixed variable naming in '${file}': ${upper_globals} UPPER_CASE globals and ${lower_globals} lower_case globals. Bash convention uses UPPER_CASE for globals/constants and lower_case/snake_case for local variables."
          local fix="Standardize global/constant variables to UPPER_CASE and local variables to lower_case in '${file}'. Use 'local' keyword for function-scoped variables. Check for name collisions after renaming."
          local criteria='["Global constants use UPPER_CASE","Local function variables use lower_case with local keyword","No name collisions or broken references"]'

          add_finding "$id" "naming" "low" "$agent" "$fallback" \
            "[\"$file\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: mixed var naming in $file (upper=$upper_globals, lower=$lower_globals)"
        fi
        ;;
    esac

    # ── Single-letter variable names outside loops ────────────────────────────
    case "$lang" in
      python)
        # Find single-letter variables not in for loops
        local single_letter
        single_letter=$(grep -nE '^\s+[b-df-hj-np-rt-vx-z]\s*=' "$file" 2>/dev/null | \
          grep -v 'for\s' | head -5 || true)

        if [[ -n "$single_letter" ]]; then
          local first_line
          first_line=$(echo "$single_letter" | head -1 | cut -d: -f1)
          local count
          count=$(echo "$single_letter" | wc -l | tr -d ' ')
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="code-reviewer"

          local desc="Single-letter variable names found outside loops in '${file}' (${count} occurrence(s), e.g., near line ${first_line}). These reduce readability by removing semantic context."
          local fix="Replace single-letter variables with descriptive names that convey intent. For example, 'n' → 'count', 'f' → 'file_path', 'r' → 'response'. Exception: 'i', 'j', 'k' in loop bodies are acceptable."
          local criteria='["No single-letter variable names outside of loop iterators (i, j, k)","Variable names clearly convey their purpose","All references updated consistently"]'

          add_finding "$id" "naming" "low" "$agent" "$fallback" \
            "[\"${file}:${first_line}\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: single-letter vars in $file near line $first_line"
        fi
        ;;

      javascript|typescript)
        local single_letter
        single_letter=$(grep -nE '^\s+(const|let|var)\s+[b-df-hj-np-rt-vx-z]\s*=' "$file" 2>/dev/null | head -5 || true)

        if [[ -n "$single_letter" ]]; then
          local first_line
          first_line=$(echo "$single_letter" | head -1 | cut -d: -f1)
          local count
          count=$(echo "$single_letter" | wc -l | tr -d ' ')
          local id
          id=$(format_id "$FINDING_COUNTER")
          local agent fallback
          agent=$(get_owning_agent "$file")
          fallback="code-reviewer"

          local desc="Single-letter variable names found in '${file}' (${count} occurrence(s), e.g., near line ${first_line}). These obscure intent and reduce readability."
          local fix="Replace single-letter variable names with descriptive alternatives. Update all references. Exception: loop counters and destructuring patterns where context is obvious."
          local criteria='["No opaque single-letter variable names remain","Variable names convey their purpose","TypeScript types still infer correctly"]'

          add_finding "$id" "naming" "low" "$agent" "$fallback" \
            "[\"${file}:${first_line}\"]" "$desc" "$fix" "$criteria"
          found=$((found + 1))
          log_verbose "    → $id: single-letter vars in $file near line $first_line"
        fi
        ;;
    esac

    # ── Inconsistent abbreviations ────────────────────────────────────────────
    # Detect common inconsistent abbreviations (e.g., "req" vs "request", "res" vs "response")
    case "$lang" in
      python|javascript|typescript)
        local abbrev_patterns=(
          "req:request"
          "res:response"
          "msg:message"
          "cfg:config"
          "fn:function"
          "val:value"
          "idx:index"
        )

        for pattern in "${abbrev_patterns[@]}"; do
          local abbrev full
          abbrev="${pattern%%:*}"
          full="${pattern##*:}"

          local abbrev_count full_count
          abbrev_count=$(grep -cE "\b${abbrev}\b" "$file" 2>/dev/null || echo 0)
          full_count=$(grep -cE "\b${full}\b" "$file" 2>/dev/null || echo 0)

          # Flag if both forms used significantly (>2 each)
          if [[ "$abbrev_count" -gt 2 && "$full_count" -gt 2 ]]; then
            local id
            id=$(format_id "$FINDING_COUNTER")
            local agent fallback
            agent=$(get_owning_agent "$file")
            fallback="code-reviewer"

            local desc="Inconsistent abbreviation in '${file}': '${abbrev}' (${abbrev_count} uses) and '${full}' (${full_count} uses) refer to the same concept. Pick one form and use it consistently."
            local fix="Choose either '${abbrev}' or '${full}' as the canonical form throughout '${file}'. Prefer the full word for clarity unless the abbreviated form is domain-standard. Update all occurrences consistently."
            local criteria='["Only one form ('"${abbrev}"' or '"${full}"') is used throughout the file","The chosen form matches the convention in the surrounding codebase","All references are consistent"]'

            add_finding "$id" "naming" "low" "$agent" "$fallback" \
              "[\"$file\"]" "$desc" "$fix" "$criteria"
            found=$((found + 1))
            log_verbose "    → $id: inconsistent abbrev $abbrev/$full in $file"
            break  # One abbrev finding per file is enough
          fi
        done
        ;;
    esac
  done

  log "Naming scan complete: $found finding(s)"
}

# ─── Output ───────────────────────────────────────────────────────────────────

write_output() {
  local findings="$1"
  local total
  total=$(echo "$findings" | jq 'length')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$findings" | jq '.'
    log "Dry-run: $total finding(s) (not written to file)"
    return
  fi

  local final_findings="$findings"

  # If appending, merge with existing findings
  if [[ "$APPEND" == "true" && -f "$OUTPUT_FILE" ]]; then
    local existing
    existing=$(jq '.' "$OUTPUT_FILE" 2>/dev/null || echo '[]')
    final_findings=$(echo "$existing $findings" | jq -s '.[0] + .[1]')
    log "Appended to existing findings ($(echo "$existing" | jq 'length') existing + $total new)"
  fi

  mkdir -p "$(dirname "$OUTPUT_FILE")"
  echo "$final_findings" | jq '.' > "$OUTPUT_FILE"
  log "Wrote $(echo "$final_findings" | jq 'length') finding(s) to $OUTPUT_FILE"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps

  log "Code quality scanner v${SCANNER_VERSION}"
  log "Categories: $CATEGORIES"
  log "Thresholds: file=${MAX_FILE_LINES}L fn=${MAX_FN_LINES}L complexity=${MAX_COMPLEXITY} methods=${MAX_METHODS}"
  log "Dedup: min=${DEDUP_MIN_LINES}L similarity=${DEDUP_SIMILARITY}%"
  log "Dead code: comment_block=${DEAD_COMMENT_LINES}L"

  # Collect files to scan
  local all_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && all_files+=("$f")
  done < <(collect_files)

  log "Files to scan: ${#all_files[@]}"

  if [[ ${#all_files[@]} -eq 0 ]]; then
    log "No supported files found to scan."
    write_output "[]"
    exit 0
  fi

  # Run enabled scanners
  if category_enabled "modularize"; then
    scan_modularize "${all_files[@]}"
  fi

  if category_enabled "dedup"; then
    scan_dedup "${all_files[@]}"
  fi

  if category_enabled "dead-code"; then
    scan_dead_code "${all_files[@]}"
  fi

  if category_enabled "naming"; then
    scan_naming "${all_files[@]}"
  fi

  # Write output
  write_output "$FINDINGS_JSON"

  # Determine exit code based on severity
  local critical_high
  critical_high=$(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "critical" or .severity == "high")] | length')

  local total
  total=$(echo "$FINDINGS_JSON" | jq 'length')

  log ""
  log "Scan complete: $total finding(s)"
  log "  Critical/High: $(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "critical")] | length') / $(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "high")] | length')"
  log "  Medium:        $(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "medium")] | length')"
  log "  Low:           $(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "low")] | length')"

  if [[ "$critical_high" -gt 0 ]]; then
    log "EXIT 1: critical/high findings require attention"
    exit 1
  fi

  exit 0
}

main "$@"
