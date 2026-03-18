#!/usr/bin/env bash
#
# performance-feedback.sh
# Feature #1301: Cross-repo feedback loop for performance skills
#
# Submit performance audit findings back to the claude-tastic framework repo
# when running from a consumer repository. Enables continuous improvement by
# aggregating field findings from all consumer repos.
#
# Usage:
#   ./performance-feedback.sh --skill NAME --score N --findings-count N \
#     --severity-summary "critical:1,high:3,medium:5,low:2" \
#     [--key-findings JSON] [--framework-repo OWNER/REPO] [--dry-run]
#
# Exit codes:
#   0 - Success (issue created or dry-run preview shown)
#   1 - Not a consumer repo (running in framework repo itself)
#   2 - Missing required arguments
#   3 - gh CLI not available or not authenticated
#   4 - Issue creation failed

set -euo pipefail

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✗${NC}  $1" >&2; }

# ─── Defaults ────────────────────────────────────────────────────────────────
SKILL_NAME=""
SCORE=""
FINDINGS_COUNT=""
SEVERITY_SUMMARY=""
KEY_FINDINGS="[]"
DRY_RUN=false
FRAMEWORK_REPO=""

# Default framework repo — can be overridden via config or argument
DEFAULT_FRAMEWORK_REPO="claude-tastic/claude-tastic"

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skill)           SKILL_NAME="$2";        shift 2 ;;
    --score)           SCORE="$2";             shift 2 ;;
    --findings-count)  FINDINGS_COUNT="$2";    shift 2 ;;
    --severity-summary) SEVERITY_SUMMARY="$2"; shift 2 ;;
    --key-findings)    KEY_FINDINGS="$2";      shift 2 ;;
    --framework-repo)  FRAMEWORK_REPO="$2";    shift 2 ;;
    --dry-run)         DRY_RUN=true;           shift   ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) error "Unknown argument: $1"; exit 2 ;;
  esac
done

# ─── Validate required args ───────────────────────────────────────────────────
if [[ -z "$SKILL_NAME" ]]; then
  error "--skill is required"
  exit 2
fi

# ─── Detect current repo ──────────────────────────────────────────────────────
CURRENT_REPO=$(git remote get-url origin 2>/dev/null \
  | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' \
  || echo "unknown/unknown")

# ─── Resolve framework repo ───────────────────────────────────────────────────
# Priority: --framework-repo arg > config file > default
if [[ -z "$FRAMEWORK_REPO" ]]; then
  # Try to read from corporate-mode config
  CORP_CONFIG="./config/corporate-mode.yaml"
  if [[ -f "$CORP_CONFIG" ]]; then
    FRAMEWORK_REPO=$(grep "framework_repo:" "$CORP_CONFIG" 2>/dev/null \
      | awk '{print $2}' | tr -d '"' || echo "")
  fi
fi

if [[ -z "$FRAMEWORK_REPO" ]]; then
  FRAMEWORK_REPO="$DEFAULT_FRAMEWORK_REPO"
fi

# ─── Consumer repo check ──────────────────────────────────────────────────────
# Normalize repo names for comparison (remove .git suffix, lowercase)
NORM_CURRENT=$(echo "$CURRENT_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/\.git$//')
NORM_FRAMEWORK=$(echo "$FRAMEWORK_REPO" | tr '[:upper:]' '[:lower:]' | sed 's/\.git$//')

if [[ "$NORM_CURRENT" == "$NORM_FRAMEWORK" ]]; then
  info "Running in the framework repo itself — feedback loop not applicable."
  exit 1
fi

# ─── Check gh CLI ─────────────────────────────────────────────────────────────
if ! command -v gh &>/dev/null; then
  error "GitHub CLI (gh) is not installed. Install from: https://cli.github.com/"
  exit 3
fi

if ! gh auth status &>/dev/null; then
  error "GitHub CLI is not authenticated. Run: gh auth login"
  exit 3
fi

# ─── Sanitize findings ────────────────────────────────────────────────────────
# Remove absolute file paths, replace with relative placeholders
# Remove anything that looks like a secret, token, or credential
sanitize_findings() {
  local raw="$1"
  echo "$raw" \
    | sed -E 's|/[a-zA-Z0-9/_.-]{10,}(:[0-9]+)?|<file>|g' \
    | sed -E 's/(password|secret|token|key|credential|auth)[=:][^ "]+/<redacted>/gi' \
    | sed -E 's/[A-Za-z0-9+/]{40,}=*/<redacted-token>/g'
}

SANITIZED_FINDINGS=$(sanitize_findings "$KEY_FINDINGS")

# ─── Build issue content ──────────────────────────────────────────────────────
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CONSUMER_REPO_ID=$(echo "$CURRENT_REPO" | cut -d'/' -f1)  # Only org/owner, not full path

# Parse severity summary into friendly format
SEVERITY_DISPLAY=""
if [[ -n "$SEVERITY_SUMMARY" ]]; then
  SEVERITY_DISPLAY=$(echo "$SEVERITY_SUMMARY" | tr ',' '\n' | while IFS=: read -r sev count; do
    echo "- **${sev}**: ${count}"
  done)
fi

SCORE_DISPLAY="${SCORE:-N/A}"
FINDINGS_DISPLAY="${FINDINGS_COUNT:-N/A}"

ISSUE_TITLE="[Field Feedback] ${SKILL_NAME} audit from consumer repo — ${FINDINGS_DISPLAY} findings"

ISSUE_BODY=$(cat <<EOF
## Performance Skill Field Feedback

**Skill:** \`${SKILL_NAME}\`
**Consumer Org:** ${CONSUMER_REPO_ID}
**Date:** ${TIMESTAMP}
**Score:** ${SCORE_DISPLAY}/100
**Total Findings:** ${FINDINGS_DISPLAY}

### Severity Breakdown

${SEVERITY_DISPLAY}

### Key Findings Summary

The following patterns were detected (file paths sanitized):

\`\`\`json
${SANITIZED_FINDINGS}
\`\`\`

### Suggested Framework Improvements

Based on these field findings, the framework team may want to consider:

1. Review if the ${SKILL_NAME} skill detection rules cover the patterns found above
2. Check if any findings represent new patterns not yet in the skill's pattern library
3. Consider adding new detection rules or improving existing ones if common patterns emerge across consumer repos

### Notes

- No sensitive data, credentials, or secrets from the consumer repo are included
- File paths have been sanitized to \`<file>\` placeholders
- This feedback was automatically generated by the \`${SKILL_NAME}\` skill

---

*This issue was automatically created by the \`${SKILL_NAME}\` performance skill from a consumer repository.*
*Labels: field-feedback, performance*
EOF
)

# ─── Create or preview issue ──────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  echo ""
  echo -e "${CYAN}── Dry Run: Framework Feedback Issue ──────────────────────────────────${NC}"
  echo ""
  echo "Repository: ${FRAMEWORK_REPO}"
  echo "Title: ${ISSUE_TITLE}"
  echo "Labels: field-feedback, performance"
  echo ""
  echo "Body preview:"
  echo "─────────────────────────────────────────────────────────────"
  echo "$ISSUE_BODY"
  echo "─────────────────────────────────────────────────────────────"
  echo ""
  warn "Dry run — no issue was created."
  exit 0
fi

# Create the issue
info "Creating framework feedback issue in ${FRAMEWORK_REPO}..."

ISSUE_URL=$(gh issue create \
  --repo "${FRAMEWORK_REPO}" \
  --title "${ISSUE_TITLE}" \
  --body "${ISSUE_BODY}" \
  --label "field-feedback,performance" \
  2>&1) || {
  error "Failed to create issue: ${ISSUE_URL}"
  exit 4
}

success "Framework feedback issue created: ${ISSUE_URL}"
echo ""
echo "The framework team will review findings from consumer repos and push"
echo "improvements as continuous updates to all consumers."
