#!/usr/bin/env bash
set -euo pipefail
#
# Pre-commit security hook: scans staged files for hardcoded secrets
# Blocks commits containing passwords, API keys, tokens, or private keys.
#
# Usage: Called by pre-commit hook or directly:
#   ./scripts/hooks/pre-commit-security.sh
#
# Bypass: git commit --no-verify
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

VIOLATIONS=0
VIOLATION_DETAILS=""

# Get list of staged files (only added, copied, modified - skip deleted)
STAGED_FILES=$(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)

if [ -z "$STAGED_FILES" ]; then
  exit 0
fi

# Filter to text files only (skip binaries, images, etc.)
TEXT_FILES=""
while IFS= read -r file; do
  # Skip binary/non-text extensions
  case "$file" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.svg|*.woff|*.woff2|*.ttf|*.eot|*.pdf|*.zip|*.tar|*.gz|*.bz2|*.lock)
      continue
      ;;
  esac
  # Skip if file doesn't exist (edge case)
  if [ -f "$file" ]; then
    TEXT_FILES="$TEXT_FILES
$file"
  fi
done <<< "$STAGED_FILES"

TEXT_FILES=$(echo "$TEXT_FILES" | sed '/^$/d')

if [ -z "$TEXT_FILES" ]; then
  exit 0
fi

# Function to record a violation
record_violation() {
  local file="$1"
  local line_num="$2"
  local pattern_desc="$3"
  local line_content="$4"

  ((VIOLATIONS++)) || true
  VIOLATION_DETAILS="${VIOLATION_DETAILS}  ${RED}${BOLD}${file}:${line_num}${NC} - ${pattern_desc}\n"
  # Show truncated line content (max 80 chars)
  local truncated="${line_content:0:80}"
  if [ ${#line_content} -gt 80 ]; then
    truncated="${truncated}..."
  fi
  VIOLATION_DETAILS="${VIOLATION_DETAILS}    ${YELLOW}>${NC} ${truncated}\n\n"
}

# Function to check if a value is a placeholder/safe pattern
is_safe_value() {
  local value="$1"

  # Placeholder patterns
  [[ "$value" =~ ^your- ]] && return 0
  [[ "$value" =~ -here$ ]] && return 0
  [[ "$value" =~ ^xxx ]] && return 0
  [[ "$value" =~ ^placeholder ]] && return 0
  [[ "$value" =~ ^changeme ]] && return 0
  [[ "$value" =~ ^CHANGEME ]] && return 0
  [[ "$value" =~ ^\<.*\>$ ]] && return 0
  [[ "$value" =~ ^\{.*\}$ ]] && return 0
  [[ "$value" =~ ^TODO ]] && return 0

  # Environment variable references
  [[ "$value" =~ ^\$ ]] && return 0
  [[ "$value" =~ ^\$\{ ]] && return 0
  [[ "$value" =~ ^process\.env\. ]] && return 0
  [[ "$value" =~ ^os\.environ ]] && return 0

  # Test fixtures with obvious fake values
  [[ "$value" =~ ^test- ]] && return 0
  [[ "$value" =~ ^fake- ]] && return 0
  [[ "$value" =~ ^mock- ]] && return 0
  [[ "$value" =~ ^dummy- ]] && return 0
  [[ "$value" =~ ^example- ]] && return 0

  # Empty or very short values (likely not real secrets)
  [ ${#value} -lt 4 ] && return 0

  return 1
}

# Extract quoted value from a line matching key=value or key: value pattern
# Extracts the value between the first pair of quotes after = or :
extract_value() {
  local line="$1"
  # Remove everything up to and including the = or : and optional whitespace
  local after_eq="${line#*[=:]}"
  # Trim leading whitespace
  after_eq="${after_eq#"${after_eq%%[![:space:]]*}"}"
  # Extract value between quotes (double or single)
  if [[ "$after_eq" =~ ^\"([^\"]+)\" ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$after_eq" =~ ^\'([^\']+)\' ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Scan each staged file using grep for speed, then validate matches
while IFS= read -r file; do
  # Use grep -in to find candidate lines (fast pre-filter)
  # Patterns: password, api_key, api-key, secret, token, AWS keys, private key
  candidates=$(git show ":$file" 2>/dev/null | grep -inE '(password|passwd|pwd|api[_-]?key|apikey|secret|auth[_-]?token|access[_-]?token|bearer[_-]?token|jwt[_-]?token|AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|BEGIN.*PRIVATE KEY)' 2>/dev/null || true)

  if [ -z "$candidates" ]; then
    continue
  fi

  # Process only matching lines
  while IFS= read -r candidate; do
    # Extract line number and content from grep -n output (format: "NUM:content")
    line_num="${candidate%%:*}"
    line="${candidate#*:}"

    # Skip comments
    stripped="${line#"${line%%[![:space:]]*}"}"
    case "$stripped" in
      \#*|//*|\**)
        continue
        ;;
    esac

    # Lowercase for case-insensitive matching (only on candidate lines - fast)
    line_lower=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')

    # Pattern 1: password = "value"
    if [[ "$line_lower" =~ (password|passwd|pwd)[[:space:]]*[=:] ]] && [[ "$line" =~ [=:][[:space:]]*[\"\'] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && ! is_safe_value "$value"; then
        record_violation "$file" "$line_num" "Hardcoded password" "$line"
      fi
    fi

    # Pattern 2: api_key or api-key = "value"
    if [[ "$line_lower" =~ (api[_-]key|apikey)[[:space:]]*[=:] ]] && [[ "$line" =~ [=:][[:space:]]*[\"\'] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && ! is_safe_value "$value"; then
        record_violation "$file" "$line_num" "Hardcoded API key" "$line"
      fi
    fi

    # Pattern 3: secret = "value"
    if [[ "$line_lower" =~ (secret|secret[_-]key)[[:space:]]*[=:] ]] && [[ "$line" =~ [=:][[:space:]]*[\"\'] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && ! is_safe_value "$value"; then
        record_violation "$file" "$line_num" "Hardcoded secret" "$line"
      fi
    fi

    # Pattern 4: auth/access/bearer/jwt token = "value"
    if [[ "$line_lower" =~ (auth[_-]?token|access[_-]?token|bearer[_-]?token|jwt[_-]?token)[[:space:]]*[=:] ]] && [[ "$line" =~ [=:][[:space:]]*[\"\'] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && ! is_safe_value "$value"; then
        record_violation "$file" "$line_num" "Hardcoded token" "$line"
      fi
    fi

    # Pattern 5: AWS_ACCESS_KEY_ID with value
    if [[ "$line" =~ AWS_ACCESS_KEY_ID[[:space:]]*[=:] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && [[ "$value" =~ ^[A-Z0-9]{16,}$ ]]; then
        record_violation "$file" "$line_num" "AWS Access Key ID" "$line"
      fi
    fi

    # Pattern 6: AWS_SECRET_ACCESS_KEY with value
    if [[ "$line" =~ AWS_SECRET_ACCESS_KEY[[:space:]]*[=:] ]]; then
      value=$(extract_value "$line")
      if [ -n "$value" ] && [ ${#value} -ge 30 ]; then
        record_violation "$file" "$line_num" "AWS Secret Access Key" "$line"
      fi
    fi

    # Pattern 7: Private key headers
    if [[ "$line" =~ -----BEGIN\ (RSA\ |EC\ |DSA\ |OPENSSH\ )?PRIVATE\ KEY----- ]]; then
      record_violation "$file" "$line_num" "Private key file" "$line"
    fi

  done <<< "$candidates"
done <<< "$TEXT_FILES"

# Report results
if [ "$VIOLATIONS" -gt 0 ]; then
  echo ""
  echo -e "${RED}${BOLD}Security Check Failed${NC}"
  echo -e "${RED}Found $VIOLATIONS potential secret(s) in staged files:${NC}"
  echo ""
  echo -e "$VIOLATION_DETAILS"
  echo -e "${YELLOW}How to fix:${NC}"
  echo "  1. Move secrets to environment variables"
  echo "  2. Use placeholder values (e.g., your-api-key-here)"
  echo "  3. Reference .env files (ensure .env is in .gitignore)"
  echo ""
  echo -e "${YELLOW}To bypass (not recommended):${NC} git commit --no-verify"
  exit 1
fi

echo -e "${GREEN}Security check passed${NC} - no secrets detected in staged files."
exit 0
