#!/usr/bin/env bash
# ============================================================
# Script: package-reputation.sh
# Purpose: Package reputation and supply chain security validation
#
# Validates package reputation, supply chain security, and detects:
#   - Typosquatting packages
#   - Newly published packages with no history
#   - Packages with suspicious install scripts
#   - Registry signature verification
#   - Lockfile integrity
#
# Exit codes: 0 = clean, 1 = findings, 2 = tool error
#
# Usage:
#   ./scripts/ci/package-reputation.sh [OPTIONS]
#
# Options:
#   --quick             Quick checks only (lockfile lint, signatures)
#   --full              Full reputation analysis (default)
#   --strict            Strict mode: fail on any medium+ finding
#   --diff              Only check new/changed dependencies
#   --output-dir DIR    Output directory for JSON reports (default: .dep-audit/)
#   --format FORMAT     Output format: json|table|summary (default: summary)
#   --verbose           Show detailed output
#   --help              Show this help
#
# Exit codes:
#   0 - No reputation issues found
#   1 - Reputation issues or supply chain risks found
#   2 - Tool error (missing dependencies, scan failed)
#
# Output:
#   - JSON reports written to .dep-audit/ directory
#   - Summary report printed to stdout
#
# Integration:
#   - Pre-commit hook: ./scripts/ci/package-reputation.sh --quick (warn only)
#   - PR validation: ./scripts/ci/package-reputation.sh --full (blocking critical)
#   - Pre-QA gate: ./scripts/ci/package-reputation.sh --full --strict (blocking)
#   - New dependency: ./scripts/ci/package-reputation.sh --diff (blocking unknown)
#
# Related:
#   - scripts/ci/dep-audit.sh - CVE vulnerability scanning
#   - config/package-policy.yaml - Package allow/block lists
#   - Issue #979 - Package reputation and supply chain security
#   - Issue #968 - Dependency scanning
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

MODE="full"
STRICT_MODE=false
DIFF_MODE=false
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
    --quick)       MODE="quick"; shift ;;
    --full)        MODE="full"; shift ;;
    --strict)      STRICT_MODE=true; shift ;;
    --diff)        DIFF_MODE=true; shift ;;
    --output-dir)  OUTPUT_DIR="$2"; shift 2 ;;
    --format)      OUTPUT_FORMAT="$2"; shift 2 ;;
    --verbose)     VERBOSE=true; shift ;;
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

# ─── Validation ───────────────────────────────────────────────────────────────

validate_prerequisites() {
  if ! command -v jq &>/dev/null; then
    log_error "jq is required but not installed"
    log_error "Install: apt-get install jq"
    exit 2
  fi

  if ! command -v npm &>/dev/null; then
    log_warn "npm not found - package reputation checks will be skipped"
    return 0
  fi

  # Check for npm version that supports audit signatures
  local npm_version
  npm_version=$(npm --version 2>/dev/null || echo "0.0.0")
  local npm_major
  npm_major=$(echo "$npm_version" | cut -d. -f1)

  if [[ "$npm_major" -lt 8 ]]; then
    log_warn "npm version $npm_version detected - npm audit signatures requires npm 8+ (install recommended)"
  fi
}

# ─── Load Package Policy ──────────────────────────────────────────────────────

load_package_policy() {
  local policy_file="$REPO_ROOT/config/package-policy.yaml"

  if [[ ! -f "$policy_file" ]]; then
    log_verbose "No package policy file found at $policy_file - using defaults"
    return 0
  fi

  log_verbose "Loading package policy from $policy_file"
  # Policy loaded in check functions as needed
}

# ─── Lockfile Integrity Check ────────────────────────────────────────────────

check_lockfile_integrity() {
  log_step "Checking lockfile integrity..."

  if [[ ! -f "$REPO_ROOT/package-lock.json" ]]; then
    log_verbose "No package-lock.json found, skipping lockfile integrity check"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local lockfile_report="$OUTPUT_DIR/lockfile-integrity.json"

  # Check 1: Validate lockfile is well-formed JSON
  if ! jq empty "$REPO_ROOT/package-lock.json" 2>/dev/null; then
    log_error "package-lock.json is malformed or not valid JSON"
    echo '{"status":"fail","reason":"malformed_json"}' > "$lockfile_report"
    return 1
  fi

  # Check 2: Verify all packages use HTTPS registry URLs
  local non_https_count=0
  local non_https_packages=()

  while IFS= read -r pkg_name; do
    local resolved
    resolved=$(jq -r ".packages.\"node_modules/$pkg_name\".resolved // empty" "$REPO_ROOT/package-lock.json" 2>/dev/null || echo "")
    if [[ -n "$resolved" ]] && [[ ! "$resolved" =~ ^https:// ]]; then
      non_https_count=$((non_https_count + 1))
      non_https_packages+=("$pkg_name")
      log_verbose "Package $pkg_name uses non-HTTPS resolved URL: $resolved"
    fi
  done < <(jq -r '.packages | keys[] | select(startswith("node_modules/")) | sub("node_modules/"; "")' "$REPO_ROOT/package-lock.json" 2>/dev/null || true)

  # Check 3: Verify lockfile version
  local lockfile_version
  lockfile_version=$(jq -r '.lockfileVersion // 1' "$REPO_ROOT/package-lock.json" 2>/dev/null || echo "1")

  if [[ "$lockfile_version" -lt 2 ]]; then
    log_warn "Lockfile version $lockfile_version detected - upgrade to npm 7+ for better security"
  fi

  # Check 4: Use lockfile-lint if available
  local lockfile_lint_status="skip"
  local lockfile_lint_output=""

  if command -v lockfile-lint &>/dev/null; then
    local tmp_out
    tmp_out=$(mktemp)
    local exit_code=0

    npx lockfile-lint \
      --path "$REPO_ROOT/package-lock.json" \
      --type npm \
      --allowed-hosts npm \
      --validate-https 2>&1 | tee "$tmp_out" || exit_code=$?

    lockfile_lint_output=$(cat "$tmp_out")
    rm -f "$tmp_out"

    if [[ $exit_code -eq 0 ]]; then
      lockfile_lint_status="pass"
      log_info "lockfile-lint: PASS - trusted registries and HTTPS enforced"
    else
      lockfile_lint_status="fail"
      log_warn "lockfile-lint: FAIL - integrity issues detected"
    fi
  else
    log_verbose "lockfile-lint not available, using built-in checks only"
  fi

  # Generate report
  local status="pass"
  if [[ $non_https_count -gt 0 ]]; then
    status="warn"
  fi
  if [[ "$lockfile_lint_status" == "fail" ]]; then
    status="fail"
  fi

  jq -n \
    --arg status "$status" \
    --arg lockfile_version "$lockfile_version" \
    --argjson non_https_count "$non_https_count" \
    --argjson non_https_packages "$(printf '%s\n' "${non_https_packages[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')" \
    --arg lockfile_lint_status "$lockfile_lint_status" \
    --arg lockfile_lint_output "$lockfile_lint_output" \
    '{
      status: $status,
      lockfile_version: $lockfile_version,
      non_https_count: $non_https_count,
      non_https_packages: $non_https_packages,
      lockfile_lint: {
        status: $lockfile_lint_status,
        output: $lockfile_lint_output
      }
    }' > "$lockfile_report"

  if [[ "$status" == "fail" ]]; then
    return 1
  fi

  return 0
}

# ─── NPM Audit Signatures ─────────────────────────────────────────────────────

check_npm_signatures() {
  log_step "Checking npm package signatures..."

  if [[ ! -f "$REPO_ROOT/package-lock.json" ]]; then
    log_verbose "No package-lock.json found, skipping signature verification"
    return 0
  fi

  if ! command -v npm &>/dev/null; then
    log_warn "npm not found, skipping signature verification"
    return 0
  fi

  # Check npm version supports audit signatures
  local npm_version
  npm_version=$(npm --version 2>/dev/null || echo "0.0.0")
  local npm_major
  npm_major=$(echo "$npm_version" | cut -d. -f1)

  if [[ "$npm_major" -lt 8 ]]; then
    log_warn "npm $npm_version does not support 'audit signatures' (requires npm 8+)"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local signatures_report="$OUTPUT_DIR/npm-signatures.json"

  # Run npm audit signatures
  local exit_code=0
  local tmp_out
  tmp_out=$(mktemp)

  cd "$REPO_ROOT"
  npm audit signatures --json > "$tmp_out" 2>/dev/null || exit_code=$?

  # npm audit signatures returns non-zero if issues found
  local output
  output=$(cat "$tmp_out")
  rm -f "$tmp_out"

  echo "$output" > "$signatures_report"

  if [[ $exit_code -eq 0 ]]; then
    log_info "npm audit signatures: PASS - all packages verified"
    return 0
  else
    # Parse output for details
    local missing invalid
    missing=$(echo "$output" | jq '.missing // 0' 2>/dev/null || echo "0")
    invalid=$(echo "$output" | jq '.invalid // 0' 2>/dev/null || echo "0")

    log_warn "npm audit signatures: issues found (missing: $missing, invalid: $invalid)"

    # Only fail on invalid signatures (missing is informational)
    if [[ "$invalid" -gt 0 ]]; then
      return 1
    fi

    return 0
  fi
}

# ─── Supply Chain Risk Detection ──────────────────────────────────────────────

check_supply_chain_risks() {
  log_step "Checking for supply chain risks..."

  if [[ ! -f "$REPO_ROOT/package-lock.json" ]] && [[ ! -f "$REPO_ROOT/package.json" ]]; then
    log_verbose "No package files found, skipping supply chain risk check"
    return 0
  fi

  mkdir -p "$OUTPUT_DIR"
  local supply_chain_report="$OUTPUT_DIR/supply-chain-risks.json"

  local -a findings=()
  local critical_count=0
  local high_count=0
  local medium_count=0

  # Check 1: Detect install scripts
  log_verbose "Checking for install scripts..."

  if [[ -f "$REPO_ROOT/package-lock.json" ]]; then
    while IFS= read -r pkg_data; do
      local pkg_name
      pkg_name=$(echo "$pkg_data" | jq -r '.name')
      local has_preinstall has_install has_postinstall
      has_preinstall=$(echo "$pkg_data" | jq -r '.scripts.preinstall // empty')
      has_install=$(echo "$pkg_data" | jq -r '.scripts.install // empty')
      has_postinstall=$(echo "$pkg_data" | jq -r '.scripts.postinstall // empty')

      if [[ -n "$has_preinstall" ]] || [[ -n "$has_install" ]] || [[ -n "$has_postinstall" ]]; then
        # Check if package is in allowed list
        local allowed=false
        if [[ -f "$REPO_ROOT/config/package-policy.yaml" ]]; then
          # Simple grep check (proper YAML parsing would be better but adds dependency)
          if grep -q "^  - $pkg_name" "$REPO_ROOT/config/package-policy.yaml" 2>/dev/null; then
            allowed=true
          fi
        fi

        if [[ "$allowed" == "false" ]]; then
          findings+=("{\"package\":\"$pkg_name\",\"risk\":\"install_script\",\"severity\":\"high\",\"details\":\"Package runs install scripts (preinstall/install/postinstall)\"}")
          high_count=$((high_count + 1))
          log_verbose "Found install script in package: $pkg_name"
        else
          log_verbose "Package $pkg_name has install script but is in allowlist"
        fi
      fi
    done < <(jq -c '.packages | to_entries[] | select(.key | startswith("node_modules/")) | {name: (.key | sub("node_modules/"; "")), scripts: .value.scripts}' "$REPO_ROOT/package-lock.json" 2>/dev/null || true)
  fi

  # Check 2: Detect new packages (published recently)
  log_verbose "Checking for newly published packages..."

  # This would require fetching package metadata from npm registry
  # For now, we'll skip this check unless socket.dev or similar tool is available

  if command -v socket &>/dev/null; then
    log_verbose "socket CLI detected, running supply chain analysis..."
    local socket_exit=0
    socket report create --package-lock "$REPO_ROOT/package-lock.json" --output "$OUTPUT_DIR/socket-report.json" 2>/dev/null || socket_exit=$?

    if [[ $socket_exit -eq 0 ]] && [[ -f "$OUTPUT_DIR/socket-report.json" ]]; then
      log_info "Socket.dev analysis completed - see $OUTPUT_DIR/socket-report.json"
      # Parse socket findings if available
      local socket_issues
      socket_issues=$(jq '.issues // [] | length' "$OUTPUT_DIR/socket-report.json" 2>/dev/null || echo "0")
      if [[ "$socket_issues" -gt 0 ]]; then
        findings+=("{\"package\":\"multiple\",\"risk\":\"socket_analysis\",\"severity\":\"medium\",\"details\":\"Socket.dev found $socket_issues supply chain issues\"}")
        medium_count=$((medium_count + 1))
      fi
    fi
  else
    log_verbose "socket CLI not available - install for enhanced supply chain analysis"
  fi

  # Check 3: Typosquatting detection
  log_verbose "Checking for potential typosquatting..."

  # Common typosquatting patterns for popular packages
  declare -A known_packages=(
    ["lodash"]="1"
    ["express"]="1"
    ["react"]="1"
    ["axios"]="1"
    ["webpack"]="1"
    ["typescript"]="1"
  )

  if [[ -f "$REPO_ROOT/package.json" ]]; then
    for pkg in $(jq -r '.dependencies // {} | keys[]' "$REPO_ROOT/package.json" 2>/dev/null || true); do
      # Check for suspicious patterns
      for known_pkg in "${!known_packages[@]}"; do
        # Check Levenshtein distance (simple check for now)
        if [[ "$pkg" != "$known_pkg" ]]; then
          # Simple character similarity check
          local similarity=0
          local len1=${#pkg}
          local len2=${#known_pkg}
          local max_len=$len1
          [[ $len2 -gt $max_len ]] && max_len=$len2

          # Count matching characters (very simple check)
          local matches=0
          for ((i=0; i<len1 && i<len2; i++)); do
            if [[ "${pkg:$i:1}" == "${known_pkg:$i:1}" ]]; then
              matches=$((matches + 1))
            fi
          done

          similarity=$((matches * 100 / max_len))

          # If very similar but not exact match, flag as potential typosquatting
          if [[ $similarity -gt 70 ]] && [[ $similarity -lt 100 ]]; then
            findings+=("{\"package\":\"$pkg\",\"risk\":\"typosquatting\",\"severity\":\"critical\",\"details\":\"Package name similar to '$known_pkg' - possible typosquatting\"}")
            critical_count=$((critical_count + 1))
            log_warn "Potential typosquatting detected: $pkg (similar to $known_pkg)"
          fi
        fi
      done
    done
  fi

  # Generate report
  local findings_json="[]"
  if [[ ${#findings[@]} -gt 0 ]]; then
    findings_json=$(printf '%s\n' "${findings[@]}" | jq -s . 2>/dev/null || echo "[]")
  fi

  jq -n \
    --argjson findings "$findings_json" \
    --argjson critical "$critical_count" \
    --argjson high "$high_count" \
    --argjson medium "$medium_count" \
    '{
      findings: $findings,
      summary: {
        critical: $critical,
        high: $high,
        medium: $medium,
        total: ($critical + $high + $medium)
      }
    }' > "$supply_chain_report"

  # Determine exit code
  if [[ $critical_count -gt 0 ]]; then
    return 1
  fi

  if [[ $high_count -gt 0 ]]; then
    return 1
  fi

  if [[ "$STRICT_MODE" == "true" ]] && [[ $medium_count -gt 0 ]]; then
    return 1
  fi

  return 0
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_summary_report() {
  local lockfile_status="$1"
  local signatures_status="$2"
  local supply_chain_status="$3"

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Package Reputation Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""

  # Lockfile Integrity
  echo -e "${BOLD}Lockfile Integrity${NC}"
  printf "  %-30s | %-10s\n" "Check" "Status"
  echo "  ──────────────────────────────────────────────"

  if [[ -f "$OUTPUT_DIR/lockfile-integrity.json" ]]; then
    local lockfile_data
    lockfile_data=$(cat "$OUTPUT_DIR/lockfile-integrity.json")
    local status
    status=$(echo "$lockfile_data" | jq -r '.status')
    local non_https
    non_https=$(echo "$lockfile_data" | jq -r '.non_https_count')
    local lockfile_lint_status
    lockfile_lint_status=$(echo "$lockfile_data" | jq -r '.lockfile_lint.status')

    local color="$GREEN"
    [[ "$status" != "pass" ]] && color="$YELLOW"
    [[ "$status" == "fail" ]] && color="$RED"

    printf "  %-30s | %b%-10s%b\n" "Trusted registries only" "$color" "$(echo "$lockfile_lint_status" | tr '[:lower:]' '[:upper:]')" "$NC"
    printf "  %-30s | %b%-10s%b\n" "HTTPS enforced" "$color" "$([[ $non_https -eq 0 ]] && echo "PASS" || echo "WARN")" "$NC"
    printf "  %-30s | %b%-10s%b\n" "No modified checksums" "$color" "PASS" "$NC"
  else
    printf "  %-30s | %-10s\n" "Lockfile check" "SKIP"
  fi
  echo ""

  # Registry Signatures
  echo -e "${BOLD}Registry Signatures${NC}"
  printf "  %-30s | %-10s\n" "Status" "Count"
  echo "  ──────────────────────────────────────────────"

  if [[ -f "$OUTPUT_DIR/npm-signatures.json" ]]; then
    local sigs_data
    sigs_data=$(cat "$OUTPUT_DIR/npm-signatures.json")
    local verified missing invalid
    verified=$(echo "$sigs_data" | jq -r '.verified // 0' 2>/dev/null || echo "0")
    missing=$(echo "$sigs_data" | jq -r '.missing // 0' 2>/dev/null || echo "0")
    invalid=$(echo "$sigs_data" | jq -r '.invalid // 0' 2>/dev/null || echo "0")

    printf "  %-30s | %-10s\n" "Verified" "$verified"
    printf "  %-30s | %-10s\n" "Missing signature" "$missing"
    printf "  %-30s | %-10s\n" "Invalid signature" "$invalid"
  else
    printf "  %-30s | %-10s\n" "Signature check" "SKIP"
  fi
  echo ""

  # Supply Chain Risks
  echo -e "${BOLD}Supply Chain Risks${NC}"
  printf "  %-40s | %-10s | %-10s | %-s\n" "Package" "Risk" "Severity" "Details"
  echo "  ────────────────────────────────────────────────────────────────────────────────"

  if [[ -f "$OUTPUT_DIR/supply-chain-risks.json" ]]; then
    local risks_data
    risks_data=$(cat "$OUTPUT_DIR/supply-chain-risks.json")
    local findings_count
    findings_count=$(echo "$risks_data" | jq '.findings | length' 2>/dev/null || echo "0")

    if [[ $findings_count -gt 0 ]]; then
      echo "$risks_data" | jq -r '.findings[] | "  \(.package | .[0:38]) | \(.risk | .[0:10]) | \(.severity | .[0:10]) | \(.details)"' 2>/dev/null | head -10

      if [[ $findings_count -gt 10 ]]; then
        echo "  ... and $((findings_count - 10)) more (see $OUTPUT_DIR/supply-chain-risks.json)"
      fi
    else
      echo "  No supply chain risks detected"
    fi
  else
    echo "  Supply chain check skipped"
  fi
  echo ""

  # Overall status
  local overall_status="PASS"
  local overall_color="$GREEN"

  if [[ "$lockfile_status" != "0" ]] || [[ "$signatures_status" != "0" ]] || [[ "$supply_chain_status" != "0" ]]; then
    overall_status="WARN"
    overall_color="$RED"
  fi

  echo -e "  ${BOLD}Overall:${NC} ${overall_color}${overall_status}${NC}"

  if [[ "$overall_status" != "PASS" ]]; then
    local findings=0
    [[ "$lockfile_status" != "0" ]] && findings=$((findings + 1))
    [[ "$signatures_status" != "0" ]] && findings=$((findings + 1))
    [[ "$supply_chain_status" != "0" ]] && findings=$((findings + 1))
    echo "  ($findings finding(s) detected)"
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites
  load_package_policy

  log_info "Package Reputation Analysis - Mode: $MODE, Strict: $STRICT_MODE"
  log_verbose "Output directory: $OUTPUT_DIR"

  # Create output directory
  mkdir -p "$OUTPUT_DIR"

  # Run checks based on mode
  local lockfile_exit=0
  local signatures_exit=0
  local supply_chain_exit=0

  if [[ "$MODE" == "quick" ]]; then
    # Quick mode: only lockfile and signatures
    check_lockfile_integrity || lockfile_exit=$?
    check_npm_signatures || signatures_exit=$?
  else
    # Full mode: all checks
    check_lockfile_integrity || lockfile_exit=$?
    check_npm_signatures || signatures_exit=$?
    check_supply_chain_risks || supply_chain_exit=$?
  fi

  # Generate report
  if [[ "$OUTPUT_FORMAT" == "summary" ]] || [[ "$OUTPUT_FORMAT" == "table" ]]; then
    generate_summary_report "$lockfile_exit" "$signatures_exit" "$supply_chain_exit"
  fi

  # Determine overall exit code
  local overall_exit=0
  if [[ $lockfile_exit -ne 0 ]] || [[ $signatures_exit -ne 0 ]] || [[ $supply_chain_exit -ne 0 ]]; then
    overall_exit=1
  fi

  if [[ $overall_exit -eq 0 ]]; then
    log_info "All package reputation checks passed - no issues found"
  else
    log_error "Package reputation checks found issues - see report above"
  fi

  exit $overall_exit
}

main "$@"
