#!/usr/bin/env bash
# Purpose: Run the full test suite using available test runners
# Usage: ./scripts/ci/run-tests.sh [--suite=<suite>] [--docker]
#
# Suites:
#   all         Run all test suites (default)
#   agents      Run agent validation only (scripts/validate/validate-agents.sh --all)
#   shell       Run shell unit tests from tests/unit/
#   python      Run Python tests via pytest
#   github      Run GitHub conventions validation
#
# Options:
#   --docker    Run in Docker Ubuntu 24.04 container (mirrors make test-ci)
#
# Exit codes:
#   0  All tests pass
#   1  One or more test suites failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

SUITE="all"
USE_DOCKER=false
FAILED=0

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --suite=*)
      SUITE="${arg#*=}"
      ;;
    --docker)
      USE_DOCKER=true
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      echo "Usage: $0 [--suite=all|agents|shell|python|github] [--docker]" >&2
      exit 1
      ;;
  esac
done

cd "${REPO_ROOT}"

# Docker mode: delegate to make test-ci
if [[ "${USE_DOCKER}" == "true" ]]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Running CI tests in Docker Ubuntu 24.04..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  make test-ci
  exit $?
fi

# ─── Helper ──────────────────────────────────────────────────────────────────

run_suite() {
  local name="$1"
  local cmd="$2"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Suite: ${name}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if eval "${cmd}"; then
    echo "✅ ${name}: PASSED"
  else
    echo "❌ ${name}: FAILED"
    FAILED=$((FAILED + 1))
  fi
}

# ─── Agent Validation ─────────────────────────────────────────────────────────

run_agents() {
  if [[ -x "${REPO_ROOT}/scripts/validate/validate-agents.sh" ]]; then
    run_suite "Agent Validation" "${REPO_ROOT}/scripts/validate/validate-agents.sh --all"
  else
    echo "⚠ scripts/validate/validate-agents.sh not found — skipping agent validation."
  fi
}

# ─── Shell Unit Tests ─────────────────────────────────────────────────────────

run_shell_tests() {
  local test_dir="${REPO_ROOT}/tests/unit"
  if [[ -d "${test_dir}" ]]; then
    local count=0
    local pass=0
    local fail=0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Suite: Shell Unit Tests"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    while IFS= read -r test_file; do
      [[ -f "${test_file}" ]] || continue
      count=$((count + 1))
      chmod +x "${test_file}"
      echo "Running: ${test_file}"
      if bash "${test_file}"; then
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
        echo "❌ FAILED: ${test_file}"
        FAILED=$((FAILED + 1))
      fi
    done < <(find "${test_dir}" -name "test-*.sh" -o -name "*.test.sh" | sort)

    if [[ ${count} -eq 0 ]]; then
      echo "⚠ No shell test files found in ${test_dir}."
    else
      echo ""
      echo "Shell tests: ${pass}/${count} passed, ${fail} failed."
      if [[ ${fail} -eq 0 ]]; then
        echo "✅ Shell Unit Tests: PASSED"
      else
        echo "❌ Shell Unit Tests: FAILED"
      fi
    fi
  else
    echo "⚠ tests/unit/ not found — skipping shell unit tests."
  fi
}

# ─── Python Tests ─────────────────────────────────────────────────────────────

run_python_tests() {
  if command -v pytest &>/dev/null; then
    run_suite "Python Tests (pytest)" "pytest tests/ -v --tb=short 2>&1"
  elif [[ -f "${REPO_ROOT}/pyproject.toml" ]]; then
    echo "⚠ pytest not installed. Install with: pip install pytest"
    echo "  Skipping Python test suite."
  fi
}

# ─── GitHub Conventions ───────────────────────────────────────────────────────

run_github_conventions() {
  if [[ -x "${REPO_ROOT}/scripts/validate/validate-github-conventions.sh" ]]; then
    if command -v gh &>/dev/null; then
      run_suite "GitHub Conventions" "${REPO_ROOT}/scripts/validate/validate-github-conventions.sh --check"
    else
      echo "⚠ gh CLI not available — skipping GitHub conventions check."
    fi
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CI Test Runner"
echo "Suite: ${SUITE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

case "${SUITE}" in
  all)
    run_agents
    run_shell_tests
    run_python_tests
    run_github_conventions
    ;;
  agents)
    run_agents
    ;;
  shell)
    run_shell_tests
    ;;
  python)
    run_python_tests
    ;;
  github)
    run_github_conventions
    ;;
  *)
    echo "Unknown suite: ${SUITE}" >&2
    echo "Valid suites: all, agents, shell, python, github" >&2
    exit 1
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${FAILED} -eq 0 ]]; then
  echo "✅ All test suites passed."
  exit 0
else
  echo "❌ ${FAILED} test suite(s) failed."
  exit 1
fi
