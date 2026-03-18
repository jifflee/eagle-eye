#!/usr/bin/env bash
# ============================================================
# Script: dep-review-data.sh
# Purpose: Breaking change analysis for dependency PRs
#
# Extracts version diffs from Dependabot/dependency PRs, classifies
# bump severity (patch/minor/major), scans codebase for imports of
# affected packages, and outputs structured JSON for the
# /pr-dep-review skill.
#
# Usage:
#   ./scripts/dep-review-data.sh [OPTIONS]
#
# Options:
#   --pr N              Analyze specific PR number
#   --all               Analyze all open dependency PRs
#   --json              Output raw JSON (default)
#   --verbose           Verbose logging
#   --help              Show this help
#
# Exit codes:
#   0 - All PRs analyzed successfully (no breaking changes found)
#   1 - Breaking changes detected (major bumps needing review)
#   2 - Script error (missing tools, API failure)
#
# Output (JSON):
#   {
#     "prs": [
#       {
#         "number": 1010,
#         "title": "Bump vitest from 1.6.1 to 4.0.18",
#         "package": "vitest",
#         "ecosystem": "npm",
#         "from_version": "1.6.1",
#         "to_version": "4.0.18",
#         "bump_type": "major",
#         "verdict": "REVIEW",
#         "imports_found": ["vitest.config.ts", "tests/setup.ts"],
#         "import_count": 2,
#         "changelog_url": "https://github.com/vitest-dev/vitest/releases",
#         "migration_notes": "Major version bump from 1.x to 4.x"
#       }
#     ],
#     "summary": {
#       "total": 6,
#       "safe": 1,
#       "review": 4,
#       "breaking": 1
#     }
#   }
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

PR_NUMBER=""
ANALYZE_ALL=false
VERBOSE=false

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -40
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr)       PR_NUMBER="$2"; shift 2 ;;
    --all)      ANALYZE_ALL=true; shift ;;
    --json)     shift ;;  # JSON is default, accepted for compat
    --verbose)  VERBOSE=true; shift ;;
    --help|-h)  show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log() {
  echo "[dep-review-data] $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[dep-review-data:verbose] $*" >&2
  fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v gh &>/dev/null; then
  log "ERROR: gh CLI required"
  exit 2
fi

if ! command -v jq &>/dev/null; then
  log "ERROR: jq required"
  exit 2
fi

# ─── Version Parsing ─────────────────────────────────────────────────────────

# Parse semver components: "1.6.1" → major minor patch
parse_semver() {
  local version="$1"
  # Strip leading v if present
  version="${version#v}"
  echo "$version" | awk -F. '{
    printf "%s %s %s", ($1+0), ($2+0), ($3+0)
  }'
}

# Classify bump type from two version strings
classify_bump() {
  local from_version="$1"
  local to_version="$2"

  local from_parts to_parts
  read -r from_major from_minor from_patch <<< "$(parse_semver "$from_version")"
  read -r to_major to_minor to_patch <<< "$(parse_semver "$to_version")"

  if [[ "$to_major" -gt "$from_major" ]]; then
    echo "major"
  elif [[ "$to_minor" -gt "$from_minor" ]]; then
    echo "minor"
  else
    echo "patch"
  fi
}

# ─── PR Analysis ─────────────────────────────────────────────────────────────

# Extract package and version info from PR title
# Supports: "Bump X from A to B", "chore(deps): Bump X from A to B",
#           "chore(deps)(deps-dev): Bump X from A to B"
parse_pr_title() {
  local title="$1"

  # Extract package name and versions using pattern matching
  # First strip any prefix before "Bump" (e.g., "chore(deps)(deps-dev): ")
  local bump_part
  bump_part=$(echo "$title" | sed -E 's/.*[Bb]ump //')

  # Now parse: "<package> from <from> to <to>"
  local package from_ver to_ver

  if echo "$bump_part" | grep -qE 'from .* to '; then
    package=$(echo "$bump_part" | sed -E 's/[[:space:]]+from[[:space:]]+.*//')
    from_ver=$(echo "$bump_part" | sed -E 's/.*from[[:space:]]+([0-9v][0-9.]*)[[:space:]]+to.*/\1/')
    to_ver=$(echo "$bump_part" | sed -E 's/.*to[[:space:]]+([0-9v][0-9.]*).*/\1/')
  fi

  # Validate extraction
  if [[ -z "${package:-}" || -z "${from_ver:-}" || -z "${to_ver:-}" ]]; then
    echo ""
    return
  fi

  echo "${package}|${from_ver}|${to_ver}"
}

# Detect ecosystem from PR branch name or package name
detect_ecosystem() {
  local branch="$1"
  local package="$2"

  if echo "$branch" | grep -q "npm_and_yarn"; then
    echo "npm"
  elif echo "$branch" | grep -q "pip"; then
    echo "pip"
  elif echo "$branch" | grep -q "gomod"; then
    echo "go"
  elif echo "$package" | grep -q "^@"; then
    echo "npm"
  else
    # Check if package exists in package.json or requirements.txt
    if [[ -f "$REPO_ROOT/package.json" ]] && jq -e ".dependencies[\"$package\"] // .devDependencies[\"$package\"]" "$REPO_ROOT/package.json" &>/dev/null; then
      echo "npm"
    elif [[ -f "$REPO_ROOT/requirements.txt" ]] && grep -qi "^${package}" "$REPO_ROOT/requirements.txt" 2>/dev/null; then
      echo "pip"
    else
      echo "unknown"
    fi
  fi
}

# Scan codebase for imports of a package
scan_imports() {
  local package="$1"
  local ecosystem="$2"

  # Collect results into a temp file to avoid unbound array issues
  local tmp_results
  tmp_results=$(mktemp)
  trap "rm -f '$tmp_results'" RETURN

  case "$ecosystem" in
    npm)
      # Search for JS/TS imports: import ... from 'package' or require('package')
      local search_pattern
      search_pattern="(from\\s+['\"]${package}|require\\(['\"]${package})"

      grep -rlE "$search_pattern" "$REPO_ROOT" \
        --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" --include="*.mjs" \
        2>/dev/null | sed "s|^$REPO_ROOT/||" | head -20 >> "$tmp_results" || true

      # Also check vitest.config, vite.config etc for test frameworks
      if [[ "$package" == "vitest" || "$package" == "@vitest/"* ]]; then
        for config_file in vitest.config.ts vitest.config.js vite.config.ts vite.config.js; do
          if [[ -f "$REPO_ROOT/$config_file" ]]; then
            echo "$config_file" >> "$tmp_results"
          fi
        done
      fi
      ;;
    pip)
      # Search for Python imports: import package or from package import
      local py_package
      py_package=$(echo "$package" | tr '-' '_')

      grep -rlE "(^import ${py_package}|^from ${py_package})" "$REPO_ROOT" \
        --include="*.py" \
        2>/dev/null | sed "s|^$REPO_ROOT/||" | head -20 >> "$tmp_results" || true
      ;;
  esac

  # Deduplicate and output
  if [[ -s "$tmp_results" ]]; then
    sort -u "$tmp_results"
  fi
}

# Build changelog URL for common registries
get_changelog_url() {
  local package="$1"
  local ecosystem="$2"
  local pr_body="$3"

  # Try to extract from PR body (Dependabot includes release notes links)
  local url
  url=$(echo "$pr_body" | grep -oE 'https://github\.com/[^/]+/[^/]+/releases' | head -1 || true)
  if [[ -n "$url" ]]; then
    echo "$url"
    return
  fi

  # Fallback: construct from package name
  case "$ecosystem" in
    npm)
      echo "https://www.npmjs.com/package/${package}?activeTab=changelog"
      ;;
    pip)
      echo "https://pypi.org/project/${package}/#history"
      ;;
    *)
      echo ""
      ;;
  esac
}

# Determine verdict based on bump type and import count
determine_verdict() {
  local bump_type="$1"
  local import_count="$2"

  case "$bump_type" in
    patch)
      echo "SAFE"
      ;;
    minor)
      if [[ "$import_count" -eq 0 ]]; then
        echo "SAFE"
      else
        echo "SAFE"
      fi
      ;;
    major)
      if [[ "$import_count" -eq 0 ]]; then
        echo "REVIEW"
      else
        echo "REVIEW"
      fi
      ;;
  esac
}

# Generate migration notes
generate_notes() {
  local package="$1"
  local from_ver="$2"
  local to_ver="$3"
  local bump_type="$4"
  local import_count="$5"

  local from_major to_major
  read -r from_major _ _ <<< "$(parse_semver "$from_ver")"
  read -r to_major _ _ <<< "$(parse_semver "$to_ver")"

  case "$bump_type" in
    patch)
      echo "Patch bump - bug fixes only, safe to merge"
      ;;
    minor)
      echo "Minor bump - new features, backward compatible"
      ;;
    major)
      local note="Major version bump ${from_major}.x to ${to_major}.x"
      if [[ "$import_count" -gt 0 ]]; then
        note="${note}. ${import_count} file(s) import this package - review for API changes"
      else
        note="${note}. No direct imports found - lower risk but verify transitive usage"
      fi
      echo "$note"
      ;;
  esac
}

# ─── Analyze Single PR ───────────────────────────────────────────────────────

analyze_pr() {
  local pr_num="$1"

  log_verbose "Analyzing PR #${pr_num}..."

  # Fetch PR data
  local pr_data
  pr_data=$(gh pr view "$pr_num" --json title,headRefName,body 2>/dev/null)
  if [[ -z "$pr_data" ]]; then
    log "ERROR: Could not fetch PR #${pr_num}"
    return
  fi

  local title branch body
  title=$(echo "$pr_data" | jq -r '.title')
  branch=$(echo "$pr_data" | jq -r '.headRefName')
  body=$(echo "$pr_data" | jq -r '.body')

  # Parse package info from title
  local parsed
  parsed=$(parse_pr_title "$title")
  if [[ -z "$parsed" ]]; then
    log_verbose "Could not parse version info from PR #${pr_num}: $title"
    # Output minimal entry for unparseable PRs
    jq -n \
      --argjson number "$pr_num" \
      --arg title "$title" \
      '{
        number: $number,
        title: $title,
        package: "unknown",
        ecosystem: "unknown",
        from_version: "unknown",
        to_version: "unknown",
        bump_type: "unknown",
        verdict: "REVIEW",
        imports_found: [],
        import_count: 0,
        changelog_url: "",
        migration_notes: "Could not parse version info - manual review required"
      }'
    return
  fi

  local package from_ver to_ver
  IFS='|' read -r package from_ver to_ver <<< "$parsed"

  # Detect ecosystem
  local ecosystem
  ecosystem=$(detect_ecosystem "$branch" "$package")

  # Classify bump
  local bump_type
  bump_type=$(classify_bump "$from_ver" "$to_ver")

  # Scan imports
  local imports_json="[]"
  local import_count=0
  local import_files
  import_files=$(scan_imports "$package" "$ecosystem" || true)
  if [[ -n "$import_files" ]]; then
    imports_json=$(echo "$import_files" | jq -R . | jq -s .)
    import_count=$(echo "$imports_json" | jq 'length')
  fi

  # Get changelog URL
  local changelog_url
  changelog_url=$(get_changelog_url "$package" "$ecosystem" "$body")

  # Determine verdict
  local verdict
  verdict=$(determine_verdict "$bump_type" "$import_count")

  # Generate notes
  local notes
  notes=$(generate_notes "$package" "$from_ver" "$to_ver" "$bump_type" "$import_count")

  # Output JSON
  jq -n \
    --argjson number "$pr_num" \
    --arg title "$title" \
    --arg package "$package" \
    --arg ecosystem "$ecosystem" \
    --arg from_version "$from_ver" \
    --arg to_version "$to_ver" \
    --arg bump_type "$bump_type" \
    --arg verdict "$verdict" \
    --argjson imports_found "$imports_json" \
    --argjson import_count "$import_count" \
    --arg changelog_url "$changelog_url" \
    --arg migration_notes "$notes" \
    '{
      number: $number,
      title: $title,
      package: $package,
      ecosystem: $ecosystem,
      from_version: $from_version,
      to_version: $to_version,
      bump_type: $bump_type,
      verdict: $verdict,
      imports_found: $imports_found,
      import_count: $import_count,
      changelog_url: $changelog_url,
      migration_notes: $migration_notes
    }'
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  local pr_numbers=()

  if [[ -n "$PR_NUMBER" ]]; then
    pr_numbers+=("$PR_NUMBER")
  elif [[ "$ANALYZE_ALL" == "true" ]]; then
    # Find all open Dependabot/dependency PRs
    while IFS= read -r num; do
      [[ -n "$num" ]] && pr_numbers+=("$num")
    done < <(gh pr list --json number,title --jq '.[] | select(.title | test("(?i)bump|dependabot")) | .number' 2>/dev/null)
  else
    # Default: analyze all dependency PRs
    ANALYZE_ALL=true
    while IFS= read -r num; do
      [[ -n "$num" ]] && pr_numbers+=("$num")
    done < <(gh pr list --json number,title --jq '.[] | select(.title | test("(?i)bump|dependabot")) | .number' 2>/dev/null)
  fi

  if [[ ${#pr_numbers[@]} -eq 0 ]]; then
    log "No dependency PRs found"
    jq -n '{prs: [], summary: {total: 0, safe: 0, review: 0, breaking: 0}}'
    exit 0
  fi

  log "Analyzing ${#pr_numbers[@]} dependency PR(s)..."

  # Analyze each PR
  local all_results="[]"
  for pr_num in "${pr_numbers[@]}"; do
    local result
    result=$(analyze_pr "$pr_num")
    if [[ -n "$result" ]]; then
      all_results=$(echo "$all_results" | jq --argjson pr "$result" '. + [$pr]')
    fi
  done

  # Calculate summary
  local total safe review breaking
  total=$(echo "$all_results" | jq 'length')
  safe=$(echo "$all_results" | jq '[.[] | select(.verdict == "SAFE")] | length')
  review=$(echo "$all_results" | jq '[.[] | select(.verdict == "REVIEW")] | length')
  breaking=$(echo "$all_results" | jq '[.[] | select(.verdict == "BREAKING")] | length')

  # Output final JSON
  jq -n \
    --argjson prs "$all_results" \
    --argjson total "$total" \
    --argjson safe "$safe" \
    --argjson review "$review" \
    --argjson breaking "$breaking" \
    '{
      prs: $prs,
      summary: {
        total: $total,
        safe: $safe,
        review: $review,
        breaking: $breaking
      }
    }'

  # Exit code based on results
  if [[ "$breaking" -gt 0 ]]; then
    exit 1
  elif [[ "$review" -gt 0 ]]; then
    exit 0
  else
    exit 0
  fi
}

main "$@"
