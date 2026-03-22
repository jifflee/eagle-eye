---
description: Interactive discovery wizard to create local agents or tool skills via guided questions
argument-hint: "[--agent | --skill | --tool]"
---

# Create Function

> **TL;DR:** Guided discovery wizard that asks what you're trying to accomplish, proposes a design, and generates a standardized GitHub issue to drive implementation.

## Purpose

Instead of requiring users to know framework conventions upfront, this wizard:

1. Asks whether you want to create a **local agent** or a **local tool/skill**
2. Asks tailored discovery questions per type
3. Proposes a structured design for your approval
4. Generates a GitHub issue with all context and acceptance criteria

## Usage

```
/local:create-function              # Full interactive mode
/local:create-function --agent      # Skip type selection, go straight to agent flow
/local:create-function --skill      # Skip type selection, go to tool/skill flow
/local:create-function --tool       # Alias for --skill
```

## Steps

### 1. Type Selection

If no type flag is provided, ask:

```
What would you like to create?

1. Local Agent   — A specialized subagent that handles a domain of tasks
2. Local Skill   — A slash command / tool skill that executes a workflow

Enter 1 or 2:
```

Set `function_type = "agent"` or `function_type = "skill"` accordingly.

---

### 2. Discovery Questions (Agent Path)

When `function_type = "agent"`, ask these questions in sequence.
Wait for the user's answer before asking the next question.

**Q1 — Purpose/Domain:**
```
What domain or area of expertise should this agent have?
(e.g. "database migrations", "security review", "API design", "test generation")
```

**Q2 — Trigger & Input:**
```
What triggers this agent and what input does it receive?
(e.g. "Invoked by the orchestrator with a PR diff", "Called with a file path and audit type")
```

**Q3 — Expected Output:**
```
What should the agent produce or return when done?
(e.g. "A structured report as markdown", "A list of code suggestions", "Modified files + summary")
```

**Q4 — Escalation & Decision Rules:**
```
Are there situations where the agent should stop and ask for help or escalate?
(e.g. "If it encounters secrets in code", "If confidence is below 70%", "Never — always complete autonomously")
```

**Q5 — Permissions:**
```
What level of access does this agent need?
1. Read-only   (read files, search, analyze)
2. Read+Write  (create/edit files, run safe shell commands)
3. Full access (destructive operations, GitHub actions, deploys)

Enter 1, 2, or 3:
```

**Q6 — Model:**
```
What model should power this agent?
1. haiku   — Fast and cheap, good for simple tasks
2. sonnet  — Balanced, good for most tasks (recommended)
3. opus    — Powerful, best for complex reasoning

Enter 1, 2, or 3:
```

Store all answers as `agent_discovery = { domain, trigger, output, escalation, permissions, model }`.

---

### 3. Discovery Questions (Skill/Tool Path)

When `function_type = "skill"`, ask these questions in sequence.

**Q1 — End-to-End Goal:**
```
What should this skill accomplish from start to finish?
Describe the complete workflow, not just one step.
(e.g. "Scan open PRs, find the ones without tests, and post a comment with a checklist")
```

**Q2 — Trigger:**
```
How is this skill invoked?
(e.g. "User runs /my-skill ISSUE_NUMBER", "Runs automatically on a schedule", "Called by another skill")
```

**Q3 — Input:**
```
What arguments or data does this skill take as input?
(e.g. "A GitHub issue number", "A branch name and target environment", "No arguments — no user input needed")
```

**Q4 — Output:**
```
What does the skill output or produce when complete?
(e.g. "A markdown report printed to the terminal", "Creates a GitHub PR", "Updates a config file")
```

**Q5 — Edge Cases:**
```
Are there cases where the skill should stop, warn, or behave differently?
(e.g. "If no open PRs exist, print a friendly message and exit", "Warn if run on main branch")
```

**Q6 — Domain / Category:**
```
Which skill domain fits best?
1. local     — Local repo setup and helpers
2. tool      — Standalone utility
3. audit     — Analysis and compliance
4. issue     — GitHub issue management
5. pr        — Pull request workflows
6. sprint    — Sprint automation
7. other     — I'll specify a custom category

Enter 1-7:
```

Store all answers as `skill_discovery = { goal, trigger, input, output, edge_cases, domain }`.

---

### 4. Clarifying Questions

After the primary discovery questions, ask up to 3 targeted clarifying questions based on gaps in the answers.

**Evaluate answers for gaps:**

| Gap Detected | Clarifying Question |
|---|---|
| Output is vague (no format mentioned) | "What format should the output use? (markdown table, JSON, plain text, GitHub comment)" |
| Permissions seem too broad for stated purpose | "This needs write access — can you confirm it needs to create/modify files, not just read them?" |
| No error handling mentioned | "What should happen if the main operation fails or returns no results?" |
| Scope unclear (how many items to process) | "Should this process one item at a time or batch-process multiple items?" |
| Trigger is ambiguous | "When you say 'automatically', do you mean via a cron schedule, CI pipeline, or another skill calling this one?" |

Ask only the clarifying questions that are truly needed. If no gaps exist, skip this step.

---

### 5. Proposal Generation

**Use sonnet model for this step** to produce a high-quality design proposal.

Synthesize all discovery answers into a structured design proposal:

```
## Proposed Design: {suggested-name}

**Type:** {Agent | Skill}
**Name:** {category}:{action-name}  (or {agent-name} for agents)
**Category:** {domain}
**Model:** {haiku | sonnet | opus}
**Permission Tier:** {Tier 1 (read) | Tier 2 (write) | Tier 3 (destructive)}
**Local-Origin:** true (protected from framework updates)

---

### What It Does

{2-3 sentence summary of the end-to-end behavior}

### Inputs

{List of inputs with types and descriptions}

### Outputs

{Description of what it produces}

### Key Behaviors

- {Key behavior 1}
- {Key behavior 2}
- {Key behavior 3}

### Escalation / Edge Cases

- {Edge case 1 and how it's handled}
- {Edge case 2 and how it's handled}

### Acceptance Criteria (draft)

- [ ] {Criterion 1}
- [ ] {Criterion 2}
- [ ] {Criterion 3}
- [ ] Tests cover the main workflow
- [ ] Locally-created artifact tagged with local-origin metadata

---

Does this proposal look right?
1. Approve — generate the GitHub issue
2. Edit — I want to change something
3. Start over — restart the discovery
```

---

### 6. Handle Edit Request

If user selects "Edit":

```
What would you like to change?
1. Name / category
2. Permissions / model
3. Key behaviors
4. Acceptance criteria
5. Something else — describe it

Enter 1-5:
```

Apply the requested change, then show the updated proposal again (loop back to step 5).

---

### 7. Generate GitHub Issue

After proposal approval, generate a standardized GitHub issue.

**Invoke the repo-workflow agent** using the Task tool with `subagent_type: "repo-workflow"` and `model: "sonnet"`.

**Issue title format:**
```
Add {type}: {suggested-name} — {one-line description}
```

**Issue body template:**

```markdown
## Summary

{2-3 sentence description from proposal}

## Discovery Context

**Type:** {Agent | Skill}
**Proposed Name:** `{name}`
**Category / Domain:** `{category}`
**Model:** `{model}`
**Permission Tier:** {tier}

### Discovery Q&A

| Question | Answer |
|---|---|
| Purpose / Goal | {answer} |
| Trigger / Input | {answer} |
| Expected Output | {answer} |
| Escalation / Edge Cases | {answer} |
| Permissions | {answer} |

## Proposed Design

{Full design spec from step 5}

## Acceptance Criteria

- [ ] {criterion from proposal}
- [ ] {criterion from proposal}
- [ ] {criterion from proposal}
- [ ] Tests cover the main workflow and edge cases
- [ ] Artifact tagged as `local-origin: true` in manifest
- [ ] Follows `docs/SKILL_NAMING_CONVENTION.md` conventions
- [ ] Leverages existing `local:create-agent` or `local:create-skill` scaffolding where applicable

## Implementation Notes

- Run `/local:create-agent {name}` or `/local:create-skill {name}` to scaffold the file
- Mark artifact as local-origin in `.claude/.manifest.json`
- Use `/sprint:work-auto` to drive implementation from this issue
- Reference `docs/ARCHITECTURE.md` and `docs/SKILL_NAMING_CONVENTION.md` during implementation

<details>
<summary>Raw Discovery Session</summary>

Captured via /local:create-function wizard.
Date: {current_date}
Type selected: {agent | skill}

</details>

---

## Context
Captured via /local:create-function command.
Category: feature
Component: {agents | skills}
Local-Origin: true
```

**Labels to apply:** `feature`, `backlog`, `component:{agents|skills}`, `local-origin`

---

### 8. Display Result

```
## Issue Created: #{number}

**Title:** {title}
**URL:** {url}

Next steps:
- Scaffold the file:  /local:create-{agent|skill} {name}
- Drive implementation:  /sprint:work-auto (picks up this issue)
- Mark local-origin in .claude/.manifest.json after scaffolding
```

---

## Local-Origin Protection

All artifacts created via this wizard are tagged as `local-origin: true` in `.claude/.manifest.json`.

This means:
- Framework updates (`/tool:skill-sync`, `/repo:framework-update`) will **not** overwrite them
- They are tracked separately from framework-managed files
- To intentionally update them, remove the `local-origin` flag manually

**Manifest entry format:**

```json
{
  "local/agents/{name}.md": {
    "target": "agents/{name}.md",
    "category": "agents",
    "local-origin": true,
    "hash": "<computed-sha256>",
    "size": <file-size>
  }
}
```

## Notes

- This is a **discovery layer** — it sits above `local:create-agent` and `local:create-skill`
- The generated issue drives actual file creation via `/sprint:work-auto`
- Uses **sonnet model** for proposal generation (step 5) for high-quality designs
- Clarifying questions are adaptive — only asked when gaps are detected
- Proposal can be edited before issue generation (step 6)
- Leverages `docs/ARCHITECTURE.md` and `docs/SKILL_NAMING_CONVENTION.md` for conventions
- WRITE operation — creates a GitHub issue
