#!/usr/bin/env bash
# rqs_notebook.sh — extract structured content from Jupyter notebooks

cmd_notebook() {
    local filepath=""
    local debug=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs notebook <file> [--debug]

Extract structured content from a Jupyter notebook (.ipynb).

Renders markdown cells as-is, code cells in fenced blocks, and outputs
with smart truncation (text: first N lines, errors: ename + last frames,
rich outputs: placeholders).

Options:
  --debug   Error analysis mode: parse tracebacks, classify frames
            (notebook-local / repo-local / external), extract enclosing
            function source for repo-local frames with error line marked,
            show dependency chains, and produce diagnostic summaries with
            suggested rqs commands.

Environment variables:
  RQS_NOTEBOOK_MAX_OUTPUT_LINES   Max text output lines (default: 10)
  RQS_NOTEBOOK_MAX_TRACEBACK      Max traceback frames (default: 5)

Examples:
  rqs notebook notebooks/analysis.ipynb
  rqs notebook notebooks/analysis.ipynb --debug
  RQS_NOTEBOOK_MAX_OUTPUT_LINES=20 rqs notebook demo.ipynb
EOF
                return 0
                ;;
            --debug) debug=true; shift ;;
            -*) rqs_error "notebook: unknown option '$1'" ;;
            *)
                if [[ -z "$filepath" ]]; then
                    filepath="$1"
                else
                    rqs_error "notebook: too many arguments"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$filepath" ]]; then
        rqs_error "notebook: missing file argument (try 'rqs notebook --help')"
    fi

    # Validate extension
    if [[ "$filepath" != *.ipynb ]]; then
        rqs_error "notebook: file must have .ipynb extension: $filepath"
    fi

    # Resolve path
    local abs_path
    abs_path=$(rqs_resolve_path "$filepath") || exit 1

    if [[ ! -f "$abs_path" ]]; then
        rqs_error "notebook: file not found: $filepath"
    fi

    local rel
    rel=$(rqs_relative_path "$abs_path")

    if [[ "$debug" == true ]]; then
        # Cache ctags for cross-referencing (best-effort)
        local ctags_cache
        ctags_cache=$(rqs_cache_ctags 2>/dev/null) || true
        if [[ -n "$ctags_cache" ]]; then
            export RQS_CTAGS_CACHE="$ctags_cache"
        fi
        rqs_render notebook-debug "$rel"
    else
        rqs_render notebook "$rel"
    fi
}
