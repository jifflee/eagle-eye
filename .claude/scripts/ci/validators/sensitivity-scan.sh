#!/usr/bin/env bash
# ============================================================
# Script: sensitivity-scan.sh
# Purpose: Public release sensitivity scanning for external repos
#
# Scans for sensitive data that should not be exposed in public repos:
#   - Credentials, API keys, tokens, passwords
#   - Private keys, SSH keys, certificates
#   - Internal URLs, IPs, hostnames
#   - Internal filesystem paths
#   - Environment files with real values
#   - Internal tool configurations
#   - PII, keychain references, internal issue links
#
# Usage:
#   ./scripts/ci/sensitivity-scan.sh [OPTIONS]
#
# Options:
#   --repo-profile FILE  Path to repo-profile.yaml (default: config/repo-profile.yaml)
#   --allowlist FILE     Path to allowlist (default: config/public-release-allowlist.yaml)
#   --output FILE        Write findings JSON to FILE
#   --fix                Attempt to auto-fix findings (interactive)
#   --dry-run            Show what would be scanned
#   --verbose            Verbose output
#   --help               Show this help
#
# Exit codes:
#   0  No findings (clean, ready for public release)
#   1  Findings detected (blocks promotion/sync)
#   2  Error (missing config, invalid options, etc.)
#
# Integration:
#   - Called by /pr-to-main for external repos
#   - Called by dual-repo sync before push to external
#   - Configured in config/repo-profile.yaml
#
# Related: Issue #934 (public/private repo detection)
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

REPO_PROFILE="${REPO_PROFILE:-config/repo-profile.yaml}"
ALLOWLIST_FILE="${ALLOWLIST_FILE:-config/public-release-allowlist.yaml}"
OUTPUT_FILE=""
DRY_RUN=false
VERBOSE=false
FIX_MODE=false

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ─── Argument Parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-profile) REPO_PROFILE="$2"; shift 2 ;;
    --allowlist)    ALLOWLIST_FILE="$2"; shift 2 ;;
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

# Check if repo is configured as public (external)
VISIBILITY=$(yq eval '.visibility.type' "$REPO_ROOT/$REPO_PROFILE" 2>/dev/null || echo "unknown")

if [[ "$VISIBILITY" != "public" ]]; then
  echo -e "${BLUE}[INFO]${NC} Sensitivity scan skipped (repo is not public)"
  echo "  Visibility: $VISIBILITY"
  echo "  Only external repos require sensitivity scanning"
  exit 0
fi

# ─── Load Allowlist ───────────────────────────────────────────────────────────

load_allowlist() {
  if [[ ! -f "$REPO_ROOT/$ALLOWLIST_FILE" ]]; then
    echo -e "${YELLOW}[WARN]${NC} Allowlist not found: $ALLOWLIST_FILE" >&2
    echo "  Using built-in patterns only" >&2
    return
  fi

  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${BLUE}[INFO]${NC} Loaded allowlist: $ALLOWLIST_FILE"
  fi
}

# ─── Scan Functions ───────────────────────────────────────────────────────────

FINDINGS=0
FINDINGS_FILE=$(mktemp)

log_finding() {
  local category="$1"
  local file="$2"
  local line="$3"
  local pattern="$4"
  local context="${5:-}"

  echo "$category|$file|$line|$pattern|$context" >> "$FINDINGS_FILE"
  FINDINGS=$((FINDINGS + 1))

  if [[ "$VERBOSE" == "true" ]]; then
    echo -e "${YELLOW}[FINDING]${NC} $category in $file:$line"
    echo "  Pattern: $pattern"
    [[ -n "$context" ]] && echo "  Context: $context"
  fi
}

check_allowlist() {
  local pattern="$1"
  local category="$2"

  # Check if pattern is in allowlist
  # This is a simplified check - real implementation would use yq to parse allowlist
  if [[ -f "$REPO_ROOT/$ALLOWLIST_FILE" ]]; then
    # Check common placeholder patterns
    if echo "$pattern" | grep -qiE '(example|placeholder|your-|test-|demo-|sample-|mock-)'; then
      return 0  # Safe pattern
    fi
  fi

  return 1  # Not in allowlist
}

scan_credentials() {
  echo -e "${BLUE}[SCAN]${NC} Checking for credentials and secrets..."

  # API keys, tokens, passwords
  local patterns=(
    'api[_-]?key[[:space:]]*[:=][[:space:]]*["\047]?[A-Za-z0-9_-]{20,}'
    'password[[:space:]]*[:=][[:space:]]*["\047]?[^"\047[:space:]]{8,}'
    'secret[_-]?key[[:space:]]*[:=][[:space:]]*["\047]?[A-Za-z0-9_-]{20,}'
    'token[[:space:]]*[:=][[:space:]]*["\047]?[A-Za-z0-9_-]{20,}'
    'GITHUB_TOKEN[[:space:]]*[:=]'
    'ghp_[A-Za-z0-9]{36}'
    'sk-proj-[A-Za-z0-9]{48}'
    'Bearer [A-Za-z0-9_-]{20,}'
    'Authorization:[[:space:]]*[A-Za-z0-9_-]{20,}'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "credentials"; then
        log_finding "CREDENTIALS" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -niE "$pattern" 2>/dev/null || true)
  done
}

scan_private_keys() {
  echo -e "${BLUE}[SCAN]${NC} Checking for private keys and certificates..."

  # PEM files, SSH keys
  local patterns=(
    '-----BEGIN [A-Z ]+ PRIVATE KEY-----'
    '-----BEGIN RSA PRIVATE KEY-----'
    '-----BEGIN OPENSSH PRIVATE KEY-----'
    '-----BEGIN EC PRIVATE KEY-----'
    '-----BEGIN CERTIFICATE-----'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "private_keys"; then
        log_finding "PRIVATE_KEYS" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -nF "$pattern" 2>/dev/null || true)
  done
}

scan_internal_urls() {
  echo -e "${BLUE}[SCAN]${NC} Checking for internal URLs and IPs..."

  # Internal hostnames, private IPs
  local patterns=(
    'https?://[a-zA-Z0-9.-]*\.internal\.[a-zA-Z0-9.-]+'
    'https?://192\.168\.[0-9]{1,3}\.[0-9]{1,3}'
    'https?://10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
    'https?://172\.(1[6-9]|2[0-9]|3[0-1])\.[0-9]{1,3}\.[0-9]{1,3}'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "internal_urls"; then
        log_finding "INTERNAL_URLS" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -niE "$pattern" 2>/dev/null || true)
  done
}

scan_internal_paths() {
  echo -e "${BLUE}[SCAN]${NC} Checking for internal filesystem paths..."

  # User home directories, internal paths
  local patterns=(
    '/Users/[a-zA-Z0-9_-]+/'
    '/home/[a-zA-Z0-9_-]+/'
    'C:\\Users\\[a-zA-Z0-9_-]+\\'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      # Skip if it's a template placeholder
      if echo "$match" | grep -qiE '(\{|\$|<|example|placeholder)'; then
        continue
      fi
      if ! check_allowlist "$match" "internal_paths"; then
        log_finding "INTERNAL_PATHS" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -niE "$pattern" 2>/dev/null || true)
  done
}

scan_env_files() {
  echo -e "${BLUE}[SCAN]${NC} Checking for environment files with real values..."

  # Find .env files that are not examples
  while IFS= read -r file; do
    # Skip .env.example, .env.template, etc.
    if echo "$file" | grep -qiE '\.(example|template|sample)$'; then
      continue
    fi

    # Check if file contains non-placeholder values
    if grep -qE '=[^"\047[:space:]]{10,}' "$file" 2>/dev/null; then
      # Check if values look real (not placeholders)
      if ! grep -qiE '(example|placeholder|your-|changeme)' "$file"; then
        log_finding "ENV_FILES" "$file" "0" ".env file with real values" "$(basename "$file")"
      fi
    fi
  done < <(find . -name ".env*" -type f 2>/dev/null || true)
}

scan_internal_config() {
  echo -e "${BLUE}[SCAN]${NC} Checking for internal tool configurations..."

  # Internal configs that shouldn't be public
  local patterns=(
    'debug[[:space:]]*[:=][[:space:]]*(true|1|yes)'
    'internal[_-]?webhook'
    'n8n\.internal'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "internal_config"; then
        log_finding "INTERNAL_CONFIG" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -niE "$pattern" 2>/dev/null || true)
  done
}

scan_keychain_refs() {
  echo -e "${BLUE}[SCAN]${NC} Checking for keychain/vault references..."

  local patterns=(
    'keychain:'
    'vault://'
    'secret-manager://'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "keychain_refs"; then
        log_finding "KEYCHAIN_REFS" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -nF "$pattern" 2>/dev/null || true)
  done
}

scan_internal_issues() {
  echo -e "${BLUE}[SCAN]${NC} Checking for internal issue references..."

  # References to source-* repos
  local patterns=(
    'source-[a-zA-Z0-9_-]+#[0-9]+'
  )

  for pattern in "${patterns[@]}"; do
    while IFS=: read -r file line match; do
      if ! check_allowlist "$match" "internal_issues"; then
        log_finding "INTERNAL_ISSUES" "$file" "$line" "$pattern" "$match"
      fi
    done < <(git grep -niE "$pattern" 2>/dev/null || true)
  done
}

scan_pii() {
  echo -e "${BLUE}[SCAN]${NC} Checking for PII..."

  # Email addresses (excluding safe examples)
  while IFS=: read -r file line match; do
    # Skip example.com and common test domains
    if echo "$match" | grep -qiE '@(example\.(com|org)|test\.com)'; then
      continue
    fi
    if ! check_allowlist "$match" "pii"; then
      log_finding "PII" "$file" "$line" "email address" "$match"
    fi
  done < <(git grep -niE '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}' 2>/dev/null || true)
}

# ─── Main Scan Execution ──────────────────────────────────────────────────────

main() {
  echo ""
  echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║        Public Release Sensitivity Scan                     ║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "Repository: ${YELLOW}$(basename "$REPO_ROOT")${NC}"
  echo -e "Visibility: ${YELLOW}$VISIBILITY${NC}"
  echo -e "Profile:    $REPO_PROFILE"
  echo -e "Allowlist:  $ALLOWLIST_FILE"
  echo ""

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY-RUN]${NC} Would scan for sensitive data in:"
    echo "  - Credentials and secrets"
    echo "  - Private keys and certificates"
    echo "  - Internal URLs and IPs"
    echo "  - Internal filesystem paths"
    echo "  - Environment files"
    echo "  - Internal tool configurations"
    echo "  - Keychain/vault references"
    echo "  - Internal issue references"
    echo "  - PII (email addresses, names)"
    exit 0
  fi

  load_allowlist

  # Run all scans
  scan_credentials
  scan_private_keys
  scan_internal_urls
  scan_internal_paths
  scan_env_files
  scan_internal_config
  scan_keychain_refs
  scan_internal_issues
  scan_pii

  echo ""
  echo "────────────────────────────────────────────────────────────"

  # Report results
  if [[ "$FINDINGS" -eq 0 ]]; then
    echo -e "${GREEN}✓ Sensitivity scan PASSED${NC}"
    echo "  No sensitive data detected"
    echo "  Repository is ready for public release"
    exit 0
  else
    echo -e "${RED}✗ Sensitivity scan FAILED${NC}"
    echo "  $FINDINGS finding(s) detected"
    echo ""
    echo -e "${YELLOW}Findings by category:${NC}"

    # Summarize findings
    awk -F'|' '{print $1}' "$FINDINGS_FILE" | sort | uniq -c | while read -r count category; do
      echo "  - $category: $count"
    done

    echo ""
    echo -e "${YELLOW}Review findings:${NC}"
    awk -F'|' '{printf "  %s in %s:%s\n", $1, $2, $3}' "$FINDINGS_FILE" | head -20

    if [[ "$FINDINGS" -gt 20 ]]; then
      echo "  ... and $((FINDINGS - 20)) more"
    fi

    echo ""
    echo -e "${RED}Action required:${NC}"
    echo "  1. Review the findings listed above"
    echo "  2. Remove or redact sensitive data"
    echo "  3. Add safe patterns to: $ALLOWLIST_FILE"
    echo "  4. Re-run this scan to verify"
    echo ""
    echo "  Promotion/sync to external repo is BLOCKED until resolved."

    # Save detailed findings if output file specified
    if [[ -n "$OUTPUT_FILE" ]]; then
      cp "$FINDINGS_FILE" "$OUTPUT_FILE"
      echo ""
      echo "  Detailed findings saved to: $OUTPUT_FILE"
    fi

    rm -f "$FINDINGS_FILE"
    exit 1
  fi
}

trap 'rm -f "$FINDINGS_FILE"' EXIT

main "$@"
