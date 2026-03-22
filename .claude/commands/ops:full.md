---
description: Run all ops audits in a single invocation and submit aggregated report as a GitHub issue to jifflee/claude-tastic with compression for large payloads
argument-hint: "[--no-submit] [--dry-run] [--repo REPO]"
---

# Ops Full Audit

Orchestrates all 6 ops skills, aggregates findings into a unified report, and submits results as a GitHub issue to `jifflee/claude-tastic`. Large payloads are compressed via gzip+base64 to stay within GitHub's ~65K character issue body limit.

**READ-ONLY OPERATION** — collects data from read-only ops skills; the only write action is issue creation in the target repo.

## Usage

```
/ops:full                          # Run all audits and submit issue (default)
/ops:full --no-submit              # Run all audits, print report only
/ops:full --dry-run                # Preview issue body without submitting
/ops:full --repo owner/repo        # Submit to different repo (default: jifflee/claude-tastic)
```

## Arguments

| Argument | Description |
|----------|-------------|
| `--no-submit` | Print aggregated report only, do not create issue |
| `--dry-run` | Preview issue body (includes compression if needed) |
| `--repo OWNER/REPO` | Target repo for issue submission (default: `jifflee/claude-tastic`) |

## Steps

### 1. Parse Arguments

Check for flags and set defaults:
- `TARGET_REPO="jifflee/claude-tastic"` (override with `--repo`)
- `SUBMIT=true` (set to false with `--no-submit`)
- `DRY_RUN=false` (set to true with `--dry-run`)

### 2. Run All Ops Skills via Skill Tool

Invoke each skill sequentially and capture output. Use the Skill tool for each:

1. `/ops:metrics` — token usage, model selection, performance
2. `/ops:skills` — skill token efficiency and scripting opportunities
3. `/ops:agents` — agent format compliance and quality
4. `/ops:actions` — action audit log and tier analysis
5. `/ops:models` — model configuration distribution
6. `/ops:skill-deps` — dependency visualization and tier inheritance

Store each output with a section label for aggregation.

### 3. Aggregate into Unified Report

Combine all outputs into a structured markdown report:

```
# Ops Full Audit Report

**Generated:** {ISO-8601 timestamp}
**Repository:** {current repo name via `gh repo view --json name -q .name`}
**Framework:** claude-tastic consumer ops health check

---

## Executive Summary

| Skill | Status | Key Finding |
|-------|--------|-------------|
| ops:metrics | {OK/WARN/CRIT} | {one-line summary} |
| ops:skills | {OK/WARN/CRIT} | {one-line summary} |
| ops:agents | {OK/WARN/CRIT} | {one-line summary} |
| ops:actions | {OK/WARN/CRIT} | {one-line summary} |
| ops:models | {OK/WARN/CRIT} | {one-line summary} |
| ops:skill-deps | {OK/WARN/CRIT} | {one-line summary} |

---

## ops:metrics

{full output}

---

## ops:skills

{full output}

---

## ops:agents

{full output}

---

## ops:actions

{full output}

---

## ops:models

{full output}

---

## ops:skill-deps

{full output}

---

## Recommendations

{cross-cutting recommendations from all findings}
```

### 4. Apply Compression if Needed

Check report length and apply the framework compression standard if needed:

```bash
REPORT_LEN=${#REPORT}
LIMIT=60000   # Safe threshold below GitHub's 65,535 char limit

if [ "$REPORT_LEN" -gt "$LIMIT" ]; then
    # Compress: gzip + base64
    COMPRESSED=$(echo "$REPORT" | gzip -9 | base64 -w 0)
    ISSUE_BODY="$(cat <<'BODY'
# Ops Full Audit Report (Compressed)

> **Payload size exceeded GitHub limit. Full report is gzip+base64 encoded below.**
> **Compression standard:** See [docs/COMPRESSION_STANDARD.md](../docs/COMPRESSION_STANDARD.md)

## Decompression Instructions

Save the payload below to a file, then run:

\`\`\`bash
# Decompress on Linux/macOS
echo "<PAYLOAD>" | base64 -d | gunzip > ops-full-report.md
cat ops-full-report.md

# Or pipe directly:
echo "<PAYLOAD>" | base64 -d | gunzip | less
\`\`\`

## Executive Summary

{executive_summary_section}

## Compressed Payload

\`\`\`
<PAYLOAD>
\`\`\`

BODY
)"
    ISSUE_BODY="${ISSUE_BODY//<PAYLOAD>/$COMPRESSED}"
else
    ISSUE_BODY="$REPORT"
fi
```

Refer to `docs/COMPRESSION_STANDARD.md` for the canonical compression algorithm and decompression instructions.

### 5. Submit Issue to Target Repo

Unless `--no-submit` or `--dry-run`:

```bash
REPO_NAME=$(gh repo view --json name,owner -q '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "unknown/repo")
DATE=$(date -u +%Y-%m-%d)

gh issue create \
  --repo "$TARGET_REPO" \
  --title "ops:full audit — $REPO_NAME ($DATE)" \
  --label "ops-report,automated" \
  --body "$ISSUE_BODY"
```

For `--dry-run`, print `$ISSUE_BODY` and the character count without submitting.

## Output Format

### Success

```
## Ops Full Audit Complete

**Skills run:** 6/6
**Report size:** {N} characters ({compressed: yes/no})
**Issue submitted:** {URL or "not submitted (--no-submit)"}

{executive summary table}

Run with --no-submit to print the full report locally.
```

### Dry Run

```
## Ops Full Audit — Dry Run

**Report size:** {N} characters
**Compression:** {applied/not needed} (limit: 60,000 chars)
**Would submit to:** {TARGET_REPO}

--- ISSUE BODY PREVIEW ---

{issue body}
```

## Token Optimization

- Each sub-skill already uses data scripts (pre-computed JSON)
- Aggregation is additive — no re-analysis needed
- Compression offloaded to bash (`gzip`, `base64`) — zero Claude tokens
- Estimated total: ~3,000–5,000 tokens across all 6 sub-skills

## Notes

- **Compression standard:** `docs/COMPRESSION_STANDARD.md` — defines the canonical gzip+base64 method for all framework skills
- **Target repo:** Default `jifflee/claude-tastic`; requires `gh auth` with repo write access to that org
- **Labels:** Creates `ops-report` and `automated` labels on the target repo if they do not exist
- **Consumer repo usage:** Run from any consumer repo — the report includes the repo name so findings are attributed correctly
- **Sub-skill order:** Sequential to avoid rate-limit collisions; each sub-skill is READ-ONLY
- **NEVER invoke** `/sprint-work` or write operations from this skill
