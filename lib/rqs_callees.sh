#!/usr/bin/env bash
# rqs_callees.sh — show what a function/method calls

cmd_callees() {
    local symbol=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs callees <symbol>

Show what functions/methods a given symbol calls (outgoing edges).
This is the inverse of `rqs references` — instead of "who calls me?",
it answers "what do I call?".

Options:
  symbol    Name of the function or method to analyze
  --help    Show this help

For Python files, uses AST analysis to extract call names from the
function body. For other languages, extracts the function source and
cross-references against the repository's symbol table.
EOF
                return 0
                ;;
            -*) rqs_error "callees: unknown option '$1'" ;;
            *) symbol="$1"; shift ;;
        esac
    done

    if [[ -z "$symbol" ]]; then
        rqs_error "callees: symbol argument required"
    fi

    if ! rqs_has_ctags; then
        rqs_error "callees: ctags required but not available"
    fi

    # Generate ctags for the whole repo, pipe to render with symbol name
    rqs_list_files | while IFS= read -r f; do
        (cd "$RQS_TARGET_REPO" && ctags $(rqs_ctags_args) -f - "$f" 2>/dev/null)
    done | rqs_render callees "$symbol" || true
}
