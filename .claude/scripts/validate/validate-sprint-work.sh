#!/usr/bin/env bash
# validate-sprint-work.sh - Validate sprint-work.md has required sections and keywords
#
# Usage:
#   ./scripts/validate-sprint-work.sh [--verbose] [--file PATH]
#
# Exit codes:
#   0 - Valid (all required sections and keywords found)
#   1 - Invalid (missing required sections or keywords)
#   2 - Error (file not found, etc.)
#
# Required by workers who depend on sprint-work.md for SDLC instructions.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_FILE="${REPO_ROOT}/core/commands/sprint-work.md"

# Required sections that must exist in sprint-work.md
# Workers depend on these for SDLC workflow
REQUIRED_SECTIONS=(
  "## Steps"
  "## Usage"
  "## Notes"
  "### 0.1. Worktree Pre-flight"
  "### 4. Start Work"
  "### 5. Execute SDLC Phases"
  "### 6. Create PR"
)

# Required keywords that indicate critical instructions are present
# These ensure workers have proper guidance
REQUIRED_KEYWORDS=(
  "Fixes #"           # PR linking convention
  "--base dev"        # Target branch guidance (appears in PR creation command)
  "worktree"          # Worktree workflow
  "commit"            # Commit instructions
  "SDLC"              # Workflow reference
  "blocked"           # Blocking guidance
  "in-progress"       # Status labels
  "backlog"           # Status labels
)

# Parse arguments
VERBOSE=false
SPRINT_WORK_FILE="${DEFAULT_FILE}"

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --file|-f)
      SPRINT_WORK_FILE="$2"
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--verbose] [--file PATH]"
      echo ""
      echo "Validates sprint-work.md contains required sections and keywords."
      echo ""
      echo "Options:"
      echo "  --verbose, -v    Show detailed output"
      echo "  --file, -f PATH  Path to sprint-work.md (default: core/commands/sprint-work.md)"
      echo "  --help, -h       Show this help message"
      echo ""
      echo "Exit codes:"
      echo "  0 - Valid"
      echo "  1 - Invalid (missing sections/keywords)"
      echo "  2 - Error"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

# Check file exists
if [[ ! -f "${SPRINT_WORK_FILE}" ]]; then
  echo "ERROR: sprint-work.md not found at: ${SPRINT_WORK_FILE}" >&2
  exit 2
fi

# Track validation results
missing_sections=()
missing_keywords=()
has_errors=false

# Read file content once
file_content=$(cat "${SPRINT_WORK_FILE}")

# Check required sections
if ${VERBOSE}; then
  echo "Checking required sections..."
fi

for section in "${REQUIRED_SECTIONS[@]}"; do
  if echo "${file_content}" | grep -qF "${section}"; then
    if ${VERBOSE}; then
      echo "  ✓ Found: ${section}"
    fi
  else
    missing_sections+=("${section}")
    has_errors=true
    if ${VERBOSE}; then
      echo "  ✗ Missing: ${section}"
    fi
  fi
done

# Check required keywords (case-insensitive)
if ${VERBOSE}; then
  echo ""
  echo "Checking required keywords..."
fi

for keyword in "${REQUIRED_KEYWORDS[@]}"; do
  # Use -F for fixed string (literal) and -- to handle patterns starting with dashes
  if echo "${file_content}" | grep -qiF -- "${keyword}"; then
    if ${VERBOSE}; then
      echo "  ✓ Found: ${keyword}"
    fi
  else
    missing_keywords+=("${keyword}")
    has_errors=true
    if ${VERBOSE}; then
      echo "  ✗ Missing: ${keyword}"
    fi
  fi
done

# Output results
if ${has_errors}; then
  echo ""
  echo "⚠️ sprint-work.md validation failed!"
  echo ""

  if [[ ${#missing_sections[@]} -gt 0 ]]; then
    echo "Missing required sections:"
    for section in "${missing_sections[@]}"; do
      echo "  - \"${section}\" not found"
    done
    echo ""
  fi

  if [[ ${#missing_keywords[@]} -gt 0 ]]; then
    echo "Missing required keywords:"
    for keyword in "${missing_keywords[@]}"; do
      echo "  - Keyword \"${keyword}\" not found"
    done
    echo ""
  fi

  echo "Workers depend on these sections. Please restore them."
  echo "See issue #279 for context on required sections."
  exit 1
else
  if ${VERBOSE}; then
    echo ""
    echo "✓ sprint-work.md validation passed!"
    echo "  - ${#REQUIRED_SECTIONS[@]} required sections found"
    echo "  - ${#REQUIRED_KEYWORDS[@]} required keywords found"
  fi
  exit 0
fi
