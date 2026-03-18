#!/usr/bin/env bash
# ============================================================
# Script: install-ci-tools.sh
# Purpose: Install CI/CD pipeline tools for local development
#
# Installs all required tools for running local CI checks:
#   - jq (JSON processing)
#   - pip-audit (Python CVE scanner)
#   - safety (Python vulnerability scanner)
#   - shellcheck (Shell script linter)
#   - Node.js/npm (for npm audit)
#
# Usage:
#   ./scripts/ci/install-ci-tools.sh [OPTIONS]
#
# Options:
#   --all               Install all tools (default)
#   --python-only       Install only Python tools (pip-audit, safety)
#   --node-only         Install only Node.js tools (npm)
#   --minimal           Install only essential tools (jq)
#   --skip-python       Skip Python tools
#   --skip-node         Skip Node.js tools
#   --dry-run           Show what would be installed without installing
#   --verbose           Show detailed output
#   --help              Show this help
#
# Exit codes:
#   0 - All requested tools installed successfully
#   1 - One or more tools failed to install
#   2 - Invalid options or missing prerequisites
#
# Requirements:
#   - apt/apt-get (for Debian/Ubuntu)
#   - brew (for macOS)
#   - python3/pip3 (for Python tools)
#
# Related:
#   - scripts/ci/dep-audit.sh - Dependency scanner
#   - scripts/ci/dep-review.sh - PR dependency review
#   - Issue #968 - Add local CI dependency scanning
# ============================================================

set -euo pipefail

# ─── Defaults ─────────────────────────────────────────────────────────────────

INSTALL_MODE="all"
SKIP_PYTHON=false
SKIP_NODE=false
DRY_RUN=false
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
    --all)          INSTALL_MODE="all"; shift ;;
    --python-only)  INSTALL_MODE="python"; shift ;;
    --node-only)    INSTALL_MODE="node"; shift ;;
    --minimal)      INSTALL_MODE="minimal"; shift ;;
    --skip-python)  SKIP_PYTHON=true; shift ;;
    --skip-node)    SKIP_NODE=true; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --help|-h)      show_help ;;
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
  echo -e "${BLUE}[INSTALL]${NC} $*"
}

log_skip() {
  echo -e "${YELLOW}[SKIP]${NC} $*"
}

log_success() {
  echo -e "${GREEN}[✓]${NC} $*"
}

# ─── Detect OS ────────────────────────────────────────────────────────────────

detect_os() {
  if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "linux"
  elif [[ "$OSTYPE" == "darwin"* ]]; then
    echo "macos"
  else
    echo "unknown"
  fi
}

# ─── Package Manager Detection ────────────────────────────────────────────────

get_package_manager() {
  local os="$1"

  if [[ "$os" == "macos" ]]; then
    if command -v brew &>/dev/null; then
      echo "brew"
    else
      echo "none"
    fi
  elif [[ "$os" == "linux" ]]; then
    if command -v apt-get &>/dev/null; then
      echo "apt"
    elif command -v yum &>/dev/null; then
      echo "yum"
    else
      echo "none"
    fi
  else
    echo "none"
  fi
}

# ─── Tool Installation Functions ──────────────────────────────────────────────

install_jq() {
  local os="$1"
  local pm="$2"

  if command -v jq &>/dev/null; then
    log_success "jq already installed ($(jq --version 2>&1 || echo 'version unknown'))"
    return 0
  fi

  log_step "Installing jq..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install: jq"
    return 0
  fi

  case "$pm" in
    apt)
      sudo apt-get update -qq &>/dev/null || true
      sudo apt-get install -y jq
      ;;
    brew)
      brew install jq
      ;;
    yum)
      sudo yum install -y jq
      ;;
    *)
      log_error "Cannot install jq: unsupported package manager"
      return 1
      ;;
  esac

  if command -v jq &>/dev/null; then
    log_success "jq installed successfully"
    return 0
  else
    log_error "jq installation failed"
    return 1
  fi
}

install_python_tools() {
  if [[ "$SKIP_PYTHON" == "true" ]]; then
    log_skip "Skipping Python tools (--skip-python)"
    return 0
  fi

  if [[ "$INSTALL_MODE" == "node" ]] || [[ "$INSTALL_MODE" == "minimal" ]]; then
    log_skip "Skipping Python tools (mode: $INSTALL_MODE)"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    log_error "python3 not found - install Python 3 first"
    return 1
  fi

  if ! command -v pip3 &>/dev/null && ! command -v pip &>/dev/null; then
    log_error "pip not found - install pip first"
    return 1
  fi

  local pip_cmd="pip3"
  command -v pip3 &>/dev/null || pip_cmd="pip"

  # Install pip-audit
  if command -v pip-audit &>/dev/null; then
    log_success "pip-audit already installed ($(pip-audit --version 2>&1 | head -1 || echo 'version unknown'))"
  else
    log_step "Installing pip-audit..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "Would install: pip-audit"
    else
      $pip_cmd install --user pip-audit || {
        log_error "pip-audit installation failed"
        return 1
      }
      log_success "pip-audit installed successfully"
    fi
  fi

  # Install safety
  if command -v safety &>/dev/null; then
    log_success "safety already installed ($(safety --version 2>&1 | head -1 || echo 'version unknown'))"
  else
    log_step "Installing safety..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "Would install: safety"
    else
      $pip_cmd install --user safety || {
        log_error "safety installation failed"
        return 1
      }
      log_success "safety installed successfully"
    fi
  fi

  return 0
}

install_shellcheck() {
  local os="$1"
  local pm="$2"

  if command -v shellcheck &>/dev/null; then
    log_success "shellcheck already installed ($(shellcheck --version | grep version | cut -d' ' -f2 || echo 'version unknown'))"
    return 0
  fi

  log_step "Installing shellcheck..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Would install: shellcheck"
    return 0
  fi

  case "$pm" in
    apt)
      sudo apt-get update -qq &>/dev/null || true
      sudo apt-get install -y shellcheck
      ;;
    brew)
      brew install shellcheck
      ;;
    yum)
      sudo yum install -y ShellCheck
      ;;
    *)
      log_warn "Cannot install shellcheck: unsupported package manager"
      log_warn "Install manually: https://github.com/koalaman/shellcheck#installing"
      return 0  # Non-critical, don't fail
      ;;
  esac

  if command -v shellcheck &>/dev/null; then
    log_success "shellcheck installed successfully"
    return 0
  else
    log_warn "shellcheck installation failed (non-critical)"
    return 0
  fi
}

check_node() {
  if [[ "$SKIP_NODE" == "true" ]]; then
    log_skip "Skipping Node.js check (--skip-node)"
    return 0
  fi

  if [[ "$INSTALL_MODE" == "python" ]] || [[ "$INSTALL_MODE" == "minimal" ]]; then
    log_skip "Skipping Node.js check (mode: $INSTALL_MODE)"
    return 0
  fi

  if command -v node &>/dev/null && command -v npm &>/dev/null; then
    local node_version
    node_version=$(node --version 2>&1 || echo "unknown")
    local npm_version
    npm_version=$(npm --version 2>&1 || echo "unknown")
    log_success "Node.js already installed (node $node_version, npm $npm_version)"
    return 0
  else
    log_warn "Node.js/npm not found"
    log_warn "npm audit requires Node.js - install from: https://nodejs.org/"
    log_warn "Or use package manager: apt install nodejs npm / brew install node"
    return 0  # Non-critical, don't fail
  fi
}

install_package_reputation_tools() {
  if [[ "$SKIP_NODE" == "true" ]]; then
    log_skip "Skipping package reputation tools (--skip-node)"
    return 0
  fi

  if [[ "$INSTALL_MODE" == "python" ]] || [[ "$INSTALL_MODE" == "minimal" ]]; then
    log_skip "Skipping package reputation tools (mode: $INSTALL_MODE)"
    return 0
  fi

  if ! command -v npm &>/dev/null; then
    log_warn "npm not found - package reputation tools require Node.js/npm"
    return 0
  fi

  # Check npm version for audit signatures support
  local npm_version
  npm_version=$(npm --version 2>&1 || echo "0.0.0")
  local npm_major
  npm_major=$(echo "$npm_version" | cut -d. -f1)

  if [[ "$npm_major" -lt 8 ]]; then
    log_warn "npm $npm_version detected - npm audit signatures requires npm 8+"
    log_warn "Upgrade npm: npm install -g npm@latest"
  else
    log_success "npm $npm_version supports audit signatures"
  fi

  # Install lockfile-lint (optional but recommended)
  log_step "Checking for lockfile-lint..."
  if command -v lockfile-lint &>/dev/null || npm list -g lockfile-lint &>/dev/null; then
    log_success "lockfile-lint already available"
  else
    if [[ "$DRY_RUN" == "true" ]]; then
      log_info "Would install: lockfile-lint (npx will handle on-demand)"
    else
      log_info "lockfile-lint will be installed on-demand via npx"
      log_info "To pre-install: npm install -g lockfile-lint"
    fi
  fi

  # Check for optional tools
  log_step "Checking for optional supply chain tools..."

  if command -v socket &>/dev/null; then
    log_success "Socket.dev CLI already installed ($(socket --version 2>&1 || echo 'version unknown'))"
  else
    log_info "Socket.dev CLI not found (optional)"
    log_info "Install: npm install -g @socketsecurity/cli"
  fi

  if command -v snyk &>/dev/null; then
    log_success "Snyk CLI already installed"
  else
    log_info "Snyk CLI not found (optional)"
    log_info "Install: npm install -g snyk"
  fi

  if command -v scorecard &>/dev/null; then
    log_success "OSSF Scorecard already installed"
  else
    log_info "OSSF Scorecard not found (optional)"
    log_info "Install: go install github.com/ossf/scorecard/v4/cmd/scorecard@latest"
  fi

  return 0
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BOLD}CI Tools Installation${NC}"
  echo -e "Mode: $INSTALL_MODE"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}DRY RUN - no changes will be made${NC}"
  fi
  echo "────────────────────────────────────────"
  echo ""

  # Detect OS and package manager
  local os
  os=$(detect_os)
  log_verbose "Detected OS: $os"

  local pm
  pm=$(get_package_manager "$os")
  log_verbose "Package manager: $pm"

  if [[ "$pm" == "none" ]]; then
    log_error "No supported package manager found (apt, yum, or brew)"
    log_error "Install tools manually"
    exit 2
  fi

  # Track installation status
  local failed=0

  # Install essential tools
  install_jq "$os" "$pm" || failed=$((failed + 1))

  # Install Python tools
  install_python_tools || failed=$((failed + 1))

  # Install shellcheck (optional)
  install_shellcheck "$os" "$pm" || true

  # Check Node.js (informational only)
  check_node || true

  # Install package reputation tools (optional)
  install_package_reputation_tools || true

  # Summary
  echo ""
  echo "────────────────────────────────────────"
  if [[ $failed -eq 0 ]]; then
    log_success "All tools installed successfully!"
    echo ""
    echo "  Verify installation:"
    echo "    jq --version"
    echo "    pip-audit --version"
    echo "    safety --version"
    echo "    npm --version"
    echo ""
    echo "  Run dependency audit:"
    echo "    ./scripts/ci/dep-audit.sh"
    echo ""
    echo "  Run package reputation check:"
    echo "    ./scripts/ci/package-reputation.sh"
    echo ""
  else
    log_error "$failed tool(s) failed to install"
    exit 1
  fi

  exit 0
}

main "$@"
