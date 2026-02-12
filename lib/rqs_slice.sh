#!/usr/bin/env bash
# rqs_slice.sh — extract exact code slice with line numbers

cmd_slice() {
    local filepath=""
    local start_line=""
    local end_line=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs slice <file> <start> <end>

Extract exact code slice with line numbers.

Options:
  file      Path to the file
  start     Starting line number
  end       Ending line number
  --help    Show this help

The maximum slice size is controlled by RQS_SLICE_MAX_LINES (default: 200).
EOF
                return 0
                ;;
            -*) rqs_error "slice: unknown option '$1'" ;;
            *)
                if [[ -z "$filepath" ]]; then
                    filepath="$1"
                elif [[ -z "$start_line" ]]; then
                    start_line="$1"
                elif [[ -z "$end_line" ]]; then
                    end_line="$1"
                else
                    rqs_error "slice: too many arguments"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$filepath" || -z "$start_line" || -z "$end_line" ]]; then
        rqs_error "slice: requires <file> <start> <end>"
    fi

    # Validate line numbers
    if ! [[ "$start_line" =~ ^[0-9]+$ && "$end_line" =~ ^[0-9]+$ ]]; then
        rqs_error "slice: start and end must be positive integers"
    fi

    if [[ "$start_line" -gt "$end_line" ]]; then
        rqs_error "slice: start ($start_line) must be <= end ($end_line)"
    fi

    local span=$((end_line - start_line + 1))
    if [[ "$span" -gt "$RQS_SLICE_MAX_LINES" ]]; then
        rqs_error "slice: requested $span lines exceeds maximum ($RQS_SLICE_MAX_LINES)"
    fi

    local resolved
    resolved=$(rqs_resolve_path "$filepath")
    local rel
    rel=$(rqs_relative_path "$resolved")

    if [[ ! -f "$resolved" ]]; then
        rqs_error "slice: file not found: $filepath"
    fi

    if ! rqs_is_text_file "$rel"; then
        rqs_error "slice: not a text file: $filepath"
    fi

    # Detect language for code fence
    local lang=""
    case "${rel##*.}" in
        py) lang="python" ;;
        js) lang="javascript" ;;
        ts) lang="typescript" ;;
        jsx) lang="jsx" ;;
        tsx) lang="tsx" ;;
        sh|bash) lang="bash" ;;
        rb) lang="ruby" ;;
        go) lang="go" ;;
        rs) lang="rust" ;;
        java) lang="java" ;;
        c|h) lang="c" ;;
        cpp|cc|cxx|hpp) lang="cpp" ;;
        css) lang="css" ;;
        html|htm) lang="html" ;;
        json) lang="json" ;;
        yaml|yml) lang="yaml" ;;
        toml) lang="toml" ;;
        xml) lang="xml" ;;
        sql) lang="sql" ;;
        md) lang="markdown" ;;
        *) lang="" ;;
    esac

    # Extract slice with line numbers
    sed -n "${start_line},${end_line}p" "$resolved" \
        | awk -v start="$start_line" '{printf "%*d: %s\n", length(start+NR), start+NR-1, $0}' \
        | rqs_render slice "$rel" "$lang" --lines "$start_line" "$end_line"
}
