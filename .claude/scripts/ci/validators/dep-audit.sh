#!/usr/bin/env bash
# ============================================================
# Script: dep-audit.sh
# Purpose: Dependency vulnerability scanning with pip-audit, safety, and npm audit
#
# Runs vulnerability scans against Python and JavaScript dependencies.
# Exit codes: 0 = clean, 1 = vulnerabilities found, 2 = tool error
#
# Usage:
#   ./scripts/ci/dep-audit.sh [OPTIONS]
#
# Options:
#   --quick             Quick scan (npm audit only, no Python scans)
#   --full              Full scan (all tools)
#   --strict            Strict mode: fail on any vulnerability (default: critical/high only)
#   --with-attestation  Include package attestation validation (provenance checks)
#   --output-dir DIR    Output directory for JSON reports (default: .dep-audit/)
#   --format FORMAT     Output format: json|table|summary (default: summary)
#   --no-npm            Skip npm audit
#   --no-python         Skip Python scans (pip-audit and safety)
#   --no-osv            Skip OSV-Scanner (broader ecosystem coverage)
#   --verbose           Show detailed output
#   --help              Show this help
#
# Exit codes:
#   0 - No vulnerabilities found (or only low/medium in non-strict mode)
#   1 - Critical or high vulnerabilities found
#   2 - Tool error (missing dependencies, scan failed)
#
# Output:
#   - JSON reports written to .dep-audit/ directory
#   - Summary report printed to stdout
#   - Human-readable table format available with --format table
#
# Integration:
#   - Pre-commit hook: ./scripts/ci/dep-audit.sh --quick (warn only)
#   - PR validation: ./scripts/ci/dep-review.sh (blocking for new vulns)
#   - Pre-QA gate: ./scripts/ci/dep-audit.sh --full (blocking)
#   - Pre-main gate: ./scripts/ci/dep-audit.sh --full --strict (blocking)
#
# Related:
#   - scripts/ci/validators/package-attestation.sh - Package attestation validation
#   - scripts/ci/validators/osv-scan.sh - OSV-Scanner integration for broader coverage
#   - scripts/ci/dep-review.sh - PR-level dependency review
#   - scripts/ci/check-dependencies.sh - Dependency structure checks
#   - Issue #968 - Add local CI dependency scanning
#   - Issue #1031 - Add package attestation and provenance validation
#   - Issue #1040 - Integrate OSV-Scanner for broader vulnerability coverage
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

MODE="full"
STRICT_MODE=false
WITH_ATTESTATION=false
OUTPUT_DIR="$REPO_ROOT/.dep-audit"
OUTPUT_FORMAT="summary"
SKIP_NPM=false
SKIP_PYTHON=false
SKIP_OSV=false
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
    --quick)           MODE="quick"; shift ;;
    --full)            MODE="full"; shift ;;
    --strict)          STRICT_MODE=true; shift ;;
    --with-attestation) WITH_ATTESTATION=true; shift ;;
    --output-dir)      OUTPUT_DIR="$2"; shift 2 ;;
    --format)          OUTPUT_FORMAT="$2"; shift 2 ;;
    --no-npm)          SKIP_NPM=true; shift ;;
    --no-python)       SKIP_PYTHON=true; shift ;;
    --no-osv)          SKIP_OSV=true; shift ;;
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

  # Check for at least one scanning tool
  local has_tools=false
  if command -v npm &>/dev/null; then
    has_tools=true
  fi
  if command -v pip-audit &>/dev/null || command -v safety &>/dev/null; then
    has_tools=true
  fi

  if [[ "$has_tools" == "false" ]]; then
    log_error "No scanning tools available (npm, pip-audit, or safety)"
    log_error "Install tools: see scripts/ci/install-ci-tools.sh"
    exit 2
  fi
}

# ─── NPM Audit ────────────────────────────────────────────────────────────────

run_npm_audit() {
  log_step "Running npm audit..."

  if [[ "$SKIP_NPM" == "true" ]]; then
    log_verbose "Skipping npm audit (--no-npm)"
    return 0
  fi

  if ! command -v npm &>/dev/null; then
    log_warn "npm not found, skipping npm audit"
    return 0
  fi

  # Check for package-lock.json
  if [[ ! -f "$REPO_ROOT/package-lock.json" ]] && [[ ! -f "$REPO_ROOT/package.json" ]]; then
    log_verbose "No package.json or package-lock.json found, skipping npm audit"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local npm_report="$OUTPUT_DIR/npm-audit.json"

  # Run npm audit with JSON output
  local exit_code=0
  cd "$REPO_ROOT"
  npm audit --json > "$npm_report" 2>/dev/null || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_info "npm audit: no vulnerabilities found"
    return 0
  else
    # npm audit returns non-zero if vulnerabilities found
    local critical high medium low
    critical=$(jq '.metadata.vulnerabilities.critical // 0' "$npm_report" 2>/dev/null || echo "0")
    high=$(jq '.metadata.vulnerabilities.high // 0' "$npm_report" 2>/dev/null || echo "0")
    medium=$(jq '.metadata.vulnerabilities.moderate // 0' "$npm_report" 2>/dev/null || echo "0")
    low=$(jq '.metadata.vulnerabilities.low // 0' "$npm_report" 2>/dev/null || echo "0")

    log_verbose "npm audit results: critical=$critical, high=$high, medium=$medium, low=$low"

    # Return 1 if critical or high found
    if [[ $critical -gt 0 || $high -gt 0 ]]; then
      return 1
    fi

    # In strict mode, fail on any vulnerability
    if [[ "$STRICT_MODE" == "true" ]] && [[ $((critical + high + medium + low)) -gt 0 ]]; then
      return 1
    fi

    return 0
  fi
}

# ─── pip-audit ────────────────────────────────────────────────────────────────

run_pip_audit() {
  log_step "Running pip-audit..."

  if [[ "$SKIP_PYTHON" == "true" ]]; then
    log_verbose "Skipping pip-audit (--no-python)"
    return 0
  fi

  if ! command -v pip-audit &>/dev/null; then
    log_warn "pip-audit not found, skipping (install: pip install pip-audit)"
    return 0
  fi

  # Find requirements files
  local requirements_files=()
  while IFS= read -r req_file; do
    [[ -n "$req_file" ]] && requirements_files+=("$req_file")
  done < <(find "$REPO_ROOT" -name "requirements*.txt" -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/venv/*" 2>/dev/null || true)

  if [[ ${#requirements_files[@]} -eq 0 ]]; then
    log_verbose "No requirements*.txt files found, skipping pip-audit"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local pip_audit_report="$OUTPUT_DIR/pip-audit.json"
  local combined_findings='[]'
  local has_findings=false

  for req_file in "${requirements_files[@]}"; do
    log_verbose "Scanning $req_file with pip-audit..."
    local tmp_report; tmp_report=$(mktemp)
    local exit_code=0

    # Run pip-audit with JSON output
    pip-audit -r "$req_file" --format json > "$tmp_report" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      log_verbose "pip-audit: no vulnerabilities in $req_file"
    else
      # pip-audit found vulnerabilities
      has_findings=true
      local findings
      findings=$(jq '.dependencies // []' "$tmp_report" 2>/dev/null || echo '[]')
      combined_findings=$(echo "$combined_findings" | jq --argjson new "$findings" '. + $new')
    fi

    rm -f "$tmp_report"
  done

  # Write combined report
  echo "{\"dependencies\": $combined_findings}" > "$pip_audit_report"

  if [[ "$has_findings" == "false" ]]; then
    log_info "pip-audit: no vulnerabilities found"
    return 0
  else
    # Count severity levels
    local critical high medium low
    critical=$(echo "$combined_findings" | jq '[.[] | select(.vulnerabilities[].severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    high=$(echo "$combined_findings" | jq '[.[] | select(.vulnerabilities[].severity == "HIGH")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$combined_findings" | jq '[.[] | select(.vulnerabilities[].severity == "MEDIUM")] | length' 2>/dev/null || echo "0")
    low=$(echo "$combined_findings" | jq '[.[] | select(.vulnerabilities[].severity == "LOW")] | length' 2>/dev/null || echo "0")

    log_verbose "pip-audit results: critical=$critical, high=$high, medium=$medium, low=$low"

    # Return 1 if critical or high found
    if [[ $critical -gt 0 || $high -gt 0 ]]; then
      return 1
    fi

    # In strict mode, fail on any vulnerability
    if [[ "$STRICT_MODE" == "true" ]] && [[ $((critical + high + medium + low)) -gt 0 ]]; then
      return 1
    fi

    return 0
  fi
}

# ─── safety ───────────────────────────────────────────────────────────────────

run_safety() {
  log_step "Running safety..."

  if [[ "$SKIP_PYTHON" == "true" ]]; then
    log_verbose "Skipping safety (--no-python)"
    return 0
  fi

  if ! command -v safety &>/dev/null; then
    log_warn "safety not found, skipping (install: pip install safety)"
    return 0
  fi

  # Find requirements files
  local requirements_files=()
  while IFS= read -r req_file; do
    [[ -n "$req_file" ]] && requirements_files+=("$req_file")
  done < <(find "$REPO_ROOT" -name "requirements*.txt" -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/venv/*" 2>/dev/null || true)

  if [[ ${#requirements_files[@]} -eq 0 ]]; then
    log_verbose "No requirements*.txt files found, skipping safety"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local safety_report="$OUTPUT_DIR/safety.json"
  local has_findings=false

  # safety check with JSON output
  for req_file in "${requirements_files[@]}"; do
    log_verbose "Scanning $req_file with safety..."
    local tmp_report; tmp_report=$(mktemp)
    local exit_code=0

    # Run safety check
    safety check -r "$req_file" --json > "$tmp_report" 2>/dev/null || exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      log_verbose "safety: no vulnerabilities in $req_file"
    else
      has_findings=true
    fi

    # Append to combined report
    if [[ -s "$tmp_report" ]]; then
      cat "$tmp_report" >> "$safety_report"
    fi

    rm -f "$tmp_report"
  done

  if [[ "$has_findings" == "false" ]]; then
    log_info "safety: no vulnerabilities found"
    return 0
  else
    # Safety always returns findings as JSON array, count them
    local findings_count
    findings_count=$(jq 'length' "$safety_report" 2>/dev/null || echo "0")

    log_verbose "safety results: $findings_count vulnerabilities found"

    # safety doesn't provide severity levels in the same way, so we treat all as potentially high
    # Return 1 if any findings in non-strict mode, or always in strict mode
    if [[ $findings_count -gt 0 ]]; then
      return 1
    fi

    return 0
  fi
}

# ─── OSV-Scanner ──────────────────────────────────────────────────────────────

run_osv_scanner() {
  log_step "Running OSV-Scanner..."

  if [[ "$SKIP_OSV" == "true" ]]; then
    log_verbose "Skipping OSV-Scanner (--no-osv)"
    return 0
  fi

  local osv_script="$SCRIPT_DIR/osv-scan.sh"
  if [[ ! -x "$osv_script" ]]; then
    log_verbose "OSV-Scanner script not found or not executable: $osv_script"
    return 0
  fi

  # Run OSV-Scanner with same output settings
  local exit_code=0
  "$osv_script" \
    --output-dir "$OUTPUT_DIR" \
    --format "$OUTPUT_FORMAT" \
    $([ "$VERBOSE" == "true" ] && echo "--verbose") || exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_info "OSV-Scanner: no vulnerabilities found"
    return 0
  elif [[ $exit_code -eq 1 ]]; then
    # Vulnerabilities found
    return 1
  else
    # Scanner error - non-fatal, just warn
    log_warn "OSV-Scanner encountered an error (tool may not be installed)"
    return 0
  fi
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_summary_report() {
  local npm_status="$1"
  local pip_audit_status="$2"
  local safety_status="$3"
  local osv_status="${4:-0}"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Dependency Audit Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Count files scanned
  local npm_files=0
  local py_files=0
  [[ -f "$REPO_ROOT/package-lock.json" ]] && npm_files=1
  py_files=$(find "$REPO_ROOT" -name "requirements*.txt" -not -path "*/node_modules/*" -not -path "*/.venv/*" -not -path "*/venv/*" 2>/dev/null | wc -l | tr -d ' ')

  echo "  Scanned: $npm_files npm package files, $py_files Python requirement files"
  echo ""

  # Results table
  printf "  %-15s | %-10s | %-8s | %-8s | %-8s | %-8s\n" "Tool" "Status" "Critical" "High" "Medium" "Low"
  echo "  ─────────────────────────────────────────────────────────────────────────"

  # npm audit results
  if [[ -f "$OUTPUT_DIR/npm-audit.json" ]]; then
    local critical high medium low
    critical=$(jq '.metadata.vulnerabilities.critical // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")
    high=$(jq '.metadata.vulnerabilities.high // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")
    medium=$(jq '.metadata.vulnerabilities.moderate // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")
    low=$(jq '.metadata.vulnerabilities.low // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")

    local status_color="$GREEN"
    [[ "$npm_status" != "0" ]] && status_color="$RED"
    printf "  %-15s | %b%-10s%b | %-8s | %-8s | %-8s | %-8s\n" "npm audit" "$status_color" "$([[ "$npm_status" == "0" ]] && echo "PASS" || echo "FAIL")" "$NC" "$critical" "$high" "$medium" "$low"
  else
    printf "  %-15s | %-10s | %-8s | %-8s | %-8s | %-8s\n" "npm audit" "SKIP" "-" "-" "-" "-"
  fi

  # pip-audit results
  if [[ -f "$OUTPUT_DIR/pip-audit.json" ]]; then
    local critical high medium low
    local findings
    findings=$(jq '.dependencies // []' "$OUTPUT_DIR/pip-audit.json" 2>/dev/null || echo '[]')
    critical=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    high=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "HIGH")] | length' 2>/dev/null || echo "0")
    medium=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "MEDIUM")] | length' 2>/dev/null || echo "0")
    low=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "LOW")] | length' 2>/dev/null || echo "0")

    local status_color="$GREEN"
    [[ "$pip_audit_status" != "0" ]] && status_color="$RED"
    printf "  %-15s | %b%-10s%b | %-8s | %-8s | %-8s | %-8s\n" "pip-audit" "$status_color" "$([[ "$pip_audit_status" == "0" ]] && echo "PASS" || echo "FAIL")" "$NC" "$critical" "$high" "$medium" "$low"
  else
    printf "  %-15s | %-10s | %-8s | %-8s | %-8s | %-8s\n" "pip-audit" "SKIP" "-" "-" "-" "-"
  fi

  # safety results
  if [[ -f "$OUTPUT_DIR/safety.json" ]]; then
    local findings_count
    findings_count=$(jq 'length' "$OUTPUT_DIR/safety.json" 2>/dev/null || echo "0")

    local status_color="$GREEN"
    [[ "$safety_status" != "0" ]] && status_color="$RED"
    printf "  %-15s | %b%-10s%b | %-8s | %-8s | %-8s | %-8s\n" "safety" "$status_color" "$([[ "$safety_status" == "0" ]] && echo "PASS" || echo "FAIL")" "$NC" "-" "$findings_count" "-" "-"
  else
    printf "  %-15s | %-10s | %-8s | %-8s | %-8s | %-8s\n" "safety" "SKIP" "-" "-" "-" "-"
  fi

  # OSV-Scanner results
  if [[ -f "$OUTPUT_DIR/osv-scanner.json" ]]; then
    local vuln_packages total_vulns
    vuln_packages=$(jq '.summary.vulnerable_packages // 0' "$OUTPUT_DIR/osv-scanner.json" 2>/dev/null || echo "0")
    total_vulns=$(jq '.summary.total_vulnerabilities // 0' "$OUTPUT_DIR/osv-scanner.json" 2>/dev/null || echo "0")

    local status_color="$GREEN"
    [[ "$osv_status" != "0" ]] && status_color="$RED"
    printf "  %-15s | %b%-10s%b | %-8s | %-8s | %-8s | %-8s\n" "osv-scanner" "$status_color" "$([[ "$osv_status" == "0" ]] && echo "PASS" || echo "FAIL")" "$NC" "-" "$total_vulns" "-" "-"
  else
    printf "  %-15s | %-10s | %-8s | %-8s | %-8s | %-8s\n" "osv-scanner" "SKIP" "-" "-" "-" "-"
  fi

  echo ""

  # Critical/High findings details
  local has_critical_high=false

  if [[ -f "$OUTPUT_DIR/npm-audit.json" ]]; then
    local critical high
    critical=$(jq '.metadata.vulnerabilities.critical // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")
    high=$(jq '.metadata.vulnerabilities.high // 0' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || echo "0")
    if [[ $critical -gt 0 || $high -gt 0 ]]; then
      has_critical_high=true
      echo -e "  ${RED}${BOLD}Critical/High Findings (npm):${NC}"
      echo ""
      # Extract top 5 critical/high vulnerabilities
      jq -r '.vulnerabilities | to_entries | map(select(.value.severity == "critical" or .value.severity == "high")) | .[:5] | .[] | "  • \(.key) (\(.value.via[0].title // "Unknown")): \(.value.severity)"' "$OUTPUT_DIR/npm-audit.json" 2>/dev/null || true
      echo ""
    fi
  fi

  if [[ -f "$OUTPUT_DIR/pip-audit.json" ]]; then
    local findings
    findings=$(jq '.dependencies // []' "$OUTPUT_DIR/pip-audit.json" 2>/dev/null || echo '[]')
    local critical high
    critical=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    high=$(echo "$findings" | jq '[.[] | select(.vulnerabilities[].severity == "HIGH")] | length' 2>/dev/null || echo "0")
    if [[ $critical -gt 0 || $high -gt 0 ]]; then
      has_critical_high=true
      echo -e "  ${RED}${BOLD}Critical/High Findings (pip-audit):${NC}"
      echo ""
      # Extract top 5 critical/high vulnerabilities
      echo "$findings" | jq -r '.[] | select(.vulnerabilities[].severity == "CRITICAL" or .vulnerabilities[].severity == "HIGH") | .vulnerabilities[] | "  • \(.package) \(.version): \(.id) (\(.severity))"' 2>/dev/null | head -5 || true
      echo ""
    fi
  fi

  echo -e "  ${BOLD}Remediation:${NC}"
  echo "    npm:        npm audit fix"
  echo "    Python:     pip install --upgrade <package>"
  echo "    Review:     cat $OUTPUT_DIR/*.json for full details"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites

  log_info "Dependency Audit - Mode: $MODE, Strict: $STRICT_MODE"
  log_verbose "Output directory: $OUTPUT_DIR"

  # Create output directory
  mkdir -p "$OUTPUT_DIR"

  # Quick mode: npm audit only
  if [[ "$MODE" == "quick" ]]; then
    SKIP_PYTHON=true
  fi

  # Run scans
  local npm_exit=0
  local pip_audit_exit=0
  local safety_exit=0
  local osv_exit=0

  run_npm_audit || npm_exit=$?
  run_pip_audit || pip_audit_exit=$?
  run_safety || safety_exit=$?
  run_osv_scanner || osv_exit=$?

  # Run attestation checks if requested
  local attestation_exit=0
  if [[ "$WITH_ATTESTATION" == "true" ]]; then
    local attestation_script="$SCRIPT_DIR/package-attestation.sh"
    if [[ -x "$attestation_script" ]]; then
      log_step "Running package attestation validation..."
      "$attestation_script" \
        --output-dir "$OUTPUT_DIR" \
        --format "$OUTPUT_FORMAT" \
        $([ "$VERBOSE" == "true" ] && echo "--verbose") \
        $([ "$MODE" == "quick" ] && echo "--quick" || echo "--full") \
        $([ "$STRICT_MODE" == "true" ] && echo "--strict") || attestation_exit=$?

      if [[ $attestation_exit -eq 0 ]]; then
        log_info "Package attestation validation: PASS"
      else
        log_warn "Package attestation validation: issues found"
      fi
    else
      log_warn "Package attestation script not found or not executable: $attestation_script"
    fi
  fi

  # Generate report
  if [[ "$OUTPUT_FORMAT" == "summary" ]] || [[ "$OUTPUT_FORMAT" == "table" ]]; then
    generate_summary_report "$npm_exit" "$pip_audit_exit" "$safety_exit" "$osv_exit"
  fi

  # Determine overall exit code
  local overall_exit=0
  if [[ $npm_exit -ne 0 || $pip_audit_exit -ne 0 || $safety_exit -ne 0 || $osv_exit -ne 0 ]]; then
    overall_exit=1
  fi

  # Include attestation results if enabled (warnings only by default)
  if [[ "$WITH_ATTESTATION" == "true" ]] && [[ "$STRICT_MODE" == "true" ]] && [[ $attestation_exit -ne 0 ]]; then
    overall_exit=1
  fi

  if [[ $overall_exit -eq 0 ]]; then
    log_info "All dependency audits passed - no critical/high vulnerabilities found"
  else
    log_error "Dependency audits found vulnerabilities - see report above"
  fi

  exit $overall_exit
}

main "$@"
