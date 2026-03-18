#!/usr/bin/env bash
# ============================================================
# Script: demo-package-attestation.sh
# Purpose: Demonstration of package attestation validation features
#
# This script demonstrates the package attestation and provenance
# validation system, showing how to verify supply chain integrity
# for npm packages.
#
# Usage:
#   ./scripts/ci/examples/demo-package-attestation.sh
#
# Related: Issue #1063 - Add package validation and attestation verification
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Package Attestation & Provenance Validation Demo${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""

# ─── Demo 1: Quick Check ──────────────────────────────────────────────────────

echo -e "${CYAN}Demo 1: Quick Attestation Check (npm provenance only)${NC}"
echo "Command: ./scripts/ci/validators/package-attestation.sh --quick"
echo ""

./scripts/ci/validators/package-attestation.sh --quick || true

echo ""
read -p "Press Enter to continue..."
echo ""

# ─── Demo 2: Full Check ───────────────────────────────────────────────────────

echo -e "${CYAN}Demo 2: Full Attestation Check (all verification types)${NC}"
echo "Command: ./scripts/ci/validators/package-attestation.sh --full --verbose"
echo ""

./scripts/ci/validators/package-attestation.sh --full --verbose || true

echo ""
read -p "Press Enter to continue..."
echo ""

# ─── Demo 3: Integration with dep-audit ───────────────────────────────────────

echo -e "${CYAN}Demo 3: Integrated Vulnerability + Attestation Scan${NC}"
echo "Command: ./scripts/ci/validators/dep-audit.sh --quick --with-attestation"
echo ""
echo "This combines:"
echo "  - Vulnerability scanning (npm audit, pip-audit, safety)"
echo "  - Package attestation validation"
echo "  - Supply chain integrity checks"
echo ""

./scripts/ci/validators/dep-audit.sh --quick --with-attestation || true

echo ""
read -p "Press Enter to continue..."
echo ""

# ─── Demo 4: View Reports ─────────────────────────────────────────────────────

echo -e "${CYAN}Demo 4: Review Generated Reports${NC}"
echo ""

if [[ -f "$REPO_ROOT/.dep-audit/npm-provenance.json" ]]; then
  echo "Report: .dep-audit/npm-provenance.json"
  echo ""
  cat "$REPO_ROOT/.dep-audit/npm-provenance.json" | jq '
    {
      summary: .summary,
      sample_unattested: .unattested_packages[:5],
      sample_attested: .attested_packages[:5]
    }
  ' 2>/dev/null || echo "Report exists but jq parsing failed"
  echo ""
else
  echo -e "${YELLOW}No npm-provenance.json report found (likely no package-lock.json)${NC}"
  echo ""
fi

if [[ -f "$REPO_ROOT/.dep-audit/slsa-provenance.json" ]]; then
  echo "Report: .dep-audit/slsa-provenance.json"
  echo ""
  cat "$REPO_ROOT/.dep-audit/slsa-provenance.json" | jq '.summary' 2>/dev/null || echo "Report exists"
  echo ""
fi

read -p "Press Enter to continue..."
echo ""

# ─── Demo 5: Configuration ────────────────────────────────────────────────────

echo -e "${CYAN}Demo 5: Package Policy Configuration${NC}"
echo ""
echo "Configuration file: config/package-policy.yaml"
echo ""

if [[ -f "$REPO_ROOT/config/package-policy.yaml" ]]; then
  echo "Current attestation policy:"
  echo ""
  grep -A15 "attestation_verification:" "$REPO_ROOT/config/package-policy.yaml" | head -20
  echo ""
else
  echo -e "${RED}Config file not found!${NC}"
fi

echo ""
read -p "Press Enter to continue..."
echo ""

# ─── Summary ──────────────────────────────────────────────────────────────────

echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Demo Complete${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Key Features Demonstrated:"
echo ""
echo "  ✅ Quick attestation checks (--quick)"
echo "  ✅ Full validation with all check types (--full)"
echo "  ✅ Integration with dependency auditing"
echo "  ✅ JSON report generation"
echo "  ✅ Policy-based configuration"
echo ""
echo "Next Steps:"
echo ""
echo "  1. Review documentation:"
echo "     cat docs/ci/PACKAGE_ATTESTATION.md"
echo ""
echo "  2. Configure policy for your project:"
echo "     vi config/package-policy.yaml"
echo ""
echo "  3. Integrate into CI/CD pipeline:"
echo "     Add to .github/workflows or scripts/pr/pr-validation-gate.sh"
echo ""
echo "  4. Enable strict mode (optional):"
echo "     Set fail_on_missing: true in config/package-policy.yaml"
echo ""
echo "Related Issues:"
echo "  - #1063: Add package validation and attestation verification"
echo "  - #1031: Add package attestation and provenance validation"
echo "  - #1030: CI/CD infrastructure improvements (parent epic)"
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""
