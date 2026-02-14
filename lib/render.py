#!/usr/bin/env python3
"""render.py — Markdown rendering layer for repo-query-surface.

Reads structured data from stdin, writes clean markdown to stdout.
Single script, multiple render modes. Stdlib only.
"""

import ast
import json
import math
import os
import re
import subprocess
import sys
import warnings
from collections import Counter, defaultdict


def _xml_escape_attr(value):
    """Escape attribute values for XML-style wrapper tags."""
    if value is None:
        return ""
    return (str(value)
            .replace("&", "&amp;")
            .replace('"', "&quot;")
            .replace("<", "&lt;")
            .replace(">", "&gt;"))


def _open_tag(tag, **attrs):
    """Emit a simple XML-style opening tag."""
    if attrs:
        rendered = " ".join(f'{k}="{_xml_escape_attr(v)}"' for k, v in attrs.items())
        print(f"<{tag} {rendered}>")
    else:
        print(f"<{tag}>")


def _close_tag(tag):
    """Emit a simple XML-style closing tag."""
    print(f"</{tag}>")


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


def render_tree_lines(tree, dirs, prefix="", path_prefix="", line_counts=None):
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
            lines.extend(render_tree_lines(children, dirs, prefix + extension, node_path, line_counts))
        else:
            lc = line_counts.get(node_path) if line_counts else None
            if lc is not None:
                lines.append(f"{prefix}{connector}{name} ({lc})")
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

    # Compute line counts
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")
    line_counts = {}
    for f in file_list:
        path = os.path.join(repo_root, f)
        try:
            with open(path, "rb") as fh:
                line_counts[f] = sum(1 for _ in fh)
        except OSError:
            pass

    tree, dirs = build_tree(file_list, depth)
    root_label = root.rstrip("/") if root != "." else "."
    print(f"## Tree: `{root_label}`")
    depth_info = f"depth: {depth}" if depth else "full depth"
    print(f"> Filtered directory structure from git-tracked files ({depth_info}, {len(file_list)} files). Request `rqs tree <path> --depth N` to explore subdirectories.")
    print(f"```")
    print(f"{root_label}/")
    for line in render_tree_lines(tree, dirs, line_counts=line_counts):
        print(line)
    print(f"```")


# ── Symbol Rendering ───────────────────────────────────────────────────────


CTAGS_KIND_MAP = {
    "c": "class",
    "f": "function",
    "m": "member",
    "v": "variable",
    "p": "prototype",
    "s": "struct",
    "u": "union",
    "e": "enum",
    "g": "enum_member",
    "t": "typedef",
    # fall back to raw code if unknown
}

def _parse_exuberant_tag_line(line: str):
    """Parse a single classic-format Exuberant/Universal ctags line into our tag dict."""
    if line.startswith("!"):
        return None

    parts = line.split("\t")
    if len(parts) < 4:
        return None

    name = parts[0]
    path = parts[1]
    # parts[2] is the ex command; we don't need it here
    rest = parts[3:]
    if not rest:
        return None

    # First field after ex command is the kind code (single letter)
    kind_code = rest[0]
    extra = rest[1:]

    kind = CTAGS_KIND_MAP.get(kind_code, kind_code)
    line_no = None
    end_no = None
    sig = None
    scope = None
    scope_kind = None

    for field in extra:
        if field.startswith("line:"):
            try:
                line_no = int(field.split(":", 1)[1])
            except ValueError:
                pass
        elif field.startswith("end:"):
            try:
                end_no = int(field.split(":", 1)[1])
            except ValueError:
                pass
        elif field.startswith("signature:"):
            sig = field.split(":", 1)[1]
        elif ":" in field:
            # Scope fields like class:ClassName, function:FuncName
            fkey, fval = field.split(":", 1)
            if fkey in ("class", "struct", "function", "enum", "interface", "namespace", "module"):
                scope = fval
                scope_kind = fkey

    if line_no is None:
        # Best-effort default; keeps sort stable without crashing
        line_no = 0

    tag = {
        "_type": "tag",
        "name": name,
        "path": path,
        "line": line_no,
        "kind": kind,
    }
    if end_no is not None:
        tag["end"] = end_no
    if sig is not None:
        tag["signature"] = sig
    if scope is not None:
        tag["scope"] = scope
    if scope_kind is not None:
        tag["scopeKind"] = scope_kind

    return tag

def parse_ctags_json(lines):
    """Parse ctags output (Universal JSON or classic) into structured records."""
    symbols = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue

        tag = None

        # Prefer JSON (Universal Ctags)
        if line.startswith("{") or line.startswith("["):
            try:
                tag = json.loads(line)
            except json.JSONDecodeError:
                tag = None

        # Fallback: classic tags line (Exuberant / non-JSON Universal)
        if tag is None:
            tag = _parse_exuberant_tag_line(line)

        if tag and tag.get("_type") == "tag":
            symbols.append(tag)

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
        syms = sorted(by_file[path], key=lambda x: x.get("line", 0))
        _open_tag("file", path=path)
        print(f"\n### `{path}`")

        # Pre-compute rows and column widths
        rows = []
        for s in syms:
            name = s.get("name", "?")
            kind = s.get("kind", "?")
            line = s.get("line", "?")
            end = s.get("end", "")
            sig = s.get("signature", "")
            scope_info = s.get("scope", "")
            if scope_info:
                name = f"{scope_info}.{name}"
            lines_str = f"{line}-{end}" if end else str(line)
            rows.append((name, kind, lines_str, sig))

        w_sym = max(max((len(r[0]) + 2 for r in rows), default=6), 6)   # "Symbol"
        w_kind = max(max((len(r[1]) for r in rows), default=4), 4)      # "Kind"
        w_lines = max(max((len(r[2]) for r in rows), default=5), 5)     # "Lines"
        w_sig = max(max((len(r[3]) + 2 for r in rows if r[3]), default=9), 9)  # "Signature"

        print(f"| {'Symbol':<{w_sym}} | {'Kind':<{w_kind}} | {'Lines':<{w_lines}} | {'Signature':<{w_sig}} |")
        print(f"|{'-' * (w_sym + 2)}|{'-' * (w_kind + 2)}|{'-' * (w_lines + 2)}|{'-' * (w_sig + 2)}|")
        for name, kind, lines_str, sig in rows:
            sym_col = f"`{name}`".ljust(w_sym)
            kind_col = kind.ljust(w_kind)
            lines_col = lines_str.ljust(w_lines)
            sig_col = f"`{sig}`".ljust(w_sig) if sig else " " * w_sig
            print(f"| {sym_col} | {kind_col} | {lines_col} | {sig_col} |")
        _close_tag("file")


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
        sig = sym.get("signature", "")

        # Indent based on scope depth
        indent = ""
        if scope:
            depth = scope.count(".") + 1
            indent = "  " * depth

        span = f"L{line}"
        if end_line:
            span = f"L{line}-{end_line}"

        if sig:
            print(f"{indent}{kind}: {name}{sig} [{span}]")
        else:
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

    # Pre-compute rows and column widths
    rows = []
    for s in symbols:
        path = s.get("path", "?")
        kind = s.get("kind", "?")
        line = s.get("line", "?")
        end = s.get("end", "")
        lines_str = f"{line}-{end}" if end else str(line)
        rows.append((path, kind, lines_str))

    w_file = max(max((len(r[0]) + 2 for r in rows), default=4), 4)   # "File"
    w_kind = max(max((len(r[1]) for r in rows), default=4), 4)       # "Kind"
    w_lines = max(max((len(r[2]) for r in rows), default=5), 5)      # "Lines"

    print(f"| {'File':<{w_file}} | {'Kind':<{w_kind}} | {'Lines':<{w_lines}} |")
    print(f"|{'-' * (w_file + 2)}|{'-' * (w_kind + 2)}|{'-' * (w_lines + 2)}|")
    for path, kind, lines_str in rows:
        file_col = f"`{path}`".ljust(w_file)
        kind_col = kind.ljust(w_kind)
        lines_col = lines_str.ljust(w_lines)
        print(f"| {file_col} | {kind_col} | {lines_col} |")


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
        symbols = entry.get("symbols", [])

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
        if symbols:
            sym_str = ", ".join(f"`{s}`" for s in symbols[:10])
            if len(symbols) > 10:
                sym_str += f", ... ({len(symbols)} total)"
            print(sym_str)


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


def _extract_signatures_from_file(filepath, source_lines, indent="", with_spans=False):
    """Extract signatures from a parsed AST file."""
    try:
        source = "\n".join(source_lines)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            tree = ast.parse(source, filename=filepath)
    except SyntaxError:
        return [f"{indent}# (syntax error, could not parse)"]

    return _extract_signatures_from_body(tree.body, source_lines, indent, is_module=True, with_spans=with_spans)


def _extract_signatures_from_body(body, source_lines, indent="", is_module=False, with_spans=False):
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
            def_line = _reconstruct_def_line(node, source_lines)
            if with_spans and hasattr(node, 'end_lineno') and node.end_lineno:
                def_line += f"  # L{node.lineno}-{node.end_lineno}"
            lines.append(def_line)
            # Class docstring
            doc = _get_docstring_first_line(node)
            if doc:
                lines.append(f"{indent}    # {doc}")
                lines.append("")
            # Class body — recurse for methods
            method_lines = _extract_signatures_from_body(
                node.body, source_lines, indent + "    ", with_spans=with_spans
            )
            if method_lines:
                lines.extend(method_lines)
            lines.append("")

        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            # Decorators
            for dec in node.decorator_list:
                lines.append(_reconstruct_decorator(dec, source_lines))
            # Function definition line
            def_line = _reconstruct_def_line(node, source_lines)
            if with_spans and hasattr(node, 'end_lineno') and node.end_lineno:
                def_line += f"  # L{node.lineno}-{node.end_lineno}"
            lines.append(def_line)
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


# Language detection for code fences
_LANG_MAP = {
    ".py": "python", ".js": "javascript", ".ts": "typescript",
    ".jsx": "jsx", ".tsx": "tsx", ".sh": "bash", ".bash": "bash",
    ".rb": "ruby", ".go": "go", ".rs": "rust", ".java": "java",
    ".c": "c", ".h": "c", ".cpp": "cpp", ".cc": "cpp", ".hpp": "cpp",
    ".css": "css", ".html": "html", ".json": "json", ".yaml": "yaml",
    ".yml": "yaml", ".toml": "toml", ".xml": "xml", ".sql": "sql",
    ".md": "markdown",
}

# Kinds that represent meaningful signatures
_SIG_KINDS = {"class", "function", "method", "member", "struct", "interface",
              "type", "enum", "prototype", "module"}


def _format_ctags_signatures(symbols):
    """Format ctags symbols as signature-style lines."""
    symbols = [s for s in symbols if s.get("kind", "") in _SIG_KINDS]
    symbols.sort(key=lambda s: s.get("line", 0))
    if not symbols:
        return []
    lines = []
    for s in symbols:
        name = s.get("name", "?")
        kind = s.get("kind", "?")
        sig = s.get("signature", "")
        line = s.get("line", "?")
        end = s.get("end", "")
        scope = s.get("scope", "")
        indent = "    " if scope else ""
        span = f"L{line}-{end}" if end else f"L{line}"
        if sig:
            lines.append(f"{indent}{kind}: {name}{sig} [{span}]")
        else:
            lines.append(f"{indent}{kind}: {name} [{span}]")
    return lines


def _run_ctags_on_file(repo_root, filepath):
    """Run ctags on a single file and return parsed symbols."""
    # Try JSON format first (Universal Ctags)
    try:
        result = subprocess.run(
            ["ctags", "--output-format=json", "--fields=+nKSse", "-f", "-", filepath],
            cwd=repo_root, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return parse_ctags_json(result.stdout.strip().split("\n"))
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    # Try classic format (Exuberant Ctags)
    try:
        result = subprocess.run(
            ["ctags", "--fields=+nSe", "-f", "-", filepath],
            cwd=repo_root, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0 and result.stdout.strip():
            return parse_ctags_json(result.stdout.strip().split("\n"))
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return []


def render_signatures(args):
    """Render file signatures from file list on stdin.

    Python files: full AST analysis (signatures, decorators, docstrings, returns).
    Other languages: ctags-based behavioral sketch (signatures, line spans).
    """
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    scope = None
    with_spans = False
    i = 0
    while i < len(args):
        if args[i] == "--scope":
            scope = args[i + 1]
            i += 2
        elif args[i] == "--with-line-spans":
            with_spans = True
            i += 1
        else:
            i += 1

    file_list = [line.strip() for line in sys.stdin if line.strip()]
    if not file_list:
        print("*(no files found)*")
        return

    py_files = [f for f in file_list if f.endswith(".py")]
    other_files = [f for f in file_list if not f.endswith(".py")]

    results = []

    # Python: AST analysis
    for filepath in py_files:
        abs_path = os.path.join(repo_root, filepath)
        if not os.path.isfile(abs_path):
            continue

        try:
            with open(abs_path) as f:
                source_lines = f.read().splitlines()
        except (OSError, UnicodeDecodeError):
            continue

        sig_lines = _extract_signatures_from_file(filepath, source_lines, with_spans=with_spans)

        # Skip files with no meaningful signatures
        non_empty = [l for l in sig_lines if l.strip() and l.strip() != "..."]
        if not non_empty:
            continue

        # Trim trailing blank lines
        while sig_lines and not sig_lines[-1].strip():
            sig_lines.pop()

        ext = os.path.splitext(filepath)[1]
        lang = _LANG_MAP.get(ext, "")
        results.append((filepath, sig_lines, lang))

    # Non-Python: ctags-based signatures
    for filepath in other_files:
        symbols = _run_ctags_on_file(repo_root, filepath)
        if not symbols:
            continue
        sig_lines = _format_ctags_signatures(symbols)
        if not sig_lines:
            continue
        ext = os.path.splitext(filepath)[1]
        lang = _LANG_MAP.get(ext, "")
        results.append((filepath, sig_lines, lang))

    if not results:
        print("*(no signatures found)*")
        return

    # Print top-level header with description once
    if with_spans:
        title = f"## Symbol Map: `{scope}`" if scope else "## Symbol Map"
        print(title)
        print("> Symbols, signatures, and structure with line spans per file. Request `rqs slice <file> <start> <end>` to see full code.")
    else:
        title = f"## Signatures: `{scope}`" if scope else "## Signatures"
        print(title)
        print("> Behavioral sketch: signatures, structure, and key details per file. Request `rqs slice <file> <start> <end>` to see full code.")

    for filepath, sig_lines, lang in results:
        _open_tag("file", path=filepath, language=lang or "text")
        print(f"\n### `{filepath}`")
        print(f"```{lang}")
        for line in sig_lines:
            print(line)
        print("```")
        _close_tag("file")


# ── Show Rendering ─────────────────────────────────────────────────────────


def render_show(args):
    """Render full source of named symbols.

    Reads ctags data from stdin, finds matching symbols,
    reads source files directly, and renders each symbol's code.
    """
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    # All args are symbol names
    symbol_names = args
    if not symbol_names:
        print("*(no symbols specified)*")
        return

    # Parse ctags from stdin
    lines = sys.stdin.readlines()
    all_tags = parse_ctags_json(lines)

    for symbol in symbol_names:
        # Find matching tags
        matches = [t for t in all_tags if t.get("name") == symbol]

        if not matches:
            print(f"*(no definition found for `{symbol}`)*")
            print()
            continue

        # Prefer match with end line; among those, prefer class/function over member
        _kind_priority = {"class": 0, "struct": 0, "interface": 0, "enum": 0,
                          "function": 1, "method": 2, "member": 3}
        matches.sort(key=lambda t: (
            0 if "end" in t else 1,
            _kind_priority.get(t.get("kind", ""), 5),
            t.get("line", 0),
        ))
        best = matches[0]

        path = best.get("path", "")
        start = best.get("line", 1)
        end = best.get("end")
        kind = best.get("kind", "?")
        scope = best.get("scope", "")
        display_name = f"{scope}.{symbol}" if scope else symbol

        abs_path = os.path.join(repo_root, path)
        if not os.path.isfile(abs_path):
            print(f"*(file not found: {path})*")
            print()
            continue

        try:
            with open(abs_path) as f:
                source_lines = f.readlines()
        except (OSError, UnicodeDecodeError):
            print(f"*(could not read: {path})*")
            print()
            continue

        # If no end line, estimate from file length
        if end is None:
            end = len(source_lines)

        # Extract source with line numbers
        extracted = source_lines[start - 1:end]
        if not extracted:
            print(f"*(empty source for `{symbol}`)*")
            print()
            continue

        ext = os.path.splitext(path)[1]
        lang = _LANG_MAP.get(ext, "")

        _open_tag("symbol", name=display_name, kind=kind, path=path, start=start, end=end)
        print(f"## Show: `{display_name}` ({kind} in `{path}`, lines {start}-{end})")
        print(f"> Full source of `{display_name}`. Request `rqs references {symbol}` for usage, or `rqs show <other>` for related symbols.")
        print(f"```{lang}")
        width = len(str(end))
        for i, line in enumerate(extracted, start=start):
            print(f"{i:>{width}}: {line}", end="")
        print("```")
        _close_tag("symbol")
        print()


# ── Context Rendering ──────────────────────────────────────────────────────


def render_context(args):
    """Render the enclosing symbol for a given file:line.

    Reads ctags data from stdin, finds the innermost symbol
    containing the target line, and renders its full source.
    """
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    filepath = args[0] if args else "?"
    target_line = int(args[1]) if len(args) > 1 else 0

    # Parse ctags from stdin
    lines = sys.stdin.readlines()
    all_tags = parse_ctags_json(lines)

    # Filter to tags in this file that have end lines and contain the target line
    containing = []
    for t in all_tags:
        if t.get("path") != filepath:
            continue
        start = t.get("line", 0)
        end = t.get("end")
        if end is None:
            continue
        if start <= target_line <= end:
            containing.append(t)

    if not containing:
        # Fallback: find the nearest symbol starting before target_line
        file_tags = [t for t in all_tags if t.get("path") == filepath]
        before = [t for t in file_tags if t.get("line", 0) <= target_line]
        if before:
            before.sort(key=lambda t: t.get("line", 0), reverse=True)
            best = before[0]
            end = best.get("end")
            if end is None:
                # Estimate end from next symbol or EOF
                after = [t for t in file_tags if t.get("line", 0) > best.get("line", 0)]
                if after:
                    after.sort(key=lambda t: t.get("line", 0))
                    end = after[0].get("line", 0) - 1
                else:
                    abs_path = os.path.join(repo_root, filepath)
                    try:
                        with open(abs_path) as f:
                            end = sum(1 for _ in f)
                    except OSError:
                        end = target_line
            containing = [dict(best, end=end)]

    if not containing:
        print(f"*(no enclosing symbol found for `{filepath}:{target_line}`)*")
        return

    # Pick the innermost (smallest span) containing symbol
    containing.sort(key=lambda t: (t.get("end", 0) - t.get("line", 0)))
    best = containing[0]

    name = best.get("name", "?")
    kind = best.get("kind", "?")
    start = best.get("line", 1)
    end = best.get("end", start)
    scope = best.get("scope", "")
    display_name = f"{scope}.{name}" if scope else name

    abs_path = os.path.join(repo_root, filepath)
    try:
        with open(abs_path) as f:
            source_lines = f.readlines()
    except (OSError, UnicodeDecodeError):
        print(f"*(could not read: {filepath})*")
        return

    extracted = source_lines[start - 1:end]
    if not extracted:
        print(f"*(empty source)*")
        return

    ext = os.path.splitext(filepath)[1]
    lang = _LANG_MAP.get(ext, "")

    print(f"## Context: `{filepath}:{target_line}` \u2192 `{display_name}` ({kind}, lines {start}-{end})")
    print(f"> Enclosing symbol for line {target_line}. Request `rqs show {name}` or `rqs slice {filepath} {start} {end}` for the same code by name or range.")
    print(f"```{lang}")
    width = len(str(end))
    for i, line in enumerate(extracted, start=start):
        print(f"{i:>{width}}: {line}", end="")
    print("```")


# ── Diff Rendering ─────────────────────────────────────────────────────────


def render_diff(args):
    """Render git diff output as structured markdown."""
    ref = args[0] if args else None

    content = sys.stdin.read()
    if not content.strip():
        if ref:
            print(f"*(no differences against `{ref}`)*")
        else:
            print("*(no differences)*")
        return

    # Parse diff to count files and changes
    files_changed = set()
    additions = 0
    deletions = 0
    for line in content.split("\n"):
        if line.startswith("diff --git"):
            parts = line.split()
            if len(parts) >= 4:
                files_changed.add(parts[3].lstrip("b/"))
        elif line.startswith("+") and not line.startswith("+++"):
            additions += 1
        elif line.startswith("-") and not line.startswith("---"):
            deletions += 1

    if ref:
        print(f"## Diff: `{ref}`")
    else:
        print("## Diff")
    stats = f"{len(files_changed)} files, +{additions}/-{deletions} lines"
    print(f"> Git diff ({stats}). Request `rqs show <symbol>` or `rqs slice <file> <start> <end>` to see full context around changes.")
    print("```diff")
    print(content, end="")
    print("```")


# ── Files Rendering ────────────────────────────────────────────────────────


def render_files(args):
    """Render file list matching a glob pattern, with line counts."""
    pattern = args[0] if args else "?"
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    file_list = [line.strip() for line in sys.stdin if line.strip()]
    if not file_list:
        print(f"*(no files matching `{pattern}`)*")
        return

    # Compute line counts
    line_counts = {}
    for f in file_list:
        path = os.path.join(repo_root, f)
        try:
            with open(path, "rb") as fh:
                line_counts[f] = sum(1 for _ in fh)
        except OSError:
            pass

    total_lines = sum(line_counts.values())
    print(f"## Files: `{pattern}`")
    print(f"> {len(file_list)} files matching pattern ({total_lines} total lines). Request `rqs show <symbol>` or `rqs slice <file> <start> <end>` to read code.")

    for f in file_list:
        lc = line_counts.get(f)
        if lc is not None:
            print(f"- `{f}` ({lc} lines)")
        else:
            print(f"- `{f}`")


# ── Callees Rendering ──────────────────────────────────────────────────────


def render_callees(args):
    """Render what a function/method calls.

    Reads ctags data from stdin. Finds the target symbol, reads its
    source, extracts call names via AST (Python) or regex (other),
    and cross-references against the symbol table.
    """
    symbol = args[0] if args else "?"
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    # Parse all ctags from stdin
    lines = sys.stdin.readlines()
    all_tags = parse_ctags_json(lines)

    # Find the target symbol
    matches = [t for t in all_tags if t.get("name") == symbol]
    if not matches:
        print(f"*(no definition found for `{symbol}`)*")
        return

    # Prefer function/method with end line
    _kind_priority = {"function": 0, "method": 1, "member": 2, "class": 3}
    matches.sort(key=lambda t: (
        0 if "end" in t else 1,
        _kind_priority.get(t.get("kind", ""), 5),
        t.get("line", 0),
    ))
    best = matches[0]

    path = best.get("path", "")
    start = best.get("line", 1)
    end = best.get("end")
    kind = best.get("kind", "?")

    abs_path = os.path.join(repo_root, path)
    if not os.path.isfile(abs_path):
        print(f"*(file not found: {path})*")
        return

    try:
        with open(abs_path) as f:
            source_lines = f.readlines()
    except (OSError, UnicodeDecodeError):
        print(f"*(could not read: {path})*")
        return

    if end is None:
        end = len(source_lines)

    # Build symbol table for cross-referencing
    known_symbols = {}
    for t in all_tags:
        name = t.get("name", "")
        if name and name not in known_symbols:
            known_symbols[name] = {
                "path": t.get("path", ""),
                "kind": t.get("kind", ""),
                "line": t.get("line", 0),
            }

    # Extract calls
    ext = os.path.splitext(path)[1]
    if ext == ".py":
        calls = _extract_python_calls(abs_path, source_lines, start, end, symbol)
    else:
        calls = _extract_regex_calls(source_lines, start, end, known_symbols, symbol)

    if not calls:
        print(f"*(no calls found in `{symbol}`)*")
        return

    # Cross-reference calls against symbol table
    resolved = []
    unresolved = []
    for call_name in sorted(set(calls)):
        if call_name in known_symbols:
            info = known_symbols[call_name]
            resolved.append((call_name, info["path"], info["kind"], info["line"]))
        else:
            unresolved.append(call_name)

    scope = best.get("scope", "")
    display_name = f"{scope}.{symbol}" if scope else symbol

    print(f"## Callees: `{display_name}` ({kind} in `{path}`)")
    print(f"> Functions and methods called by `{display_name}`. Request `rqs show <symbol>` to read any of them.")

    if resolved:
        w_sym = max(max((len(r[0]) + 2 for r in resolved), default=13), 13)   # "Called Symbol"
        w_file = max(max((len(r[1]) + 2 for r in resolved), default=4), 4)    # "File"
        w_kind = max(max((len(r[2]) for r in resolved), default=4), 4)        # "Kind"
        w_line = max(max((len(str(r[3])) for r in resolved), default=4), 4)   # "Line"

        print(f"\n| {'Called Symbol':<{w_sym}} | {'File':<{w_file}} | {'Kind':<{w_kind}} | {'Line':>{w_line}} |")
        print(f"|{'-' * (w_sym + 2)}|{'-' * (w_file + 2)}|{'-' * (w_kind + 2)}|{'-' * (w_line + 2)}|")
        for name, fpath, fkind, fline in resolved:
            sym_col = f"`{name}`".ljust(w_sym)
            file_col = f"`{fpath}`".ljust(w_file)
            kind_col = fkind.ljust(w_kind)
            line_col = str(fline).rjust(w_line)
            print(f"| {sym_col} | {file_col} | {kind_col} | {line_col} |")

    if unresolved:
        print(f"\n**External/unresolved:** {', '.join(f'`{n}`' for n in unresolved)}")


def _extract_python_calls(filepath, source_lines, start, end, symbol_name):
    """Extract function/method call names from a Python function body using AST."""
    source = "".join(source_lines)
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", SyntaxWarning)
            tree = ast.parse(source, filename=filepath)
    except SyntaxError:
        return []

    # Find the target function node
    target_node = None
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if node.name == symbol_name and node.lineno >= start and node.lineno <= end:
                target_node = node
                break

    if target_node is None:
        # Might be a class — look for __init__ or just walk the range
        return _extract_range_calls(source_lines, start, end)

    # Walk the function body and collect call names
    calls = []
    for node in ast.walk(target_node):
        if isinstance(node, ast.Call):
            name = _get_call_name(node)
            if name and name != symbol_name:
                calls.append(name)

    return calls


def _get_call_name(call_node):
    """Extract the function name from an ast.Call node."""
    func = call_node.func
    if isinstance(func, ast.Name):
        return func.id
    elif isinstance(func, ast.Attribute):
        return func.attr
    return None


def _extract_range_calls(source_lines, start, end):
    """Fallback: extract call-like patterns from source lines via regex."""
    calls = []
    call_pattern = re.compile(r'\b([a-zA-Z_]\w*)\s*\(')
    # Python keywords that look like calls but aren't
    skip = {"if", "for", "while", "with", "return", "yield", "assert",
            "raise", "print", "del", "not", "and", "or", "in", "is",
            "class", "def", "lambda", "except", "finally", "try", "elif"}
    for line in source_lines[start - 1:end]:
        for m in call_pattern.finditer(line):
            name = m.group(1)
            if name not in skip:
                calls.append(name)
    return calls


def _extract_regex_calls(source_lines, start, end, known_symbols, symbol_name):
    """Extract call-like patterns and filter against known symbols."""
    calls = []
    call_pattern = re.compile(r'\b([a-zA-Z_]\w*)\s*\(')
    for line in source_lines[start - 1:end]:
        for m in call_pattern.finditer(line):
            name = m.group(1)
            if name != symbol_name and name in known_symbols:
                calls.append(name)
    return calls


# ── Related Rendering ──────────────────────────────────────────────────────


def render_related(args):
    """Render files related to a given file (forward + reverse deps)."""
    filepath = args[0] if args else "?"
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    forward_files = []
    reverse_files = []

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        if line.startswith("FORWARD:"):
            content = line[len("FORWARD:"):]
            if content:
                forward_files.append(content.strip())
        elif line.startswith("REVERSE:"):
            content = line[len("REVERSE:"):]
            if content:
                reverse_files.append(content.strip())

    # Compute line counts for referenced files
    all_related = set(forward_files + reverse_files)
    line_counts = {}
    for f in all_related:
        path = os.path.join(repo_root, f)
        try:
            with open(path, "rb") as fh:
                line_counts[f] = sum(1 for _ in fh)
        except OSError:
            pass

    print(f"## Related: `{filepath}`")
    total = len(all_related)
    print(f"> Neighborhood view: {len(forward_files)} imported by this file, {len(reverse_files)} files that reference it ({total} unique). Request `rqs deps <file>` for full import details.")

    if forward_files:
        print("\n**Imports (this file depends on):**")
        for f in forward_files:
            lc = line_counts.get(f)
            if lc is not None:
                print(f"- `{f}` ({lc} lines)")
            else:
                print(f"- `{f}`")

    if reverse_files:
        print("\n**Imported by (depends on this file):**")
        for f in reverse_files:
            lc = line_counts.get(f)
            if lc is not None:
                print(f"- `{f}` ({lc} lines)")
            else:
                print(f"- `{f}`")

    if not forward_files and not reverse_files:
        print("\n*(no related files found)*")


# ── Notebook Rendering ──────────────────────────────────────────────────────


def _truncate_text(text, max_lines):
    """Truncate text to max_lines, returning (truncated_text, total_lines)."""
    lines = text.split("\n")
    # Strip trailing empty line from final newline
    if lines and lines[-1] == "":
        lines = lines[:-1]
    total = len(lines)
    if total <= max_lines:
        return "\n".join(lines), total
    truncated = "\n".join(lines[:max_lines])
    return truncated, total


def _render_notebook_outputs(outputs, max_lines, max_tb):
    """Render cell outputs with truncation. Returns list of output strings."""
    result = []

    for out in outputs:
        output_type = out.get("output_type", "")

        if output_type in ("stream", "execute_result", "display_data"):
            # Get text content
            if output_type == "stream":
                text = out.get("text", "")
                if isinstance(text, list):
                    text = "".join(text)
            else:
                # execute_result / display_data — check for rich types first
                data = out.get("data", {})
                rich_types = []
                for mime in data:
                    if mime.startswith("image/") or mime in ("text/html", "text/latex", "application/json"):
                        rich_types.append(mime)

                if rich_types and "text/plain" not in data:
                    # Only rich outputs, no text fallback
                    for mime in rich_types:
                        result.append(f"[{mime} output]")
                    continue

                if rich_types:
                    # Has both rich and text — show placeholders for rich, then text
                    for mime in rich_types:
                        result.append(f"[{mime} output]")

                text = data.get("text/plain", "")
                if isinstance(text, list):
                    text = "".join(text)

            text = text.rstrip("\n")
            if not text:
                continue

            truncated, total = _truncate_text(text, max_lines)
            if total > max_lines:
                header = f"\u2192 {max_lines} lines of output (truncated from {total})"
            else:
                header = f"\u2192 {total} lines of output"

            result.append(f"{header}\n```\n{truncated}\n```")

        elif output_type == "error":
            ename = out.get("ename", "Error")
            evalue = out.get("evalue", "")
            traceback_lines = out.get("traceback", [])

            error_header = f"\u2192 **{ename}**: {evalue}"

            if traceback_lines:
                # Traceback lines may contain ANSI codes — strip them
                clean_tb = []
                for line in traceback_lines:
                    # Strip ANSI escape sequences
                    cleaned = re.sub(r'\x1b\[[0-9;]*m', '', str(line))
                    clean_tb.append(cleaned)

                total_frames = len(clean_tb)
                if total_frames > max_tb:
                    tb_display = clean_tb[-max_tb:]
                    tb_text = "\n".join(tb_display)
                    error_header += f" ({total_frames} frames, showing last {max_tb})"
                else:
                    tb_text = "\n".join(clean_tb)

                result.append(f"{error_header}\n```\n{tb_text}\n```")
            else:
                result.append(error_header)

    return result


def render_notebook(args):
    """Render a Jupyter notebook as structured markdown."""
    filepath = args[0] if args else "?"
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")
    max_output = int(os.environ.get("RQS_NOTEBOOK_MAX_OUTPUT_LINES", "10"))
    max_tb = int(os.environ.get("RQS_NOTEBOOK_MAX_TRACEBACK", "5"))

    abs_path = os.path.join(repo_root, filepath)
    try:
        with open(abs_path) as f:
            nb = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"*(error reading notebook: {e})*")
        return

    cells = nb.get("cells", [])
    metadata = nb.get("metadata", {})
    kernel = metadata.get("kernelspec", {}).get("language", "")
    kernel_name = metadata.get("kernelspec", {}).get("name", "")

    # Count cell types
    type_counts = {}
    for cell in cells:
        ct = cell.get("cell_type", "unknown")
        type_counts[ct] = type_counts.get(ct, 0) + 1

    count_parts = []
    for ct in ("code", "markdown", "raw"):
        if ct in type_counts:
            count_parts.append(f"{type_counts[ct]} {ct}")

    count_str = ", ".join(count_parts)
    kernel_str = f", kernel: {kernel_name}" if kernel_name else ""

    print(f"## Notebook: `{filepath}`")
    print(f"> {len(cells)} cells ({count_str}){kernel_str}")

    exec_count_idx = 0
    for i, cell in enumerate(cells, 1):
        cell_type = cell.get("cell_type", "unknown")
        source = cell.get("source", "")
        if isinstance(source, list):
            source = "".join(source)

        _open_tag("cell", index=i, cell_type=cell_type)
        print(f"\n---\n*Cell {i} \u2014 {cell_type}", end="")

        if cell_type == "code":
            # Show execution count if available
            exec_count = cell.get("execution_count")
            if exec_count is not None:
                print(f" [{exec_count}]", end="")
            print(":*")

            lang = kernel or "python"
            print(f"```{lang}")
            print(source, end="")
            if source and not source.endswith("\n"):
                print()
            print("```")

            # Render outputs
            outputs = cell.get("outputs", [])
            if outputs:
                rendered = _render_notebook_outputs(outputs, max_output, max_tb)
                for block in rendered:
                    print(block)

        elif cell_type == "markdown":
            print(":*")
            print()
            print(source, end="")
            if source and not source.endswith("\n"):
                print()

        elif cell_type == "raw":
            print(":*")
            print()
            print(source, end="")
            if source and not source.endswith("\n"):
                print()

        else:
            print(":*")
            print()
            print(source, end="")
            if source and not source.endswith("\n"):
                print()

        _close_tag("cell")


# ── Notebook Debug Rendering ─────────────────────────────────────────────────


_FRAME_RE_STANDARD = re.compile(
    r'File "([^"]+)", line (\d+)(?:, in (.+))?'
)
# IPython file frame: File path:line, in func(args)  (no quotes around path)
_FRAME_RE_IPYTHON_FILE = re.compile(
    r'File (\S+?):(\d+)(?:,\s*in\s+(\S+))?'
)
_FRAME_RE_IPYTHON = re.compile(
    r'(?:Cell |Input )\s*(?:In\s*\[?\s*(\d+)\]?),?\s*line\s*(\d+)'
)
_FRAME_RE_IPYTHON_FUNC = re.compile(
    r'(?:Cell |Input )\s*(?:In\s*\[?\s*(\d+)\]?),?\s*in\s+(\S+)'
)


def _parse_traceback_frames(traceback_lines):
    """Parse traceback lines into structured frame dicts.

    Returns list of {type, path, line, function} where type is initially None
    (to be classified later).
    """
    frames = []
    for raw_line in traceback_lines:
        # Strip ANSI codes
        line = re.sub(r'\x1b\[[0-9;]*m', '', str(raw_line))

        # Try standard Python frame: File "path", line N, in func
        m = _FRAME_RE_STANDARD.search(line)
        if m:
            frames.append({
                "path": m.group(1),
                "line": int(m.group(2)),
                "function": m.group(3) or "",
                "type": None,
            })
            continue

        # Try IPython file frame: File path:line, in func (no quotes)
        m = _FRAME_RE_IPYTHON_FILE.search(line)
        if m:
            func = m.group(3) or ""
            # Strip trailing parens from func name like "validate_input(value)"
            if "(" in func:
                func = func[:func.index("(")]
            frames.append({
                "path": m.group(1),
                "line": int(m.group(2)),
                "function": func,
                "type": None,
            })
            continue

        # Try IPython cell frame with function name
        m = _FRAME_RE_IPYTHON_FUNC.search(line)
        if m:
            frames.append({
                "path": f"Cell In[{m.group(1)}]",
                "line": 0,
                "function": m.group(2),
                "type": "notebook",
            })
            continue

        # Try IPython cell frame (line reference)
        m = _FRAME_RE_IPYTHON.search(line)
        if m:
            frames.append({
                "path": f"Cell In[{m.group(1)}]",
                "line": int(m.group(2)),
                "function": "",
                "type": "notebook",
            })
            continue

    return frames


def _classify_frame(frame, repo_root, tracked_files):
    """Classify a frame as notebook, repo, or external."""
    if frame["type"] == "notebook":
        return frame

    path = frame["path"]

    # Check if path is relative and in tracked files
    if path in tracked_files:
        frame["type"] = "repo"
        return frame

    # Check if absolute path resolves into repo
    if os.path.isabs(path):
        try:
            rel = os.path.relpath(path, repo_root)
            if not rel.startswith("..") and rel in tracked_files:
                frame["path"] = rel
                frame["type"] = "repo"
                return frame
        except ValueError:
            pass

    frame["type"] = "external"
    return frame


def _render_repo_frame_details(repo_frames, repo_root, all_tags):
    """Render enclosing function source for repo-local frames with >>> marker."""
    lines = []

    for frame in repo_frames:
        path = frame["path"]
        target_line = frame["line"]
        func_name = frame.get("function", "")

        abs_path = os.path.join(repo_root, path)
        if not os.path.isfile(abs_path):
            continue

        try:
            with open(abs_path) as f:
                source_lines = f.readlines()
        except (OSError, UnicodeDecodeError):
            continue

        # Find enclosing function from ctags
        containing = []
        for t in all_tags:
            if t.get("path") != path:
                continue
            start = t.get("line", 0)
            end = t.get("end")
            if end is None:
                continue
            if start <= target_line <= end:
                containing.append(t)

        if not containing:
            # Fallback: show a few lines around the error
            start = max(1, target_line - 2)
            end = min(len(source_lines), target_line + 2)
            sym_name = func_name or f"line {target_line}"
            lines.append(f"\n**`{path}:{target_line}`** (`{sym_name}`):")
            ext = os.path.splitext(path)[1]
            lang = _LANG_MAP.get(ext, "")
            lines.append(f"```{lang}")
            width = len(str(end))
            for i in range(start, end + 1):
                prefix = ">>>" if i == target_line else "   "
                lines.append(f"{prefix} {i:>{width}}: {source_lines[i - 1].rstrip()}")
            lines.append("```")
            continue

        # Pick innermost (smallest span) containing symbol
        containing.sort(key=lambda t: (t.get("end", 0) - t.get("line", 0)))
        best = containing[0]

        sym_name = best.get("name", func_name or "?")
        kind = best.get("kind", "?")
        start = best.get("line", 1)
        end = best.get("end", start)
        scope = best.get("scope", "")
        display_name = f"{scope}.{sym_name}" if scope else sym_name

        lines.append(f"\n**`{path}:{target_line}`** \u2192 `{display_name}` ({kind}, lines {start}-{end}):")

        ext = os.path.splitext(path)[1]
        lang = _LANG_MAP.get(ext, "")
        lines.append(f"```{lang}")
        width = len(str(end))
        for i in range(start, end + 1):
            prefix = ">>>" if i == target_line else "   "
            lines.append(f"{prefix} {i:>{width}}: {source_lines[i - 1].rstrip()}")
        lines.append("```")

        # Extract callees for context
        if ext == ".py":
            callees = _extract_python_calls(abs_path, source_lines, start, end, sym_name)
            if callees:
                unique_calls = sorted(set(callees))
                lines.append(f"Calls: {', '.join(f'`{c}`' for c in unique_calls)}")

    return lines


def _is_internal_module(module_name, rel_path, tracked_files):
    """Check if a module name maps to a tracked file in the repo."""
    # Convert dotted module to path candidates
    parts = module_name.split(".")
    candidates = [
        "/".join(parts) + ".py",
        "/".join(parts) + "/__init__.py",
    ]
    # Also try relative to the file's directory
    if rel_path:
        dir_path = os.path.dirname(rel_path)
        if dir_path:
            candidates.append(dir_path + "/" + "/".join(parts) + ".py")
            candidates.append(dir_path + "/" + "/".join(parts) + "/__init__.py")

    for candidate in candidates:
        if candidate in tracked_files:
            return True
    return False


def _render_dependency_trace(repo_frames, repo_root, tracked_files):
    """Render import analysis for files involved in the traceback."""
    lines = []
    seen_files = set()

    for frame in repo_frames:
        path = frame["path"]
        if path in seen_files:
            continue
        seen_files.add(path)

        abs_path = os.path.join(repo_root, path)
        if not os.path.isfile(abs_path) or not path.endswith(".py"):
            continue

        try:
            with open(abs_path) as f:
                source = f.read()
        except (OSError, UnicodeDecodeError):
            continue

        try:
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", SyntaxWarning)
                tree = ast.parse(source, filename=path)
        except SyntaxError:
            continue

        internal = []
        external = []

        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    mod = alias.name
                    if _is_internal_module(mod, path, tracked_files):
                        internal.append(mod)
                    else:
                        external.append(mod)
            elif isinstance(node, ast.ImportFrom):
                mod = node.module or ""
                if mod and _is_internal_module(mod, path, tracked_files):
                    internal.append(mod)
                elif mod:
                    external.append(mod)

        if internal or external:
            lines.append(f"\n**`{path}`**:")
            if internal:
                lines.append(f"- Internal: {', '.join(f'`{m}`' for m in sorted(set(internal)))}")
            if external:
                lines.append(f"- External: {', '.join(f'`{m}`' for m in sorted(set(external)))}")

    return lines


def _render_diagnostic_summary(cell_index, ename, evalue, frames, repo_frames, filepath):
    """Render bullet-point diagnostic summary with suggested commands."""
    lines = []

    notebook_frames = [f for f in frames if f["type"] == "notebook"]
    external_frames = [f for f in frames if f["type"] == "external"]

    lines.append(f"- **Error**: `{ename}: {evalue}`")
    lines.append(f"- **Cell**: {cell_index}")
    lines.append(f"- **Frames**: {len(frames)} total ({len(notebook_frames)} notebook, {len(repo_frames)} repo, {len(external_frames)} external)")

    if repo_frames:
        paths = sorted(set(f["path"] for f in repo_frames))
        lines.append(f"- **Repo files involved**: {', '.join(f'`{p}`' for p in paths)}")

    lines.append("")
    lines.append("**Suggested commands:**")
    for f in repo_frames:
        lines.append(f"- `rqs context {f['path']} {f['line']}` \u2014 enclosing function at error site")
    if repo_frames:
        paths = sorted(set(f["path"] for f in repo_frames))
        for p in paths:
            lines.append(f"- `rqs deps {p}` \u2014 dependency analysis")
        funcs = [f["function"] for f in repo_frames if f.get("function")]
        for fn in sorted(set(funcs)):
            lines.append(f"- `rqs callees {fn}` \u2014 what `{fn}` calls")

    return lines


def _render_debug_error(cell_index, cell, repo_root, tracked_files, all_tags, filepath):
    """Render all debug sections for one error cell."""
    lines = []
    source = cell.get("source", "")
    if isinstance(source, list):
        source = "".join(source)

    for out in cell.get("outputs", []):
        if out.get("output_type") != "error":
            continue

        ename = out.get("ename", "Error")
        evalue = out.get("evalue", "")
        traceback_raw = out.get("traceback", [])

        # ── 1. Error Summary ──
        lines.append(f"### Error: `{ename}: {evalue}`")
        lines.append(f"*Cell {cell_index}:*")
        lines.append("```python")
        lines.append(source.rstrip())
        lines.append("```")

        # ── 2. Traceback Frames ──
        frames = _parse_traceback_frames(traceback_raw)
        for f in frames:
            _classify_frame(f, repo_root, tracked_files)

        if frames:
            lines.append("\n**Traceback Frames:**")
            lines.append("| # | Location | Line | Function | Type |")
            lines.append("|---|----------|------|----------|------|")
            for i, f in enumerate(frames, 1):
                ftype = f["type"]
                label = {"notebook": "notebook-local", "repo": "repo-local", "external": "external"}.get(ftype, ftype)
                lines.append(f"| {i} | `{f['path']}` | {f['line']} | `{f['function']}`  | {label} |")

        # ── 3. Repo Code in Traceback ──
        repo_frames = [f for f in frames if f["type"] == "repo"]
        if repo_frames and all_tags is not None:
            lines.append("\n**Repo Code in Traceback:**")
            lines.extend(_render_repo_frame_details(repo_frames, repo_root, all_tags))

        # ── 4. Dependency Trace ──
        if repo_frames:
            dep_lines = _render_dependency_trace(repo_frames, repo_root, tracked_files)
            lines.append("\n**Dependency Trace:**")
            if dep_lines:
                lines.extend(dep_lines)
            else:
                lines.append("*(no imports in traced files)*")

        # ── 5. Diagnostic Summary ──
        lines.append("\n**Diagnostic Summary:**")
        lines.extend(_render_diagnostic_summary(cell_index, ename, evalue, frames, repo_frames, filepath))

    return lines


def _render_notebook_debug_no_errors(cells, filepath):
    """Render 'no errors found' summary."""
    code_cells = [c for c in cells if c.get("cell_type") == "code"]
    executed = [c for c in code_cells if c.get("execution_count") is not None]
    print(f"## Notebook Debug: `{filepath}`")
    print(f"> No errors found. {len(code_cells)} code cells ({len(executed)} executed).")


def render_notebook_debug(args):
    """Render notebook error analysis with traceback cross-referencing."""
    filepath = args[0] if args else "?"
    repo_root = os.environ.get("RQS_TARGET_REPO", ".")

    abs_path = os.path.join(repo_root, filepath)
    try:
        with open(abs_path) as f:
            nb = json.load(f)
    except (OSError, json.JSONDecodeError) as e:
        print(f"*(error reading notebook: {e})*")
        return

    cells = nb.get("cells", [])

    # Find error cells
    error_cells = []
    for i, cell in enumerate(cells, 1):
        if cell.get("cell_type") != "code":
            continue
        for out in cell.get("outputs", []):
            if out.get("output_type") == "error":
                error_cells.append((i, cell))
                break

    if not error_cells:
        _render_notebook_debug_no_errors(cells, filepath)
        return

    # Load ctags cache if available
    all_tags = None
    ctags_cache = os.environ.get("RQS_CTAGS_CACHE", "")
    if ctags_cache and os.path.isfile(ctags_cache):
        try:
            with open(ctags_cache) as f:
                all_tags = parse_ctags_json(f.readlines())
        except OSError:
            pass

    # Get tracked files
    tracked_files = set()
    try:
        result = subprocess.run(
            ["git", "ls-files"],
            cwd=repo_root, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            tracked_files = set(line.strip() for line in result.stdout.split("\n") if line.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass

    # Render header
    error_count = len(error_cells)
    error_names = [out.get("ename", "Error")
                   for _, cell in error_cells
                   for out in cell.get("outputs", [])
                   if out.get("output_type") == "error"]
    print(f"## Notebook Debug: `{filepath}`")
    print(f"> {error_count} errors found: {', '.join(error_names)}")

    # Render each error
    for cell_index, cell in error_cells:
        output_lines = _render_debug_error(
            cell_index, cell, repo_root, tracked_files, all_tags, filepath
        )
        print()
        print("\n".join(output_lines))


# ── Churn Rendering ──────────────────────────────────────────────────────────


SHADES = " \u2591\u2592\u2593\u2588"


def _parse_churn_log(content):
    """Parse git log --pretty=format:COMMIT --numstat into chronological commit list.

    Returns a list of commits (oldest first), where each commit is a list of
    (filename, changes) tuples.
    """
    commits = []
    current = []
    for line in content.splitlines():
        if line == "COMMIT":
            if current:
                commits.append(current)
            current = []
        elif line.strip():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[0] != "-":
                try:
                    changes = int(parts[0]) + int(parts[1])
                    current.append((parts[2], changes))
                except ValueError:
                    pass
    if current:
        commits.append(current)
    commits.reverse()  # git log is newest-first; we want chronological
    return commits


def _auto_churn_bucket_size(commit_count):
    """Choose commits-per-bucket to target ~50 buckets (prefer 30-60 when possible)."""
    if commit_count <= 0:
        return 1
    # For shorter histories, show per-commit resolution.
    if commit_count <= 60:
        return 1

    # Start with a ~50-bucket target, then clamp to 30-60 bucket window.
    bucket_size = max(1, round(commit_count / 50))
    num_buckets = math.ceil(commit_count / bucket_size)
    if num_buckets > 60:
        bucket_size = max(1, math.ceil(commit_count / 60))
    elif num_buckets < 30:
        bucket_size = max(1, math.floor(commit_count / 30))
    return bucket_size


def render_churn(args):
    """Render file modification heatmap from git log --numstat output."""
    top_n = 20
    bucket_size = None
    bucket_auto = True
    i = 0
    while i < len(args):
        if args[i] == "--top":
            top_n = int(args[i + 1])
            i += 2
        elif args[i] == "--bucket":
            raw_bucket = args[i + 1].strip().lower()
            if raw_bucket in {"", "auto"}:
                bucket_size = None
                bucket_auto = True
            else:
                parsed_bucket = int(raw_bucket)
                if parsed_bucket <= 0:
                    raise ValueError("bucket size must be positive")
                bucket_size = parsed_bucket
                bucket_auto = False
            i += 2
        else:
            i += 1

    content = sys.stdin.read()
    commits = _parse_churn_log(content)
    if not commits:
        print("*(no commit history found)*")
        return

    if bucket_size is None:
        bucket_size = _auto_churn_bucket_size(len(commits))
        bucket_auto = True

    num_buckets = math.ceil(len(commits) / bucket_size)

    # Aggregate per-file stats
    file_buckets = defaultdict(lambda: [0] * num_buckets)
    file_commits = Counter()
    file_total = Counter()

    for ci, commit_files in enumerate(commits):
        bucket_idx = ci // bucket_size
        for filename, changes in commit_files:
            file_buckets[filename][bucket_idx] += changes
            file_commits[filename] += 1
            file_total[filename] += changes

    # Top N by total changes
    sorted_files = sorted(file_buckets.keys(),
                          key=lambda f: file_total[f], reverse=True)[:top_n]

    # Global max for shade normalization
    global_max = max(
        (file_buckets[f][b] for f in sorted_files for b in range(num_buckets)),
        default=1,
    ) or 1

    # Pre-compute column widths for alignment
    max_file_w = max((len(f) + 2 for f in sorted_files), default=4)  # +2 for backticks
    max_commits_w = max((len(str(file_commits[f])) for f in sorted_files), default=1)
    max_total_w = max((len(str(file_total[f])) for f in sorted_files), default=1)
    max_file_w = max(max_file_w, 4)  # at least "File"
    max_commits_w = max(max_commits_w, 7)  # at least "Commits"
    max_total_w = max(max_total_w, 5)  # at least "Lines"

    # Render
    print("## Churn")
    print(f"> {len(commits)} commits, {len(file_buckets)} files touched. "
          f"Commits = number of commits that modified the file. "
          f"Lines = total lines added + deleted. "
          f"History = per-file activity binned into {num_buckets} buckets "
          f"of {bucket_size} commits each (oldest \u2192 newest)"
          f"{' [auto-sized]' if bucket_auto else ''}, "
          f"shaded by lines changed relative to the global max.")
    print()
    max_history_w = max(num_buckets + 2, 7)  # bar + backticks, at least "History"
    print(f"| {'Commits':>{max_commits_w}} | {'Lines':>{max_total_w}} | {'History':<{max_history_w}} | {'File':<{max_file_w}} |")
    print(f"|{'-' * (max_commits_w + 2)}|{'-' * (max_total_w + 2)}|{'-' * (max_history_w + 2)}|{'-' * (max_file_w + 2)}|")
    for f in sorted_files:
        bar = ""
        for val in file_buckets[f]:
            if val == 0:
                bar += SHADES[0]
            else:
                idx = min(len(SHADES) - 1,
                          int((val / global_max) * (len(SHADES) - 2)) + 1)
                bar += SHADES[idx]
        history_col = f"`{bar}`".ljust(max_history_w)
        file_col = f"`{f}`".ljust(max_file_w)
        commits_col = str(file_commits[f]).rjust(max_commits_w)
        total_col = str(file_total[f]).rjust(max_total_w)
        print(f"| {commits_col} | {total_col} | {history_col} | {file_col} |")


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
    "show": render_show,
    "context": render_context,
    "diff": render_diff,
    "files": render_files,
    "callees": render_callees,
    "related": render_related,
    "notebook": render_notebook,
    "notebook-debug": render_notebook_debug,
    "churn": render_churn,
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

    _open_tag(mode)
    try:
        MODES[mode](args)
    finally:
        _close_tag(mode)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # Downstream consumer closed the pipe early (for example, `| head`).
        # Exit quietly instead of emitting a traceback.
        sys.exit(0)
