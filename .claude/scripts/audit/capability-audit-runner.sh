#!/usr/bin/env bash
#
# capability-audit-runner.sh - Wrapper for running capability audits in different contexts
# Provides pre-configured audit profiles for common use cases
#
# Usage:
#   ./scripts/audit/capability-audit-runner.sh quick        # Quick audit (no obsolete check)
#   ./scripts/audit/capability-audit-runner.sh full         # Full audit with obsolete check
#   ./scripts/audit/capability-audit-runner.sh ci           # CI-friendly JSON output
#   ./scripts/audit/capability-audit-runner.sh report       # Generate markdown report

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUDIT_SCRIPT="$SCRIPT_DIR/../capability-audit.sh"

if [ ! -f "$AUDIT_SCRIPT" ]; then
  echo "Error: capability-audit.sh not found at $AUDIT_SCRIPT"
  exit 2
fi

case "${1:-quick}" in
  quick)
    echo "Running quick capability audit..."
    "$AUDIT_SCRIPT"
    ;;

  full)
    echo "Running full capability audit with obsolescence check..."
    "$AUDIT_SCRIPT" --check-obsolete
    ;;

  ci)
    echo "Running CI capability audit..."
    "$AUDIT_SCRIPT" --format json
    ;;

  report)
    REPORT_FILE="audit-report-$(date +%Y%m%d-%H%M%S).md"
    echo "Generating capability audit report: $REPORT_FILE"
    "$AUDIT_SCRIPT" --check-obsolete --format markdown --report "$REPORT_FILE"
    echo "Report saved to: $REPORT_FILE"
    ;;

  skills)
    echo "Auditing skills only..."
    "$AUDIT_SCRIPT" --skills
    ;;

  agents)
    echo "Auditing agents only..."
    "$AUDIT_SCRIPT" --agents
    ;;

  *)
    echo "Unknown profile: $1"
    echo ""
    echo "Usage: $0 [profile]"
    echo ""
    echo "Profiles:"
    echo "  quick     - Quick audit without obsolescence check (default)"
    echo "  full      - Full audit with obsolescence check"
    echo "  ci        - CI-friendly JSON output"
    echo "  report    - Generate timestamped markdown report"
    echo "  skills    - Audit skills only"
    echo "  agents    - Audit agents only"
    exit 2
    ;;
esac
