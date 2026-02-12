#!/usr/bin/env bash
# rqs_signatures.sh — extract structural signatures from Python files

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

Currently supports Python files (.py) via AST analysis.
EOF
                return 0
                ;;
            -*) rqs_error "signatures: unknown option '$1'" ;;
            *) target="$1"; shift ;;
        esac
    done

    local py_files

    if [[ -n "$target" ]]; then
        local resolved
        resolved=$(rqs_resolve_path "$target")
        local rel
        rel=$(rqs_relative_path "$resolved")

        if [[ -f "$resolved" ]]; then
            if [[ "$rel" != *.py ]]; then
                rqs_error "signatures: only Python files are supported (got $rel)"
            fi
            echo "$rel" | rqs_render signatures
        else
            py_files=$(rqs_list_files "$rel" | grep '\.py$' || true)
            if [[ -z "$py_files" ]]; then
                echo "" | rqs_render signatures
            else
                echo "$py_files" | rqs_render signatures
            fi
        fi
    else
        py_files=$(rqs_list_files | grep '\.py$' || true)
        if [[ -z "$py_files" ]]; then
            echo "" | rqs_render signatures
        else
            echo "$py_files" | rqs_render signatures
        fi
    fi
}
