#!/usr/bin/env bash
# rqs_churn.sh — file modification heatmap

cmd_churn() {
    local rev_range=""
    local top_n="${RQS_CHURN_TOP_N}"
    local bucket="${RQS_CHURN_BUCKET:-auto}"
    local sort_arg=""
    local min_lines_arg=""
    local min_continuity_arg=""
    local -a include_args=()
    local -a exclude_args=()
    local -a author_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs churn [rev-range] [--top N] [--bucket N|auto] [--sort MODE]
                 [--min-lines N] [--min-continuity P]
                 [--include GLOB ...] [--exclude GLOB ...] [--author NAME ...]

File modification heatmap showing change intensity over time.

Options:
  rev-range            Git revision range (default: all history)
                       Examples: HEAD~50, v1.0..HEAD, main..feature
  --top N              Show top N files by total changes (default: 20)
  --bucket N           Commits per heatmap bucket (default: auto; targets ~50 buckets)
  --sort MODE          Sort order: lines (default), commits, or init (first appearance)
  --min-lines N        Only show files with at least N total lines changed
  --min-continuity P   Minimum continuity for sustained files (default: 0.25)
  --include GLOB       Only include files matching glob (repeatable)
  --exclude GLOB       Exclude files matching glob (repeatable)
  --author NAME        Only include commits by author (repeatable, case-insensitive substring)
  --help               Show this help

Examples:
  rqs churn                              # Full history, top 20 files
  rqs churn HEAD~50                      # Last 50 commits
  rqs churn --top 10                     # Top 10 most-changed files
  rqs churn --bucket auto                # Auto bucket sizing (~50 buckets target)
  rqs churn --bucket 20                  # Wider buckets (20 commits each)
  rqs churn v1.0..HEAD                   # Changes since v1.0
  rqs churn --sort init                  # Oldest files first (repo build-out order)
  rqs churn --sort commits               # Most-committed files first
  rqs churn --min-lines 100              # Only files with >= 100 lines changed
  rqs churn --include "src/*"            # Only files under src/
  rqs churn --exclude "*.md"             # Skip markdown files
  rqs churn --author alice --author bob  # Only commits by alice or bob
EOF
                return 0
                ;;
            --top) top_n="$2"; shift 2 ;;
            --bucket) bucket="$2"; shift 2 ;;
            --sort) sort_arg="$2"; shift 2 ;;
            --min-lines) min_lines_arg="$2"; shift 2 ;;
            --min-continuity) min_continuity_arg="$2"; shift 2 ;;
            --include) include_args+=(--include "$2"); shift 2 ;;
            --exclude) exclude_args+=(--exclude "$2"); shift 2 ;;
            --author) author_args+=(--author "$2"); shift 2 ;;
            -*) rqs_error "churn: unknown option '$1'" ;;
            *) rev_range="$1"; shift ;;
        esac
    done

    local log_args=("--pretty=format:COMMIT%x09%an" "--numstat")
    [[ -n "$rev_range" ]] && log_args+=("$rev_range")

    local log_output
    log_output=$(cd "$RQS_TARGET_REPO" && git log "${log_args[@]}" 2>&1) || true

    local -a sort_args=()
    [[ -n "$sort_arg" ]] && sort_args=(--sort "$sort_arg")
    local -a min_lines_args=()
    [[ -n "$min_lines_arg" ]] && min_lines_args=(--min-lines "$min_lines_arg")
    local -a min_cont_args=()
    [[ -n "$min_continuity_arg" ]] && min_cont_args=(--min-continuity "$min_continuity_arg")

    echo "$log_output" | rqs_render churn --top "$top_n" --bucket "$bucket" \
        "${sort_args[@]}" "${min_lines_args[@]}" "${min_cont_args[@]}" \
        "${include_args[@]}" "${exclude_args[@]}" "${author_args[@]}"
}
