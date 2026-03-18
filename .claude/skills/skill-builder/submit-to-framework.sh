#!/usr/bin/env bash
# submit-to-framework.sh
# Submit extension to framework repository
# Part of skill-builder (#991)

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
CORPORATE_CONFIG="${REPO_ROOT}/config/corporate-mode.yaml"

# Usage
usage() {
    cat <<EOF
Usage: submit-to-framework.sh <extension-path> [OPTIONS]

Submit an extension to the framework repository.

OPTIONS:
    --method METHOD     Submission method: issue, branch, tarball (default: issue)
    -h, --help          Show this help message

EXAMPLES:
    submit-to-framework.sh core/skills/my-skill
    submit-to-framework.sh core/skills/my-skill --method branch
    submit-to-framework.sh .claude/hooks/my-hook.sh --method tarball

EOF
    exit 0
}

# Get framework repo
get_framework_repo() {
    if [ -f "$CORPORATE_CONFIG" ]; then
        grep "framework_repo:" "$CORPORATE_CONFIG" | awk '{print $2}' | tr -d '"' || echo ""
    else
        echo ""
    fi
}

# Create GitHub issue
submit_via_issue() {
    local path="$1"
    local ext_name="$2"
    local ext_type="$3"
    local framework_repo="$4"

    echo -e "${BLUE}📝 Creating GitHub issue...${NC}"
    echo ""

    # Check if gh is available
    if ! command -v gh &> /dev/null; then
        echo -e "${RED}❌ Error: GitHub CLI (gh) not installed${NC}"
        echo "Install from: https://cli.github.com/"
        return 1
    fi

    # Check authentication
    if ! gh auth status &> /dev/null; then
        echo -e "${RED}❌ Error: GitHub CLI not authenticated${NC}"
        echo "Run: gh auth login"
        return 1
    fi

    # Gather information
    echo -e "${BLUE}Please provide some information:${NC}"
    echo ""

    echo -ne "${BLUE}Brief description:${NC} "
    read -r description

    echo -ne "${BLUE}Why is this useful?${NC} "
    read -r rationale

    # Get file list
    local file_list
    if [ -d "$path" ]; then
        file_list=$(find "$path" -type f | sed "s|$path/|  - |" | sort)
    else
        file_list="  - $(basename "$path")"
    fi

    # Create issue body
    local issue_body
    issue_body=$(cat <<EOF
## Extension Contribution

**Type:** ${ext_type}
**Name:** ${ext_name}

### Description

${description}

### Rationale

${rationale}

### Files Included

${file_list}

### Environment

- **Submitted From:** $(git remote get-url origin 2>/dev/null | sed 's/.*github.com[:/]\(.*\)\.git/\1/' || echo "local repository")
- **Date:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
- **User:** ${USER}@$(hostname)

### Testing

- [ ] Validated locally
- [ ] Tested functionality
- [ ] Follows framework conventions

---

This contribution was created using the \`/skill-builder\` tool.
EOF
)

    local issue_title="[Contribution] New ${ext_type}: ${ext_name}"

    echo ""
    echo -e "${BLUE}Creating issue in ${framework_repo}...${NC}"

    # Create the issue
    if gh issue create \
        --repo "$framework_repo" \
        --title "$issue_title" \
        --body "$issue_body" \
        --label "contribution,${ext_type}" > /tmp/gh-issue-url.txt 2>&1; then

        local issue_url=$(cat /tmp/gh-issue-url.txt)
        echo ""
        echo -e "${GREEN}✅ Issue created successfully!${NC}"
        echo ""
        echo -e "${CYAN}Issue URL:${NC} ${issue_url}"
        echo ""
        echo "The framework maintainers will review your contribution."
        echo "You can track the status at the URL above."
        return 0
    else
        echo -e "${RED}❌ Failed to create issue${NC}"
        cat /tmp/gh-issue-url.txt
        return 1
    fi
}

# Create local branch
submit_via_branch() {
    local path="$1"
    local ext_name="$2"
    local ext_type="$3"

    echo -e "${BLUE}🌿 Creating local branch...${NC}"
    echo ""

    local branch_name="contrib/${ext_type}/${ext_name}"

    echo -e "${CYAN}Instructions to create a PR:${NC}"
    echo ""
    echo "1. Create and switch to branch:"
    echo -e "   ${YELLOW}git checkout -b ${branch_name}${NC}"
    echo ""
    echo "2. Add your extension:"
    echo -e "   ${YELLOW}git add ${path}${NC}"
    echo ""
    echo "3. Commit:"
    echo -e "   ${YELLOW}git commit -m \"feat: add ${ext_type} - ${ext_name}\"${NC}"
    echo ""
    echo "4. Push to origin:"
    echo -e "   ${YELLOW}git push origin ${branch_name}${NC}"
    echo ""
    echo "5. Create PR:"
    echo -e "   ${YELLOW}gh pr create --title \"feat: add ${ext_type} - ${ext_name}\" --body \"[Your description]\"${NC}"
    echo ""

    # Offer to execute
    echo -ne "${BLUE}Would you like to execute these steps now? (y/n):${NC} "
    read -r response

    if [[ "$response" =~ ^[Yy]$ ]]; then
        echo ""
        git checkout -b "$branch_name"
        git add "$path"
        git commit -m "feat: add ${ext_type} - ${ext_name}"

        echo ""
        echo -e "${GREEN}✅ Branch created and committed!${NC}"
        echo ""
        echo "Now push and create PR:"
        echo -e "   ${YELLOW}git push origin ${branch_name}${NC}"
        echo -e "   ${YELLOW}gh pr create --title \"feat: add ${ext_type} - ${ext_name}\"${NC}"
        echo ""
    fi

    return 0
}

# Export as tarball
submit_via_tarball() {
    local path="$1"
    local ext_name="$2"
    local ext_type="$3"

    echo -e "${BLUE}📦 Creating tarball...${NC}"
    echo ""

    local tarball="${ext_name}-contribution.tar.gz"
    local temp_dir=$(mktemp -d)

    # Copy files to temp directory
    if [ -d "$path" ]; then
        cp -r "$path" "${temp_dir}/${ext_name}"
        tar -czf "$tarball" -C "$temp_dir" "${ext_name}"
    else
        mkdir -p "${temp_dir}/${ext_name}"
        cp "$path" "${temp_dir}/${ext_name}/"
        tar -czf "$tarball" -C "$temp_dir" "${ext_name}"
    fi

    rm -rf "$temp_dir"

    echo -e "  ${GREEN}✅${NC} Created: ${tarball}"
    echo ""
    echo -e "${CYAN}File details:${NC}"
    ls -lh "$tarball" | awk '{print "  Size: " $5}'
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Test the tarball:"
    echo -e "     ${YELLOW}tar -tzf ${tarball}${NC}"
    echo ""
    echo "  2. Submit to framework maintainers:"
    echo "     - Attach to a GitHub issue"
    echo "     - Email to maintainers"
    echo "     - Share via file transfer"
    echo ""
    echo -e "${CYAN}To extract:${NC}"
    echo -e "   ${YELLOW}tar -xzf ${tarball}${NC}"
    echo ""

    return 0
}

# Main
main() {
    local path="${1:-.}"
    local method="issue"

    # Parse arguments
    shift || true
    while [[ $# -gt 0 ]]; do
        case $1 in
            --method)
                method="$2"
                shift 2
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                usage
                ;;
        esac
    done

    # Validate path
    if [ ! -e "$path" ]; then
        echo -e "${RED}Error: Path not found: $path${NC}"
        exit 1
    fi

    echo -e "${CYAN}📤 Extension Submission Tool${NC}"
    echo ""

    # Determine extension type
    local ext_type="extension"
    local ext_name

    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        ext_type="skill"
        ext_name=$(basename "$path")
    elif [ -d "$path" ]; then
        ext_type="directory"
        ext_name=$(basename "$path")
    elif [ -f "$path" ]; then
        if [[ "$path" == *"/hooks/"* ]]; then
            ext_type="hook"
        else
            ext_type="script"
        fi
        ext_name=$(basename "$path" .sh)
    fi

    echo -e "${BLUE}Extension:${NC} ${ext_name}"
    echo -e "${BLUE}Type:${NC} ${ext_type}"
    echo -e "${BLUE}Method:${NC} ${method}"
    echo ""

    # Get framework repo
    local framework_repo=$(get_framework_repo)

    # Execute submission based on method
    case "$method" in
        issue)
            if [ -z "$framework_repo" ]; then
                echo -e "${YELLOW}⚠️  Framework repository not configured${NC}"
                echo ""
                echo "Configure in ${CORPORATE_CONFIG}:"
                echo ""
                echo "corporate_mode:"
                echo "  framework_repo: \"owner/claude-tastic\""
                echo ""
                exit 1
            fi
            submit_via_issue "$path" "$ext_name" "$ext_type" "$framework_repo"
            ;;
        branch)
            submit_via_branch "$path" "$ext_name" "$ext_type"
            ;;
        tarball)
            submit_via_tarball "$path" "$ext_name" "$ext_type"
            ;;
        *)
            echo -e "${RED}Unknown method: ${method}${NC}"
            echo "Valid methods: issue, branch, tarball"
            exit 1
            ;;
    esac
}

# Run main
main "$@"
