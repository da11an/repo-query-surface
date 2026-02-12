#!/usr/bin/env python3
"""render.py — Markdown rendering layer for repo-query-surface.

Reads structured data from stdin, writes clean markdown to stdout.
Single script, multiple render modes. Stdlib only.
"""

import ast
import json
import os
import sys
import warnings
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
    depth_info = f"depth: {depth}" if depth else "full depth"
    print(f"> Filtered directory structure from git-tracked files ({depth_info}, {len(file_list)} files). Request `rqs tree <path> --depth N` to explore subdirectories.")
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
    sym_count = len(symbols)
    file_count = len(by_file)
    print(f"> Symbol index extracted via ctags — classes, functions, types grouped by file ({sym_count} symbols across {file_count} files). Request `rqs outline <file>` for hierarchy detail or `rqs signatures <file>` for full signatures.")

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
    print("> Structural hierarchy of symbols with line spans. Request `rqs slice <file> <start> <end>` to see implementation.")
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
    filepath = "?"
    lang = ""
    start_line = None
    end_line = None
    i = 0
    positional = []
    while i < len(args):
        if args[i] == "--lines":
            start_line = args[i + 1]
            end_line = args[i + 2]
            i += 3
        else:
            positional.append(args[i])
            i += 1
    filepath = positional[0] if len(positional) > 0 else "?"
    lang = positional[1] if len(positional) > 1 else ""

    content = sys.stdin.read()
    if not content.strip():
        print("*(empty slice)*")
        return

    if start_line and end_line:
        print(f"## Slice: `{filepath}` (lines {start_line}-{end_line})")
    else:
        print(f"## Slice: `{filepath}`")
    print("> Code extract with line numbers. Request adjacent ranges to see surrounding context.")
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
    print("> Source locations where this symbol is defined. Request `rqs slice <file> <start> <end>` to see the implementation, or `rqs references <symbol>` for usage.")
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
    print("> Call sites and usage (definition lines excluded). Format: file:line:content.")
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
    print("> Import analysis. Internal = exists in this repo. External = third-party or stdlib.")

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

    match_count = sum(len(v) for v in results.values())
    file_count = len(results)
    print(f"## Grep: `{pattern}`")
    print(f"> Regex search results across git-tracked files, grouped by file with line numbers ({match_count} matches in {file_count} files).")

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


# ── Signatures Rendering ───────────────────────────────────────────────────


def _get_docstring_first_line(node):
    """Extract the first line of a docstring from an AST node, or None."""
    if (node.body
            and isinstance(node.body[0], ast.Expr)
            and isinstance(node.body[0].value, ast.Constant)):
        val = node.body[0].value
        doc = val.value
        if isinstance(doc, str):
            first = doc.strip().split("\n")[0].strip()
            return first
    return None


def _reconstruct_decorator(node, source_lines):
    """Reconstruct a decorator from source lines."""
    return source_lines[node.lineno - 1].rstrip()


def _reconstruct_def_line(node, source_lines):
    """Reconstruct the def/class line from source, handling multi-line."""
    lines = []
    for i in range(node.lineno - 1, min(node.end_lineno or node.lineno, len(source_lines))):
        lines.append(source_lines[i].rstrip())
        if ":" in source_lines[i]:
            break
    return "\n".join(lines)


def _extract_return_lines(node, source_lines):
    """Extract return statement lines from a function body (top-level only, not nested)."""
    returns = []
    for child in ast.walk(node):
        if isinstance(child, ast.Return) and child is not node:
            # Skip returns inside nested functions/classes
            if _is_direct_child_return(node, child):
                line = source_lines[child.lineno - 1].rstrip()
                returns.append(line)
    return returns


def _is_direct_child_return(func_node, return_node):
    """Check if a return node belongs directly to func_node (not a nested def)."""
    # Walk the function body to find returns, but stop at nested function boundaries
    for child in ast.iter_child_nodes(func_node):
        if child is return_node:
            return True
        if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            continue  # Don't recurse into nested defs
        if _is_direct_child_return(child, return_node):
            return True
    return False


def _extract_signatures_from_file(filepath, source_lines, indent=""):
    """Extract signatures from a parsed AST file."""
    try:
        source = "\n".join(source_lines)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            tree = ast.parse(source, filename=filepath)
    except SyntaxError:
        return [f"{indent}# (syntax error, could not parse)"]

    return _extract_signatures_from_body(tree.body, source_lines, indent, is_module=True)


def _extract_signatures_from_body(body, source_lines, indent="", is_module=False):
    """Extract signatures from a list of AST body nodes."""
    lines = []

    # Module-level docstring
    if is_module and body:
        first = body[0]
        if (isinstance(first, ast.Expr)
                and isinstance(first.value, ast.Constant)):
            val = first.value
            doc = val.value
            if isinstance(doc, str):
                first_line = doc.strip().split("\n")[0].strip()
                lines.append(f"{indent}# {first_line}")
                lines.append("")

    for node in body:
        if isinstance(node, ast.ClassDef):
            # Decorators
            for dec in node.decorator_list:
                lines.append(_reconstruct_decorator(dec, source_lines))
            # Class definition line
            lines.append(_reconstruct_def_line(node, source_lines))
            # Class docstring
            doc = _get_docstring_first_line(node)
            if doc:
                lines.append(f"{indent}    # {doc}")
                lines.append("")
            # Class body — recurse for methods
            method_lines = _extract_signatures_from_body(
                node.body, source_lines, indent + "    "
            )
            if method_lines:
                lines.extend(method_lines)
            lines.append("")

        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            # Decorators
            for dec in node.decorator_list:
                lines.append(_reconstruct_decorator(dec, source_lines))
            # Function definition line
            lines.append(_reconstruct_def_line(node, source_lines))
            # Docstring
            doc = _get_docstring_first_line(node)
            if doc:
                lines.append(f"{indent}    # {doc}")
            # Return statements
            returns = _extract_return_lines(node, source_lines)
            if returns:
                for ret in returns:
                    lines.append(ret)
            elif not doc:
                # No docstring and no returns — show placeholder
                lines.append(f"{indent}    ...")
            lines.append("")

    return lines


def render_signatures(args):
    """Render Python file signatures from file list on stdin."""
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    file_list = [line.strip() for line in sys.stdin if line.strip()]
    if not file_list:
        print("*(no Python files found)*")
        return

    for filepath in file_list:
        abs_path = os.path.join(repo_root, filepath)
        if not os.path.isfile(abs_path):
            continue

        try:
            with open(abs_path) as f:
                source_lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue

        sig_lines = _extract_signatures_from_file(filepath, source_lines)

        # Skip files with no meaningful signatures
        non_empty = [l for l in sig_lines if l.strip() and l.strip() != "..."]
        if not non_empty:
            continue

        # Trim trailing blank lines
        while sig_lines and not sig_lines[-1].strip():
            sig_lines.pop()

        print(f"## Signatures: `{filepath}`")
        print("> Behavioral sketch: class/function headers, decorators, first-line docstrings, and return statements. Implementation details omitted. Request `rqs slice <file> <start> <end>` to see full code.")
        print("```python")
        for line in sig_lines:
            print(line)
        print("```")
        print()


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
    "signatures": render_signatures,
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
