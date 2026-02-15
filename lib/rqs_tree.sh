#!/usr/bin/env bash
# rqs_tree.sh — filtered directory tree subcommand

cmd_tree() {
    local path="."
    local depth="$RQS_TREE_DEPTH"
    local -a extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth) depth="$2"; shift 2 ;;
            --budget) extra_args+=(--budget "$2"); shift 2 ;;
            --churn-data) extra_args+=(--churn-data "$2"); shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs tree [path] [--depth N] [--budget N] [--churn-data PATH]

Show a filtered directory tree of the repository.

Options:
  path              Subdirectory to root the tree at (default: repo root)
  --depth N         Maximum depth to display (default: from config)
  --budget N        Maximum output lines; prunes low-importance subtrees
  --churn-data PATH JSON file with per-file churn stats for importance scoring
  --help            Show this help
EOF
                return 0
                ;;
            -*) rqs_error "tree: unknown option '$1'" ;;
            *) path="$1"; shift ;;
        esac
    done

    rqs_list_files "$path" | rqs_render tree --depth "$depth" --root "$path" "${extra_args[@]}"
}
