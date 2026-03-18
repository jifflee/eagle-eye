#!/usr/bin/env bash
# ============================================================
# Script: dep-license-check.sh
# Purpose: Dependency license compliance checking for npm and Python packages
#
# Validates that all dependencies use approved licenses and flags
# packages with incompatible or risky licenses for review.
#
# Usage:
#   ./scripts/ci/validators/dep-license-check.sh [OPTIONS]
#
# Options:
#   --output-dir DIR    Output directory for reports (default: .dep-audit/)
#   --format FORMAT     Output format: json|table|summary (default: summary)
#   --strict            Strict mode: fail on any flagged license (default: warn only)
#   --policy FILE       Custom license policy file (default: config/license-policy.json)
#   --generate-sbom     Generate SBOM before checking (default: use existing)
#   --verbose           Show detailed output
#   --quiet             Suppress non-essential output
#   --help              Show this help
#
# Exit codes:
#   0 - All licenses approved
#   1 - Blocked licenses found (or flagged licenses in strict mode)
#   2 - Tool error (missing SBOM, invalid configuration)
#
# Output:
#   - JSON report written to .dep-audit/license-check.json
#   - Summary printed to stdout
#   - Flagged packages listed with remediation steps
#
# Integration:
#   - PR validation: ./scripts/ci/validators/dep-license-check.sh (warn only)
#   - Pre-QA gate: ./scripts/ci/validators/dep-license-check.sh (blocking for blocked licenses)
#   - Pre-main gate: ./scripts/ci/validators/dep-license-check.sh --strict (blocking)
#
# Related:
#   - config/license-policy.json - License allow/block/flag lists
#   - scripts/ci/validators/generate-sbom.sh - SBOM generation
#   - scripts/ci/validators/dep-audit.sh - Dependency vulnerability scanning
#   - Issue #1044 - Integrate license-check.sh into CI gates
#   - Epic #1030 - CI/CD infrastructure improvements
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# ─── Defaults ─────────────────────────────────────────────────────────────────

OUTPUT_DIR="$REPO_ROOT/.dep-audit"
OUTPUT_FORMAT="summary"
STRICT_MODE=false
POLICY_FILE="$REPO_ROOT/config/license-policy.json"
GENERATE_SBOM=false
VERBOSE=false
QUIET=false

# SBOM paths
SBOM_DIR="$REPO_ROOT/.sbom"
SBOM_SPDX="$SBOM_DIR/sbom.spdx.json"
SBOM_CYCLONEDX="$SBOM_DIR/sbom.cyclonedx.json"

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
  grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -50
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-dir)     OUTPUT_DIR="$2"; shift 2 ;;
    --format)         OUTPUT_FORMAT="$2"; shift 2 ;;
    --strict)         STRICT_MODE=true; shift ;;
    --policy)         POLICY_FILE="$2"; shift 2 ;;
    --generate-sbom)  GENERATE_SBOM=true; shift ;;
    --verbose)        VERBOSE=true; shift ;;
    --quiet)          QUIET=true; shift ;;
    --help|-h)        show_help ;;
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

log_success() {
  if [[ "$QUIET" != "true" ]]; then
    echo -e "${GREEN}[✓]${NC} $*"
  fi
}

log_fail() {
  echo -e "${RED}[✗]${NC} $*" >&2
}

# ─── Validation ───────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
  log_error "jq is required but not installed"
  exit 2
fi

# ─── Policy Loading ───────────────────────────────────────────────────────────

create_default_policy() {
  local policy_dir
  policy_dir=$(dirname "$POLICY_FILE")
  mkdir -p "$policy_dir"

  log_info "Creating default license policy: $POLICY_FILE"

  cat > "$POLICY_FILE" <<'EOF'
{
  "version": "1.0",
  "description": "Default license policy for dependency compliance",
  "allowed": [
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "CC0-1.0",
    "0BSD",
    "Unlicense",
    "Python-2.0",
    "PSF-2.0"
  ],
  "flagged_for_review": [
    "GPL-2.0",
    "GPL-3.0",
    "LGPL-2.1",
    "LGPL-3.0",
    "AGPL-3.0",
    "MPL-2.0",
    "EPL-1.0",
    "EPL-2.0",
    "CDDL-1.0",
    "CPL-1.0"
  ],
  "blocked": [
    "SSPL-1.0",
    "Commons Clause",
    "BUSL-1.1"
  ],
  "dual_licensed_acceptable": true,
  "unknown_license_action": "flag"
}
EOF
}

load_policy() {
  if [[ ! -f "$POLICY_FILE" ]]; then
    log_warn "License policy file not found, creating default: $POLICY_FILE"
    create_default_policy
  fi

  log_verbose "Loading license policy from: $POLICY_FILE"

  if ! jq empty "$POLICY_FILE" 2>/dev/null; then
    log_error "Invalid JSON in license policy file: $POLICY_FILE"
    exit 2
  fi
}

# ─── SBOM Generation ──────────────────────────────────────────────────────────

generate_sbom_if_needed() {
  if [[ "$GENERATE_SBOM" == "true" ]] || [[ ! -f "$SBOM_SPDX" && ! -f "$SBOM_CYCLONEDX" ]]; then
    log_step "Generating SBOM..."
    local sbom_generator="$SCRIPT_DIR/generate-sbom.sh"

    if [[ -f "$sbom_generator" && -x "$sbom_generator" ]]; then
      if "$sbom_generator" --output-dir "$SBOM_DIR" --quiet; then
        log_verbose "SBOM generation successful"
      else
        log_error "SBOM generation failed"
        exit 2
      fi
    else
      log_error "SBOM generator not found: $sbom_generator"
      log_error "Run: ./scripts/ci/validators/generate-sbom.sh --install-tools"
      exit 2
    fi
  fi
}

# ─── License Extraction ───────────────────────────────────────────────────────

extract_licenses_from_spdx() {
  local sbom_file="$1"
  log_verbose "Extracting licenses from SPDX SBOM: $sbom_file"

  # Extract packages with name, version, and license
  jq -r '.packages[] |
    select(.name != null and .name != "") |
    {
      name: .name,
      version: (.versionInfo // "unknown"),
      license: (.licenseDeclared // .licenseConcluded // "UNKNOWN"),
      ecosystem: (if .name | startswith("@") or .name | contains("/") then "npm"
                  elif .name | test("^[a-z0-9_-]+$") then "python"
                  else "unknown" end)
    } |
    @json' "$sbom_file"
}

extract_licenses_from_cyclonedx() {
  local sbom_file="$1"
  log_verbose "Extracting licenses from CycloneDX SBOM: $sbom_file"

  # Extract components with name, version, and license
  jq -r '.components[]? |
    select(.name != null) |
    {
      name: .name,
      version: (.version // "unknown"),
      license: (
        if .licenses then
          (.licenses | map(
            if .license.id then .license.id
            elif .license.name then .license.name
            elif .expression then .expression
            else "UNKNOWN"
            end
          ) | join(" OR "))
        else "UNKNOWN"
        end
      ),
      ecosystem: (.purl // "" | if startswith("pkg:npm") then "npm"
                                elif startswith("pkg:pypi") then "python"
                                else "unknown" end)
    } |
    @json' "$sbom_file"
}

extract_all_licenses() {
  local output_file="$1"
  local temp_file
  temp_file=$(mktemp)

  if [[ -f "$SBOM_SPDX" ]]; then
    log_step "Extracting licenses from SPDX SBOM..."
    extract_licenses_from_spdx "$SBOM_SPDX" >> "$temp_file"
  elif [[ -f "$SBOM_CYCLONEDX" ]]; then
    log_step "Extracting licenses from CycloneDX SBOM..."
    extract_licenses_from_cyclonedx "$SBOM_CYCLONEDX" >> "$temp_file"
  else
    log_error "No SBOM found. Generate one with: ./scripts/ci/validators/generate-sbom.sh"
    rm -f "$temp_file"
    exit 2
  fi

  # Convert to JSON array and deduplicate by name+version
  jq -s 'unique_by(.name + "@" + .version)' "$temp_file" > "$output_file"
  rm -f "$temp_file"

  local count
  count=$(jq 'length' "$output_file")
  log_verbose "Extracted $count unique dependencies"
}

# ─── License Classification ───────────────────────────────────────────────────

classify_license() {
  local license="$1"
  local policy_file="$2"

  # Normalize license (remove version suffixes like -only, -or-later)
  local normalized_license
  normalized_license=$(echo "$license" | sed 's/-only$//' | sed 's/-or-later$//')

  # Check if license is in allowed list
  if jq -e --arg lic "$license" '.allowed | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "allowed"
    return
  fi

  # Check normalized version
  if jq -e --arg lic "$normalized_license" '.allowed | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "allowed"
    return
  fi

  # Check if license is blocked
  if jq -e --arg lic "$license" '.blocked | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "blocked"
    return
  fi

  if jq -e --arg lic "$normalized_license" '.blocked | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "blocked"
    return
  fi

  # Check if flagged for review
  if jq -e --arg lic "$license" '.flagged_for_review | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "flagged"
    return
  fi

  if jq -e --arg lic "$normalized_license" '.flagged_for_review | index($lic)' "$policy_file" >/dev/null 2>&1; then
    echo "flagged"
    return
  fi

  # Handle dual-licensed packages (contains OR)
  if [[ "$license" == *" OR "* ]]; then
    local dual_acceptable
    dual_acceptable=$(jq -r '.dual_licensed_acceptable // true' "$policy_file")

    # Check if any of the licenses in OR clause is allowed
    local has_allowed=false
    while IFS= read -r lic; do
      local lic_trimmed
      lic_trimmed=$(echo "$lic" | xargs)
      if jq -e --arg l "$lic_trimmed" '.allowed | index($l)' "$policy_file" >/dev/null 2>&1; then
        has_allowed=true
        break
      fi
    done < <(echo "$license" | tr ' OR ' '\n')

    if [[ "$has_allowed" == "true" && "$dual_acceptable" == "true" ]]; then
      echo "allowed"
      return
    fi
  fi

  # Unknown license
  local unknown_action
  unknown_action=$(jq -r '.unknown_license_action // "flag"' "$policy_file")

  if [[ "$license" == "UNKNOWN" || "$license" == "NOASSERTION" || -z "$license" ]]; then
    echo "$unknown_action"
  else
    # Custom license - flag for review
    echo "flagged"
  fi
}

# ─── License Analysis ─────────────────────────────────────────────────────────

analyze_licenses() {
  local packages_file="$1"
  local output_file="$2"

  log_step "Analyzing license compliance..."

  local total_packages allowed_count flagged_count blocked_count unknown_count
  total_packages=$(jq 'length' "$packages_file")
  allowed_count=0
  flagged_count=0
  blocked_count=0
  unknown_count=0

  local results="[]"

  while IFS= read -r pkg; do
    local name version license ecosystem
    name=$(echo "$pkg" | jq -r '.name')
    version=$(echo "$pkg" | jq -r '.version')
    license=$(echo "$pkg" | jq -r '.license')
    ecosystem=$(echo "$pkg" | jq -r '.ecosystem')

    local classification
    classification=$(classify_license "$license" "$POLICY_FILE")

    case "$classification" in
      allowed)
        allowed_count=$((allowed_count + 1))
        ;;
      flagged)
        flagged_count=$((flagged_count + 1))
        log_warn "Package flagged for review: $name@$version (license: $license)"
        ;;
      blocked)
        blocked_count=$((blocked_count + 1))
        log_fail "Package BLOCKED: $name@$version (license: $license)"
        ;;
      flag)
        unknown_count=$((unknown_count + 1))
        log_warn "Unknown license: $name@$version (license: $license)"
        ;;
    esac

    local result
    result=$(jq -n \
      --arg name "$name" \
      --arg version "$version" \
      --arg license "$license" \
      --arg ecosystem "$ecosystem" \
      --arg classification "$classification" \
      '{
        name: $name,
        version: $version,
        license: $license,
        ecosystem: $ecosystem,
        classification: $classification
      }')

    results=$(echo "$results" | jq --argjson pkg "$result" '. + [$pkg]')
  done < <(jq -c '.[]' "$packages_file")

  log_verbose "Classification complete: $allowed_count allowed, $flagged_count flagged, $blocked_count blocked, $unknown_count unknown"

  # Build final report
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -n \
    --arg timestamp "$timestamp" \
    --argjson total "$total_packages" \
    --argjson allowed "$allowed_count" \
    --argjson flagged "$flagged_count" \
    --argjson blocked "$blocked_count" \
    --argjson unknown "$unknown_count" \
    --argjson packages "$results" \
    '{
      timestamp: $timestamp,
      summary: {
        total_packages: $total,
        allowed: $allowed,
        flagged_for_review: $flagged,
        blocked: $blocked,
        unknown: $unknown
      },
      packages: $packages
    }' > "$output_file"
}

# ─── Report Generation ────────────────────────────────────────────────────────

print_summary_report() {
  local report_file="$1"

  if [[ "$QUIET" == "true" ]]; then
    return
  fi

  echo ""
  echo -e "${BOLD}════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}  Dependency License Compliance Report${NC}"
  echo -e "${BOLD}════════════════════════════════════════════════${NC}"
  echo ""

  local total allowed flagged blocked unknown
  total=$(jq -r '.summary.total_packages' "$report_file")
  allowed=$(jq -r '.summary.allowed' "$report_file")
  flagged=$(jq -r '.summary.flagged_for_review' "$report_file")
  blocked=$(jq -r '.summary.blocked' "$report_file")
  unknown=$(jq -r '.summary.unknown' "$report_file")

  echo "  Total packages:          $total"
  echo -e "  ${GREEN}Allowed licenses:${NC}        $allowed"
  echo -e "  ${YELLOW}Flagged for review:${NC}      $flagged"
  echo -e "  ${RED}Blocked licenses:${NC}        $blocked"
  echo -e "  ${YELLOW}Unknown licenses:${NC}        $unknown"
  echo ""

  # Show flagged packages
  if [[ $flagged -gt 0 ]]; then
    echo -e "${YELLOW}Packages flagged for review:${NC}"
    jq -r '.packages[] | select(.classification == "flagged") | "  - \(.name)@\(.version) (\(.license))"' "$report_file"
    echo ""
  fi

  # Show blocked packages
  if [[ $blocked -gt 0 ]]; then
    echo -e "${RED}BLOCKED packages (incompatible licenses):${NC}"
    jq -r '.packages[] | select(.classification == "blocked") | "  - \(.name)@\(.version) (\(.license))"' "$report_file"
    echo ""
  fi

  # Show unknown packages
  if [[ $unknown -gt 0 ]]; then
    echo -e "${YELLOW}Packages with unknown licenses:${NC}"
    jq -r '.packages[] | select(.classification == "flag" or .license == "UNKNOWN" or .license == "NOASSERTION") | "  - \(.name)@\(.version) (\(.license))"' "$report_file"
    echo ""
  fi

  echo -e "${BOLD}────────────────────────────────────────────────${NC}"
}

print_table_report() {
  local report_file="$1"

  echo ""
  echo -e "${BOLD}Package License Report${NC}"
  echo ""
  printf "%-40s %-15s %-30s %-15s\n" "Package" "Version" "License" "Status"
  printf "%-40s %-15s %-30s %-15s\n" "----------------------------------------" "---------------" "------------------------------" "---------------"

  jq -r '.packages[] | "\(.name)|\(.version)|\(.license)|\(.classification)"' "$report_file" | \
  while IFS='|' read -r name version license classification; do
    local color=""
    local status=""
    case "$classification" in
      allowed)
        color="$GREEN"
        status="ALLOWED"
        ;;
      flagged)
        color="$YELLOW"
        status="REVIEW"
        ;;
      blocked)
        color="$RED"
        status="BLOCKED"
        ;;
      *)
        color="$YELLOW"
        status="UNKNOWN"
        ;;
    esac

    printf "${color}%-40s %-15s %-30s %-15s${NC}\n" \
      "${name:0:40}" \
      "${version:0:15}" \
      "${license:0:30}" \
      "$status"
  done

  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
  if [[ "$QUIET" != "true" ]]; then
    echo ""
    echo -e "${BOLD}Dependency License Compliance Check${NC}"
    echo "────────────────────────────────────────────────"
    echo ""
  fi

  # Load policy
  load_policy

  # Ensure SBOM exists
  generate_sbom_if_needed

  # Create output directory
  mkdir -p "$OUTPUT_DIR"

  # Extract licenses from SBOM
  local packages_file="$OUTPUT_DIR/packages-with-licenses.json"
  extract_all_licenses "$packages_file"

  # Analyze licenses
  local report_file="$OUTPUT_DIR/license-check.json"
  analyze_licenses "$packages_file" "$report_file"

  # Print report
  case "$OUTPUT_FORMAT" in
    json)
      cat "$report_file"
      ;;
    table)
      print_table_report "$report_file"
      ;;
    summary|*)
      print_summary_report "$report_file"
      ;;
  esac

  # Determine exit code
  local blocked flagged
  blocked=$(jq -r '.summary.blocked' "$report_file")
  flagged=$(jq -r '.summary.flagged_for_review + .summary.unknown' "$report_file")

  if [[ $blocked -gt 0 ]]; then
    log_fail "License check FAILED: $blocked package(s) with blocked licenses"
    echo ""
    echo "Remediation steps:"
    echo "  1. Review blocked packages in: $report_file"
    echo "  2. Remove or replace packages with incompatible licenses"
    echo "  3. Update license policy if needed: $POLICY_FILE"
    echo ""
    exit 1
  elif [[ $flagged -gt 0 ]] && [[ "$STRICT_MODE" == "true" ]]; then
    log_fail "License check FAILED (strict mode): $flagged package(s) require review"
    echo ""
    echo "Remediation steps:"
    echo "  1. Review flagged packages in: $report_file"
    echo "  2. Verify license compatibility for your use case"
    echo "  3. Update license policy to allow/block as needed: $POLICY_FILE"
    echo ""
    exit 1
  elif [[ $flagged -gt 0 ]]; then
    log_warn "License check passed with warnings: $flagged package(s) flagged for review"
    echo ""
    echo "  Report saved: $report_file"
    echo "  Review flagged packages and update policy as needed"
    echo ""
    exit 0
  else
    log_success "All dependency licenses approved"
    echo ""
    echo "  Report saved: $report_file"
    echo ""
    exit 0
  fi
}

main "$@"
