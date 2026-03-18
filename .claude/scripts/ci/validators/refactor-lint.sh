#!/usr/bin/env bash
# refactor-lint.sh
# CI-friendly refactor scan that runs all dimensions and exits with appropriate code.
#
# DESCRIPTION:
#   Designed for use in CI/CD pipelines. Runs all refactor scanners, outputs
#   a JSON report to stdout, and exits with:
#     0 - clean (no findings)
#     1 - findings present (medium/low)
#     2 - critical or high findings (blocking)
#
# USAGE:
#   ./scripts/ci/refactor-lint.sh [OPTIONS]
#
# OPTIONS:
#   --scope changed       Only scan files changed since last commit (faster)
#   --severity high       Only report high/critical findings (strict CI mode)
#   --severity medium     Report medium+ findings
#   --output-file FILE    Write JSON report to file (default: stdout only)
#   --no-color            Disable colored output
#   --quiet               Suppress stderr progress output
#   --help                Show this help
#
# EXIT CODES:
#   0  Clean — no findings (or no findings at or above --severity threshold)
#   1  Findings present — medium/low issues found
#   2  Critical/high findings — blocking issues require attention
#
# INTEGRATION:
#   Add to CI pipeline:
#     - name: Refactor lint
#       run: ./scripts/ci/refactor-lint.sh --scope changed --severity high
#
#   Or use as a pre-commit check:
#     ./scripts/ci/refactor-lint.sh --scope changed
#
# NOTES:
#   - Requires: bash 4+, jq
#   - Scanner scripts must exist in scripts/ directory
#   - READ-ONLY: does not modify any source files

set -euo pipefail

# ─── Defaults ────────────────────────────────────────────────────────────────

SCOPE="${SCOPE:-full}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-low}"   # low = report all
OUTPUT_FILE="${OUTPUT_FILE:-}"
NO_COLOR="${NO_COLOR:-false}"
QUIET="${QUIET:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Scanner scripts
SCANNERS=(
  "code:scan-code-quality.sh:.refactor/findings-code.json"
  "docs:scan-docs.sh:.refactor/findings-docs.json"
  "deps:dep-scan.sh:.refactor/findings-deps.json"
  "tests:test-scan.sh:.refactor/findings-tests.json"
  "arch:arch-scan.sh:.refactor/findings-arch.json"
  "framework:framework-scan.sh:.refactor/findings-framework.json"
)

# ─── Argument parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -50
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)        SCOPE="$2"; shift 2 ;;
    --severity)     SEVERITY_THRESHOLD="$2"; shift 2 ;;
    --output-file)  OUTPUT_FILE="$2"; shift 2 ;;
    --no-color)     NO_COLOR="true"; shift ;;
    --quiet)        QUIET="true"; shift ;;
    --help|-h)      show_help ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ─── Utilities ────────────────────────────────────────────────────────────────

log() {
  if [[ "$QUIET" != "true" ]]; then
    echo "[refactor-lint] $*" >&2
  fi
}

check_deps() {
  local missing=()
  for cmd in jq; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required commands: ${missing[*]}" >&2
    exit 2
  fi
}

# Severity to numeric for comparison
severity_to_num() {
  case "$1" in
    critical) echo 0 ;;
    high)     echo 1 ;;
    medium)   echo 2 ;;
    low)      echo 3 ;;
    *)        echo 4 ;;
  esac
}

# ─── Run scanners ─────────────────────────────────────────────────────────────

run_scanners() {
  mkdir -p "$REPO_ROOT/.refactor"

  local scope_flags=""
  if [[ "$SCOPE" == "changed" ]]; then
    scope_flags="--changed-files-only"
    log "Scope: changed files only"
  else
    log "Scope: full repository"
  fi

  local ran_count=0
  local failed_count=0

  for entry in "${SCANNERS[@]}"; do
    local dimension script output_file
    dimension="${entry%%:*}"
    rest="${entry#*:}"
    script="${rest%%:*}"
    output_file="${rest#*:}"

    local script_path="$REPO_ROOT/scripts/$script"

    if [[ ! -f "$script_path" ]]; then
      log "WARNING: Scanner not found: $script_path (skipping $dimension)"
      continue
    fi

    log "Running $dimension scanner..."

    # Run scanner, capture exit code (1 = findings, not fatal)
    local exit_code=0
    if ! "$script_path" $scope_flags \
        --output-file "$REPO_ROOT/$output_file" \
        2>/dev/null; then
      exit_code=$?
      # Exit code 1 means findings found — not a fatal error for CI
      if [[ "$exit_code" -gt 1 ]]; then
        log "WARNING: $dimension scanner failed with exit code $exit_code"
        failed_count=$((failed_count + 1))
      fi
    fi

    ran_count=$((ran_count + 1))
  done

  log "Scanners completed: $ran_count ran, $failed_count failed"
}

# ─── Merge findings ───────────────────────────────────────────────────────────

merge_findings() {
  local merged_file="$REPO_ROOT/.refactor/findings.json"
  local finding_files=()

  for entry in "${SCANNERS[@]}"; do
    local output_file="${entry##*:}"
    local full_path="$REPO_ROOT/$output_file"
    if [[ -f "$full_path" ]]; then
      finding_files+=("$full_path")
    fi
  done

  if [[ ${#finding_files[@]} -eq 0 ]]; then
    echo "[]" > "$merged_file"
    log "No finding files produced"
    return
  fi

  # Merge all arrays
  jq -s 'add // []' "${finding_files[@]}" > "$merged_file"

  local total
  total=$(jq 'length' "$merged_file")
  log "Total findings before filter: $total"
}

# ─── Filter by severity threshold ─────────────────────────────────────────────

filter_findings() {
  local findings_file="$REPO_ROOT/.refactor/findings.json"
  local threshold_num
  threshold_num=$(severity_to_num "$SEVERITY_THRESHOLD")

  local filtered
  filtered=$(jq --argjson thresh "$threshold_num" '
    map(
      . as $f |
      (
        if .severity == "critical" then 0
        elif .severity == "high" then 1
        elif .severity == "medium" then 2
        else 3 end
      ) as $sev_num |
      select($sev_num <= $thresh)
    )
  ' "$findings_file")

  echo "$filtered"
}

# ─── Build JSON report ────────────────────────────────────────────────────────

build_report() {
  local findings="$1"

  local total critical high medium low scanned_at
  total=$(echo "$findings" | jq 'length')
  critical=$(echo "$findings" | jq '[.[] | select(.severity == "critical")] | length')
  high=$(echo "$findings" | jq '[.[] | select(.severity == "high")] | length')
  medium=$(echo "$findings" | jq '[.[] | select(.severity == "medium")] | length')
  low=$(echo "$findings" | jq '[.[] | select(.severity == "low")] | length')
  scanned_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Determine dimensions scanned
  local dimensions_scanned=()
  for entry in "${SCANNERS[@]}"; do
    local dimension="${entry%%:*}"
    local output_file="${entry##*:}"
    if [[ -f "$REPO_ROOT/$output_file" ]]; then
      dimensions_scanned+=("\"$dimension\"")
    fi
  done
  local dims_json="[$(IFS=,; echo "${dimensions_scanned[*]}")]"

  jq -n \
    --arg scanned_at "$scanned_at" \
    --arg scope "$SCOPE" \
    --arg severity_threshold "$SEVERITY_THRESHOLD" \
    --argjson dimensions "$dims_json" \
    --argjson total "$total" \
    --argjson critical "$critical" \
    --argjson high "$high" \
    --argjson medium "$medium" \
    --argjson low "$low" \
    --argjson findings "$findings" \
    '{
      scanned_at: $scanned_at,
      scope: $scope,
      severity_threshold: $severity_threshold,
      dimensions: $dimensions,
      summary: {
        total: $total,
        critical: $critical,
        high: $high,
        medium: $medium,
        low: $low
      },
      findings: $findings
    }'
}

# ─── Determine exit code ──────────────────────────────────────────────────────

determine_exit_code() {
  local findings="$1"

  local critical high
  critical=$(echo "$findings" | jq '[.[] | select(.severity == "critical")] | length')
  high=$(echo "$findings" | jq '[.[] | select(.severity == "high")] | length')
  local total
  total=$(echo "$findings" | jq 'length')

  if [[ "$critical" -gt 0 || "$high" -gt 0 ]]; then
    echo 2
  elif [[ "$total" -gt 0 ]]; then
    echo 1
  else
    echo 0
  fi
}

# ─── Human-readable summary to stderr ─────────────────────────────────────────

print_summary() {
  local findings="$1"
  local exit_code="$2"

  if [[ "$QUIET" == "true" ]]; then
    return
  fi

  local total critical high medium low
  total=$(echo "$findings" | jq 'length')
  critical=$(echo "$findings" | jq '[.[] | select(.severity == "critical")] | length')
  high=$(echo "$findings" | jq '[.[] | select(.severity == "high")] | length')
  medium=$(echo "$findings" | jq '[.[] | select(.severity == "medium")] | length')
  low=$(echo "$findings" | jq '[.[] | select(.severity == "low")] | length')

  echo "" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "  REFACTOR LINT RESULTS" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
  echo "  Scope:      $SCOPE" >&2
  echo "  Severity:   $SEVERITY_THRESHOLD+" >&2
  echo "  Total:      $total findings" >&2
  echo "" >&2
  echo "  Critical:   $critical" >&2
  echo "  High:       $high" >&2
  echo "  Medium:     $medium" >&2
  echo "  Low:        $low" >&2
  echo "" >&2

  if [[ "$exit_code" -eq 0 ]]; then
    echo "  ✅ PASS — No findings at severity threshold ($SEVERITY_THRESHOLD+)" >&2
  elif [[ "$exit_code" -eq 1 ]]; then
    echo "  ⚠️  WARN — Findings present (non-blocking)" >&2
  else
    echo "  ❌ FAIL — Critical/high findings require attention" >&2
  fi

  echo "" >&2

  # Show top findings
  if [[ "$total" -gt 0 ]]; then
    echo "  Top findings:" >&2
    echo "$findings" | jq -r '
      sort_by(
        if .severity == "critical" then 0
        elif .severity == "high" then 1
        elif .severity == "medium" then 2
        else 3 end
      ) | .[0:5] |
      .[] |
      "  [" + .severity + "] " + .id + " — " + (.file_paths[0] // "unknown") + ": " + .description[0:80]
    ' >&2 2>/dev/null || true
  fi

  echo "" >&2
  echo "  To fix: /refactor --fix" >&2
  echo "  Full report: /refactor --audit" >&2
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
  echo "" >&2
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_deps

  log "refactor-lint starting (scope=$SCOPE, severity>=$SEVERITY_THRESHOLD)"

  # Step 1: Run all scanners
  run_scanners

  # Step 2: Merge findings
  merge_findings

  # Step 3: Filter by severity threshold
  local filtered_findings
  filtered_findings=$(filter_findings)

  # Step 4: Build JSON report
  local report
  report=$(build_report "$filtered_findings")

  # Step 5: Determine exit code
  local exit_code
  exit_code=$(determine_exit_code "$filtered_findings")

  # Step 6: Output JSON report
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" | jq '.' > "$OUTPUT_FILE"
    log "Report written to: $OUTPUT_FILE"
    # Also print to stdout
    echo "$report" | jq '.'
  else
    echo "$report" | jq '.'
  fi

  # Step 7: Print human-readable summary to stderr
  print_summary "$filtered_findings" "$exit_code"

  exit "$exit_code"
}

main "$@"
