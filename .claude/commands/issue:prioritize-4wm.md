---
description: Run the Four Wise Men decision framework to prioritize issues and reach consensus on scope, timing, need, and strategic fit (READ-ONLY - advisory only)
---

# Wise Men Debate

**🔒 READ-ONLY OPERATION - This skill NEVER modifies issues or triggers work**

Orchestrates a structured debate between four specialized decision agents to evaluate an issue or decision point and reach consensus on prioritization.

**CRITICAL SAFEGUARD:**
- This skill ONLY produces advisory output and recommendations
- All suggested actions are for USER execution, not automatic invocation
- NEVER invoke `/sprint-work`, `/issue:label`, or any write operations from this skill
- DO NOT use the Skill tool to execute write operations

## The Four Wise Men

| Agent | Question | Domain |
|-------|----------|--------|
| **Timing Agent** | "Should we do this right now?" | Urgency, blockers, dependencies, scheduling |
| **Scope Agent** | "How much should we do right now?" | MVP vs full, slicing, complexity |
| **Need Agent** | "Do we need this right now?" | Business value, user impact, ROI |
| **Vision Agent** | "Does this fit our project vision?" | Strategic alignment, long-term fit |

## Usage

```
/issue-prioritize #143              # Debate specific issue
/issue-prioritize "Add dark mode"   # Debate a proposal
/issue-prioritize --backlog         # Prioritize top backlog items
```

## Debate Protocol

### Phase 1: Individual Assessments

Each agent independently evaluates the issue:

```
Launch four agents in parallel:
- timing-agent: Assess urgency and timing
- scope-agent: Assess appropriate scope
- need-agent: Assess necessity and value
- vision-agent: Assess strategic alignment
```

### Phase 2: Cross-Agent Response

Each agent responds to the others' assessments:

```
For each agent:
  - Review other agents' positions
  - Note agreements and disagreements
  - Adjust position if warranted (or defend)
```

### Phase 3: Consensus Synthesis

Combine assessments into final recommendation:

```
Weight each agent's position:
- Timing: 25% (when)
- Scope: 25% (how much)
- Need: 25% (should we)
- Vision: 25% (strategic fit)

Derive consensus:
- Priority (P0-P3)
- Scope recommendation
- Timing recommendation
- Go/No-Go decision
```

## Consensus Matrix

| Timing | Scope | Need | Vision | Consensus |
|--------|-------|------|--------|-----------|
| PROCEED | FULL | ESSENTIAL | ALIGNED | P0 - Do immediately, full scope |
| PROCEED | MVP | ESSENTIAL | ALIGNED | P1 - Do now, start with MVP |
| WAIT | MVP | VALUABLE | COMPATIBLE | P2 - Plan for next sprint |
| DEFER | FOUNDATION | OPTIONAL | TANGENTIAL | P3 - Backlog, low priority |
| DEFER | SPIKE | UNNECESSARY | MISALIGNED | Close - Not worth pursuing |

## Output Format

```
## Four Wise Men Consensus

**Issue/Decision:** [Title]

### Individual Positions

| Agent | Position | Key Reasoning |
|-------|----------|---------------|
| Timing | [PROCEED/WAIT/DEFER] | [One-liner] |
| Scope | [FULL/MVP/FOUNDATION/SPIKE] | [One-liner] |
| Need | [ESSENTIAL/VALUABLE/OPTIONAL/UNNECESSARY] | [One-liner] |
| Vision | [ALIGNED/COMPATIBLE/TANGENTIAL/MISALIGNED] | [One-liner] |

### Cross-Agent Notes

**Agreements:**
- [Points where agents agree]

**Tensions:**
- [Points where agents disagree]

### Consensus Recommendation

**Priority:** [P0/P1/P2/P3]
**Scope:** [What to deliver]
**Timing:** [When to do it]
**Decision:** [GO/DEFER/CLOSE]

**Rationale:**
[Brief explanation of how consensus was reached]
```

## Example Debate

**Issue:** "Add dark mode support" (#78)

### Individual Positions

| Agent | Position | Key Reasoning |
|-------|----------|---------------|
| Timing | DEFER | P1 bugs need attention first, sprint full |
| Scope | FOUNDATION | Start with CSS variables only |
| Need | OPTIONAL | No user requests, nice-to-have |
| Vision | COMPATIBLE | Aligns with UX goals but not core |

### Cross-Agent Notes

**Agreements:**
- All agree this is not urgent
- All agree full implementation is too large for now
- Vision and Need agree this has some value but isn't critical

**Tensions:**
- Scope suggests foundation work; Need questions if even that is necessary
- Timing says defer; Vision says it fits roadmap

### Consensus Recommendation

**Priority:** P3
**Scope:** Foundation only (CSS variables + toggle skeleton)
**Timing:** Next sprint, after current P1 bugs resolved
**Decision:** DEFER with specific conditions

**Rationale:**
Three of four agents suggest deferral or optional status. While strategically
compatible, there's no demonstrated need. If pursued, foundation scope
reduces risk and enables future work. Schedule for next sprint.

## Integration Points

### /sprint-work

Use wise men debate when multiple backlog items have similar priority:

```
# In sprint-work, before selecting next issue
if multiple_p2_issues_available:
    run_wise_men_debate(candidates)
    order_by_consensus_score()
```

### /issue:triage-bulk

Use wise men debate for priority recommendations:

```
# In pm-triage, for issues without priority
if issue.priority is None:
    run_wise_men_debate(issue)
    recommended_priority = consensus.priority
```

### Manual Invocation

For ad-hoc decisions or backlog grooming:

```
/issue-prioritize "Should we refactor the auth module?"
/issue-prioritize --backlog --limit 5
```

## Token Optimization

- Run agents in parallel (not sequential)
- Use haiku model for all four agents
- Limit cross-agent response to one round
- Total cost: ~4 haiku calls (~2000 tokens)

## Notes

- **READ-ONLY OPERATION**: This skill produces advisory output only
- Consensus is advisory, not mandatory
- PM can override consensus with justification
- Works best with clear issue descriptions
- Requires project vision context for Vision Agent
- **NEVER automatically invoke**:
  - `/sprint-work` command
  - `/issue:label` command
  - `gh issue edit` commands
  - DO NOT use the Skill tool to execute write operations under any circumstance
- **BOUNDARY ENFORCEMENT**: This skill is READ-ONLY (advisory). Label/issue changes are WRITE-FULL. Never cross this boundary.

**User action:** Apply recommended priority via `/issue:label` manually or instruct PM to delegate
