#!/usr/bin/env bash
# rqs_files.sh — list files matching a glob pattern

cmd_files() {
    local pattern=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs files <glob>

List git-tracked files matching a glob pattern, with line counts.

Options:
  glob      Glob pattern to match (e.g. "*.py", "src/**/*.ts", "*_test*")
  --help    Show this help

Examples:
  rqs files "*.py"           All Python files
  rqs files "test_*"         Files starting with test_
  rqs files "src/**/*.js"    JS files under src/
  rqs files "*config*"       Files with config in the name
EOF
                return 0
                ;;
            -*) rqs_error "files: unknown option '$1'" ;;
            *)
                if [[ -z "$pattern" ]]; then
                    pattern="$1"
                else
                    rqs_error "files: too many arguments"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$pattern" ]]; then
        rqs_error "files: glob pattern required"
    fi

    # Use git ls-files with glob, filtered through ignore patterns
    local matched
    matched=$(cd "$RQS_TARGET_REPO" && git ls-files -- "$pattern" 2>/dev/null \
        | grep -vE "$RQS_IGNORE_REGEX" \
        | sort) || true

    if [[ -z "$matched" ]]; then
        echo "*(no files matching \`$pattern\`)*"
        return
    fi

    echo "$matched" | rqs_render files "$pattern"
}
