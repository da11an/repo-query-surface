#!/usr/bin/env bash
# rqs_references.sh — find call sites / usage of a symbol

cmd_references() {
    local symbol=""
    local max_results="$RQS_REF_MAX_RESULTS"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --max) max_results="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs references <symbol> [--max N]

Find call sites and usage of a symbol (excludes definitions).

Options:
  symbol    Name of the symbol to search for
  --max N   Maximum number of results (default: from config)
  --help    Show this help
EOF
                return 0
                ;;
            -*) rqs_error "references: unknown option '$1'" ;;
            *) symbol="$1"; shift ;;
        esac
    done

    if [[ -z "$symbol" ]]; then
        rqs_error "references: symbol argument required"
    fi

    # Find all occurrences, then filter out definition lines
    local def_pattern="(class|def|function|async function|const|let|var|interface|type|enum|struct)\s+${symbol}\b"

    local results
    results=$(cd "$RQS_TARGET_REPO" && rqs_list_files \
        | xargs grep -HnE "\b${symbol}\b" 2>/dev/null \
        | grep -vE "$def_pattern" \
        | head -n "$max_results" || true)

    echo "$results" | rqs_render references "$symbol"
}
