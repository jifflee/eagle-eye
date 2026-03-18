#!/usr/bin/env bash
# validate-extension.sh
# Standalone validator for Claude Code extensions
# Part of skill-builder (#991)

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
ERRORS=0
WARNINGS=0
CHECKS=0

# Check function
check() {
    local description="$1"
    local status="$2"  # pass, warn, fail
    local message="${3:-}"

    ((CHECKS++))

    case "$status" in
        pass)
            echo -e "  ${GREEN}✅${NC} ${description}"
            ;;
        warn)
            echo -e "  ${YELLOW}⚠️${NC}  ${description}"
            [ -n "$message" ] && echo -e "     ${YELLOW}→${NC} ${message}"
            ((WARNINGS++))
            ;;
        fail)
            echo -e "  ${RED}❌${NC} ${description}"
            [ -n "$message" ] && echo -e "     ${RED}→${NC} ${message}"
            ((ERRORS++))
            ;;
    esac
}

# Validate skill
validate_skill() {
    local path="$1"
    local skill_name=$(basename "$path")

    echo -e "${BLUE}Validating Skill:${NC} ${skill_name}"
    echo ""

    # Check SKILL.md exists
    if [ -f "$path/SKILL.md" ]; then
        check "SKILL.md present" "pass"

        # Validate YAML frontmatter
        if head -n 20 "$path/SKILL.md" | grep -q "^---" && head -n 20 "$path/SKILL.md" | tail -n +2 | grep -q "^---"; then
            check "YAML frontmatter present" "pass"

            # Check required fields
            if grep -q "^name:" "$path/SKILL.md"; then
                local yaml_name=$(grep "^name:" "$path/SKILL.md" | head -1 | awk '{print $2}')
                if [ "$yaml_name" = "$skill_name" ]; then
                    check "Name matches directory" "pass"
                else
                    check "Name matches directory" "fail" "Expected '$skill_name', got '$yaml_name'"
                fi
            else
                check "Name field present" "fail"
            fi

            if grep -q "^description:" "$path/SKILL.md"; then
                check "Description field present" "pass"
            else
                check "Description field present" "fail"
            fi

            if grep -q "^permissions:" "$path/SKILL.md"; then
                check "Permissions block present" "pass"

                # Check permission tier
                if grep -A 10 "^permissions:" "$path/SKILL.md" | grep -q "max_tier:"; then
                    check "Permission tier declared" "pass"
                else
                    check "Permission tier declared" "warn" "Consider adding max_tier"
                fi
            else
                check "Permissions block present" "warn" "Recommended to declare permissions"
            fi
        else
            check "YAML frontmatter present" "fail"
        fi
    else
        check "SKILL.md present" "fail"
    fi

    # Check main script
    if [ -f "$path/${skill_name}.sh" ]; then
        check "Main script present (${skill_name}.sh)" "pass"

        # Check executable
        if [ -x "$path/${skill_name}.sh" ]; then
            check "Script is executable" "pass"
        else
            check "Script is executable" "warn" "Run: chmod +x ${skill_name}.sh"
        fi

        # Check shebang
        if head -n1 "$path/${skill_name}.sh" | grep -q "^#!/"; then
            check "Shebang present" "pass"
        else
            check "Shebang present" "fail"
        fi

        # Check error handling
        if grep -q "set -euo pipefail" "$path/${skill_name}.sh"; then
            check "Error handling configured" "pass"
        else
            check "Error handling configured" "warn" "Add: set -euo pipefail"
        fi

        # Check for usage function
        if grep -q "^usage()" "$path/${skill_name}.sh"; then
            check "Usage function defined" "pass"
        else
            check "Usage function defined" "warn" "Consider adding usage documentation"
        fi

        # Shellcheck if available
        if command -v shellcheck &> /dev/null; then
            if shellcheck "$path/${skill_name}.sh" &> /dev/null; then
                check "Shellcheck passed" "pass"
            else
                check "Shellcheck passed" "warn" "Run: shellcheck ${skill_name}.sh"
            fi
        fi
    else
        check "Main script present" "fail" "Expected: ${skill_name}.sh"
    fi

    # Check for README or documentation
    if [ -f "$path/README.md" ]; then
        check "README.md present" "pass"
    fi

    # Check naming convention (kebab-case)
    if [[ "$skill_name" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
        check "Naming convention (kebab-case)" "pass"
    else
        check "Naming convention (kebab-case)" "fail" "Use lowercase with hyphens"
    fi
}

# Validate hook
validate_hook() {
    local path="$1"
    local hook_name=$(basename "$path")

    echo -e "${BLUE}Validating Hook:${NC} ${hook_name}"
    echo ""

    # Check file exists
    if [ -f "$path" ]; then
        check "Hook file present" "pass"

        # Check executable
        if [ -x "$path" ]; then
            check "Hook is executable" "pass"
        else
            check "Hook is executable" "warn" "Run: chmod +x $(basename $path)"
        fi

        # Check shebang
        if head -n1 "$path" | grep -q "^#!/"; then
            check "Shebang present" "pass"
        else
            check "Shebang present" "fail"
        fi

        # Check error handling
        if grep -q "set -euo pipefail" "$path"; then
            check "Error handling configured" "pass"
        else
            check "Error handling configured" "warn" "Add: set -euo pipefail"
        fi

        # Check for logging
        if grep -q "log_hook\|log_" "$path"; then
            check "Logging implemented" "pass"
        else
            check "Logging implemented" "warn" "Consider adding logging"
        fi

        # Shellcheck if available
        if command -v shellcheck &> /dev/null; then
            if shellcheck "$path" &> /dev/null; then
                check "Shellcheck passed" "pass"
            else
                check "Shellcheck passed" "warn" "Run: shellcheck $(basename $path)"
            fi
        fi
    else
        check "Hook file present" "fail"
    fi
}

# Validate script
validate_script() {
    local path="$1"
    local script_name=$(basename "$path")

    echo -e "${BLUE}Validating Script:${NC} ${script_name}"
    echo ""

    # Check file exists
    if [ -f "$path" ]; then
        check "Script file present" "pass"

        # Check executable
        if [ -x "$path" ]; then
            check "Script is executable" "pass"
        else
            check "Script is executable" "warn"
        fi

        # Check shebang
        if head -n1 "$path" | grep -q "^#!/"; then
            check "Shebang present" "pass"
        else
            check "Shebang present" "fail"
        fi

        # Shellcheck if available
        if command -v shellcheck &> /dev/null; then
            if shellcheck "$path" &> /dev/null; then
                check "Shellcheck passed" "pass"
            else
                check "Shellcheck passed" "warn"
            fi
        fi
    else
        check "Script file present" "fail"
    fi
}

# Main
main() {
    local path="${1:-.}"

    if [ ! -e "$path" ]; then
        echo -e "${RED}Error: Path not found: $path${NC}"
        exit 1
    fi

    echo -e "${BLUE}🔍 Extension Validator${NC}"
    echo ""

    # Determine extension type and validate
    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        validate_skill "$path"
    elif [ -f "$path" ] && [[ "$path" == *.sh ]]; then
        if [[ "$path" == *"/hooks/"* ]]; then
            validate_hook "$path"
        else
            validate_script "$path"
        fi
    else
        echo -e "${YELLOW}⚠️  Unable to determine extension type${NC}"
        echo "Path should be either:"
        echo "  - A skill directory with SKILL.md"
        echo "  - A .sh hook/script file"
        exit 1
    fi

    # Summary
    echo ""
    echo -e "${BLUE}═══════════════════════════════════${NC}"
    echo -e "${BLUE}Validation Summary${NC}"
    echo -e "${BLUE}═══════════════════════════════════${NC}"
    echo -e "  Total checks: ${CHECKS}"
    echo -e "  Errors: ${ERRORS}"
    echo -e "  Warnings: ${WARNINGS}"
    echo ""

    if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
        echo -e "${GREEN}✅ Validation passed!${NC}"
        echo -e "Extension is ready for deployment."
        exit 0
    elif [ $ERRORS -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Validation passed with warnings${NC}"
        echo -e "Extension is functional but could be improved."
        exit 0
    else
        echo -e "${RED}❌ Validation failed${NC}"
        echo -e "Fix errors before deploying."
        exit 1
    fi
}

# Run main
main "$@"
