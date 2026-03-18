#!/usr/bin/env bash
# ============================================================
# Script: install-bats.sh
# Purpose: Install bats-core (Bash Automated Testing System)
#          for shell script testing in CI and local environments
#
# Usage:
#   ./scripts/ci/install-bats.sh [--prefix PREFIX] [--version VERSION]
#
# Options:
#   --prefix DIR    Installation prefix (default: /usr/local)
#   --version VER   bats-core version (default: v1.11.0)
#   --check         Check if bats is installed and exit
#   --help          Show this help
#
# After installation, run bats tests with:
#   bats tests/unit/bats/
#
# Exit codes:
#   0  Success
#   1  Error
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
BATS_VERSION="${BATS_VERSION:-v1.11.0}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/usr/local}"
CHECK_ONLY=false

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info()    { echo "[install-bats] INFO: $*"; }
log_success() { echo "[install-bats] OK: $*"; }
log_warn()    { echo "[install-bats] WARN: $*" >&2; }
log_error()   { echo "[install-bats] ERROR: $*" >&2; }

# ─── Argument Parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --prefix)
      INSTALL_PREFIX="$2"
      shift 2
      ;;
    --version)
      BATS_VERSION="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=true
      shift
      ;;
    --help|-h)
      sed -n '2,20p' "$0" | grep -E '^#' | sed 's/^# \?//'
      exit 0
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
done

# ─── Check Existing Installation ──────────────────────────────────────────────

check_bats() {
  if command -v bats &>/dev/null; then
    local version
    version=$(bats --version 2>&1 | head -1)
    log_success "bats is installed: $version"
    return 0
  else
    log_warn "bats is not installed"
    return 1
  fi
}

if $CHECK_ONLY; then
  check_bats
  exit $?
fi

if check_bats; then
  log_info "bats already installed, skipping installation"
  exit 0
fi

# ─── Install bats-core ────────────────────────────────────────────────────────

log_info "Installing bats-core ${BATS_VERSION} to ${INSTALL_PREFIX}..."

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

# Clone bats-core and helper libraries
cd "$TEMP_DIR"

log_info "Cloning bats-core..."
git clone --depth 1 --branch "$BATS_VERSION" \
  https://github.com/bats-core/bats-core.git bats-core

log_info "Installing bats-core..."
cd bats-core
./install.sh "$INSTALL_PREFIX"

# Install bats helper libraries
cd "$TEMP_DIR"

log_info "Cloning bats-support..."
git clone --depth 1 \
  https://github.com/bats-core/bats-support.git \
  "${INSTALL_PREFIX}/lib/bats-support" 2>/dev/null || true

log_info "Cloning bats-assert..."
git clone --depth 1 \
  https://github.com/bats-core/bats-assert.git \
  "${INSTALL_PREFIX}/lib/bats-assert" 2>/dev/null || true

log_info "Cloning bats-file..."
git clone --depth 1 \
  https://github.com/bats-core/bats-file.git \
  "${INSTALL_PREFIX}/lib/bats-file" 2>/dev/null || true

# Verify installation
if check_bats; then
  log_success "bats-core installation complete"
  log_info "Run tests: bats tests/unit/bats/"
  exit 0
else
  log_error "bats installation verification failed"
  exit 1
fi
