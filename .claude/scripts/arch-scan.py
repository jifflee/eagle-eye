#!/usr/bin/env python3
"""
arch-scan.py
Deep architecture scanner using Python's AST for precise import analysis.

Provides more accurate circular dependency detection using graph algorithms
(Tarjan's SCC / DFS cycle detection) and precise fan-in/fan-out metrics.

USAGE:
  python scripts/arch-scan.py [OPTIONS]

OPTIONS:
  --source-dir DIR          Source directory to scan (default: .)
  --output-file FILE        Output findings JSON (default: .refactor/arch-findings.json)
  --fanout-threshold N      Max imports per module (default: 15)
  --fanin-threshold N       Max importers per non-utility module (default: 20)
  --categories LIST         Comma-separated: circular-dep,coupling,layering,api-surface
  --severity-threshold LVL  Minimum severity: critical|high|medium|low (default: low)
  --format json|summary     Output format (default: json)
  --project-type TYPE       Force project type: python|nodejs|auto (default: auto)
  --dry-run                 Print scan plan, do not execute
  --verbose                 Verbose output

OUTPUT:
  JSON array of findings conforming to refactor-finding.schema.json
  Exit codes: 0=no findings, 1=medium/low only, 2=critical/high found
"""

import ast
import json
import os
import re
import sys
import argparse
import datetime
from pathlib import Path
from collections import defaultdict, deque
from typing import Dict, List, Set, Tuple, Optional

SCANNER_VERSION = "1.0.0"

# ─── Utility helpers ──────────────────────────────────────────────────────────

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1}

EXCLUDE_DIRS = {
    "node_modules", ".git", "__pycache__", "venv", ".venv",
    "dist", "build", ".next", "coverage", ".nyc_output",
    ".refactor", ".claude", "migrations",
}

UTILITY_PATTERNS = re.compile(
    r"(util|lib|helper|common|shared|constant|config|type|fixture|mock)",
    re.IGNORECASE,
)

PRESENTATION_PATTERNS = re.compile(
    r"(page|view|component|ui|route|controller|handler|template|screen)",
    re.IGNORECASE,
)

BUSINESS_PATTERNS = re.compile(
    r"(service|usecase|domain|core|business|logic|manager|workflow|orchestrat)",
    re.IGNORECASE,
)

DATA_PATTERNS = re.compile(
    r"(repositor|model|database|db|dao|persistence|store|storage|migration|schema)",
    re.IGNORECASE,
)

_finding_counter = 0


def next_finding_id() -> str:
    global _finding_counter
    _finding_counter += 1
    return f"RF-{_finding_counter:03d}"


def now_iso() -> str:
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def severity_meets_threshold(severity: str, threshold: str) -> bool:
    return SEVERITY_ORDER.get(severity, 0) >= SEVERITY_ORDER.get(threshold, 0)


def is_excluded(path: Path) -> bool:
    for part in path.parts:
        if part in EXCLUDE_DIRS:
            return True
    return False


def find_source_files(source_dir: Path, extensions: List[str]) -> List[Path]:
    files = []
    for ext in extensions:
        for f in source_dir.rglob(f"*{ext}"):
            if not is_excluded(f):
                files.append(f)
    return sorted(files)


def detect_project_type(source_dir: Path) -> str:
    if (source_dir / "pyproject.toml").exists() or (source_dir / "requirements.txt").exists():
        return "python"
    if (source_dir / "package.json").exists():
        return "nodejs"
    if (source_dir / "go.mod").exists():
        return "go"
    if (source_dir / "Cargo.toml").exists():
        return "rust"
    # Check which has more files
    py_count = len(list(source_dir.rglob("*.py")))
    ts_count = len(list(source_dir.rglob("*.ts")))
    return "python" if py_count >= ts_count else "nodejs"


# ─── Import Graph Builder ─────────────────────────────────────────────────────

def extract_python_imports(filepath: Path, source_dir: Path) -> List[str]:
    """Extract imports from a Python file using AST. Returns list of module paths."""
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, UnicodeDecodeError):
        return []

    imports = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imports.append(alias.name)
        elif isinstance(node, ast.ImportFrom):
            if node.module:
                # Relative imports: resolve based on file location
                if node.level and node.level > 0:
                    # Relative import - resolve to absolute path
                    parent = filepath.parent
                    for _ in range(node.level - 1):
                        parent = parent.parent
                    rel_module = parent / node.module.replace(".", "/")
                    try:
                        rel = rel_module.relative_to(source_dir)
                        imports.append(str(rel))
                    except ValueError:
                        imports.append(node.module)
                else:
                    imports.append(node.module)
    return imports


def extract_ts_imports(filepath: Path, source_dir: Path) -> List[str]:
    """Extract imports from TypeScript/JavaScript using regex."""
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []

    imports = []
    # Match: import X from './path', require('./path'), import('./path')
    patterns = [
        r"""(?:import|export)\s+(?:[\w\s{},*]+\s+from\s+)?['"]([^'"]+)['"]""",
        r"""require\s*\(\s*['"]([^'"]+)['"]\s*\)""",
        r"""import\s*\(\s*['"]([^'"]+)['"]\s*\)""",
    ]
    for pattern in patterns:
        for match in re.finditer(pattern, source):
            imp = match.group(1)
            if imp.startswith("."):
                # Relative import - resolve to file path
                resolved = (filepath.parent / imp).resolve()
                try:
                    rel = resolved.relative_to(source_dir.resolve())
                    imports.append(str(rel))
                except ValueError:
                    imports.append(imp)
            else:
                imports.append(imp)
    return imports


def normalize_python_imports(
    raw_imports: List[str], source_dir: Path, known_files: Set[str]
) -> List[str]:
    """
    Normalize Python module names to file paths where possible.
    e.g. 'payments.charge' → 'src/payments/charge.py' if that file exists.
    Falls back to the raw module name if no file match found.
    """
    normalized = []
    for imp in raw_imports:
        # Skip standard library and third-party packages (no '.' slash resolution needed)
        # Try: module.submodule → module/submodule.py or module/submodule/__init__.py
        module_path = imp.replace(".", "/")

        # Try direct file paths relative to source root
        candidates = [
            f"{module_path}.py",
            f"{module_path}/__init__.py",
            f"src/{module_path}.py",
            f"src/{module_path}/__init__.py",
        ]

        matched = False
        for candidate in candidates:
            if candidate in known_files:
                normalized.append(candidate)
                matched = True
                break

        if not matched:
            # Also check if any known file ends with the module path
            for known in known_files:
                known_no_ext = known.replace("/__init__.py", "").replace(".py", "")
                if known_no_ext.endswith(module_path):
                    normalized.append(known)
                    matched = True
                    break

        if not matched:
            # Keep raw for external packages
            normalized.append(imp)

    return normalized


def build_import_graph(
    source_dir: Path, project_type: str
) -> Dict[str, List[str]]:
    """Build file→imports graph. Returns {file_path: [imported_module, ...]}."""
    graph: Dict[str, List[str]] = {}

    if project_type == "python":
        files = find_source_files(source_dir, [".py"])
        raw_graph: Dict[str, List[str]] = {}
        for f in files:
            rel = str(f.relative_to(source_dir))
            raw_graph[rel] = extract_python_imports(f, source_dir)

        # Normalize module names to file paths
        known_files = set(raw_graph.keys())
        for rel, raw_imports in raw_graph.items():
            graph[rel] = normalize_python_imports(raw_imports, source_dir, known_files)

    elif project_type in ("nodejs", "mixed"):
        files = find_source_files(source_dir, [".ts", ".tsx", ".js", ".jsx"])
        for f in files:
            rel = str(f.relative_to(source_dir))
            graph[rel] = extract_ts_imports(f, source_dir)
    else:
        # Both Python and TS/JS
        py_files = find_source_files(source_dir, [".py"])
        raw_graph = {}
        for f in py_files:
            rel = str(f.relative_to(source_dir))
            raw_graph[rel] = extract_python_imports(f, source_dir)
        known_files = set(raw_graph.keys())
        for rel, raw_imports in raw_graph.items():
            graph[rel] = normalize_python_imports(raw_imports, source_dir, known_files)

        for f in find_source_files(source_dir, [".ts", ".tsx", ".js", ".jsx"]):
            rel = str(f.relative_to(source_dir))
            graph[rel] = extract_ts_imports(f, source_dir)

    return graph


def normalize_module_to_file(module: str, source_dir: Path, importer: Path) -> Optional[str]:
    """Try to resolve a module string to a relative file path."""
    # Already looks like a path
    if "/" in module or module.endswith(".py"):
        return module

    # Try Python module → file mapping
    module_path = module.replace(".", "/")
    candidates = [
        source_dir / f"{module_path}.py",
        source_dir / module_path / "__init__.py",
        source_dir / f"{module_path}.ts",
        source_dir / f"{module_path}.js",
    ]
    for c in candidates:
        if c.exists():
            try:
                return str(c.relative_to(source_dir))
            except ValueError:
                pass
    return None


# ─── Cycle Detection (Tarjan's SCC) ──────────────────────────────────────────

def find_cycles_tarjan(graph: Dict[str, List[str]]) -> List[List[str]]:
    """
    Find all strongly connected components with size > 1 using Tarjan's algorithm.
    These represent circular dependency groups.
    """
    index_counter = [0]
    stack = []
    lowlink: Dict[str, int] = {}
    index: Dict[str, int] = {}
    on_stack: Dict[str, bool] = {}
    sccs: List[List[str]] = []

    def strongconnect(v: str):
        index[v] = index_counter[0]
        lowlink[v] = index_counter[0]
        index_counter[0] += 1
        stack.append(v)
        on_stack[v] = True

        for w in graph.get(v, []):
            # Only follow edges to known nodes
            if w not in graph:
                continue
            if w not in index:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif on_stack.get(w, False):
                lowlink[v] = min(lowlink[v], index[w])

        if lowlink[v] == index[v]:
            scc = []
            while True:
                w = stack.pop()
                on_stack[w] = False
                scc.append(w)
                if w == v:
                    break
            if len(scc) > 1:
                sccs.append(scc)

    for v in graph:
        if v not in index:
            try:
                strongconnect(v)
            except RecursionError:
                # Fall back for deep graphs
                pass

    return sccs


def find_mutual_deps(graph: Dict[str, List[str]]) -> List[Tuple[str, str]]:
    """Find all pairs of files that import each other."""
    pairs = []
    seen = set()
    for f, deps in graph.items():
        for dep in deps:
            if dep in graph and f in graph.get(dep, []):
                pair = tuple(sorted([f, dep]))
                if pair not in seen:
                    seen.add(pair)
                    pairs.append((f, dep))
    return pairs


# ─── Layer Classification ─────────────────────────────────────────────────────

def classify_layer(filepath: str) -> str:
    """Classify a file path into an architectural layer."""
    path_lower = filepath.lower()
    if PRESENTATION_PATTERNS.search(path_lower):
        return "presentation"
    if BUSINESS_PATTERNS.search(path_lower):
        return "business"
    if DATA_PATTERNS.search(path_lower):
        return "data"
    if UTILITY_PATTERNS.search(path_lower):
        return "utility"
    # Check for test files
    if re.search(r"(test_|_test\.|\.test\.|\.spec\.)", path_lower):
        return "test"
    return "unknown"


# ─── Scan Functions ───────────────────────────────────────────────────────────

def scan_circular_deps(
    graph: Dict[str, List[str]],
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect circular dependencies using Tarjan's SCC algorithm."""
    findings = []

    # Build normalized graph for cycle detection
    # Only include files that exist in our graph as nodes
    known_files = set(graph.keys())
    normalized_graph: Dict[str, List[str]] = {}
    for f, deps in graph.items():
        normalized_deps = []
        for dep in deps:
            # Try to match dep to a known file
            # Direct match
            if dep in known_files:
                normalized_deps.append(dep)
                continue
            # Match by prefix (e.g., "src/utils" matches "src/utils.py")
            for known in known_files:
                if known.startswith(dep) or dep.startswith(known.rsplit(".", 1)[0]):
                    normalized_deps.append(known)
                    break
        normalized_graph[f] = normalized_deps

    # Find SCCs (groups of mutually dependent files)
    sccs = find_cycles_tarjan(normalized_graph)

    if verbose:
        print(f"[arch-scan:verbose] Found {len(sccs)} circular dependency group(s)", file=sys.stderr)

    for scc in sccs[:10]:  # Cap at 10 findings
        severity = "critical" if len(scc) == 2 else "high"

        if not severity_meets_threshold(severity, severity_threshold):
            continue

        cycle_str = " → ".join(sorted(scc)[:5])
        if len(scc) > 5:
            cycle_str += f" ... (+{len(scc) - 5} more)"

        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "circular-dep",
            "severity": severity,
            "owning_agent": "architect",
            "fallback_agent": "refactoring-specialist",
            "file_paths": sorted(scc)[:5],
            "description": (
                f"Circular dependency group detected ({len(scc)} modules): {cycle_str}. "
                "These modules form a strongly connected component — each can reach all others "
                "via import chains. This prevents independent testing, creates initialization "
                "order issues, and makes each module impossible to use without the whole group."
            ),
            "suggested_fix": (
                "Break the cycle by: (1) extracting shared types/interfaces to a new common "
                "module that all group members depend on but none of which depend on each other; "
                "(2) applying Dependency Inversion — modules depend on abstractions (protocols/"
                "interfaces) not concrete implementations; (3) for runtime-only cycles, use "
                "lazy imports (TYPE_CHECKING guard in Python, dynamic import() in JS)."
            ),
            "acceptance_criteria": [
                "No circular import path exists between the identified modules",
                "Each module can be imported independently without side effects",
                "Tarjan's SCC analysis produces no SCC of size > 1 for these modules",
                "All existing tests pass after refactoring",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["circular-dep", "architecture", "scc"],
                "effort_estimate": "l" if len(scc) > 5 else "m",
            },
        }
        findings.append(finding)

    # Also report mutual deps not caught by SCC (edge case with normalization)
    mutual = find_mutual_deps(normalized_graph)
    for f, dep in mutual[:5]:
        if not any(f in fc["file_paths"] and dep in fc["file_paths"] for fc in findings):
            if not severity_meets_threshold("high", severity_threshold):
                continue
            finding = {
                "id": next_finding_id(),
                "dimension": "architecture",
                "category": "circular-dep",
                "severity": "high",
                "owning_agent": "architect",
                "fallback_agent": "refactoring-specialist",
                "file_paths": sorted([f, dep]),
                "description": (
                    f"Mutual dependency: {f} and {dep} import each other directly. "
                    "This tight coupling means neither module can be tested or deployed "
                    "without the other."
                ),
                "suggested_fix": (
                    "Extract the shared dependency into a third module. Use dependency "
                    "injection to pass shared state rather than importing between the two files."
                ),
                "acceptance_criteria": [
                    f"{f} does not import from {dep} (or vice versa)",
                    "Shared code is in a separate, independent module",
                    "Both modules have passing independent unit tests",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["circular-dep", "mutual-dep"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    return findings


def scan_coupling(
    graph: Dict[str, List[str]],
    fanout_threshold: int,
    fanin_threshold: int,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect high fan-in and fan-out coupling issues."""
    findings = []

    # Fan-out: files importing too many others
    fanout = {f: len(set(deps)) for f, deps in graph.items()}
    high_fanout = sorted(
        [(f, n) for f, n in fanout.items() if n > fanout_threshold],
        key=lambda x: -x[1],
    )

    if verbose:
        print(f"[arch-scan:verbose] Fan-out violations: {len(high_fanout)}", file=sys.stderr)

    for filepath, count in high_fanout[:10]:
        severity = "medium"
        if count > fanout_threshold * 3:
            severity = "critical"
        elif count > fanout_threshold * 2:
            severity = "high"

        if not severity_meets_threshold(severity, severity_threshold):
            continue

        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": severity,
            "owning_agent": "architect",
            "fallback_agent": "refactoring-specialist",
            "file_paths": [filepath],
            "description": (
                f"High fan-out: {filepath} imports {count} distinct modules "
                f"(threshold: {fanout_threshold}). A module with this many dependencies "
                "is likely doing too many things, is hard to test in isolation, and becomes "
                "a change magnet — every dependency change risks breaking it."
            ),
            "suggested_fix": (
                f"Decompose {filepath} into focused sub-modules, each with ≤{fanout_threshold} "
                "dependencies. Apply the Facade pattern to present a unified interface while "
                "delegating to specialized sub-modules. Group related imports into cohesive "
                "modules. Consider dependency injection for frequently-changed dependencies."
            ),
            "acceptance_criteria": [
                f"Module fan-out is below {fanout_threshold}",
                "Each extracted sub-module has a single clear responsibility",
                "All existing tests pass after decomposition",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["coupling", "fan-out"],
                "effort_estimate": "l" if count > fanout_threshold * 2 else "m",
            },
        }
        findings.append(finding)

    # Fan-in: build reverse graph
    fanin: Dict[str, List[str]] = defaultdict(list)
    for importer, deps in graph.items():
        for dep in deps:
            fanin[dep].append(importer)

    # High fan-in on non-utility modules
    high_fanin = sorted(
        [
            (mod, importers)
            for mod, importers in fanin.items()
            if len(importers) > fanin_threshold and not UTILITY_PATTERNS.search(mod.lower())
        ],
        key=lambda x: -len(x[1]),
    )

    if verbose:
        print(f"[arch-scan:verbose] Fan-in violations: {len(high_fanin)}", file=sys.stderr)

    for module, importers in high_fanin[:5]:
        severity = "high" if len(importers) > fanin_threshold * 2 else "medium"

        if not severity_meets_threshold(severity, severity_threshold):
            continue

        sample_importers = sorted(importers)[:3]

        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": severity,
            "owning_agent": "architect",
            "fallback_agent": "backend-developer",
            "file_paths": [module] + sample_importers,
            "description": (
                f"High fan-in on non-utility module: {module} is imported by "
                f"{len(importers)} modules (threshold: {fanin_threshold}). "
                "This module has accumulated too many responsibilities and has become "
                "an unintentional god object, creating hidden coupling across the codebase."
            ),
            "suggested_fix": (
                f"If {module} is a utility, move it to a utilities directory and clearly "
                "document its role. If it has mixed concerns, decompose it — extract each "
                "distinct responsibility into its own module. Consider whether importers "
                "could use dependency injection rather than direct imports."
            ),
            "acceptance_criteria": [
                "Module has a single, clearly documented responsibility",
                f"Module is either in utilities (fan-in expected) or fan-in < {fanin_threshold}",
                "No circular dependencies introduced by decomposition",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["coupling", "fan-in", "god-object"],
                "effort_estimate": "l",
            },
        }
        findings.append(finding)

    return findings


def scan_layering(
    graph: Dict[str, List[str]],
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Detect layering violations based on file path conventions."""
    findings = []

    # Classify each file
    layer_map = {f: classify_layer(f) for f in graph}

    if verbose:
        from collections import Counter
        counts = Counter(layer_map.values())
        print(f"[arch-scan:verbose] Layer classification: {dict(counts)}", file=sys.stderr)

    # Violation 1: presentation → data (skipping business)
    pres_to_data: List[Tuple[str, str]] = []
    for f, deps in graph.items():
        if layer_map.get(f) == "presentation":
            for dep in deps:
                if classify_layer(dep) == "data":
                    pres_to_data.append((f, dep))

    if pres_to_data and severity_meets_threshold("high", severity_threshold):
        files = sorted({f for f, _ in pres_to_data} | {d for _, d in pres_to_data})[:5]
        examples = "; ".join(f"{f} → {d}" for f, d in pres_to_data[:3])
        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": "high",
            "owning_agent": "architect",
            "fallback_agent": "backend-developer",
            "file_paths": files,
            "description": (
                f"Layering violation: {len(pres_to_data)} direct import(s) from "
                "presentation layer to data/persistence layer, bypassing the service/business "
                f"layer. Examples: {examples}. This couples UI concerns directly to "
                "persistence, making both harder to change independently."
            ),
            "suggested_fix": (
                "Route all data access through the service/business layer. "
                "Presentation components should depend on service interfaces only. "
                "Create service methods that encapsulate the data access. "
                "If no service layer exists, introduce one as a thin coordination layer."
            ),
            "acceptance_criteria": [
                "No direct imports from presentation layer to data/repository layer",
                "All data access goes through service layer interfaces",
                "Presentation layer tests can mock the service layer without touching storage",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["layering", "presentation-to-data"],
                "effort_estimate": "m",
            },
        }
        findings.append(finding)

    # Violation 2: utility → business logic
    util_to_biz: List[Tuple[str, str]] = []
    for f, deps in graph.items():
        if layer_map.get(f) == "utility":
            for dep in deps:
                if classify_layer(dep) == "business":
                    util_to_biz.append((f, dep))

    if util_to_biz and severity_meets_threshold("medium", severity_threshold):
        files = sorted({f for f, _ in util_to_biz})[:5]
        examples = "; ".join(f"{f} → {d}" for f, d in util_to_biz[:3])
        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": "medium",
            "owning_agent": "architect",
            "fallback_agent": "refactoring-specialist",
            "file_paths": files,
            "description": (
                f"Layering violation: {len(util_to_biz)} utility module(s) importing "
                f"from business logic layer. Examples: {examples}. "
                "Pure utilities should be domain-agnostic; importing business logic "
                "creates an inverted dependency that prevents reuse across contexts."
            ),
            "suggested_fix": (
                "Remove business logic imports from utility modules. "
                "Pass business-specific behavior as parameters or callbacks (dependency "
                "injection) rather than hard-coding it in utilities. "
                "If the utility is truly business-specific, move it to the business layer."
            ),
            "acceptance_criteria": [
                "Utility modules contain no imports from service/business logic layer",
                "Business-specific behavior is injected via parameters",
                "Utility modules can be used across different business domains without changes",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["layering", "utility-to-business"],
                "effort_estimate": "s",
            },
        }
        findings.append(finding)

    # Violation 3: test → test cross-imports
    test_to_test: List[Tuple[str, str]] = []
    for f, deps in graph.items():
        if layer_map.get(f) == "test":
            for dep in deps:
                if classify_layer(dep) == "test" and dep != f:
                    test_to_test.append((f, dep))

    if test_to_test and severity_meets_threshold("medium", severity_threshold):
        files = sorted({f for f, _ in test_to_test})[:5]
        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": "medium",
            "owning_agent": "architect",
            "fallback_agent": "test-qa",
            "file_paths": files,
            "description": (
                f"Test isolation violation: {len(test_to_test)} test file(s) importing "
                "from other test files. Tests should be independent; cross-test imports "
                "create fragile suites where changes to one test file can break unrelated tests."
            ),
            "suggested_fix": (
                "Extract shared test utilities into a dedicated directory: "
                "tests/helpers/, tests/fixtures/, or tests/factories/. "
                "These shared modules should be clearly named as test infrastructure, "
                "not test files themselves (e.g., conftest.py in Python, setup-test.ts in JS)."
            ),
            "acceptance_criteria": [
                "No test files import from other test files",
                "Shared test utilities are in a dedicated helpers/fixtures directory",
                "Each test file can run independently",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["layering", "test-isolation"],
                "effort_estimate": "s",
            },
        }
        findings.append(finding)

    return findings


def scan_api_surface(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """Analyze API surface for deprecated endpoints, naming issues, and coverage gaps."""
    findings = []

    # Route detection patterns
    route_patterns = {
        "python": re.compile(
            r"""@(?:app|router|blueprint)\s*\.\s*(?:route|get|post|put|delete|patch)\s*\(\s*['"]([^'"]+)['"]""",
            re.MULTILINE,
        ),
        "nodejs": re.compile(
            r"""(?:router|app)\s*\.\s*(?:get|post|put|delete|patch|all)\s*\(\s*['"]([^'"]+)['"]""",
            re.MULTILINE,
        ),
    }

    deprecated_pattern = re.compile(
        r"""@deprecated|#\s*DEPRECATED|//\s*DEPRECATED|DEPRECATED\s*[:=]""",
        re.IGNORECASE,
    )

    # Find route files
    if project_type == "python":
        extensions = [".py"]
        route_pat = route_patterns["python"]
    else:
        extensions = [".ts", ".tsx", ".js"]
        route_pat = route_patterns["nodejs"]

    route_files = []
    all_routes: Dict[str, List[str]] = {}  # file → [routes]
    deprecated_routes: List[Tuple[str, str]] = []

    for f in find_source_files(source_dir, extensions):
        # Skip test files
        if re.search(r"(test_|_test\.|\.test\.|\.spec\.)", f.name.lower()):
            continue

        try:
            content = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        routes = route_pat.findall(content)
        if routes:
            rel = str(f.relative_to(source_dir))
            route_files.append(rel)
            all_routes[rel] = routes

            # Check for deprecated annotations
            lines = content.split("\n")
            for i, line in enumerate(lines):
                if deprecated_pattern.search(line):
                    deprecated_routes.append((rel, line.strip()))

    if verbose:
        print(f"[arch-scan:verbose] Found {len(route_files)} route file(s)", file=sys.stderr)
        print(f"[arch-scan:verbose] Total routes: {sum(len(v) for v in all_routes.values())}", file=sys.stderr)

    # Finding 1: Deprecated endpoints still active
    if deprecated_routes and severity_meets_threshold("medium", severity_threshold):
        files = sorted({f for f, _ in deprecated_routes})[:5]
        finding = {
            "id": next_finding_id(),
            "dimension": "architecture",
            "category": "coupling",
            "severity": "medium",
            "owning_agent": "api-designer",
            "fallback_agent": "backend-developer",
            "file_paths": files if files else ["(detected in route scan)"],
            "description": (
                f"Deprecated API endpoints still active: {len(deprecated_routes)} "
                "deprecated route(s) found in the codebase. Deprecated routes accumulate "
                "technical debt, confuse API consumers, and may not receive security patches."
            ),
            "suggested_fix": (
                "For each deprecated endpoint: (1) if no active consumers — remove it; "
                "(2) if consumers exist — create migration guide, set Sunset header with "
                "removal date, and return Deprecation header per RFC 8594; "
                "(3) document in CHANGELOG with migration path."
            ),
            "acceptance_criteria": [
                "Each deprecated endpoint has a documented migration path or has been removed",
                "Active deprecated endpoints return Deprecation and Sunset HTTP headers",
                "Deprecation timeline is documented in CHANGELOG or API docs",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["api-surface", "deprecated"],
                "effort_estimate": "m",
            },
        }
        findings.append(finding)

    # Finding 2: Inconsistent endpoint naming
    if all_routes:
        snake_routes = []
        kebab_routes = []
        camel_routes = []

        for file_routes in all_routes.values():
            for route in file_routes:
                segments = [s for s in route.split("/") if s and not s.startswith("{") and not s.startswith(":")]
                for seg in segments:
                    if "_" in seg and seg == seg.lower():
                        snake_routes.append(route)
                    elif "-" in seg:
                        kebab_routes.append(route)
                    elif seg != seg.lower() and "_" not in seg:
                        camel_routes.append(route)

        style_count = sum(1 for lst in [snake_routes, kebab_routes, camel_routes] if lst)
        if style_count > 1 and severity_meets_threshold("low", severity_threshold):
            dominant = max(
                [("snake_case", len(snake_routes)), ("kebab-case", len(kebab_routes)), ("camelCase", len(camel_routes))],
                key=lambda x: x[1],
            )[0]

            finding = {
                "id": next_finding_id(),
                "dimension": "architecture",
                "category": "naming",
                "severity": "low",
                "owning_agent": "api-designer",
                "fallback_agent": "backend-developer",
                "file_paths": list(all_routes.keys())[:3],
                "description": (
                    f"Inconsistent API endpoint naming: {len(snake_routes)} snake_case, "
                    f"{len(kebab_routes)} kebab-case, {len(camel_routes)} camelCase routes "
                    "detected. REST standards (RFC 3986) recommend kebab-case for URL paths."
                ),
                "suggested_fix": (
                    f"Standardize on {dominant} (REST standard is kebab-case). "
                    "Add a lint rule or test to enforce the convention on new routes. "
                    "Migrate existing routes with backward-compatible redirects (301) "
                    "if external consumers depend on the old URLs."
                ),
                "acceptance_criteria": [
                    "All API route path segments use a single consistent naming convention",
                    "Naming convention is documented in API style guide",
                    "Automated check (lint/test) enforces the convention going forward",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["api-surface", "naming", "consistency"],
                    "effort_estimate": "s",
                },
            }
            findings.append(finding)

    # Finding 3: Route files with no corresponding tests
    if all_routes and severity_meets_threshold("medium", severity_threshold):
        untested: List[str] = []
        for rel_file in route_files:
            basename = Path(rel_file).stem
            # Look for test files referencing this module
            has_test = False
            test_patterns = [
                f"test_{basename}",
                f"{basename}_test",
                f"{basename}.test",
                f"{basename}.spec",
            ]
            for f in find_source_files(source_dir, extensions + [".py"]):
                if any(p in f.stem for p in test_patterns):
                    has_test = True
                    break
                # Check if this test file imports the route file
                try:
                    content = f.read_text(encoding="utf-8", errors="replace")
                    if re.search(r"(test_|_test\.|\.test\.|\.spec\.)", f.name.lower()):
                        if basename in content:
                            has_test = True
                            break
                except OSError:
                    pass

            if not has_test:
                untested.append(rel_file)

        if untested:
            finding = {
                "id": next_finding_id(),
                "dimension": "architecture",
                "category": "missing-tests",
                "severity": "medium",
                "owning_agent": "api-designer",
                "fallback_agent": "test-qa",
                "file_paths": untested[:5],
                "description": (
                    f"API surface gap: {len(untested)} route file(s) have no corresponding "
                    "test coverage. Untested endpoints are invisible to CI, prone to regression, "
                    "and create uncertainty about their contract and error behavior."
                ),
                "suggested_fix": (
                    "Create integration tests for each untested route file: "
                    "(1) happy path with valid input, (2) error cases with invalid input, "
                    "(3) auth checks if applicable, (4) edge cases (empty body, large payload). "
                    "Use pytest-httpx, Django test client, supertest, or similar."
                ),
                "acceptance_criteria": [
                    "Every route file has at least one corresponding test file",
                    "Tests cover happy path and at least one error case per endpoint",
                    "CI runs API tests on every PR",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["api-surface", "missing-tests", "coverage"],
                    "effort_estimate": "m",
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
    print("│        Architecture Scan Summary            │", file=sys.stderr)
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


# ─── Main ────────────────────────────────────────────────────────────────────

def parse_args():
    parser = argparse.ArgumentParser(
        description="Architecture scanner: circular deps, coupling, layering, API surface"
    )
    parser.add_argument("--source-dir", default=".", help="Source directory to scan")
    parser.add_argument("--output-file", default=".refactor/arch-findings.json")
    parser.add_argument("--fanout-threshold", type=int, default=15)
    parser.add_argument("--fanin-threshold", type=int, default=20)
    parser.add_argument(
        "--categories",
        default="circular-dep,coupling,layering,api-surface",
        help="Comma-separated list of categories to scan",
    )
    parser.add_argument(
        "--severity-threshold",
        default="low",
        choices=["critical", "high", "medium", "low"],
    )
    parser.add_argument("--format", default="json", choices=["json", "summary"])
    parser.add_argument(
        "--project-type",
        default="auto",
        choices=["python", "nodejs", "mixed", "auto"],
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    categories = set(args.categories.split(","))

    print(f"[arch-scan] Architecture scanner v{SCANNER_VERSION}", file=sys.stderr)
    print(f"[arch-scan]   Source dir: {source_dir}", file=sys.stderr)
    print(f"[arch-scan]   Categories: {args.categories}", file=sys.stderr)
    print(f"[arch-scan]   Fan-out threshold: {args.fanout_threshold}", file=sys.stderr)
    print(f"[arch-scan]   Fan-in threshold: {args.fanin_threshold}", file=sys.stderr)

    if args.dry_run:
        print(f"[arch-scan] DRY-RUN: would scan {source_dir}", file=sys.stderr)
        print(f"[arch-scan] DRY-RUN: output → {args.output_file}", file=sys.stderr)
        sys.exit(0)

    # Detect project type
    project_type = args.project_type
    if project_type == "auto":
        project_type = detect_project_type(source_dir)
    print(f"[arch-scan]   Project type: {project_type}", file=sys.stderr)

    # Build import graph (used by multiple scanners)
    all_findings: List[dict] = []

    graph: Dict[str, List[str]] = {}
    if categories & {"circular-dep", "coupling", "layering"}:
        print("[arch-scan] Building import graph...", file=sys.stderr)
        graph = build_import_graph(source_dir, project_type)
        node_count = len(graph)
        edge_count = sum(len(v) for v in graph.values())
        print(f"[arch-scan]   Graph: {node_count} nodes, {edge_count} edges", file=sys.stderr)

    # Run scans
    if "circular-dep" in categories:
        print("[arch-scan] Scanning circular dependencies...", file=sys.stderr)
        findings = scan_circular_deps(graph, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[arch-scan]   circular-dep: {len(findings)} finding(s)", file=sys.stderr)

    if "coupling" in categories:
        print("[arch-scan] Scanning coupling metrics...", file=sys.stderr)
        findings = scan_coupling(
            graph,
            args.fanout_threshold,
            args.fanin_threshold,
            args.severity_threshold,
            args.verbose,
        )
        all_findings.extend(findings)
        print(f"[arch-scan]   coupling: {len(findings)} finding(s)", file=sys.stderr)

    if "layering" in categories:
        print("[arch-scan] Scanning layering violations...", file=sys.stderr)
        findings = scan_layering(graph, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[arch-scan]   layering: {len(findings)} finding(s)", file=sys.stderr)

    if "api-surface" in categories:
        print("[arch-scan] Scanning API surface...", file=sys.stderr)
        findings = scan_api_surface(
            source_dir, project_type, args.severity_threshold, args.verbose
        )
        all_findings.extend(findings)
        print(f"[arch-scan]   api-surface: {len(findings)} finding(s)", file=sys.stderr)

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
    print(f"[arch-scan] Findings written to: {output_file}", file=sys.stderr)

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
