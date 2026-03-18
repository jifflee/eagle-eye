#!/usr/bin/env python3
"""
test-runner.py
Auto-discovery test runner: maps changed files to their test suites and runs
only relevant tests. Supports bash tests and pytest.

USAGE:
  python scripts/test-runner.py [OPTIONS]

MODES:
  --fast               Run only tests affected by changed files (default)
  --full               Run the complete test suite
  --list               List discovered file-to-test mappings without running

OPTIONS:
  --changed FILES      Comma-separated list of changed files to analyse
  --base-ref REF       Git ref to diff against (default: HEAD~1 or main)
  --test-dir DIR       Override test directory (default: tests/)
  --source-dirs DIRS   Comma-separated source directories (default: scripts,src,core)
  --output FILE        Write JSON results to FILE (default: stdout)
  --output-format FMT  Output format: json|summary (default: json)
  --config FILE        Config file for custom mappings (.test-runner.json)
  --no-run             Discover and map only; do not execute tests
  --verbose            Verbose output
  --coverage           Emit coverage delta information
  --help               Show this help

JSON OUTPUT (--output-format json):
  {
    "mode": "fast|full",
    "changed_files": [...],
    "mappings": [
      {"source": "scripts/foo.sh", "tests": ["tests/scripts/test-foo.sh"]}
    ],
    "suites": {
      "bash": ["tests/scripts/test-foo.sh"],
      "pytest": ["tests/test_bar.py"]
    },
    "results": {
      "bash": { "passed": N, "failed": N, "skipped": N, "tests": [...] },
      "pytest": { "passed": N, "failed": N, "skipped": N, "tests": [...] }
    },
    "coverage_delta": {...},
    "summary": { "total": N, "passed": N, "failed": N, "duration_seconds": N },
    "passed": true|false
  }

EXIT CODES:
  0   All tests passed (or no tests found)
  1   One or more tests failed
  2   Fatal error (missing dependencies, invalid arguments)
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

RUNNER_VERSION = "1.0.0"

# ─── Constants ────────────────────────────────────────────────────────────────

DEFAULT_TEST_DIR = "tests"
DEFAULT_SOURCE_DIRS = ["scripts", "src", "core", "domains", "primitives"]
DEFAULT_CONFIG_FILE = ".test-runner.json"

# Directories to skip during discovery
EXCLUDE_DIRS: Set[str] = {
    "node_modules", ".git", "__pycache__", "venv", ".venv",
    "dist", "build", ".next", "coverage", ".nyc_output",
    ".refactor", ".claude", "fixtures", "generated",
    "templates", "e2e",
}


# ─── Logging ─────────────────────────────────────────────────────────────────

def log(msg: str, verbose: bool = False, is_verbose: bool = False) -> None:
    if is_verbose and not verbose:
        return
    print(f"[test-runner] {msg}", file=sys.stderr)


def log_v(msg: str, verbose: bool = False) -> None:
    log(msg, verbose=verbose, is_verbose=True)


# ─── Config Loading ───────────────────────────────────────────────────────────

def load_config(config_path: Path) -> dict:
    """Load optional config file for custom mappings."""
    if not config_path.exists():
        return {}
    try:
        with config_path.open() as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        log(f"WARNING: Could not load config {config_path}: {e}")
        return {}


# ─── Changed File Detection ───────────────────────────────────────────────────

def get_changed_files(base_ref: str, repo_root: Path, verbose: bool) -> List[str]:
    """Get list of changed files vs git base ref."""
    # Try diff against base_ref
    for cmd in [
        ["git", "diff", "--name-only", base_ref, "HEAD"],
        ["git", "diff", "--name-only", "HEAD~1"],
        ["git", "diff", "--name-only", "--cached"],
        ["git", "status", "--porcelain"],
    ]:
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=repo_root,
                timeout=30,
            )
            if result.returncode == 0 and result.stdout.strip():
                files = []
                for line in result.stdout.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    # Handle `git status --porcelain` output
                    if len(line) > 2 and line[2] == " ":
                        line = line[3:]
                    files.append(line)
                log_v(f"Changed files from '{' '.join(cmd)}': {files}", verbose)
                return files
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue
    return []


# ─── File-to-Test Mapping ─────────────────────────────────────────────────────

def discover_all_tests(test_dir: Path, verbose: bool) -> Dict[str, List[Path]]:
    """
    Discover all test files, split by type.
    Returns: {"bash": [...], "pytest": [...]}
    """
    bash_tests: List[Path] = []
    pytest_tests: List[Path] = []

    if not test_dir.exists():
        return {"bash": [], "pytest": []}

    for path in sorted(test_dir.rglob("*")):
        if not path.is_file():
            continue
        # Skip excluded directories
        if any(part in EXCLUDE_DIRS for part in path.parts):
            continue

        name = path.name
        if name.startswith("test-") and name.endswith(".sh"):
            bash_tests.append(path)
        elif (name.startswith("test_") and name.endswith(".py")) or \
             (name.endswith("_test.py")):
            pytest_tests.append(path)

    log_v(f"Discovered {len(bash_tests)} bash tests, {len(pytest_tests)} pytest tests", verbose)
    return {"bash": bash_tests, "pytest": pytest_tests}


def derive_test_name_variants(source_file: Path) -> List[str]:
    """
    Given a source file path, derive candidate test file stem names.

    Examples:
      scripts/foo.sh         -> test-foo, test-foo.sh
      scripts/foo-bar.sh     -> test-foo-bar
      src/my_module.py       -> test_my_module, test-my-module
      core/utils/helper.sh   -> test-helper, test-utils-helper
    """
    stem = source_file.stem  # filename without extension
    variants = set()

    # Direct mapping: test-{stem} or test_{stem}
    variants.add(f"test-{stem}")
    variants.add(f"test_{stem}")

    # Replace underscores with dashes and vice versa
    dash_stem = stem.replace("_", "-")
    underscore_stem = stem.replace("-", "_")
    variants.add(f"test-{dash_stem}")
    variants.add(f"test_{underscore_stem}")

    # For deeply nested files, also try parent-dir + name combos
    parts = list(source_file.parts)
    if len(parts) >= 2:
        parent = parts[-2]
        variants.add(f"test-{parent}-{stem}")
        variants.add(f"test-{parent}_{stem}")

    return list(variants)


def build_mapping_from_conventions(
    source_file: Path,
    all_tests: Dict[str, List[Path]],
    repo_root: Path,
) -> List[Path]:
    """
    Map a single source file to its test files using naming conventions.
    Returns list of matching test paths.
    """
    candidates = derive_test_name_variants(source_file)
    matched: List[Path] = []

    for test_type, test_files in all_tests.items():
        for test_path in test_files:
            test_stem = test_path.stem
            if test_stem in candidates:
                matched.append(test_path)

    return matched


def build_mapping_from_config(
    source_file: Path,
    config: dict,
    repo_root: Path,
) -> List[Path]:
    """
    Map source file using explicit config file mappings.
    Config format: {"mappings": {"scripts/foo.sh": ["tests/scripts/test-foo.sh"]}}
    """
    custom_mappings: dict = config.get("mappings", {})
    rel_source = str(source_file.relative_to(repo_root)) if source_file.is_absolute() else str(source_file)
    matched: List[Path] = []

    for pattern, test_paths in custom_mappings.items():
        # Support glob-style wildcard matching
        if re.match(pattern.replace("*", ".*").replace("?", "."), rel_source):
            for tp in test_paths:
                full_path = repo_root / tp
                if full_path.exists():
                    matched.append(full_path)

    return matched


def map_file_to_tests(
    source_file: Path,
    all_tests: Dict[str, List[Path]],
    config: dict,
    repo_root: Path,
    verbose: bool,
) -> List[Path]:
    """
    Map a source file to its tests using:
    1. Custom config mappings
    2. Naming convention discovery
    """
    matched: List[Path] = []

    # 1. Config-based mappings take priority
    config_matched = build_mapping_from_config(source_file, config, repo_root)
    matched.extend(config_matched)

    # 2. Convention-based discovery
    convention_matched = build_mapping_from_conventions(source_file, all_tests, repo_root)
    for path in convention_matched:
        if path not in matched:
            matched.append(path)

    log_v(f"  {source_file.name} -> {[p.name for p in matched]}", verbose)
    return matched


def build_mappings(
    changed_files: List[str],
    all_tests: Dict[str, List[Path]],
    config: dict,
    repo_root: Path,
    verbose: bool,
) -> Tuple[List[dict], Set[Path]]:
    """
    Build file-to-test mapping for changed files.
    Returns (mappings_list, affected_test_paths)
    """
    mappings: List[dict] = []
    affected: Set[Path] = set()

    for file_str in changed_files:
        file_path = Path(file_str)
        if file_path.is_absolute():
            abs_path = file_path
        else:
            abs_path = repo_root / file_path

        if not abs_path.exists():
            log_v(f"Skipping non-existent: {file_str}", verbose)
            continue

        tests = map_file_to_tests(abs_path, all_tests, config, repo_root, verbose)

        rel_source = str(abs_path.relative_to(repo_root))
        rel_tests = [str(t.relative_to(repo_root)) for t in tests]

        mappings.append({
            "source": rel_source,
            "tests": rel_tests,
        })
        affected.update(tests)

    return mappings, affected


# ─── Test Execution ───────────────────────────────────────────────────────────

def run_bash_test(test_path: Path, repo_root: Path, verbose: bool) -> dict:
    """Run a single bash test file. Returns result dict."""
    start = time.time()
    rel_path = str(test_path.relative_to(repo_root))

    try:
        result = subprocess.run(
            [str(test_path)],
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=120,
        )
        duration = time.time() - start
        status = "pass" if result.returncode == 0 else "fail"
        output = (result.stdout + result.stderr).strip()
        return {
            "name": rel_path,
            "status": status,
            "exit_code": result.returncode,
            "duration_seconds": round(duration, 2),
            "output": output[:2000] if output else "",
        }
    except subprocess.TimeoutExpired:
        return {
            "name": rel_path,
            "status": "fail",
            "exit_code": 124,
            "duration_seconds": 120.0,
            "output": "TIMEOUT: Test exceeded 120s limit",
        }
    except (OSError, PermissionError) as e:
        return {
            "name": rel_path,
            "status": "skip",
            "exit_code": -1,
            "duration_seconds": 0.0,
            "output": f"ERROR: Could not run test: {e}",
        }


def run_bash_suite(test_paths: List[Path], repo_root: Path, verbose: bool) -> dict:
    """Run all bash tests and aggregate results."""
    results = []
    for path in test_paths:
        if not path.exists():
            log_v(f"Skipping missing test: {path}", verbose)
            continue
        if not os.access(path, os.X_OK):
            log(f"WARNING: Test not executable, skipping: {path.name}")
            continue
        log_v(f"Running bash test: {path.name}", verbose)
        r = run_bash_test(path, repo_root, verbose)
        results.append(r)
        status_sym = "✓" if r["status"] == "pass" else "✗"
        log(f"  {status_sym} {r['name']} ({r['duration_seconds']}s)")

    passed = sum(1 for r in results if r["status"] == "pass")
    failed = sum(1 for r in results if r["status"] == "fail")
    skipped = sum(1 for r in results if r["status"] == "skip")

    return {
        "passed": passed,
        "failed": failed,
        "skipped": skipped,
        "tests": results,
    }


def run_pytest_suite(test_paths: List[Path], repo_root: Path, verbose: bool, coverage: bool) -> dict:
    """Run pytest on the given test files."""
    if not test_paths:
        return {"passed": 0, "failed": 0, "skipped": 0, "tests": []}

    # Check if pytest is available
    pytest_cmd = None
    for cmd in ["pytest", "python3 -m pytest", "python -m pytest"]:
        try:
            subprocess.run(
                cmd.split() + ["--version"],
                capture_output=True,
                timeout=5,
            )
            pytest_cmd = cmd.split()
            break
        except (subprocess.TimeoutExpired, FileNotFoundError):
            continue

    if pytest_cmd is None:
        log("WARNING: pytest not found, skipping Python tests")
        return {
            "passed": 0,
            "failed": 0,
            "skipped": len(test_paths),
            "tests": [
                {"name": str(p.relative_to(repo_root)), "status": "skip",
                 "exit_code": -1, "duration_seconds": 0.0,
                 "output": "pytest not available"}
                for p in test_paths
            ],
        }

    start = time.time()
    str_paths = [str(p) for p in test_paths]

    cmd = pytest_cmd + [
        "--tb=short",
        "--no-header",
        "-q",
        "--json-report",
        "--json-report-file=-",
    ] + str_paths

    if coverage:
        cmd += ["--cov=.", "--cov-report=json"]

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=repo_root,
            timeout=300,
        )
        duration = time.time() - start

        # Try to parse JSON report
        try:
            report = json.loads(result.stdout)
            tests = []
            for t in report.get("tests", []):
                tests.append({
                    "name": t.get("nodeid", ""),
                    "status": t.get("outcome", "fail"),
                    "exit_code": 0 if t.get("outcome") == "passed" else 1,
                    "duration_seconds": round(t.get("duration", 0), 2),
                    "output": t.get("call", {}).get("longrepr", "")[:500] if t.get("outcome") != "passed" else "",
                })
            summary = report.get("summary", {})
            return {
                "passed": summary.get("passed", 0),
                "failed": summary.get("failed", 0),
                "skipped": summary.get("skipped", 0),
                "tests": tests,
            }
        except (json.JSONDecodeError, KeyError):
            # Fall back to parsing text output
            passed = failed = skipped = 0
            output = (result.stdout + result.stderr).strip()
            # Simple regex parse of summary line: "5 passed, 2 failed, 1 skipped"
            m = re.search(r"(\d+) passed", output)
            if m:
                passed = int(m.group(1))
            m = re.search(r"(\d+) failed", output)
            if m:
                failed = int(m.group(1))
            m = re.search(r"(\d+) skipped", output)
            if m:
                skipped = int(m.group(1))

            status = "pass" if result.returncode == 0 else "fail"
            return {
                "passed": passed,
                "failed": failed,
                "skipped": skipped,
                "tests": [
                    {
                        "name": str(p.relative_to(repo_root)),
                        "status": status,
                        "exit_code": result.returncode,
                        "duration_seconds": round(duration, 2),
                        "output": output[:2000],
                    }
                    for p in test_paths
                ],
            }
    except subprocess.TimeoutExpired:
        return {
            "passed": 0,
            "failed": len(test_paths),
            "skipped": 0,
            "tests": [
                {
                    "name": str(p.relative_to(repo_root)),
                    "status": "fail",
                    "exit_code": 124,
                    "duration_seconds": 300.0,
                    "output": "TIMEOUT: Test suite exceeded 300s limit",
                }
                for p in test_paths
            ],
        }


# ─── Coverage Delta ───────────────────────────────────────────────────────────

def compute_coverage_delta(
    before_paths: List[str],
    after_paths: List[str],
    repo_root: Path,
) -> dict:
    """
    Compute basic coverage delta: which files now have tests vs before.
    Returns a summary dict.
    """
    before = set(before_paths)
    after = set(after_paths)
    newly_covered = sorted(after - before)
    lost_coverage = sorted(before - after)

    return {
        "newly_covered": newly_covered,
        "lost_coverage": lost_coverage,
        "net_change": len(newly_covered) - len(lost_coverage),
    }


# ─── Report Output ────────────────────────────────────────────────────────────

def print_summary_report(report: dict) -> None:
    summary = report.get("summary", {})
    total = summary.get("total", 0)
    passed = summary.get("passed", 0)
    failed = summary.get("failed", 0)
    skipped = summary.get("skipped", 0)
    duration = summary.get("duration_seconds", 0)
    overall = report.get("passed", False)

    print("", file=sys.stderr)
    print("┌──────────────────────────────────────────────────┐", file=sys.stderr)
    print("│              Test Runner Summary                  │", file=sys.stderr)
    print("├──────────────────────────────────────────────────┤", file=sys.stderr)
    print(f"│  Mode:        {report.get('mode', '?'):<35}│", file=sys.stderr)
    print(f"│  Total tests: {total:<35}│", file=sys.stderr)
    print(f"│  Passed:      {passed:<35}│", file=sys.stderr)
    print(f"│  Failed:      {failed:<35}│", file=sys.stderr)
    print(f"│  Skipped:     {skipped:<35}│", file=sys.stderr)
    print(f"│  Duration:    {duration:.1f}s{'':<33}│", file=sys.stderr)
    result_str = "✓ PASSED" if overall else "✗ FAILED"
    print(f"│  Result:      {result_str:<35}│", file=sys.stderr)
    print("└──────────────────────────────────────────────────┘", file=sys.stderr)

    if report.get("mappings"):
        print(f"\n  File-to-test mappings ({len(report['mappings'])}):", file=sys.stderr)
        for m in report["mappings"]:
            tests_str = ", ".join(m["tests"]) if m["tests"] else "(no tests found)"
            print(f"    {m['source']} -> {tests_str}", file=sys.stderr)

    if report.get("coverage_delta"):
        delta = report["coverage_delta"]
        if delta.get("newly_covered"):
            print(f"\n  Newly covered: {', '.join(delta['newly_covered'])}", file=sys.stderr)
        if delta.get("lost_coverage"):
            print(f"  Lost coverage: {', '.join(delta['lost_coverage'])}", file=sys.stderr)


# ─── Argument Parsing ─────────────────────────────────────────────────────────

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Auto-discovery test runner: maps changed files to test suites",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )

    mode_group = parser.add_mutually_exclusive_group()
    mode_group.add_argument("--fast", action="store_true", default=True,
                            help="Run only tests affected by changed files (default)")
    mode_group.add_argument("--full", action="store_true",
                            help="Run the complete test suite")
    mode_group.add_argument("--list", action="store_true",
                            help="List mappings without running tests")

    parser.add_argument("--changed",
                        help="Comma-separated list of changed files")
    parser.add_argument("--base-ref", default="HEAD~1",
                        help="Git ref to diff against (default: HEAD~1)")
    parser.add_argument("--test-dir", default=DEFAULT_TEST_DIR,
                        help=f"Test directory (default: {DEFAULT_TEST_DIR})")
    parser.add_argument("--source-dirs",
                        default=",".join(DEFAULT_SOURCE_DIRS),
                        help=f"Source directories (default: {','.join(DEFAULT_SOURCE_DIRS)})")
    parser.add_argument("--output",
                        help="Write JSON results to FILE (default: stdout)")
    parser.add_argument("--output-format", default="json",
                        choices=["json", "summary"],
                        help="Output format (default: json)")
    parser.add_argument("--config", default=DEFAULT_CONFIG_FILE,
                        help=f"Config file (default: {DEFAULT_CONFIG_FILE})")
    parser.add_argument("--no-run", action="store_true",
                        help="Discover and map only; do not execute tests")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--coverage", action="store_true",
                        help="Emit coverage delta information")

    return parser.parse_args()


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    args = parse_args()

    # Resolve repo root: prefer CWD with .git, then walk up, then script's parent
    def _find_git_root(start: Path) -> Optional[Path]:
        current = start.resolve()
        for _ in range(10):
            if (current / ".git").exists():
                return current
            parent = current.parent
            if parent == current:
                break
            current = parent
        return None

    cwd_git = _find_git_root(Path.cwd())
    script_git = _find_git_root(Path(__file__).resolve().parent)

    if cwd_git is not None:
        repo_root = cwd_git
    elif script_git is not None:
        repo_root = script_git
    else:
        repo_root = Path.cwd()

    verbose = args.verbose

    log(f"Test runner v{RUNNER_VERSION}")
    log(f"  Repo root: {repo_root}")

    # Determine mode
    if args.list:
        mode = "list"
    elif args.full:
        mode = "full"
    else:
        mode = "fast"

    log(f"  Mode: {mode}")

    # Load config
    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = repo_root / config_path
    config = load_config(config_path)

    # Resolve directories
    test_dir = Path(args.test_dir)
    if not test_dir.is_absolute():
        test_dir = repo_root / test_dir

    # Discover all tests
    log("Discovering test files...")
    all_tests = discover_all_tests(test_dir, verbose)
    all_bash = all_tests["bash"]
    all_pytest = all_tests["pytest"]
    log(f"  Found {len(all_bash)} bash tests, {len(all_pytest)} pytest tests")

    # Determine which tests to run
    mappings: List[dict] = []
    bash_to_run: List[Path] = []
    pytest_to_run: List[Path] = []
    changed_files: List[str] = []

    if mode == "full":
        bash_to_run = all_bash
        pytest_to_run = all_pytest
        log(f"Full mode: running all {len(all_bash)} bash + {len(all_pytest)} pytest tests")

    elif mode in ("fast", "list"):
        # Determine changed files
        if args.changed:
            changed_files = [f.strip() for f in args.changed.split(",") if f.strip()]
            log(f"  Using provided changed files: {changed_files}")
        else:
            changed_files = get_changed_files(args.base_ref, repo_root, verbose)
            log(f"  Detected {len(changed_files)} changed file(s) vs {args.base_ref}")

        if not changed_files:
            log("No changed files detected. Use --full to run all tests.")
            # Still emit valid output
            report = {
                "mode": mode,
                "changed_files": [],
                "mappings": [],
                "suites": {"bash": [], "pytest": []},
                "results": {
                    "bash": {"passed": 0, "failed": 0, "skipped": 0, "tests": []},
                    "pytest": {"passed": 0, "failed": 0, "skipped": 0, "tests": []},
                },
                "coverage_delta": {},
                "summary": {"total": 0, "passed": 0, "failed": 0, "skipped": 0, "duration_seconds": 0.0},
                "passed": True,
                "runner_version": RUNNER_VERSION,
                "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            _emit_output(report, args)
            return 0

        # Build mappings
        log("Building file-to-test mappings...")
        mappings, affected_tests = build_mappings(
            changed_files, all_tests, config, repo_root, verbose
        )

        log(f"  Mapped {len(changed_files)} source file(s) -> {len(affected_tests)} test file(s)")

        # Split affected tests by type
        for test_path in affected_tests:
            if test_path.name.endswith(".sh"):
                bash_to_run.append(test_path)
            elif test_path.name.endswith(".py"):
                pytest_to_run.append(test_path)

    # If list mode, just emit mappings
    if mode == "list" or args.no_run:
        report = {
            "mode": mode,
            "changed_files": changed_files,
            "mappings": mappings,
            "suites": {
                "bash": [str(p.relative_to(repo_root)) for p in bash_to_run],
                "pytest": [str(p.relative_to(repo_root)) for p in pytest_to_run],
            },
            "results": {},
            "coverage_delta": {},
            "summary": {
                "total": len(bash_to_run) + len(pytest_to_run),
                "passed": 0,
                "failed": 0,
                "skipped": 0,
                "duration_seconds": 0.0,
            },
            "passed": True,
            "runner_version": RUNNER_VERSION,
            "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        _emit_output(report, args)
        return 0

    # ─── Execute Tests ────────────────────────────────────────────────────────

    start_time = time.time()
    bash_results: dict = {"passed": 0, "failed": 0, "skipped": 0, "tests": []}
    pytest_results: dict = {"passed": 0, "failed": 0, "skipped": 0, "tests": []}

    if bash_to_run:
        log(f"\nRunning {len(bash_to_run)} bash test(s)...")
        bash_results = run_bash_suite(bash_to_run, repo_root, verbose)

    if pytest_to_run:
        log(f"\nRunning {len(pytest_to_run)} pytest test(s)...")
        pytest_results = run_pytest_suite(pytest_to_run, repo_root, verbose, args.coverage)

    duration = time.time() - start_time

    # Aggregate
    total = (bash_results["passed"] + bash_results["failed"] + bash_results["skipped"] +
             pytest_results["passed"] + pytest_results["failed"] + pytest_results["skipped"])
    total_passed = bash_results["passed"] + pytest_results["passed"]
    total_failed = bash_results["failed"] + pytest_results["failed"]
    total_skipped = bash_results["skipped"] + pytest_results["skipped"]
    overall_passed = total_failed == 0

    # Coverage delta (basic: which test files changed?)
    coverage_delta: dict = {}
    if args.coverage:
        before_covered = []  # Could be loaded from a baseline file
        after_covered = [str(p.relative_to(repo_root)) for p in bash_to_run + pytest_to_run]
        coverage_delta = compute_coverage_delta(before_covered, after_covered, repo_root)

    report = {
        "mode": mode,
        "changed_files": changed_files,
        "mappings": mappings,
        "suites": {
            "bash": [str(p.relative_to(repo_root)) for p in bash_to_run],
            "pytest": [str(p.relative_to(repo_root)) for p in pytest_to_run],
        },
        "results": {
            "bash": bash_results,
            "pytest": pytest_results,
        },
        "coverage_delta": coverage_delta,
        "summary": {
            "total": total,
            "passed": total_passed,
            "failed": total_failed,
            "skipped": total_skipped,
            "duration_seconds": round(duration, 2),
        },
        "passed": overall_passed,
        "runner_version": RUNNER_VERSION,
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    _emit_output(report, args)

    return 0 if overall_passed else 1


def _emit_output(report: dict, args: argparse.Namespace) -> None:
    """Write report to output file or stdout."""
    output_json = json.dumps(report, indent=2)

    if args.output_format == "summary":
        print_summary_report(report)

    if args.output:
        output_path = Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(output_json + "\n", encoding="utf-8")
        log(f"Results written to: {args.output}")
    else:
        print(output_json)


if __name__ == "__main__":
    sys.exit(main())
