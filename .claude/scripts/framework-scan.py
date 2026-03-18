#!/usr/bin/env python3
"""
framework-scan.py
Framework-specific scanner for the claude-agents framework.

Detects issues specific to the claude-agents structure: skill/agent overlap,
stale manifests, hook efficiency, and deprecated aliases.

READ-ONLY analysis. Produces findings in refactor-finding.schema.json format.

USAGE:
  python scripts/framework-scan.py [OPTIONS]

OPTIONS:
  --framework-dir DIR       Framework root directory (default: .)
  --output-file FILE        Output findings JSON (default: .refactor/framework-findings.json)
  --categories LIST         Comma-separated: skill-overlap,agent-overlap,stale-manifests,
                            hook-efficiency,deprecated-aliases
  --severity-threshold LVL  Minimum severity: critical|high|medium|low (default: low)
  --format json|summary     Output format (default: json)
  --dry-run                 Print scan plan, do not execute
  --verbose                 Verbose output

OUTPUT:
  JSON array of findings conforming to refactor-finding.schema.json
  Exit codes: 0=no findings, 1=medium/low only, 2=critical/high found
"""

import json
import os
import re
import sys
import hashlib
import argparse
import datetime
from pathlib import Path
from collections import defaultdict
from typing import Dict, List, Set, Tuple, Optional

SCANNER_VERSION = "1.0.0"

# ─── Severity helpers ─────────────────────────────────────────────────────────

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1}

_finding_counter = 0


def next_finding_id() -> str:
    global _finding_counter
    _finding_counter += 1
    return f"RF-{_finding_counter:03d}"


def now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def severity_meets_threshold(severity: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(severity, 0) >= SEVERITY_ORDER.get(threshold, 0)


# ─── File discovery ───────────────────────────────────────────────────────────

def find_files(directory: Path, pattern: str) -> List[Path]:
    """Find files matching a glob pattern."""
    return sorted(directory.rglob(pattern))


def read_text_safe(path: Path) -> str:
    """Read a file safely, returning empty string on failure."""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except (OSError, PermissionError):
        return ""


def sha256_file(path: Path) -> str:
    """Compute SHA-256 hash of a file's contents."""
    content = path.read_bytes()
    return hashlib.sha256(content).hexdigest()


# ─── Skill/Agent discovery ───────────────────────────────────────────────────

def discover_skills(framework_dir: Path) -> List[Dict]:
    """Discover all skill/command markdown files."""
    skills = []
    commands_dirs = [
        framework_dir / ".claude" / "commands",
        framework_dir / "core" / "commands",
    ]
    for commands_dir in commands_dirs:
        if not commands_dir.exists():
            continue
        for md_file in sorted(commands_dir.glob("*.md")):
            content = read_text_safe(md_file)
            skills.append({
                "path": md_file,
                "name": md_file.stem,
                "content": content,
                "size": len(content),
                "rel_path": str(md_file.relative_to(framework_dir)),
            })
    return skills


def discover_agents(framework_dir: Path) -> List[Dict]:
    """Discover all agent markdown files."""
    agents = []
    agents_dirs = [
        framework_dir / ".claude" / "agents",
        framework_dir / "core" / "agents",
    ]
    for agents_dir in agents_dirs:
        if not agents_dir.exists():
            continue
        for md_file in sorted(agents_dir.glob("*.md")):
            content = read_text_safe(md_file)
            agents.append({
                "path": md_file,
                "name": md_file.stem,
                "content": content,
                "size": len(content),
                "rel_path": str(md_file.relative_to(framework_dir)),
            })
    return agents


def discover_hooks(framework_dir: Path) -> List[Dict]:
    """Discover all hook files."""
    hooks = []
    hooks_dirs = [
        framework_dir / ".claude" / "hooks",
        framework_dir / "core" / "hooks",
    ]
    for hooks_dir in hooks_dirs:
        if not hooks_dir.exists():
            continue
        for hook_file in sorted(hooks_dir.iterdir()):
            if hook_file.is_file() and hook_file.suffix in (".py", ".sh"):
                content = read_text_safe(hook_file)
                hooks.append({
                    "path": hook_file,
                    "name": hook_file.stem,
                    "content": content,
                    "size": len(content),
                    "rel_path": str(hook_file.relative_to(framework_dir)),
                })
    return hooks


# ─── Name similarity ─────────────────────────────────────────────────────────

def name_similarity(name1: str, name2: str) -> float:
    """
    Compute a simple similarity score between two names.
    Returns 0.0 (no overlap) to 1.0 (identical).
    Uses bigram similarity for robustness.
    """
    if name1 == name2:
        return 1.0

    def bigrams(s: str) -> Set[str]:
        s = s.lower().replace("-", "").replace("_", "")
        return {s[i:i+2] for i in range(len(s) - 1)}

    b1 = bigrams(name1)
    b2 = bigrams(name2)
    if not b1 or not b2:
        return 0.0
    intersection = len(b1 & b2)
    union = len(b1 | b2)
    return intersection / union if union > 0 else 0.0


def word_overlap(text1: str, text2: str, min_length: int = 4) -> float:
    """
    Compute word overlap ratio between two texts.
    Returns 0.0 to 1.0.
    """
    def significant_words(text: str) -> Set[str]:
        words = re.findall(r'\b[a-zA-Z]{%d,}\b' % min_length, text.lower())
        # Filter common/stop words
        stop = {
            "this", "that", "with", "from", "have", "will", "should", "must",
            "when", "where", "which", "each", "your", "their", "about", "also",
            "into", "more", "than", "then", "they", "what", "been", "agent",
            "skill", "tool", "task", "work", "used", "uses", "code", "file",
            "make", "take", "need", "only", "both", "some", "such", "like",
            "well", "just", "before", "after", "during", "these", "those",
        }
        return {w for w in words if w not in stop}

    w1 = significant_words(text1)
    w2 = significant_words(text2)
    if not w1 or not w2:
        return 0.0
    intersection = len(w1 & w2)
    smaller = min(len(w1), len(w2))
    return intersection / smaller if smaller > 0 else 0.0


def extract_agent_references(content: str) -> Set[str]:
    """Extract agent names referenced in a skill/command file."""
    # Look for patterns like: subagent_type: "agent-name", agent: agent-name, etc.
    patterns = [
        r'subagent_type["\s:=]+([a-z][a-z0-9-]+)',
        r'agent["\s:=]+([a-z][a-z0-9-]+)',
        r'"([a-z][a-z0-9-]+)"\s+agent',
        r'Use\s+(?:the\s+)?(?:this\s+)?(?:`([a-z][a-z0-9-]+)`|([a-z][a-z0-9-]+))\s+agent',
    ]
    refs = set()
    for pattern in patterns:
        for match in re.finditer(pattern, content, re.IGNORECASE):
            for group in match.groups():
                if group and len(group) > 2:
                    refs.add(group.lower())
    return refs


# ─── Scan: Skill Overlap ─────────────────────────────────────────────────────

def scan_skill_overlap(
    framework_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect skills with similar names or overlapping functionality."""
    findings = []
    skills = discover_skills(framework_dir)

    if verbose:
        print(f"[framework-scan:verbose] Discovered {len(skills)} skills", file=sys.stderr)

    if len(skills) < 2:
        return findings

    # 1. Name similarity check
    name_pairs = []
    for i, s1 in enumerate(skills):
        for s2 in skills[i+1:]:
            sim = name_similarity(s1["name"], s2["name"])
            if sim >= 0.5:  # 50% bigram overlap = very similar names
                name_pairs.append((s1, s2, sim))

    if name_pairs and severity_meets_threshold("medium", severity_threshold):
        for s1, s2, sim in name_pairs[:5]:
            if verbose:
                print(f"[framework-scan:verbose] Similar skill names: {s1['name']} ~ {s2['name']} (sim={sim:.2f})", file=sys.stderr)
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dedup",
                "severity": "medium",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "refactoring-specialist",
                "file_paths": [s1["rel_path"], s2["rel_path"]],
                "description": (
                    f"Similar skill names detected: `{s1['name']}` and `{s2['name']}` "
                    f"have {sim:.0%} name overlap. Skills with similar names may confuse "
                    "users about which to use, and may indicate duplicated functionality "
                    "that should be consolidated."
                ),
                "suggested_fix": (
                    f"Review `{s1['name']}` and `{s2['name']}` for functional overlap. "
                    "If they perform similar actions, consolidate into one skill with clear "
                    "parameters to differentiate behavior. If they are distinct, rename them "
                    "to make the distinction clear (e.g., add a domain prefix)."
                ),
                "acceptance_criteria": [
                    "Skills have clearly differentiated names that reflect distinct purposes",
                    "If consolidated, existing callers are updated or aliases are provided",
                    "Skill documentation clearly explains when to use each",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["skill-overlap", "naming", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    # 2. Shared agent reference check (skills that wrap the same agent)
    agent_to_skills: Dict[str, List[Dict]] = defaultdict(list)
    for skill in skills:
        agents_referenced = extract_agent_references(skill["content"])
        for agent_ref in agents_referenced:
            agent_to_skills[agent_ref].append(skill)

    for agent_ref, wrapping_skills in agent_to_skills.items():
        if len(wrapping_skills) >= 3:
            if not severity_meets_threshold("low", severity_threshold):
                continue
            if verbose:
                print(f"[framework-scan:verbose] Agent '{agent_ref}' referenced by {len(wrapping_skills)} skills", file=sys.stderr)

            skill_names = [s["name"] for s in wrapping_skills[:5]]
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dedup",
                "severity": "low",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "refactoring-specialist",
                "file_paths": [s["rel_path"] for s in wrapping_skills[:5]],
                "description": (
                    f"Multiple skills reference the same agent `{agent_ref}`: "
                    f"{', '.join(skill_names)}. "
                    "Skills that are thin wrappers over the same agent may indicate "
                    "fragmentation that could be simplified with a single parameterized skill."
                ),
                "suggested_fix": (
                    f"Audit the {len(wrapping_skills)} skills wrapping `{agent_ref}`: "
                    f"{', '.join(skill_names)}. "
                    "Consider consolidating into one skill with subcommand arguments if "
                    "the use cases are closely related. Keep separate skills only when "
                    "the different contexts genuinely require different agent instructions."
                ),
                "acceptance_criteria": [
                    f"The number of skills wrapping `{agent_ref}` is reduced or justified",
                    "Each remaining skill has a clearly distinct use case documented",
                    "No two skills produce identical agent behavior",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["skill-overlap", "agent-wrapper", "framework"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    # 3. Content similarity (functional overlap)
    content_pairs = []
    for i, s1 in enumerate(skills):
        for s2 in skills[i+1:]:
            # Skip pairs already flagged for name similarity
            already_flagged = any(
                (f["file_paths"] == [s1["rel_path"], s2["rel_path"]] or
                 f["file_paths"] == [s2["rel_path"], s1["rel_path"]])
                for f in findings
            )
            if already_flagged:
                continue
            # Only check non-trivially small skills
            if s1["size"] < 200 or s2["size"] < 200:
                continue
            overlap = word_overlap(s1["content"], s2["content"])
            if overlap >= 0.65:
                content_pairs.append((s1, s2, overlap))

    if content_pairs and severity_meets_threshold("medium", severity_threshold):
        for s1, s2, overlap in content_pairs[:3]:
            if verbose:
                print(f"[framework-scan:verbose] Content overlap: {s1['name']} ~ {s2['name']} ({overlap:.0%})", file=sys.stderr)
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dedup",
                "severity": "medium",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "refactoring-specialist",
                "file_paths": [s1["rel_path"], s2["rel_path"]],
                "description": (
                    f"High content overlap between skills `{s1['name']}` and `{s2['name']}`: "
                    f"{overlap:.0%} significant-word overlap. These skills may be implementing "
                    "similar functionality with different names, leading to user confusion "
                    "and duplicated maintenance burden."
                ),
                "suggested_fix": (
                    f"Compare `{s1['name']}` and `{s2['name']}` side-by-side. "
                    "If they serve identical purposes: consolidate into one. "
                    "If they differ slightly: extract shared instructions into a shared "
                    "fragment or base template, then specialize. "
                    "Document the distinction clearly in each skill's description."
                ),
                "acceptance_criteria": [
                    "Overlapping content is deduplicated or intentionally diverged",
                    "Each skill's unique purpose is stated in the first 2 lines",
                    "No two skills produce equivalent outputs for the same input",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["skill-overlap", "content-dedup", "framework"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    return findings


# ─── Scan: Agent Overlap ─────────────────────────────────────────────────────

def scan_agent_overlap(
    framework_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect agents with unclear boundaries or duplicated content."""
    findings = []
    agents = discover_agents(framework_dir)

    if verbose:
        print(f"[framework-scan:verbose] Discovered {len(agents)} agents", file=sys.stderr)

    if len(agents) < 2:
        return findings

    # Extract agent responsibility statements (first N lines / description section)
    def extract_description(content: str, lines: int = 10) -> str:
        """Extract the first meaningful lines as a description."""
        result = []
        for line in content.split("\n")[:lines]:
            line = line.strip()
            if line and not line.startswith("#"):
                result.append(line)
        return " ".join(result)

    # 1. Name similarity
    name_pairs = []
    for i, a1 in enumerate(agents):
        for a2 in agents[i+1:]:
            sim = name_similarity(a1["name"], a2["name"])
            if sim >= 0.45:
                name_pairs.append((a1, a2, sim))

    if name_pairs and severity_meets_threshold("low", severity_threshold):
        for a1, a2, sim in name_pairs[:5]:
            if verbose:
                print(f"[framework-scan:verbose] Similar agent names: {a1['name']} ~ {a2['name']}", file=sys.stderr)
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dedup",
                "severity": "low",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "architect",
                "file_paths": [a1["rel_path"], a2["rel_path"]],
                "description": (
                    f"Similar agent names: `{a1['name']}` and `{a2['name']}` share "
                    f"{sim:.0%} name similarity. Users and orchestrators may have difficulty "
                    "choosing the correct agent, leading to misrouting."
                ),
                "suggested_fix": (
                    f"Clarify the boundary between `{a1['name']}` and `{a2['name']}`. "
                    "Update each agent's opening description to state explicitly what it does "
                    "AND what it does NOT do. If their responsibilities genuinely overlap, "
                    "consider merging them with a unified set of instructions."
                ),
                "acceptance_criteria": [
                    "Each agent's description clearly delineates its unique responsibility",
                    "Agent selection guidance is provided (when to use each)",
                    "Routing tables in commands/skills use the correct agent",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["agent-overlap", "naming", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    # 2. Prompt content similarity
    content_pairs = []
    for i, a1 in enumerate(agents):
        for a2 in agents[i+1:]:
            if a1["size"] < 300 or a2["size"] < 300:
                continue
            overlap = word_overlap(a1["content"], a2["content"])
            if overlap >= 0.7:
                content_pairs.append((a1, a2, overlap))

    if content_pairs and severity_meets_threshold("medium", severity_threshold):
        for a1, a2, overlap in content_pairs[:3]:
            if verbose:
                print(f"[framework-scan:verbose] Agent prompt overlap: {a1['name']} ~ {a2['name']} ({overlap:.0%})", file=sys.stderr)
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dedup",
                "severity": "medium",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "architect",
                "file_paths": [a1["rel_path"], a2["rel_path"]],
                "description": (
                    f"High prompt similarity between agents `{a1['name']}` and `{a2['name']}`: "
                    f"{overlap:.0%} significant-word overlap. Agents with very similar prompts "
                    "may be consolidatable, or may have drifted from their intended specialization."
                ),
                "suggested_fix": (
                    f"Review `{a1['name']}` and `{a2['name']}` for consolidation opportunity. "
                    "If distinct: identify and expand the differentiating sections. "
                    "If redundant: merge into one agent and update all routing references. "
                    "Extract truly shared instructions into CLAUDE.md or a shared context file."
                ),
                "acceptance_criteria": [
                    "Agent prompts are differentiated with clear, specific responsibilities",
                    "Shared boilerplate (if any) is documented as intentional",
                    "Merged agents (if applicable) handle all previous routing scenarios",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["agent-overlap", "prompt-dedup", "framework"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    return findings


# ─── Scan: Stale Manifests ────────────────────────────────────────────────────

def scan_stale_manifests(
    framework_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect manifest files that are out of sync with actual agent/skill files."""
    findings = []

    manifest_paths = [
        framework_dir / ".claude" / ".manifest.json",
        framework_dir / ".sync-manifest.json",
    ]
    # Also find any manifest files in the tree
    for manifest_path in find_files(framework_dir, ".manifest.json"):
        if manifest_path not in manifest_paths:
            manifest_paths.append(manifest_path)

    if verbose:
        print(f"[framework-scan:verbose] Checking {len(manifest_paths)} manifest file(s)", file=sys.stderr)

    for manifest_path in manifest_paths:
        if not manifest_path.exists():
            continue

        rel_manifest = str(manifest_path.relative_to(framework_dir))

        try:
            manifest_data = json.loads(read_text_safe(manifest_path))
        except (json.JSONDecodeError, ValueError):
            if severity_meets_threshold("high", severity_threshold):
                finding = {
                    "id": next_finding_id(),
                    "dimension": "framework",
                    "category": "framework-pattern",
                    "severity": "high",
                    "owning_agent": "guardrails-policy",
                    "fallback_agent": "documentation-librarian",
                    "file_paths": [rel_manifest],
                    "description": (
                        f"Manifest file `{rel_manifest}` contains invalid JSON. "
                        "A corrupt manifest may cause framework tools to fail silently "
                        "or use stale file references."
                    ),
                    "suggested_fix": (
                        f"Repair or regenerate `{rel_manifest}`. "
                        "Run `scripts/generate-manifest.sh` (or equivalent) to produce "
                        "a fresh manifest. Validate with `jq . {rel_manifest}`."
                    ),
                    "acceptance_criteria": [
                        f"`{rel_manifest}` is valid JSON",
                        "Manifest passes schema validation",
                        "Framework tools operate correctly with the refreshed manifest",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["stale-manifest", "manifest", "framework"],
                        "effort_estimate": "xs",
                    },
                }
                findings.append(finding)
            continue

        # Check files section for hash mismatches and missing files
        files_section = manifest_data.get("files", {})
        if not files_section:
            # Try alternative manifest formats
            files_section = manifest_data.get("entries", {})

        if not files_section:
            if verbose:
                print(f"[framework-scan:verbose] Manifest {rel_manifest}: no files section", file=sys.stderr)
            continue

        hash_mismatches = []
        missing_files = []
        stale_refs = []

        for source_path_str, entry in files_section.items():
            if not isinstance(entry, dict):
                continue

            # Determine the target file path
            target_str = entry.get("target", source_path_str)
            # Target is relative to .claude/
            if "/" in target_str and not target_str.startswith("/"):
                # Try multiple base directories
                candidates = [
                    framework_dir / ".claude" / target_str,
                    framework_dir / target_str,
                ]
            else:
                candidates = [framework_dir / ".claude" / target_str]

            target_path = None
            for candidate in candidates:
                if candidate.exists():
                    target_path = candidate
                    break

            if target_path is None:
                # File referenced in manifest doesn't exist
                stale_refs.append(target_str)
                if verbose:
                    print(f"[framework-scan:verbose] Missing file: {target_str}", file=sys.stderr)
                continue

            # Check hash if provided
            manifest_hash = entry.get("hash")
            if manifest_hash:
                try:
                    actual_hash = sha256_file(target_path)
                    if actual_hash != manifest_hash:
                        hash_mismatches.append(str(target_path.relative_to(framework_dir)))
                        if verbose:
                            print(f"[framework-scan:verbose] Hash mismatch: {target_str}", file=sys.stderr)
                except (OSError, PermissionError):
                    pass

        # Report missing files
        if stale_refs and severity_meets_threshold("high", severity_threshold):
            sample = stale_refs[:5]
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "framework-pattern",
                "severity": "high",
                "owning_agent": "guardrails-policy",
                "fallback_agent": "documentation-librarian",
                "file_paths": [rel_manifest],
                "description": (
                    f"Stale manifest: `{rel_manifest}` references {len(stale_refs)} "
                    f"file(s) that do not exist on disk: {', '.join(sample[:3])}. "
                    "Stale references cause framework sync tools to report false positives "
                    "and may fail when attempting to install referenced files."
                ),
                "suggested_fix": (
                    f"Regenerate `{rel_manifest}` using `scripts/generate-manifest.sh`. "
                    "Alternatively, remove stale entries manually: "
                    + ", ".join(f"`{r}`" for r in sample)
                    + ". Ensure all referenced agent/skill files exist before committing "
                    "a manifest update."
                ),
                "acceptance_criteria": [
                    f"All files listed in `{rel_manifest}` exist on disk",
                    "Manifest passes validation with no missing-file errors",
                    "Framework sync/install tools complete without errors",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["stale-manifest", "missing-files", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

        # Report hash mismatches
        if hash_mismatches and severity_meets_threshold("medium", severity_threshold):
            sample = hash_mismatches[:5]
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "framework-pattern",
                "severity": "medium",
                "owning_agent": "guardrails-policy",
                "fallback_agent": "documentation-librarian",
                "file_paths": [rel_manifest] + sample,
                "description": (
                    f"Manifest hash mismatches in `{rel_manifest}`: {len(hash_mismatches)} "
                    f"file(s) have been modified since the manifest was generated: "
                    f"{', '.join(sample[:3])}. "
                    "Hash mismatches indicate the manifest is stale and does not reflect "
                    "current file contents, which may cause incorrect sync behavior."
                ),
                "suggested_fix": (
                    f"Regenerate `{rel_manifest}` with `scripts/generate-manifest.sh` "
                    "after verifying the file changes are intentional. "
                    "If changes were accidental, restore files from git: "
                    "`git checkout HEAD -- <file>`."
                ),
                "acceptance_criteria": [
                    f"All hashes in `{rel_manifest}` match the actual file contents",
                    "Manifest `generated_at` timestamp is recent",
                    "No hash mismatch warnings from framework tools",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["stale-manifest", "hash-mismatch", "framework"],
                    "effort_estimate": "xs",
                },
            }
            findings.append(finding)

    return findings


# ─── Scan: Hook Efficiency ────────────────────────────────────────────────────

def scan_hook_efficiency(
    framework_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect hook efficiency issues: broad matchers, duplicate logic, overlapping patterns."""
    findings = []
    hooks = discover_hooks(framework_dir)

    if verbose:
        print(f"[framework-scan:verbose] Discovered {len(hooks)} hook(s)", file=sys.stderr)

    if not hooks:
        return findings

    # Also check settings.json for hook configuration
    settings_path = framework_dir / ".claude" / "settings.json"
    hook_configs = []
    if settings_path.exists():
        try:
            settings = json.loads(read_text_safe(settings_path))
            # Extract hook configurations
            for hook_type in ["hooks", "UserPromptSubmit", "PreToolUse", "PostToolUse"]:
                if isinstance(settings.get(hook_type), list):
                    for h in settings[hook_type]:
                        if isinstance(h, dict):
                            hook_configs.append(h)
                elif isinstance(settings.get(hook_type), dict):
                    hook_configs.append(settings[hook_type])
        except (json.JSONDecodeError, ValueError, AttributeError):
            pass

    if verbose:
        print(f"[framework-scan:verbose] Found {len(hook_configs)} hook config entries", file=sys.stderr)

    # 1. Check for hooks that run unconditionally (no matcher)
    unconditional_hooks = []
    for hook in hooks:
        content = hook["content"]
        # Signs of unconditional execution: no conditional logic in first 30 lines
        first_lines = "\n".join(content.split("\n")[:30])
        has_condition = bool(re.search(
            r'(if\s+|match\s+|case\s+|\[.*\]|\bgrep\b|\btest\b|==|!=|startswith|endswith)',
            first_lines, re.IGNORECASE
        ))
        # If it's a Python hook reading stdin without early exit conditions
        is_python = hook["path"].suffix == ".py"
        if is_python and not has_condition and hook["size"] > 500:
            unconditional_hooks.append(hook)

    if unconditional_hooks and severity_meets_threshold("low", severity_threshold):
        for hook in unconditional_hooks[:3]:
            if verbose:
                print(f"[framework-scan:verbose] Potentially unconditional hook: {hook['name']}", file=sys.stderr)
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "framework-pattern",
                "severity": "low",
                "owning_agent": "backend-developer",
                "fallback_agent": "guardrails-policy",
                "file_paths": [hook["rel_path"]],
                "description": (
                    f"Hook `{hook['name']}` may run without early-exit conditions. "
                    "Hooks that execute full logic on every trigger (regardless of context) "
                    "add latency to every matching event even when no action is needed. "
                    "This is inefficient for high-frequency hooks like UserPromptSubmit."
                ),
                "suggested_fix": (
                    f"Add an early-exit guard in `{hook['name']}` that checks whether "
                    "the hook applies to the current context before doing any heavy processing. "
                    "Example: check tool name, file extension, or input content patterns "
                    "in the first few lines and exit 0 immediately if not relevant."
                ),
                "acceptance_criteria": [
                    "Hook exits early (< 5ms) when the triggering context doesn't match",
                    "Hook only executes full logic when relevant to the current operation",
                    "Hook behavior is unchanged for matching contexts",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["hook-efficiency", "performance", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    # 2. Check for duplicate logic across hooks
    if len(hooks) >= 2:
        logic_pairs = []
        for i, h1 in enumerate(hooks):
            for h2 in hooks[i+1:]:
                if h1["size"] < 100 or h2["size"] < 100:
                    continue
                overlap = word_overlap(h1["content"], h2["content"])
                if overlap >= 0.6:
                    logic_pairs.append((h1, h2, overlap))

        if logic_pairs and severity_meets_threshold("medium", severity_threshold):
            for h1, h2, overlap in logic_pairs[:3]:
                if verbose:
                    print(f"[framework-scan:verbose] Hook logic overlap: {h1['name']} ~ {h2['name']} ({overlap:.0%})", file=sys.stderr)
                finding = {
                    "id": next_finding_id(),
                    "dimension": "framework",
                    "category": "dedup",
                    "severity": "medium",
                    "owning_agent": "backend-developer",
                    "fallback_agent": "refactoring-specialist",
                    "file_paths": [h1["rel_path"], h2["rel_path"]],
                    "description": (
                        f"Duplicate hook logic between `{h1['name']}` and `{h2['name']}`: "
                        f"{overlap:.0%} content overlap. Duplicate hook code means bugs "
                        "must be fixed in multiple places and behavior can diverge over time."
                    ),
                    "suggested_fix": (
                        f"Extract shared logic from `{h1['name']}` and `{h2['name']}` "
                        "into a shared utility module (e.g., `hooks/hook-utils.py` or "
                        "`hooks/common.sh`). Both hooks then import/source the shared module. "
                        "Alternatively, consolidate into a single hook with broader matching."
                    ),
                    "acceptance_criteria": [
                        "Shared logic exists in exactly one location",
                        "Both hooks produce identical outputs for identical inputs",
                        "No copy-paste code between hook implementations",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["hook-efficiency", "duplicate-logic", "framework"],
                        "effort_estimate": "m",
                    },
                }
                findings.append(finding)

    # 3. Check settings.json for overlapping hook matchers
    if len(hook_configs) >= 2:
        matcher_groups: Dict[str, List[dict]] = defaultdict(list)
        for hc in hook_configs:
            # Common matcher fields
            for field in ["matcher", "tool_name", "pattern", "event"]:
                val = hc.get(field)
                if val:
                    matcher_groups[str(val)].append(hc)

        duplicate_matchers = {k: v for k, v in matcher_groups.items() if len(v) >= 2}
        if duplicate_matchers and severity_meets_threshold("medium", severity_threshold):
            for matcher, hc_list in list(duplicate_matchers.items())[:3]:
                finding = {
                    "id": next_finding_id(),
                    "dimension": "framework",
                    "category": "framework-pattern",
                    "severity": "medium",
                    "owning_agent": "backend-developer",
                    "fallback_agent": "guardrails-policy",
                    "file_paths": [str(settings_path.relative_to(framework_dir))],
                    "description": (
                        f"Overlapping hook matchers in settings.json: "
                        f"{len(hc_list)} hook configurations match on `{matcher}`. "
                        "Multiple hooks with the same matcher run sequentially on every "
                        "matching event, adding cumulative latency."
                    ),
                    "suggested_fix": (
                        f"Consolidate the {len(hc_list)} hooks that match `{matcher}` "
                        "into a single hook with combined logic. Or, separate them with "
                        "more specific matchers to reduce overlap."
                    ),
                    "acceptance_criteria": [
                        "No two hooks share identical matchers in settings.json",
                        "Combined hooks produce equivalent behavior",
                        "Hook execution time per event is reduced",
                    ],
                    "status": "open",
                    "metadata": {
                        "created_at": now_iso(),
                        "scanner_version": SCANNER_VERSION,
                        "tags": ["hook-efficiency", "overlapping-matchers", "framework"],
                        "effort_estimate": "s",
                    },
                }
                findings.append(finding)

    return findings


# ─── Scan: Deprecated Aliases ─────────────────────────────────────────────────

def scan_deprecated_aliases(
    framework_dir: Path,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect deprecated skill aliases and stale references."""
    findings = []

    skills = discover_skills(framework_dir)
    if verbose:
        print(f"[framework-scan:verbose] Checking {len(skills)} skills for deprecated aliases", file=sys.stderr)

    # Patterns that indicate a skill is a deprecated alias or redirect
    DEPRECATED_PATTERNS = [
        re.compile(r'(?i)deprecated', re.MULTILINE),
        re.compile(r'(?i)use\s+[`"]([a-z][a-z0-9-]+)[`"]\s+instead', re.MULTILINE),
        re.compile(r'(?i)alias\s+for\s+[`"]?([a-z][a-z0-9-]+)', re.MULTILINE),
        re.compile(r'(?i)renamed\s+to\s+[`"]?([a-z][a-z0-9-]+)', re.MULTILINE),
        re.compile(r'(?i)moved\s+to\s+[`"]?([a-z][a-z0-9-]+)', re.MULTILINE),
        re.compile(r'(?i)LEGACY', re.MULTILINE),
    ]

    REDIRECT_PATTERN = re.compile(
        r'(?i)(redirect|forward|delegate|invoke|call)\s+.*?[`"]([a-z][a-z0-9-]+)[`"]',
        re.MULTILINE
    )

    deprecated_skills = []
    for skill in skills:
        content = skill["content"]
        is_deprecated = any(p.search(content) for p in DEPRECATED_PATTERNS)
        has_redirect = bool(REDIRECT_PATTERN.search(content))

        if is_deprecated:
            deprecated_skills.append(skill)
            if verbose:
                print(f"[framework-scan:verbose] Deprecated skill found: {skill['name']}", file=sys.stderr)

    if deprecated_skills and severity_meets_threshold("medium", severity_threshold):
        for skill in deprecated_skills[:5]:
            # Determine what it redirects to (if anything)
            redirect_match = REDIRECT_PATTERN.search(skill["content"])
            redirect_target = redirect_match.group(2) if redirect_match else None

            # Check if the redirect target actually exists
            target_exists = redirect_target and any(
                s["name"] == redirect_target for s in skills
            )

            severity = "medium"
            if redirect_target and not target_exists:
                severity = "high"  # Points to a non-existent skill

            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dead-code",
                "severity": severity,
                "owning_agent": "documentation-librarian",
                "fallback_agent": "refactoring-specialist",
                "file_paths": [skill["rel_path"]],
                "description": (
                    f"Deprecated skill alias: `{skill['name']}` is marked as deprecated "
                    + (f"and redirects to `{redirect_target}` " if redirect_target else "")
                    + (f"(which does not exist) " if redirect_target and not target_exists else "")
                    + "but is still active in the framework. Deprecated skills accumulate "
                    "technical debt, confuse users, and may reference stale behavior."
                ),
                "suggested_fix": (
                    f"Remove `{skill['name']}` if it is no longer needed. "
                    + (f"Ensure `{redirect_target}` exists and handles all use cases. " if redirect_target else "")
                    + "Update any documentation or skill registries that reference this skill. "
                    "If backward compatibility is required, keep a minimal redirect for one "
                    "release cycle then remove."
                ),
                "acceptance_criteria": [
                    f"Skill `{skill['name']}` is either removed or undeprecated",
                    "No active workflows/commands reference the deprecated skill",
                    (f"Replacement skill `{redirect_target}` handles all use cases" if redirect_target else "A replacement is documented"),
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["deprecated-alias", "dead-code", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    # Also check for skills that reference skills that don't exist (broken aliases)
    skill_names = {s["name"] for s in skills}
    SKILL_REF_PATTERN = re.compile(r'(?i)/([a-z][a-z0-9-]+)')

    broken_refs = []
    for skill in skills:
        refs = SKILL_REF_PATTERN.findall(skill["content"])
        for ref in refs:
            # Skip common non-skill references
            if ref in {"usr", "bin", "etc", "var", "tmp", "opt", "home", "claude"}:
                continue
            # If it looks like a skill reference and doesn't exist
            if len(ref) > 3 and ref not in skill_names and "-" in ref:
                broken_refs.append((skill, ref))

    if broken_refs and severity_meets_threshold("medium", severity_threshold):
        # Group by skill
        skill_to_broken: Dict[str, List[str]] = defaultdict(list)
        for skill, ref in broken_refs:
            skill_to_broken[skill["name"]].append(ref)

        for skill_name, refs in list(skill_to_broken.items())[:3]:
            skill_data = next(s for s in skills if s["name"] == skill_name)
            unique_refs = list(set(refs))[:5]
            finding = {
                "id": next_finding_id(),
                "dimension": "framework",
                "category": "dead-code",
                "severity": "medium",
                "owning_agent": "documentation-librarian",
                "fallback_agent": "refactoring-specialist",
                "file_paths": [skill_data["rel_path"]],
                "description": (
                    f"Broken skill references in `{skill_name}`: "
                    f"references to {len(unique_refs)} non-existent skill(s): "
                    f"{', '.join(f'`/{r}`' for r in unique_refs)}. "
                    "References to renamed or removed skills cause confusion and "
                    "may cause the skill invocation to fail silently."
                ),
                "suggested_fix": (
                    f"In `{skill_name}`, update references: "
                    + ", ".join(f"`/{r}` → correct skill name" for r in unique_refs[:3])
                    + ". Run `grep -r '/{ref}' .claude/commands/` to find all references "
                    "and update them to the current skill name."
                ),
                "acceptance_criteria": [
                    f"All skill references in `{skill_name}` resolve to existing skills",
                    "No broken `/skill-name` references remain",
                    "Skill invocations succeed without 'skill not found' errors",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["deprecated-alias", "broken-reference", "framework"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    return findings


# ─── Report ───────────────────────────────────────────────────────────────────

def print_summary(findings: List[dict]) -> None:
    """Print a human-readable summary to stderr."""
    total = len(findings)
    by_severity = defaultdict(int)
    by_category = defaultdict(int)
    for f in findings:
        by_severity[f["severity"]] += 1
        by_category[f["category"]] += 1

    print("", file=sys.stderr)
    print("┌─────────────────────────────────────────────┐", file=sys.stderr)
    print("│       Framework Scan Summary                │", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    print(f"│  Total findings:  {total:<26}│", file=sys.stderr)
    print(f"│  🔴 Critical:     {by_severity['critical']:<26}│", file=sys.stderr)
    print(f"│  🟠 High:         {by_severity['high']:<26}│", file=sys.stderr)
    print(f"│  🟡 Medium:       {by_severity['medium']:<26}│", file=sys.stderr)
    print(f"│  🟢 Low:          {by_severity['low']:<26}│", file=sys.stderr)
    print("├─────────────────────────────────────────────┤", file=sys.stderr)
    print("│  By category:                               │", file=sys.stderr)
    for cat, count in sorted(by_category.items()):
        print(f"│    {cat:<20} {count:<22}│", file=sys.stderr)
    print("└─────────────────────────────────────────────┘", file=sys.stderr)


# ─── Main ─────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Framework scanner: skill overlap, agent overlap, stale manifests, hook efficiency, deprecated aliases"
    )
    parser.add_argument("--framework-dir", default=".", help="Framework root directory to scan")
    parser.add_argument("--output-file", default=".refactor/framework-findings.json")
    parser.add_argument(
        "--categories",
        default="skill-overlap,agent-overlap,stale-manifests,hook-efficiency,deprecated-aliases",
        help="Comma-separated list of categories to scan",
    )
    parser.add_argument(
        "--severity-threshold",
        default="low",
        choices=["critical", "high", "medium", "low"],
    )
    parser.add_argument("--format", default="json", choices=["json", "summary"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    framework_dir = Path(args.framework_dir).resolve()
    categories = set(args.categories.split(","))

    print(f"[framework-scan] Framework scanner v{SCANNER_VERSION}", file=sys.stderr)
    print(f"[framework-scan]   Framework dir: {framework_dir}", file=sys.stderr)
    print(f"[framework-scan]   Categories: {args.categories}", file=sys.stderr)
    print(f"[framework-scan]   Severity threshold: {args.severity_threshold}", file=sys.stderr)

    if args.dry_run:
        print(f"[framework-scan] DRY-RUN: would scan {framework_dir}", file=sys.stderr)
        print(f"[framework-scan] DRY-RUN: output → {args.output_file}", file=sys.stderr)
        sys.exit(0)

    all_findings: List[dict] = []

    if "skill-overlap" in categories:
        print("[framework-scan] Scanning skill overlap...", file=sys.stderr)
        findings = scan_skill_overlap(framework_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[framework-scan]   skill-overlap: {len(findings)} finding(s)", file=sys.stderr)

    if "agent-overlap" in categories:
        print("[framework-scan] Scanning agent overlap...", file=sys.stderr)
        findings = scan_agent_overlap(framework_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[framework-scan]   agent-overlap: {len(findings)} finding(s)", file=sys.stderr)

    if "stale-manifests" in categories:
        print("[framework-scan] Scanning stale manifests...", file=sys.stderr)
        findings = scan_stale_manifests(framework_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[framework-scan]   stale-manifests: {len(findings)} finding(s)", file=sys.stderr)

    if "hook-efficiency" in categories:
        print("[framework-scan] Scanning hook efficiency...", file=sys.stderr)
        findings = scan_hook_efficiency(framework_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[framework-scan]   hook-efficiency: {len(findings)} finding(s)", file=sys.stderr)

    if "deprecated-aliases" in categories:
        print("[framework-scan] Scanning deprecated aliases...", file=sys.stderr)
        findings = scan_deprecated_aliases(framework_dir, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[framework-scan]   deprecated-aliases: {len(findings)} finding(s)", file=sys.stderr)

    # Re-index finding IDs sequentially
    for i, finding in enumerate(all_findings):
        finding["id"] = f"RF-{i + 1:03d}"

    # Output
    output_json = json.dumps(all_findings, indent=2)

    if args.format == "summary":
        print_summary(all_findings)

    output_file = Path(args.output_file)
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(output_json + "\n", encoding="utf-8")
    print(f"[framework-scan] Findings written to: {output_file}", file=sys.stderr)

    print_summary(all_findings)

    # Exit codes
    critical_count = sum(1 for f in all_findings if f["severity"] == "critical")
    high_count = sum(1 for f in all_findings if f["severity"] == "high")

    if critical_count > 0 or high_count > 0:
        sys.exit(2)
    elif all_findings:
        sys.exit(1)
    else:
        sys.exit(0)


if __name__ == "__main__":
    main()
