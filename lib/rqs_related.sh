#!/usr/bin/env bash
# rqs_related.sh — show files related to a given file

cmd_related() {
    local filepath=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs related <file>

Show files related to a given file: files it imports (forward
dependencies) and files that import it (reverse dependencies).
A one-command "neighborhood" view of a file's connections.

Options:
  file      Path to the file to analyze
  --help    Show this help
EOF
                return 0
                ;;
            -*) rqs_error "related: unknown option '$1'" ;;
            *) filepath="$1"; shift ;;
        esac
    done

    if [[ -z "$filepath" ]]; then
        rqs_error "related: file argument required"
    fi

    local resolved
    resolved=$(rqs_resolve_path "$filepath")
    local rel
    rel=$(rqs_relative_path "$resolved")

    if [[ ! -f "$resolved" ]]; then
        rqs_error "related: file not found: $filepath"
    fi

    # Compute forward deps (what this file imports)
    local forward=""
    local ext="${rel##*.}"

    if [[ "$ext" == "py" ]]; then
        forward=$(related_python_forward "$resolved" "$rel")
    else
        forward=$(related_regex_forward "$resolved" "$rel" "$ext")
    fi

    # Compute reverse deps (who imports this file)
    local reverse
    reverse=$(related_reverse "$rel")

    # Render
    {
        echo "FORWARD:$forward"
        echo "REVERSE:$reverse"
    } | rqs_render related "$rel"
}

related_python_forward() {
    local abs_path="$1"
    local rel_path="$2"

    python3 -c "
import ast, sys, os, subprocess

filepath = sys.argv[1]
rel_path = sys.argv[2]
repo_root = sys.argv[3]

try:
    with open(filepath) as f:
        tree = ast.parse(f.read())
except SyntaxError:
    sys.exit(0)

tracked = set()
try:
    result = subprocess.run(['git', 'ls-files'], cwd=repo_root,
                          capture_output=True, text=True)
    tracked = set(result.stdout.strip().split('\n'))
except Exception:
    pass

def resolve_module(module_name, level=0):
    parts = module_name.split('.')
    candidates = [
        '/'.join(parts) + '.py',
        '/'.join(parts) + '/__init__.py',
    ]
    file_dir = os.path.dirname(rel_path)
    if level > 0 and file_dir:
        # Relative import
        candidates = [
            file_dir + '/' + '/'.join(parts) + '.py',
            file_dir + '/' + '/'.join(parts) + '/__init__.py',
        ]
    elif file_dir:
        candidates.extend([
            file_dir + '/' + '/'.join(parts) + '.py',
            file_dir + '/' + '/'.join(parts) + '/__init__.py',
        ])
    for c in candidates:
        if c in tracked:
            return c
    return None

files = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            resolved = resolve_module(alias.name)
            if resolved:
                files.add(resolved)
    elif isinstance(node, ast.ImportFrom):
        if node.module:
            resolved = resolve_module(node.module, node.level)
            if resolved:
                files.add(resolved)

for f in sorted(files):
    print(f)
" "$abs_path" "$rel_path" "$RQS_TARGET_REPO" 2>/dev/null || true
}

related_regex_forward() {
    local abs_path="$1"
    local rel_path="$2"
    local ext="$3"
    local import_conf="$RQS_CONF_DIR/import_patterns.conf"

    if [[ ! -f "$import_conf" ]]; then
        return
    fi

    local tracked_files
    tracked_files=$(cd "$RQS_TARGET_REPO" && git ls-files 2>/dev/null)
    local file_dir
    file_dir=$(dirname "$rel_path")

    while IFS=$'\t' read -r pat_ext pat_regex pat_group; do
        [[ -z "$pat_ext" || "$pat_ext" == \#* ]] && continue
        pat_ext="${pat_ext#"${pat_ext%%[![:space:]]*}"}"
        pat_ext="${pat_ext%"${pat_ext##*[![:space:]]}"}"
        [[ "$pat_ext" != "$ext" ]] && continue

        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            # Try to resolve to a tracked file
            local candidates=()
            case "$ext" in
                js|ts|jsx|tsx)
                    candidates=("${match}.${ext}" "${match}/index.${ext}" "${match}.js" "${match}/index.js")
                    [[ "$file_dir" != "." ]] && candidates+=("${file_dir}/${match}.${ext}" "${file_dir}/${match}/index.${ext}")
                    ;;
                sh|bash) candidates=("${match}" "${file_dir}/${match}") ;;
                rb) candidates=("${match}.rb" "lib/${match}.rb") ;;
                *) candidates=("${match}") ;;
            esac
            for c in "${candidates[@]}"; do
                if echo "$tracked_files" | grep -qF "$c"; then
                    echo "$c"
                    break
                fi
            done
        done < <(grep -oP "$pat_regex" "$abs_path" 2>/dev/null | sed -E "s/$pat_regex/\\\\${pat_group}/" | sort -u)
    done < "$import_conf"
}

related_reverse() {
    local rel_path="$1"

    # Derive module/file name patterns that other files might use to import this one
    local basename
    basename=$(basename "$rel_path")
    local name_no_ext="${basename%.*}"
    local ext="${basename##*.}"

    # Build search patterns based on file type
    local patterns=()
    case "$ext" in
        py)
            # Python: from X.Y.Z import ... or import X.Y.Z
            # Convert path to dotted module name
            local module_path="${rel_path%.py}"
            module_path="${module_path%/__init__}"
            local dotted="${module_path//\//.}"
            patterns+=("$dotted" "$name_no_ext")
            ;;
        js|ts|jsx|tsx)
            patterns+=("$name_no_ext" "${rel_path%.*}")
            ;;
        sh|bash)
            patterns+=("$basename" "$rel_path")
            ;;
        *)
            patterns+=("$name_no_ext" "$basename")
            ;;
    esac

    # Search tracked files for import references
    local all_files
    all_files=$(cd "$RQS_TARGET_REPO" && git ls-files 2>/dev/null | grep -vE "$RQS_IGNORE_REGEX")

    local found=()
    for pattern in "${patterns[@]}"; do
        [[ -z "$pattern" ]] && continue
        local matches
        matches=$(cd "$RQS_TARGET_REPO" && echo "$all_files" | xargs grep -lF "$pattern" 2>/dev/null || true)
        while IFS= read -r f; do
            [[ -z "$f" || "$f" == "$rel_path" ]] && continue
            found+=("$f")
        done <<< "$matches"
    done

    # Deduplicate and sort
    printf '%s\n' "${found[@]}" | sort -u
}
