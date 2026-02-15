#!/usr/bin/env python3
"""primer_insights.py — deterministic onboarding insights for rqs primer.

Generates markdown sections that accelerate repository orientation:
- Fast start map (entrypoints, dispatch, read order)
- Runtime boundaries (guardrails and invariants)
- Behavioral contract from tests
- Critical path file ranking
- Heuristic/risk hotspots
"""

from __future__ import annotations

import argparse
import math
import os
import re
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Dict, List, Sequence, Set, Tuple


MAX_SCAN_BYTES = 512_000
MAX_TEXT_SCAN_FILES = 2500

TEXT_EXTS = {
    ".py", ".sh", ".bash", ".zsh", ".js", ".jsx", ".ts", ".tsx", ".go", ".rb",
    ".rs", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".php", ".swift",
    ".kt", ".kts", ".scala", ".lua", ".sql", ".md", ".rst", ".txt", ".toml",
    ".yaml", ".yml", ".json", ".xml", ".ini", ".cfg", ".conf",
}

ENTRY_NAME_HINTS = {
    "main.py", "main.go", "main.rs", "main.c", "main.cc", "main.cpp",
    "index.js", "app.py", "app.js",
    "cli.py", "cli.js", "manage.py", "server.py", "server.js",
}

# Paths that are build/CI orchestration, not runtime entrypoints.
_CI_BUILD_PREFIXES = (
    ".github/", "contrib/", "ci/", ".circleci/", ".buildkite/",
    "scripts/ci", "scripts/release",
)

_BUILD_TOOL_FILES = {
    "makefile", "gnumakefile", "cmakelists.txt", "meson.build", "build.ninja",
    "package.json", "setup.py", "pyproject.toml",
}

_NON_RUNTIME_PREFIXES = (
    "runtime/scripts/", "doc/", "docs/", "test/", "tests/", "bench/", "benchmarks/",
    "examples/", "example/",
)


def _xml_escape_attr(value: object) -> str:
    return (str(value)
            .replace("&", "&amp;")
            .replace('"', "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;"))


def _open_tag(name: str, **attrs: object) -> None:
    if attrs:
        rendered = " ".join(f'{k}="{_xml_escape_attr(v)}"' for k, v in attrs.items())
        print(f"<{name} {rendered}>")
    else:
        print(f"<{name}>")


def _close_tag(name: str) -> None:
    print(f"</{name}>")


@dataclass
class DispatchEntry:
    command: str
    entry_file: str
    source_file: str
    handler: str


@dataclass
class Entrypoint:
    path: str
    score: int
    signals: List[str]


def run_git_ls_files(repo_root: str) -> List[str]:
    try:
        proc = subprocess.run(
            ["git", "ls-files"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return []
    if proc.returncode != 0:
        return []
    files = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    return files


def safe_read_text(repo_root: str, rel_path: str) -> str:
    abs_path = os.path.join(repo_root, rel_path)
    try:
        with open(abs_path, "rb") as fh:
            data = fh.read(MAX_SCAN_BYTES + 1)
    except OSError:
        return ""
    if len(data) > MAX_SCAN_BYTES:
        data = data[:MAX_SCAN_BYTES]
    if b"\x00" in data:
        return ""
    return data.decode("utf-8", errors="ignore")


def safe_line_count(repo_root: str, rel_path: str) -> int:
    abs_path = os.path.join(repo_root, rel_path)
    try:
        with open(abs_path, "rb") as fh:
            return sum(1 for _ in fh)
    except OSError:
        return 0


def is_text_candidate(rel_path: str) -> bool:
    base = os.path.basename(rel_path).lower()
    ext = os.path.splitext(rel_path)[1].lower()
    if ext in TEXT_EXTS:
        return True
    if base in {"makefile", "dockerfile", "rakefile"}:
        return True
    if rel_path.startswith("bin/") or rel_path.startswith("scripts/"):
        return True
    return False


def _text_scan_priority(rel_path: str) -> int:
    """Heuristic priority for expensive full-text scanning."""
    rel_l = rel_path.lower()
    base_l = os.path.basename(rel_l)
    ext = os.path.splitext(rel_l)[1]

    score = 0
    if rel_l.startswith(("bin/", "src/", "lib/", "app/", "core/", "cmd/", "internal/")):
        score += 8
    if rel_l.startswith(("tests/", "test/")) or "/tests/" in rel_l or "/test/" in rel_l:
        score += 6
    if rel_l.startswith(("conf/", "config/", ".github/")):
        score += 5
    if ext in {".py", ".c", ".cc", ".cpp", ".h", ".hpp", ".go", ".rs", ".java", ".js", ".ts", ".sh", ".bash", ".lua"}:
        score += 7
    if ext in {".md", ".rst", ".txt"}:
        score -= 3
    if base_l in {"makefile", "cmakelists.txt", "dockerfile"}:
        score += 2
    return score


def select_text_files_for_scan(files: Sequence[str]) -> List[str]:
    """Select a prioritized subset for full-text scanning while keeping full file index."""
    candidates = [f for f in files if is_text_candidate(f)]
    if len(candidates) <= MAX_TEXT_SCAN_FILES:
        return candidates
    ranked = sorted(candidates, key=lambda p: (-_text_scan_priority(p), p))
    return ranked[:MAX_TEXT_SCAN_FILES]


def _is_fixture(rel: str) -> bool:
    return "tests/fixtures/" in rel or rel.startswith("tests/fixtures/")


def _is_build_orchestration_path(rel: str) -> bool:
    rel_l = rel.lower()
    base_l = os.path.basename(rel_l)
    if base_l in _BUILD_TOOL_FILES:
        return True
    if any(rel_l.startswith(p) for p in _CI_BUILD_PREFIXES):
        return True
    if rel_l.startswith(("cmake/", "build/", "packaging/", "dist/")):
        return True
    return False


def find_entrypoints(repo_root: str, files: Sequence[str], texts: Dict[str, str]) -> List[Entrypoint]:
    entrypoints: List[Entrypoint] = []
    for rel in files:
        if _is_fixture(rel):
            continue
        # Skip CI/build orchestration — not runtime entrypoints
        if _is_build_orchestration_path(rel):
            continue
        base = os.path.basename(rel)
        base_l = base.lower()
        ext = os.path.splitext(rel)[1].lower()
        text = texts.get(rel, "")
        abs_path = os.path.join(repo_root, rel)

        score = 0
        signals: List[str] = []

        if rel.startswith("bin/"):
            score += 5
            signals.append("bin")
        if os.access(abs_path, os.X_OK):
            score += 4
            signals.append("executable")
        if base_l in ENTRY_NAME_HINTS:
            score += 4
            signals.append("entry-name")
        if re.search(r"(main|cli|app|server)", base_l):
            score += 2
            signals.append("name-hint")
        if "/" not in rel and ext in {".py", ".sh", ".js", ".ts", ".go", ".rb", ".rs"}:
            score += 1
            signals.append("repo-root")

        if text:
            if re.search(r"case\s+\"?\$[A-Za-z_]", text):
                score += 4
                signals.append("case-dispatch")
            if re.search(r"argparse|add_parser|subparsers|click\.command", text):
                score += 3
                signals.append("cli-parser")
            if re.search(r"if __name__ == [\"']__main__[\"']", text):
                score += 2
                signals.append("__main__")
            # C/C++ main function
            if ext in {".c", ".cc", ".cpp"} and re.search(r"\bint\s+main\s*\(", text):
                score += 5
                signals.append("c-main")

        has_runtime_router = any(
            s in signals for s in ("case-dispatch", "cli-parser", "__main__", "c-main", "bin")
        )

        # Penalize common non-runtime locations/scripts unless they expose router signals.
        if any(rel.lower().startswith(p) for p in _NON_RUNTIME_PREFIXES) and not has_runtime_router:
            score -= 4
            signals.append("non-runtime-path")
        if ext in {".sh", ".bash"} and not rel.startswith("bin/") and not has_runtime_router:
            score -= 3
            signals.append("non-entry-shell")

        if score >= 4:
            entrypoints.append(Entrypoint(path=rel, score=score, signals=signals))

    entrypoints.sort(key=lambda e: (-e.score, e.path))
    return entrypoints[:8]


def _resolve_shell_source_path(source_token: str, entry_file: str, file_set: Set[str]) -> str:
    token = source_token.strip().strip("'\"")
    if not token or "$" in token or "`" in token:
        return ""

    if token in file_set:
        return token

    if token.startswith("./") or token.startswith("../"):
        candidate = os.path.normpath(os.path.join(os.path.dirname(entry_file), token)).replace("\\", "/")
        if candidate in file_set:
            return candidate

    # Common variable-based pattern in this repo: $RQS_LIB_DIR/<file>.sh
    if "/" in token:
        tail = token.split("/")[-1]
        if tail:
            lib_candidate = f"lib/{tail}"
            if lib_candidate in file_set:
                return lib_candidate

    return token


def parse_shell_dispatch(entry_file: str, text: str, file_set: Set[str]) -> List[DispatchEntry]:
    lines = text.splitlines()
    results: List[DispatchEntry] = []
    in_case = False
    current_cmd = ""
    current_source = ""
    current_handler = ""

    label_re = re.compile(r"^\s*([A-Za-z0-9_.-]+)\)\s*$")
    source_re = re.compile(r"^\s*source\s+(.+)$")
    handler_re = re.compile(r"\b(cmd_[A-Za-z0-9_]+)\b")

    for raw in lines:
        line = raw.strip()
        if line.startswith("case ") and "$" in line:
            in_case = True
            current_cmd = ""
            continue
        if in_case and line.startswith("esac"):
            in_case = False
            current_cmd = ""
            continue
        if not in_case:
            continue

        m_label = label_re.match(line)
        if m_label:
            current_cmd = m_label.group(1)
            current_source = ""
            current_handler = ""
            continue

        if not current_cmd:
            continue

        m_source = source_re.match(raw)
        if m_source and not current_source:
            token = m_source.group(1).split("#", 1)[0].strip()
            current_source = _resolve_shell_source_path(token, entry_file, file_set)

        m_handler = handler_re.search(raw)
        if m_handler and not current_handler:
            current_handler = m_handler.group(1)

        if line.startswith(";;"):
            results.append(
                DispatchEntry(
                    command=current_cmd,
                    entry_file=entry_file,
                    source_file=current_source,
                    handler=current_handler,
                )
            )
            current_cmd = ""

    return results


def parse_dispatch(entrypoints: Sequence[Entrypoint], texts: Dict[str, str], file_set: Set[str]) -> List[DispatchEntry]:
    entries: List[DispatchEntry] = []
    for ep in entrypoints:
        text = texts.get(ep.path, "")
        if not text:
            continue
        ext = os.path.splitext(ep.path)[1].lower()
        if ext in {".sh", ".bash", ""}:
            entries.extend(parse_shell_dispatch(ep.path, text, file_set))
        elif ext == ".py":
            parser_hits = re.findall(r"add_parser\(\s*[\"']([A-Za-z0-9_.-]+)[\"']", text)
            for cmd in parser_hits:
                entries.append(
                    DispatchEntry(
                        command=cmd,
                        entry_file=ep.path,
                        source_file="",
                        handler="",
                    )
                )

    dedup: Dict[Tuple[str, str, str, str], DispatchEntry] = {}
    for e in entries:
        dedup[(e.command, e.entry_file, e.source_file, e.handler)] = e
    result = list(dedup.values())
    result.sort(key=lambda e: (e.entry_file, e.command))
    return result


def compute_file_continuity(repo_root: str, tracked_files: Sequence[str], target_buckets: int = 40) -> Dict[str, float]:
    """Continuity per file over full git history once the file first appears.

    Continuity = active_buckets_since_first_seen / buckets_since_first_seen.
    """
    tracked = set(tracked_files)
    if not tracked:
        return {}

    try:
        proc = subprocess.run(
            ["git", "log", "--pretty=format:COMMIT", "--name-only"],
            cwd=repo_root,
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return {}
    if proc.returncode != 0:
        return {}

    commits: List[List[str]] = []
    current: List[str] = []
    for raw in proc.stdout.splitlines():
        line = raw.strip()
        if line == "COMMIT":
            if current:
                commits.append(current)
            current = []
            continue
        if not line:
            continue
        if line in tracked:
            current.append(line)
    if current:
        commits.append(current)

    commits.reverse()  # chronological
    if not commits:
        return {}

    bucket_size = max(1, round(len(commits) / max(1, target_buckets)))
    num_buckets = max(1, math.ceil(len(commits) / bucket_size))

    first_bucket: Dict[str, int] = {}
    active_buckets: Dict[str, Set[int]] = defaultdict(set)
    for ci, touched in enumerate(commits):
        b = ci // bucket_size
        for rel in set(touched):
            if rel not in first_bucket:
                first_bucket[rel] = b
            active_buckets[rel].add(b)

    continuity: Dict[str, float] = {}
    for rel, first_b in first_bucket.items():
        possible = num_buckets - first_b
        if possible <= 0:
            continue
        active = sum(1 for b in active_buckets[rel] if b >= first_b)
        continuity[rel] = active / possible
    return continuity


def rerank_entrypoints(
    entrypoints: Sequence[Entrypoint],
    critical_scores: Sequence[Tuple[str, float, Dict[str, float]]],
    continuity: Dict[str, float],
) -> List[Tuple[Entrypoint, float, float, float]]:
    """Blend heuristic, structural, and continuity signals for orientation ranking."""
    if not entrypoints:
        return []

    crit_map = {rel: (score, comp) for rel, score, comp in critical_scores}
    max_crit = max((score for _, score, _ in critical_scores), default=1.0) or 1.0

    ranked: List[Tuple[Entrypoint, float, float, float]] = []
    for ep in entrypoints:
        cscore, comp = crit_map.get(ep.path, (0.0, {}))
        fanin = float(comp.get("fanin", 0.0))
        dispatch = float(comp.get("dispatch", 0.0))
        cont = continuity.get(ep.path, 0.0)

        structural = (cscore / max_crit) * 4.0
        blended = float(ep.score) + structural + min(fanin, 8.0) * 0.8 + min(dispatch, 4.0) * 1.2 + cont * 2.5

        # Soft penalties for build/tooling surfaces still slipping through.
        if _is_build_orchestration_path(ep.path):
            blended -= 4.0
        if any(ep.path.lower().startswith(p) for p in _NON_RUNTIME_PREFIXES):
            blended -= 2.0

        ranked.append((ep, blended, cscore, cont))

    ranked.sort(key=lambda row: (-row[1], row[0].path))
    return ranked[:8]


def find_test_files(files: Sequence[str]) -> List[str]:
    tests: List[str] = []
    for rel in files:
        base = os.path.basename(rel).lower()
        # Directory-based detection: tests/ or test/ at any level
        if rel.startswith("tests/") or "/tests/" in rel:
            tests.append(rel)
            continue
        if rel.startswith("test/") or "/test/" in rel:
            tests.append(rel)
            continue
        # Filename-based detection
        if base.startswith("test_") or base.endswith("_test.py") or base.endswith(".spec.js"):
            tests.append(rel)
            continue
        # Lua test conventions: _spec.lua (busted/plenary)
        if base.endswith("_spec.lua") or base.endswith("_test.lua"):
            tests.append(rel)
    return sorted(set(tests))


def extract_test_case_count(rel: str, text: str) -> int:
    ext = os.path.splitext(rel)[1].lower()
    if ext in {".sh", ".bash"}:
        return len(re.findall(r"^\s*test_[A-Za-z0-9_]+\s*\(\)\s*\{", text, flags=re.MULTILINE))
    if ext == ".py":
        return len(re.findall(r"^\s*def\s+test_[A-Za-z0-9_]+\s*\(", text, flags=re.MULTILINE))
    if ext in {".js", ".jsx", ".ts", ".tsx"}:
        return len(re.findall(r"\b(?:it|test)\s*\(\s*[\"']", text))
    if ext == ".lua":
        # Lua busted/plenary: it('...') and describe('...')
        return len(re.findall(r"\bit\s*\(\s*[\"']", text))
    return 0


def extract_assert_count(rel: str, text: str) -> int:
    ext = os.path.splitext(rel)[1].lower()
    if ext in {".sh", ".bash"}:
        return len(re.findall(r"\bassert_[A-Za-z0-9_]+\b", text))
    if ext == ".py":
        return len(re.findall(r"\bassert\b", text))
    if ext in {".js", ".jsx", ".ts", ".tsx"}:
        return len(re.findall(r"\bexpect\s*\(", text))
    if ext == ".lua":
        # Lua test assertions: eq(), ok(), neq(), matches(), assert
        return len(re.findall(r"\b(?:eq|ok|neq|matches)\s*\(", text)) + len(re.findall(r"\bassert\b", text))
    return 0


def extract_rqs_command_hits(test_texts: Dict[str, str]) -> Counter:
    hits: Counter = Counter()
    pattern = re.compile(r"\brqs\b(?:\s+--repo\s+\S+)?\s+([A-Za-z0-9_-]+)")
    for text in test_texts.values():
        for cmd in pattern.findall(text):
            hits[cmd] += 1
    return hits


def find_runtime_boundaries(texts: Dict[str, str]) -> List[Tuple[str, List[Tuple[str, int, str]]]]:
    checks = [
        ("Strict shell fail-fast mode", re.compile(r"\bset -euo pipefail\b")),
        ("Repository boundary enforcement", re.compile(r"outside target repository|not inside a git repository")),
        ("Layered config loading", re.compile(r"defaults\.conf|\.rqsrc|load_config|source .*conf")),
        ("CLI input validation", re.compile(r"unknown option|argument required|requires <|must be")),
    ]

    findings: List[Tuple[str, List[Tuple[str, int, str]]]] = []
    for label, regex in checks:
        matches: List[Tuple[str, int, str]] = []
        for rel, text in texts.items():
            if not text:
                continue
            for idx, raw in enumerate(text.splitlines(), start=1):
                if regex.search(raw):
                    snippet = raw.strip()
                    if len(snippet) > 110:
                        snippet = snippet[:107] + "..."
                    matches.append((rel, idx, snippet))
                    if len(matches) >= 3:
                        break
            if len(matches) >= 3:
                break
        findings.append((label, matches))
    return findings


def resolve_internal_dep(rel: str, dep: str, file_set: Set[str]) -> str:
    ext = os.path.splitext(rel)[1].lower()
    src_dir = os.path.dirname(rel)

    if ext == ".py":
        dep = dep.strip()
        if not dep:
            return ""
        if dep.startswith("."):
            dep = dep.lstrip(".")
            base_dir = src_dir
            if dep:
                module_path = dep.replace(".", "/")
                candidates = [
                    f"{base_dir}/{module_path}.py" if base_dir else f"{module_path}.py",
                    f"{base_dir}/{module_path}/__init__.py" if base_dir else f"{module_path}/__init__.py",
                ]
            else:
                candidates = [f"{base_dir}/__init__.py"] if base_dir else []
        else:
            module_path = dep.replace(".", "/")
            candidates = [
                f"{module_path}.py",
                f"{module_path}/__init__.py",
            ]
            if src_dir:
                candidates.extend([
                    f"{src_dir}/{module_path}.py",
                    f"{src_dir}/{module_path}/__init__.py",
                ])
        for c in candidates:
            c = os.path.normpath(c).replace("\\", "/")
            if c in file_set:
                return c
        return ""

    if ext in {".js", ".jsx", ".ts", ".tsx"}:
        dep = dep.strip()
        if not dep.startswith("."):
            return ""
        base = os.path.normpath(os.path.join(src_dir, dep)).replace("\\", "/")
        candidates = [base]
        for suffix in (".ts", ".tsx", ".js", ".jsx"):
            candidates.append(base + suffix)
        for suffix in ("index.ts", "index.tsx", "index.js", "index.jsx"):
            candidates.append(f"{base}/{suffix}")
        for c in candidates:
            if c in file_set:
                return c
        return ""

    if ext in {".sh", ".bash"}:
        dep = dep.strip().strip("'\"")
        if not dep or "$" in dep or "`" in dep:
            return ""
        cands = [dep]
        if dep.startswith("./") or dep.startswith("../"):
            cands.append(os.path.normpath(os.path.join(src_dir, dep)).replace("\\", "/"))
        if src_dir:
            cands.append(os.path.normpath(os.path.join(src_dir, dep)).replace("\\", "/"))
        for c in cands:
            if c in file_set:
                return c
        return ""

    if ext in {".c", ".cc", ".cpp", ".h", ".hpp"}:
        dep = dep.strip().strip("'\"<>")
        if not dep or dep.startswith("/"):
            return ""

        candidates = [dep]
        if src_dir:
            candidates.append(os.path.normpath(os.path.join(src_dir, dep)).replace("\\", "/"))
            candidates.append(os.path.normpath(os.path.join(src_dir, "..", dep)).replace("\\", "/"))

        for root in ("src", "include", "lib"):
            candidates.append(f"{root}/{dep}")

        # Header without path often lives near the source directory.
        if "/" not in dep and dep.endswith((".h", ".hpp")):
            if src_dir:
                candidates.append(f"{src_dir}/{dep}")
            parent = os.path.dirname(src_dir)
            if parent:
                candidates.append(f"{parent}/{dep}")

        # Deduplicate while preserving order.
        seen = set()
        for c in candidates:
            norm = os.path.normpath(c).replace("\\", "/")
            if norm in seen:
                continue
            seen.add(norm)
            if norm in file_set:
                return norm
        return ""

    return ""


def extract_internal_edges(files: Sequence[str], texts: Dict[str, str], file_set: Set[str]) -> Dict[str, Set[str]]:
    edges: Dict[str, Set[str]] = defaultdict(set)
    for rel in files:
        text = texts.get(rel, "")
        if not text:
            continue
        ext = os.path.splitext(rel)[1].lower()
        deps: Set[str] = set()

        if ext == ".py":
            for mod in re.findall(r"^\s*import\s+([A-Za-z0-9_.,\s]+)", text, flags=re.MULTILINE):
                for part in mod.split(","):
                    token = part.strip().split(" as ")[0].strip()
                    dep = resolve_internal_dep(rel, token, file_set)
                    if dep:
                        deps.add(dep)
            for mod in re.findall(r"^\s*from\s+([.A-Za-z0-9_]+)\s+import\b", text, flags=re.MULTILINE):
                dep = resolve_internal_dep(rel, mod, file_set)
                if dep:
                    deps.add(dep)

        elif ext in {".js", ".jsx", ".ts", ".tsx"}:
            for mod in re.findall(r"\bfrom\s+[\"']([@A-Za-z0-9_./-]+)[\"']", text):
                dep = resolve_internal_dep(rel, mod, file_set)
                if dep:
                    deps.add(dep)
            for mod in re.findall(r"\brequire\s*\(\s*[\"']([@A-Za-z0-9_./-]+)[\"']\s*\)", text):
                dep = resolve_internal_dep(rel, mod, file_set)
                if dep:
                    deps.add(dep)

        elif ext in {".sh", ".bash"}:
            for mod in re.findall(r"(?:^|\s)(?:source|\.)\s+([A-Za-z0-9_./'\"-]+)", text):
                dep = resolve_internal_dep(rel, mod, file_set)
                if dep:
                    deps.add(dep)

        elif ext in {".c", ".cc", ".cpp", ".h", ".hpp"}:
            for mod in re.findall(r"^\s*#\s*include\s*[<\"]([^\">]+)[\">]", text, flags=re.MULTILINE):
                dep = resolve_internal_dep(rel, mod, file_set)
                if dep:
                    deps.add(dep)

        if deps:
            edges[rel].update(deps)
    return edges


def build_critical_scores(
    files: Sequence[str],
    line_counts: Dict[str, int],
    entrypoints: Sequence[Entrypoint],
    dispatch_entries: Sequence[DispatchEntry],
    test_texts: Dict[str, str],
    command_hits: Counter,
    edges: Dict[str, Set[str]],
) -> List[Tuple[str, float, Dict[str, float]]]:
    inbound: Dict[str, int] = defaultdict(int)
    for src, deps in edges.items():
        _ = src
        for dep in deps:
            inbound[dep] += 1

    entry_set = {e.path for e in entrypoints}

    dispatch_targets: Counter = Counter()
    command_to_source: Dict[str, str] = {}
    for d in dispatch_entries:
        if d.source_file:
            dispatch_targets[d.source_file] += 1
            command_to_source[d.command] = d.source_file

    test_path_hits: Counter = Counter()
    path_pattern = re.compile(r"\b(?:bin|lib|conf|src)/[A-Za-z0-9_./-]+\b")
    for text in test_texts.values():
        for p in path_pattern.findall(text):
            test_path_hits[p] += 1

    command_touch: Counter = Counter()
    for cmd, hits in command_hits.items():
        source = command_to_source.get(cmd)
        if source:
            command_touch[source] += hits

    symbol_counts: Dict[str, int] = defaultdict(int)
    symbol_re = re.compile(r"^\s*(class|def|function|struct|interface|type|enum)\b", flags=re.MULTILINE)
    for rel in files:
        text = test_texts.get(rel)
        if text is None:
            continue
        symbol_counts[rel] = len(symbol_re.findall(text))

    scores: List[Tuple[str, float, Dict[str, float]]] = []
    for rel in files:
        if _is_fixture(rel):
            continue
        ext = os.path.splitext(rel)[1].lower()
        entry = 1.0 if rel in entry_set else 0.0
        dispatch = float(dispatch_targets.get(rel, 0))
        fanin = float(inbound.get(rel, 0))
        test_ref = float(test_path_hits.get(rel, 0) + command_touch.get(rel, 0))
        lines = float(line_counts.get(rel, 0))
        sym = float(symbol_counts.get(rel, 0))
        if ext in {
            ".py", ".sh", ".bash", ".js", ".jsx", ".ts", ".tsx",
            ".go", ".rb", ".rs", ".java", ".c", ".cc", ".cpp",
        }:
            code_bonus = 1.5
        elif ext in {".md", ".rst", ".txt", ".ipynb"}:
            code_bonus = -0.8
        else:
            code_bonus = 0.0

        score = (
            6.0 * entry
            + 4.0 * dispatch
            + 3.0 * fanin
            + 2.0 * test_ref
            + min(lines / 300.0, 2.0)
            + min(sym / 8.0, 2.0)
            + code_bonus
        )
        components = {
            "entry": entry,
            "dispatch": dispatch,
            "fanin": fanin,
            "test": test_ref,
        }
        if lines == 0 and entry == 0 and dispatch == 0 and fanin == 0 and test_ref == 0:
            continue
        if score > 0.2:
            scores.append((rel, score, components))

    scores.sort(key=lambda x: (-x[1], x[0]))
    return scores[:12]


def find_risk_hotspots(texts: Dict[str, str]) -> List[Tuple[str, int, str, str]]:
    checks = [
        ("heuristic/fallback", re.compile(r"fallback|heuristic", re.IGNORECASE)),
        ("error suppression", re.compile(r"\|\|\s*true|2>/dev/null")),
        ("broad exception", re.compile(r"\bexcept Exception\b")),
        ("todo/fixme", re.compile(r"TODO|FIXME|XXX")),
    ]

    hotspots: List[Tuple[str, int, str, str]] = []
    for rel, text in texts.items():
        if not text or _is_fixture(rel):
            continue
        for idx, raw in enumerate(text.splitlines(), start=1):
            line = raw.strip()
            if not line:
                continue
            # Skip regex pattern definitions and their doc comments
            if "re.compile" in line or "re.match" in line or "re.search" in line:
                continue
            if line.startswith("#") and any(kw in line.lower() for kw in ("fallback", "heuristic", "todo", "fixme")):
                continue
            for label, regex in checks:
                if regex.search(line):
                    snippet = line
                    if len(snippet) > 100:
                        snippet = snippet[:97] + "..."
                    hotspots.append((rel, idx, label, snippet))
                    break
            if len(hotspots) >= 16:
                return hotspots
    return hotspots


def render_orientation(
    entrypoints: Sequence[Entrypoint],
    dispatch_entries: Sequence[DispatchEntry],
    critical_scores: Sequence[Tuple[str, float, Dict[str, float]]],
    continuity: Dict[str, float],
) -> None:
    def print_table(headers: Sequence[str], rows: Sequence[Sequence[object]], right_align: Set[int] | None = None) -> None:
        if right_align is None:
            right_align = set()
        widths = [len(h) for h in headers]
        for row in rows:
            for i, cell in enumerate(row):
                widths[i] = max(widths[i], len(str(cell)))

        def fmt_cell(col: int, value: object) -> str:
            text = str(value)
            return text.rjust(widths[col]) if col in right_align else text.ljust(widths[col])

        print("| " + " | ".join(fmt_cell(i, h) for i, h in enumerate(headers)) + " |")
        print("|-" + "-|-".join("-" * w for w in widths) + "-|")
        for row in rows:
            print("| " + " | ".join(fmt_cell(i, cell) for i, cell in enumerate(row)) + " |")

    _open_tag("orientation")
    print("## Orientation")
    print("> Entrypoints, dispatch surface, and critical-path ranking.")

    print("\n**Likely entrypoints:**")
    ranked_entrypoints = rerank_entrypoints(entrypoints, critical_scores, continuity)
    if not ranked_entrypoints:
        print("- *(no likely entrypoints detected by current heuristics)*")
        print("- Expected signals include executable files in `bin/`, entry-like filenames (`main`, `app`, `cli`, `server`), Python `__main__` blocks, and CLI parser wiring.")
        print("- Implication: this repo may be library-first, config/framework-driven, monorepo-style, or using entry conventions not covered by current static checks.")
    else:
        for ep, blended, cscore, cont in ranked_entrypoints[:6]:
            signals = ", ".join(ep.signals[:3]) if ep.signals else "heuristic"
            print(
                f"- `{ep.path}` (entry {ep.score}, blend {blended:.1f}, "
                f"critical {cscore:.1f}, continuity {cont:.0%}; {signals})"
            )

    print("\n**Dispatch surface:**")
    if not dispatch_entries:
        print("- *(no explicit dispatch map detected)*")
        print("- The detector currently maps shell `case \"$...\"` style command routing and Python `argparse add_parser(...)` command tables.")
        print("- Implication: control flow may be framework/router-driven, config/plugin-driven, direct-call without a command router, or outside the currently parsed patterns.")
    else:
        dispatch_rows: List[Tuple[str, str, str]] = []
        for e in dispatch_entries[:20]:
            if e.source_file and e.handler:
                handler = f"`{e.source_file}` -> `{e.handler}`"
            elif e.source_file:
                handler = f"`{e.source_file}`"
            elif e.handler:
                handler = f"`{e.handler}`"
            else:
                handler = "*(not resolved)*"
            dispatch_rows.append((f"`{e.command}`", f"`{e.entry_file}`", handler))
        print_table(("Command", "Entrypoint", "Handler"), dispatch_rows)

    if critical_scores:
        print("\n**Critical path (ranked):**")
        critical_rows: List[Tuple[int, str, str, str]] = []
        for rank, (rel, score, comp) in enumerate(critical_scores[:10], start=1):
            signals: List[str] = []
            if comp["entry"] > 0:
                signals.append("entrypoint")
            if comp["dispatch"] > 0:
                signals.append(f"dispatch x{int(comp['dispatch'])}")
            if comp["fanin"] > 0:
                signals.append(f"imported-by {int(comp['fanin'])}")
            if comp["test"] > 0:
                signals.append(f"test-touch {int(comp['test'])}")
            signal_text = ", ".join(signals) if signals else "size/symbol density"
            critical_rows.append((rank, f"`{rel}`", f"{score:.1f}", signal_text))
        print_table(("#", "File", "Score", "Signals"), critical_rows, right_align={0, 2})
    _close_tag("orientation")


def render_runtime_boundaries(findings: Sequence[Tuple[str, List[Tuple[str, int, str]]]]) -> None:
    _open_tag("runtime_boundaries")
    print("## Runtime Boundaries")
    print("> Guardrails and operational constraints inferred from implementation patterns.")
    any_match = False
    for label, matches in findings:
        if matches:
            any_match = True
            refs = ", ".join(f"`{rel}:{line}`" for rel, line, _ in matches[:2])
            print(f"- {label}: {refs}")
    if not any_match:
        print("- *(no strong boundary signals detected)*")
    _close_tag("runtime_boundaries")


def render_behavioral_contract(
    test_files: Sequence[str],
    test_cases: int,
    assertions: int,
    command_hits: Counter,
) -> None:
    _open_tag("behavioral_contract")
    print("## Behavioral Contract (Tests)")
    print("> What the test suite explicitly validates today.")
    if not test_files:
        print("- *(no test files detected)*")
        _close_tag("behavioral_contract")
        return

    print(f"- Test files detected: {len(test_files)}")
    print(f"- Named test cases detected: {test_cases}")
    print(f"- Assertion-like checks detected: {assertions}")

    print("\n**Most exercised command surfaces:**")
    if not command_hits:
        print("- *(no command invocation patterns detected in tests)*")
    else:
        for cmd, hits in command_hits.most_common(10):
            print(f"- `{cmd}` ({hits} references)")
    _close_tag("behavioral_contract")



def render_risk_hotspots(hotspots: Sequence[Tuple[str, int, str, str]]) -> None:
    def print_table(headers: Sequence[str], rows: Sequence[Sequence[object]]) -> None:
        widths = [len(h) for h in headers]
        for row in rows:
            for i, cell in enumerate(row):
                widths[i] = max(widths[i], len(str(cell)))

        def fmt_cell(col: int, value: object) -> str:
            return str(value).ljust(widths[col])

        print("| " + " | ".join(fmt_cell(i, h) for i, h in enumerate(headers)) + " |")
        print("|-" + "-|-".join("-" * w for w in widths) + "-|")
        for row in rows:
            print("| " + " | ".join(fmt_cell(i, cell) for i, cell in enumerate(row)) + " |")

    _open_tag("heuristic_risk_hotspots")
    print("## Heuristic Risk Hotspots")
    print("> Areas where behavior may be approximate, suppressed, or brittle under edge conditions.")
    if not hotspots:
        print("- *(no obvious hotspots detected by heuristics)*")
        _close_tag("heuristic_risk_hotspots")
        return

    rows = [(f"`{rel}:{line}`", label, f"`{snippet}`") for rel, line, label, snippet in hotspots[:12]]
    print_table(("File", "Signal", "Snippet"), rows)
    _close_tag("heuristic_risk_hotspots")



def main() -> None:
    parser = argparse.ArgumentParser(description="Generate primer onboarding insights")
    parser.add_argument("--repo", required=True, help="Repository root")
    parser.add_argument("--level", choices=["light", "medium", "heavy"], default="medium")
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo)
    files = run_git_ls_files(repo_root)
    file_set = set(files)

    text_files = select_text_files_for_scan(files)
    texts = {f: safe_read_text(repo_root, f) for f in text_files}
    line_counts = {f: safe_line_count(repo_root, f) for f in files}

    entrypoints = find_entrypoints(repo_root, files, texts)
    dispatch_entries = parse_dispatch(entrypoints, texts, file_set)

    test_files = find_test_files(files)
    test_texts = {f: safe_read_text(repo_root, f) for f in test_files}
    test_case_count = sum(extract_test_case_count(f, test_texts.get(f, "")) for f in test_files)
    assertion_count = sum(extract_assert_count(f, test_texts.get(f, "")) for f in test_files)
    command_hits = extract_rqs_command_hits(test_texts)

    edges = extract_internal_edges(files, texts, file_set)
    continuity = compute_file_continuity(repo_root, files)
    # Reuse a merged text map for symbol counting in critical score calculation.
    merged_texts = dict(texts)
    merged_texts.update(test_texts)
    critical_scores = build_critical_scores(
        files=files,
        line_counts=line_counts,
        entrypoints=entrypoints,
        dispatch_entries=dispatch_entries,
        test_texts=merged_texts,
        command_hits=command_hits,
        edges=edges,
    )

    boundaries = find_runtime_boundaries(texts)
    hotspots = find_risk_hotspots(texts)

    if args.level in {"medium", "heavy"}:
        render_orientation(entrypoints, dispatch_entries, critical_scores, continuity)
    else:
        render_orientation(entrypoints, dispatch_entries, [], continuity)
    print("")
    render_runtime_boundaries(boundaries)

    if args.level in {"medium", "heavy"}:
        print("")
        render_behavioral_contract(test_files, test_case_count, assertion_count, command_hits)

    if args.level == "heavy":
        print("")
        render_risk_hotspots(hotspots)


if __name__ == "__main__":
    main()
