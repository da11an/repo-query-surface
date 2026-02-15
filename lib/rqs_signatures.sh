#!/usr/bin/env bash
# rqs_signatures.sh — extract structural signatures from source files

cmd_signatures() {
    local target=""
    local -a extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs signatures [file|dir] [--budget N] [--churn-data PATH]

Extract class/function signatures with decorators, return statements,
and first-line docstrings. Gives an LLM a behavioral sketch of the
code without implementation details.

Options:
  file|dir         Scope to a specific file or directory (default: entire repo)
  --budget N       Limit output to ~N lines with importance-ranked tiers
  --churn-data PATH  JSON file with per-file churn data for ranking
  --help           Show this help

Python files use full AST analysis. Other languages use ctags signatures.
EOF
                return 0
                ;;
            --budget|--churn-data) extra_args+=("$1" "$2"); shift 2 ;;
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
            echo "$rel" | rqs_render signatures --scope "$rel" "${extra_args[@]}"
        else
            local files
            files=$(rqs_list_files "$rel" || true)
            if [[ -z "$files" ]]; then
                echo "" | rqs_render signatures --scope "$rel" "${extra_args[@]}"
            else
                echo "$files" | rqs_render signatures --scope "$rel" "${extra_args[@]}"
            fi
        fi
    else
        local files
        files=$(rqs_list_files || true)
        if [[ -z "$files" ]]; then
            echo "" | rqs_render signatures "${extra_args[@]}"
        else
            echo "$files" | rqs_render signatures "${extra_args[@]}"
        fi
    fi
}
