#!/usr/bin/env bash
# ============================================================
# Script: validate-repo-settings.sh
# Purpose: Validate GitHub repository settings against configuration
#
# Detects drift between actual GitHub repository settings and the
# desired state defined in config/repo-settings.yaml
#
# Usage:
#   ./scripts/ci/validate-repo-settings.sh [OPTIONS]
#
# Options:
#   --config FILE        Path to repo-settings.yaml (default: config/repo-settings.yaml)
#   --profile FILE       Path to repo-profile.yaml (default: config/repo-profile.yaml)
#   --mode MODE          Enforcement mode: advisory (warn) or strict (block)
#   --check SETTING      Check specific setting (can be repeated)
#   --auto-fix           Attempt to fix drift automatically (requires admin)
#   --report             Generate drift report (JSON output)
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  No drift detected (settings match configuration)
#   1  Drift detected (settings don't match)
#   2  Error (missing config, API failure, etc.)
#
# Integration:
#   - Called during PR creation via hook
#   - Called before PR merge
#   - Can be run manually for drift detection
#
# Related: Issue #940 (repo settings drift detection)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO_SETTINGS="${REPO_SETTINGS:-config/repo-settings.yaml}"
REPO_PROFILE="${REPO_PROFILE:-config/repo-profile.yaml}"
MODE=""
CHECK_SETTINGS=()
AUTO_FIX=false
REPORT=false
VERBOSE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Drift tracking ───────────────────────────────────────────────────────────

DRIFT_COUNT=0
declare -a DRIFT_DETAILS=()

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)       REPO_SETTINGS="$2"; shift 2 ;;
    --profile)      REPO_PROFILE="$2"; shift 2 ;;
    --mode)         MODE="$2"; shift 2 ;;
    --check)        CHECK_SETTINGS+=("$2"); shift 2 ;;
    --auto-fix)     AUTO_FIX=true; shift ;;
    --report)       REPORT=true; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --help|-h)      show_help ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      echo "Run with --help for usage." >&2
      exit 2
      ;;
  esac
done

# ─── Utility Functions ────────────────────────────────────────────────────────

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[VERBOSE]${NC} $*" >&2
  fi
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $*"
}

record_drift() {
  local setting="$1"
  local expected="$2"
  local actual="$3"
  local severity="${4:-warning}"

  DRIFT_COUNT=$((DRIFT_COUNT + 1))
  DRIFT_DETAILS+=("$severity|$setting|$expected|$actual")

  if [[ "$severity" == "error" ]]; then
    log_error "Drift detected: $setting"
  else
    log_warn "Drift detected: $setting"
  fi
  log_verbose "  Expected: $expected"
  log_verbose "  Actual:   $actual"
}

# ─── Validation ───────────────────────────────────────────────────────────────

check_prerequisites() {
  local errors=0

  if ! command -v yq &>/dev/null; then
    log_error "yq is required for YAML parsing"
    echo "  Install: brew install yq (macOS) or snap install yq (Linux)" >&2
    errors=1
  fi

  if ! command -v gh &>/dev/null; then
    log_error "gh CLI is required"
    echo "  Install from: https://cli.github.com/" >&2
    errors=1
  fi

  if ! command -v jq &>/dev/null; then
    log_error "jq is required for JSON parsing"
    echo "  Install: brew install jq (macOS) or apt install jq (Linux)" >&2
    errors=1
  fi

  if ! gh auth status &>/dev/null 2>&1; then
    log_error "gh CLI not authenticated"
    echo "  Run: gh auth login" >&2
    errors=1
  fi

  if [[ ! -f "$REPO_ROOT/$REPO_SETTINGS" ]]; then
    log_error "Settings config not found: $REPO_SETTINGS"
    echo "  Expected location: $REPO_ROOT/$REPO_SETTINGS" >&2
    errors=1
  fi

  if [[ ! -f "$REPO_ROOT/$REPO_PROFILE" ]]; then
    log_warn "Repo profile not found: $REPO_PROFILE"
    echo "  Run /repo-init to create repo profile" >&2
    echo "  Assuming private repo visibility for now" >&2
  fi

  return $errors
}

# ─── Get Repository Information ──────────────────────────────────────────────

get_repo_visibility() {
  # Get visibility from repo profile, default to private
  if [[ -f "$REPO_ROOT/$REPO_PROFILE" ]]; then
    yq eval '.visibility.type' "$REPO_ROOT/$REPO_PROFILE" 2>/dev/null || echo "private"
  else
    echo "private"
  fi
}

get_repo_owner_name() {
  # Get owner/repo from GitHub
  gh repo view --json nameWithOwner --jq '.nameWithOwner'
}

# ─── Fetch GitHub Settings ────────────────────────────────────────────────────

fetch_repo_settings() {
  log_verbose "Fetching repository settings from GitHub API..."
  gh api "repos/:owner/:repo" --jq '{
    allow_auto_merge: .allow_auto_merge,
    allow_merge_commit: .allow_merge_commit,
    allow_squash_merge: .allow_squash_merge,
    allow_rebase_merge: .allow_rebase_merge,
    delete_branch_on_merge: .delete_branch_on_merge,
    default_branch: .default_branch,
    allow_forking: .allow_forking,
    private: .private
  }'
}

fetch_branch_protection() {
  local branch="$1"
  log_verbose "Fetching branch protection for: $branch"

  # Check if branch exists first
  if ! gh api "repos/:owner/:repo/branches/$branch" &>/dev/null; then
    log_verbose "  Branch $branch does not exist"
    echo "null"
    return
  fi

  # Fetch branch protection (may not exist)
  gh api "repos/:owner/:repo/branches/$branch/protection" 2>/dev/null || echo "null"
}

# ─── Compare Settings ─────────────────────────────────────────────────────────

compare_boolean() {
  local setting="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$expected" != "$actual" ]]; then
    record_drift "$setting" "$expected" "$actual" "warning"
    return 1
  fi
  return 0
}

compare_string() {
  local setting="$1"
  local expected="$2"
  local actual="$3"

  if [[ "$expected" != "$actual" ]]; then
    record_drift "$setting" "$expected" "$actual" "warning"
    return 1
  fi
  return 0
}

compare_branch_protection() {
  local branch="$1"
  local visibility="$2"
  local expected_config="$REPO_ROOT/$REPO_SETTINGS"

  # Get expected settings for this branch and visibility
  local expected_protection
  expected_protection=$(yq eval ".$visibility.branch_protection.$branch" "$expected_config" 2>/dev/null)

  if [[ "$expected_protection" == "null" ]] || [[ -z "$expected_protection" ]]; then
    log_verbose "No protection config defined for branch: $branch (visibility: $visibility)"
    return 0
  fi

  # Get actual branch protection
  local actual_protection
  actual_protection=$(fetch_branch_protection "$branch")

  if [[ "$actual_protection" == "null" ]]; then
    log_warn "Branch protection not configured for: $branch"
    record_drift "branch_protection.$branch" "configured" "not configured" "warning"
    return 1
  fi

  # Compare specific protection settings
  local setting_path

  # Required status checks
  if yq eval ".$visibility.branch_protection.$branch.required_status_checks" "$expected_config" &>/dev/null; then
    local expected_strict
    expected_strict=$(yq eval ".$visibility.branch_protection.$branch.required_status_checks.strict" "$expected_config")
    local actual_strict
    actual_strict=$(echo "$actual_protection" | jq -r '.required_status_checks.strict // "null"')

    if [[ "$expected_strict" != "null" ]] && [[ "$expected_strict" != "$actual_strict" ]]; then
      record_drift "branch_protection.$branch.required_status_checks.strict" "$expected_strict" "$actual_strict" "warning"
    fi
  fi

  # Required approving review count
  local expected_reviews
  expected_reviews=$(yq eval ".$visibility.branch_protection.$branch.required_pull_request_reviews.required_approving_review_count" "$expected_config" 2>/dev/null || echo "null")
  if [[ "$expected_reviews" != "null" ]]; then
    local actual_reviews
    actual_reviews=$(echo "$actual_protection" | jq -r '.required_pull_request_reviews.required_approving_review_count // 0')

    if [[ "$expected_reviews" != "$actual_reviews" ]]; then
      record_drift "branch_protection.$branch.required_approving_review_count" "$expected_reviews" "$actual_reviews" "warning"
    fi
  fi

  # Linear history
  local expected_linear
  expected_linear=$(yq eval ".$visibility.branch_protection.$branch.required_linear_history" "$expected_config" 2>/dev/null || echo "null")
  if [[ "$expected_linear" != "null" ]]; then
    local actual_linear
    actual_linear=$(echo "$actual_protection" | jq -r '.required_linear_history.enabled // false')

    if [[ "$expected_linear" != "$actual_linear" ]]; then
      record_drift "branch_protection.$branch.required_linear_history" "$expected_linear" "$actual_linear" "warning"
    fi
  fi

  return 0
}

# ─── Validate Settings ────────────────────────────────────────────────────────

validate_repository_settings() {
  local visibility="$1"
  local actual_settings
  actual_settings=$(fetch_repo_settings)

  log_verbose "Comparing repository-level settings..."

  # Compare each setting
  local expected_value actual_value

  # allow_auto_merge
  expected_value=$(yq eval ".$visibility.repository.allow_auto_merge" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.allow_auto_merge')
  compare_boolean "repository.allow_auto_merge" "$expected_value" "$actual_value"

  # allow_merge_commit
  expected_value=$(yq eval ".$visibility.repository.allow_merge_commit" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.allow_merge_commit')
  compare_boolean "repository.allow_merge_commit" "$expected_value" "$actual_value"

  # allow_squash_merge
  expected_value=$(yq eval ".$visibility.repository.allow_squash_merge" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.allow_squash_merge')
  compare_boolean "repository.allow_squash_merge" "$expected_value" "$actual_value"

  # allow_rebase_merge
  expected_value=$(yq eval ".$visibility.repository.allow_rebase_merge" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.allow_rebase_merge')
  compare_boolean "repository.allow_rebase_merge" "$expected_value" "$actual_value"

  # delete_branch_on_merge
  expected_value=$(yq eval ".$visibility.repository.delete_branch_on_merge" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.delete_branch_on_merge')
  compare_boolean "repository.delete_branch_on_merge" "$expected_value" "$actual_value"

  # default_branch
  expected_value=$(yq eval ".$visibility.repository.default_branch" "$REPO_ROOT/$REPO_SETTINGS")
  actual_value=$(echo "$actual_settings" | jq -r '.default_branch')
  compare_string "repository.default_branch" "$expected_value" "$actual_value"
}

validate_branch_protections() {
  local visibility="$1"

  log_verbose "Validating branch protections..."

  # Get list of branches to check based on visibility
  local branches_to_check=()

  if [[ "$visibility" == "private" ]]; then
    branches_to_check=("main" "qa" "dev")
  else
    branches_to_check=("main")
  fi

  for branch in "${branches_to_check[@]}"; do
    compare_branch_protection "$branch" "$visibility"
  done
}

# ─── Generate Report ──────────────────────────────────────────────────────────

generate_report() {
  local visibility="$1"
  local timestamp
  timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  cat <<EOF
{
  "timestamp": "$timestamp",
  "repository": "$(get_repo_owner_name)",
  "visibility": "$visibility",
  "drift_count": $DRIFT_COUNT,
  "drift_details": [
EOF

  local first=true
  for detail in "${DRIFT_DETAILS[@]}"; do
    IFS='|' read -r severity setting expected actual <<< "$detail"

    if [[ "$first" == "true" ]]; then
      first=false
    else
      echo ","
    fi

    cat <<EOF
    {
      "severity": "$severity",
      "setting": "$setting",
      "expected": "$expected",
      "actual": "$actual"
    }
EOF
  done

  cat <<EOF

  ],
  "status": "$( [[ $DRIFT_COUNT -eq 0 ]] && echo "compliant" || echo "drift_detected" )"
}
EOF
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}Repository Settings Drift Detection${NC}"
  echo "────────────────────────────────────────────────────────────"

  # Pre-flight checks
  if ! check_prerequisites; then
    exit 2
  fi

  # Get repository info
  local visibility
  visibility=$(get_repo_visibility)

  local repo_name
  repo_name=$(get_repo_owner_name)

  # Determine enforcement mode
  if [[ -z "$MODE" ]]; then
    MODE=$(yq eval '.drift_detection.mode' "$REPO_ROOT/$REPO_SETTINGS" 2>/dev/null || echo "advisory")
  fi

  echo -e "Repository:  ${YELLOW}$repo_name${NC}"
  echo -e "Visibility:  ${YELLOW}$visibility${NC}"
  echo -e "Mode:        ${YELLOW}$MODE${NC}"
  echo ""

  # Validate settings
  log_info "Validating repository settings..."
  validate_repository_settings "$visibility"

  log_info "Validating branch protections..."
  validate_branch_protections "$visibility"

  echo ""
  echo "────────────────────────────────────────────────────────────"

  # Generate report if requested
  if [[ "$REPORT" == "true" ]]; then
    generate_report "$visibility"
    exit 0
  fi

  # Summary
  if [[ $DRIFT_COUNT -eq 0 ]]; then
    log_success "No drift detected"
    echo "  All repository settings match the configuration"
    exit 0
  else
    echo -e "${YELLOW}Drift Summary:${NC}"
    echo "  Settings with drift: $DRIFT_COUNT"
    echo ""

    # Display drift details
    for detail in "${DRIFT_DETAILS[@]}"; do
      IFS='|' read -r severity setting expected actual <<< "$detail"
      echo -e "  ${YELLOW}•${NC} $setting"
      echo -e "    Expected: $expected"
      echo -e "    Actual:   $actual"
    done

    echo ""

    if [[ "$MODE" == "strict" ]]; then
      log_error "Drift detected in strict mode - BLOCKING"
      echo ""
      echo "Fix repository settings to match config/repo-settings.yaml"
      echo "Or update the configuration if settings have intentionally changed"
      exit 1
    else
      log_warn "Drift detected in advisory mode - WARNING"
      echo ""
      echo "Consider updating repository settings or the configuration file"
      exit 0
    fi
  fi
}

main "$@"
