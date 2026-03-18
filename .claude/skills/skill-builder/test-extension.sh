#!/usr/bin/env bash
# test-extension.sh
# Test extension locally before deployment
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
NC='\033[0m'

# Test skill
test_skill() {
    local path="$1"
    local skill_name=$(basename "$path")

    echo -e "${BLUE}🧪 Testing Skill:${NC} ${skill_name}"
    echo ""

    # Deploy to .claude
    local claude_dir="${REPO_ROOT}/.claude/skills/${skill_name}"

    echo -e "${BLUE}Step 1: Deploying to .claude/skills/${NC}"
    mkdir -p "$claude_dir"
    cp -r "$path"/* "$claude_dir/"
    echo -e "  ${GREEN}✅${NC} Deployed to: ${claude_dir}"
    echo ""

    # Test execution
    echo -e "${BLUE}Step 2: Testing execution${NC}"
    if [ -x "${claude_dir}/${skill_name}.sh" ]; then
        echo -e "  ${BLUE}Testing --help flag...${NC}"
        if "${claude_dir}/${skill_name}.sh" --help &> /dev/null; then
            echo -e "  ${GREEN}✅${NC} Help flag works"
        else
            echo -e "  ${YELLOW}⚠️${NC}  Help flag returned error (may be normal)"
        fi

        echo -e "  ${BLUE}Testing basic execution...${NC}"
        if timeout 5 "${claude_dir}/${skill_name}.sh" &> /tmp/skill-test-output.txt; then
            echo -e "  ${GREEN}✅${NC} Script executed successfully"
        else
            echo -e "  ${YELLOW}⚠️${NC}  Script execution had issues:"
            head -5 /tmp/skill-test-output.txt | sed 's/^/     /'
        fi
    else
        echo -e "  ${RED}❌${NC} Script is not executable"
    fi
    echo ""

    # Test SKILL.md
    echo -e "${BLUE}Step 3: Validating SKILL.md${NC}"
    if [ -f "${claude_dir}/SKILL.md" ]; then
        echo -e "  ${GREEN}✅${NC} SKILL.md present"

        # Check if can be parsed
        if head -n 20 "${claude_dir}/SKILL.md" | grep -q "^name:"; then
            echo -e "  ${GREEN}✅${NC} SKILL.md is parseable"
        else
            echo -e "  ${YELLOW}⚠️${NC}  SKILL.md may have format issues"
        fi
    else
        echo -e "  ${RED}❌${NC} SKILL.md missing"
    fi
    echo ""

    # Summary
    echo -e "${GREEN}✅ Testing complete!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Test the skill: /${skill_name}"
    echo -e "  2. Review logs if issues occur"
    echo -e "  3. Make adjustments and re-test"
    echo -e "  4. Deploy permanently: ./scripts/generate-manifest.sh"
    echo ""
}

# Test hook
test_hook() {
    local path="$1"
    local hook_name=$(basename "$path")

    echo -e "${BLUE}🧪 Testing Hook:${NC} ${hook_name}"
    echo ""

    # Test execution
    echo -e "${BLUE}Step 1: Testing execution${NC}"
    if [ -x "$path" ]; then
        echo -e "  ${BLUE}Running hook...${NC}"
        if timeout 5 "$path" &> /tmp/hook-test-output.txt; then
            echo -e "  ${GREEN}✅${NC} Hook executed successfully"
        else
            local exit_code=$?
            echo -e "  ${YELLOW}⚠️${NC}  Hook exited with code: ${exit_code}"
            echo -e "  ${BLUE}Output:${NC}"
            head -10 /tmp/hook-test-output.txt | sed 's/^/     /'
        fi
    else
        echo -e "  ${RED}❌${NC} Hook is not executable"
    fi
    echo ""

    # Check logs
    echo -e "${BLUE}Step 2: Checking logs${NC}"
    local log_dir="${HOME}/.claude-tastic/hooks"
    if [ -d "$log_dir" ]; then
        local log_files=$(find "$log_dir" -name "*${hook_name}*.log" -o -name "hook-*.log" | head -3)
        if [ -n "$log_files" ]; then
            echo -e "  ${GREEN}✅${NC} Log files found:"
            echo "$log_files" | sed 's/^/     /'
        else
            echo -e "  ${YELLOW}⚠️${NC}  No log files found (hook may not log)"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Log directory not found: ${log_dir}"
    fi
    echo ""

    # Summary
    echo -e "${GREEN}✅ Testing complete!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Review hook behavior and logs"
    echo -e "  2. Test integration with Claude"
    echo -e "  3. Adjust and re-test as needed"
    echo ""
}

# Main
main() {
    local path="${1:-.}"

    if [ ! -e "$path" ]; then
        echo -e "${RED}Error: Path not found: $path${NC}"
        exit 1
    fi

    echo -e "${BLUE}🔬 Extension Tester${NC}"
    echo ""

    # Determine type and test
    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        test_skill "$path"
    elif [ -f "$path" ] && [[ "$path" == *.sh ]]; then
        test_hook "$path"
    else
        echo -e "${RED}Error: Unknown extension type${NC}"
        echo "Path should be either:"
        echo "  - A skill directory with SKILL.md"
        echo "  - A .sh hook/script file"
        exit 1
    fi
}

# Run main
main "$@"
