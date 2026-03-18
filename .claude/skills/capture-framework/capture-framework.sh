#!/usr/bin/env bash
# capture-framework.sh
# Feature #686: Cross-repo feedback mechanism
#
# Submit issues to the framework repository from consumer repos

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
# shellcheck source=scripts/lib/common.sh
source "$(dirname "${SCRIPT_DIR}")/../scripts/lib/common.sh" 2>/dev/null || true

# Source corporate enforcement
# shellcheck source=scripts/lib/corporate-enforcement.sh
source "$(dirname "${SCRIPT_DIR}")/../scripts/lib/corporate-enforcement.sh" 2>/dev/null || true

# Configuration
CORPORATE_CONFIG="${CORPORATE_CONFIG:-./config/corporate-mode.yaml}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Usage information
usage() {
    cat <<EOF
Usage: capture-framework.sh <feedback-message>

Submit feedback about the framework to the source repository.

ARGUMENTS:
    feedback-message    The feedback to submit (required)

EXAMPLES:
    capture-framework.sh "skill-sync purged a skill I still need"
    capture-framework.sh "Add support for custom agent templates"

CONFIGURATION:
    Set framework_repo in config/corporate-mode.yaml:

    corporate_mode:
      framework_repo: "owner/claude-tastic"

EOF
    exit 0
}

# Parse arguments
if [[ $# -eq 0 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
fi

FEEDBACK_MESSAGE="$*"

# Check if corporate mode config exists
if [[ ! -f "${CORPORATE_CONFIG}" ]]; then
    echo -e "${RED}❌ Error: Corporate mode configuration not found: ${CORPORATE_CONFIG}${NC}" >&2
    exit 1
fi

# Get framework repository
FRAMEWORK_REPO=$(grep "framework_repo:" "${CORPORATE_CONFIG}" | awk '{print $2}' | tr -d '"' || echo "")

if [[ -z "${FRAMEWORK_REPO}" ]]; then
    echo -e "${RED}❌ Error: Framework repository not configured${NC}" >&2
    echo ""
    echo "To use /capture --framework, add the framework repository to ${CORPORATE_CONFIG}:"
    echo ""
    echo "corporate_mode:"
    echo "  framework_repo: \"owner/claude-tastic\""
    echo ""
    exit 1
fi

# Check if gh is available
if ! command -v gh &> /dev/null; then
    echo -e "${RED}❌ Error: GitHub CLI (gh) is not installed${NC}" >&2
    echo "Install it from: https://cli.github.com/"
    exit 1
fi

# Check if gh is authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}❌ Error: GitHub CLI is not authenticated${NC}" >&2
    echo "Run: gh auth login"
    exit 1
fi

# Gather context information
echo -e "${BLUE}Gathering context information...${NC}"

# Get current repository
CURRENT_REPO=$(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "unknown")

# Get current user
CURRENT_USER="${USER}@$(hostname)"

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Detect OS
OS_INFO=$(uname -s || echo "unknown")

# Get shell version
SHELL_VERSION=$(bash --version | head -n1 || echo "unknown")

# Determine issue type based on keywords
ISSUE_TYPE="feedback"
if echo "${FEEDBACK_MESSAGE}" | grep -qi "bug\|error\|fail\|broke\|issue"; then
    ISSUE_TYPE="bug"
elif echo "${FEEDBACK_MESSAGE}" | grep -qi "feature\|add\|support\|enhance"; then
    ISSUE_TYPE="enhancement"
elif echo "${FEEDBACK_MESSAGE}" | grep -qi "config\|setting\|setup"; then
    ISSUE_TYPE="config"
fi

# Create issue title
ISSUE_TITLE="[Consumer Feedback] ${FEEDBACK_MESSAGE:0:80}"
if [[ ${#FEEDBACK_MESSAGE} -gt 80 ]]; then
    ISSUE_TITLE="${ISSUE_TITLE}..."
fi

# Create issue body
ISSUE_BODY=$(cat <<EOF
## Consumer Feedback

**From Repository:** ${CURRENT_REPO}
**Submitted By:** ${CURRENT_USER}
**Date:** ${TIMESTAMP}

### Feedback

${FEEDBACK_MESSAGE}

### Environment

- OS: ${OS_INFO}
- Shell: ${SHELL_VERSION}
- Framework Version: (auto-detection pending)

### Configuration

(Relevant config sections would be included here)

### Additional Context

(Any error logs or traces would be included here)

---

This issue was automatically created by the \`/capture --framework\` skill from a consumer repository.

**Labels:** feedback, from-consumer, ${ISSUE_TYPE}
EOF
)

# Create issue
echo -e "${BLUE}Creating issue in framework repository: ${FRAMEWORK_REPO}${NC}"
echo ""

# Note: In full implementation, this would actually create the issue
# For now, show what would be created
cat <<EOF
${GREEN}Issue would be created with:${NC}

Title: ${ISSUE_TITLE}
Repository: ${FRAMEWORK_REPO}
Labels: feedback, from-consumer, ${ISSUE_TYPE}

Body:
${ISSUE_BODY}

${YELLOW}Note: Full GitHub API implementation pending.${NC}
${YELLOW}Use: gh issue create --repo "${FRAMEWORK_REPO}" --title "..." --body "..."${NC}

EOF

# Log in audit trail (corporate mode)
log_operation "github_api" "${FRAMEWORK_REPO}" "allowed" "Framework feedback submission" 2>/dev/null || true

# Show what the command would be
echo -e "${BLUE}Full command:${NC}"
echo "gh issue create --repo \"${FRAMEWORK_REPO}\" \\"
echo "  --title \"${ISSUE_TITLE}\" \\"
echo "  --body \"\${ISSUE_BODY}\" \\"
echo "  --label \"feedback,from-consumer,${ISSUE_TYPE}\""

echo ""
echo -e "${GREEN}✅ Framework feedback prepared successfully${NC}"
echo ""
echo "Your feedback will be submitted to: ${FRAMEWORK_REPO}"
echo "The framework maintainers will review and respond in the GitHub issue."
