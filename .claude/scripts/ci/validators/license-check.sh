#!/usr/bin/env bash
# ============================================================
# Script: license-check.sh
# Purpose: Validate LICENSE file presence, format, and required content
#
# This script enforces that the repository has a valid LICENSE file
# containing non-commercial open source terms and required sections.
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LICENSE_FILE="$REPO_ROOT/LICENSE"

# Required licensor value (base64 encoded)
REQUIRED_LICENSOR="VG8gTXkgU29uIFRoZW8sIEkgTG92ZSBZb3U="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Flags
VERBOSE=false
QUIET=false

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[INFO]${NC} $*"
  fi
}

log_warn() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
  fi
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}[DEBUG]${NC} $*"
  fi
}

log_success() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[✓]${NC} $*"
  fi
}

log_fail() {
  echo -e "${RED}[✗]${NC} $*" >&2
}

# ─── Help ─────────────────────────────────────────────────────────────────────

show_help() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Validates that the LICENSE file exists, contains the correct license type,
and includes all required sections.

Options:
  --verbose       Show detailed validation steps
  --quiet         Suppress all non-error output
  --help, -h      Show this help message

Exit codes:
  0  License validation passed
  1  License validation failed (missing file, invalid content, or missing sections)
  2  Invalid arguments or script error

Requirements:
  - LICENSE file must exist at repository root
  - License must be non-commercial open source (e.g., PolyForm Noncommercial License)
  - License must clearly state commercial use is not authorized without permission
  - License must include a Licensor section with required value

Examples:
  $(basename "$0")                    # Validate license with normal output
  $(basename "$0") --verbose          # Show detailed validation steps
  $(basename "$0") --quiet            # Only show errors
EOF
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verbose)
        VERBOSE=true
        shift
        ;;
      --quiet)
        QUIET=true
        shift
        ;;
      --help|-h)
        show_help
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        echo "Run with --help for usage." >&2
        exit 2
        ;;
    esac
  done
}

# ─── Validation Functions ─────────────────────────────────────────────────────

check_file_exists() {
  log_verbose "Checking if LICENSE file exists at: $LICENSE_FILE"

  if [[ ! -f "$LICENSE_FILE" ]]; then
    log_fail "LICENSE file not found at repository root"
    log_error "Expected location: $LICENSE_FILE"
    return 1
  fi

  log_verbose "LICENSE file exists"
  return 0
}

check_noncommercial_license() {
  log_verbose "Checking for non-commercial license terms"

  # Check for common non-commercial license indicators
  local has_noncommercial=false

  if grep -qi "noncommercial" "$LICENSE_FILE" || \
     grep -qi "non-commercial" "$LICENSE_FILE" || \
     grep -qi "Business Source License" "$LICENSE_FILE" || \
     grep -qi "Commons Clause" "$LICENSE_FILE"; then
    has_noncommercial=true
    log_verbose "Found non-commercial license indicator"
  fi

  if [[ "$has_noncommercial" != "true" ]]; then
    log_fail "LICENSE does not appear to be a non-commercial open source license"
    log_error "Expected one of: PolyForm Noncommercial License, Business Source License (BSL), Commons Clause, or custom non-commercial license"
    return 1
  fi

  log_verbose "Non-commercial license terms found"
  return 0
}

check_commercial_restriction() {
  log_verbose "Checking for commercial use restrictions"

  # Check that the license mentions restrictions on commercial use
  # or defines permitted purposes excluding commercial use
  local has_restriction=false

  if grep -qi "permitted purpose" "$LICENSE_FILE" || \
     grep -qi "commercial" "$LICENSE_FILE" || \
     grep -qi "permission" "$LICENSE_FILE"; then
    has_restriction=true
    log_verbose "Found commercial restriction language"
  fi

  if [[ "$has_restriction" != "true" ]]; then
    log_fail "LICENSE does not clearly state restrictions on commercial use"
    log_error "License must explicitly address commercial use restrictions or require permission"
    return 1
  fi

  log_verbose "Commercial use restriction found"
  return 0
}

check_licensor_section() {
  log_verbose "Checking for required Licensor section"

  # Check if the license contains the required licensor value
  if ! grep -qF "$REQUIRED_LICENSOR" "$LICENSE_FILE"; then
    log_fail "LICENSE is missing required Licensor section"
    log_error "The LICENSE file must include a Licensor section with value: $REQUIRED_LICENSOR"
    log_error ""
    log_error "Add the following section to your LICENSE file:"
    log_error ""
    log_error "Licensor"
    log_error ""
    log_error "$REQUIRED_LICENSOR"
    log_error ""
    return 1
  fi

  log_verbose "Required Licensor section found"
  return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  parse_args "$@"

  if [[ "$QUIET" != "true" ]]; then
    echo ""
    echo -e "${BOLD}License Validation Check${NC}"
    echo "────────────────────────────────────────"
    echo ""
  fi

  local exit_code=0

  # Run all validation checks
  if ! check_file_exists; then
    exit_code=1
  elif ! check_noncommercial_license; then
    exit_code=1
  elif ! check_commercial_restriction; then
    exit_code=1
  elif ! check_licensor_section; then
    exit_code=1
  fi

  # Summary
  if [[ $exit_code -eq 0 ]]; then
    log_success "All license validation checks passed"
    if [[ "$QUIET" != "true" ]]; then
      echo ""
      echo -e "${GREEN}✓ LICENSE file is valid${NC}"
      echo "  - Non-commercial open source license: Yes"
      echo "  - Commercial use restrictions: Yes"
      echo "  - Required Licensor section: Yes"
      echo ""
    fi
  else
    if [[ "$QUIET" != "true" ]]; then
      echo ""
      echo -e "${RED}✗ LICENSE validation failed${NC}"
      echo ""
      echo "Fix the issues above and run this check again."
      echo ""
    fi
  fi

  exit $exit_code
}

main "$@"
