#!/usr/bin/env bash
# scan-docs.sh
# Documentation scanner: obsolete, stale, duplicate, orphan, bloat dimensions.
#
# DESCRIPTION:
#   READ-ONLY analysis that produces structured findings conforming to
#   refactor-finding.schema.json. Scans documentation files across five categories:
#
#   1. obsolete   - References to files/functions/classes that no longer exist;
#                   dead links, removed features, deprecated APIs
#   2. stale      - Counts that don't match reality, old API signatures,
#                   version numbers that don't match current release
#   3. duplicate  - Same concept documented in multiple places,
#                   copy-paste paragraphs across docs, diverging content
#   4. orphan     - Doc files not linked from any index/README/CLAUDE.md,
#                   generated docs with no consumer
#   5. bloat      - Docs exceeding reasonable length, excessive repetition,
#                   verbose explanations that could be a table or list
#
# USAGE:
#   ./scripts/scan-docs.sh [OPTIONS]
#
# OPTIONS:
#   --output-file FILE        Path to write findings JSON (default: .refactor/findings-docs.json)
#   --paths GLOB              Colon-separated list of paths to scan (default: whole repo)
#   --changed-files-only      Scan only files changed since last git commit
#   --categories LIST         Comma-separated categories to run (default: all)
#                             Values: obsolete,stale,duplicate,orphan,bloat
#   --max-doc-lines N         Bloat: line threshold for a doc file (default: 500)
#   --duplicate-min-lines N   Duplicate: minimum paragraph block size (default: 5)
#   --duplicate-similarity N  Duplicate: similarity threshold 0-100 (default: 80)
#   --append                  Append findings to existing file instead of overwriting
#   --finding-id-start N      Starting RF- number for new findings (default: 1)
#   --dry-run                 Print findings to stdout only, do not write file
#   --severity-threshold LVL  Minimum severity to report: critical|high|medium|low (default: low)
#   --verbose                 Verbose output
#   --help                    Show this help
#
# OUTPUT:
#   JSON array of findings conforming to refactor-finding.schema.json
#   Exit code 0: scan complete, no critical/high findings
#   Exit code 1: scan complete, critical or high findings found
#   Exit code 2: fatal error
#
# SUPPORTED FILE TYPES:
#   Markdown (.md), reStructuredText (.rst), text (.txt)
#
# NOTES:
#   - Requires: bash 3.2+, jq, git
#   - Optional: wc, grep, awk, find (standard POSIX tools)
#   - READ-ONLY: does not modify any source files
#   - Compatible with macOS default bash (3.2) and bash 4+

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

OUTPUT_FILE="${OUTPUT_FILE:-.refactor/findings-docs.json}"
SCAN_PATHS="${SCAN_PATHS:-}"
CHANGED_FILES_ONLY="${CHANGED_FILES_ONLY:-false}"
CATEGORIES="${CATEGORIES:-obsolete,stale,duplicate,orphan,bloat}"
MAX_DOC_LINES="${MAX_DOC_LINES:-500}"
DUPLICATE_MIN_LINES="${DUPLICATE_MIN_LINES:-5}"
DUPLICATE_SIMILARITY="${DUPLICATE_SIMILARITY:-80}"
APPEND="${APPEND:-false}"
FINDING_ID_START="${FINDING_ID_START:-1}"
DRY_RUN="${DRY_RUN:-false}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-low}"
VERBOSE="${VERBOSE:-false}"

SCANNER_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# Capture the working directory at invocation time for relative path display
SCAN_ROOT="$(pwd)"

# ─── Argument parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -60
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)           OUTPUT_FILE="$2"; shift 2 ;;
    --paths)                 SCAN_PATHS="$2"; shift 2 ;;
    --changed-files-only)    CHANGED_FILES_ONLY="true"; shift ;;
    --categories)            CATEGORIES="$2"; shift 2 ;;
    --max-doc-lines)         MAX_DOC_LINES="$2"; shift 2 ;;
    --duplicate-min-lines)   DUPLICATE_MIN_LINES="$2"; shift 2 ;;
    --duplicate-similarity)  DUPLICATE_SIMILARITY="$2"; shift 2 ;;
    --append)                APPEND="true"; shift ;;
    --finding-id-start)      FINDING_ID_START="$2"; shift 2 ;;
    --dry-run)               DRY_RUN="true"; shift ;;
    --severity-threshold)    SEVERITY_THRESHOLD="$2"; shift 2 ;;
    --verbose)               VERBOSE="true"; shift ;;
    --help|-h)               show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ────────────────────────────────────────────────────────────────

log() {
  echo "[scan-docs] $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[scan-docs:verbose] $*" >&2
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
    echo "ERROR: Missing required commands: ${missing[*]}" >&2
    exit 2
  fi
}

# Format finding ID
format_id() {
  local n="$1"
  printf "RF-%03d" "$n"
}

# Severity order for threshold filtering
severity_order() {
  case "$1" in
    critical) echo 4 ;;
    high)     echo 3 ;;
    medium)   echo 2 ;;
    low)      echo 1 ;;
    *)        echo 0 ;;
  esac
}

severity_meets_threshold() {
  local sev="$1"
  local threshold="${SEVERITY_THRESHOLD:-low}"
  [[ $(severity_order "$sev") -ge $(severity_order "$threshold") ]]
}

# Global finding counter and accumulator
FINDING_COUNTER="$FINDING_ID_START"
FINDINGS_JSON="[]"
HAS_HIGH_CRITICAL=false

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

  # Apply severity threshold filter
  if ! severity_meets_threshold "$severity"; then
    log_verbose "  Skipping $id (severity $severity below threshold $SEVERITY_THRESHOLD)"
    return 0
  fi

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
      dimension: "documentation",
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

  if [[ "$severity" == "critical" || "$severity" == "high" ]]; then
    HAS_HIGH_CRITICAL=true
  fi
}

# Check if a category is enabled
category_enabled() {
  local cat="$1"
  echo "$CATEGORIES" | tr ',' '\n' | grep -qx "$cat"
}

# ─── File collection ──────────────────────────────────────────────────────────

# Collect doc files to scan
collect_doc_files() {
  local files=()

  # Determine the git root of the current scan context (may differ in test environments)
  local scan_git_root
  scan_git_root=$(git -C "$SCAN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$SCAN_ROOT")

  if [[ "$CHANGED_FILES_ONLY" == "true" ]]; then
    log "Collecting changed doc files since last commit"
    while IFS= read -r f; do
      local full="$scan_git_root/$f"
      [[ -n "$f" && -f "$full" ]] && files+=("$full")
    done < <(
      {
        git -C "$scan_git_root" diff --name-only HEAD 2>/dev/null
        git -C "$scan_git_root" diff --cached --name-only 2>/dev/null
        git -C "$scan_git_root" diff --name-only HEAD~1 HEAD 2>/dev/null | head -100
      } | sort -u
    )
  elif [[ -n "$SCAN_PATHS" ]]; then
    log "Scanning specified paths: $SCAN_PATHS"
    local IFS_SAVED="$IFS"
    IFS=':'
    read -ra path_list <<< "$SCAN_PATHS"
    IFS="$IFS_SAVED"
    for p in "${path_list[@]}"; do
      local resolved_p="$p"
      if [[ ! "$p" = /* ]]; then
        # Resolve relative path against SCAN_ROOT (CWD at invocation)
        if [[ -e "$SCAN_ROOT/$p" ]]; then
          resolved_p="$SCAN_ROOT/$p"
        else
          resolved_p="$scan_git_root/$p"
        fi
      fi
      while IFS= read -r f; do
        [[ -n "$f" && -f "$f" ]] && files+=("$f")
      done < <(find "$resolved_p" -type f 2>/dev/null)
    done
  else
    log "Scanning entire repository for doc files"
    while IFS= read -r f; do
      local full_path="$scan_git_root/$f"
      [[ -n "$f" && -f "$full_path" ]] && files+=("$full_path")
    done < <(git -C "$scan_git_root" ls-files 2>/dev/null || find "$scan_git_root" -type f -not -path '*/.git/*')
  fi

  # Filter to supported doc file types
  local supported=()
  for f in "${files[@]}"; do
    local ext
    ext=$(echo "${f##*.}" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
      md|rst|txt) supported+=("$f") ;;
    esac
  done

  printf '%s\n' "${supported[@]}"
}

# Collect all tracked files for reference checking
collect_all_files() {
  local git_root
  git_root=$(git -C "$SCAN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$SCAN_ROOT")
  git -C "$git_root" ls-files 2>/dev/null || find "$git_root" -type f -not -path '*/.git/*'
}

# ─── Scanner: Obsolete ────────────────────────────────────────────────────────

# Detect file/path references in a doc and check if they exist
scan_obsolete() {
  local doc_files=("$@")
  local found=0

  log "Scanning obsolete references (${#doc_files[@]} doc files)..."

  # Build set of tracked files relative to scan git root
  local obs_git_root
  obs_git_root=$(git -C "$SCAN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$SCAN_ROOT")
  # Store tracked files in a temp file for bash 3.2-compatible membership tests
  local tracked_files_tmp
  tracked_files_tmp=$(mktemp)
  git -C "$obs_git_root" ls-files 2>/dev/null | sort > "$tracked_files_tmp" || true

  for doc_file in "${doc_files[@]}"; do
    local rel_doc
    rel_doc=$(realpath --relative-to="$SCAN_ROOT" "$doc_file" 2>/dev/null || echo "$doc_file")
    log_verbose "  obsolete: checking $rel_doc"

    # ── Dead file references (markdown links and code references) ──────────
    # Match patterns like [text](path), `path/to/file`, scripts/foo.sh, etc.
    local dead_refs=()
    while IFS= read -r line_info; do
      local lineno ref_path
      lineno=$(echo "$line_info" | cut -d: -f1)
      ref_path=$(echo "$line_info" | cut -d: -f2-)

      # Strip leading/trailing whitespace and quotes
      ref_path=$(echo "$ref_path" | sed 's/^[[:space:]"`(]*//;s/[[:space:]"`):,]*$//')

      # Skip empty, anchors-only, external URLs, and obviously wrong matches
      [[ -z "$ref_path" ]] && continue
      [[ "$ref_path" =~ ^# ]] && continue
      [[ "$ref_path" =~ ^https?:// ]] && continue
      [[ "$ref_path" =~ ^mailto: ]] && continue
      [[ "$ref_path" =~ ^[[:space:]]*$ ]] && continue

      # Strip anchor from path
      local path_without_anchor
      path_without_anchor="${ref_path%%#*}"
      [[ -z "$path_without_anchor" ]] && continue

      # Try to resolve relative to the doc file's directory
      local doc_dir
      doc_dir=$(dirname "$doc_file")
      local candidate1="$doc_dir/$path_without_anchor"
      local candidate2="$obs_git_root/$path_without_anchor"

      local exists=false
      if [[ -f "$candidate1" || -d "$candidate1" ]]; then
        exists=true
      elif [[ -f "$candidate2" || -d "$candidate2" ]]; then
        exists=true
      elif grep -qxF "$path_without_anchor" "$tracked_files_tmp" 2>/dev/null; then
        exists=true
      fi

      if [[ "$exists" == "false" ]]; then
        dead_refs+=("${lineno}:${ref_path}")
      fi
    done < <(
      # Extract markdown link targets: [label](path)
      grep -n '\[.*\]([^)]*[^#)][^)]*)' "$doc_file" 2>/dev/null \
        | grep -oP '(?<=\()[^)]+(?=\))' \
        | grep -v '^https\?://' \
        | grep -v '^#' \
        | awk '{print NR ":" $0}' || true
      # Extract inline code references to scripts/src/docs paths
      grep -nP '`[^`]*(scripts|src|docs|tests|configs|deploy)/[^`]+`' "$doc_file" 2>/dev/null \
        | sed "s/.*\`\([^'\`]*\)\`.*/\1/" \
        | awk '{print NR ":" $0}' || true
    )

    if [[ ${#dead_refs[@]} -gt 0 ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local refs_summary
      refs_summary=$(printf '%s\n' "${dead_refs[@]}" | head -5 | tr '\n' '; ')

      local desc="Documentation file references paths that no longer exist: ${refs_summary}. Dead references mislead readers and erode trust in documentation."
      local fix="Remove or update each dead reference. If the file was moved, update the path. If the feature was removed, remove or rewrite the section."
      local criteria='["All file/path references in the doc resolve to existing files","No broken internal links remain","External links are validated or removed"]'

      add_finding "$id" "obsolete-docs" "medium" "documentation" "documentation-librarian" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: ${#dead_refs[@]} dead reference(s) in $rel_doc"
    fi

    # ── Version number mismatches ────────────────────────────────────────────
    # Check if doc references specific version numbers that may be outdated
    local version_mentions
    version_mentions=$(grep -cP 'v\d+\.\d+\.\d+|version[[:space:]]+"?\d+\.\d+' "$doc_file" 2>/dev/null | tr -d '[:space:]' || echo 0)
    version_mentions="${version_mentions:-0}"
    if [[ "$version_mentions" -gt 3 ]]; then
      log_verbose "    Note: $rel_doc has $version_mentions version number mentions (may contain outdated versions)"
    fi
  done

  # Clean up temp file
  rm -f "$tracked_files_tmp"

  log "Obsolete scan: found $found potential issues"
}

# ─── Scanner: Stale ──────────────────────────────────────────────────────────

scan_stale() {
  local doc_files=("$@")
  local found=0

  log "Scanning stale content (${#doc_files[@]} doc files)..."

  for doc_file in "${doc_files[@]}"; do
    local rel_doc
    rel_doc=$(realpath --relative-to="$SCAN_ROOT" "$doc_file" 2>/dev/null || echo "$doc_file")
    log_verbose "  stale: checking $rel_doc"

    # ── Hardcoded counts that might not match reality ────────────────────────
    # Pattern: "N agents", "N scripts", "N workflows", etc.
    local count_patterns=()
    while IFS= read -r match; do
      [[ -n "$match" ]] && count_patterns+=("$match")
    done < <(
      grep -nP '\b\d+\s+(agents?|scripts?|workflows?|commands?|skills?|nodes?|files?|tests?|endpoints?)\b' \
        "$doc_file" 2>/dev/null | head -10 || true
    )

    if [[ ${#count_patterns[@]} -gt 0 ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local examples
      examples=$(printf '%s\n' "${count_patterns[@]}" | head -3 | tr '\n' '; ')

      local desc="Documentation contains hardcoded counts that may not match the current state of the codebase: ${examples}. Hardcoded numbers become stale as the project evolves."
      local fix="Replace hardcoded counts with dynamic references (e.g., 'see the full list in...') or verify and update each count against the actual codebase."
      local criteria='["No hardcoded counts that could drift","Count claims are either removed or verified accurate","Dynamic references used where counts change frequently"]'

      add_finding "$id" "stale-docs" "low" "documentation" "" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: ${#count_patterns[@]} hardcoded count(s) in $rel_doc"
    fi

    # ── Old API or command signatures ────────────────────────────────────────
    # Detect references to deprecated/renamed CLI flags or commands
    # Flag patterns: old flag names in common frameworks
    local deprecated_patterns=()
    while IFS= read -r match; do
      [[ -n "$match" ]] && deprecated_patterns+=("$match")
    done < <(
      grep -nP '\-\-no-verify|\-\-force-with-lease|npm run [a-z]' \
        "$doc_file" 2>/dev/null | head -5 || true
    )

    # ── TODO/FIXME markers in docs ───────────────────────────────────────────
    local todo_count
    todo_count=$(grep -cP '\bTODO\b|\bFIXME\b|\bXXX\b|\bHACK\b' "$doc_file" 2>/dev/null || echo 0)
    if [[ "$todo_count" -gt 0 ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")

      local desc="Documentation file contains $todo_count TODO/FIXME marker(s) indicating unfinished content. These markers indicate the doc was published before being complete."
      local fix="Resolve each TODO/FIXME: either complete the missing content, remove the placeholder, or file a separate issue tracking the work."
      local criteria='["No TODO/FIXME/XXX markers remain in the documentation","All placeholder sections are either completed or removed","Any tracked work items are filed as GitHub issues"]'

      add_finding "$id" "stale-docs" "low" "documentation" "" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: $todo_count TODO/FIXME marker(s) in $rel_doc"
    fi

    # ── Setup instructions that reference removed files or old steps ─────────
    # Check if doc references setup steps for files that don't exist
    local setup_refs=()
    while IFS= read -r match; do
      [[ -n "$match" ]] && setup_refs+=("$match")
    done < <(
      grep -nP '^\s*(cp|mv|touch|mkdir|install)\s+' "$doc_file" 2>/dev/null | head -5 || true
    )

    # For setup instructions, check if referenced files exist
    for setup_line in "${setup_refs[@]}"; do
      local lineno setup_target
      lineno=$(echo "$setup_line" | cut -d: -f1)
      setup_target=$(echo "$setup_line" | awk '{print $NF}' | tr -d '`"' | head -c 200)
      # Only flag if it looks like an existing path reference
      if echo "$setup_target" | grep -qP '[./]' && [[ ${#setup_target} -gt 3 ]]; then
        log_verbose "    Note: setup instruction in $rel_doc:$lineno references $setup_target"
      fi
    done
  done

  log "Stale scan: found $found potential issues"
}

# ─── Scanner: Duplicate ───────────────────────────────────────────────────────

scan_duplicate() {
  local doc_files=("$@")
  local found=0
  local file_count="${#doc_files[@]}"

  log "Scanning duplicate content ($file_count doc files)..."

  if [[ "$file_count" -lt 2 ]]; then
    log "  Skipping duplicate scan (need at least 2 files)"
    return 0
  fi

  # Extract paragraph blocks and compare across files
  # A paragraph block is MIN_LINES or more consecutive non-blank lines
  # Use a temp file instead of associative array for bash 3.2 compatibility
  local headings_tmp
  headings_tmp=$(mktemp)

  for doc_file in "${doc_files[@]}"; do
    local rel_doc
    rel_doc=$(realpath --relative-to="$SCAN_ROOT" "$doc_file" 2>/dev/null || echo "$doc_file")
    log_verbose "  duplicate: indexing $rel_doc"

    # Extract heading titles for cross-doc comparison
    # Write "normalized_heading TAB rel_doc" to temp file
    while IFS= read -r heading; do
      [[ -n "$heading" ]] || continue
      local normalized
      normalized=$(echo "$heading" | sed 's/^#+[[:space:]]*//' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      if [[ -n "$normalized" ]]; then
        printf '%s\t%s\n' "$normalized" "$rel_doc" >> "$headings_tmp"
      fi
    done < <(grep -P '^#{1,3}\s+\S' "$doc_file" 2>/dev/null || true)
  done

  # Find headings that appear in multiple docs (potential duplication)
  # Group by heading, collect files, emit entries where count >= 2
  local duplicate_headings=()
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && duplicate_headings+=("$entry")
  done < <(
    sort "$headings_tmp" 2>/dev/null | awk -F'\t' '
      {
        if ($1 != prev_heading) {
          if (prev_heading != "" && file_count >= 2) {
            print prev_heading " IN: " files_list
          }
          prev_heading = $1
          files_list = $2
          file_count = 1
        } else {
          files_list = files_list ", " $2
          file_count++
        }
      }
      END {
        if (prev_heading != "" && file_count >= 2) {
          print prev_heading " IN: " files_list
        }
      }
    ' || true
  )
  rm -f "$headings_tmp"

  if [[ ${#duplicate_headings[@]} -gt 0 ]]; then
    # Group into a single finding per N duplicates to avoid noise
    local batch_size=5
    local i=0
    while [[ $i -lt ${#duplicate_headings[@]} ]]; do
      local batch_items=()
      local j=0
      while [[ $j -lt $batch_size && $((i + j)) -lt ${#duplicate_headings[@]} ]]; do
        batch_items+=("${duplicate_headings[$((i + j))]}")
        j=$((j + 1))
      done

      local id
      id=$(format_id "$FINDING_COUNTER")
      local examples
      examples=$(printf '  - %s\n' "${batch_items[@]}" | head -10)
      local affected_files
      affected_files=$(printf '%s\n' "${doc_files[@]}" | head -5 \
        | while IFS= read -r f; do realpath --relative-to="$SCAN_ROOT" "$f" 2>/dev/null || echo "$f"; done \
        | jq -R . | jq -s .)

      local desc
      desc=$(printf 'The following section headings appear in multiple documentation files, indicating possible duplicate or diverging content:\n%s' "${examples}")
      local fix="Consolidate duplicate sections: choose the canonical location, redirect other occurrences with a brief summary and a link. Remove verbatim copies."
      local criteria='["Each concept is documented in exactly one canonical location","Other docs reference (not duplicate) the canonical doc","No copy-paste paragraphs exist across docs"]'

      add_finding "$id" "duplicate-docs" "low" "documentation-librarian" "documentation" \
        "$(echo "$affected_files" | jq -c .)" \
        "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: ${#batch_items[@]} duplicate heading(s)"

      i=$((i + batch_size))
    done
  fi

  # ── Large verbatim paragraph blocks shared across files ──────────────────
  # Compare files pairwise for long shared text blocks (simplified: line-hash approach)
  local checked_pairs=0
  for ((a=0; a<file_count; a++)); do
    for ((b=a+1; b<file_count; b++)); do
      local fa="${doc_files[$a]}"
      local fb="${doc_files[$b]}"
      local rel_fa rel_fb
      rel_fa=$(realpath --relative-to="$SCAN_ROOT" "$fa" 2>/dev/null || echo "$fa")
      rel_fb=$(realpath --relative-to="$SCAN_ROOT" "$fb" 2>/dev/null || echo "$fb")

      # Count common non-trivial lines (lines with >= 20 chars)
      local common_lines
      common_lines=$(comm -12 \
        <(grep -P '.{20,}' "$fa" 2>/dev/null | sort | uniq) \
        <(grep -P '.{20,}' "$fb" 2>/dev/null | sort | uniq) \
        2>/dev/null | wc -l || echo 0)

      local fa_lines
      fa_lines=$(wc -l < "$fa" 2>/dev/null | tr -d ' ' || echo 1)
      local similarity=0
      if [[ "$fa_lines" -gt 0 ]]; then
        similarity=$(( (common_lines * 100) / fa_lines ))
      fi

      log_verbose "    pairwise: $rel_fa vs $rel_fb: $common_lines common lines, $similarity% similarity"

      if [[ "$common_lines" -ge "$DUPLICATE_MIN_LINES" && "$similarity" -ge "$DUPLICATE_SIMILARITY" ]]; then
        local id
        id=$(format_id "$FINDING_COUNTER")

        local desc="Files '$rel_fa' and '$rel_fb' share approximately $common_lines common non-trivial lines ($similarity% similarity). This suggests significant copy-paste duplication between the documents."
        local fix="Extract the shared content into a canonical location. In one file, keep the full content. In the other, replace the duplicate with a brief summary and a link to the canonical source."
        local criteria='["Duplicated content exists in only one canonical file","Other file references (not duplicates) the canonical","Combined docs are shorter and more maintainable"]'

        add_finding "$id" "duplicate-docs" "medium" "documentation-librarian" "documentation" \
          "[\"$rel_fa\", \"$rel_fb\"]" "$desc" "$fix" "$criteria"
        found=$((found + 1))
        log_verbose "    → $id: duplicate content between $rel_fa and $rel_fb"
      fi

      checked_pairs=$((checked_pairs + 1))
      # Limit pairwise comparisons for performance
      if [[ "$checked_pairs" -ge 200 ]]; then
        log "  Duplicate pairwise comparison limit reached (200 pairs). Use --paths to narrow scope."
        break 2
      fi
    done
  done

  log "Duplicate scan: found $found potential issues"
}

# ─── Scanner: Orphan ─────────────────────────────────────────────────────────

scan_orphan() {
  local doc_files=("$@")
  local found=0

  log "Scanning orphan docs (${#doc_files[@]} doc files)..."

  # Determine the git root of the scan context (may differ from REPO_ROOT in tests)
  local scan_git_root
  scan_git_root=$(git -C "$SCAN_ROOT" rev-parse --show-toplevel 2>/dev/null || echo "$SCAN_ROOT")

  # Collect all files that reference docs
  local index_files=()
  while IFS= read -r f; do
    local full="$scan_git_root/$f"
    [[ -f "$full" ]] && index_files+=("$full")
  done < <(
    git -C "$scan_git_root" ls-files 2>/dev/null \
      | grep -P '\.(md|rst|txt|sh|py|ts|js)$' \
      | grep -v '^\.git' \
      || true
  )

  # Build set of all referenced doc paths (from links, includes, etc.)
  # Use a temp file instead of associative array for bash 3.2 compatibility
  local referenced_tmp
  referenced_tmp=$(mktemp)

  for idx_file in "${index_files[@]}"; do
    # Extract markdown links
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      # Normalize: strip anchor and leading ./
      local norm
      norm="${link%%#*}"
      norm=$(echo "$norm" | sed 's|^\./||')
      if [[ -n "$norm" ]]; then
        echo "$norm" >> "$referenced_tmp"
        # Also try relative to file's directory
        local file_dir
        file_dir=$(dirname "$idx_file")
        local rel_dir
        rel_dir=$(realpath --relative-to="$SCAN_ROOT" "$file_dir" 2>/dev/null || echo ".")
        if [[ "$rel_dir" != "." ]]; then
          echo "$rel_dir/$norm" >> "$referenced_tmp"
        fi
      fi
    done < <(grep -oP '(?<=\()[^)]+\.md(?=[)#])' "$idx_file" 2>/dev/null || true)

    # Also scan for references in CLAUDE.md and skill files by filename stems
    while IFS= read -r stem; do
      [[ -n "$stem" ]] || continue
      echo "$stem" >> "$referenced_tmp"
    done < <(
      grep -oP '[A-Z][A-Z_-]+(?=\.md)' "$idx_file" 2>/dev/null || true
    )
  done

  # Sort and deduplicate the referenced list
  sort -u "$referenced_tmp" -o "$referenced_tmp" 2>/dev/null || sort "$referenced_tmp" | uniq > "${referenced_tmp}.sorted" && mv "${referenced_tmp}.sorted" "$referenced_tmp" || true

  # Check each doc file against the referenced set
  for doc_file in "${doc_files[@]}"; do
    local rel_doc
    rel_doc=$(realpath --relative-to="$SCAN_ROOT" "$doc_file" 2>/dev/null || echo "$doc_file")
    local basename_doc
    basename_doc=$(basename "$doc_file")
    local stem_doc="${basename_doc%.*}"

    # Skip top-level README and CLAUDE.md - these are always the entry points
    if [[ "$basename_doc" =~ ^(README\.md|CLAUDE\.md|claude\.md|INDEX\.md)$ ]]; then
      log_verbose "  orphan: skipping index file $rel_doc"
      continue
    fi

    local is_referenced=false

    # Check by full relative path
    if grep -qxF "$rel_doc" "$referenced_tmp" 2>/dev/null; then
      is_referenced=true
    fi

    # Check by filename stem
    if grep -qxF "$stem_doc" "$referenced_tmp" 2>/dev/null; then
      is_referenced=true
    fi

    # Check by basename
    if grep -qxF "$basename_doc" "$referenced_tmp" 2>/dev/null; then
      is_referenced=true
    fi

    # Check if referenced by partial path search (slower but catches cross-dir links)
    if [[ "$is_referenced" == "false" ]]; then
      # grep for lines that are a substring of rel_doc or contain rel_doc
      if grep -qF "$rel_doc" "$referenced_tmp" 2>/dev/null; then
        is_referenced=true
      elif grep -qF "$stem_doc" "$referenced_tmp" 2>/dev/null; then
        is_referenced=true
      fi
    fi

    if [[ "$is_referenced" == "false" ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")

      local desc="Documentation file '$rel_doc' does not appear to be linked from any index, README, CLAUDE.md, or other documentation. Orphan docs are not discoverable by readers."
      local fix="Either: (1) add a link to this doc from the appropriate index or README, (2) include it in CLAUDE.md navigation if it's framework documentation, or (3) delete it if it's no longer relevant."
      local criteria='["Doc is reachable from at least one index/README/CLAUDE.md","Or doc is deliberately standalone with clear entry point","Or doc is archived/deleted if no longer relevant"]'

      add_finding "$id" "orphan-docs" "low" "documentation-librarian" "" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: orphan doc $rel_doc"
    else
      log_verbose "  orphan: referenced $rel_doc (ok)"
    fi
  done

  # Clean up temp file
  rm -f "$referenced_tmp"

  log "Orphan scan: found $found potential issues"
}

# ─── Scanner: Bloat ──────────────────────────────────────────────────────────

scan_bloat() {
  local doc_files=("$@")
  local found=0

  log "Scanning bloat (${#doc_files[@]} doc files)..."

  for doc_file in "${doc_files[@]}"; do
    local rel_doc
    rel_doc=$(realpath --relative-to="$SCAN_ROOT" "$doc_file" 2>/dev/null || echo "$doc_file")
    local total_lines
    total_lines=$(wc -l < "$doc_file" 2>/dev/null | tr -d ' ' || echo 0)
    log_verbose "  bloat: $rel_doc ($total_lines lines)"

    # ── Excessive length ────────────────────────────────────────────────────
    if [[ "$total_lines" -gt "$MAX_DOC_LINES" ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")
      local severity="low"
      if [[ "$total_lines" -gt $((MAX_DOC_LINES * 3)) ]]; then
        severity="medium"
      fi

      local desc="Documentation file '$rel_doc' is $total_lines lines long (threshold: $MAX_DOC_LINES). Very long docs are hard to navigate and often signal that multiple concerns are mixed together."
      local fix="Split this doc into focused sub-pages by topic. Create a brief summary/overview page that links to each sub-page. Consider using a table instead of long prose for reference content."
      local criteria='["Each resulting doc is under $MAX_DOC_LINES lines","All content from the original is preserved or intentionally removed","An index or summary links to each sub-page"]'

      add_finding "$id" "bloat-docs" "$severity" "documentation" "" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: doc too long ($total_lines lines)"
    fi

    # ── Excessive repetition within the document ────────────────────────────
    local total_nontrivial_lines
    total_nontrivial_lines=$(grep -cP '.{15,}' "$doc_file" 2>/dev/null || echo 0)
    local unique_lines
    unique_lines=$(grep -P '.{15,}' "$doc_file" 2>/dev/null | sort -u | wc -l || echo 0)

    if [[ "$total_nontrivial_lines" -gt 20 && "$unique_lines" -gt 0 ]]; then
      local repeat_pct
      repeat_pct=$(( (total_nontrivial_lines - unique_lines) * 100 / total_nontrivial_lines ))
      if [[ "$repeat_pct" -ge 40 ]]; then
        local id
        id=$(format_id "$FINDING_COUNTER")

        local desc="Documentation file '$rel_doc' has approximately $repeat_pct% line repetition (${total_nontrivial_lines} total non-trivial lines, ${unique_lines} unique). High internal repetition makes docs harder to maintain."
        local fix="Identify repeated patterns and consolidate them: use a table for repeated option/flag descriptions, extract common notes into a 'See also' section, use include/reference directives if supported."
        local criteria='["Repetition rate drops below 30%","Repeated information is consolidated into tables or shared sections","Doc is shorter and easier to scan"]'

        add_finding "$id" "bloat-docs" "low" "documentation" "" \
          "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
        found=$((found + 1))
        log_verbose "    → $id: $repeat_pct% repetition in $rel_doc"
      fi
    fi

    # ── Code comments that restate the code ────────────────────────────────
    # Check for inline code blocks with surrounding prose that duplicates the code
    local redundant_comments
    redundant_comments=$(awk '
      /^```/ { in_block = !in_block; next }
      !in_block && /^[[:space:]]*#.*[[:space:]]+(returns|gets|sets|calls|creates|deletes|updates)[[:space:]]/ {
        count++
      }
      END { print count+0 }
    ' "$doc_file" 2>/dev/null || echo 0)

    if [[ "$redundant_comments" -ge 3 ]]; then
      local id
      id=$(format_id "$FINDING_COUNTER")

      local desc="Documentation file '$rel_doc' contains approximately $redundant_comments prose lines that may restate what code examples already show. This is a common form of documentation bloat."
      local fix="Review each prose description adjacent to a code block. If the prose just restates what the code does, remove or replace it with a brief 'why' explanation instead of 'what'."
      local criteria='["Prose adds context, not just restates the code","Documentation is shorter and focuses on intent","Code examples speak for themselves where self-explanatory"]'

      add_finding "$id" "bloat-docs" "low" "documentation" "" \
        "[\"$rel_doc\"]" "$desc" "$fix" "$criteria"
      found=$((found + 1))
      log_verbose "    → $id: $redundant_comments potential redundant prose lines in $rel_doc"
    fi
  done

  log "Bloat scan: found $found potential issues"
}

# ─── Output ───────────────────────────────────────────────────────────────────

write_output() {
  local output

  if [[ "$APPEND" == "true" && -f "$OUTPUT_FILE" ]]; then
    # Merge existing findings with new ones, reassigning IDs to avoid conflicts
    local existing_count
    existing_count=$(jq 'length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    output=$(jq -s '.[0] + .[1]' "$OUTPUT_FILE" <(echo "$FINDINGS_JSON") 2>/dev/null || echo "$FINDINGS_JSON")
  else
    output="$FINDINGS_JSON"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "$output" | jq .
  else
    local dir
    dir=$(dirname "$OUTPUT_FILE")
    mkdir -p "$dir"
    echo "$output" | jq . > "$OUTPUT_FILE"
    local count
    count=$(echo "$output" | jq 'length')
    log "Wrote $count findings to $OUTPUT_FILE"
  fi
}

# ─── Summary ─────────────────────────────────────────────────────────────────

print_summary() {
  local count
  count=$(echo "$FINDINGS_JSON" | jq 'length')
  local critical_count high_count medium_count low_count

  critical_count=$(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "critical")] | length')
  high_count=$(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "high")] | length')
  medium_count=$(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "medium")] | length')
  low_count=$(echo "$FINDINGS_JSON" | jq '[.[] | select(.severity == "low")] | length')

  log "────────────────────────────────────────"
  log "Documentation scan complete"
  log "  Total findings: $count"
  log "  Critical: $critical_count | High: $high_count | Medium: $medium_count | Low: $low_count"

  if [[ "$count" -gt 0 ]]; then
    echo "$FINDINGS_JSON" | jq -r '.[] | "  [\(.severity | ascii_upcase)] \(.id) [\(.category)] \(.file_paths[0])"' >&2 || true
  fi
  log "────────────────────────────────────────"
}

# ─── Main ────────────────────────────────────────────────────────────────────

main() {
  check_deps

  log "Documentation scanner v$SCANNER_VERSION"
  log "Categories: $CATEGORIES"
  log "Output: $OUTPUT_FILE"

  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN mode - findings will not be written to file"
  fi

  # Collect files to scan (bash 3.2-compatible alternative to mapfile)
  DOC_FILES=()
  while IFS= read -r _line; do
    [[ -n "$_line" ]] && DOC_FILES+=("$_line")
  done < <(collect_doc_files)

  if [[ "${#DOC_FILES[@]}" -eq 0 ]]; then
    log "No documentation files found to scan"
    if [[ "$DRY_RUN" != "true" ]]; then
      local dir
      dir=$(dirname "$OUTPUT_FILE")
      mkdir -p "$dir"
      echo "[]" > "$OUTPUT_FILE"
    fi
    exit 0
  fi

  log "Found ${#DOC_FILES[@]} documentation files to scan"

  # Run enabled scanners
  category_enabled "obsolete"   && scan_obsolete   "${DOC_FILES[@]}"
  category_enabled "stale"      && scan_stale      "${DOC_FILES[@]}"
  category_enabled "duplicate"  && scan_duplicate  "${DOC_FILES[@]}"
  category_enabled "orphan"     && scan_orphan     "${DOC_FILES[@]}"
  category_enabled "bloat"      && scan_bloat      "${DOC_FILES[@]}"

  print_summary
  write_output

  # Exit code based on findings
  local total
  total=$(echo "$FINDINGS_JSON" | jq 'length')
  if [[ "$HAS_HIGH_CRITICAL" == "true" ]]; then
    exit 1
  elif [[ "$total" -gt 0 ]]; then
    exit 0
  else
    exit 0
  fi
}

main "$@"
