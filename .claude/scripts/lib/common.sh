#!/usr/bin/env bash
set -euo pipefail
# ============================================================
# Script: common.sh
# Purpose: Shared utility functions for all scripts
# Usage: source "$(dirname "$0")/lib/common.sh"
# Dependencies: None (pure bash)
# ============================================================

# Prevent double-sourcing
if [ -n "${_COMMON_SH_LOADED:-}" ]; then
  return 0
fi
readonly _COMMON_SH_LOADED=1

# Color codes (only if terminal supports it)
if [ -t 1 ]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[0;33m'
  readonly BLUE='\033[0;34m'
  readonly CYAN='\033[0;36m'
  readonly BOLD='\033[1m'
  readonly NC='\033[0m'  # No Color
else
  readonly RED=''
  readonly GREEN=''
  readonly YELLOW=''
  readonly BLUE=''
  readonly CYAN=''
  readonly BOLD=''
  readonly NC=''
fi

# ============================================================
# Logging Functions
# ============================================================

# Log informational message (blue)
# Usage: log_info "message"
log_info() {
  echo -e "${BLUE}[INFO]${NC} $*" >&2
}

# Log warning message (yellow)
# Usage: log_warn "message"
log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Log error message (red)
# Usage: log_error "message"
log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Log success message (green)
# Usage: log_success "message"
log_success() {
  echo -e "${GREEN}[OK]${NC} $*" >&2
}

# Log debug message (only if DEBUG is set)
# Usage: log_debug "message"
log_debug() {
  if [ -n "${DEBUG:-}" ]; then
    echo -e "[DEBUG] $*" >&2
  fi
}

# ============================================================
# Error Handling
# ============================================================

# Log error and exit with code 1
# Usage: die "message"
die() {
  log_error "$*"
  exit 1
}

# Log error and exit with specific code
# Usage: die_with_code 2 "Invalid arguments"
die_with_code() {
  local code="$1"
  shift
  log_error "$*"
  exit "$code"
}

# ============================================================
# Validation Functions
# ============================================================

# Check if a command exists, die if not
# Usage: require_command "jq"
require_command() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    die_with_code 3 "Required command not found: $cmd"
  fi
}

# Check if a variable is set and non-empty, die if not
# Usage: require_var "MY_VAR"
require_var() {
  local var_name="$1"
  local var_value="${!var_name:-}"
  if [ -z "$var_value" ]; then
    die_with_code 2 "Required variable not set: $var_name"
  fi
}

# Check if a file exists, die if not
# Usage: require_file "/path/to/file"
require_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    die_with_code 5 "Required file not found: $file"
  fi
}

# Check if a directory exists, die if not
# Usage: require_dir "/path/to/dir"
require_dir() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    die_with_code 5 "Required directory not found: $dir"
  fi
}

# ============================================================
# Utility Functions
# ============================================================

# Get the directory of the current script
# Usage: SCRIPT_DIR=$(get_script_dir)
get_script_dir() {
  cd "$(dirname "${BASH_SOURCE[1]}")" && pwd
}

# Check if running in a git repository
# Usage: if is_git_repo; then ...
is_git_repo() {
  git rev-parse --git-dir &>/dev/null
}

# Get the repository root directory
# Usage: REPO_ROOT=$(get_repo_root)
get_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Check if running in a worktree
# Usage: if is_worktree; then ...
is_worktree() {
  local git_dir
  git_dir=$(git rev-parse --git-dir 2>/dev/null)
  [ -f "$git_dir/commondir" ]
}

# Generate a timestamp in ISO 8601 format
# Usage: ts=$(timestamp)
timestamp() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ============================================================
# JSON Helpers
# ============================================================

# Output a simple JSON object
# Usage: json_result "success" "Operation completed"
json_result() {
  local status="$1"
  local message="$2"
  jq -n \
    --arg status "$status" \
    --arg message "$message" \
    --arg timestamp "$(timestamp)" \
    '{status: $status, message: $message, timestamp: $timestamp}'
}

# Output a JSON error object
# Usage: json_error "Something went wrong"
json_error() {
  local message="$1"
  json_result "error" "$message"
}

# Output a JSON success object
# Usage: json_success "Operation completed"
json_success() {
  local message="$1"
  json_result "success" "$message"
}
