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
  --light    Quick orientation: prompt + header + tree
  --medium   Standard (default): light + symbols + module summaries
  --heavy    Full sketch: medium + signatures + dependency wiring

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

    local repo_name
    repo_name=$(basename "$(readlink -f "$RQS_TARGET_REPO")")

    # ── Header (all tiers) ──
    echo "# Repository Primer: \`${repo_name}\`"
    echo ""

    # Include README summary if available
    primer_readme_summary

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
            (cd "$RQS_TARGET_REPO" && ctags --output-format=json --fields=+nKSse -f - "$f" 2>/dev/null)
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
import json, sys, os
from collections import defaultdict

files = [line.strip() for line in sys.stdin if line.strip()]
if not files:
    sys.exit(0)

# Group files by top-level directory
dirs = defaultdict(lambda: {'files': 0, 'types': defaultdict(int)})

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

summaries = []
for dir_name in sorted(dirs.keys()):
    info = dirs[dir_name]
    entry = {
        'path': dir_name,
        'files': info['files'],
        'types': dict(info['types']),
        'description': ''
    }
    summaries.append(entry)

print(json.dumps(summaries))
" | rqs_render summaries
}

primer_dependency_wiring() {
    echo "## Internal Dependencies"
    echo ""

    local py_files
    py_files=$(rqs_list_files | grep '\.py$' || true)

    if [[ -z "$py_files" ]]; then
        # Try other languages
        local has_deps=false
        local all_files
        all_files=$(rqs_list_files)

        if [[ -n "$all_files" ]]; then
            echo "| File | Imports |"
            echo "|------|---------|"

            local tracked
            tracked=$(cd "$RQS_TARGET_REPO" && git ls-files)

            echo "$all_files" | while IFS= read -r f; do
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
                        echo "| \`$f\` | $deps_list |"
                        has_deps=true
                    fi
                fi
            done

            if [[ "$has_deps" == "false" ]]; then
                echo "*(no internal dependencies detected)*"
            fi
        else
            echo "*(no files to analyze)*"
        fi
        return
    fi

    # Python dependency graph
    echo "| File | Internal Imports |"
    echo "|------|-----------------|"

    echo "$py_files" | while IFS= read -r f; do
        local abs="$RQS_TARGET_REPO/$f"
        [[ ! -f "$abs" ]] && continue

        local internal_deps
        internal_deps=$(python3 -c "
import ast, sys, os, subprocess

filepath = sys.argv[1]
rel_path = sys.argv[2]
repo_root = sys.argv[3]

try:
    with open(filepath) as fh:
        tree = ast.parse(fh.read())
except SyntaxError:
    sys.exit(0)

tracked = set()
try:
    result = subprocess.run(['git', 'ls-files'], cwd=repo_root,
                          capture_output=True, text=True)
    tracked = set(result.stdout.strip().split('\n'))
except Exception:
    pass

def is_internal(module_name):
    parts = module_name.split('.')
    candidates = [
        '/'.join(parts) + '.py',
        '/'.join(parts) + '/__init__.py',
    ]
    file_dir = os.path.dirname(rel_path)
    if file_dir:
        candidates.extend([
            file_dir + '/' + '/'.join(parts) + '.py',
            file_dir + '/' + '/'.join(parts) + '/__init__.py',
        ])
    for c in candidates:
        if c in tracked:
            return True
    return False

internal = []
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            if is_internal(alias.name):
                internal.append(alias.name)
    elif isinstance(node, ast.ImportFrom):
        if node.module and node.level == 0 and is_internal(node.module):
            internal.append(node.module)
        elif node.level > 0 and node.module:
            internal.append('.' * node.level + node.module)

if internal:
    print(', '.join(sorted(set(internal))))
" "$abs" "$f" "$RQS_TARGET_REPO" 2>/dev/null || true)

        if [[ -n "$internal_deps" ]]; then
            echo "| \`$f\` | $internal_deps |"
        fi
    done
}
