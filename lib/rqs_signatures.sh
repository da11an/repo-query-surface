#!/usr/bin/env bash
# rqs_signatures.sh — extract structural signatures from source files

cmd_signatures() {
    local target=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs signatures [file|dir]

Extract class/function signatures with decorators, return statements,
and first-line docstrings. Gives an LLM a behavioral sketch of the
code without implementation details.

Options:
  file|dir   Scope to a specific file or directory (default: entire repo)
  --help     Show this help

Python files use full AST analysis. Other languages use ctags signatures.
EOF
                return 0
                ;;
            -*) rqs_error "signatures: unknown option '$1'" ;;
            *) target="$1"; shift ;;
        esac
    done

    if [[ -n "$target" ]]; then
        local resolved
        resolved=$(rqs_resolve_path "$target")
        local rel
        rel=$(rqs_relative_path "$resolved")

        if [[ -f "$resolved" ]]; then
            echo "$rel" | rqs_render signatures --scope "$rel"
        else
            local files
            files=$(rqs_list_files "$rel" || true)
            if [[ -z "$files" ]]; then
                echo "" | rqs_render signatures --scope "$rel"
            else
                echo "$files" | rqs_render signatures --scope "$rel"
            fi
        fi
    else
        local files
        files=$(rqs_list_files || true)
        if [[ -z "$files" ]]; then
            echo "" | rqs_render signatures
        else
            echo "$files" | rqs_render signatures
        fi
    fi
}
