#!/usr/bin/env bash
# size-ok: orchestrator consolidates multiple checks
# ============================================================
# Script: run-pipeline.sh
# Purpose: CI pipeline orchestrator - discovers and runs all CI checks

set -euo pipefail
#
# Usage:
#   ./scripts/ci/run-pipeline.sh [MODE] [OPTIONS]
#
# Modes (required, one of):
#   --pre-commit     Lightweight checks (target: < 2 minutes)
#   --pre-pr         Full pipeline checks (target: < 5 minutes)
#   --pre-merge      Pre-merge validation checks
#   --pre-release    Everything, all checks
#
# Options:
#   --parallel       Run independent checks in parallel (default: true)
#   --no-parallel    Run checks sequentially
#   --output FILE    Write JSON report to FILE (default: ci-report.json)
#   --no-report      Skip writing JSON report
#   --verbose        Show detailed output from each check
#   --quiet          Suppress all non-essential output
#   --config FILE    Use alternate config file (default: .ci-config.json)
#   --dry-run        Show what would run without running it
#   --scope changed  Only run tests/checks related to changed files
#   --changed FILES  Comma-separated list of changed files (for --scope changed)
#   --help           Show this help
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error (missing dependencies, invalid configuration)
#
# Configuration:
#   .ci-config.json              - Root JSON config file for check selection/timeouts
#   <dir>/.ci-config.json        - Directory-scoped overrides (merged with root config)
#   Environment variables override config file values:
#     CI_TIMEOUT_PRE_COMMIT  - Timeout for pre-commit (default: 120s)
#     CI_TIMEOUT_PRE_PR      - Timeout for pre-pr (default: 300s)
#     CI_PARALLEL            - Enable parallel (default: true)
#     CI_REPORT_FILE         - Report output path
#     CI_CHANGED_FILES       - Comma-separated changed files (used with --scope changed)
#
# Directory-scoped CI config overrides:
#   Place a .ci-config.json in any subdirectory to override CI settings for
#   files in that directory. The override format is:
#   {
#     "_scope": "my-dir",
#     "overrides": {
#       "pre-commit": { "timeout_seconds": 60, "additional_checks": [...] }
#     },
#     "thresholds": { "max_script_lines": 200 },
#     "test_mappings": { "foo.sh": ["tests/test-foo.sh"] }
#   }
#
# Selective test running (--scope changed):
#   When --scope changed is specified, the pipeline runs only checks and tests
#   related to the files changed since the last commit. This can reduce CI time
#   by >50% for typical PRs touching fewer than 10 files.
#   The selective runner maps changed files to tests using:
#     1. Naming conventions (scripts/foo.sh -> tests/scripts/test-foo.sh)
#     2. Directory-scoped test_mappings in .ci-config.json overrides
#     3. Root .test-runner.json explicit mappings
#
# Adding new checks:
#   1. Create a script in scripts/ci/ following naming: check-*.sh or validate-*.sh
#   2. Add the check to .ci-config.json under the appropriate modes
#   3. Ensure the script exits with 0 (pass) or non-zero (fail)
#   4. The script will be auto-discovered if added to the discovery list
#
# JSON Report Format:
#   {
#     "timestamp": "ISO-8601",
#     "mode": "pre-commit|pre-pr|pre-merge|pre-release",
#     "scope": "all|changed",
#     "changed_files": [...],
#     "duration_seconds": 42,
#     "duration_savings_pct": 60,
#     "passed": true|false,
#     "summary": { "total": N, "passed": N, "failed": N, "skipped": N },
#     "checks": [
#       { "name": "...", "status": "pass|fail|skip", "duration_seconds": N, "output": "..." }
#     ],
#     "dir_configs_applied": [...]
#   }

# ─── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_CONFIG_FILE=".state/.ci-config.json"
DEFAULT_REPORT_FILE="ci-report.json"
DEFAULT_TIMEOUT_PRE_COMMIT=120
DEFAULT_TIMEOUT_PRE_PR=300
DEFAULT_TIMEOUT_PRE_MERGE=300
DEFAULT_TIMEOUT_PRE_RELEASE=600

# ─── Cleanup Handler ──────────────────────────────────────────────────────────

cleanup() {
  local exit_code=$?
  # Clean up any temporary files or resources
  if [[ -n "${TEMP_FILES:-}" ]]; then
    rm -f $TEMP_FILES 2>/dev/null || true
  fi
  exit $exit_code
}

trap cleanup EXIT INT TERM

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────

MODE=""
PARALLEL="${CI_PARALLEL:-true}"
OUTPUT_FILE="${CI_REPORT_FILE:-$DEFAULT_REPORT_FILE}"
WRITE_REPORT=true
VERBOSE=false
QUIET=false
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
CONFIG_PATH=""
DRY_RUN=false
SCOPE="all"
CHANGED_FILES="${CI_CHANGED_FILES:-}"
DIR_CONFIGS_APPLIED=()
FULL_CHECK_COUNT=0  # Track total checks before scope filtering

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pre-commit)   MODE="pre-commit"; shift ;;
    --pre-pr)       MODE="pre-pr"; shift ;;
    --pre-merge)    MODE="pre-merge"; shift ;;
    --pre-release)  MODE="pre-release"; shift ;;
    --parallel)     PARALLEL=true; shift ;;
    --no-parallel)  PARALLEL=false; shift ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --no-report)    WRITE_REPORT=false; shift ;;
    --verbose)      VERBOSE=true; shift ;;
    --quiet)        QUIET=true; shift ;;
    --config)       CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --scope)        SCOPE="$2"; shift 2 ;;
    --changed)      CHANGED_FILES="$2"; shift 2 ;;
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
    echo -e "${CYAN}[DEBUG]${NC} $*"
  fi
}

log_step() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${BLUE}[STEP]${NC} $*"
  fi
}

# ─── Validation ───────────────────────────────────────────────────────────────

validate_prerequisites() {
  local missing=()

  if ! command -v jq &>/dev/null; then
    missing+=("jq")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Install with: apt-get install ${missing[*]}"
    exit 2
  fi

  if [[ -z "$MODE" ]]; then
    log_error "No mode specified. Use one of: --pre-commit, --pre-pr, --pre-merge, --pre-release"
    echo "Run with --help for usage." >&2
    exit 2
  fi
}

# ─── Configuration ────────────────────────────────────────────────────────────

# Load config from .ci-config.json or environment
load_config() {
  # Support both absolute paths and paths relative to repo root
  local config_path
  if [[ "$CONFIG_FILE" = /* ]]; then
    config_path="$CONFIG_FILE"
  else
    config_path="$REPO_ROOT/$CONFIG_FILE"
  fi
  CONFIG_PATH="$config_path"

  # Set timeout based on mode and env vars
  case "$MODE" in
    pre-commit)
      TIMEOUT="${CI_TIMEOUT_PRE_COMMIT:-$DEFAULT_TIMEOUT_PRE_COMMIT}"
      ;;
    pre-pr)
      TIMEOUT="${CI_TIMEOUT_PRE_PR:-$DEFAULT_TIMEOUT_PRE_PR}"
      ;;
    pre-merge)
      TIMEOUT="${CI_TIMEOUT_PRE_MERGE:-$DEFAULT_TIMEOUT_PRE_MERGE}"
      ;;
    pre-release)
      TIMEOUT="${CI_TIMEOUT_PRE_RELEASE:-$DEFAULT_TIMEOUT_PRE_RELEASE}"
      ;;
  esac

  # Override with config file values if present
  if [[ -f "$config_path" ]]; then
    log_verbose "Loading config from: $config_path"
    local cfg_timeout
    cfg_timeout=$(jq -r ".modes.\"$MODE\".timeout_seconds // empty" "$config_path" 2>/dev/null || true)
    if [[ -n "$cfg_timeout" ]]; then
      TIMEOUT="$cfg_timeout"
    fi

    local cfg_parallel
    cfg_parallel=$(jq -r ".parallel // empty" "$config_path" 2>/dev/null || true)
    # Command-line flag overrides config file
    if [[ -n "$cfg_parallel" ]] && [[ "$PARALLEL" == "${CI_PARALLEL:-true}" ]]; then
      PARALLEL="$cfg_parallel"
    fi
  fi

  log_verbose "Mode: $MODE, Timeout: ${TIMEOUT}s, Parallel: $PARALLEL"

  # Apply directory-scoped config overrides when changed files are known
  if [[ -n "$CHANGED_FILES" ]]; then
    _apply_dir_config_overrides
  fi
}

# ─── Directory-Scoped Config Merging ──────────────────────────────────────────

# Find and apply directory-scoped .ci-config.json overrides for changed files.
# Mutates global CONFIG_PATH to point to a merged temp config file.
_apply_dir_config_overrides() {
  local load_dir_script="$SCRIPT_DIR/load-dir-config.sh"

  if [[ ! -f "$load_dir_script" ]]; then
    log_verbose "load-dir-config.sh not found, skipping directory config merging"
    return
  fi

  # shellcheck source=scripts/ci/load-dir-config.sh
  # Use load-dir-config.sh to find and collect dir configs
  local dir_summary
  dir_summary=$(bash "$load_dir_script" \
    --changed "$CHANGED_FILES" \
    --config "$CONFIG_PATH" \
    --mode "$MODE" \
    --summary 2>/dev/null || echo '{"dir_config_count": 0, "dir_configs_applied": []}')

  local dir_count
  dir_count=$(echo "$dir_summary" | jq -r '.dir_config_count // 0' 2>/dev/null || echo "0")

  if [[ "$dir_count" -gt 0 ]]; then
    log_verbose "Found $dir_count directory-scoped CI config(s) to apply"

    # Generate merged config to a temp file
    local merged_config_file
    merged_config_file=$(mktemp --suffix=".ci-config.json")

    bash "$load_dir_script" \
      --changed "$CHANGED_FILES" \
      --config "$CONFIG_PATH" \
      --mode "$MODE" \
      2>/dev/null > "$merged_config_file" || true

    if jq empty "$merged_config_file" 2>/dev/null; then
      CONFIG_PATH="$merged_config_file"
      log_verbose "Applied directory config overrides from $dir_count config(s)"

      # Reload timeout from merged config
      local cfg_timeout
      cfg_timeout=$(jq -r ".modes.\"$MODE\".timeout_seconds // empty" "$merged_config_file" 2>/dev/null || true)
      if [[ -n "$cfg_timeout" ]]; then
        TIMEOUT="$cfg_timeout"
        log_verbose "Updated timeout from directory config: ${TIMEOUT}s"
      fi

      # Track applied configs for report
      while IFS= read -r applied; do
        [[ -n "$applied" ]] && DIR_CONFIGS_APPLIED+=("$applied")
      done < <(echo "$dir_summary" | jq -r '.dir_configs_applied[]?' 2>/dev/null || true)
    else
      log_warn "Merged directory config was invalid, using root config"
      rm -f "$merged_config_file"
    fi
  else
    log_verbose "No directory-scoped CI configs found for changed files"
  fi
}

# ─── Selective Test Runner (--scope changed) ──────────────────────────────────

# Get changed files from git when not provided explicitly.
_get_git_changed_files() {
  # Try to get changed files vs HEAD~1, fall back to staged files
  local files=""
  if git rev-parse HEAD~1 &>/dev/null 2>&1; then
    files=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || true)
  fi
  if [[ -z "$files" ]]; then
    files=$(git diff --name-only --cached 2>/dev/null || true)
  fi
  if [[ -z "$files" ]]; then
    files=$(git diff --name-only 2>/dev/null || true)
  fi
  echo "$files" | tr '\n' ',' | sed 's/,$//'
}

# Run selective tests for changed files using test-runner.py
run_selective_tests() {
  local changed_files="$1"
  local test_runner="$REPO_ROOT/scripts/test-runner.py"

  if [[ ! -f "$test_runner" ]]; then
    log_verbose "test-runner.py not found at $test_runner, skipping selective test run"
    return 0
  fi

  if ! command -v python3 &>/dev/null; then
    log_verbose "python3 not available, skipping selective test run"
    return 0
  fi

  log_step "Running selective tests for changed files"

  # Collect directory-level test mappings
  local load_dir_script="$SCRIPT_DIR/load-dir-config.sh"
  local dir_mappings="{}"
  if [[ -f "$load_dir_script" ]]; then
    dir_mappings=$(bash "$load_dir_script" \
      --changed "$changed_files" \
      --config "$CONFIG_PATH" \
      --mappings 2>/dev/null || echo "{}")
  fi

  # Write dir mappings to a temp config for test-runner
  local runner_config
  runner_config=$(mktemp --suffix=".test-runner.json")
  echo "{\"mappings\": $dir_mappings}" > "$runner_config"

  # Run test-runner with changed files
  local runner_output_file
  runner_output_file=$(mktemp --suffix="-test-runner-report.json")

  local runner_exit=0
  python3 "$test_runner" \
    --fast \
    --changed "$changed_files" \
    --config "$runner_config" \
    --output "$runner_output_file" \
    --output-format summary \
    2>&1 | sed 's/^/  [test-runner] /' || runner_exit=$?

  rm -f "$runner_config"

  # Record result
  local runner_status="pass"
  if [[ $runner_exit -ne 0 ]]; then
    runner_status="fail"
  fi

  local runner_output=""
  if [[ -f "$runner_output_file" ]]; then
    runner_output=$(cat "$runner_output_file")
    rm -f "$runner_output_file"
  fi

  CHECK_NAMES+=("selective-tests")
  CHECK_STATUSES+=("$runner_status")
  CHECK_DURATIONS+=(0)
  CHECK_OUTPUTS+=("$runner_output")

  if [[ "$runner_status" == "pass" ]]; then
    if [[ "$QUIET" != "true" ]]; then
      echo -e "  ${GREEN}✓${NC} selective-tests"
    fi
  else
    echo -e "  ${RED}✗${NC} selective-tests (exit: $runner_exit)"
  fi
}

# Filter check list to only those relevant to changed files.
# For --scope changed: keeps structural/security checks but adds selective test runner.
filter_checks_for_scope() {
  local -n _check_list_ref="$1"
  local changed_files="$2"

  # Checks that always run regardless of scope (structural integrity checks)
  local always_run=("naming-conventions" "structure" "security-lightweight" "security-full")

  local -a filtered=()
  for check_entry in "${_check_list_ref[@]}"; do
    local name="${check_entry%%:*}"
    local always=false
    for always_name in "${always_run[@]}"; do
      if [[ "$name" == "$always_name" ]]; then
        always=true
        break
      fi
    done
    if [[ "$always" == "true" ]]; then
      filtered+=("$check_entry")
    else
      # For non-always checks, only include if changed files touch relevant areas
      local script="${check_entry#*:}"
      script="${script%%:*}"
      # Include script-sizes if any script files changed
      if [[ "$name" == "script-sizes" ]]; then
        if echo "$changed_files" | grep -qE '\.(sh|py|js|ts)$' 2>/dev/null; then
          filtered+=("$check_entry")
        fi
      # Include agent-docs if any agent docs changed
      elif [[ "$name" == "agent-docs" ]]; then
        if echo "$changed_files" | grep -qE '(agents/|\.md$)' 2>/dev/null; then
          filtered+=("$check_entry")
        fi
      # Include dependencies check if dependency files changed
      elif [[ "$name" == "dependencies" ]]; then
        if echo "$changed_files" | grep -qE '(package\.json|requirements|Gemfile|go\.mod|Makefile)' 2>/dev/null; then
          filtered+=("$check_entry")
        fi
      # Include fixtures check if fixture files changed
      elif [[ "$name" == "fixtures" ]]; then
        if echo "$changed_files" | grep -qE '(fixtures/|\.fixture\.)' 2>/dev/null; then
          filtered+=("$check_entry")
        fi
      # Include refactor-lint if source files changed
      elif [[ "$name" == "refactor-lint" ]]; then
        if echo "$changed_files" | grep -qE '\.(sh|py|js|ts|rb|go)$' 2>/dev/null; then
          filtered+=("$check_entry")
        fi
      else
        # Default: include the check
        filtered+=("$check_entry")
      fi
    fi
  done

  _check_list_ref=("${filtered[@]}")
}

# ─── Check Discovery ──────────────────────────────────────────────────────────

# Returns list of checks to run for the given mode
# Format: "name:script:args"
get_checks_for_mode() {
  local mode="$1"
  # Use CONFIG_PATH set by load_config (handles absolute/relative paths)
  local config_path="${CONFIG_PATH:-$REPO_ROOT/$CONFIG_FILE}"

  # If config file exists, use it to determine checks
  if [[ -f "$config_path" ]]; then
    local config_checks
    config_checks=$(jq -r ".modes.\"$mode\".checks[]? | \"\(.name):\(.script):\(.args // \"\")\"" "$config_path" 2>/dev/null || true)
    if [[ -n "$config_checks" ]]; then
      echo "$config_checks"
      return
    fi
  fi

  # Default check sets per mode
  case "$mode" in
    pre-commit)
      # Lightweight: fast checks only
      echo "naming-conventions:check-naming-conventions.sh:"
      echo "script-sizes:check-script-sizes.sh:--files"
      echo "structure:check-structure.sh:"
      ;;
    pre-pr)
      # Full: all standard checks
      echo "naming-conventions:check-naming-conventions.sh:"
      echo "script-sizes:check-script-sizes.sh:"
      echo "structure:check-structure.sh:"
      echo "dependencies:check-dependencies.sh:"
      echo "fixtures:ci-validate-fixtures.sh:"
      echo "refactor-lint:refactor-lint.sh:--scope changed --severity high"
      echo "design-compliance:design-compliance.sh:"
      ;;
    pre-merge)
      # Validation: all standard + refactor lint
      echo "naming-conventions:check-naming-conventions.sh:"
      echo "script-sizes:check-script-sizes.sh:"
      echo "structure:check-structure.sh:"
      echo "dependencies:check-dependencies.sh:"
      echo "fixtures:ci-validate-fixtures.sh:"
      echo "refactor-lint:refactor-lint.sh:--severity medium"
      echo "design-compliance:design-compliance.sh:"
      ;;
    pre-release)
      # Everything: comprehensive validation
      echo "naming-conventions:check-naming-conventions.sh:"
      echo "script-sizes:check-script-sizes.sh:--strict"
      echo "structure:check-structure.sh:"
      echo "dependencies:check-dependencies.sh:"
      echo "fixtures:ci-validate-fixtures.sh:"
      echo "refactor-lint:refactor-lint.sh:--severity low"
      echo "design-compliance:design-compliance.sh:--verbose"
      ;;
  esac
}

# ─── Check Execution ──────────────────────────────────────────────────────────

# Globals for tracking results
declare -a CHECK_NAMES=()
declare -a CHECK_STATUSES=()
declare -a CHECK_DURATIONS=()
declare -a CHECK_OUTPUTS=()

# Run a single check and record results
run_check() {
  local name="$1"
  local script="$2"
  local args="$3"
  local script_path="$REPO_ROOT/scripts/ci/$script"
  local result_file
  result_file=$(mktemp)

  # Validate script exists
  if [[ ! -f "$script_path" ]]; then
    log_warn "Check script not found: $script_path (skipping)"
    CHECK_NAMES+=("$name")
    CHECK_STATUSES+=("skip")
    CHECK_DURATIONS+=(0)
    CHECK_OUTPUTS+=("Script not found: $script_path")
    rm -f "$result_file"
    return
  fi

  if [[ ! -x "$script_path" ]]; then
    log_warn "Check script not executable: $script_path (skipping)"
    CHECK_NAMES+=("$name")
    CHECK_STATUSES+=("skip")
    CHECK_DURATIONS+=(0)
    CHECK_OUTPUTS+=("Script not executable: $script_path")
    rm -f "$result_file"
    return
  fi

  log_step "Running check: $name"

  local start_time
  start_time=$(date +%s)

  # Build args array safely
  local args_array=()
  if [[ -n "$args" ]]; then
    # Split args on spaces (simple split, no quoting support)
    IFS=' ' read -ra args_array <<< "$args"
  fi

  # Run with timeout, capture output and exit code
  local output exit_code
  local tmp_out
  tmp_out=$(mktemp)
  (cd "$REPO_ROOT" && timeout "$TIMEOUT" "$script_path" "${args_array[@]}" >"$tmp_out" 2>&1) && exit_code=0 || exit_code=$?
  output=$(cat "$tmp_out")
  rm -f "$tmp_out"

  if [[ $exit_code -eq 124 ]]; then
    output="TIMEOUT: Check exceeded ${TIMEOUT}s limit"
  fi

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Record result
  local status="pass"
  if [[ $exit_code -ne 0 ]]; then
    status="fail"
  fi

  CHECK_NAMES+=("$name")
  CHECK_STATUSES+=("$status")
  CHECK_DURATIONS+=("$duration")
  CHECK_OUTPUTS+=("$output")

  # Display result
  if [[ "$status" == "pass" ]]; then
    if [[ "$QUIET" != "true" ]]; then
      echo -e "  ${GREEN}✓${NC} $name (${duration}s)"
    fi
  else
    echo -e "  ${RED}✗${NC} $name (${duration}s, exit: $exit_code)"
    if [[ "$VERBOSE" == "true" ]] || [[ "$QUIET" != "true" ]]; then
      echo "$output" | head -20 | sed 's/^/    /'
    fi
  fi

  if [[ "$VERBOSE" == "true" ]] && [[ "$status" == "pass" ]]; then
    echo "$output" | head -10 | sed 's/^/    /'
  fi

  rm -f "$result_file"
}

# Run checks in parallel
run_checks_parallel() {
  local -a check_list=("$@")
  local -a pids=()
  local -a tmp_files=()

  log_verbose "Running ${#check_list[@]} checks in parallel"

  # Launch all checks in background
  for check_entry in "${check_list[@]}"; do
    local name script args
    name="${check_entry%%:*}"
    local rest="${check_entry#*:}"
    script="${rest%%:*}"
    args="${rest#*:}"

    local tmp_file
    tmp_file=$(mktemp)
    tmp_files+=("$tmp_file")

    (
      # Run in subshell and write results to tmp file
      CHECK_NAMES=()
      CHECK_STATUSES=()
      CHECK_DURATIONS=()
      CHECK_OUTPUTS=()

      run_check "$name" "$script" "$args"

      # Write results to tmp file as delimited data
      {
        echo "${CHECK_NAMES[0]:-}"
        echo "${CHECK_STATUSES[0]:-skip}"
        echo "${CHECK_DURATIONS[0]:-0}"
        printf '%s\n' "${CHECK_OUTPUTS[0]:-}"
      } > "$tmp_file"
    ) &
    pids+=($!)
  done

  # Wait for all and collect results
  local i=0
  for pid in "${pids[@]}"; do
    wait "$pid" || true
    local tmp_file="${tmp_files[$i]}"

    if [[ -f "$tmp_file" ]]; then
      local name status duration output
      name=$(sed -n '1p' "$tmp_file")
      status=$(sed -n '2p' "$tmp_file")
      duration=$(sed -n '3p' "$tmp_file")
      output=$(tail -n +4 "$tmp_file")

      CHECK_NAMES+=("$name")
      CHECK_STATUSES+=("$status")
      CHECK_DURATIONS+=("$duration")
      CHECK_OUTPUTS+=("$output")

      rm -f "$tmp_file"
    fi
    i=$((i + 1))
  done
}

# Run checks sequentially
run_checks_sequential() {
  local -a check_list=("$@")

  log_verbose "Running ${#check_list[@]} checks sequentially"

  for check_entry in "${check_list[@]}"; do
    local name script args
    name="${check_entry%%:*}"
    local rest="${check_entry#*:}"
    script="${rest%%:*}"
    args="${rest#*:}"

    run_check "$name" "$script" "$args"
  done
}

# ─── Report Generation ────────────────────────────────────────────────────────

generate_json_report() {
  local mode="$1"
  local pipeline_start="$2"
  local pipeline_end="$3"
  local total_duration=$((pipeline_end - pipeline_start))
  local full_check_count="${FULL_CHECK_COUNT:-0}"

  # Count results
  local total=0 passed=0 failed=0 skipped=0
  for status in "${CHECK_STATUSES[@]}"; do
    total=$((total + 1))
    case "$status" in
      pass) passed=$((passed + 1)) ;;
      fail) failed=$((failed + 1)) ;;
      skip) skipped=$((skipped + 1)) ;;
    esac
  done

  local overall_passed="true"
  if [[ $failed -gt 0 ]]; then
    overall_passed="false"
  fi

  # Build checks JSON array
  local checks_json="["
  local first=true
  for i in "${!CHECK_NAMES[@]}"; do
    local name="${CHECK_NAMES[$i]}"
    local status="${CHECK_STATUSES[$i]}"
    local duration="${CHECK_DURATIONS[$i]}"
    local output="${CHECK_OUTPUTS[$i]}"

    # Escape output for JSON
    local escaped_output
    escaped_output=$(printf '%s' "$output" | jq -Rs '.')

    if [[ "$first" != "true" ]]; then
      checks_json+=","
    fi
    first=false

    checks_json+=$(jq -n \
      --arg name "$name" \
      --arg status "$status" \
      --argjson duration "$duration" \
      --argjson output "$escaped_output" \
      '{name: $name, status: $status, duration_seconds: $duration, output: $output}')
  done
  checks_json+="]"

  # Build complete report
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Calculate savings percentage when scope=changed
  local savings_pct=0
  if [[ "$SCOPE" == "changed" ]] && [[ "$full_check_count" -gt 0 ]] && [[ "$total" -lt "$full_check_count" ]]; then
    savings_pct=$(( (full_check_count - total) * 100 / full_check_count ))
  fi

  # Build changed_files JSON array
  local changed_files_json="[]"
  if [[ -n "$CHANGED_FILES" ]]; then
    changed_files_json=$(echo "$CHANGED_FILES" | tr ',' '\n' | jq -R . | jq -s . 2>/dev/null || echo "[]")
  fi

  # Build dir_configs_applied JSON array
  local dir_configs_json="[]"
  if [[ ${#DIR_CONFIGS_APPLIED[@]} -gt 0 ]]; then
    dir_configs_json=$(printf '%s\n' "${DIR_CONFIGS_APPLIED[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")
  fi

  jq -n \
    --arg timestamp "$timestamp" \
    --arg mode "$mode" \
    --arg scope "$SCOPE" \
    --argjson duration "$total_duration" \
    --argjson savings_pct "$savings_pct" \
    --argjson passed_bool "$overall_passed" \
    --argjson total "$total" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    --argjson skipped "$skipped" \
    --argjson checks "$checks_json" \
    --argjson changed_files "$changed_files_json" \
    --argjson dir_configs "$dir_configs_json" \
    '{
      timestamp: $timestamp,
      mode: $mode,
      scope: $scope,
      changed_files: $changed_files,
      duration_seconds: $duration,
      duration_savings_pct: $savings_pct,
      passed: $passed_bool,
      summary: {
        total: $total,
        passed: $passed,
        failed: $failed,
        skipped: $skipped
      },
      checks: $checks,
      dir_configs_applied: $dir_configs
    }'
}

print_summary() {
  local total=0 passed=0 failed=0 skipped=0
  for status in "${CHECK_STATUSES[@]}"; do
    total=$((total + 1))
    case "$status" in
      pass) passed=$((passed + 1)) ;;
      fail) failed=$((failed + 1)) ;;
      skip) skipped=$((skipped + 1)) ;;
    esac
  done

  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo -e "${BOLD}  CI Pipeline Summary${NC}"
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo ""
  echo "  Mode:    $MODE"
  if [[ "$SCOPE" == "changed" ]]; then
    echo "  Scope:   changed (selective)"
    if [[ "$FULL_CHECK_COUNT" -gt 0 ]] && [[ "$total" -lt "$FULL_CHECK_COUNT" ]]; then
      local savings_pct=$(( (FULL_CHECK_COUNT - total) * 100 / FULL_CHECK_COUNT ))
      echo -e "  Savings: ${GREEN}${savings_pct}% fewer checks${NC} ($total of $FULL_CHECK_COUNT run)"
    fi
  fi
  echo "  Total:   $total checks"
  echo -e "  Passed:  ${GREEN}$passed${NC}"
  if [[ $failed -gt 0 ]]; then
    echo -e "  Failed:  ${RED}$failed${NC}"
  else
    echo "  Failed:  $failed"
  fi
  if [[ $skipped -gt 0 ]]; then
    echo -e "  Skipped: ${YELLOW}$skipped${NC}"
  fi
  echo ""

  if [[ $failed -gt 0 ]]; then
    echo -e "  ${RED}✗ FAILED${NC} - $failed check(s) failed"
    echo ""
    echo "  Failed checks:"
    for i in "${!CHECK_NAMES[@]}"; do
      if [[ "${CHECK_STATUSES[$i]}" == "fail" ]]; then
        echo -e "    ${RED}•${NC} ${CHECK_NAMES[$i]}"
      fi
    done
  else
    echo -e "  ${GREEN}✓ PASSED${NC} - All checks passed"
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════${NC}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  validate_prerequisites
  load_config

  cd "$REPO_ROOT"

  # Banner
  if [[ "$QUIET" != "true" ]]; then
    echo ""
    echo -e "${BOLD}CI Pipeline Orchestrator${NC}"
    local scope_label="$SCOPE"
    if [[ "$SCOPE" == "changed" ]] && [[ -n "$CHANGED_FILES" ]]; then
      local nfiles
      nfiles=$(echo "$CHANGED_FILES" | tr ',' '\n' | grep -c '.' || echo 0)
      scope_label="changed ($nfiles file(s))"
    fi
    echo -e "Mode: ${CYAN}$MODE${NC}  |  Scope: ${CYAN}${scope_label}${NC}  |  Timeout: ${TIMEOUT}s  |  Parallel: $PARALLEL"
    echo "────────────────────────────────────────"
    echo ""
  fi

  # Validate scope
  if [[ "$SCOPE" != "all" ]] && [[ "$SCOPE" != "changed" ]]; then
    log_error "Invalid --scope value: $SCOPE (must be 'all' or 'changed')"
    exit 2
  fi

  # Auto-detect changed files for --scope changed
  if [[ "$SCOPE" == "changed" ]] && [[ -z "$CHANGED_FILES" ]]; then
    log_verbose "Auto-detecting changed files from git..."
    CHANGED_FILES=$(_get_git_changed_files)
    if [[ -n "$CHANGED_FILES" ]]; then
      log_info "Detected changed files: $(echo "$CHANGED_FILES" | tr ',' '\n' | wc -l | tr -d ' ') file(s)"
    else
      log_info "No changed files detected - running full suite"
      SCOPE="all"
    fi
  fi

  # Get checks for mode
  local check_list=()
  while IFS= read -r check; do
    [[ -n "$check" ]] && check_list+=("$check")
  done < <(get_checks_for_mode "$MODE")

  if [[ ${#check_list[@]} -eq 0 ]]; then
    log_warn "No checks configured for mode: $MODE"
    exit 0
  fi

  # Record full check count before scope filtering (for savings reporting)
  FULL_CHECK_COUNT=${#check_list[@]}

  # Apply scope filtering for --scope changed
  if [[ "$SCOPE" == "changed" ]] && [[ -n "$CHANGED_FILES" ]]; then
    log_info "Scope: changed (filtering checks for ${#check_list[@]} configured checks)"
    filter_checks_for_scope check_list "$CHANGED_FILES"
    local saved_checks=$((FULL_CHECK_COUNT - ${#check_list[@]}))
    if [[ $saved_checks -gt 0 ]]; then
      log_info "Scope filtering: skipping $saved_checks check(s) not relevant to changed files"
    fi
  fi

  log_info "Found ${#check_list[@]} check(s) for mode: $MODE"
  echo ""

  # Dry run mode
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN - would execute the following checks:"
    if [[ "$SCOPE" == "changed" ]]; then
      echo "  (scope: changed - ${#check_list[@]} of $FULL_CHECK_COUNT checks selected)"
      if [[ -n "$CHANGED_FILES" ]]; then
        echo "  Changed files:"
        echo "$CHANGED_FILES" | tr ',' '\n' | sed 's/^/    - /'
      fi
    fi
    for check_entry in "${check_list[@]}"; do
      local name script args
      name="${check_entry%%:*}"
      local rest="${check_entry#*:}"
      script="${rest%%:*}"
      args="${rest#*:}"
      echo "  • $name ($script${args:+ $args})"
    done
    if [[ "$SCOPE" == "changed" ]]; then
      echo "  • selective-tests (test-runner.py --fast)"
    fi
    echo ""
    exit 0
  fi

  # Record start time
  local pipeline_start
  pipeline_start=$(date +%s)

  # Run checks
  if [[ "$PARALLEL" == "true" ]] && [[ ${#check_list[@]} -gt 1 ]]; then
    run_checks_parallel "${check_list[@]}"
  else
    run_checks_sequential "${check_list[@]}"
  fi

  # Run selective tests when scope=changed
  if [[ "$SCOPE" == "changed" ]] && [[ -n "$CHANGED_FILES" ]]; then
    run_selective_tests "$CHANGED_FILES"
  fi

  # Record end time
  local pipeline_end
  pipeline_end=$(date +%s)

  # Generate and write report
  local report
  report=$(generate_json_report "$MODE" "$pipeline_start" "$pipeline_end")

  if [[ "$WRITE_REPORT" == "true" ]]; then
    echo "$report" > "$OUTPUT_FILE"
    log_verbose "Report written to: $OUTPUT_FILE"

    # Store results in .ci/ for local CI dashboard
    local store_script="$SCRIPT_DIR/store-results.sh"
    if [[ -x "$store_script" ]]; then
      echo "$report" | "$store_script" --stdin --quiet || true
      log_verbose "CI results stored to .ci/"
    fi
  fi

  # Print summary
  if [[ "$QUIET" != "true" ]]; then
    print_summary
  fi

  # Determine exit code
  local has_failures=false
  for status in "${CHECK_STATUSES[@]}"; do
    if [[ "$status" == "fail" ]]; then
      has_failures=true
      break
    fi
  done

  if [[ "$has_failures" == "true" ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
