#!/usr/bin/env bash
# run_tests.sh — test suite for repo-query-surface
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
RQS_ROOT="$(dirname "$SCRIPT_DIR")"
RQS="$RQS_ROOT/bin/rqs"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/sample-repo"

PASS=0
FAIL=0
ERRORS=""

# ── Fixture Setup ──────────────────────────────────────────────────────────

setup_fixture() {
    if [[ ! -d "$FIXTURE_DIR/.git" ]]; then
        (cd "$FIXTURE_DIR" && git init -q && git add -A && git commit -q -m "fixture")
    fi
}

cleanup_fixture() {
    rm -rf "$FIXTURE_DIR/.git" "$FIXTURE_DIR/.rqs_cache"
}

trap cleanup_fixture EXIT
setup_fixture

# ── Helpers ─────────────────────────────────────────────────────────────────

assert_contains() {
    local test_name="$1"
    local output="$2"
    local expected="$3"

    if echo "$output" | grep -qF "$expected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $test_name\n    expected to contain: $expected\n    got: $(echo "$output" | head -3)"
        echo "  FAIL: $test_name"
    fi
}

assert_not_contains() {
    local test_name="$1"
    local output="$2"
    local unexpected="$3"

    if ! echo "$output" | grep -qF "$unexpected"; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $test_name\n    expected NOT to contain: $unexpected"
        echo "  FAIL: $test_name"
    fi
}

assert_exit_code() {
    local test_name="$1"
    local expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?

    if [[ "$actual_code" -eq "$expected_code" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: $test_name"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: $test_name\n    expected exit code $expected_code, got $actual_code"
        echo "  FAIL: $test_name"
    fi
}

# ── Test: Tree ──────────────────────────────────────────────────────────────

test_tree() {
    echo "Testing: tree"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" tree)
    assert_contains "tree shows root" "$output" "## Tree"
    assert_contains "tree has description" "$output" "Filtered directory structure from git-tracked files"
    assert_contains "tree shows src dir" "$output" "src/"
    assert_contains "tree shows lib dir" "$output" "lib/"
    assert_contains "tree shows docs dir" "$output" "docs/"
    assert_contains "tree shows main.py" "$output" "main.py"
    assert_not_contains "tree excludes .git" "$output" ".git"

    # Test with depth
    output=$("$RQS" --repo "$FIXTURE_DIR" tree --depth 1)
    assert_contains "tree depth=1 shows dirs" "$output" "src/"
    assert_not_contains "tree depth=1 hides deep files" "$output" "helpers.py"

    # Test with subpath
    output=$("$RQS" --repo "$FIXTURE_DIR" tree src/)
    assert_contains "tree subpath shows main" "$output" "main.py"
    assert_contains "tree subpath shows utils" "$output" "utils/"
}

# ── Test: Symbols ───────────────────────────────────────────────────────────

test_symbols() {
    echo "Testing: symbols"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" symbols src/main.py 2>&1)
    assert_contains "symbols shows Application class" "$output" "Application"
    assert_contains "symbols shows main function" "$output" "main"
    assert_contains "symbols header" "$output" "## Symbols"
    assert_contains "symbols has description" "$output" "Symbol index extracted via ctags"
}

# ── Test: Outline ───────────────────────────────────────────────────────────

test_outline() {
    echo "Testing: outline"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" outline src/main.py 2>&1)
    assert_contains "outline header" "$output" "## Outline"
    assert_contains "outline has description" "$output" "Structural hierarchy of symbols"
    assert_contains "outline shows Application" "$output" "Application"
    assert_contains "outline shows start method" "$output" "start"
    assert_contains "outline shows stop method" "$output" "stop"
}

# ── Test: Slice ─────────────────────────────────────────────────────────────

test_slice() {
    echo "Testing: slice"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" slice src/main.py 1 5)
    assert_contains "slice header" "$output" "## Slice"
    assert_contains "slice has line range" "$output" "(lines 1-5)"
    assert_contains "slice has description" "$output" "Code extract with line numbers"
    assert_contains "slice has python fence" "$output" '```python'
    assert_contains "slice shows docstring" "$output" "Main entry point"
    assert_contains "slice has line numbers" "$output" "1:"

    # Error cases
    assert_exit_code "slice rejects missing args" 1 "$RQS" --repo "$FIXTURE_DIR" slice src/main.py 1
    assert_exit_code "slice rejects bad range" 1 "$RQS" --repo "$FIXTURE_DIR" slice src/main.py 10 5
}

# ── Test: Definition ───────────────────────────────────────────────────────

test_definition() {
    echo "Testing: definition"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" definition Application 2>&1)
    assert_contains "definition finds class" "$output" "src/main.py"
    assert_contains "definition header" "$output" "## Definition"
    assert_contains "definition has description" "$output" "Source locations where this symbol is defined"
}

# ── Test: References ───────────────────────────────────────────────────────

test_references() {
    echo "Testing: references"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" references format_output 2>&1)
    assert_contains "references header" "$output" "## References"
    assert_contains "references has description" "$output" "Call sites and usage"
    assert_contains "references finds usage in main.py" "$output" "main.py"
}

# ── Test: Deps ──────────────────────────────────────────────────────────────

test_deps() {
    echo "Testing: deps"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" deps src/main.py 2>&1)
    assert_contains "deps header" "$output" "## Dependencies"
    assert_contains "deps has description" "$output" "Import analysis"
    assert_contains "deps shows external os" "$output" "os"
    assert_contains "deps shows external sys" "$output" "sys"
}

# ── Test: Grep ──────────────────────────────────────────────────────────────

test_grep() {
    echo "Testing: grep"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" grep "def " 2>&1)
    assert_contains "grep header" "$output" '## Grep: `def `'
    assert_contains "grep has description" "$output" "Regex search results across git-tracked files"
    assert_contains "grep finds functions" "$output" "def "

    output=$("$RQS" --repo "$FIXTURE_DIR" grep "class Application" 2>&1)
    assert_contains "grep finds class" "$output" "Application"

    output=$("$RQS" --repo "$FIXTURE_DIR" grep "NONEXISTENT_PATTERN_12345" 2>&1)
    assert_contains "grep no matches" "$output" "no matches"
}

# ── Test: Primer ────────────────────────────────────────────────────────────

test_primer() {
    echo "Testing: primer"

    # Default (medium) includes prompt + header + tree + symbols + summaries
    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" primer 2>&1)
    assert_contains "primer has repo name" "$output" "# Repository Primer"
    assert_contains "primer has prompt orientation" "$output" "# Repository Context Instructions"
    assert_contains "primer has tree" "$output" "## Tree"
    assert_contains "primer has symbols" "$output" "## Symbols"
    assert_contains "primer has module summaries" "$output" "## Module Summaries"
    assert_not_contains "primer default has no task" "$output" "## Task:"
    assert_not_contains "primer default no signatures" "$output" "## Signatures"
    assert_not_contains "primer default no deps" "$output" "## Internal Dependencies"

    # Light: prompt + header + tree, no symbols or summaries
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --light 2>&1)
    assert_contains "primer light has prompt" "$output" "# Repository Context Instructions"
    assert_contains "primer light has repo name" "$output" "# Repository Primer"
    assert_contains "primer light has tree" "$output" "## Tree"
    assert_not_contains "primer light no symbols" "$output" "## Symbols"
    assert_not_contains "primer light no summaries" "$output" "## Module Summaries"

    # Heavy: everything including signatures + deps
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --heavy 2>&1)
    assert_contains "primer heavy has prompt" "$output" "# Repository Context Instructions"
    assert_contains "primer heavy has tree" "$output" "## Tree"
    assert_contains "primer heavy has symbols" "$output" "## Symbols"
    assert_contains "primer heavy has signatures" "$output" "## Signatures"
    assert_contains "primer heavy has deps" "$output" "## Internal Dependencies"

    # Task flag
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --task debug 2>&1)
    assert_contains "primer task debug" "$output" "## Task: Debug"
    assert_contains "primer task debug has prompt" "$output" "# Repository Context Instructions"

    # Light + task
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --light --task review 2>&1)
    assert_contains "primer light+task has review" "$output" "## Task: Code Review"
    assert_contains "primer light+task has tree" "$output" "## Tree"
    assert_not_contains "primer light+task no symbols" "$output" "## Symbols"
}

# ── Test: Help ──────────────────────────────────────────────────────────────

test_help() {
    echo "Testing: help"

    local output
    output=$("$RQS" --help)
    assert_contains "help shows usage" "$output" "Usage:"
    assert_contains "help lists tree" "$output" "tree"
    assert_contains "help lists symbols" "$output" "symbols"
    assert_contains "help lists primer" "$output" "primer"
    assert_contains "help lists prompt" "$output" "prompt"

    # Subcommand help
    output=$("$RQS" --repo "$FIXTURE_DIR" tree --help)
    assert_contains "tree --help" "$output" "Usage: rqs tree"

    output=$("$RQS" --repo "$FIXTURE_DIR" slice --help)
    assert_contains "slice --help" "$output" "Usage: rqs slice"
}

# ── Test: Prompt ───────────────────────────────────────────────────────────

test_prompt() {
    echo "Testing: prompt"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" prompt)
    assert_contains "prompt has orientation header" "$output" "# Repository Context Instructions"
    assert_contains "prompt has how to read" "$output" "## How to Read the Context"
    assert_contains "prompt has how to request" "$output" "## How to Request More Context"
    assert_contains "prompt has command table" "$output" "rqs slice"
    assert_not_contains "prompt general has no task" "$output" "## Task:"

    # Task variants
    output=$("$RQS" --repo "$FIXTURE_DIR" prompt debug)
    assert_contains "prompt debug has task section" "$output" "## Task: Debug"
    assert_contains "prompt debug has orientation" "$output" "# Repository Context Instructions"

    output=$("$RQS" --repo "$FIXTURE_DIR" prompt feature)
    assert_contains "prompt feature has task section" "$output" "## Task: Feature Design"

    output=$("$RQS" --repo "$FIXTURE_DIR" prompt review)
    assert_contains "prompt review has task section" "$output" "## Task: Code Review"

    output=$("$RQS" --repo "$FIXTURE_DIR" prompt explain)
    assert_contains "prompt explain has task section" "$output" "## Task: Code Explanation"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" prompt --help)
    assert_contains "prompt help" "$output" "Usage: rqs prompt"

    # Error: unknown task
    assert_exit_code "prompt unknown task" 1 "$RQS" --repo "$FIXTURE_DIR" prompt bogus
}

# ── Test: Signatures ────────────────────────────────────────────────────────

test_signatures() {
    echo "Testing: signatures"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures src/main.py 2>&1)
    assert_contains "signatures header" "$output" "## Signatures"
    assert_contains "signatures has description" "$output" "Behavioral sketch"
    assert_contains "signatures shows class" "$output" "class Application:"
    assert_contains "signatures shows method" "$output" "def start(self):"
    assert_contains "signatures shows __init__" "$output" "def __init__(self, name):"
    assert_contains "signatures shows docstring" "$output" "# Start the application."
    assert_contains "signatures shows return" "$output" "return format_output"
    assert_not_contains "signatures hides implementation" "$output" "self.running = False"
    assert_not_contains "signatures hides assignment" "$output" "self.running = True"

    # Directory mode
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures src/ 2>&1)
    assert_contains "signatures dir has main.py" "$output" '### `src/main.py`'
    assert_contains "signatures dir has helpers.py" "$output" '### `src/utils/helpers.py`'
    assert_contains "signatures dir has format_output" "$output" "def format_output"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures --help 2>&1)
    assert_contains "signatures help" "$output" "Usage: rqs signatures"
}

# ── Test: Error Handling ────────────────────────────────────────────────────

test_errors() {
    echo "Testing: error handling"

    assert_exit_code "no command" 1 "$RQS" --repo "$FIXTURE_DIR"
    assert_exit_code "unknown command" 1 "$RQS" --repo "$FIXTURE_DIR" foobar
    assert_exit_code "outline missing file" 1 "$RQS" --repo "$FIXTURE_DIR" outline
    assert_exit_code "outline nonexistent file" 1 "$RQS" --repo "$FIXTURE_DIR" outline nonexistent.py
    assert_exit_code "definition missing symbol" 1 "$RQS" --repo "$FIXTURE_DIR" definition
    assert_exit_code "slice missing args" 1 "$RQS" --repo "$FIXTURE_DIR" slice
}

# ── Run All Tests ───────────────────────────────────────────────────────────

echo "═══════════════════════════════════════"
echo " repo-query-surface test suite"
echo "═══════════════════════════════════════"
echo ""

test_help
echo ""
test_tree
echo ""
test_symbols
echo ""
test_outline
echo ""
test_signatures
echo ""
test_slice
echo ""
test_definition
echo ""
test_references
echo ""
test_deps
echo ""
test_grep
echo ""
test_primer
echo ""
test_prompt
echo ""
test_errors

echo ""
echo "═══════════════════════════════════════"
echo " Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
fi
