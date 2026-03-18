#!/bin/bash
# repo-deploy-review-data.sh
# Comprehensive CLAUDE.md quality analysis with scoring across 8 dimensions
# Part of /repo-deploy-review skill (READ-ONLY)
set -euo pipefail

CLAUDE_MD_PATH="${1:-CLAUDE.md}"
FRAMEWORK_TEMPLATE="${2:-repo-template/CLAUDE.md}"

# Check if CLAUDE.md exists
if [[ ! -f "$CLAUDE_MD_PATH" ]]; then
  echo '{"exists":false,"migration_needed":false}'
  exit 0
fi

# Basic file stats
FILE_SIZE=$(wc -l < "$CLAUDE_MD_PATH" 2>/dev/null || echo 0)
FILE_CONTENT=$(cat "$CLAUDE_MD_PATH")

# Extract sections
SECTIONS=$(echo "$FILE_CONTENT" | grep '^#' | sed 's/^#* //' | jq -R . | jq -s . || echo '[]')

# Initialize scores (0-100 for each dimension)
SCORE_STRUCTURE=0
SCORE_AGENT_CONFIG=0
SCORE_SDLC_WORKFLOW=0
SCORE_SECURITY_RULES=0
SCORE_PERMISSIONS=0
SCORE_MODEL_SELECTION=0
SCORE_ESCALATION=0
SCORE_COMMIT_STRATEGY=0

# Arrays for findings
GAPS=()
CONFLICTS=()
CUSTOMIZATIONS=()
MERGE_SECTIONS=()
ADD_SECTIONS=()
CONFLICT_SECTIONS=()
PRESERVE_SECTIONS=()
RECOMMENDATIONS=()

#############################################
# 1. STRUCTURE SCORING (0-100)
#############################################

# Has clear sections (+20)
SECTION_COUNT=$(echo "$SECTIONS" | jq length)
if [[ $SECTION_COUNT -ge 5 ]]; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 20))
elif [[ $SECTION_COUNT -ge 3 ]]; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 10))
fi

# Has table of contents (+15)
if echo "$FILE_CONTENT" | grep -qi "table of contents\|## contents"; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 15))
fi

# Proper markdown formatting (+15)
if echo "$FILE_CONTENT" | grep -q '^```'; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 10))
fi
if echo "$FILE_CONTENT" | grep -q '^|.*|.*|'; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 5))
fi

# Logical organization (+20)
if echo "$FILE_CONTENT" | grep -qi "purpose\|overview\|introduction"; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 10))
fi
if echo "$FILE_CONTENT" | grep -qi "reference\|see also\|links"; then
  SCORE_STRUCTURE=$((SCORE_STRUCTURE + 10))
fi

# Section completeness (+30)
EXPECTED_SECTIONS=("agent" "workflow" "security" "standard")
FOUND_SECTION_COUNT=0
for section in "${EXPECTED_SECTIONS[@]}"; do
  if echo "$FILE_CONTENT" | grep -qi "$section"; then
    FOUND_SECTION_COUNT=$((FOUND_SECTION_COUNT + 1))
  fi
done
SCORE_STRUCTURE=$((SCORE_STRUCTURE + (FOUND_SECTION_COUNT * 7)))

#############################################
# 2. AGENT CONFIGURATION SCORING (0-100)
#############################################

# Agents defined (+25)
if echo "$FILE_CONTENT" | grep -qi "agent"; then
  SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 15))

  # Count agent definitions (count lines mentioning agent)
  AGENT_COUNT=$(echo "$FILE_CONTENT" | grep -i "agent" | wc -l 2>/dev/null || echo 0)
  if [[ $AGENT_COUNT -ge 5 ]]; then
    SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 10))
  fi
else
  GAPS+=("No agent definitions found")
fi

# Roles specified (+20)
if echo "$FILE_CONTENT" | grep -qi "role\|responsibility\|purpose"; then
  SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 20))
fi

# Models assigned (+20)
if echo "$FILE_CONTENT" | grep -qi "haiku\|sonnet\|opus"; then
  SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 20))
else
  GAPS+=("No model assignments (haiku/sonnet/opus) specified")
fi

# Permissions defined (+20)
if echo "$FILE_CONTENT" | grep -qi "permission\|read-only\|write"; then
  SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 20))
else
  GAPS+=("Missing permission boundaries (READ-ONLY vs WRITE-FULL)")
fi

# Delegation rules (+15)
if echo "$FILE_CONTENT" | grep -qi "delegate\|routing\|orchestrat"; then
  SCORE_AGENT_CONFIG=$((SCORE_AGENT_CONFIG + 15))
fi

#############################################
# 3. SDLC WORKFLOW SCORING (0-100)
#############################################

# Workflow phases defined (+25)
if echo "$FILE_CONTENT" | grep -qi "workflow\|process\|sdlc"; then
  SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 15))

  # Multiple phases (count each separately and sum)
  PHASE_COUNT=0
  echo "$FILE_CONTENT" | grep -qi "phase" && PHASE_COUNT=$((PHASE_COUNT + 1))
  echo "$FILE_CONTENT" | grep -qi "step" && PHASE_COUNT=$((PHASE_COUNT + 1))
  echo "$FILE_CONTENT" | grep -qi "stage" && PHASE_COUNT=$((PHASE_COUNT + 1))
  if [[ $PHASE_COUNT -ge 2 ]]; then
    SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 10))
  fi
else
  GAPS+=("SDLC workflow not clearly defined")
fi

# Phase transitions clear (+20)
if echo "$FILE_CONTENT" | grep -qi "transition\|gate\|checkpoint"; then
  SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 20))
fi

# Micro-task pattern (+20)
if echo "$FILE_CONTENT" | grep -qi "micro-task\|atomic\|small task"; then
  SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 20))
else
  GAPS+=("No micro-task pattern defined")
fi

# Gates and checks (+20)
if echo "$FILE_CONTENT" | grep -qi "gate\|check\|validation"; then
  SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 20))
fi

# Error handling (+15)
if echo "$FILE_CONTENT" | grep -qi "error\|failure\|rollback"; then
  SCORE_SDLC_WORKFLOW=$((SCORE_SDLC_WORKFLOW + 15))
fi

#############################################
# 4. SECURITY RULES SCORING (0-100)
#############################################

# Secrets management (+25)
if echo "$FILE_CONTENT" | grep -qi "secret\|credential\|api key\|password"; then
  SCORE_SECURITY_RULES=$((SCORE_SECURITY_RULES + 25))
else
  GAPS+=("No secrets management rules defined")
fi

# Pre-commit checks (+20)
if echo "$FILE_CONTENT" | grep -qi "pre-commit\|commit hook\|before commit"; then
  SCORE_SECURITY_RULES=$((SCORE_SECURITY_RULES + 20))
fi

# Security hooks (+20)
if echo "$FILE_CONTENT" | grep -qi "security hook\|security check\|security scan"; then
  SCORE_SECURITY_RULES=$((SCORE_SECURITY_RULES + 20))
fi

# IAM rules (+20)
if echo "$FILE_CONTENT" | grep -qi "iam\|identity\|authentication\|authorization"; then
  SCORE_SECURITY_RULES=$((SCORE_SECURITY_RULES + 20))
fi

# Audit logging (+15)
if echo "$FILE_CONTENT" | grep -qi "audit\|logging\|tracking"; then
  SCORE_SECURITY_RULES=$((SCORE_SECURITY_RULES + 15))
fi

#############################################
# 5. PERMISSIONS SCORING (0-100)
#############################################

# T0/T1/T2/T3 defined (+30)
if echo "$FILE_CONTENT" | grep -qi "t0\|t1\|t2\|t3\|tier"; then
  SCORE_PERMISSIONS=$((SCORE_PERMISSIONS + 30))
else
  GAPS+=("No T0/T1/T2/T3 permission tier system defined")
fi

# Boundaries clear (+25)
if echo "$FILE_CONTENT" | grep -qi "boundary\|read-only\|write-only"; then
  SCORE_PERMISSIONS=$((SCORE_PERMISSIONS + 25))
fi

# Tool classification (+20)
if echo "$FILE_CONTENT" | grep -qi "tool classification\|operation tier"; then
  SCORE_PERMISSIONS=$((SCORE_PERMISSIONS + 20))
fi

# Escalation triggers (+15)
if echo "$FILE_CONTENT" | grep -qi "escalat\|approval\|prompt"; then
  SCORE_PERMISSIONS=$((SCORE_PERMISSIONS + 15))
fi

# Reversal procedures (+10)
if echo "$FILE_CONTENT" | grep -qi "reversal\|undo\|rollback"; then
  SCORE_PERMISSIONS=$((SCORE_PERMISSIONS + 10))
fi

#############################################
# 6. MODEL SELECTION SCORING (0-100)
#############################################

# haiku/sonnet/opus defined (+30)
MODEL_COUNT=0
echo "$FILE_CONTENT" | grep -qi "haiku" && MODEL_COUNT=$((MODEL_COUNT + 1))
echo "$FILE_CONTENT" | grep -qi "sonnet" && MODEL_COUNT=$((MODEL_COUNT + 1))
echo "$FILE_CONTENT" | grep -qi "opus" && MODEL_COUNT=$((MODEL_COUNT + 1))

if [[ $MODEL_COUNT -eq 3 ]]; then
  SCORE_MODEL_SELECTION=$((SCORE_MODEL_SELECTION + 30))
elif [[ $MODEL_COUNT -ge 1 ]]; then
  SCORE_MODEL_SELECTION=$((SCORE_MODEL_SELECTION + 15))
else
  GAPS+=("No model selection strategy defined")
fi

# Cost optimization (+25)
if echo "$FILE_CONTENT" | grep -qi "cost\|optimization\|efficiency"; then
  SCORE_MODEL_SELECTION=$((SCORE_MODEL_SELECTION + 25))
fi

# Task-model mapping (+25)
if echo "$FILE_CONTENT" | grep -qi "task.*model\|model.*task\|mapping"; then
  SCORE_MODEL_SELECTION=$((SCORE_MODEL_SELECTION + 25))
fi

# Performance guidance (+20)
if echo "$FILE_CONTENT" | grep -qi "performance\|latency\|speed"; then
  SCORE_MODEL_SELECTION=$((SCORE_MODEL_SELECTION + 20))
fi

#############################################
# 7. ESCALATION SCORING (0-100)
#############################################

# Paths defined (+30)
if echo "$FILE_CONTENT" | grep -qi "escalation path\|escalate to"; then
  SCORE_ESCALATION=$((SCORE_ESCALATION + 30))
fi

# Agent delegation (+25)
if echo "$FILE_CONTENT" | grep -qi "delegate\|hand off\|route to"; then
  SCORE_ESCALATION=$((SCORE_ESCALATION + 25))
fi

# User approval triggers (+20)
if echo "$FILE_CONTENT" | grep -qi "user approval\|ask user\|prompt user"; then
  SCORE_ESCALATION=$((SCORE_ESCALATION + 20))
fi

# Error recovery (+15)
if echo "$FILE_CONTENT" | grep -qi "error recovery\|failure handling"; then
  SCORE_ESCALATION=$((SCORE_ESCALATION + 15))
fi

# Timeout handling (+10)
if echo "$FILE_CONTENT" | grep -qi "timeout\|deadline\|time limit"; then
  SCORE_ESCALATION=$((SCORE_ESCALATION + 10))
fi

#############################################
# 8. COMMIT STRATEGY SCORING (0-100)
#############################################

# Conventional commits (+25)
if echo "$FILE_CONTENT" | grep -qi "conventional commit\|commit format\|feat:\|fix:"; then
  SCORE_COMMIT_STRATEGY=$((SCORE_COMMIT_STRATEGY + 25))
fi

# Atomic commits (+20)
if echo "$FILE_CONTENT" | grep -qi "atomic\|small commit\|focused commit"; then
  SCORE_COMMIT_STRATEGY=$((SCORE_COMMIT_STRATEGY + 20))
fi

# Co-authorship (+20)
if echo "$FILE_CONTENT" | grep -qi "co-author\|attribution\|claude"; then
  SCORE_COMMIT_STRATEGY=$((SCORE_COMMIT_STRATEGY + 20))
fi

# Message format (+20)
if echo "$FILE_CONTENT" | grep -qi "commit message\|message format"; then
  SCORE_COMMIT_STRATEGY=$((SCORE_COMMIT_STRATEGY + 20))
fi

# Guidelines clear (+15)
if echo "$FILE_CONTENT" | grep -qi "guideline\|convention\|standard"; then
  SCORE_COMMIT_STRATEGY=$((SCORE_COMMIT_STRATEGY + 15))
fi

#############################################
# OVERALL QUALITY SCORE (weighted average)
#############################################

OVERALL_SCORE=$(( (SCORE_STRUCTURE + SCORE_AGENT_CONFIG + SCORE_SDLC_WORKFLOW + SCORE_SECURITY_RULES + SCORE_PERMISSIONS + SCORE_MODEL_SELECTION + SCORE_ESCALATION + SCORE_COMMIT_STRATEGY) / 8 ))

#############################################
# CONFLICT DETECTION
#############################################

# Check for conflicting agent names
if echo "$FILE_CONTENT" | grep -qi "backend-dev\|frontend-dev\|test-agent"; then
  CONFLICTS+=("Agent naming conflicts detected (e.g., 'backend-dev' vs 'backend-developer')")
  CONFLICT_SECTIONS+=("Agent Roster")
fi

# Check for different commit formats
if echo "$FILE_CONTENT" | grep -q "^-.*emoji\|:.*:"; then
  if ! echo "$FILE_CONTENT" | grep -qi "conventional commit"; then
    CONFLICTS+=("Different commit message format (existing uses emoji prefix)")
  fi
fi

#############################################
# CUSTOMIZATION DETECTION
#############################################

# Detect custom sections not in framework template
if [[ -f "$FRAMEWORK_TEMPLATE" ]]; then
  FRAMEWORK_CONTENT=$(cat "$FRAMEWORK_TEMPLATE")

  # Check for unique sections
  if echo "$FILE_CONTENT" | grep -qi "deployment"; then
    if ! echo "$FRAMEWORK_CONTENT" | grep -qi "deployment"; then
      CUSTOMIZATIONS+=("Custom deployment workflow")
      PRESERVE_SECTIONS+=("Custom Deployment")
    fi
  fi

  if echo "$FILE_CONTENT" | grep -qi "team\|convention"; then
    CUSTOMIZATIONS+=("Team-specific conventions and standards")
    PRESERVE_SECTIONS+=("Team Conventions")
  fi
else
  # Framework template not found - detect custom sections anyway
  if echo "$FILE_CONTENT" | grep -qi "deployment"; then
    CUSTOMIZATIONS+=("Custom deployment workflow")
    PRESERVE_SECTIONS+=("Custom Deployment")
  fi

  if echo "$FILE_CONTENT" | grep -qi "team\|convention"; then
    CUSTOMIZATIONS+=("Team-specific conventions and standards")
    PRESERVE_SECTIONS+=("Team Conventions")
  fi
fi

#############################################
# MIGRATION PLAN
#############################################

# Sections to merge (exist in both)
if echo "$FILE_CONTENT" | grep -qi "purpose\|overview"; then
  MERGE_SECTIONS+=("Purpose / Project Overview")
fi

if echo "$FILE_CONTENT" | grep -qi "security"; then
  MERGE_SECTIONS+=("Security Rules")
fi

# Sections to add (missing from existing)
if [[ $SCORE_PERMISSIONS -lt 50 ]]; then
  ADD_SECTIONS+=("Agent Permissions (T0/T1/T2/T3 tier system)")
fi

if [[ $SCORE_MODEL_SELECTION -lt 50 ]]; then
  ADD_SECTIONS+=("Performance Optimization (model selection strategy)")
fi

if ! echo "$FILE_CONTENT" | grep -qi "micro-task"; then
  ADD_SECTIONS+=("Micro-Task Pattern (PM orchestration)")
fi

#############################################
# RECOMMENDATIONS
#############################################

if [[ $SCORE_MODEL_SELECTION -lt 50 ]]; then
  RECOMMENDATIONS+=("Add model selection strategy for cost optimization")
fi

if [[ $SCORE_PERMISSIONS -lt 50 ]]; then
  RECOMMENDATIONS+=("Define permission boundaries using T0/T1/T2/T3 tier system")
fi

if ! echo "$FILE_CONTENT" | grep -qi "micro-task"; then
  RECOMMENDATIONS+=("Add micro-task pattern for PM orchestration")
fi

if [[ $SCORE_AGENT_CONFIG -lt 60 ]]; then
  RECOMMENDATIONS+=("Enhance agent definitions with clear roles and models")
fi

if [[ $SCORE_SECURITY_RULES -lt 70 ]]; then
  RECOMMENDATIONS+=("Strengthen security rules with pre-commit hooks and secret scanning")
fi

#############################################
# BUILD JSON OUTPUT
#############################################

# Helper function to output array as JSON, filtering empty strings
output_json_array() {
    local arr=("$@")
    if [ ${#arr[@]} -eq 0 ]; then
        echo '[]'
    else
        printf '%s\n' "${arr[@]}" | grep -v '^$' | jq -R . | jq -s . 2>/dev/null || echo '[]'
    fi
}

cat <<EOF
{
  "claude_md_analysis": {
    "file_exists": true,
    "line_count": $FILE_SIZE,
    "sections_found": $SECTIONS,
    "quality_score": $OVERALL_SCORE,
    "quality_breakdown": {
      "structure": $SCORE_STRUCTURE,
      "agent_config": $SCORE_AGENT_CONFIG,
      "sdlc_workflow": $SCORE_SDLC_WORKFLOW,
      "security_rules": $SCORE_SECURITY_RULES,
      "permissions": $SCORE_PERMISSIONS,
      "model_selection": $SCORE_MODEL_SELECTION,
      "escalation": $SCORE_ESCALATION,
      "commit_strategy": $SCORE_COMMIT_STRATEGY
    },
    "gaps": $(output_json_array "${GAPS[@]}"),
    "conflicts": $(output_json_array "${CONFLICTS[@]}"),
    "customizations_to_preserve": $(output_json_array "${CUSTOMIZATIONS[@]}"),
    "migration_plan": {
      "merge_sections": $(output_json_array "${MERGE_SECTIONS[@]}"),
      "add_sections": $(output_json_array "${ADD_SECTIONS[@]}"),
      "conflict_sections": $(output_json_array "${CONFLICT_SECTIONS[@]}"),
      "preserve_sections": $(output_json_array "${PRESERVE_SECTIONS[@]}")
    },
    "recommendations": $(output_json_array "${RECOMMENDATIONS[@]}")
  }
}
EOF
