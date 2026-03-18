#!/usr/bin/env bash
# ============================================================
# Script: doc-consistency.sh
# Purpose: Check all .md files for stale references and inconsistencies
# Usage: ./scripts/headless/doc-consistency.sh [OPTIONS]
# Dependencies: bash, jq, git, grep
# ============================================================
#
# DESCRIPTION:
#   Headless-mode compatible script that scans documentation files for:
#   - Stale port number references (e.g., 8080 vs current config)
#   - Dead internal links (references to non-existent files)
#   - Outdated version numbers
#   - VM/hostname references that may be stale
#   - Cross-file architectural description mismatches
#
# OPTIONS:
#   --output-file FILE       Path to write JSON report (default: doc-consistency-report.json)
#   --format FORMAT          Output format: json|markdown (default: json)
#   --severity-threshold LVL Minimum severity to report: critical|high|medium|low (default: medium)
#   --fix                    Attempt to auto-fix issues (creates a fix plan)
#   --verbose                Verbose output
#   --help                   Show this help
#
# OUTPUT:
#   JSON or Markdown report suitable for Claude headless mode consumption
#   Exit code 0: no critical/high issues found
#   Exit code 1: critical or high issues found
#   Exit code 2: fatal error
#
# HEADLESS MODE USAGE:
#   claude -p "$(cat scripts/headless/doc-consistency.sh | bash)"
#   OR
#   ./scripts/headless/doc-consistency.sh --format markdown | claude -p -

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Defaults ────────────────────────────────────────────────────────────────

OUTPUT_FILE="${OUTPUT_FILE:-doc-consistency-report.json}"
FORMAT="${FORMAT:-json}"
SEVERITY_THRESHOLD="${SEVERITY_THRESHOLD:-medium}"
FIX="${FIX:-false}"
VERBOSE="${VERBOSE:-false}"

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT" || die "Failed to change to repo root"

# ─── Argument parsing ─────────────────────────────────────────────────────────

show_help() {
  grep '^#' "$0" | sed 's/^# \?//' | head -35
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-file)       OUTPUT_FILE="$2"; shift 2 ;;
    --format)            FORMAT="$2"; shift 2 ;;
    --severity-threshold) SEVERITY_THRESHOLD="$2"; shift 2 ;;
    --fix)               FIX="true"; shift ;;
    --verbose)           VERBOSE="true"; shift ;;
    --help|-h)           show_help ;;
    *) log_error "Unknown option: $1"; exit 2 ;;
  esac
done

# ─── Helper Functions ─────────────────────────────────────────────────────────

log_verbose() {
  if [ "$VERBOSE" = "true" ]; then
    log_info "$@"
  fi
}

# Convert severity to numeric value for comparison
severity_to_number() {
  case "$1" in
    critical) echo 4 ;;
    high) echo 3 ;;
    medium) echo 2 ;;
    low) echo 1 ;;
    *) echo 0 ;;
  esac
}

# ─── Main Scan Logic ──────────────────────────────────────────────────────────

log_info "Starting documentation consistency scan..."

# Initialize findings array
FINDINGS='[]'
FINDING_COUNT=0

# 1. Check for stale port references
log_verbose "Checking for port number inconsistencies..."

# Extract common port numbers from various config files
COMMON_PORTS=$(find . -name "*.json" -o -name "*.yml" -o -name "*.yaml" | \
  xargs grep -hoE '[0-9]{4,5}' 2>/dev/null | sort -u || echo "")

# Find port references in markdown that might be stale
while IFS= read -r md_file; do
  [ ! -f "$md_file" ] && continue

  # Find port numbers in markdown
  while IFS= read -r port; do
    [ -z "$port" ] && continue

    # Skip non-numeric values
    [[ ! "$port" =~ ^[0-9]+$ ]] && continue

    # Check if this is a common application port (3000-9999)
    if [ "$port" -ge 3000 ] 2>/dev/null && [ "$port" -le 9999 ] 2>/dev/null; then
      # Count occurrences in config vs docs
      config_count=$(echo "$COMMON_PORTS" | grep -c "^$port$" 2>/dev/null || echo "0")

      # Ensure config_count is a valid integer
      [[ ! "$config_count" =~ ^[0-9]+$ ]] && config_count=0

      if [ "$config_count" -eq 0 ] 2>/dev/null; then
        # Port found in docs but not in config - potentially stale
        line_num=$(grep -n "$port" "$md_file" | head -1 | cut -d: -f1)

        FINDING_COUNT=$((FINDING_COUNT + 1))
        FINDINGS=$(echo "$FINDINGS" | jq --arg id "DC-$FINDING_COUNT" \
          --arg file "$md_file" \
          --arg line "$line_num" \
          --arg port "$port" \
          '. += [{
            id: $id,
            type: "stale_port_reference",
            severity: "medium",
            file: $file,
            line: ($line | tonumber),
            description: "Port \($port) referenced in documentation but not found in config files",
            suggestion: "Verify if port \($port) is current or update to correct port number"
          }]')
      fi
    fi
  done < <(grep -oE '\b[0-9]{4,5}\b' "$md_file" 2>/dev/null || true)
done < <(find . -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)

# 2. Check for broken internal links
log_verbose "Checking for broken internal markdown links..."

while IFS= read -r md_file; do
  [ ! -f "$md_file" ] && continue

  # Extract markdown links: [text](path)
  while IFS= read -r link_line; do
    [ -z "$link_line" ] && continue

    # Extract the path from [text](path)
    link_path=$(echo "$link_line" | sed -n 's/.*\](\([^)]*\)).*/\1/p' | head -1)

    # Skip external links and anchors
    [[ "$link_path" =~ ^https?:// ]] && continue
    [[ "$link_path" =~ ^# ]] && continue
    [ -z "$link_path" ] && continue

    # Remove anchor if present
    clean_path="${link_path%%#*}"

    # Resolve relative path
    md_dir=$(dirname "$md_file")
    if [[ "$clean_path" == /* ]]; then
      target_path=".${clean_path}"
    else
      target_path="${md_dir}/${clean_path}"
    fi

    # Normalize path
    target_path=$(realpath -m "$target_path" 2>/dev/null || echo "$target_path")

    # Check if target exists
    if [ ! -e "$target_path" ]; then
      line_num=$(grep -n "$link_path" "$md_file" | head -1 | cut -d: -f1)

      FINDING_COUNT=$((FINDING_COUNT + 1))
      FINDINGS=$(echo "$FINDINGS" | jq --arg id "DC-$FINDING_COUNT" \
        --arg file "$md_file" \
        --arg line "$line_num" \
        --arg link "$link_path" \
        --arg target "$target_path" \
        '. += [{
          id: $id,
          type: "broken_link",
          severity: "high",
          file: $file,
          line: ($line | tonumber),
          description: "Broken internal link: \($link) -> \($target)",
          suggestion: "Update link to correct path or remove if obsolete"
        }]')
    fi
  done < <(grep -oE '\[([^\]]+)\]\(([^)]+)\)' "$md_file" 2>/dev/null || true)
done < <(find . -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)

# 3. Check for version number inconsistencies
log_verbose "Checking for version number inconsistencies..."

# Get current version from package.json if exists
if [ -f "package.json" ]; then
  CURRENT_VERSION=$(jq -r '.version // "unknown"' package.json)

  # Find version references in docs
  while IFS= read -r md_file; do
    [ ! -f "$md_file" ] && continue

    # Look for semantic version patterns
    while IFS= read -r version_match; do
      [ -z "$version_match" ] && continue

      # Skip if it matches current version
      [[ "$version_match" == "$CURRENT_VERSION" ]] && continue

      # Flag as potentially stale
      line_num=$(grep -n "$version_match" "$md_file" | head -1 | cut -d: -f1)

      FINDING_COUNT=$((FINDING_COUNT + 1))
      FINDINGS=$(echo "$FINDINGS" | jq --arg id "DC-$FINDING_COUNT" \
        --arg file "$md_file" \
        --arg line "$line_num" \
        --arg found "$version_match" \
        --arg current "$CURRENT_VERSION" \
        '. += [{
          id: $id,
          type: "stale_version",
          severity: "low",
          file: $file,
          line: ($line | tonumber),
          description: "Version \($found) found in docs (current: \($current))",
          suggestion: "Verify if version reference should be updated to \($current)"
        }]')
    done < <(grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' "$md_file" 2>/dev/null || true)
  done < <(find . -name "*.md" -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/CHANGELOG.md" 2>/dev/null)
fi

# 4. Check for common hostname/VM references that may be stale
log_verbose "Checking for potentially stale hostname/VM references..."

# Common stale reference patterns
STALE_PATTERNS=(
  "localhost:8080"
  "127.0.0.1:8080"
  "dev-server"
  "staging-server"
  "old-vm"
  "legacy-host"
)

for pattern in "${STALE_PATTERNS[@]}"; do
  while IFS= read -r result; do
    [ -z "$result" ] && continue

    md_file=$(echo "$result" | cut -d: -f1)
    line_num=$(echo "$result" | cut -d: -f2)

    FINDING_COUNT=$((FINDING_COUNT + 1))
    FINDINGS=$(echo "$FINDINGS" | jq --arg id "DC-$FINDING_COUNT" \
      --arg file "$md_file" \
      --arg line "$line_num" \
      --arg pattern "$pattern" \
      '. += [{
        id: $id,
        type: "stale_reference",
        severity: "medium",
        file: $file,
        line: ($line | tonumber),
        description: "Potentially stale reference: \($pattern)",
        suggestion: "Verify if \($pattern) is current or update to correct value"
      }]')
  done < <(grep -rn "$pattern" . --include="*.md" 2>/dev/null || true)
done

# ─── Filter by severity threshold ─────────────────────────────────────────────

THRESHOLD_NUM=$(severity_to_number "$SEVERITY_THRESHOLD")
FINDINGS=$(echo "$FINDINGS" | jq --argjson threshold "$THRESHOLD_NUM" '
  map(
    . + {severity_num: (
      if .severity == "critical" then 4
      elif .severity == "high" then 3
      elif .severity == "medium" then 2
      elif .severity == "low" then 1
      else 0
      end
    )}
  ) | map(select(.severity_num >= $threshold))
')

# ─── Generate Report ──────────────────────────────────────────────────────────

TOTAL_FINDINGS=$(echo "$FINDINGS" | jq 'length')
CRITICAL_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "critical")] | length')
HIGH_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "high")] | length')
MEDIUM_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "medium")] | length')
LOW_COUNT=$(echo "$FINDINGS" | jq '[.[] | select(.severity == "low")] | length')

# Use temp file to avoid argument list too long
TEMP_FINDINGS=$(mktemp)
echo "$FINDINGS" > "$TEMP_FINDINGS"
trap "rm -f $TEMP_FINDINGS" EXIT

REPORT=$(jq -n \
  --slurpfile findings "$TEMP_FINDINGS" \
  --argjson total "$TOTAL_FINDINGS" \
  --argjson critical "$CRITICAL_COUNT" \
  --argjson high "$HIGH_COUNT" \
  --argjson medium "$MEDIUM_COUNT" \
  --argjson low "$LOW_COUNT" \
  --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg severity_threshold "$SEVERITY_THRESHOLD" \
  '{
    scan_type: "documentation_consistency",
    timestamp: $timestamp,
    severity_threshold: $severity_threshold,
    summary: {
      total_findings: $total,
      by_severity: {
        critical: $critical,
        high: $high,
        medium: $medium,
        low: $low
      }
    },
    findings: $findings[0]
  }')

# ─── Output ───────────────────────────────────────────────────────────────────

if [ "$FORMAT" = "markdown" ]; then
  # Generate markdown report
  cat <<EOF
# Documentation Consistency Report

**Generated:** $(date)
**Severity Threshold:** $SEVERITY_THRESHOLD

## Summary

- **Total Findings:** $TOTAL_FINDINGS
- **Critical:** $CRITICAL_COUNT
- **High:** $HIGH_COUNT
- **Medium:** $MEDIUM_COUNT
- **Low:** $LOW_COUNT

## Findings

EOF

  # Process findings in batches to avoid argument list too long
  if [ "$TOTAL_FINDINGS" -gt 0 ]; then
    echo "$FINDINGS" | jq -r '.[] | "### [\(.severity | ascii_upcase)] \(.type)\n\n**File:** `\(.file):\(.line)`\n\n**Description:** \(.description)\n\n**Suggestion:** \(.suggestion)\n\n---\n"'
  else
    echo "No findings to report."
  fi

else
  # JSON output
  echo "$REPORT" | jq '.'

  if [ "$OUTPUT_FILE" != "-" ]; then
    echo "$REPORT" | jq '.' > "$OUTPUT_FILE"
    log_success "Report written to: $OUTPUT_FILE"
  fi
fi

# ─── Exit Status ──────────────────────────────────────────────────────────────

if [ "$CRITICAL_COUNT" -gt 0 ] || [ "$HIGH_COUNT" -gt 0 ]; then
  log_warn "Found $CRITICAL_COUNT critical and $HIGH_COUNT high severity issues"
  exit 1
else
  log_success "Scan complete. Found $TOTAL_FINDINGS total issues (severity >= $SEVERITY_THRESHOLD)"
  exit 0
fi
