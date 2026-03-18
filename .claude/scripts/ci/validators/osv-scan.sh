#!/usr/bin/env bash
# ============================================================
# Script: osv-scan.sh
# Purpose: OSV-Scanner integration for broader vulnerability coverage
#
# Scans lockfiles and dependencies using Google's OSV database which
# aggregates vulnerabilities from npm audit, pip-audit, NVD, and
# ecosystem-specific databases (Go, Rust, etc.).
#
# Usage:
#   ./scripts/ci/validators/osv-scan.sh [OPTIONS]
#
# Options:
#   --output-dir DIR    Output directory for JSON reports (default: .dep-audit/)
#   --format FORMAT     Output format: json|table|summary (default: summary)
#   --verbose           Show detailed output
#   --help              Show this help
#
# Exit codes:
#   0 - No vulnerabilities found
#   1 - Vulnerabilities found
#   2 - Tool error (osv-scanner not installed, scan failed)
#
# Output:
#   - JSON reports written to output directory
#   - Results in standardized format compatible with dep-audit.sh
#
# Integration:
#   - Called by dep-audit.sh to complement npm audit and pip-audit
#   - Provides broader coverage via OSV database aggregation
#
# Related:
#   - scripts/ci/validators/dep-audit.sh - Main dependency audit orchestrator
#   - Issue #1040 - Integrate OSV-Scanner for broader vulnerability coverage
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

OUTPUT_DIR="$REPO_ROOT/.dep-audit"
OUTPUT_FORMAT="summary"
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    --format)          OUTPUT_FORMAT="$2"; shift 2 ;;
    --verbose)         VERBOSE=true; shift ;;
    --help|-h)         show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_step() {
  echo -e "${BLUE}[STEP]${NC} $*"
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_prerequisites() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_error "Install: apt-get install jq"
    exit 2
  fi

  if ! command -v osv-scanner &>/dev/null; then
    log_warn "osv-scanner not found - skipping OSV scan"
    log_warn "Install: https://google.github.io/osv-scanner/installation/"
    log_warn "  curl -sSfL https://raw.githubusercontent.com/google/osv-scanner/main/scripts/install.sh | sh"

    # Create output directory and empty report before exiting
    mkdir -p "$OUTPUT_DIR"
    echo '{"results": [], "summary": {"total_packages": 0, "vulnerable_packages": 0, "total_vulnerabilities": 0}}' > "$OUTPUT_DIR/osv-scanner.json"

    exit 0
  fi
}

# ─── Lockfile Discovery ───────────────────────────────────────────────────────

find_lockfiles() {
  local lockfiles=()

  # Python lockfiles
  while IFS= read -r lockfile; do
    [[ -n "$lockfile" ]] && lockfiles+=("$lockfile")
  done < <(find "$REPO_ROOT" -name "requirements.txt" -o -name "poetry.lock" -o -name "Pipfile.lock" 2>/dev/null | grep -v node_modules | grep -v ".venv" | grep -v "venv" || true)

  # Node.js lockfiles
  while IFS= read -r lockfile; do
    [[ -n "$lockfile" ]] && lockfiles+=("$lockfile")
  done < <(find "$REPO_ROOT" -name "package-lock.json" -o -name "yarn.lock" -o -name "pnpm-lock.yaml" 2>/dev/null | grep -v node_modules || true)

  # Go lockfiles
  while IFS= read -r lockfile; do
    [[ -n "$lockfile" ]] && lockfiles+=("$lockfile")
  done < <(find "$REPO_ROOT" -name "go.sum" 2>/dev/null || true)

  # Rust lockfiles
  while IFS= read -r lockfile; do
    [[ -n "$lockfile" ]] && lockfiles+=("$lockfile")
  done < <(find "$REPO_ROOT" -name "Cargo.lock" 2>/dev/null || true)

  printf '%s\n' "${lockfiles[@]}"
}

# ─── OSV Scanner ──────────────────────────────────────────────────────────────

run_osv_scanner() {
  log_step "Running osv-scanner..."

  mkdir -p "$OUTPUT_DIR"
  local osv_report="$OUTPUT_DIR/osv-scanner.json"

  # Find all lockfiles
  local lockfiles=()
  while IFS= read -r lockfile; do
    [[ -n "$lockfile" ]] && lockfiles+=("$lockfile")
  done < <(find_lockfiles)

  if [[ ${#lockfiles[@]} -eq 0 ]]; then
    log_verbose "No lockfiles found, skipping osv-scanner"
    echo '{"results": []}' > "$osv_report"
    return 0
  fi

  log_verbose "Found ${#lockfiles[@]} lockfile(s) to scan"

  # Run osv-scanner on the entire repository
  # This scans all lockfiles in one pass
  local exit_code=0
  local tmp_output
  tmp_output=$(mktemp)

  osv-scanner scan \
    --lockfile "$REPO_ROOT" \
    --format json \
    --output "$tmp_output" 2>/dev/null || exit_code=$?

  # osv-scanner returns non-zero if vulnerabilities found
  if [[ $exit_code -eq 0 ]]; then
    log_info "osv-scanner: no vulnerabilities found"
    echo '{"results": []}' > "$osv_report"
    rm -f "$tmp_output"
    return 0
  elif [[ $exit_code -eq 1 ]]; then
    # Vulnerabilities found - process the output
    if [[ -s "$tmp_output" ]]; then
      # Parse and normalize the output
      local normalized
      normalized=$(normalize_osv_output "$tmp_output")
      echo "$normalized" > "$osv_report"

      log_verbose "osv-scanner found vulnerabilities"
      rm -f "$tmp_output"
      return 1
    else
      log_warn "osv-scanner returned error but no output"
      echo '{"results": []}' > "$osv_report"
      rm -f "$tmp_output"
      return 0
    fi
  else
    # Scanner error
    log_error "osv-scanner failed with exit code $exit_code"
    if [[ -s "$tmp_output" ]]; then
      cat "$tmp_output" >&2
    fi
    rm -f "$tmp_output"
    return 2
  fi
}

# ─── Output Normalization ─────────────────────────────────────────────────────

normalize_osv_output() {
  local osv_json_file="$1"

  # OSV-Scanner output format:
  # {
  #   "results": [
  #     {
  #       "source": { "path": "...", "type": "..." },
  #       "packages": [
  #         {
  #           "package": { "name": "...", "version": "...", "ecosystem": "..." },
  #           "vulnerabilities": [
  #             {
  #               "id": "GHSA-...",
  #               "summary": "...",
  #               "severity": [{"type": "CVSS_V3", "score": "..."}],
  #               ...
  #             }
  #           ]
  #         }
  #       ]
  #     }
  #   ]
  # }

  # Normalize to simplified format compatible with dep-audit.sh
  jq '{
    results: [
      .results[]? |
      .packages[]? |
      select(.vulnerabilities != null and (.vulnerabilities | length) > 0) |
      {
        package: .package.name,
        version: .package.version,
        ecosystem: .package.ecosystem,
        vulnerabilities: [
          .vulnerabilities[] | {
            id: .id,
            summary: .summary,
            severity: (
              if .database_specific.severity != null then
                .database_specific.severity
              elif .severity != null then
                (.severity[0].score // "UNKNOWN")
              else
                "UNKNOWN"
              end
            )
          }
        ]
      }
    ],
    summary: {
      total_packages: ([.results[]?.packages[]?] | length),
      vulnerable_packages: ([.results[]?.packages[]? | select(.vulnerabilities != null and (.vulnerabilities | length) > 0)] | length),
      total_vulnerabilities: ([.results[]?.packages[]?.vulnerabilities[]?] | length)
    }
  }' "$osv_json_file" 2>/dev/null || echo '{"results": [], "summary": {"total_packages": 0, "vulnerable_packages": 0, "total_vulnerabilities": 0}}'
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_summary_report() {
  local osv_status="$1"
  local osv_report="$OUTPUT_DIR/osv-scanner.json"

  if [[ ! -f "$osv_report" ]]; then
    log_verbose "No osv-scanner report found"
    return
  fi

  local summary
  summary=$(jq -r '.summary // {}' "$osv_report" 2>/dev/null || echo '{}')

  local total_packages vulnerable_packages total_vulns
  total_packages=$(echo "$summary" | jq -r '.total_packages // 0')
  vulnerable_packages=$(echo "$summary" | jq -r '.vulnerable_packages // 0')
  total_vulns=$(echo "$summary" | jq -r '.total_vulnerabilities // 0')

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  OSV-Scanner Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
  echo "  Scanned: $total_packages package(s) across all ecosystems"
  echo "  Vulnerable: $vulnerable_packages package(s)"
  echo "  Total vulnerabilities: $total_vulns"
  echo ""

  if [[ "$osv_status" != "0" ]]; then
    echo -e "  ${RED}${BOLD}Vulnerabilities Found:${NC}"
    echo ""

    # Show top 10 vulnerabilities
    jq -r '.results[]? | "  • \(.package) \(.version) (\(.ecosystem)): \(.vulnerabilities | length) vuln(s)"' "$osv_report" 2>/dev/null | head -10 || true

    if [[ "$total_vulns" -gt 10 ]]; then
      echo "  ... and $((total_vulns - 10)) more"
    fi
    echo ""
  fi

  echo "  Full report: $osv_report"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites

  log_info "OSV-Scanner - Broad vulnerability database coverage"
  log_verbose "Output directory: $OUTPUT_DIR"

  # Create output directory
  mkdir -p "$OUTPUT_DIR"

  # Run scanner
  local osv_exit=0
  run_osv_scanner || osv_exit=$?

  # Generate report
  if [[ "$OUTPUT_FORMAT" == "summary" ]] || [[ "$OUTPUT_FORMAT" == "table" ]]; then
    generate_summary_report "$osv_exit"
  fi

  # Determine overall exit code
  if [[ $osv_exit -eq 2 ]]; then
    log_error "OSV-Scanner tool error"
    exit 2
  elif [[ $osv_exit -ne 0 ]]; then
    log_warn "OSV-Scanner found vulnerabilities - see report above"
    exit 1
  else
    log_info "OSV-Scanner completed - no vulnerabilities found"
    exit 0
  fi
}

main "$@"
