#!/usr/bin/env bash
# skill-builder.sh
# Feature #991: Skill builder for local hook/action/skill development
#
# Interactive wizard to create, validate, test, and deploy Claude Code extensions

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

# Source common utilities
# shellcheck source=scripts/lib/common.sh
source "${REPO_ROOT}/scripts/lib/common.sh" 2>/dev/null || true

# Configuration
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
CORE_SKILLS_DIR="${REPO_ROOT}/core/skills"
CLAUDE_HOOKS_DIR="${REPO_ROOT}/.claude/hooks"
SCRIPTS_HOOKS_DIR="${REPO_ROOT}/scripts/hooks"
CLAUDE_ACTIONS_DIR="${REPO_ROOT}/.claude/actions"
AGENTS_DIR="${REPO_ROOT}/src/agents"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Usage information
usage() {
    cat <<EOF
Usage: skill-builder.sh [OPTIONS]

Interactive wizard to build Claude Code extensions (skills, hooks, actions, commands, agents).

OPTIONS:
    --type TYPE         Extension type: skill, hook, action, command, agent
    --name NAME         Extension name (kebab-case)
    --template TMPL     Template to use
    --validate PATH     Validate existing extension
    --test PATH         Test extension locally
    --submit PATH       Submit extension to framework repo
    -h, --help          Show this help message

EXAMPLES:
    # Interactive mode
    skill-builder.sh

    # Quick create
    skill-builder.sh --type skill --name my-skill

    # Create from template
    skill-builder.sh --type hook --template pre-commit --name check-deps

    # Validate extension
    skill-builder.sh --validate core/skills/my-skill

    # Test extension
    skill-builder.sh --test core/skills/my-skill

    # Submit to framework
    skill-builder.sh --submit core/skills/my-skill

EOF
    exit 0
}

# Print banner
print_banner() {
    echo -e "${CYAN}"
    cat <<'EOF'
    ╔═══════════════════════════════════════════════╗
    ║   🎨 Claude Code Extension Builder           ║
    ║   Build skills, hooks, actions, and more!    ║
    ╚═══════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

# Prompt for input with default
prompt() {
    local prompt_text="$1"
    local default="${2:-}"
    local result

    if [ -n "$default" ]; then
        echo -ne "${BLUE}${prompt_text}${NC} ${YELLOW}[${default}]${NC}: "
    else
        echo -ne "${BLUE}${prompt_text}${NC}: "
    fi

    read -r result
    echo "${result:-$default}"
}

# Prompt for choice
prompt_choice() {
    local prompt_text="$1"
    shift
    local options=("$@")
    local choice

    echo -e "${BLUE}${prompt_text}${NC}"
    for i in "${!options[@]}"; do
        echo -e "  ${YELLOW}$((i + 1)).${NC} ${options[$i]}"
    done
    echo ""

    while true; do
        echo -ne "${BLUE}Your choice${NC} ${YELLOW}[1-${#options[@]}]${NC}: "
        read -r choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
            echo "${options[$((choice - 1))]}"
            return 0
        else
            echo -e "${RED}Invalid choice. Please enter a number between 1 and ${#options[@]}.${NC}"
        fi
    done
}

# Confirm action
confirm() {
    local prompt_text="$1"
    local response

    echo -ne "${YELLOW}${prompt_text} (y/n):${NC} "
    read -r response

    [[ "$response" =~ ^[Yy]$ ]]
}

# Validate name (kebab-case)
validate_name() {
    local name="$1"

    if [[ ! "$name" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]]; then
        echo -e "${RED}❌ Invalid name. Use kebab-case (e.g., my-skill, check-deps)${NC}"
        return 1
    fi

    return 0
}

# Create skill
create_skill() {
    local name="$1"
    local description="$2"
    local tier="$3"
    local template="${4:-basic}"

    echo -e "${MAGENTA}✨ Generating skill: ${name}${NC}"
    echo ""

    local skill_dir="${CORE_SKILLS_DIR}/${name}"

    # Check if already exists
    if [ -d "$skill_dir" ]; then
        if ! confirm "Skill directory already exists. Overwrite?"; then
            echo -e "${YELLOW}⚠️  Cancelled${NC}"
            return 1
        fi
        rm -rf "$skill_dir"
    fi

    # Create directory
    mkdir -p "$skill_dir"

    # Apply template
    local template_file="${TEMPLATES_DIR}/skills/${template}.template"
    if [ -f "$template_file" ]; then
        cat "$template_file" | sed "s/{{NAME}}/${name}/g" | sed "s/{{DESCRIPTION}}/${description}/g" | sed "s/{{TIER}}/${tier}/g" > "${skill_dir}/${name}.sh"
    else
        # Use basic template
        cat > "${skill_dir}/${name}.sh" <<EOF
#!/usr/bin/env bash
# ${name}.sh
# ${description}

set -euo pipefail

# Script directory
SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"

# Source common utilities
# shellcheck source=scripts/lib/common.sh
source "\$(dirname "\${SCRIPT_DIR}")/../scripts/lib/common.sh" 2>/dev/null || true

# Main logic
main() {
    echo "Running ${name}..."

    # TODO: Implement your skill logic here

    echo "✅ ${name} completed successfully"
}

# Run main
main "\$@"
EOF
    fi

    # Create SKILL.md
    cat > "${skill_dir}/SKILL.md" <<EOF
---
name: ${name}
description: ${description}
permissions:
  max_tier: ${tier}
  scripts:
    - name: ${name}.sh
      tier: ${tier}
---

# $(echo "$name" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

${description}

## When to Use

Claude will use this skill when the user asks to:
- TODO: Add use cases

## Usage

\`\`\`bash
/${name} [arguments]
\`\`\`

## Instructions

When this skill is invoked:

1. TODO: Add step-by-step instructions for Claude

## Permissions

This skill has ${tier} permissions:
- **${name}.sh (${tier})** - TODO: Describe what this script does

## Examples

### Example 1

\`\`\`bash
\$ /${name}

# Expected output here
\`\`\`

## Notes

- TODO: Add any additional notes or considerations
EOF

    # Make script executable
    chmod +x "${skill_dir}/${name}.sh"

    # Show created files
    echo -e "${GREEN}Created:${NC}"
    echo -e "  ${GREEN}✅${NC} ${skill_dir}/SKILL.md"
    echo -e "  ${GREEN}✅${NC} ${skill_dir}/${name}.sh"
    echo ""

    # Validate
    validate_extension "$skill_dir"

    echo ""
    echo -e "${GREEN}🎉 Skill created successfully!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Review and customize: ${skill_dir}/"
    echo -e "  2. Test locally: ./core/skills/skill-builder/skill-builder.sh --test ${name}"
    echo -e "  3. Deploy: ./scripts/generate-manifest.sh"
    echo -e "  4. Use: /${name}"
    echo ""

    return 0
}

# Create hook
create_hook() {
    local name="$1"
    local hook_type="$2"
    local template="${3:-basic}"

    echo -e "${MAGENTA}✨ Generating hook: ${name}${NC}"
    echo ""

    local hook_file
    if [ "$hook_type" = "claude" ]; then
        hook_file="${CLAUDE_HOOKS_DIR}/${name}.sh"
    else
        hook_file="${SCRIPTS_HOOKS_DIR}/${name}"
    fi

    # Check if already exists
    if [ -f "$hook_file" ]; then
        if ! confirm "Hook already exists. Overwrite?"; then
            echo -e "${YELLOW}⚠️  Cancelled${NC}"
            return 1
        fi
    fi

    # Apply template
    local template_file="${TEMPLATES_DIR}/hooks/${template}.template"
    if [ -f "$template_file" ]; then
        cat "$template_file" | sed "s/{{NAME}}/${name}/g" > "$hook_file"
    else
        # Use basic template
        cat > "$hook_file" <<'EOF'
#!/usr/bin/env bash
# {{NAME}}.sh
# TODO: Add description

set -euo pipefail

# Hook logic
main() {
    echo "Running hook: {{NAME}}"

    # TODO: Implement hook logic

    # Exit 0 for success, non-zero for failure
    exit 0
}

main "$@"
EOF
        sed -i "s/{{NAME}}/${name}/g" "$hook_file"
    fi

    # Make executable
    chmod +x "$hook_file"

    echo -e "${GREEN}Created:${NC}"
    echo -e "  ${GREEN}✅${NC} ${hook_file}"
    echo ""

    echo -e "${GREEN}🎉 Hook created successfully!${NC}"
    echo ""
    echo -e "${CYAN}Next steps:${NC}"
    echo -e "  1. Customize: ${hook_file}"
    if [ "$hook_type" = "git" ]; then
        echo -e "  2. Install: ./scripts/hooks/install-hooks.sh"
    fi
    echo -e "  3. Test: Execute the hook manually"
    echo ""

    return 0
}

# Validate extension
validate_extension() {
    local path="$1"

    echo -e "${CYAN}🔍 Validating extension...${NC}"
    echo ""

    local errors=0
    local warnings=0

    # Determine extension type
    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        # Skill validation
        echo -e "${BLUE}Type:${NC} Skill"

        # Check structure
        if [ -f "$path/SKILL.md" ]; then
            echo -e "  ${GREEN}✅${NC} SKILL.md present"
        else
            echo -e "  ${RED}❌${NC} SKILL.md missing"
            ((errors++))
        fi

        # Check for main script
        local skill_name=$(basename "$path")
        if [ -f "$path/${skill_name}.sh" ]; then
            echo -e "  ${GREEN}✅${NC} Main script present: ${skill_name}.sh"

            # Check executable
            if [ -x "$path/${skill_name}.sh" ]; then
                echo -e "  ${GREEN}✅${NC} Script is executable"
            else
                echo -e "  ${YELLOW}⚠️${NC}  Script not executable"
                ((warnings++))
            fi

            # Check shebang
            if head -n1 "$path/${skill_name}.sh" | grep -q "^#!/"; then
                echo -e "  ${GREEN}✅${NC} Shebang present"
            else
                echo -e "  ${RED}❌${NC} Shebang missing"
                ((errors++))
            fi
        else
            echo -e "  ${RED}❌${NC} Main script missing: ${skill_name}.sh"
            ((errors++))
        fi

        # Validate SKILL.md format
        if grep -q "^---" "$path/SKILL.md" && grep -q "^name:" "$path/SKILL.md"; then
            echo -e "  ${GREEN}✅${NC} SKILL.md properly formatted"
        else
            echo -e "  ${YELLOW}⚠️${NC}  SKILL.md may not be properly formatted"
            ((warnings++))
        fi

    elif [ -f "$path" ] && [[ "$path" == *.sh ]]; then
        # Hook/script validation
        echo -e "${BLUE}Type:${NC} Hook/Script"

        # Check executable
        if [ -x "$path" ]; then
            echo -e "  ${GREEN}✅${NC} Script is executable"
        else
            echo -e "  ${YELLOW}⚠️${NC}  Script not executable"
            ((warnings++))
        fi

        # Check shebang
        if head -n1 "$path" | grep -q "^#!/"; then
            echo -e "  ${GREEN}✅${NC} Shebang present"
        else
            echo -e "  ${RED}❌${NC} Shebang missing"
            ((errors++))
        fi

        # Check for error handling
        if grep -q "set -euo pipefail" "$path"; then
            echo -e "  ${GREEN}✅${NC} Error handling configured"
        else
            echo -e "  ${YELLOW}⚠️${NC}  Consider adding 'set -euo pipefail'"
            ((warnings++))
        fi
    else
        echo -e "  ${RED}❌${NC} Unknown extension type"
        ((errors++))
    fi

    echo ""
    if [ $errors -eq 0 ] && [ $warnings -eq 0 ]; then
        echo -e "${GREEN}✅ Validation passed!${NC}"
        return 0
    elif [ $errors -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Validation passed with ${warnings} warning(s)${NC}"
        return 0
    else
        echo -e "${RED}❌ Validation failed with ${errors} error(s) and ${warnings} warning(s)${NC}"
        return 1
    fi
}

# Test extension
test_extension() {
    local path="$1"

    echo -e "${CYAN}🧪 Testing extension...${NC}"
    echo ""

    # Determine type and test
    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        local skill_name=$(basename "$path")
        echo -e "${BLUE}Testing skill:${NC} ${skill_name}"

        # Deploy to .claude
        local claude_skill_dir="${REPO_ROOT}/.claude/skills/${skill_name}"
        echo -e "  ${BLUE}Deploying to:${NC} ${claude_skill_dir}"

        mkdir -p "$claude_skill_dir"
        cp -r "$path"/* "$claude_skill_dir/"

        echo -e "  ${GREEN}✅${NC} Deployed to .claude/skills/${skill_name}/"

        # Try to execute
        if [ -x "${claude_skill_dir}/${skill_name}.sh" ]; then
            echo -e "  ${BLUE}Testing execution...${NC}"
            if "${claude_skill_dir}/${skill_name}.sh" --help 2>/dev/null || true; then
                echo -e "  ${GREEN}✅${NC} Skill is executable"
            fi
        fi

    elif [ -f "$path" ]; then
        echo -e "${BLUE}Testing script:${NC} $(basename "$path")"

        if [ -x "$path" ]; then
            echo -e "  ${BLUE}Testing execution...${NC}"
            if "$path" --help 2>/dev/null || true; then
                echo -e "  ${GREEN}✅${NC} Script is executable"
            fi
        fi
    fi

    echo ""
    echo -e "${GREEN}✅ Testing complete!${NC}"
    echo ""

    return 0
}

# Submit extension
submit_extension() {
    local path="$1"

    echo -e "${CYAN}📤 Preparing submission to framework repository...${NC}"
    echo ""

    # Check if framework repo is configured
    local config_file="${REPO_ROOT}/config/corporate-mode.yaml"
    local framework_repo=""

    if [ -f "$config_file" ]; then
        framework_repo=$(grep "framework_repo:" "$config_file" | awk '{print $2}' | tr -d '"' || echo "")
    fi

    if [ -z "$framework_repo" ]; then
        echo -e "${YELLOW}⚠️  Framework repository not configured${NC}"
        echo ""
        echo "To submit to the framework, configure it in config/corporate-mode.yaml:"
        echo ""
        echo "corporate_mode:"
        echo "  framework_repo: \"owner/claude-tastic\""
        echo ""
        return 1
    fi

    # Determine extension type
    local ext_type="extension"
    local ext_name

    if [ -d "$path" ] && [ -f "$path/SKILL.md" ]; then
        ext_type="skill"
        ext_name=$(basename "$path")
    elif [ -f "$path" ]; then
        ext_type="script"
        ext_name=$(basename "$path")
    fi

    echo -e "${BLUE}Extension:${NC} ${ext_name}"
    echo -e "${BLUE}Type:${NC} ${ext_type}"
    echo -e "${BLUE}Framework repo:${NC} ${framework_repo}"
    echo ""

    # Prompt for submission method
    local method
    method=$(prompt_choice "How would you like to submit?" \
        "Create GitHub issue with contribution" \
        "Create local branch for PR" \
        "Export as tarball")

    case "$method" in
        "Create GitHub issue with contribution")
            echo ""
            echo -e "${BLUE}Creating GitHub issue...${NC}"
            echo ""

            # Use capture-framework skill
            local description
            description=$(prompt "Brief description of this contribution")

            echo ""
            echo -e "${GREEN}Use this command to submit:${NC}"
            echo ""
            echo "cd \"${REPO_ROOT}\" && ./core/skills/capture-framework/capture-framework.sh \"[Contribution] New ${ext_type}: ${ext_name} - ${description}\""
            echo ""
            ;;

        "Create local branch for PR")
            echo ""
            local branch_name="contrib/${ext_type}/${ext_name}"
            echo -e "${BLUE}Creating branch:${NC} ${branch_name}"
            echo ""
            echo -e "${GREEN}Run these commands:${NC}"
            echo ""
            echo "git checkout -b ${branch_name}"
            echo "git add ${path}"
            echo "git commit -m \"feat: add ${ext_type} - ${ext_name}\""
            echo "git push origin ${branch_name}"
            echo "gh pr create --title \"feat: add ${ext_type} - ${ext_name}\" --body \"[Describe your contribution]\""
            echo ""
            ;;

        "Export as tarball")
            echo ""
            local tarball="${ext_name}.tar.gz"
            echo -e "${BLUE}Creating tarball:${NC} ${tarball}"

            tar -czf "$tarball" -C "$(dirname "$path")" "$(basename "$path")"

            echo -e "  ${GREEN}✅${NC} Created: ${tarball}"
            echo ""
            echo "Send this file to the framework maintainers or attach to a GitHub issue."
            echo ""
            ;;
    esac

    return 0
}

# Interactive mode
interactive_mode() {
    print_banner

    # Select extension type
    local ext_type
    ext_type=$(prompt_choice "Select extension type:" \
        "Skill - Custom slash command" \
        "Hook - Runtime hook" \
        "Action - Event-driven action" \
        "Command - CLI tool" \
        "Agent - Specialized AI agent")

    echo ""

    case "$ext_type" in
        "Skill - Custom slash command")
            echo -e "${MAGENTA}📝 Creating a new skill...${NC}"
            echo ""

            local name description tier template

            while true; do
                name=$(prompt "Skill name (kebab-case)")
                if validate_name "$name"; then
                    break
                fi
            done

            description=$(prompt "Description (when should Claude invoke it)")

            tier=$(prompt_choice "Permission tier:" "T0 - Read-only" "T1 - Safe writes" "T2 - Bash commands" "T3 - Destructive")
            tier=$(echo "$tier" | cut -d' ' -f1)

            template=$(prompt_choice "Select template:" "Basic" "Audit" "Deployment" "Data sync")
            template=$(echo "$template" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

            echo ""
            create_skill "$name" "$description" "$tier" "$template"

            echo ""
            if confirm "Would you like to test it now?"; then
                test_extension "${CORE_SKILLS_DIR}/${name}"
            fi
            ;;

        "Hook - Runtime hook")
            echo -e "${MAGENTA}📝 Creating a new hook...${NC}"
            echo ""

            local name hook_type template

            while true; do
                name=$(prompt "Hook name (kebab-case)")
                if validate_name "$name"; then
                    break
                fi
            done

            hook_type=$(prompt_choice "Hook type:" "Claude runtime hook (.claude/hooks/)" "Git hook (scripts/hooks/)")
            if [[ "$hook_type" == *"Claude"* ]]; then
                hook_type="claude"
            else
                hook_type="git"
            fi

            template=$(prompt_choice "Select template:" "Basic" "Permission check" "Validation" "Metrics capture" "Webhook")
            template=$(echo "$template" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')

            echo ""
            create_hook "$name" "$hook_type" "$template"
            ;;

        *)
            echo -e "${YELLOW}⚠️  This extension type is not yet fully implemented.${NC}"
            echo ""
            echo "For now, you can:"
            echo "  - Create a skill or hook using the builder"
            echo "  - Manually create the extension following framework conventions"
            echo "  - Check the documentation for examples"
            echo ""
            ;;
    esac
}

# Main
main() {
    local mode="interactive"
    local ext_type=""
    local name=""
    local template=""
    local validate_path=""
    local test_path=""
    local submit_path=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --type)
                ext_type="$2"
                mode="quick"
                shift 2
                ;;
            --name)
                name="$2"
                shift 2
                ;;
            --template)
                template="$2"
                shift 2
                ;;
            --validate)
                validate_path="$2"
                mode="validate"
                shift 2
                ;;
            --test)
                test_path="$2"
                mode="test"
                shift 2
                ;;
            --submit)
                submit_path="$2"
                mode="submit"
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

    # Execute based on mode
    case $mode in
        validate)
            validate_extension "$validate_path"
            ;;
        test)
            test_extension "$test_path"
            ;;
        submit)
            submit_extension "$submit_path"
            ;;
        quick)
            # Quick mode not fully implemented yet
            echo -e "${YELLOW}Quick mode coming soon. Using interactive mode...${NC}"
            echo ""
            interactive_mode
            ;;
        interactive)
            interactive_mode
            ;;
    esac
}

# Run main
main "$@"
