#!/usr/bin/env python3
"""render.py — Markdown rendering layer for repo-query-surface.

Reads structured data from stdin, writes clean markdown to stdout.
Single script, multiple render modes. Stdlib only.
"""

import json
import sys
from collections import defaultdict


# ── Tree Rendering ──────────────────────────────────────────────────────────


def build_tree(file_list, max_depth):
    """Build a nested dict tree from a flat list of file paths."""
    tree = {}
    dirs = set()  # Track which nodes are directories
    for path in file_list:
        parts = path.strip().split("/")
        truncated = max_depth and len(parts) > max_depth
        if truncated:
            parts = parts[:max_depth]
        node = tree
        for i, part in enumerate(parts):
            if part not in node:
                node[part] = {}
            # Mark intermediate parts as directories, and leaf as dir if truncated
            if i < len(parts) - 1 or truncated:
                node_path = "/".join(parts[: i + 1])
                dirs.add(node_path)
            node = node[part]
    return tree, dirs


def render_tree_lines(tree, dirs, prefix="", path_prefix=""):
    """Render tree dict into indented lines with box-drawing characters."""
    lines = []
    entries = sorted(tree.keys())
    for i, name in enumerate(entries):
        is_last = i == len(entries) - 1
        connector = "\u2514\u2500 " if is_last else "\u251c\u2500 "
        children = tree[name]
        node_path = f"{path_prefix}{name}" if not path_prefix else f"{path_prefix}/{name}"
        is_dir = children or node_path in dirs
        if is_dir:
            lines.append(f"{prefix}{connector}{name}/")
            extension = "   " if is_last else "\u2502  "
            lines.extend(render_tree_lines(children, dirs, prefix + extension, node_path))
        else:
            lines.append(f"{prefix}{connector}{name}")
    return lines


def render_tree(args):
    depth = None
    root = "."
    i = 0
    while i < len(args):
        if args[i] == "--depth":
            depth = int(args[i + 1])
            i += 2
        elif args[i] == "--root":
            root = args[i + 1]
            i += 2
        else:
            i += 1

    file_list = [line.strip() for line in sys.stdin if line.strip()]
    if not file_list:
        print("*(empty)*")
        return

    tree, dirs = build_tree(file_list, depth)
    root_label = root.rstrip("/") if root != "." else "."
    print(f"## Tree: `{root_label}`")
    print(f"```")
    print(f"{root_label}/")
    for line in render_tree_lines(tree, dirs):
        print(line)
    print(f"```")


# ── Symbol Rendering ───────────────────────────────────────────────────────


def parse_ctags_json(lines):
    """Parse ctags JSON output lines into structured records."""
    symbols = []
    for line in lines:
        line = line.strip()
        if not line or line.startswith("!"):
            continue
        try:
            tag = json.loads(line)
            if tag.get("_type") == "tag":
                symbols.append(tag)
        except json.JSONDecodeError:
            continue
    return symbols


def render_symbols(args):
    scope = None
    kinds = None
    from_cache = False
    i = 0
    while i < len(args):
        if args[i] == "--scope":
            scope = args[i + 1]
            i += 2
        elif args[i] == "--kinds":
            kinds = set(args[i + 1].split(","))
            i += 2
        elif args[i] == "--from-cache":
            from_cache = True
            i += 1
        else:
            i += 1

    lines = sys.stdin.readlines()
    symbols = parse_ctags_json(lines)

    # Filter by scope (path prefix)
    if scope and from_cache:
        symbols = [s for s in symbols if s.get("path", "").startswith(scope)]

    # Filter by kinds
    if kinds:
        symbols = [s for s in symbols if s.get("kind", "") in kinds]

    if not symbols:
        print("*(no symbols found)*")
        return

    # Group by file
    by_file = defaultdict(list)
    for sym in symbols:
        path = sym.get("path", "?")
        by_file[path].append(sym)

    title = f"## Symbols: `{scope}`" if scope else "## Symbols"
    print(title)

    for path in sorted(by_file.keys()):
        syms = by_file[path]
        print(f"\n### `{path}`")
        print("| Symbol | Kind | Line |")
        print("|--------|------|------|")
        for s in sorted(syms, key=lambda x: x.get("line", 0)):
            name = s.get("name", "?")
            kind = s.get("kind", "?")
            line = s.get("line", "?")
            scope_info = s.get("scope", "")
            scope_name = s.get("scopeKind", "")
            if scope_info:
                name = f"{scope_info}.{name}"
            print(f"| `{name}` | {kind} | {line} |")


# ── Outline Rendering ──────────────────────────────────────────────────────


def render_outline(args):
    filepath = args[0] if args else "?"

    lines = sys.stdin.readlines()
    symbols = parse_ctags_json(lines)

    if not symbols:
        print("*(no symbols found)*")
        return

    # Sort by line number
    symbols.sort(key=lambda s: s.get("line", 0))

    print(f"## Outline: `{filepath}`")
    print("```")
    for sym in symbols:
        name = sym.get("name", "?")
        kind = sym.get("kind", "?")
        line = sym.get("line", "?")
        scope = sym.get("scope", "")
        end_line = sym.get("end", "")

        # Indent based on scope depth
        indent = ""
        if scope:
            depth = scope.count(".") + 1
            indent = "  " * depth

        span = f"L{line}"
        if end_line:
            span = f"L{line}-{end_line}"

        print(f"{indent}{kind}: {name} [{span}]")
    print("```")


# ── Slice Rendering ─────────────────────────────────────────────────────────


def render_slice(args):
    filepath = args[0] if args else "?"
    lang = args[1] if len(args) > 1 else ""

    content = sys.stdin.read()
    if not content.strip():
        print("*(empty slice)*")
        return

    print(f"## Slice: `{filepath}`")
    print(f"```{lang}")
    print(content, end="")
    print("```")


# ── Definition Rendering ───────────────────────────────────────────────────


def render_definition(args):
    symbol = args[0] if args else "?"

    lines = sys.stdin.readlines()
    symbols = parse_ctags_json(lines)

    if not symbols:
        print(f"*(no definition found for `{symbol}`)*")
        return

    print(f"## Definition: `{symbol}`")
    print("| File | Kind | Line |")
    print("|------|------|------|")
    for s in symbols:
        path = s.get("path", "?")
        kind = s.get("kind", "?")
        line = s.get("line", "?")
        print(f"| `{path}` | {kind} | {line} |")


# ── References Rendering ───────────────────────────────────────────────────


def render_references(args):
    symbol = args[0] if args else "?"

    content = sys.stdin.read()
    if not content.strip():
        print(f"*(no references found for `{symbol}`)*")
        return

    print(f"## References: `{symbol}`")
    print(f"```")
    print(content, end="")
    print("```")


# ── Deps Rendering ─────────────────────────────────────────────────────────


def render_deps(args):
    filepath = args[0] if args else "?"

    lines = sys.stdin.readlines()
    if not lines:
        print("*(no dependencies found)*")
        return

    internal = []
    external = []

    for line in lines:
        line = line.strip()
        if not line:
            continue
        if line.startswith("INTERNAL:"):
            internal.append(line[len("INTERNAL:"):].strip())
        elif line.startswith("EXTERNAL:"):
            external.append(line[len("EXTERNAL:"):].strip())

    print(f"## Dependencies: `{filepath}`")

    if internal:
        print("\n**Internal:**")
        for dep in sorted(internal):
            print(f"- `{dep}`")

    if external:
        print("\n**External:**")
        for dep in sorted(external):
            print(f"- `{dep}`")

    if not internal and not external:
        print("*(no dependencies found)*")


# ── Grep Rendering ──────────────────────────────────────────────────────────


def render_grep(args):
    pattern = args[0] if args else "?"

    content = sys.stdin.read()
    if not content.strip():
        print(f"*(no matches for `{pattern}`)*")
        return

    # Parse grep output into grouped results
    results = defaultdict(list)
    current_file = None
    for line in content.strip().split("\n"):
        if not line or line == "--":
            continue
        # grep -Hn format: file:line:content or file-line-content (context)
        parts = line.split(":", 2)
        if len(parts) >= 3 and parts[1].isdigit():
            fpath, lineno, text = parts[0], parts[1], parts[2]
            current_file = fpath
            results[fpath].append((lineno, text))
        elif line.count("-") >= 2:
            # Context line: file-line-content
            parts = line.split("-", 2)
            if len(parts) >= 3 and parts[1].isdigit():
                fpath, lineno, text = parts[0], parts[1], parts[2]
                current_file = fpath
                results[fpath].append((lineno, text))

    print(f"## Grep: `{pattern}`")

    if not results:
        print(f"```")
        print(content, end="")
        print("```")
        return

    for fpath in sorted(results.keys()):
        matches = results[fpath]
        print(f"\n### `{fpath}`")
        print("```")
        for lineno, text in matches:
            print(f"{lineno}: {text}")
        print("```")


# ── Summaries Rendering ────────────────────────────────────────────────────


def render_summaries(args):
    """Render module/directory summaries from JSON input."""
    content = sys.stdin.read()
    if not content.strip():
        print("*(no summaries available)*")
        return

    try:
        summaries = json.loads(content)
    except json.JSONDecodeError:
        print("*(invalid summary data)*")
        return

    print("## Module Summaries")
    for entry in summaries:
        path = entry.get("path", "?")
        file_count = entry.get("files", 0)
        types = entry.get("types", {})
        description = entry.get("description", "")

        print(f"\n### `{path}/`")
        if description:
            print(f"{description}")
        parts = []
        if file_count:
            parts.append(f"{file_count} files")
        for ext, count in sorted(types.items()):
            parts.append(f"{count} {ext}")
        if parts:
            print(f"*{', '.join(parts)}*")


# ── Primer Rendering ───────────────────────────────────────────────────────


def render_primer(args):
    """Render complete primer from JSON sections."""
    content = sys.stdin.read()
    if not content.strip():
        print("*(empty primer)*")
        return

    # Primer content comes pre-assembled as markdown sections
    print(content, end="")


# ── Dispatch ────────────────────────────────────────────────────────────────


MODES = {
    "tree": render_tree,
    "symbols": render_symbols,
    "outline": render_outline,
    "slice": render_slice,
    "definition": render_definition,
    "references": render_references,
    "deps": render_deps,
    "grep": render_grep,
    "summaries": render_summaries,
    "primer": render_primer,
}


def main():
    if len(sys.argv) < 2:
        print(f"Usage: render.py <mode> [args...]", file=sys.stderr)
        print(f"Modes: {', '.join(sorted(MODES.keys()))}", file=sys.stderr)
        sys.exit(1)

    mode = sys.argv[1]
    args = sys.argv[2:]

    if mode not in MODES:
        print(f"error: unknown render mode '{mode}'", file=sys.stderr)
        sys.exit(1)

    MODES[mode](args)


if __name__ == "__main__":
    main()
