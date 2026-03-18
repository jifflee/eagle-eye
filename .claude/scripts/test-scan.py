#!/usr/bin/env python3
"""
test-scan.py
Test quality scanner: dead fixtures, duplicate tests, coverage gaps, flaky indicators.

READ-ONLY analysis. Produces findings in refactor-finding.schema.json format.

USAGE:
  python scripts/test-scan.py [OPTIONS]

OPTIONS:
  --source-dir DIR          Source directory to scan (default: .)
  --test-dir DIR            Test directory override (default: auto-detect)
  --output-file FILE        Output findings JSON (default: .refactor/test-findings.json)
  --categories LIST         Comma-separated: dead-fixtures,duplicate-tests,coverage-gaps,flaky
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
from collections import defaultdict
from typing import Dict, List, Set, Optional, Tuple

SCANNER_VERSION = "1.0.0"

# ─── Severity helpers ─────────────────────────────────────────────────────────

SEVERITY_ORDER = {"critical": 4, "high": 3, "medium": 2, "low": 1}

EXCLUDE_DIRS = {
    "node_modules", ".git", "__pycache__", "venv", ".venv",
    "dist", "build", ".next", "coverage", ".nyc_output",
    ".refactor", ".claude", "migrations",
}

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
    py_count = len(list(source_dir.rglob("*.py")))
    ts_count = len(list(source_dir.rglob("*.ts")))
    return "python" if py_count >= ts_count else "nodejs"


def is_test_file(path: Path, project_type: str) -> bool:
    """Return True if the given file is a test file."""
    name = path.name.lower()
    if project_type == "python":
        return name.startswith("test_") or name.endswith("_test.py")
    else:
        return bool(re.search(r"\.(test|spec)\.(ts|tsx|js|jsx)$", name))


def find_test_files(source_dir: Path, project_type: str) -> List[Path]:
    """Find all test files in the source directory."""
    if project_type == "python":
        return [
            f for f in find_source_files(source_dir, [".py"])
            if is_test_file(f, project_type)
        ]
    else:
        return [
            f for f in find_source_files(source_dir, [".ts", ".tsx", ".js", ".jsx"])
            if is_test_file(f, project_type)
        ] + [
            f for f in source_dir.rglob("**")
            if not is_excluded(f) and f.is_file() and "__tests__" in str(f)
        ]


def find_fixture_dirs(source_dir: Path) -> List[Path]:
    """Find directories that look like test fixture directories."""
    fixture_dirs = []
    fixture_patterns = re.compile(
        r"^(fixtures?|test.?data|testdata|mock.?data|__fixtures__|stubs?|mocks?)$",
        re.IGNORECASE,
    )
    for d in source_dir.rglob("*"):
        if d.is_dir() and not is_excluded(d) and fixture_patterns.match(d.name):
            fixture_dirs.append(d)
    return fixture_dirs


# ─── Python AST helpers ───────────────────────────────────────────────────────

def extract_python_test_functions(filepath: Path) -> List[Tuple[str, int, str]]:
    """
    Extract test function/method names from a Python test file.
    Returns [(name, line_number, source_snippet), ...].
    """
    functions = []
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, UnicodeDecodeError):
        return functions

    lines = source.splitlines()
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name.startswith("test"):
                # Get a brief snippet (docstring or first line of body)
                snippet = ""
                if (
                    node.body
                    and isinstance(node.body[0], ast.Expr)
                    and isinstance(node.body[0].value, ast.Constant)
                    and isinstance(node.body[0].value.value, str)
                ):
                    snippet = node.body[0].value.value.strip()[:80]
                functions.append((node.name, node.lineno, snippet))
    return functions


def extract_python_source_functions(filepath: Path) -> List[Tuple[str, int]]:
    """
    Extract public function/method names from a Python source file.
    Returns [(name, line_number), ...].
    """
    functions = []
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, UnicodeDecodeError):
        return functions

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            # Skip private methods (starting with _), test functions, __special__
            if not node.name.startswith("_") and not node.name.startswith("test"):
                functions.append((node.name, node.lineno))
    return functions


def get_python_test_body_hash(filepath: Path, func_name: str) -> Optional[str]:
    """
    Get a simplified hash of a test function's body for duplicate detection.
    Strips variable names and whitespace to detect near-identical logic.
    """
    try:
        source = filepath.read_text(encoding="utf-8", errors="replace")
        tree = ast.parse(source, filename=str(filepath))
    except (SyntaxError, UnicodeDecodeError):
        return None

    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == func_name:
            # Get source lines for this function
            start = node.lineno
            end = getattr(node, "end_lineno", start + 20)
            lines = source.splitlines()[start - 1:end]
            # Strip the function signature line
            body_lines = lines[1:] if lines else []
            # Normalize: remove leading/trailing whitespace, blank lines
            normalized = "\n".join(
                re.sub(r'\s+', ' ', line.strip())
                for line in body_lines
                if line.strip()
            )
            return normalized
    return None


# ─── Scan: Dead Fixtures ──────────────────────────────────────────────────────

def scan_dead_fixtures(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """
    Detect test fixture files that are never referenced by any test.
    Also detects fixture data directories that are entirely unreferenced.
    """
    findings = []

    fixture_dirs = find_fixture_dirs(source_dir)
    if not fixture_dirs:
        if verbose:
            print("[test-scan:verbose] No fixture directories found", file=sys.stderr)
        return findings

    if verbose:
        print(f"[test-scan:verbose] Fixture dirs found: {[str(d) for d in fixture_dirs]}", file=sys.stderr)

    # Collect all fixture files
    fixture_files: List[Path] = []
    for fixture_dir in fixture_dirs:
        for f in fixture_dir.rglob("*"):
            if f.is_file() and not is_excluded(f):
                fixture_files.append(f)

    if not fixture_files:
        return findings

    # Collect all content from test files (and source files) to check references.
    # Explicitly exclude fixture files themselves from the search corpus to avoid
    # false negatives (e.g. a fixture named "unused.json" containing the word "unused").
    fixture_file_set = set(fixture_files)

    if project_type == "python":
        extensions = [".py"]
    else:
        extensions = [".ts", ".tsx", ".js", ".jsx", ".json"]

    all_content = ""
    for f in find_source_files(source_dir, extensions):
        if f in fixture_file_set:
            continue
        try:
            all_content += f.read_text(encoding="utf-8", errors="replace") + "\n"
        except OSError:
            pass

    # Also check config files (excluding fixture files)
    for config_glob in ["**/*.yml", "**/*.yaml", "**/*.json", "**/*.toml"]:
        for f in source_dir.rglob(config_glob):
            if f in fixture_file_set:
                continue
            if not is_excluded(f) and f.stat().st_size < 100_000:
                try:
                    all_content += f.read_text(encoding="utf-8", errors="replace") + "\n"
                except OSError:
                    pass

    # Check each fixture file for any reference in the codebase
    dead_fixtures: List[Path] = []
    for fixture_file in fixture_files:
        filename = fixture_file.name
        stem = fixture_file.stem
        rel_path = str(fixture_file.relative_to(source_dir))

        # Check for references by filename, stem, or relative path
        references = [filename, stem, rel_path]
        # Also check parts of the path (for import-style references)
        path_parts = fixture_file.parts
        references.extend(path_parts[-2:])  # Last 2 directory components

        found = any(ref in all_content for ref in references if len(ref) > 2)
        if not found:
            dead_fixtures.append(fixture_file)

    if verbose:
        print(f"[test-scan:verbose] Dead fixtures: {[str(f) for f in dead_fixtures]}", file=sys.stderr)

    if dead_fixtures and severity_meets_threshold("medium", severity_threshold):
        rel_paths = [str(f.relative_to(source_dir)) for f in dead_fixtures[:10]]
        finding = {
            "id": next_finding_id(),
            "dimension": "tests",
            "category": "test-quality",
            "severity": "medium",
            "owning_agent": "test-qa",
            "fallback_agent": "backend-developer",
            "file_paths": rel_paths[:5],
            "description": (
                f"Dead test fixtures: {len(dead_fixtures)} fixture file(s) in fixture "
                "directories are never referenced by any test or source file. "
                "Dead fixtures accumulate over time as features are removed, creating "
                "confusion about the test data contract and inflating test suite size."
            ),
            "suggested_fix": (
                "Review each dead fixture: "
                "(1) if the fixture was for a deleted feature — remove it; "
                "(2) if it should be referenced — add the missing test that uses it; "
                "(3) if uncertain — add a comment explaining its purpose and planned test. "
                f"Dead fixtures: {', '.join(rel_paths[:5])}"
                + (f"... (+{len(dead_fixtures) - 5} more)" if len(dead_fixtures) > 5 else "")
            ),
            "acceptance_criteria": [
                "Every fixture file is referenced by at least one test",
                "Removed fixtures are deleted from version control",
                "CI fails if fixture files exist with no test references",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["dead-fixture", "test-quality"],
                "effort_estimate": "s",
            },
        }
        findings.append(finding)

    return findings


# ─── Scan: Duplicate Tests ────────────────────────────────────────────────────

def scan_duplicate_tests(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """
    Detect duplicate or near-duplicate test functions.
    Detects: identical function names across test files, identical body content.
    """
    findings = []

    test_files = find_test_files(source_dir, project_type)
    if not test_files:
        return findings

    if project_type == "python":
        # Collect all test function names and their bodies
        all_test_functions: Dict[str, List[Tuple[Path, int]]] = defaultdict(list)
        # body_hash → [(file, func_name)]
        body_to_functions: Dict[str, List[Tuple[Path, str]]] = defaultdict(list)

        for test_file in test_files:
            functions = extract_python_test_functions(test_file)
            for func_name, lineno, snippet in functions:
                all_test_functions[func_name].append((test_file, lineno))
                # Get body hash for near-duplicate detection
                body = get_python_test_body_hash(test_file, func_name)
                if body and len(body) > 50:  # Only check substantial functions
                    body_to_functions[body].append((test_file, func_name))

        if verbose:
            dups = {n: locs for n, locs in all_test_functions.items() if len(locs) > 1}
            print(f"[test-scan:verbose] Duplicate test names: {len(dups)}", file=sys.stderr)

        # Finding 1: Identical function names
        dup_names = {
            name: locations
            for name, locations in all_test_functions.items()
            if len(locations) > 1
        }

        if dup_names and severity_meets_threshold("medium", severity_threshold):
            # Get up to 5 examples
            examples = list(dup_names.items())[:5]
            affected_files = list({str(fp.relative_to(source_dir)) for name, locs in examples for fp, _ in locs})[:5]
            dup_list = "; ".join(
                f"`{name}` in {', '.join(str(fp.relative_to(source_dir)) for fp, _ in locs[:2])}"
                for name, locs in examples
            )
            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "dedup",
                "severity": "medium",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files,
                "description": (
                    f"Duplicate test function names: {len(dup_names)} test function(s) have "
                    "identical names across multiple test files, suggesting copy-paste test duplication. "
                    f"Examples: {dup_list}. "
                    "Duplicate test names obscure which scenario each test covers and make "
                    "failures harder to diagnose."
                ),
                "suggested_fix": (
                    "Rename each duplicate test to clearly describe its specific scenario: "
                    "e.g., `test_create_user` → `test_create_user_with_valid_email` and "
                    "`test_create_user_returns_422_for_duplicate_email`. "
                    "If tests truly cover the same scenario, remove the duplicate; "
                    "if they cover different scenarios, rename to reflect the distinction. "
                    "Use parametrize/describe blocks to reduce structural duplication."
                ),
                "acceptance_criteria": [
                    "Each test function has a unique name across the entire test suite",
                    "Test names describe the specific scenario being tested",
                    "No copy-paste test files exist",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["duplicate-test", "test-quality"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

        # Finding 2: Near-identical bodies (copy-paste tests with minor variations)
        dup_bodies = {
            body: funcs
            for body, funcs in body_to_functions.items()
            if len(funcs) > 1
        }

        if dup_bodies and severity_meets_threshold("low", severity_threshold):
            affected_files = list({
                str(fp.relative_to(source_dir))
                for funcs in list(dup_bodies.values())[:3]
                for fp, _ in funcs
            })[:5]
            example_count = sum(len(f) for f in dup_bodies.values())

            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "dedup",
                "severity": "low",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files if affected_files else ["(test files)"],
                "description": (
                    f"Near-duplicate test bodies: {len(dup_bodies)} test function pair(s) have "
                    "nearly identical body content, suggesting copy-paste tests with only minor "
                    f"value variations ({example_count} function instances total). "
                    "This inflates test count without improving coverage and makes tests "
                    "fragile when the shared logic changes."
                ),
                "suggested_fix": (
                    "Refactor copy-paste tests using parametrize (pytest) or test.each (jest): "
                    "define the varying inputs/expected values as parameters and write the "
                    "test logic once. This reduces duplication while maintaining coverage. "
                    "Example: `@pytest.mark.parametrize('email', ['a@b.com', 'x@y.org'])`"
                ),
                "acceptance_criteria": [
                    "No test function pairs with >90% identical body content",
                    "Parametrized tests used for variations of the same scenario",
                    "Test count reduction does not reduce branch/scenario coverage",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["duplicate-test", "copy-paste", "test-quality"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    else:
        # Node.js: check for duplicate describe/it block names
        describe_it_pattern = re.compile(
            r"""(?:describe|it|test)\s*\(\s*['"`]([^'"`]+)['"`]""",
            re.MULTILINE,
        )

        all_test_names: Dict[str, List[Path]] = defaultdict(list)
        for test_file in test_files:
            try:
                content = test_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for m in describe_it_pattern.finditer(content):
                test_name = m.group(1).strip()
                if test_name and len(test_name) > 5:
                    all_test_names[test_name].append(test_file)

        dup_names = {
            name: files
            for name, files in all_test_names.items()
            if len(files) > 1
        }

        if verbose:
            print(f"[test-scan:verbose] Duplicate Node test names: {len(dup_names)}", file=sys.stderr)

        if dup_names and severity_meets_threshold("medium", severity_threshold):
            examples = list(dup_names.items())[:5]
            affected_files = list({
                str(fp.relative_to(source_dir))
                for _, files in examples
                for fp in files[:2]
            })[:5]
            dup_list = "; ".join(
                f'"{name}" in {len(files)} files'
                for name, files in examples
            )
            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "dedup",
                "severity": "medium",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files if affected_files else ["(test files)"],
                "description": (
                    f"Duplicate test descriptions: {len(dup_names)} test name(s) appear in "
                    f"multiple test files: {dup_list}. "
                    "Duplicate test descriptions indicate copy-paste tests and make it "
                    "ambiguous which scenario is being tested."
                ),
                "suggested_fix": (
                    "Rename each duplicated test to clearly distinguish its scenario. "
                    "Use describe blocks to provide context: "
                    '`describe("UserService", () => { it("creates user with valid email") })`. '
                    "If tests truly test the same thing in different files, consolidate them."
                ),
                "acceptance_criteria": [
                    "Each test description is unique within the test suite",
                    "Describe blocks provide context that disambiguates test names",
                    "Copy-paste test files are eliminated",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["duplicate-test", "test-quality", "nodejs"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    return findings


# ─── Scan: Coverage Gaps ──────────────────────────────────────────────────────

def scan_coverage_gaps(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """
    Detect public functions with no test coverage.
    Identifies source functions not referenced in any test file.
    """
    findings = []

    if project_type == "python":
        # Collect source files (exclude tests, migrations, __init__)
        source_files = [
            f for f in find_source_files(source_dir, [".py"])
            if not is_test_file(f, project_type)
            and f.name != "__init__.py"
            and "migration" not in str(f).lower()
        ]

        # Collect all content from test files
        test_content = ""
        for test_file in find_test_files(source_dir, project_type):
            try:
                test_content += test_file.read_text(encoding="utf-8", errors="replace") + "\n"
            except OSError:
                pass

        if not test_content:
            if verbose:
                print("[test-scan:verbose] No test content found for coverage gap analysis", file=sys.stderr)
            return findings

        # Find public functions not referenced in tests
        untested_functions: List[Tuple[str, str, int]] = []  # (file, func_name, lineno)

        for src_file in source_files:
            functions = extract_python_source_functions(src_file)
            rel_path = str(src_file.relative_to(source_dir))

            for func_name, lineno in functions:
                # Check if this function name appears in any test
                if func_name not in test_content:
                    untested_functions.append((rel_path, func_name, lineno))

        if verbose:
            print(f"[test-scan:verbose] Untested functions: {len(untested_functions)}", file=sys.stderr)

        if untested_functions and severity_meets_threshold("high", severity_threshold):
            # Group by file
            by_file: Dict[str, List[Tuple[str, int]]] = defaultdict(list)
            for rel_path, func_name, lineno in untested_functions:
                by_file[rel_path].append((func_name, lineno))

            # Report files with the most untested functions
            top_files = sorted(by_file.items(), key=lambda x: -len(x[1]))[:5]
            affected_files = [fp for fp, _ in top_files]

            total_untested = len(untested_functions)
            examples = "; ".join(
                f"{fp}: {', '.join(fn for fn, _ in funcs[:3])}"
                + ("..." if len(funcs) > 3 else "")
                for fp, funcs in top_files[:3]
            )

            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "test-coverage",
                "severity": "high",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files,
                "description": (
                    f"Coverage gaps: {total_untested} public function(s) across "
                    f"{len(by_file)} file(s) have no corresponding test. "
                    f"Examples: {examples}. "
                    "Untested public functions are invisible to regression detection "
                    "and create risk during refactoring."
                ),
                "suggested_fix": (
                    "Add unit tests for each untested public function. Priority order: "
                    "(1) functions with complex logic or multiple branches, "
                    "(2) functions called from many places (high fan-in), "
                    "(3) functions touching external state (I/O, network, database). "
                    "Use `pytest --cov` to generate a coverage report and identify specific gaps."
                ),
                "acceptance_criteria": [
                    "All public functions have at least one unit test",
                    "pytest --cov reports >80% line coverage",
                    "Error paths (exception handlers) have dedicated tests",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["coverage-gap", "test-coverage"],
                    "effort_estimate": "l",
                },
            }
            findings.append(finding)

        # Detect error paths mentioned in comments but not tested
        error_comment_pattern = re.compile(
            r"#\s*(TODO|FIXME|HACK|XXX|BUG).*test|"
            r"#\s*edge case[:\s]|"
            r"#\s*not tested|"
            r"#\s*untested|"
            r"#\s*missing test",
            re.IGNORECASE,
        )

        files_with_test_comments: List[Tuple[str, int, str]] = []
        for src_file in source_files:
            try:
                content = src_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            for i, line in enumerate(content.splitlines(), 1):
                if error_comment_pattern.search(line):
                    rel_path = str(src_file.relative_to(source_dir))
                    files_with_test_comments.append((rel_path, i, line.strip()))

        if verbose:
            print(f"[test-scan:verbose] Test-TODO comments: {len(files_with_test_comments)}", file=sys.stderr)

        if files_with_test_comments and severity_meets_threshold("medium", severity_threshold):
            affected_files = sorted({fp for fp, _, _ in files_with_test_comments})[:5]
            examples = "; ".join(
                f"{fp}:{line} → {comment[:60]}"
                for fp, line, comment in files_with_test_comments[:3]
            )
            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "test-coverage",
                "severity": "medium",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files,
                "description": (
                    f"Edge cases identified in comments but not tested: "
                    f"{len(files_with_test_comments)} comment(s) indicate known-missing tests "
                    f"(TODO/FIXME/edge case). Examples: {examples}. "
                    "These comments document known gaps that should become failing tests."
                ),
                "suggested_fix": (
                    "Convert each TODO/edge-case comment into a failing test. "
                    "The comment documents what needs to be verified — turn it into a test "
                    "that asserts the expected behavior. Remove the comment once the test exists. "
                    "Prioritize comments mentioning error paths or security edge cases."
                ),
                "acceptance_criteria": [
                    "No TODO/FIXME/edge-case comments reference missing tests",
                    "Each identified edge case has a corresponding test",
                    "Test names reflect the specific edge case being covered",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["coverage-gap", "edge-case", "test-coverage"],
                    "effort_estimate": "m",
                },
            }
            findings.append(finding)

    else:
        # Node.js: identify exported functions not covered by tests
        export_pattern = re.compile(
            r"""(?:export\s+(?:default\s+)?(?:function|const|class)\s+(\w+)|"""
            r"""module\.exports\s*=\s*\{([^}]+)\})""",
            re.MULTILINE,
        )

        source_files = [
            f for f in find_source_files(source_dir, [".ts", ".tsx", ".js", ".jsx"])
            if not is_test_file(f, project_type)
        ]

        test_content = ""
        for test_file in find_test_files(source_dir, project_type):
            try:
                test_content += test_file.read_text(encoding="utf-8", errors="replace") + "\n"
            except OSError:
                pass

        if not test_content:
            return findings

        untested_exports: List[Tuple[str, str]] = []
        for src_file in source_files:
            try:
                content = src_file.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue

            for m in export_pattern.finditer(content):
                export_name = m.group(1) or m.group(2)
                if export_name and export_name.strip() not in test_content:
                    rel_path = str(src_file.relative_to(source_dir))
                    untested_exports.append((rel_path, export_name.strip()))

        if verbose:
            print(f"[test-scan:verbose] Untested Node exports: {len(untested_exports)}", file=sys.stderr)

        if untested_exports and severity_meets_threshold("high", severity_threshold):
            by_file: Dict[str, List[str]] = defaultdict(list)
            for rel_path, name in untested_exports:
                by_file[rel_path].append(name)

            top_files = sorted(by_file.items(), key=lambda x: -len(x[1]))[:5]
            affected_files = [fp for fp, _ in top_files]

            finding = {
                "id": next_finding_id(),
                "dimension": "tests",
                "category": "test-coverage",
                "severity": "high",
                "owning_agent": "test-qa",
                "fallback_agent": "backend-developer",
                "file_paths": affected_files,
                "description": (
                    f"Coverage gaps: {len(untested_exports)} exported function(s)/class(es) "
                    f"across {len(by_file)} file(s) have no corresponding test coverage. "
                    "Untested exports create regression risk and make refactoring unsafe."
                ),
                "suggested_fix": (
                    "Add unit/integration tests for each untested export. "
                    "Use Jest with `--coverage` to identify specific gaps: "
                    "`npx jest --coverage --coverageReporters=text`. "
                    "Focus on exports that contain business logic, not pure data structures."
                ),
                "acceptance_criteria": [
                    "All exported functions have at least one test",
                    "Jest coverage report shows >80% statement coverage",
                    "Error/edge-case paths have dedicated tests",
                ],
                "status": "open",
                "metadata": {
                    "created_at": now_iso(),
                    "scanner_version": SCANNER_VERSION,
                    "tags": ["coverage-gap", "test-coverage", "nodejs"],
                    "effort_estimate": "l",
                },
            }
            findings.append(finding)

    return findings


# ─── Scan: Flaky Indicators ───────────────────────────────────────────────────

def scan_flaky_indicators(
    source_dir: Path,
    project_type: str,
    severity_threshold: str,
    verbose: bool = False,
) -> List[dict]:
    """
    Detect patterns that indicate flaky tests:
    - sleep/wait in tests
    - external service calls without mocks
    - non-deterministic ordering
    - hardcoded ports/hostnames
    """
    findings = []

    test_files = find_test_files(source_dir, project_type)
    if not test_files:
        return findings

    # ─ Pattern sets ─────────────────────────────────────────────────────────

    if project_type == "python":
        sleep_pattern = re.compile(
            r"\btime\.sleep\s*\(|asyncio\.sleep\s*\(|await\s+asyncio\.sleep\s*\(",
            re.IGNORECASE,
        )
        external_service_pattern = re.compile(
            r"""(?:requests|httpx|aiohttp|urllib)\s*\.\s*(?:get|post|put|delete|patch|request)\s*\([^)]*https?://(?!localhost|127\.|0\.0\.0)""",
            re.IGNORECASE,
        )
        hardcoded_host_pattern = re.compile(
            r"""['"](https?://(?!localhost|127\.|0\.0\.0|example\.com)[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}[^'"]*)['"]\s*[,)]""",
        )
        ordering_pattern = re.compile(
            r"\brandom\.(random|choice|shuffle|randint|sample)\b|"
            r"\bos\.urandom\b|"
            r"\bdatetime\.now\(\)|"
            r"\btime\.time\(\)|"
            r"\buuid\.uuid[14]\(\)",
            re.IGNORECASE,
        )
        mock_pattern = re.compile(
            r"\bpatch\b|\bMagicMock\b|\bMock\b|\bmonkeypatch\b|\brespx\b|\bresponses\b|\bhttpretty\b",
        )
    else:
        sleep_pattern = re.compile(
            r"\bsetTimeout\s*\(|\bsetInterval\s*\(|await\s+sleep\s*\(|"
            r"\bnew\s+Promise\s*\(.*setTimeout",
            re.IGNORECASE,
        )
        external_service_pattern = re.compile(
            r"""(?:fetch|axios|got|superagent)\s*\([^)]*https?://(?!localhost|127\.|0\.0\.0)""",
            re.IGNORECASE,
        )
        hardcoded_host_pattern = re.compile(
            r"""['"](https?://(?!localhost|127\.|0\.0\.0|example\.com)[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}[^'"]*)['"]\s*[,)]""",
        )
        ordering_pattern = re.compile(
            r"\bMath\.random\(\)|"
            r"\bDate\.now\(\)|"
            r"\bnew\s+Date\(\)|"
            r"\bcrypto\.randomUUID\(\)|"
            r"\.sort\(\)",
            re.IGNORECASE,
        )
        mock_pattern = re.compile(
            r"\bjest\.mock\b|\bjest\.fn\b|\bsinon\b|\bnock\b|\bmsw\b|"
            r"\bvi\.mock\b|\bvi\.fn\b",
        )

    # ─ Scan each test file ───────────────────────────────────────────────────

    sleep_files: List[Tuple[str, int, str]] = []
    external_files: List[Tuple[str, int, str]] = []
    ordering_files: List[Tuple[str, int, str]] = []

    for test_file in test_files:
        try:
            content = test_file.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        rel_path = str(test_file.relative_to(source_dir))
        has_mock = bool(mock_pattern.search(content))

        for i, line in enumerate(content.splitlines(), 1):
            # Sleep patterns
            if sleep_pattern.search(line):
                sleep_files.append((rel_path, i, line.strip()[:80]))

            # External service calls without mocks (only flag if no mock detected in file)
            if not has_mock and external_service_pattern.search(line):
                external_files.append((rel_path, i, line.strip()[:80]))

            # Hardcoded production hostnames
            m = hardcoded_host_pattern.search(line)
            if m and not has_mock:
                external_files.append((rel_path, i, f"hardcoded host: {m.group(1)[:60]}"))

            # Non-deterministic ordering in tests
            if ordering_pattern.search(line):
                # Only flag if not obviously in setup/mock context
                if not re.search(r"(mock|stub|spy|fake|seed|jest\.fn|sinon)", line, re.IGNORECASE):
                    ordering_files.append((rel_path, i, line.strip()[:80]))

    if verbose:
        print(f"[test-scan:verbose] Sleep patterns: {len(sleep_files)}", file=sys.stderr)
        print(f"[test-scan:verbose] External calls: {len(external_files)}", file=sys.stderr)
        print(f"[test-scan:verbose] Ordering issues: {len(ordering_files)}", file=sys.stderr)

    # Finding 1: sleep/wait patterns
    if sleep_files and severity_meets_threshold("high", severity_threshold):
        affected_files = sorted({fp for fp, _, _ in sleep_files})[:5]
        examples = "; ".join(f"{fp}:{line}" for fp, line, _ in sleep_files[:3])
        finding = {
            "id": next_finding_id(),
            "dimension": "tests",
            "category": "test-quality",
            "severity": "high",
            "owning_agent": "test-qa",
            "fallback_agent": "backend-developer",
            "file_paths": affected_files,
            "description": (
                f"Flaky test indicator — sleep/wait: {len(sleep_files)} test(s) use "
                "sleep() or setTimeout() to wait for async operations. Examples: "
                f"{examples}. "
                "Time-based waits are inherently flaky: too short fails on slow CI, "
                "too long wastes time, and any delay is non-deterministic."
            ),
            "suggested_fix": (
                "Replace time-based waits with event-based synchronization: "
                "(Python) use `asyncio.wait_for()`, event objects, or `pytest-asyncio` fixtures; "
                "(JS) use `waitFor()` from testing-library, `jest.useFakeTimers()`, or "
                "properly `await` promises. "
                "For polling scenarios, inject a configurable polling interval and set it to 0 in tests."
            ),
            "acceptance_criteria": [
                "No tests use sleep() or setTimeout() for synchronization",
                "Async tests properly await all async operations",
                "Tests pass consistently on the first run without timing issues",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["flaky", "sleep", "test-quality"],
                "effort_estimate": "m",
            },
        }
        findings.append(finding)

    # Finding 2: External service calls without mocks
    if external_files and severity_meets_threshold("high", severity_threshold):
        affected_files = sorted({fp for fp, _, _ in external_files})[:5]
        examples = "; ".join(f"{fp}:{line}" for fp, line, _ in external_files[:3])
        finding = {
            "id": next_finding_id(),
            "dimension": "tests",
            "category": "test-quality",
            "severity": "high",
            "owning_agent": "test-qa",
            "fallback_agent": "backend-developer",
            "file_paths": affected_files,
            "description": (
                f"Flaky test indicator — external services without mocks: "
                f"{len(external_files)} test(s) appear to call external services without "
                f"intercepting HTTP requests. Examples: {examples}. "
                "Tests depending on external services are slow, flaky, and fail in offline "
                "environments (CI without network, air-gapped deployments)."
            ),
            "suggested_fix": (
                "Mock all external HTTP calls in tests: "
                "(Python) use `responses`, `httpretty`, `respx`, or `pytest-httpx`; "
                "(JS) use `msw` (Mock Service Worker), `nock`, or `jest.mock`. "
                "For integration tests that must hit real services, move them to a separate "
                "suite tagged `@integration` and exclude from default CI runs."
            ),
            "acceptance_criteria": [
                "No unit tests make real HTTP calls to external services",
                "All HTTP calls in unit tests are intercepted by a mock library",
                "Integration tests (if any) are clearly tagged and run separately",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["flaky", "external-service", "test-quality"],
                "effort_estimate": "m",
            },
        }
        findings.append(finding)

    # Finding 3: Non-deterministic ordering
    if ordering_files and severity_meets_threshold("medium", severity_threshold):
        affected_files = sorted({fp for fp, _, _ in ordering_files})[:5]
        examples = "; ".join(f"{fp}:{line}" for fp, line, _ in ordering_files[:3])
        finding = {
            "id": next_finding_id(),
            "dimension": "tests",
            "category": "test-quality",
            "severity": "medium",
            "owning_agent": "test-qa",
            "fallback_agent": "backend-developer",
            "file_paths": affected_files,
            "description": (
                f"Flaky test indicator — non-deterministic data: {len(ordering_files)} test(s) "
                "use random values, current timestamps, or random UUIDs without seeding. "
                f"Examples: {examples}. "
                "Tests using non-seeded random data produce different results on each run, "
                "making failures non-reproducible."
            ),
            "suggested_fix": (
                "Use deterministic test data: "
                "(1) use fixed seed values: `random.seed(42)` or `faker.seed(42)`; "
                "(2) use fixed timestamps: freeze time with `freezegun` (Python) or "
                "`jest.useFakeTimers()` (JS); "
                "(3) use predictable IDs: sequential integers or hardcoded UUIDs like "
                '`"00000000-0000-0000-0000-000000000001"` in tests.'
            ),
            "acceptance_criteria": [
                "Tests produce identical output on every run with the same code",
                "Random values are seeded or replaced with fixed values in tests",
                "Time-dependent tests use frozen/mocked time",
            ],
            "status": "open",
            "metadata": {
                "created_at": now_iso(),
                "scanner_version": SCANNER_VERSION,
                "tags": ["flaky", "non-deterministic", "test-quality"],
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
    print("│           Test Scan Summary                 │", file=sys.stderr)
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
        description="Test scanner: dead fixtures, duplicate tests, coverage gaps, flaky indicators"
    )
    parser.add_argument("--source-dir", default=".", help="Source directory to scan")
    parser.add_argument("--output-file", default=".refactor/test-findings.json")
    parser.add_argument(
        "--categories",
        default="dead-fixtures,duplicate-tests,coverage-gaps,flaky",
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
        choices=["python", "nodejs", "auto"],
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main():
    args = parse_args()
    source_dir = Path(args.source_dir).resolve()
    categories = set(args.categories.split(","))

    print(f"[test-scan] Test scanner v{SCANNER_VERSION}", file=sys.stderr)
    print(f"[test-scan]   Source dir: {source_dir}", file=sys.stderr)
    print(f"[test-scan]   Categories: {args.categories}", file=sys.stderr)

    if args.dry_run:
        print(f"[test-scan] DRY-RUN: would scan {source_dir}", file=sys.stderr)
        print(f"[test-scan] DRY-RUN: output → {args.output_file}", file=sys.stderr)
        sys.exit(0)

    # Detect project type
    project_type = args.project_type
    if project_type == "auto":
        project_type = detect_project_type(source_dir)
    print(f"[test-scan]   Project type: {project_type}", file=sys.stderr)

    all_findings: List[dict] = []

    if "dead-fixtures" in categories:
        print("[test-scan] Scanning for dead test fixtures...", file=sys.stderr)
        findings = scan_dead_fixtures(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[test-scan]   dead-fixtures: {len(findings)} finding(s)", file=sys.stderr)

    if "duplicate-tests" in categories:
        print("[test-scan] Scanning for duplicate tests...", file=sys.stderr)
        findings = scan_duplicate_tests(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[test-scan]   duplicate-tests: {len(findings)} finding(s)", file=sys.stderr)

    if "coverage-gaps" in categories:
        print("[test-scan] Scanning for coverage gaps...", file=sys.stderr)
        findings = scan_coverage_gaps(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[test-scan]   coverage-gaps: {len(findings)} finding(s)", file=sys.stderr)

    if "flaky" in categories:
        print("[test-scan] Scanning for flaky test indicators...", file=sys.stderr)
        findings = scan_flaky_indicators(source_dir, project_type, args.severity_threshold, args.verbose)
        all_findings.extend(findings)
        print(f"[test-scan]   flaky: {len(findings)} finding(s)", file=sys.stderr)

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
    print(f"[test-scan] Findings written to: {output_file}", file=sys.stderr)

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
