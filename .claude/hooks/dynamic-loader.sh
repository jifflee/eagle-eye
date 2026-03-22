#!/bin/bash
# dynamic-loader.sh
# UserPromptSubmit hook that dynamically loads relevant agent context
#
# Instead of loading all 27 agents into context for every prompt,
# this hook analyzes the prompt and injects only relevant agent definitions.
#
# Input: JSON via stdin with { prompt, session_id, ... }
# Output: JSON to stdout with { result: "..." } if agents matched
# Exit: 0 = allow prompt to proceed
#
# IMPORTANT: This hook must ALWAYS exit 0. It should never block prompt processing.
# Errors are silently ignored so new/consumer repos without full deployment work fine.

# Use pipefail but NOT -e: this hook must never exit non-zero
# -u helps catch bugs but we trap it for safety
set -uo pipefail

# Trap any unexpected error and exit cleanly — hook must never block prompts
trap 'exit 0' ERR

# Get project root
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
AGENTS_DIR="$PROJECT_ROOT/.claude/agents"

# Read JSON from stdin
json_input=$(cat)

# Extract prompt text
prompt=$(echo "$json_input" | jq -r '.prompt // ""' 2>/dev/null || echo "")

# Exit early if no prompt or agents dir missing
if [ -z "$prompt" ] || [ ! -d "$AGENTS_DIR" ]; then
  exit 0
fi

prompt_lower=$(echo "$prompt" | tr '[:upper:]' '[:lower:]')

# Build list of agents to load based on keyword matching
agents_to_load=""

match_agent() {
  local keyword="$1"
  local agent_file="$2"
  if echo "$prompt_lower" | grep -qi "$keyword"; then
    if [ -f "$AGENTS_DIR/$agent_file" ] && ! echo "$agents_to_load" | grep -q "$agent_file"; then
      agents_to_load="${agents_to_load}${agent_file}\n"
    fi
  fi
}

# Architecture & design
match_agent "architect" "architect.md"
match_agent "architecture" "architect.md"
match_agent "design" "architect.md"

# Development
match_agent "backend" "backend-developer.md"
match_agent "frontend" "frontend-developer.md"
match_agent "api" "api-designer.md"

# Security
match_agent "security" "security-iam-design.md"
match_agent "iam" "security-iam-design.md"
match_agent "vulnerab" "security-iam-design.md"

# Testing
match_agent "test" "test-qa.md"
match_agent "qa" "test-qa.md"

# Code quality
match_agent "review" "pr-code-reviewer.md"
match_agent "refactor" "refactoring-specialist.md"
match_agent "bug" "bug.md"
match_agent "debug" "bug.md"

# Infrastructure
match_agent "deploy" "deployment.md"
match_agent "cicd" "cicd-workflow.md"
match_agent "pipeline" "cicd-workflow.md"

# Data
match_agent "database" "data-storage.md"
match_agent "schema" "data-storage.md"
match_agent "migration" "database-migration.md"

# Documentation
match_agent "documentation" "documentation.md"
match_agent "docs" "documentation.md"

# Performance & dependencies
match_agent "performance" "performance-engineering.md"
match_agent "optimiz" "performance-engineering.md"
match_agent "dependency" "dependency-manager.md"

# Governance
match_agent "guardrails" "guardrails-policy.md"
match_agent "policy" "guardrails-policy.md"
match_agent "milestone" "milestone-manager.md"

# PM
match_agent "orchestrat" "pm-orchestrator.md"
match_agent "coordinate" "pm-orchestrator.md"

# If no agents matched, exit silently
if [ -z "$agents_to_load" ]; then
  exit 0
fi

# Count matched agents
agent_count=$(echo -e "$agents_to_load" | grep -c "\.md$" || echo "0")

# Output result (Claude Code uses the result field as additional context)
jq -nc --arg count "$agent_count" \
  '{"result": ("Dynamic loader: " + $count + " relevant agent definition(s) available in .claude/agents/")}'

exit 0
