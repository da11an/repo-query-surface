#!/usr/bin/env bash
# rqs_diff.sh — structured git diff output

cmd_diff() {
    local ref=""
    local staged=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs diff [ref] [--staged]

Show git diff as structured markdown output.

Options:
  ref        Compare against a branch, tag, or commit (default: working tree changes)
  --staged   Show staged changes (git diff --cached)
  --help     Show this help

Examples:
  rqs diff                # Unstaged working tree changes
  rqs diff --staged       # Staged changes (ready to commit)
  rqs diff main           # Changes compared to main branch
  rqs diff HEAD~3         # Changes in last 3 commits
  rqs diff v1.0..v2.0     # Changes between two tags
EOF
                return 0
                ;;
            --staged|--cached) staged=true; shift ;;
            -*) rqs_error "diff: unknown option '$1'" ;;
            *) ref="$1"; shift ;;
        esac
    done

    local diff_args=()
    local display_ref=""

    if [[ -n "$ref" ]]; then
        diff_args+=("$ref")
        display_ref="$ref"
    elif [[ "$staged" == true ]]; then
        diff_args+=("--cached")
        display_ref="staged"
    fi

    # Run git diff from the repo root
    local diff_output
    diff_output=$(cd "$RQS_TARGET_REPO" && git diff "${diff_args[@]}" 2>&1) || true

    echo "$diff_output" | rqs_render diff "$display_ref"
}
