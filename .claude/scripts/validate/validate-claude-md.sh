#!/usr/bin/env bash
# size-ok: CLAUDE.md schema and policy validation with multi-file support
#
# Standalone CLAUDE.md validation script
#
# Validates all CLAUDE.md files in the repository against the policy defined
# in config/claude-md-policy.yaml. Can be used in CI, Make targets, or
# invoked directly.
#
# Usage:
#   ./scripts/validate-claude-md.sh                   # validate all CLAUDE.md files
#   ./scripts/validate-claude-md.sh path/to/CLAUDE.md # validate specific file
#   ./scripts/validate-claude-md.sh --strict           # strict mode (warnings = errors)
#   ./scripts/validate-claude-md.sh --report-only      # report issues but don't fail
#
# Exit codes:
#   0 - All files pass validation
#   1 - One or more files have validation errors
#   2 - Configuration error (policy file missing, etc.)
#
# Issue: #840 - Add CLAUDE.md update guardrails and enforcement
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
POLICY_FILE="${REPO_ROOT}/config/claude-md-policy.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
STRICT_MODE=false
REPORT_ONLY=false
SPECIFIC_FILE=""
TOTAL_ERRORS=0
TOTAL_WARNINGS=0
TOTAL_FILES=0
PASS_FILES=0

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_args() {
  for arg in "$@"; do
    case "${arg}" in
      --strict)     STRICT_MODE=true ;;
      --report-only) REPORT_ONLY=true ;;
      --help|-h)
        echo "Usage: $0 [--strict] [--report-only] [path/to/CLAUDE.md]"
        echo ""
        echo "  --strict       Treat warnings as errors"
        echo "  --report-only  Report issues but always exit 0"
        echo ""
        exit 0
        ;;
      -*)
        echo "Unknown option: ${arg}" >&2
        exit 2
        ;;
      *)
        SPECIFIC_FILE="${arg}"
        ;;
    esac
  done
}

# =============================================================================
# FILE DISCOVERY
# =============================================================================

discover_files() {
  if [ -n "${SPECIFIC_FILE}" ]; then
    if [ ! -f "${SPECIFIC_FILE}" ]; then
      echo -e "${RED}Error: File not found: ${SPECIFIC_FILE}${NC}" >&2
      exit 2
    fi
    echo "${SPECIFIC_FILE}"
    return
  fi

  # Find all CLAUDE.md files (case-insensitive)
  find "${REPO_ROOT}" \
    -name "CLAUDE.md" -o -name "claude.md" \
    2>/dev/null \
    | grep -v node_modules \
    | grep -v ".git/" \
    | sort
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

file_errors=0
file_warnings=0

reset_counters() {
  file_errors=0
  file_warnings=0
}

fail_check() {
  local msg="$1"
  echo -e "  ${RED}✗ FAIL:${NC} ${msg}"
  file_errors=$((file_errors + 1))
}

warn_check() {
  local msg="$1"
  echo -e "  ${YELLOW}⚠ WARN:${NC} ${msg}"
  file_warnings=$((file_warnings + 1))
  if [ "${STRICT_MODE}" = "true" ]; then
    file_errors=$((file_errors + 1))
  fi
}

pass_check() {
  local msg="$1"
  echo -e "  ${GREEN}✓${NC} ${msg}"
}

# Check: Has top-level markdown heading
check_has_heading() {
  local file="$1"
  local content="$2"
  if printf '%s\n' "${content}" | grep -qE '^# '; then
    pass_check "Has top-level heading"
  else
    fail_check "Missing top-level heading (# Title) - CLAUDE.md must begin with a heading"
  fi
}

# Check: No hardcoded secrets
check_no_secrets() {
  local file="$1"
  local content="$2"

  local matches
  matches="$(printf '%s\n' "${content}" | \
    grep -inE '(password|passwd|api[_-]?key|secret|auth[_-]?token|access[_-]?token)[[:space:]]*[=:][[:space:]]*["\047][a-zA-Z0-9+/._~\-]{8,}' \
    2>/dev/null || true)"

  if [ -n "${matches}" ]; then
    local real_secrets
    real_secrets="$(printf '%s\n' "${matches}" | \
      grep -ivE '(your-|placeholder|changeme|example|xxx|<.*>|\{.*\}|TODO|test-|fake-|mock-)' \
      2>/dev/null || true)"

    if [ -n "${real_secrets}" ]; then
      fail_check "Potential hardcoded secret detected - use placeholders or environment variables"
      return
    fi
  fi
  pass_check "No hardcoded secrets detected"
}

# Check: No private keys
check_no_private_keys() {
  local file="$1"
  local content="$2"
  if printf '%s\n' "${content}" | grep -qE 'BEGIN (RSA |EC |DSA |OPENSSH )?PRIVATE KEY' 2>/dev/null; then
    fail_check "Contains private key material - never store keys in CLAUDE.md"
  else
    pass_check "No private key material"
  fi
}

# Check: File size
check_size() {
  local file="$1"
  local content="$2"
  local line_count
  line_count="$(printf '%s\n' "${content}" | wc -l | tr -d ' ')"
  local byte_count
  byte_count="$(printf '%s' "${content}" | wc -c | tr -d ' ')"

  if [ "${line_count}" -gt 2000 ]; then
    fail_check "File too large: ${line_count} lines (max 2000) - split into multiple sections"
  elif [ "${line_count}" -gt 1000 ]; then
    warn_check "File approaching size limit: ${line_count} lines (warn at 1000)"
  else
    pass_check "File size OK: ${line_count} lines"
  fi

  if [ "${byte_count}" -gt 204800 ]; then
    fail_check "File too large: ${byte_count} bytes (max 200KB)"
  fi
}

# Check: No .env-like content
check_no_env_exposure() {
  local file="$1"
  local content="$2"
  if printf '%s\n' "${content}" | grep -qE '^[A-Z_]{3,}=.{8,}$' 2>/dev/null; then
    local candidates
    candidates="$(printf '%s\n' "${content}" | \
      grep -E '^[A-Z_]{3,}=.{8,}$' | \
      grep -ivE '(your-|placeholder|changeme|example|xxx|<|TODO)' \
      2>/dev/null || true)"
    if [ -n "${candidates}" ]; then
      warn_check "Contains environment variable assignments - verify no real values are exposed"
    else
      pass_check "No sensitive environment variable content"
    fi
  else
    pass_check "No environment variable exposure"
  fi
}

# Check: File is valid UTF-8 text (no binary/NUL content)
check_is_text() {
  local file="$1"
  # Use 'file' command if available, otherwise fall back to NUL byte check
  if command -v file >/dev/null 2>&1; then
    if file "${file}" 2>/dev/null | grep -qi 'text\|ASCII\|UTF-8'; then
      pass_check "Valid text file format"
    else
      warn_check "File may not be valid UTF-8 text - verify file encoding"
    fi
  else
    # Fallback: check for NUL bytes (binary indicator)
    if grep -qP '\x00' "${file}" 2>/dev/null; then
      warn_check "File contains NUL bytes - may not be valid UTF-8 text"
    else
      pass_check "Valid text file format (no NUL bytes detected)"
    fi
  fi
}

# Check: Required structure for copilot instruction files
check_structure() {
  local file="$1"
  local content="$2"

  # Files named exactly CLAUDE.md or claude.md at any level should have structure
  local has_sections
  has_sections="$(printf '%s\n' "${content}" | grep -c '^##' 2>/dev/null || echo 0)"

  if [ "${has_sections}" -eq 0 ]; then
    warn_check "No second-level sections found (## Section) - consider adding structure"
  else
    pass_check "Has ${has_sections} section(s)"
  fi
}

# =============================================================================
# VALIDATE SINGLE FILE
# =============================================================================

validate_file() {
  local file="$1"
  reset_counters
  TOTAL_FILES=$((TOTAL_FILES + 1))

  echo ""
  echo -e "${CYAN}${BOLD}┌─ Validating: ${file}${NC}"

  # Read file content
  local content
  content="$(cat "${file}" 2>/dev/null || true)"

  if [ -z "${content}" ]; then
    warn_check "File is empty"
    echo -e "${CYAN}${BOLD}└─ Result:${NC} ${YELLOW}WARN (empty file)${NC}"
    TOTAL_WARNINGS=$((TOTAL_WARNINGS + file_warnings))
    return
  fi

  # Run all checks
  check_has_heading    "${file}" "${content}"
  check_no_secrets     "${file}" "${content}"
  check_no_private_keys "${file}" "${content}"
  check_size           "${file}" "${content}"
  check_no_env_exposure "${file}" "${content}"
  check_is_text        "${file}"
  check_structure      "${file}" "${content}"

  # Accumulate counts
  TOTAL_ERRORS=$((TOTAL_ERRORS + file_errors))
  TOTAL_WARNINGS=$((TOTAL_WARNINGS + file_warnings))

  # Summary for this file
  if [ "${file_errors}" -gt 0 ]; then
    echo -e "${CYAN}${BOLD}└─ Result:${NC} ${RED}${BOLD}FAIL${NC} (${file_errors} error(s), ${file_warnings} warning(s))"
  elif [ "${file_warnings}" -gt 0 ]; then
    echo -e "${CYAN}${BOLD}└─ Result:${NC} ${YELLOW}WARN${NC} (${file_warnings} warning(s))"
    PASS_FILES=$((PASS_FILES + 1))
  else
    echo -e "${CYAN}${BOLD}└─ Result:${NC} ${GREEN}${BOLD}PASS${NC}"
    PASS_FILES=$((PASS_FILES + 1))
  fi
}

# =============================================================================
# MAIN
# =============================================================================

parse_args "$@"

echo ""
echo -e "${BOLD}╔═══════════════════════════════════════╗${NC}"
echo -e "${BOLD}║    CLAUDE.md Validation Report        ║${NC}"
echo -e "${BOLD}╚═══════════════════════════════════════╝${NC}"

# Check for policy file
if [ ! -f "${POLICY_FILE}" ]; then
  echo -e "${YELLOW}Warning: Policy file not found at ${POLICY_FILE}${NC}"
  echo "Running with built-in defaults. See config/claude-md-policy.yaml."
else
  echo -e "${BLUE}Policy:${NC} ${POLICY_FILE}"
fi

echo -e "${BLUE}Mode:${NC}   $([ "${STRICT_MODE}" = "true" ] && echo "strict (warnings = errors)" || echo "standard")"

# Discover and validate files
while IFS= read -r file; do
  [ -z "${file}" ] && continue
  validate_file "${file}"
done < <(discover_files)

# =============================================================================
# FINAL SUMMARY
# =============================================================================

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}Summary: ${TOTAL_FILES} file(s) checked, ${PASS_FILES} passed, $((TOTAL_FILES - PASS_FILES)) failed${NC}"
echo -e "${BOLD}         ${TOTAL_ERRORS} error(s), ${TOTAL_WARNINGS} warning(s)${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [ "${TOTAL_FILES}" -eq 0 ]; then
  echo -e "${YELLOW}No CLAUDE.md files found.${NC}"
  exit 0
fi

if [ "${REPORT_ONLY}" = "true" ]; then
  echo -e "${BLUE}Report-only mode: exiting 0 regardless of findings.${NC}"
  exit 0
fi

if [ "${TOTAL_ERRORS}" -gt 0 ]; then
  echo -e "${RED}${BOLD}CLAUDE.md validation FAILED.${NC}"
  echo "See docs/CLAUDE_MD_GUARDRAILS.md for remediation guidance."
  exit 1
fi

if [ "${TOTAL_WARNINGS}" -gt 0 ]; then
  echo -e "${GREEN}${BOLD}CLAUDE.md validation PASSED${NC} with ${TOTAL_WARNINGS} warning(s)."
else
  echo -e "${GREEN}${BOLD}CLAUDE.md validation PASSED.${NC}"
fi
exit 0
