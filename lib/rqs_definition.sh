#!/usr/bin/env bash
# rqs_definition.sh — find where a symbol is defined

cmd_definition() {
    local symbol=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs definition <symbol>

Find where a symbol is defined in the repository.

Options:
  symbol    Name of the symbol to find
  --help    Show this help
EOF
                return 0
                ;;
            -*) rqs_error "definition: unknown option '$1'" ;;
            *) symbol="$1"; shift ;;
        esac
    done

    if [[ -z "$symbol" ]]; then
        rqs_error "definition: symbol argument required"
    fi

    if rqs_has_ctags; then
        # Run ctags on all tracked files and search
        { rqs_list_files | while IFS= read -r f; do
            (cd "$RQS_TARGET_REPO" && ctags --output-format=json --fields=+nKSse -f - "$f" 2>/dev/null)
        done | grep "\"name\": *\"$symbol\"" || true; } | rqs_render definition "$symbol"
    else
        # Grep fallback
        rqs_warn "ctags not available, using grep heuristic"
        definition_grep_fallback "$symbol"
    fi
}

definition_grep_fallback() {
    local symbol="$1"

    # Search for common definition patterns
    local results
    results=$(cd "$RQS_TARGET_REPO" && rqs_list_files | xargs grep -nE \
        "(class|def|function|const|let|var|interface|type|enum|struct)\s+${symbol}\b" \
        2>/dev/null || true)

    if [[ -z "$results" ]]; then
        echo "" | rqs_render definition "$symbol"
        return
    fi

    # Convert grep results to ctags-like JSON
    echo "$results" | while IFS=: read -r file line content; do
        local kind="function"
        [[ "$content" =~ class ]] && kind="class"
        [[ "$content" =~ interface ]] && kind="interface"
        [[ "$content" =~ type[[:space:]] ]] && kind="type"
        [[ "$content" =~ struct ]] && kind="struct"
        [[ "$content" =~ enum ]] && kind="enum"
        [[ "$content" =~ (const|let|var) ]] && kind="variable"
        echo "{\"_type\":\"tag\",\"name\":\"$symbol\",\"path\":\"$file\",\"line\":$line,\"kind\":\"$kind\"}"
    done | rqs_render definition "$symbol"
}
