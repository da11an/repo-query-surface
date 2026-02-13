#!/usr/bin/env bash
# rqs_show.sh — extract full source of named symbols

cmd_show() {
    local symbols=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs show <symbol> [symbol...]

Extract the full source code of one or more named symbols (classes,
functions, methods). Uses ctags to locate each symbol's file and
line span, then extracts the source with line numbers.

Options:
  symbol    One or more symbol names to extract
  --help    Show this help

Multiple symbols can be requested in a single call to reduce round trips.
EOF
                return 0
                ;;
            -*) rqs_error "show: unknown option '$1'" ;;
            *) symbols+=("$1"); shift ;;
        esac
    done

    if [[ ${#symbols[@]} -eq 0 ]]; then
        rqs_error "show: at least one symbol argument required"
    fi

    if ! rqs_has_ctags; then
        rqs_error "show: ctags required but not available"
    fi

    # Generate ctags for the whole repo, pipe to render with symbol names
    rqs_list_files | while IFS= read -r f; do
        (cd "$RQS_TARGET_REPO" && ctags $(rqs_ctags_args) -f - "$f" 2>/dev/null)
    done | rqs_render show "${symbols[@]}" || true
}
