#!/usr/bin/env bash
# rqs_outline.sh — structural outline of a single file

cmd_outline() {
    local filepath=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs outline <file>

Show structural outline of a single file (hierarchy-aware).

Options:
  file      Path to the file to outline
  --help    Show this help
EOF
                return 0
                ;;
            -*) rqs_error "outline: unknown option '$1'" ;;
            *) filepath="$1"; shift ;;
        esac
    done

    if [[ -z "$filepath" ]]; then
        rqs_error "outline: file argument required"
    fi

    local resolved
    resolved=$(rqs_resolve_path "$filepath")
    local rel
    rel=$(rqs_relative_path "$resolved")

    if [[ ! -f "$resolved" ]]; then
        rqs_error "outline: file not found: $filepath"
    fi

    if ! rqs_is_text_file "$rel"; then
        rqs_error "outline: not a text file: $filepath"
    fi

    if rqs_has_ctags; then
        rqs_run_ctags_file "$rel" | rqs_render outline "$rel"
    else
        # Grep fallback for outline
        rqs_warn "ctags not available, using grep heuristic"
        outline_grep_fallback "$resolved" "$rel"
    fi
}

outline_grep_fallback() {
    local abs_path="$1"
    local rel_path="$2"
    local ext="${rel_path##*.}"

    (
        case "$ext" in
            py)
                grep -nE '^\s*(class|def|async def)\s+\w+' "$abs_path" 2>/dev/null | while IFS=: read -r line content; do
                    local kind="function"
                    [[ "$content" =~ ^[[:space:]]*class ]] && kind="class"
                    # Measure indent to infer scope
                    local indent_len
                    indent_len=$(echo "$content" | sed -E 's/^( *).*/\1/' | wc -c)
                    indent_len=$((indent_len - 1))
                    local scope=""
                    if [[ $indent_len -gt 0 ]]; then
                        scope="(nested)"
                    fi
                    local name
                    name=$(echo "$content" | sed -E 's/^\s*(class|def|async def)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')
                    echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$rel_path\",\"line\":$line,\"kind\":\"$kind\",\"scope\":\"$scope\"}"
                done
                ;;
            js|ts|jsx|tsx)
                grep -nE '^\s*(export\s+)?(class|function|async function|const|interface|type|enum)\s+\w+' "$abs_path" 2>/dev/null | while IFS=: read -r line content; do
                    local kind="function"
                    [[ "$content" =~ class ]] && kind="class"
                    [[ "$content" =~ interface ]] && kind="interface"
                    [[ "$content" =~ type[[:space:]] ]] && kind="type"
                    [[ "$content" =~ enum ]] && kind="enum"
                    local name
                    name=$(echo "$content" | sed -E 's/^\s*(export\s+)?(class|function|async function|const|let|var|interface|type|enum)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\3/')
                    echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$rel_path\",\"line\":$line,\"kind\":\"$kind\"}"
                done
                ;;
            sh|bash)
                grep -nE '^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)|^\s*function\s+\w+' "$abs_path" 2>/dev/null | while IFS=: read -r line content; do
                    local name
                    name=$(echo "$content" | sed -E 's/^\s*(function\s+)?([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')
                    echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$rel_path\",\"line\":$line,\"kind\":\"function\"}"
                done
                ;;
        esac
    ) | rqs_render outline "$rel_path"
}
