#!/usr/bin/env bash
# rqs_tree.sh — filtered directory tree subcommand

cmd_tree() {
    local path="."
    local depth="$RQS_TREE_DEPTH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --depth) depth="$2"; shift 2 ;;
            --help)
                cat <<'EOF'
Usage: rqs tree [path] [--depth N]

Show a filtered directory tree of the repository.

Options:
  path        Subdirectory to root the tree at (default: repo root)
  --depth N   Maximum depth to display (default: from config)
  --help      Show this help
EOF
                return 0
                ;;
            -*) rqs_error "tree: unknown option '$1'" ;;
            *) path="$1"; shift ;;
        esac
    done

    rqs_list_files "$path" | rqs_render tree --depth "$depth" --root "$path"
}
