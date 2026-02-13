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
import os
import re
import subprocess
from collections import Counter, defaultdict
from dataclasses import dataclass
from typing import Dict, List, Sequence, Set, Tuple


MAX_SCAN_BYTES = 512_000
MAX_SCAN_FILES = 2000

TEXT_EXTS = {
    ".py", ".sh", ".bash", ".zsh", ".js", ".jsx", ".ts", ".tsx", ".go", ".rb",
    ".rs", ".java", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs", ".php", ".swift",
    ".kt", ".kts", ".scala", ".sql", ".md", ".rst", ".txt", ".toml", ".yaml",
    ".yml", ".json", ".xml", ".ini", ".cfg", ".conf",
}

ENTRY_NAME_HINTS = {
    "main.py", "main.go", "main.rs", "index.js", "app.py", "app.js",
    "cli.py", "cli.js", "manage.py", "server.py", "server.js", "rakefile",
    "makefile",
}


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
    return files[:MAX_SCAN_FILES]


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


def find_entrypoints(repo_root: str, files: Sequence[str], texts: Dict[str, str]) -> List[Entrypoint]:
    entrypoints: List[Entrypoint] = []
    for rel in files:
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


def find_test_files(files: Sequence[str]) -> List[str]:
    tests: List[str] = []
    for rel in files:
        base = os.path.basename(rel).lower()
        if rel.startswith("tests/") or "/tests/" in rel:
            tests.append(rel)
            continue
        if base.startswith("test_") or base.endswith("_test.py") or base.endswith(".spec.js"):
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
    return 0


def extract_assert_count(rel: str, text: str) -> int:
    ext = os.path.splitext(rel)[1].lower()
    if ext in {".sh", ".bash"}:
        return len(re.findall(r"\bassert_[A-Za-z0-9_]+\b", text))
    if ext == ".py":
        return len(re.findall(r"\bassert\b", text))
    if ext in {".js", ".jsx", ".ts", ".tsx"}:
        return len(re.findall(r"\bexpect\s*\(", text))
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
        if not text:
            continue
        for idx, raw in enumerate(text.splitlines(), start=1):
            line = raw.strip()
            if not line:
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


def render_fast_start(
    entrypoints: Sequence[Entrypoint],
    dispatch_entries: Sequence[DispatchEntry],
    read_order: Sequence[Tuple[str, str]],
) -> None:
    print("## Fast Start Map")
    print("> Deterministic onboarding map: likely entrypoints, dispatch surface, and a suggested first-read path.")

    print("\n**Likely entrypoints:**")
    if not entrypoints:
        print("- *(none detected)*")
    else:
        for ep in entrypoints[:6]:
            signals = ", ".join(ep.signals[:3]) if ep.signals else "heuristic"
            print(f"- `{ep.path}` (score {ep.score}; {signals})")

    print("\n**Detected dispatch surface:**")
    if not dispatch_entries:
        print("- *(no explicit dispatch map detected)*")
    else:
        print("| Command | Entrypoint | Handler |")
        print("|---------|------------|---------|")
        for e in dispatch_entries[:20]:
            if e.source_file and e.handler:
                handler = f"`{e.source_file}` -> `{e.handler}`"
            elif e.source_file:
                handler = f"`{e.source_file}`"
            elif e.handler:
                handler = f"`{e.handler}`"
            else:
                handler = "*(not resolved)*"
            print(f"| `{e.command}` | `{e.entry_file}` | {handler} |")

    print("\n**Suggested first read order:**")
    if not read_order:
        print("- *(unable to derive read order)*")
    else:
        for idx, (path, reason) in enumerate(read_order[:10], start=1):
            print(f"{idx}. `{path}` — {reason}")


def render_runtime_boundaries(findings: Sequence[Tuple[str, List[Tuple[str, int, str]]]]) -> None:
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


def render_behavioral_contract(
    test_files: Sequence[str],
    test_cases: int,
    assertions: int,
    command_hits: Counter,
) -> None:
    print("## Behavioral Contract (Tests)")
    print("> What the test suite explicitly validates today.")
    if not test_files:
        print("- *(no test files detected)*")
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


def render_critical_path(scores: Sequence[Tuple[str, float, Dict[str, float]]]) -> None:
    print("## Critical Path Files")
    print("> Heuristic centrality ranking using entrypoint/dispatch role, dependency fan-in, and test touch points.")
    if not scores:
        print("- *(no critical-path signals detected)*")
        return

    print("| File | Score | Signals |")
    print("|------|------:|---------|")
    for rel, score, comp in scores[:10]:
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
        print(f"| `{rel}` | {score:.1f} | {signal_text} |")


def render_risk_hotspots(hotspots: Sequence[Tuple[str, int, str, str]]) -> None:
    print("## Heuristic Risk Hotspots")
    print("> Areas where behavior may be approximate, suppressed, or brittle under edge conditions.")
    if not hotspots:
        print("- *(no obvious hotspots detected by heuristics)*")
        return

    print("| File | Signal | Snippet |")
    print("|------|--------|---------|")
    for rel, line, label, snippet in hotspots[:12]:
        print(f"| `{rel}:{line}` | {label} | `{snippet}` |")


def derive_read_order(
    entrypoints: Sequence[Entrypoint],
    dispatch_entries: Sequence[DispatchEntry],
    critical_scores: Sequence[Tuple[str, float, Dict[str, float]]],
    test_files: Sequence[str],
) -> List[Tuple[str, str]]:
    order: List[Tuple[str, str]] = []
    seen: Set[str] = set()

    def add(path: str, reason: str) -> None:
        if not path or path in seen:
            return
        seen.add(path)
        order.append((path, reason))

    for ep in entrypoints[:3]:
        add(ep.path, "entrypoint and control-flow root")

    dispatch_sources = Counter(d.source_file for d in dispatch_entries if d.source_file)
    for src, _count in dispatch_sources.most_common(5):
        add(src, "direct dispatch target")

    for rel, _score, _comp in critical_scores[:6]:
        add(rel, "high criticality score")

    for tf in test_files[:3]:
        add(tf, "behavioral contract (tests)")

    return order


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate primer onboarding insights")
    parser.add_argument("--repo", required=True, help="Repository root")
    parser.add_argument("--level", choices=["light", "medium", "heavy"], default="medium")
    args = parser.parse_args()

    repo_root = os.path.abspath(args.repo)
    files = run_git_ls_files(repo_root)
    file_set = set(files)

    text_files = [f for f in files if is_text_candidate(f)]
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

    read_order = derive_read_order(entrypoints, dispatch_entries, critical_scores, test_files)
    boundaries = find_runtime_boundaries(texts)
    hotspots = find_risk_hotspots(texts)

    render_fast_start(entrypoints, dispatch_entries, read_order)
    print("")
    render_runtime_boundaries(boundaries)

    if args.level in {"medium", "heavy"}:
        print("")
        render_behavioral_contract(test_files, test_case_count, assertion_count, command_hits)
        print("")
        render_critical_path(critical_scores)

    if args.level == "heavy":
        print("")
        render_risk_hotspots(hotspots)


if __name__ == "__main__":
    main()
