#!/usr/bin/env bash
# rqs_deps.sh — show imports, distinguish internal vs external

cmd_deps() {
    local filepath=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs deps <file>

Show imports/dependencies for a file, classified as internal or external.

Options:
  file      Path to the file to analyze
  --help    Show this help

Internal dependencies are modules/files that exist in the repository.
External dependencies are third-party libraries or system modules.

For Python files, uses AST-based analysis when possible, falling back
to regex patterns for other languages.
EOF
                return 0
                ;;
            -*) rqs_error "deps: unknown option '$1'" ;;
            *) filepath="$1"; shift ;;
        esac
    done

    if [[ -z "$filepath" ]]; then
        rqs_error "deps: file argument required"
    fi

    local resolved
    resolved=$(rqs_resolve_path "$filepath")
    local rel
    rel=$(rqs_relative_path "$resolved")

    if [[ ! -f "$resolved" ]]; then
        rqs_error "deps: file not found: $filepath"
    fi

    if ! rqs_is_text_file "$rel"; then
        rqs_error "deps: not a text file: $filepath"
    fi

    local ext="${rel##*.}"

    # For Python files, use AST-based analysis
    if [[ "$ext" == "py" ]]; then
        deps_python_ast "$resolved" "$rel"
        return
    fi

    # For other languages, use regex patterns
    deps_regex "$resolved" "$rel" "$ext"
}

deps_python_ast() {
    local abs_path="$1"
    local rel_path="$2"

    python3 -c "
import ast, sys, os

filepath = sys.argv[1]
rel_path = sys.argv[2]
repo_root = sys.argv[3]

try:
    with open(filepath) as f:
        tree = ast.parse(f.read(), filename=filepath)
except SyntaxError:
    sys.exit(1)

# Get all tracked files for internal resolution
import subprocess
tracked = set()
try:
    result = subprocess.run(['git', 'ls-files'], cwd=repo_root,
                          capture_output=True, text=True)
    tracked = set(result.stdout.strip().split('\n'))
except Exception:
    pass

def is_internal(module_name):
    \"\"\"Check if a module corresponds to a file in the repository.\"\"\"
    # Convert dotted module to possible file paths
    parts = module_name.split('.')
    candidates = [
        '/'.join(parts) + '.py',
        '/'.join(parts) + '/__init__.py',
    ]
    # Also check relative to the file's directory
    file_dir = os.path.dirname(rel_path)
    if file_dir:
        candidates.extend([
            file_dir + '/' + '/'.join(parts) + '.py',
            file_dir + '/' + '/'.join(parts) + '/__init__.py',
        ])
    # Check parent package
    if len(parts) > 1:
        candidates.append('/'.join(parts[:-1]) + '.py')

    for candidate in candidates:
        if candidate in tracked:
            return True
    return False

for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        for alias in node.names:
            mod = alias.name
            prefix = 'INTERNAL' if is_internal(mod) else 'EXTERNAL'
            print(f'{prefix}:{mod}')
    elif isinstance(node, ast.ImportFrom):
        if node.module:
            mod = node.module
            names = ', '.join(a.name for a in node.names) if node.names else ''
            suffix = f' ({names})' if names else ''
            if node.level > 0:
                # Relative import — always internal
                label = '.' * node.level + mod
                print(f'INTERNAL:{label}{suffix}')
            else:
                prefix = 'INTERNAL' if is_internal(mod) else 'EXTERNAL'
                print(f'{prefix}:{mod}{suffix}')
" "$abs_path" "$rel_path" "$RQS_TARGET_REPO" | sort -u | rqs_render deps "$rel_path"
}

deps_regex() {
    local abs_path="$1"
    local rel_path="$2"
    local ext="$3"
    local import_conf="$RQS_CONF_DIR/import_patterns.conf"

    if [[ ! -f "$import_conf" ]]; then
        echo "" | rqs_render deps "$rel_path"
        return
    fi

    # Get tracked files for internal resolution
    local tracked_files
    tracked_files=$(cd "$RQS_TARGET_REPO" && git ls-files 2>/dev/null)

    # Extract imports using language-specific patterns
    local imports=""
    while IFS=$'\t' read -r pat_ext pat_regex pat_group; do
        # Skip comments and blanks
        [[ -z "$pat_ext" || "$pat_ext" == \#* ]] && continue
        pat_ext="${pat_ext#"${pat_ext%%[![:space:]]*}"}"
        pat_ext="${pat_ext%"${pat_ext##*[![:space:]]}"}"

        [[ "$pat_ext" != "$ext" ]] && continue

        # Extract matches
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            # Classify as internal or external
            if is_internal_dep "$match" "$rel_path" "$tracked_files" "$ext"; then
                imports="${imports}INTERNAL:${match}"$'\n'
            else
                imports="${imports}EXTERNAL:${match}"$'\n'
            fi
        done < <(grep -oP "$pat_regex" "$abs_path" 2>/dev/null | sed -E "s/$pat_regex/\\${pat_group}/" | sort -u)
    done < "$import_conf"

    echo "$imports" | rqs_render deps "$rel_path"
}

is_internal_dep() {
    local module="$1"
    local rel_path="$2"
    local tracked="$3"
    local ext="$4"

    # Relative path imports (./foo, ../bar)
    if [[ "$module" == ./* || "$module" == ../* ]]; then
        return 0
    fi

    # Convert module to possible file paths and check
    local file_dir
    file_dir=$(dirname "$rel_path")

    local candidates=()
    case "$ext" in
        js|ts|jsx|tsx)
            candidates=(
                "${module}.${ext}"
                "${module}/index.${ext}"
                "${module}.js"
                "${module}/index.js"
            )
            if [[ "$file_dir" != "." ]]; then
                candidates+=(
                    "${file_dir}/${module}.${ext}"
                    "${file_dir}/${module}/index.${ext}"
                )
            fi
            ;;
        go)
            # Go uses package paths
            candidates=("${module}")
            ;;
        rb)
            candidates=("${module}.rb" "lib/${module}.rb")
            ;;
        c|cpp|h|hpp)
            candidates=("${module}" "include/${module}" "src/${module}")
            ;;
        sh|bash)
            candidates=("${module}")
            if [[ "$file_dir" != "." ]]; then
                candidates+=("${file_dir}/${module}")
            fi
            ;;
    esac

    for candidate in "${candidates[@]}"; do
        if echo "$tracked" | grep -qF "$candidate"; then
            return 0
        fi
    done
    return 1
}
