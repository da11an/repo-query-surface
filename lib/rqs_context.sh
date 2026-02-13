#!/usr/bin/env bash
# rqs_context.sh — show enclosing symbol for a given file:line

cmd_context() {
    local filepath=""
    local target_line=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs context <file> <line>

Show the enclosing function or class for a given line number. Uses
ctags to find the innermost symbol whose span contains the target
line, then extracts its full source with line numbers.

Options:
  file      Path to the file
  line      Line number to find context for
  --help    Show this help

Useful when you have a line number (from grep, error trace, etc.)
and want to see the full function or class around it.
EOF
                return 0
                ;;
            -*) rqs_error "context: unknown option '$1'" ;;
            *)
                if [[ -z "$filepath" ]]; then
                    filepath="$1"
                elif [[ -z "$target_line" ]]; then
                    target_line="$1"
                else
                    rqs_error "context: too many arguments"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$filepath" || -z "$target_line" ]]; then
        rqs_error "context: requires <file> <line>"
    fi

    if ! [[ "$target_line" =~ ^[0-9]+$ ]]; then
        rqs_error "context: line must be a positive integer"
    fi

    local resolved
    resolved=$(rqs_resolve_path "$filepath")
    local rel
    rel=$(rqs_relative_path "$resolved")

    if [[ ! -f "$resolved" ]]; then
        rqs_error "context: file not found: $filepath"
    fi

    if ! rqs_has_ctags; then
        rqs_error "context: ctags required but not available"
    fi

    # Run ctags on this file, pipe to render with filepath and target line
    rqs_run_ctags_file "$rel" | rqs_render context "$rel" "$target_line"
}
