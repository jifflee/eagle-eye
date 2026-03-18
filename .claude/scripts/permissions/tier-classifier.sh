#!/bin/bash
# tier-classifier.sh
# Classify operations into permission tiers (T0-T3)
# Part of the Permission Decision Engine (Issue #596)
#
# Tiers:
#   T0 - Read-only (auto-allow): No state change
#   T1 - Safe write (auto-allow): Easily reversible
#   T2 - Reversible write (policy-check): State-changing but reversible
#   T3 - Destructive (deny/escalate): Irreversible operations
#
# Usage:
#   ./scripts/permissions/tier-classifier.sh --tool <tool> --input <json>
#   echo '{"tool":"Bash","command":"git status"}' | ./scripts/permissions/tier-classifier.sh
#
# Output: JSON with tier and reason

set -euo pipefail

# Read input from stdin or args
if [ -t 0 ]; then
    # Interactive - parse args
    TOOL=""
    INPUT=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tool) TOOL="$2"; shift 2 ;;
            --input) INPUT="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
else
    # Piped input
    INPUT=$(cat)
    TOOL=$(echo "$INPUT" | jq -r '.tool // .tool_name // ""')
fi

COMMAND=$(echo "$INPUT" | jq -r '.command // .tool_input.command // ""' 2>/dev/null || echo "")
FILE_PATH=$(echo "$INPUT" | jq -r '.file_path // .tool_input.file_path // ""' 2>/dev/null || echo "")

# Classify based on tool and operation
classify_tier() {
    local tool="$1"
    local command="$2"
    local file_path="$3"

    case "$tool" in
        # T0: Read-only tools
        Read|Glob|Grep|WebSearch|WebFetch)
            echo '{"tier":"T0","reason":"read-only tool"}'
            return
            ;;

        # T1: Safe write tools (easily reversible via git)
        Edit|Write)
            # Check if it's a sensitive file
            if [[ "$file_path" =~ \.(env|key|pem|secret|credential)$ ]]; then
                echo '{"tier":"T3","reason":"sensitive file type"}'
            elif [[ "$file_path" =~ ^(/etc/|/usr/|/var/) ]]; then
                echo '{"tier":"T3","reason":"system directory"}'
            else
                echo '{"tier":"T1","reason":"file edit (git-reversible)"}'
            fi
            return
            ;;

        # Bash: Classify based on command
        Bash)
            classify_bash_command "$command"
            return
            ;;

        # Task/Agent tools
        Task)
            echo '{"tier":"T2","reason":"agent delegation"}'
            return
            ;;

        # Unknown tools - conservative
        *)
            echo '{"tier":"T2","reason":"unknown tool - policy check required"}'
            return
            ;;
    esac
}

# Classify Bash commands
classify_bash_command() {
    local cmd="$1"

    # T0: Pure read commands
    if [[ "$cmd" =~ ^(ls|pwd|whoami|date|env|which|cat|head|tail|less|more|wc|file|stat|id|groups|hostname|uname|echo|printf)([[:space:]]|$) ]]; then
        echo '{"tier":"T0","reason":"read-only bash command"}'
        return
    fi

    # T0: Git read commands
    if [[ "$cmd" =~ ^git[[:space:]]+(status|log|diff|branch|show|blame|tag|remote|config\ --get|ls-files|rev-parse)([[:space:]]|$) ]]; then
        echo '{"tier":"T0","reason":"git read command"}'
        return
    fi

    # T1: Safe git writes (easily reversible)
    if [[ "$cmd" =~ ^git[[:space:]]+(add|commit|checkout|stash|reset\ --soft|branch\ -[dD])([[:space:]]|$) ]]; then
        echo '{"tier":"T1","reason":"git safe write (reversible)"}'
        return
    fi

    # T1: Package manager read/safe commands
    if [[ "$cmd" =~ ^(npm|yarn|pnpm)[[:space:]]+(list|ls|outdated|audit|info|view|search|run\ test|run\ lint|run\ build)([[:space:]]|$) ]]; then
        echo '{"tier":"T1","reason":"package manager safe command"}'
        return
    fi

    # T2: Git push (reversible but state-changing)
    if [[ "$cmd" =~ ^git[[:space:]]+push([[:space:]]|$) ]] && [[ ! "$cmd" =~ --force ]]; then
        echo '{"tier":"T2","reason":"git push (state-changing)"}'
        return
    fi

    # T2: Package install (reversible)
    if [[ "$cmd" =~ ^(npm|yarn|pnpm)[[:space:]]+(install|add|remove|uninstall)([[:space:]]|$) ]]; then
        echo '{"tier":"T2","reason":"package manager install"}'
        return
    fi

    # T2: gh CLI (API operations)
    if [[ "$cmd" =~ ^gh[[:space:]]+(issue|pr|api|repo)([[:space:]]|$) ]]; then
        echo '{"tier":"T2","reason":"github cli operation"}'
        return
    fi

    # T2: File operations (reversible with git)
    if [[ "$cmd" =~ ^(mkdir|touch|cp|mv)([[:space:]]|$) ]]; then
        echo '{"tier":"T2","reason":"file operation (git-reversible)"}'
        return
    fi

    # T3: Destructive commands
    if [[ "$cmd" =~ (rm[[:space:]]+-rf|rm[[:space:]]+-r[[:space:]]|rmdir|truncate|shred) ]]; then
        echo '{"tier":"T3","reason":"destructive file operation"}'
        return
    fi

    # T3: Force push
    if [[ "$cmd" =~ git[[:space:]]+push[[:space:]]+.*--force ]]; then
        echo '{"tier":"T3","reason":"git force push"}'
        return
    fi

    # T3: Network operations (potential exfiltration)
    if [[ "$cmd" =~ ^(curl|wget|nc|netcat|ssh|scp|rsync|ftp)([[:space:]]|$) ]]; then
        echo '{"tier":"T3","reason":"network operation"}'
        return
    fi

    # T3: Privilege escalation
    if [[ "$cmd" =~ ^(sudo|su|doas|pkexec)([[:space:]]|$) ]]; then
        echo '{"tier":"T3","reason":"privilege escalation"}'
        return
    fi

    # T3: System modification
    if [[ "$cmd" =~ ^(apt|yum|dnf|brew|pacman|systemctl|service)([[:space:]]|$) ]]; then
        echo '{"tier":"T3","reason":"system modification"}'
        return
    fi

    # T3: Database operations
    if [[ "$cmd" =~ (DROP|DELETE|TRUNCATE|ALTER)[[:space:]] ]]; then
        echo '{"tier":"T3","reason":"destructive database operation"}'
        return
    fi

    # Default: T2 for unknown commands (require policy check)
    echo '{"tier":"T2","reason":"unknown command - policy check required"}'
}

# Main
RESULT=$(classify_tier "$TOOL" "$COMMAND" "$FILE_PATH")
echo "$RESULT"
