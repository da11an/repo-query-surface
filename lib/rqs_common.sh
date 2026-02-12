#!/usr/bin/env bash
# rqs_common.sh — shared functions for repo-query-surface

set -euo pipefail

# ── Config Loading ──────────────────────────────────────────────────────────

rqs_build_ignore_regex() {
    local ignore_file="$RQS_CONF_DIR/ignore_patterns.conf"
    local patterns=()
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        patterns+=("$line")
    done < "$ignore_file"

    local IFS='|'
    RQS_IGNORE_REGEX="${patterns[*]}"
}

rqs_load_config() {
    # Layer 1: defaults
    # shellcheck source=../conf/defaults.conf
    source "$RQS_CONF_DIR/defaults.conf"

    # Layer 2: per-repo .rqsrc (if exists and valid)
    local rqsrc="$RQS_TARGET_REPO/.rqsrc"
    if [[ -f "$rqsrc" ]]; then
        rqs_validate_rqsrc "$rqsrc"
        # shellcheck source=/dev/null
        source "$rqsrc"
    fi

    # Build ignore regex
    rqs_build_ignore_regex
}

rqs_validate_rqsrc() {
    local rqsrc="$1"
    # Only allow simple KEY=VALUE lines (no commands, no subshells)
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # Skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Must be KEY=VALUE where KEY is uppercase/underscore, VALUE is quoted or simple
        if ! [[ "$line" =~ ^[[:space:]]*RQS_[A-Z_]+=[^\;]*$ ]]; then
            echo "error: invalid .rqsrc line $line_num: $line" >&2
            exit 1
        fi
        # Reject command substitution, subshells, backticks
        if [[ "$line" =~ [\$\`\(] ]]; then
            echo "error: .rqsrc line $line_num contains disallowed characters: $line" >&2
            exit 1
        fi
    done < "$rqsrc"
}

# ── File Listing ────────────────────────────────────────────────────────────

rqs_list_files() {
    local path="${1:-.}"
    (cd "$RQS_TARGET_REPO" && git ls-files -- "$path" 2>/dev/null) \
        | grep -vE "$RQS_IGNORE_REGEX" \
        | sort
}

rqs_is_text_file() {
    local filepath="$RQS_TARGET_REPO/$1"
    [[ -f "$filepath" ]] || return 1
    local mime
    mime=$(file --mime-type -b "$filepath" 2>/dev/null)
    [[ "$mime" == text/* || "$mime" == application/json || "$mime" == application/xml \
       || "$mime" == application/javascript || "$mime" == application/x-shellscript \
       || "$mime" == application/x-python ]]
}

# ── Path Resolution ────────────────────────────────────────────────────────

rqs_resolve_path() {
    local input="$1"
    local resolved

    # If absolute, use as-is; if relative, resolve from target repo
    if [[ "$input" = /* ]]; then
        resolved="$input"
    else
        resolved="$RQS_TARGET_REPO/$input"
    fi

    # Canonicalize (don't require existence with -m if available, fall back to -f)
    resolved=$(readlink -m "$resolved" 2>/dev/null || readlink -f "$resolved" 2>/dev/null || echo "$resolved")

    # Security: must be inside target repo
    local repo_real
    repo_real=$(readlink -f "$RQS_TARGET_REPO")
    if [[ "$resolved" != "$repo_real"* ]]; then
        echo "error: path '$input' resolves outside target repository" >&2
        return 1
    fi

    echo "$resolved"
}

rqs_relative_path() {
    local abs="$1"
    local repo_real
    repo_real=$(readlink -f "$RQS_TARGET_REPO")
    echo "${abs#"$repo_real"/}"
}

# ── ctags Integration ──────────────────────────────────────────────────────

rqs_has_ctags() {
    command -v ctags &>/dev/null && ctags --version 2>/dev/null | grep -qi "universal"
}

rqs_cache_dir() {
    echo "$RQS_TARGET_REPO/${RQS_CACHE_DIR:-.rqs_cache}"
}

rqs_cache_ctags() {
    local cache_dir
    cache_dir=$(rqs_cache_dir)

    local head_commit
    head_commit=$(cd "$RQS_TARGET_REPO" && git rev-parse HEAD 2>/dev/null || echo "unknown")

    local tags_file="$cache_dir/tags-$head_commit.json"

    if [[ -f "$tags_file" ]]; then
        echo "$tags_file"
        return 0
    fi

    if ! rqs_has_ctags; then
        return 1
    fi

    mkdir -p "$cache_dir"
    # Clean old cache files
    find "$cache_dir" -name 'tags-*.json' -not -name "tags-$head_commit.json" -delete 2>/dev/null || true

    # Generate tags
    (cd "$RQS_TARGET_REPO" && git ls-files | grep -vE "$RQS_IGNORE_REGEX" \
        | ctags --output-format=json --fields=+nKSse -L - -f - 2>/dev/null) \
        > "$tags_file"

    echo "$tags_file"
}

rqs_run_ctags_file() {
    local filepath="$1"
    if rqs_has_ctags; then
        (cd "$RQS_TARGET_REPO" && ctags --output-format=json --fields=+nKSse -f - "$filepath" 2>/dev/null)
    fi
}

# ── Rendering ───────────────────────────────────────────────────────────────

rqs_render() {
    local mode="$1"
    shift
    python3 "$RQS_LIB_DIR/render.py" "$mode" "$@"
}

# ── Error Handling ──────────────────────────────────────────────────────────

rqs_error() {
    echo "error: $*" >&2
    exit 1
}

rqs_warn() {
    echo "warning: $*" >&2
}
