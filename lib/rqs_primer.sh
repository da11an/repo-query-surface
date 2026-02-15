#!/usr/bin/env bash
# rqs_primer.sh — generate static primer

cmd_primer() {
    local tree_depth="$RQS_PRIMER_TREE_DEPTH"
    local max_symbols="$RQS_PRIMER_MAX_SYMBOLS"
    local task=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tree-depth) tree_depth="$2"; shift 2 ;;
            --max-symbols) max_symbols="$2"; shift 2 ;;
            --task) task="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs primer [--task TASK] [--tree-depth N] [--max-symbols N]

Generate a static primer for the repository.

Includes: prompt orientation, onboarding context, churn heatmap,
churn-informed budgeted tree, module summaries, symbol map,
dependency wiring, and heuristic risk hotspots.

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

    # ── Prompt orientation ──
    if [[ -n "$task" ]]; then
        cmd_prompt "$task"
    else
        cmd_prompt
    fi
    echo ""

    echo "<repository_primer>"

    local repo_name
    repo_name=$(basename "$(readlink -f "$RQS_TARGET_REPO")")

    # ── Header ──
    echo "# Repository Primer: \`${repo_name}\`"
    echo ""

    # Include README summary if available
    primer_readme_summary

    # ── Deterministic onboarding context ──
    primer_strategy_context "heavy"
    echo ""

    # ── File Churn (orientation first) ──
    source "$RQS_LIB_DIR/rqs_churn.sh"
    cmd_churn --top "$RQS_CHURN_TOP_N" --bucket "$RQS_CHURN_BUCKET"
    echo ""

    # ── Churn summary for tree importance scoring ──
    local churn_tmp
    churn_tmp=$(mktemp)
    (cd "$RQS_TARGET_REPO" && git log --pretty=format:COMMIT%x09%an --numstat 2>&1) \
        | rqs_render churn-summary > "$churn_tmp"

    # ── Tree (churn-informed, budgeted) ──
    rqs_list_files | rqs_render tree --depth "$tree_depth" --root "." \
        --budget "${RQS_PRIMER_TREE_BUDGET:-50}" --churn-data "$churn_tmp"
    echo ""

    # ── Module Summaries ──
    primer_module_summaries
    echo ""

    # ── Symbol Map (signatures with line spans, budgeted) ──
    source "$RQS_LIB_DIR/rqs_signatures.sh"
    rqs_list_files | grep -v '^tests/fixtures/' | rqs_render signatures --with-line-spans \
        --budget "${RQS_PRIMER_MAX_SYMBOLS:-500}" --churn-data "$churn_tmp"
    echo ""
    rm -f "$churn_tmp"

    # ── Dependency Wiring ──
    primer_dependency_wiring
    echo ""

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
            local -a dep_files=()
            local -a dep_imports=()
            local max_file_w=4
            local max_imports_w=7
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
                        local file_cell
                        file_cell="\`$f\`"
                        deps_list=$(echo "$sources" | tr '\n' ', ' | sed 's/,$//')
                        dep_files+=("$file_cell")
                        dep_imports+=("$deps_list")
                        (( ${#file_cell} > max_file_w )) && max_file_w=${#file_cell}
                        (( ${#deps_list} > max_imports_w )) && max_imports_w=${#deps_list}
                    fi
                fi
            done <<< "$all_files"

            if [[ ${#dep_files[@]} -eq 0 ]]; then
                echo "*(no internal dependencies detected)*"
            else
                printf "| %-*s | %-*s |\n" "$max_file_w" "File" "$max_imports_w" "Imports"
                printf "|-%s-|-%s-|\n" \
                    "$(printf '%*s' "$max_file_w" '' | tr ' ' '-')" \
                    "$(printf '%*s' "$max_imports_w" '' | tr ' ' '-')"
                local i
                for i in "${!dep_files[@]}"; do
                    printf "| %-*s | %-*s |\n" \
                        "$max_file_w" "${dep_files[$i]}" \
                        "$max_imports_w" "${dep_imports[$i]}"
                done
            fi
        else
            echo "*(no files to analyze)*"
        fi
        return
    fi

    # Python dependency graph (aggregated/ranked + topology)
    python3 - "$RQS_TARGET_REPO" "$max_all" "$top_n" 3<<<"$py_files" <<'PY'
import ast
import os
import sys
from collections import Counter, defaultdict, deque

repo_root = sys.argv[1]
try:
    max_all = max(1, int(sys.argv[2]))
except ValueError:
    max_all = 50
try:
    top_n = max(1, int(sys.argv[3]))
except ValueError:
    top_n = 50


def render_table(headers, rows, right_align=None, pad_header=True):
    if right_align is None:
        right_align = set()

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))

    def _cell(i, value):
        text = str(value)
        return text.rjust(widths[i]) if i in right_align else text.ljust(widths[i])

    if pad_header:
        header_cells = [_cell(i, h) for i, h in enumerate(headers)]
    else:
        header_cells = [str(h) for h in headers]
    header_row = "| " + " | ".join(header_cells) + " |"
    sep_row = "|-" + "-|-".join("-" * w for w in widths) + "-|"
    print(header_row)
    print(sep_row)
    for row in rows:
        print("| " + " | ".join(_cell(i, c) for i, c in enumerate(row)) + " |")


with os.fdopen(3) as py_stream:
    py_files = [line.strip() for line in py_stream if line.strip()]
if not py_files:
    print("*(no Python files to analyze)*")
    sys.exit(0)

py_set = set(py_files)
adj = {p: set() for p in py_set}
rev_adj = {p: set() for p in py_set}

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


def resolve_module_to_file(module):
    if not module:
        return None
    rel = module_to_rel(module)
    for root in source_roots:
        prefix = f"{root}/" if root else ""
        py_candidate = f"{prefix}{rel}.py"
        init_candidate = f"{prefix}{rel}/__init__.py"
        if py_candidate in py_set:
            return py_candidate
        if init_candidate in py_set:
            return init_candidate
    return None


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
    seen_modules = set()

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mod = alias.name
                if is_internal_module(mod):
                    seen_modules.add(mod)
        elif isinstance(node, ast.ImportFrom):
            base = ""
            if node.level > 0:
                base = resolve_relative_import(pkg, node.level, node.module)
                if base and is_internal_module(base):
                    seen_modules.add(base)
            elif node.module:
                base = node.module
                if is_internal_module(base):
                    seen_modules.add(base)

            # Handle "from X import Y" where Y may be a submodule.
            if node.level > 0 and node.module is None:
                # Handle "from . import foo, bar" style imports.
                for alias in node.names:
                    if alias.name == "*":
                        continue
                    candidate = f"{base}.{alias.name}" if base else alias.name
                    if is_internal_module(candidate):
                        seen_modules.add(candidate)
            elif base:
                for alias in node.names:
                    if alias.name == "*":
                        continue
                    candidate = f"{base}.{alias.name}"
                    if is_internal_module(candidate):
                        seen_modules.add(candidate)

    for mod in seen_modules:
        counts[mod] += 1
        importers[mod].add(rel_path)
        target_file = resolve_module_to_file(mod)
        if target_file and target_file != rel_path:
            adj[rel_path].add(target_file)
            rev_adj[target_file].add(rel_path)

if not counts:
    print("*(no internal dependencies detected)*")
    sys.exit(0)

ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
unique_modules = len(ranked)
total_edges = sum(counts.values())

edge_count = sum(len(v) for v in adj.values())

# Only show flat module table when there's no topology to display
if edge_count == 0:
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
    dep_rows = [
        (f"`{module}`", count, len(importers[module]))
        for module, count in shown
    ]
    render_table(
        ["Internal Module", "Import Count", "Imported By Files"],
        dep_rows,
        right_align={1, 2},
    )
if edge_count == 0:
    print("")
    print("## Import Topology")
    print("")
    print("*(no internal file-to-file import edges detected)*")
    sys.exit(0)


def topological_sort(nodes, graph):
    indeg = {n: 0 for n in nodes}
    for n in nodes:
        for m in graph[n]:
            indeg[m] += 1
    q = deque(sorted(n for n in nodes if indeg[n] == 0))
    out = []
    while q:
        n = q.popleft()
        out.append(n)
        for m in sorted(graph[n]):
            indeg[m] -= 1
            if indeg[m] == 0:
                q.append(m)
    return out


def tarjan_scc(nodes, graph):
    sys.setrecursionlimit(max(2000, len(nodes) * 4))
    index = 0
    indices = {}
    lowlink = {}
    stack = []
    on_stack = set()
    components = []

    def strongconnect(v):
        nonlocal index
        indices[v] = index
        lowlink[v] = index
        index += 1
        stack.append(v)
        on_stack.add(v)

        for w in graph[v]:
            if w not in indices:
                strongconnect(w)
                lowlink[v] = min(lowlink[v], lowlink[w])
            elif w in on_stack:
                lowlink[v] = min(lowlink[v], indices[w])

        if lowlink[v] == indices[v]:
            comp = []
            while True:
                w = stack.pop()
                on_stack.remove(w)
                comp.append(w)
                if w == v:
                    break
            components.append(comp)

    for n in nodes:
        if n not in indices:
            strongconnect(n)
    return components


def brandes_betweenness(nodes, graph, max_sources=120):
    ordered = sorted(nodes)
    if not ordered:
        return {}, False, 0

    approx = False
    if len(ordered) > max_sources:
        step = max(1, len(ordered) // max_sources)
        sources = ordered[::step][:max_sources]
        approx = True
    else:
        sources = ordered

    scale = len(ordered) / len(sources)
    bc = {n: 0.0 for n in ordered}

    for s in sources:
        stack = []
        pred = defaultdict(list)
        sigma = defaultdict(float)
        sigma[s] = 1.0
        dist = {s: 0}
        q = deque([s])

        while q:
            v = q.popleft()
            stack.append(v)
            for w in graph[v]:
                if w not in dist:
                    dist[w] = dist[v] + 1
                    q.append(w)
                if dist[w] == dist[v] + 1:
                    sigma[w] += sigma[v]
                    pred[w].append(v)

        delta = defaultdict(float)
        while stack:
            w = stack.pop()
            for v in pred[w]:
                if sigma[w] > 0:
                    delta[v] += (sigma[v] / sigma[w]) * (1.0 + delta[w])
            if w != s:
                bc[w] += delta[w]

    for n in bc:
        bc[n] *= scale
    return bc, approx, len(sources)


nodes = sorted(py_set)
sccs = tarjan_scc(nodes, adj)
node_to_comp = {}
for i, comp in enumerate(sccs):
    for n in comp:
        node_to_comp[n] = i

comp_adj = {i: set() for i in range(len(sccs))}
for src in nodes:
    c_src = node_to_comp[src]
    for dst in adj[src]:
        c_dst = node_to_comp[dst]
        if c_src != c_dst:
            comp_adj[c_src].add(c_dst)

comp_order = topological_sort(sorted(comp_adj.keys()), comp_adj)
comp_layer = {}
for c in reversed(comp_order):
    if not comp_adj[c]:
        comp_layer[c] = 0
    else:
        comp_layer[c] = 1 + max(comp_layer[n] for n in comp_adj[c])

file_layer = {n: comp_layer[node_to_comp[n]] for n in nodes}
max_layer = max(file_layer.values()) if file_layer else 0

fan_in = {n: len(rev_adj[n]) for n in nodes}
fan_out = {n: len(adj[n]) for n in nodes}
betweenness, bc_approx, bc_sources = brandes_betweenness(nodes, adj)

cyclic_components = [c for c in sccs if len(c) > 1]
largest_scc = max((len(c) for c in sccs), default=0)

print("")
print("## Import Topology")
print(
    f"> Directed internal file graph: {len(nodes)} Python files, {edge_count} edges, "
    f"{len(sccs)} SCCs, max dependency depth {max_layer}."
)
if largest_scc > 1:
    print(
        f"> Circular imports detected: {len(cyclic_components)} SCCs with cycles "
        f"(largest size {largest_scc})."
    )
else:
    print("> No circular imports detected (all SCCs are size 1).")

top_k = 10

# Unified key files table: rank by combined hub + bridge importance
key_files_scored = sorted(
    nodes,
    key=lambda n: (-(fan_in[n] + fan_out[n] + betweenness[n]), n),
)[:top_k]

print("")
print("### Key Files")
if bc_approx:
    print(
        f"> Betweenness centrality is approximated from {bc_sources} sampled source files."
    )
key_file_rows = [
    (f"`{f}`", fan_in[f], fan_out[f], f"{betweenness[f]:.2f}", file_layer[f])
    for f in key_files_scored
]
render_table(
    ["File", "Fan-In", "Fan-Out", "Betweenness", "Layer"],
    key_file_rows,
    right_align={1, 2, 3, 4},
)

print("")
print("### Layer Map (Foundation -> Orchestration)")
layers = defaultdict(list)
for f in nodes:
    layers[file_layer[f]].append(f)

shown_layers = sorted(layers.keys())
max_layers_to_show = 8
omitted = 0
if len(shown_layers) > max_layers_to_show:
    omitted = len(shown_layers) - max_layers_to_show
    shown_layers = shown_layers[: max_layers_to_show - 1] + [shown_layers[-1]]

files_per_layer = 8
for layer in shown_layers:
    entries = sorted(layers[layer], key=lambda n: (-fan_in[n], n))
    preview = entries[:files_per_layer]
    preview_text = ", ".join(f"`{p}`" for p in preview)
    if len(entries) > files_per_layer:
        preview_text += f", ... (+{len(entries) - files_per_layer} more)"
    label = "foundations" if layer == 0 else f"layer {layer}"
    print(f"- L{layer} ({label}): {preview_text}")
if omitted > 0:
    print(f"- ... {omitted} middle layers omitted for brevity")

print("")
print("### Key Dependency Links")
edge_rows = []
for src in nodes:
    for dst in adj[src]:
        layer_drop = file_layer[src] - file_layer[dst]
        score = (fan_out[src] + 1) * (fan_in[dst] + 1) * (max(layer_drop, 0) + 1)
        edge_rows.append((score, src, dst, layer_drop))

link_rows = []
for score, src, dst, layer_drop in sorted(
    edge_rows, key=lambda item: (-item[0], item[1], item[2])
)[:12]:
    link_rows.append((f"`{src}`", f"`{dst}`", layer_drop, score))

render_table(
    ["Importer", "Imported", "Layer Drop", "Score"],
    link_rows,
    right_align={2, 3},
    pad_header=False,
)
PY
}
