#!/usr/bin/env bash
# rqs_churn.sh — file modification heatmap

cmd_churn() {
    local rev_range=""
    local top_n="${RQS_CHURN_TOP_N}"
    local bucket="${RQS_CHURN_BUCKET:-auto}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs churn [rev-range] [--top N] [--bucket N|auto]

File modification heatmap showing change intensity over time.

Options:
  rev-range    Git revision range (default: all history)
               Examples: HEAD~50, v1.0..HEAD, main..feature
  --top N      Show top N files by total changes (default: 20)
  --bucket N   Commits per heatmap bucket (default: auto; targets ~50 buckets)
  --help       Show this help

Examples:
  rqs churn                  # Full history, top 20 files
  rqs churn HEAD~50          # Last 50 commits
  rqs churn --top 10         # Top 10 most-changed files
  rqs churn --bucket auto    # Auto bucket sizing (~50 buckets target)
  rqs churn --bucket 20      # Wider buckets (20 commits each)
  rqs churn v1.0..HEAD       # Changes since v1.0
EOF
                return 0
                ;;
            --top) top_n="$2"; shift 2 ;;
            --bucket) bucket="$2"; shift 2 ;;
            -*) rqs_error "churn: unknown option '$1'" ;;
            *) rev_range="$1"; shift ;;
        esac
    done

    local log_args=("--pretty=format:COMMIT" "--numstat")
    [[ -n "$rev_range" ]] && log_args+=("$rev_range")

    local log_output
    log_output=$(cd "$RQS_TARGET_REPO" && git log "${log_args[@]}" 2>&1) || true

    echo "$log_output" | rqs_render churn --top "$top_n" --bucket "$bucket"
}
