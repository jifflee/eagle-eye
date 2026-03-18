---
description: Review existing CLAUDE.md after framework deployment and generate migration plan (READ-ONLY - query only)
model: opus
deprecated: true
superseded_by: "repo:init-framework with --merge flag (CLAUDE.md generation now integrated)"
---

# Deploy Review

**⚠️ DEPRECATED:** This skill's core functionality has been merged into `/repo:init-framework` and `/local:init`.
Use those skills for CLAUDE.md generation and merging. This skill remains available for standalone analysis only.

**🔒 READ-ONLY OPERATION - This skill NEVER modifies files**

Comprehensive evaluation and review of existing CLAUDE.md when claude-tastic is installed into an existing repo. Uses **opus model** for thorough analysis — CLAUDE.md quality directly impacts all agent behavior.

**CRITICAL SAFEGUARD:**
- This skill ONLY queries data and presents reports
- All recommendations are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work` or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## Usage

**⚠️ Note:** For CLAUDE.md generation during framework initialization, use `/repo:init-framework` or `/local:init` instead.

This skill is now primarily for standalone analysis:

```
/repo-deploy-review    # Analyze existing CLAUDE.md quality (READ-ONLY)
```

For CLAUDE.md generation/merging, use:
```
/repo:init-framework    # Full framework setup with CLAUDE.md generation
/local:init             # Consumer repo setup with CLAUDE.md generation
```

## Model Selection

**Uses opus (best available model)** for CLAUDE.md review because:
- CLAUDE.md is the authoritative guide for all agent behavior
- Quality of this review directly impacts everything else
- This is a critical analysis task, not routine work
- Comprehensive evaluation requires deep reasoning

## Analysis Dimensions

The skill performs comprehensive quality analysis across 8 dimensions:

### 1. Structure Review
- Sections present and organization
- Completeness of documentation
- Logical flow and coherence
- Proper markdown formatting

### 2. Agent Configuration
- Agent definitions with proper roles
- Model assignments (haiku/sonnet/opus)
- Permission boundaries (READ-ONLY vs WRITE-FULL)
- Agent routing and delegation rules

### 3. SDLC Workflow
- Development workflow clearly defined
- Phase transitions and gates
- Micro-task pattern definition
- Escalation paths

### 4. Security Rules
- Security guardrails present and adequate
- Secrets management rules
- Pre-commit security checks
- Security hook definitions

### 5. Permission Boundaries
- READ-ONLY vs WRITE-FULL boundaries defined
- Permission tier system (T0/T1/T2/T3)
- Tool permission classification
- Escalation rules for destructive operations

### 6. Model Selection Strategy
- Model recommendations specified (haiku/sonnet/opus)
- Cost optimization guidance
- Task-to-model mapping
- Performance vs cost tradeoffs

### 7. Escalation Rules
- Clear escalation paths defined
- Agent-to-agent delegation rules
- User approval triggers
- Error handling and recovery

### 8. Commit Strategy
- Commit guidelines present
- Conventional commits format
- Atomic commit guidance
- Co-authorship attribution

## Steps

### 1. Check for Existing CLAUDE.md

Run the data script to gather initial information:

```bash
./scripts/repo-deploy-review-data.sh
```

### 2. Quality Scoring Analysis

The data script performs comprehensive scoring (0-100) across all 8 dimensions:

- **Structure** (0-100): Organization and completeness
- **Agent Config** (0-100): Agent definitions and setup
- **SDLC Workflow** (0-100): Development process clarity
- **Security Rules** (0-100): Security guardrails strength
- **Permissions** (0-100): Permission boundary clarity
- **Model Selection** (0-100): Model strategy completeness
- **Escalation** (0-100): Escalation path clarity
- **Commit Strategy** (0-100): Commit guideline quality

**Overall Quality Score**: Weighted average of all dimensions

### 3. Compatibility Analysis

Compare existing CLAUDE.md against framework template:

**Identify:**
- **Gaps**: Framework sections missing from existing file
- **Conflicts**: Clashing agent names or contradictory rules
- **Customizations**: User-specific content to preserve

**Check Alignment:**
- Framework CLAUDE.md template (`repo-template/CLAUDE.md`)
- Agent roster and naming conventions
- Permission model and tier system
- SDLC sequence and workflow

### 4. Migration Plan Generation

Generate section-by-section merge recommendations:

- **Merge sections**: Combine existing with framework content
- **Add sections**: New framework sections to add
- **Conflict sections**: Sections requiring user resolution
- **Preserve sections**: User customizations to keep

### 5. Generate Report

Create comprehensive analysis report with actionable recommendations.

## Output Format

The skill outputs JSON for programmatic consumption:

```json
{
  "claude_md_analysis": {
    "file_exists": true,
    "line_count": 487,
    "sections_found": ["Purpose", "Agents", "Workflow", "Security"],
    "quality_score": 72,
    "quality_breakdown": {
      "structure": 80,
      "agent_config": 65,
      "sdlc_workflow": 70,
      "security_rules": 85,
      "permissions": 50,
      "model_selection": 40,
      "escalation": 75,
      "commit_strategy": 60
    },
    "gaps": [
      "No model selection strategy defined",
      "Missing permission boundaries (READ-ONLY vs WRITE-FULL)",
      "No micro-task pattern defined"
    ],
    "conflicts": [
      "Agent 'backend-dev' conflicts with framework 'backend-developer'"
    ],
    "customizations_to_preserve": [
      "Custom deployment workflow in section 8",
      "Project-specific security rules in section 5"
    ],
    "migration_plan": {
      "merge_sections": ["Purpose", "Security"],
      "add_sections": ["Performance Optimization", "Agent Permissions"],
      "conflict_sections": ["Agent Roster"],
      "preserve_sections": ["Custom Deployment"]
    },
    "recommendations": [
      "Add model selection strategy for cost optimization",
      "Define permission boundaries using T0/T1/T2/T3 tier system",
      "Add micro-task pattern for PM orchestration"
    ]
  }
}
```

**Human-Readable Report:**

The skill also generates a formatted report for user review:

```markdown
## Deploy Review Report

**Repository:** {name}
**Existing CLAUDE.md:** Yes (487 lines)
**Overall Quality Score:** 72/100

---

### Quality Analysis

| Dimension | Score | Status |
|-----------|-------|--------|
| Structure | 80/100 | ✓ Good |
| Agent Config | 65/100 | ⚠ Needs Work |
| SDLC Workflow | 70/100 | ⚠ Needs Work |
| Security Rules | 85/100 | ✓ Good |
| Permissions | 50/100 | ❌ Poor |
| Model Selection | 40/100 | ❌ Poor |
| Escalation | 75/100 | ✓ Good |
| Commit Strategy | 60/100 | ⚠ Needs Work |

---

### Gaps (Missing from Existing CLAUDE.md)

1. No model selection strategy defined
2. Missing permission boundaries (READ-ONLY vs WRITE-FULL)
3. No micro-task pattern defined
4. No T0/T1/T2/T3 tier system defined

---

### Conflicts (Require Resolution)

1. Agent 'backend-dev' conflicts with framework 'backend-developer'
2. Different commit message format (existing uses emoji prefix)

---

### Customizations to Preserve

1. Custom deployment workflow in section 8
2. Project-specific security rules in section 5
3. Team coding standards and conventions

---

### Migration Plan

**Merge Sections** (combine existing + framework):
- Purpose / Project Overview
- Security Rules (existing + framework additions)

**Add Sections** (new from framework):
- Agent Permissions (T0/T1/T2/T3 tier system)
- Performance Optimization (model selection strategy)
- Micro-Task Pattern (PM orchestration)

**Conflict Sections** (manual resolution required):
- Agent Roster (rename 'backend-dev' → 'backend-developer')

**Preserve Sections** (keep as-is):
- Custom Deployment workflow
- Team conventions

---

### Recommended Next Steps

1. Review conflict sections and choose resolution strategy
2. Merge framework template with existing customizations
3. Add missing sections (permissions, model selection, micro-tasks)
4. Validate merged CLAUDE.md with /repo-structure
5. Test agent behavior with new configuration
```

## Integration with Onboarding Flow

This skill integrates with existing repo onboarding (#969):

**Phase 0: Discovery & Analysis**
- Called during discovery phase
- Results saved to `.claude-tastic-discovery.json` under `claude_md_analysis`
- Feeds into Phase 1 (Interactive Reconciliation)

**Output Location:**
```bash
.claude-tastic-discovery.json
# Contains claude_md_analysis section with full quality report
```

## Token Optimization

- **Data script:** `scripts/repo-deploy-review-data.sh`
- **Model:** opus (justified for critical CLAUDE.md analysis)
- **Analysis:** File-based comparison with pattern matching
- **Output:** JSON + formatted markdown report
- **Savings:** ~60% token reduction from scripted analysis

## Quality Scoring Methodology

**Scoring System (0-100 per dimension):**

**Structure (0-100):**
- Has clear sections: +20
- Logical organization: +20
- Table of contents: +15
- Proper markdown: +15
- Section completeness: +30

**Agent Config (0-100):**
- Agents defined: +25
- Roles specified: +20
- Models assigned: +20
- Permissions defined: +20
- Delegation rules: +15

**SDLC Workflow (0-100):**
- Workflow phases defined: +25
- Phase transitions clear: +20
- Micro-task pattern: +20
- Gates and checks: +20
- Error handling: +15

**Security Rules (0-100):**
- Secrets management: +25
- Pre-commit checks: +20
- Security hooks: +20
- IAM rules: +20
- Audit logging: +15

**Permissions (0-100):**
- T0/T1/T2/T3 defined: +30
- Boundaries clear: +25
- Tool classification: +20
- Escalation triggers: +15
- Reversal procedures: +10

**Model Selection (0-100):**
- haiku/sonnet/opus defined: +30
- Cost optimization: +25
- Task-model mapping: +25
- Performance guidance: +20

**Escalation (0-100):**
- Paths defined: +30
- Agent delegation: +25
- User approval triggers: +20
- Error recovery: +15
- Timeout handling: +10

**Commit Strategy (0-100):**
- Conventional commits: +25
- Atomic commits: +20
- Co-authorship: +20
- Message format: +20
- Guidelines clear: +15

## Notes

- **DEPRECATED**: CLAUDE.md generation is now integrated into `/repo:init-framework` and `/local:init`
- **READ-ONLY OPERATION**: This skill queries data and presents reports only
- **Uses opus model**: Critical analysis justifies best available model
- Use this skill only for standalone CLAUDE.md quality analysis
- For actual CLAUDE.md generation/merging, use `/repo:init-framework` or `/local:init`
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - File modification operations
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY. Never cross this boundary.

**User action:** Review report and apply recommended migration steps manually (or use `/repo:init-framework` for automatic merging)

## See Also

- `scripts/generate-claude-md.sh` - CLAUDE.md generation script (used by init skills)
- `scripts/repo-deploy-review-data.sh` - Data collection script (analysis only)
- `docs/EXISTING_REPO_ONBOARDING.md` - Onboarding flow documentation
- `repo-template/CLAUDE.md` - Framework template for comparison
- `/repo:init-framework` - Recommended for CLAUDE.md generation
- `/local:init` - Consumer repo variant with CLAUDE.md generation
- Issue #970 - Enhancement specification
- Issue #969 - Existing repo onboarding flow
- Issue #1137 - CLAUDE.md generation merge into init-framework
