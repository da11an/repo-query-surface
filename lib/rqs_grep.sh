#!/usr/bin/env bash
# rqs_grep.sh — structured regex search with context

cmd_grep() {
    local pattern=""
    local scope="."
    local context="$RQS_GREP_CONTEXT"
    local max_results="$RQS_GREP_MAX_RESULTS"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --scope) scope="$2"; shift 2 ;;
            --context|-C) context="$2"; shift 2 ;;
            --max) max_results="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs grep <pattern> [--scope dir] [--context N] [--max N]

Structured regex search across repository files.

Options:
  pattern       Extended regex pattern to search for
  --scope dir   Limit search to a subdirectory
  --context N   Lines of context around matches (default: from config)
  --max N       Maximum number of matches (default: from config)
  --help        Show this help
EOF
                return 0
                ;;
            -*) rqs_error "grep: unknown option '$1'" ;;
            *)
                if [[ -z "$pattern" ]]; then
                    pattern="$1"
                else
                    rqs_error "grep: unexpected argument '$1'"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$pattern" ]]; then
        rqs_error "grep: pattern argument required"
    fi

    # Get file list and search
    local results
    results=$(cd "$RQS_TARGET_REPO" && rqs_list_files "$scope" \
        | xargs grep -HnE -C "$context" -- "$pattern" 2>/dev/null \
        | head -n "$((max_results * (1 + 2 * context + 1)))" || true)

    echo "$results" | rqs_render grep "$pattern"
}
