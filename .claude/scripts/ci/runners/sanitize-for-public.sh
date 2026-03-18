#!/usr/bin/env bash
# ============================================================
# Script: sanitize-for-public.sh
# Purpose: Public repo sanitization for visibility-aware QA gates
#
# Scans for patterns that should not appear in public repositories:
#   - Absolute paths (/Users/username/, /home/username/)
#   - Internal references (hardcoded IPs, internal URLs, hostnames)
#   - License headers (internal-only licenses)
#   - Usernames and internal identifiers
#   - Internal comments and TODOs with sensitive context
#
# This is a VISIBILITY-AWARE gate - blocking for public repos, warning for private.
#
# Usage:
#   ./scripts/ci/sanitize-for-public.sh [OPTIONS]
#
# Options:
#   --repo-profile FILE  Path to repo-profile.yaml (default: config/repo/repo-profile.yaml)
#   --output FILE        Write findings JSON to FILE
#   --fix                Attempt to auto-fix safe findings (interactive)
#   --dry-run            Show what would be scanned
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  No sanitization issues (clean for public release)
#   1  Sanitization issues found (blocks promotion for public repos, warns for private)
#   2  Error (missing config, invalid options, etc.)
#
# Integration:
#   - Called by pre-promote-qa-gate.sh for QA promotion
#   - Gated on repo visibility from repo-profile.yaml
#   - Related: Issue #972 (QA gates), #934 (repo visibility)
#
# Related: Issue #972 (mandatory sanitization for QA promotion)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO_PROFILE="${REPO_PROFILE:-config/repo/repo-profile.yaml}"
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false
FIX_MODE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-profile) REPO_PROFILE="$2"; shift 2 ;;
    --output)       OUTPUT_FILE="$2"; shift 2 ;;
    --fix)          FIX_MODE=true; shift ;;
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

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v yq &>/dev/null; then
  echo -e "${RED}[ERROR]${NC} yq is required for YAML parsing" >&2
  echo "  Install: brew install yq (macOS) or snap install yq (Linux)" >&2
  exit 2
fi

if [[ ! -f "$REPO_ROOT/$REPO_PROFILE" ]]; then
  echo -e "${RED}[ERROR]${NC} Repo profile not found: $REPO_PROFILE" >&2
  echo "  Run /repo-init to create repo profile" >&2
  exit 2
fi

# ─── Load Visibility Type ─────────────────────────────────────────────────────

VISIBILITY=$(yq eval '.visibility.type' "$REPO_ROOT/$REPO_PROFILE" 2>/dev/null || echo "unknown")

if [[ "$VISIBILITY" == "unknown" ]]; then
  echo -e "${YELLOW}[WARN]${NC} Could not determine repository visibility" >&2
  echo "  Defaulting to private (non-blocking mode)" >&2
  VISIBILITY="private"
fi

# ─── Logging ──────────────────────────────────────────────────────────────────

log_info() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${GREEN}[INFO]${NC} $*"
  fi
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_finding() {
  local category="$1"
  local file="$2"
  local line="$3"
  local match="$4"

  echo "$category|$file|$line|$match" >> "$FINDINGS_FILE"
  FINDINGS=$((FINDINGS + 1))

  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${CYAN}[FINDING]${NC} $category in $file:$line"
    echo "  Match: $match"
  fi
}

# ─── Scan Functions ───────────────────────────────────────────────────────────

FINDINGS=0
FINDINGS_FILE=$(mktemp)

scan_absolute_paths() {
  log_info "Scanning for absolute paths..."

  local patterns=(
    '/Users/[a-zA-Z0-9_-]+/'
    '/home/[a-zA-Z0-9_-]+/'
    'C:\\Users\\[a-zA-Z0-9_-]+\\'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      # Skip if it's a template placeholder or variable
      if echo "$match" | grep -qE '(\{|\$|<|example|placeholder|your-user|YOUR_|{{)'; then
        continue
      fi

      # Skip config files and examples
      if [[ "$file" =~ \.(example|template|sample)$ ]]; then
        continue
      fi

      log_finding "ABSOLUTE_PATHS" "$file" "$line" "$match"
    done < <(git grep -nE "$pattern" 2>/dev/null | head -100 || true)
  done
}

scan_internal_references() {
  log_info "Scanning for internal references..."

  # Internal IPs (excluding common safe patterns)
  local patterns=(
    '192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
    '10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    '172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      # Skip example IPs and documentation
      if echo "$match" | grep -qE '(example|192\.168\.(0|1|255)|10\.0\.0\.|127\.0\.0\.)'; then
        continue
      fi

      # Skip if it's in a comment explaining IP ranges
      if git grep -B 1 "$match" "$file" 2>/dev/null | grep -qE '(example|for instance|e\.g\.|sample)'; then
        continue
      fi

      log_finding "INTERNAL_REFERENCES" "$file" "$line" "$match"
    done < <(git grep -nE "$pattern" 2>/dev/null | head -100 || true)
  done

  # Internal hostnames
  while IFS=: read -r file line match; do
    # Skip common safe patterns
    if echo "$match" | grep -qiE '(example\.com|localhost|127\.0\.0\.1|\{\{|placeholder)'; then
      continue
    fi

    log_finding "INTERNAL_HOSTNAMES" "$file" "$line" "$match"
  done < <(git grep -nE '\.internal\.[a-zA-Z0-9.-]+' 2>/dev/null | head -100 || true)
}

scan_username_references() {
  log_info "Scanning for username references..."

  # Look for common username patterns in paths or configs
  while IFS=: read -r file line match; do
    # Extract potential username
    local username=$(echo "$match" | sed -E 's|.*/([a-zA-Z0-9_-]+)/.*|\1|')

    # Skip common safe usernames and placeholders
    if echo "$username" | grep -qiE '^(root|admin|user|test|example|demo|placeholder|your|username|opt|var|tmp|usr|bin|etc)$'; then
      continue
    fi

    # Skip if length is too short (likely not a username)
    if [[ ${#username} -lt 3 ]]; then
      continue
    fi

    log_finding "USERNAME_REFERENCES" "$file" "$line" "$match"
  done < <(git grep -nE '/(Users|home)/[a-zA-Z0-9_-]+/' 2>/dev/null | head -100 || true)
}

scan_license_headers() {
  log_info "Scanning for license headers..."

  # Look for internal-only license markers
  local patterns=(
    'INTERNAL USE ONLY'
    'PROPRIETARY'
    'CONFIDENTIAL'
    'NOT FOR PUBLIC RELEASE'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      log_finding "LICENSE_HEADERS" "$file" "$line" "$match"
    done < <(git grep -nF "$pattern" 2>/dev/null | head -100 || true)
  done
}

scan_internal_comments() {
  log_info "Scanning for internal comments..."

  # Look for TODOs/FIXMEs with internal context
  local patterns=(
    'TODO.*@[a-zA-Z0-9_-]+\.(internal|corp)'
    'FIXME.*ticket.*JIRA'
    'XXX.*internal'
    'HACK.*production'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      log_finding "INTERNAL_COMMENTS" "$file" "$line" "$match"
    done < <(git grep -nE "$pattern" 2>/dev/null | head -100 || true)
  done
}

# ─── Build Report ─────────────────────────────────────────────────────────────

build_report() {
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Categorize findings
  local absolute_paths internal_refs usernames licenses comments
  absolute_paths=$(grep -c "^ABSOLUTE_PATHS|" "$FINDINGS_FILE" 2>/dev/null || echo "0")
  internal_refs=$(grep -c "^INTERNAL_REFERENCES\|^INTERNAL_HOSTNAMES|" "$FINDINGS_FILE" 2>/dev/null || echo "0")
  usernames=$(grep -c "^USERNAME_REFERENCES|" "$FINDINGS_FILE" 2>/dev/null || echo "0")
  licenses=$(grep -c "^LICENSE_HEADERS|" "$FINDINGS_FILE" 2>/dev/null || echo "0")
  comments=$(grep -c "^INTERNAL_COMMENTS|" "$FINDINGS_FILE" 2>/dev/null || echo "0")

  # Build findings array for JSON
  local findings_json="[]"
  if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    findings_json=$(awk -F'|' '{
      printf "{\"category\":\"%s\",\"file\":\"%s\",\"line\":\"%s\",\"match\":\"%s\"},\n", $1, $2, $3, $4
    }' "$FINDINGS_FILE" | sed '$ s/,$//' | sed 's/^/[/' | sed 's/$/]/' || echo "[]")
  fi

  jq -n \
    --arg timestamp "$timestamp" \
    --arg visibility "$VISIBILITY" \
    --argjson total "$FINDINGS" \
    --argjson absolute_paths "$absolute_paths" \
    --argjson internal_refs "$internal_refs" \
    --argjson usernames "$usernames" \
    --argjson licenses "$licenses" \
    --argjson comments "$comments" \
    --argjson findings "$findings_json" \
    '{
      timestamp: $timestamp,
      visibility: $visibility,
      summary: {
        total: $total,
        absolute_paths: $absolute_paths,
        internal_references: $internal_refs,
        username_references: $usernames,
        license_headers: $licenses,
        internal_comments: $comments
      },
      findings: $findings
    }'
}

# ─── Print Summary ────────────────────────────────────────────────────────────

print_summary() {
  local exit_code="$1"

  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        Public Repo Sanitization Report                     ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "Repository Visibility: ${YELLOW}${VISIBILITY}${NC}"
  echo -e "Total Findings: ${YELLOW}${FINDINGS}${NC}"
  echo ""

  if [[ -f "$FINDINGS_FILE" && -s "$FINDINGS_FILE" ]]; then
    echo "┌────────────────────────────────────────────────────────────┐"
    echo "│ Findings by Category                                       │"
    echo "├────────────────────────────────────────────────────────────┤"

    awk -F'|' '{print $1}' "$FINDINGS_FILE" | sort | uniq -c | while read -r count category; do
      printf "│  %-25s %30s │\n" "$category:" "$count"
    done

    echo "└────────────────────────────────────────────────────────────┘"
    echo ""

    echo "Sample findings:"
    awk -F'|' '{printf "  [%s] %s:%s\n", $1, $2, $3}' "$FINDINGS_FILE" | head -10

    if [[ "$FINDINGS" -gt 10 ]]; then
      echo "  ... and $((FINDINGS - 10)) more"
    fi
    echo ""
  fi

  if [[ "$exit_code" -eq 0 ]]; then
    echo -e "${GREEN}✓ Sanitization check PASSED${NC}"
    echo "  No sanitization issues found"
    echo "  Repository is ready for QA promotion"
  else
    if [[ "$VISIBILITY" == "public" ]]; then
      echo -e "${RED}✗ Sanitization check FAILED (BLOCKING)${NC}"
      echo "  Repository visibility: PUBLIC"
      echo "  $FINDINGS sanitization issue(s) must be resolved before QA promotion"
      echo ""
      echo "  Action required:"
      echo "    1. Review findings above"
      echo "    2. Remove or replace hardcoded paths, IPs, and internal references"
      echo "    3. Use placeholders or environment variables instead"
      echo "    4. Re-run this scan to verify"
    else
      echo -e "${YELLOW}⚠ Sanitization check WARNING (non-blocking)${NC}"
      echo "  Repository visibility: PRIVATE"
      echo "  $FINDINGS sanitization issue(s) found (warnings only for private repos)"
      echo ""
      echo "  Recommended actions:"
      echo "    1. Review findings for potential security issues"
      echo "    2. Consider fixing before eventual public release"
    fi
  fi

  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}Public Repo Sanitization Scan${NC}"
  echo -e "Repository: ${YELLOW}$(basename "$REPO_ROOT")${NC}"
  echo -e "Visibility: ${YELLOW}${VISIBILITY}${NC}"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would scan for sanitization issues:"
    echo "  - Absolute paths (/Users/*, /home/*)"
    echo "  - Internal references (private IPs, internal hostnames)"
    echo "  - Username references"
    echo "  - License headers (internal-only)"
    echo "  - Internal comments (TODOs with internal context)"
    echo ""
    echo "  Blocking: $([ "$VISIBILITY" = "public" ] && echo "YES" || echo "NO") (visibility: $VISIBILITY)"
    exit 0
  fi

  # Run all scans
  scan_absolute_paths
  scan_internal_references
  scan_username_references
  scan_license_headers
  scan_internal_comments

  # Build report
  local report
  report=$(build_report)

  # Save report if requested
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" | jq '.' > "$OUTPUT_FILE"
    log_info "Report saved to: $OUTPUT_FILE"
  fi

  # Determine exit code based on visibility
  local exit_code=0
  if [[ "$FINDINGS" -gt 0 ]]; then
    if [[ "$VISIBILITY" == "public" ]]; then
      exit_code=1  # Blocking for public repos
    else
      exit_code=0  # Warning only for private repos (non-blocking)
    fi
  fi

  # Print summary
  print_summary "$exit_code"

  exit "$exit_code"
}

trap 'rm -f "$FINDINGS_FILE"' EXIT

main "$@"
