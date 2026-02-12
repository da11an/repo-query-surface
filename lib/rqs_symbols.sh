#!/usr/bin/env bash
# rqs_symbols.sh — symbol index subcommand

cmd_symbols() {
    local target=""
    local filter_kinds="$RQS_SYMBOL_KINDS"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --kinds) filter_kinds="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs symbols [file|dir] [--kinds LIST]

Show symbol index via ctags (classes, functions, methods, types).

Options:
  file|dir       Scope to a specific file or directory (default: entire repo)
  --kinds LIST   Comma-separated symbol kinds to include (default: from config)
  --help         Show this help
EOF
                return 0
                ;;
            -*) rqs_error "symbols: unknown option '$1'" ;;
            *) target="$1"; shift ;;
        esac
    done

    local scope_arg=""
    if [[ -n "$target" ]]; then
        scope_arg="--scope $target"
    fi

    if rqs_has_ctags; then
        if [[ -n "$target" ]]; then
            local resolved
            resolved=$(rqs_resolve_path "$target")
            local rel
            rel=$(rqs_relative_path "$resolved")
            if [[ -f "$resolved" ]]; then
                rqs_run_ctags_file "$rel" | rqs_render symbols --scope "$rel" --kinds "$filter_kinds"
            else
                # Directory — run ctags on listed files
                rqs_list_files "$rel" | while IFS= read -r f; do
                    (cd "$RQS_TARGET_REPO" && ctags $(rqs_ctags_args) -f - "$f" 2>/dev/null)
                done | rqs_render symbols --scope "$rel" --kinds "$filter_kinds"
            fi
        else
            # Whole repo — use cache if available
            local tags_file
            if tags_file=$(rqs_cache_ctags 2>/dev/null); then
                rqs_render symbols --kinds "$filter_kinds" --from-cache < "$tags_file"
            else
                rqs_list_files | while IFS= read -r f; do
                    (cd "$RQS_TARGET_REPO" && ctags $(rqs_ctags_args) -f - "$f" 2>/dev/null)
                done | rqs_render symbols --kinds "$filter_kinds"
            fi
        fi
    else
        # Fallback: grep-based heuristic
        rqs_warn "ctags not available, using grep heuristic"
        symbols_grep_fallback "$target"
    fi
}

symbols_grep_fallback() {
    local target="${1:-.}"
    local scope_arg=""
    [[ "$target" != "." ]] && scope_arg="--scope $target"

    # Simple grep for common symbol patterns
    (cd "$RQS_TARGET_REPO" && rqs_list_files "$target" | while IFS= read -r f; do
        # Python: class/def
        if [[ "$f" == *.py ]]; then
            grep -nE '^\s*(class|def|async def)\s+\w+' "$f" 2>/dev/null | while IFS=: read -r line content; do
                local kind="function"
                [[ "$content" =~ ^[[:space:]]*class ]] && kind="class"
                local name
                name=$(echo "$content" | sed -E 's/^\s*(class|def|async def)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')
                echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$f\",\"line\":$line,\"kind\":\"$kind\"}"
            done
        fi
        # JavaScript/TypeScript: class/function/const
        if [[ "$f" == *.js || "$f" == *.ts || "$f" == *.jsx || "$f" == *.tsx ]]; then
            grep -nE '^\s*(export\s+)?(class|function|const|let|var|interface|type|enum)\s+\w+' "$f" 2>/dev/null | while IFS=: read -r line content; do
                local kind="function"
                [[ "$content" =~ class ]] && kind="class"
                [[ "$content" =~ interface ]] && kind="interface"
                [[ "$content" =~ type[[:space:]] ]] && kind="type"
                [[ "$content" =~ enum ]] && kind="enum"
                [[ "$content" =~ (const|let|var) ]] && kind="variable"
                local name
                name=$(echo "$content" | sed -E 's/^\s*(export\s+)?(class|function|async function|const|let|var|interface|type|enum)\s+([a-zA-Z_][a-zA-Z0-9_]*).*/\3/')
                echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$f\",\"line\":$line,\"kind\":\"$kind\"}"
            done
        fi
        # Shell: function
        if [[ "$f" == *.sh || "$f" == *.bash ]]; then
            grep -nE '^\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\(\)|^\s*function\s+\w+' "$f" 2>/dev/null | while IFS=: read -r line content; do
                local name
                name=$(echo "$content" | sed -E 's/^\s*(function\s+)?([a-zA-Z_][a-zA-Z0-9_]*).*/\2/')
                echo "{\"_type\":\"tag\",\"name\":\"$name\",\"path\":\"$f\",\"line\":$line,\"kind\":\"function\"}"
            done
        fi
    done) | rqs_render symbols $scope_arg
}
