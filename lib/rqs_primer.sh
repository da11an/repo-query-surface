#!/usr/bin/env bash
# rqs_primer.sh — generate tiered static primer

cmd_primer() {
    local tree_depth="$RQS_PRIMER_TREE_DEPTH"
    local max_symbols="$RQS_PRIMER_MAX_SYMBOLS"
    local level="medium"
    local task=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tree-depth) tree_depth="$2"; shift 2 ;;
            --max-symbols) max_symbols="$2"; shift 2 ;;
            --light) level="light"; shift ;;
            --medium) level="medium"; shift ;;
            --heavy) level="heavy"; shift ;;
            --task) task="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs primer [--light|--medium|--heavy] [--task TASK] [--tree-depth N] [--max-symbols N]

Generate a tiered static primer for the repository.

Tiers:
  --light    Quick orientation: prompt + header + fast-start map + boundaries + tree
  --medium   Standard (default): light + test contract + critical path + symbols + module summaries
  --heavy    Full sketch: medium + signatures + dependency wiring + heuristic hotspots

Options:
  --task TASK        Include task-specific framing (debug, feature, review, explain)
  --tree-depth N     Maximum tree depth (default: from config)
  --max-symbols N    Maximum symbols to include (default: from config)
  --help             Show this help
EOF
                return 0
                ;;
            -*) rqs_error "primer: unknown option '$1'" ;;
            *) shift ;;
        esac
    done

    # ── Source dependencies ──
    source "$RQS_LIB_DIR/rqs_prompt.sh"

    # ── Prompt orientation (all tiers) ──
    if [[ -n "$task" ]]; then
        cmd_prompt "$task"
    else
        cmd_prompt
    fi
    echo ""

    echo "<repository_primer>"

    local repo_name
    repo_name=$(basename "$(readlink -f "$RQS_TARGET_REPO")")

    # ── Header (all tiers) ──
    echo "# Repository Primer: \`${repo_name}\`"
    echo ""

    # Include README summary if available
    primer_readme_summary

    # ── Deterministic onboarding context (all tiers, depth varies by level) ──
    primer_strategy_context "$level"
    echo ""

    # ── Tree (all tiers) ──
    echo ""
    rqs_list_files | rqs_render tree --depth "$tree_depth" --root "."
    echo ""

    # ── Medium and heavy ──
    if [[ "$level" == "medium" || "$level" == "heavy" ]]; then
        # ── Symbol Index ──
        primer_symbol_index "$max_symbols"
        echo ""

        # ── Module Summaries ──
        primer_module_summaries
        echo ""
    fi

    # ── Heavy only ──
    if [[ "$level" == "heavy" ]]; then
        # ── Signatures (whole repo) ──
        source "$RQS_LIB_DIR/rqs_signatures.sh"
        cmd_signatures
        echo ""

        # ── Dependency Wiring ──
        primer_dependency_wiring
        echo ""
    fi

    echo "</repository_primer>"
}

primer_strategy_context() {
    local level="$1"
    python3 "$RQS_LIB_DIR/primer_insights.py" --repo "$RQS_TARGET_REPO" --level "$level"
}

primer_readme_summary() {
    local readme="$RQS_TARGET_REPO/README.md"
    if [[ ! -f "$readme" ]]; then
        return
    fi

    # Extract first paragraph (up to first blank line or heading after first line)
    local summary
    summary=$(awk '
        NR == 1 { next }
        /^$/ && found { exit }
        /^#/ && found { exit }
        /^[^#]/ && !/^$/ { found=1; print }
        /^$/ && !found { next }
    ' "$readme" | head -5)

    if [[ -n "$summary" ]]; then
        echo "$summary"
        echo ""
    fi
}

primer_symbol_index() {
    local max_symbols="$1"

    if rqs_has_ctags; then
        local tags_data
	tags_data=$(rqs_list_files | while IFS= read -r f; do
	    (cd "$RQS_TARGET_REPO" && ctags $(rqs_ctags_args) -f - "$f" 2>/dev/null)
        done | head -n "$max_symbols") || true

        if [[ -n "$tags_data" ]]; then
            echo "$tags_data" | rqs_render symbols --kinds "$RQS_SYMBOL_KINDS"
        else
            echo "*(no symbols found)*"
        fi
    else
        echo "## Symbols"
        echo "*(ctags not available — install universal-ctags for symbol indexing)*"
    fi
}

primer_module_summaries() {
    # Generate directory-level summaries
    local file_list
    file_list=$(rqs_list_files)

    if [[ -z "$file_list" ]]; then
        return
    fi

    # Build JSON summaries via Python
    echo "$file_list" | python3 -c "
import json, sys, os, re
from collections import defaultdict

repo_root = os.environ.get('RQS_TARGET_REPO', '.')

files = [line.strip() for line in sys.stdin if line.strip()]
if not files:
    sys.exit(0)

# Group files by top-level directory
dirs = defaultdict(lambda: {'files': 0, 'types': defaultdict(int)})
dir_symbols = defaultdict(list)

for f in files:
    parts = f.split('/')
    if len(parts) == 1:
        dir_name = '.'
    else:
        dir_name = parts[0]

    dirs[dir_name]['files'] += 1
    ext = os.path.splitext(f)[1]
    if ext:
        dirs[dir_name]['types'][ext] += 1

    # Scan for top-level symbols
    filepath = os.path.join(repo_root, f)
    try:
        with open(filepath) as fh:
            for line in fh:
                m = re.match(r'^(?:class|def|function|struct|interface|type|enum)\s+(\w+)', line)
                if m:
                    sym = m.group(1)
                    if sym not in dir_symbols[dir_name]:
                        dir_symbols[dir_name].append(sym)
    except (OSError, UnicodeDecodeError):
        pass

summaries = []
for dir_name in sorted(dirs.keys()):
    info = dirs[dir_name]
    entry = {
        'path': dir_name,
        'files': info['files'],
        'types': dict(info['types']),
        'description': '',
        'symbols': dir_symbols.get(dir_name, [])
    }
    summaries.append(entry)

print(json.dumps(summaries))
" | rqs_render summaries
}

primer_dependency_wiring() {
    echo "## Internal Dependencies"
    echo ""

    local max_all="${RQS_PRIMER_DEPS_MAX_ALL:-50}"
    local top_n="${RQS_PRIMER_DEPS_TOP_N:-50}"
    local py_files
    py_files=$(rqs_list_files | grep '\.py$' || true)

    if [[ -z "$py_files" ]]; then
        # Try other languages
        local all_files
        all_files=$(rqs_list_files)

        if [[ -n "$all_files" ]]; then
            local rows=""
            while IFS= read -r f; do
                local ext="${f##*.}"
                local abs="$RQS_TARGET_REPO/$f"
                [[ ! -f "$abs" ]] && continue

                # Check for shell source statements
                if [[ "$ext" == "sh" || "$ext" == "bash" ]]; then
                    local sources
                    sources=$(grep -oP '(?:^|\s)(?:\.|source)\s+['"'"'"]*([a-zA-Z0-9_./-]+)' "$abs" 2>/dev/null | \
                        sed -E 's/.*\s//' | sort -u || true)
                    if [[ -n "$sources" ]]; then
                        local deps_list
                        deps_list=$(echo "$sources" | tr '\n' ', ' | sed 's/,$//')
                        rows="${rows}| \`$f\` | $deps_list |\n"
                    fi
                fi
            done <<< "$all_files"

            if [[ -z "$rows" ]]; then
                echo "*(no internal dependencies detected)*"
            else
                echo "| File | Imports |"
                echo "|------|---------|"
                printf '%b' "$rows"
            fi
        else
            echo "*(no files to analyze)*"
        fi
        return
    fi

    # Python dependency graph (aggregated and ranked)
    python3 - "$RQS_TARGET_REPO" "$max_all" "$top_n" 3<<<"$py_files" <<'PY'
import ast
import os
import sys
from collections import Counter, defaultdict

repo_root = sys.argv[1]
try:
    max_all = max(1, int(sys.argv[2]))
except ValueError:
    max_all = 50
try:
    top_n = max(1, int(sys.argv[3]))
except ValueError:
    top_n = 50

with os.fdopen(3) as py_stream:
    py_files = [line.strip() for line in py_stream if line.strip()]
if not py_files:
    print("*(no Python files to analyze)*")
    sys.exit(0)

py_set = set(py_files)

# Detect likely source roots to support src/ layouts.
source_roots = {""}
for path in py_files:
    parts = path.split("/")
    if len(parts) > 1:
        source_roots.add(parts[0])

# Directory paths containing Python modules (supports namespace packages).
py_dirs = set()
for path in py_files:
    d = os.path.dirname(path)
    while d and d != ".":
        py_dirs.add(d)
        d = os.path.dirname(d)


def module_to_rel(module):
    return module.replace(".", "/")


def is_internal_module(module):
    if not module:
        return False
    rel = module_to_rel(module)
    candidates = set()
    for root in source_roots:
        prefix = f"{root}/" if root else ""
        candidates.add(f"{prefix}{rel}.py")
        candidates.add(f"{prefix}{rel}/__init__.py")
    if any(candidate in py_set for candidate in candidates):
        return True
    # Namespace package (directory with Python files below it).
    for root in source_roots:
        prefix = f"{root}/" if root else ""
        if f"{prefix}{rel}" in py_dirs:
            return True
    return False


def path_to_module(path):
    if not path.endswith(".py"):
        return ""
    no_ext = path[:-3]
    if no_ext.endswith("/__init__"):
        no_ext = no_ext[: -len("/__init__")]
    return no_ext.replace("/", ".")


def current_package(path):
    module = path_to_module(path)
    if not module:
        return ""
    if path.endswith("/__init__.py"):
        return module
    if "." in module:
        return module.rsplit(".", 1)[0]
    return ""


def resolve_relative_import(pkg, level, module):
    parts = pkg.split(".") if pkg else []
    if level > 0:
        pop_count = level - 1
        if pop_count > 0:
            parts = parts[:-pop_count] if pop_count < len(parts) else []
    if module:
        parts += module.split(".")
    return ".".join(p for p in parts if p)


counts = Counter()
importers = defaultdict(set)

for rel_path in sorted(py_set):
    abs_path = os.path.join(repo_root, rel_path)
    try:
        with open(abs_path, encoding="utf-8") as fh:
            tree = ast.parse(fh.read(), filename=rel_path)
    except (OSError, UnicodeDecodeError, SyntaxError):
        continue

    pkg = current_package(rel_path)
    seen_edges = set()

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mod = alias.name
                if is_internal_module(mod):
                    seen_edges.add(mod)
        elif isinstance(node, ast.ImportFrom):
            base = ""
            if node.level > 0:
                base = resolve_relative_import(pkg, node.level, node.module)
                if base and is_internal_module(base):
                    seen_edges.add(base)
            elif node.module:
                base = node.module
                if is_internal_module(base):
                    seen_edges.add(base)

            # Handle "from X import Y" where Y may be a submodule.
            if base:
                for alias in node.names:
                    if alias.name == "*":
                        continue
                    candidate = f"{base}.{alias.name}"
                    if is_internal_module(candidate):
                        seen_edges.add(candidate)

    for mod in seen_edges:
        counts[mod] += 1
        importers[mod].add(rel_path)

if not counts:
    print("*(no internal dependencies detected)*")
    sys.exit(0)

ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
unique_modules = len(ranked)
total_edges = sum(counts.values())

if unique_modules <= max_all:
    shown = ranked
    print(
        f"> Internal Python imports: {unique_modules} modules, {total_edges} import edges. "
        f"Showing all modules (<= {max_all})."
    )
else:
    shown = ranked[:top_n]
    print(
        f"> Internal Python imports: {unique_modules} modules, {total_edges} import edges. "
        f"Showing top {len(shown)} modules by import count."
    )

print("")
print("| Internal Module | Import Count | Imported By Files |")
print("|-----------------|--------------|-------------------|")
for module, count in shown:
    print(f"| `{module}` | {count} | {len(importers[module])} |")
PY
}
