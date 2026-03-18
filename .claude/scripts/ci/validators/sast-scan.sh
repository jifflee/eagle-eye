#!/usr/bin/env bash
# ============================================================
# Script: sast-scan.sh
# Purpose: Static Application Security Testing (SAST) with Semgrep
#
# Performs code-level security analysis using Semgrep to detect:
#   - Injection vulnerabilities (SQL, XSS, command, LDAP, etc.)
#   - Authentication and authorization bypasses
#   - Cryptographic issues (weak crypto, hardcoded secrets)
#   - Insecure deserialization and file operations
#   - Path traversal and SSRF vulnerabilities
#   - Security misconfigurations
#
# Supports bash, TypeScript, Python, JavaScript, and more.
# Complements existing security-scan.sh (pattern-based) with AST analysis.
#
# Usage:
#   ./scripts/ci/validators/sast-scan.sh [OPTIONS]
#
# Options:
#   --config FILE        Semgrep config file (default: config/semgrep-rules.yml)
#   --severity LEVEL     Minimum severity: critical|high|medium|low (default: medium)
#   --output FILE        Write JSON report to FILE (default: sast-report.json)
#   --format FORMAT      Output format: json|sarif|text|gitlab-sast (default: json)
#   --no-fail            Exit 0 even if findings detected
#   --verbose            Show detailed output
#   --dry-run            Show what would be scanned
#   --install            Install Semgrep if not present
#   --help               Show this help
#
# Exit codes:
#   0  No security findings or --no-fail
#   1  Low/medium findings (warnings)
#   2  Critical/high findings (blocks CI)
#
# Integration:
#   - Auto-discovered by run-pipeline.sh in pre-pr/pre-merge/pre-release modes
#   - Runs on all bash, TypeScript, Python, JavaScript files
#   - Results integrated with PR validation gate
#
# Related:
#   - Issue #1042 - Add SAST integration with Semgrep
#   - scripts/ci/validators/security-scan.sh - Pattern-based secret scanning
#   - scripts/ci/validators/osv-scan.sh - Dependency vulnerability scanning
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

CONFIG_FILE="${SAST_CONFIG:-config/semgrep-rules.yml}"
SEVERITY="${SAST_SEVERITY:-medium}"
OUTPUT_FILE="${SAST_REPORT:-sast-report.json}"
OUTPUT_FORMAT="json"
NO_FAIL=false
VERBOSE=false
DRY_RUN=false
INSTALL_MODE=false

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
    --config)      CONFIG_FILE="$2"; shift 2 ;;
    --severity)    SEVERITY="$2"; shift 2 ;;
    --output)      OUTPUT_FILE="$2"; shift 2 ;;
    --format)      OUTPUT_FORMAT="$2"; shift 2 ;;
    --no-fail)     NO_FAIL=true; shift ;;
    --verbose)     VERBOSE=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --install)     INSTALL_MODE=true; shift ;;
    --help|-h)     show_help ;;
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

# ─── Semgrep Installation ─────────────────────────────────────────────────────

install_semgrep() {
  log_step "Installing Semgrep..."

  if command -v pip3 &>/dev/null; then
    pip3 install --user semgrep || {
      log_error "Failed to install Semgrep via pip3"
      log_error "Try: pip3 install --user semgrep"
      return 1
    }
  elif command -v pip &>/dev/null; then
    pip install --user semgrep || {
      log_error "Failed to install Semgrep via pip"
      return 1
    }
  else
    log_error "pip or pip3 is required to install Semgrep"
    log_error "Install Python first: https://www.python.org/downloads/"
    return 1
  fi

  log_info "Semgrep installed successfully"
  log_info "You may need to add ~/.local/bin to your PATH"
  return 0
}

check_semgrep() {
  if ! command -v semgrep &>/dev/null; then
    log_warn "Semgrep not found"

    if [[ "$INSTALL_MODE" == "true" ]]; then
      install_semgrep || exit 2
    else
      log_error "Semgrep is required but not installed"
      log_error "Install: pip3 install --user semgrep"
      log_error "Or run with --install to install automatically"
      exit 2
    fi
  else
    local version
    version=$(semgrep --version 2>/dev/null | head -1 || echo "unknown")
    log_verbose "Found Semgrep: $version"
  fi
}

# ─── Configuration ────────────────────────────────────────────────────────────

validate_config() {
  local config_path
  if [[ "$CONFIG_FILE" = /* ]]; then
    config_path="$CONFIG_FILE"
  else
    config_path="$REPO_ROOT/$CONFIG_FILE"
  fi

  if [[ ! -f "$config_path" ]]; then
    log_warn "Custom config not found: $CONFIG_FILE"
    log_info "Using Semgrep community rules: p/security-audit"
    CONFIG_FILE="p/security-audit"
    return 0
  fi

  log_verbose "Using config: $config_path"
  CONFIG_FILE="$config_path"
}

# ─── Scan Execution ───────────────────────────────────────────────────────────

map_severity_to_semgrep() {
  case "$SEVERITY" in
    critical) echo "ERROR" ;;
    high)     echo "ERROR" ;;
    medium)   echo "WARNING" ;;
    low)      echo "INFO" ;;
    *)        echo "WARNING" ;;
  esac
}

run_semgrep_scan() {
  log_step "Running Semgrep SAST scan..."

  local semgrep_severity
  semgrep_severity=$(map_severity_to_semgrep)

  local -a semgrep_args=(
    "--config" "$CONFIG_FILE"
    "--severity" "$semgrep_severity"
  )

  # Output format
  case "$OUTPUT_FORMAT" in
    json)
      semgrep_args+=("--json" "--output" "$OUTPUT_FILE")
      ;;
    sarif)
      semgrep_args+=("--sarif" "--output" "$OUTPUT_FILE")
      ;;
    gitlab-sast)
      semgrep_args+=("--gitlab-sast" "--output" "$OUTPUT_FILE")
      ;;
    text)
      # Text output to stdout, no file
      semgrep_args+=("--text")
      ;;
    *)
      log_error "Unsupported format: $OUTPUT_FORMAT"
      exit 2
      ;;
  esac

  # Verbosity
  if [[ "$VERBOSE" == "true" ]]; then
    semgrep_args+=("--verbose")
  else
    semgrep_args+=("--quiet")
  fi

  # Scan target
  semgrep_args+=("$REPO_ROOT")

  log_verbose "Semgrep command: semgrep ${semgrep_args[*]}"

  # Run semgrep
  local exit_code=0
  semgrep "${semgrep_args[@]}" 2>&1 || exit_code=$?

  # Semgrep exit codes:
  # 0 = no findings
  # 1 = findings detected
  # 2+ = error

  return "$exit_code"
}

# ─── Report Parsing ───────────────────────────────────────────────────────────

parse_json_report() {
  local report_file="$1"

  if [[ ! -f "$report_file" ]]; then
    log_verbose "No report file found: $report_file"
    return 1
  fi

  if ! jq empty "$report_file" 2>/dev/null; then
    log_warn "Report file is not valid JSON"
    return 1
  fi

  local total_findings
  total_findings=$(jq -r '.results | length' "$report_file" 2>/dev/null || echo "0")

  local errors warnings infos
  errors=$(jq -r '[.results[] | select(.extra.severity == "ERROR")] | length' "$report_file" 2>/dev/null || echo "0")
  warnings=$(jq -r '[.results[] | select(.extra.severity == "WARNING")] | length' "$report_file" 2>/dev/null || echo "0")
  infos=$(jq -r '[.results[] | select(.extra.severity == "INFO")] | length' "$report_file" 2>/dev/null || echo "0")

  echo "total:$total_findings"
  echo "critical:$errors"
  echo "high:$errors"
  echo "medium:$warnings"
  echo "low:$infos"
}

# ─── Summary Report ───────────────────────────────────────────────────────────

generate_summary() {
  local exit_code="$1"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  SAST Scan Report (Semgrep)${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  if [[ ! -f "$OUTPUT_FILE" ]] || [[ "$OUTPUT_FORMAT" != "json" ]]; then
    echo "  Scan completed with exit code: $exit_code"
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
      echo "  Format: $OUTPUT_FORMAT (summary not available)"
    fi
    echo ""
    return
  fi

  local stats
  stats=$(parse_json_report "$OUTPUT_FILE")

  if [[ -z "$stats" ]]; then
    echo "  Unable to parse report"
    echo ""
    return
  fi

  local total critical high medium low
  total=$(echo "$stats" | grep "^total:" | cut -d: -f2)
  critical=$(echo "$stats" | grep "^critical:" | cut -d: -f2)
  high=$(echo "$stats" | grep "^high:" | cut -d: -f2)
  medium=$(echo "$stats" | grep "^medium:" | cut -d: -f2)
  low=$(echo "$stats" | grep "^low:" | cut -d: -f2)

  echo "  Total findings:    $total"
  echo "  Critical/High:     $critical"
  echo "  Medium:            $medium"
  echo "  Low/Info:          $low"
  echo ""

  if [[ "$total" -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Top Findings:${NC}"
    echo ""

    # Show top 5 findings
    jq -r '.results[0:5] | .[] |
      "  \u001b[33m•\u001b[0m \(.extra.severity): \(.extra.message)\n    File: \(.path):\(.start.line)\n    Rule: \(.check_id)"' \
      "$OUTPUT_FILE" 2>/dev/null || echo "  (Unable to parse findings)"

    if [[ "$total" -gt 5 ]]; then
      echo ""
      echo "  ... and $((total - 5)) more finding(s)"
    fi
    echo ""
  fi

  echo "  Full report: $OUTPUT_FILE"
  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}SAST Scanner (Semgrep)${NC}"
  echo -e "Severity: ${YELLOW}$SEVERITY+${NC}  |  Config: $CONFIG_FILE"
  echo "────────────────────────────────────────"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would run SAST scan with:"
    echo "  Config:     $CONFIG_FILE"
    echo "  Severity:   $SEVERITY"
    echo "  Format:     $OUTPUT_FORMAT"
    echo "  Output:     $OUTPUT_FILE"
    echo "  Target:     $REPO_ROOT"
    exit 0
  fi

  # Check prerequisites
  check_semgrep
  validate_config

  # Run scan
  local scan_exit=0
  run_semgrep_scan || scan_exit=$?

  log_verbose "Semgrep exit code: $scan_exit"

  # Generate summary
  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    generate_summary "$scan_exit"
  fi

  # Determine final exit code
  case "$scan_exit" in
    0)
      log_info "SAST scan passed - no security findings"
      exit 0
      ;;
    1)
      # Findings detected - determine severity
      if [[ "$OUTPUT_FORMAT" == "json" ]] && [[ -f "$OUTPUT_FILE" ]]; then
        local stats
        stats=$(parse_json_report "$OUTPUT_FILE")
        local critical
        critical=$(echo "$stats" | grep "^critical:" | cut -d: -f2)

        if [[ "$critical" -gt 0 ]]; then
          log_error "SAST scan FAILED - critical/high severity findings detected"
          [[ "$NO_FAIL" == "true" ]] && exit 0
          exit 2
        else
          log_warn "SAST scan - medium/low findings detected (see report)"
          [[ "$NO_FAIL" == "true" ]] && exit 0
          exit 1
        fi
      else
        log_warn "SAST scan - findings detected (see output)"
        [[ "$NO_FAIL" == "true" ]] && exit 0
        exit 1
      fi
      ;;
    *)
      log_error "SAST scan error (exit code: $scan_exit)"
      [[ "$NO_FAIL" == "true" ]] && exit 0
      exit 2
      ;;
  esac
}

main "$@"
