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

    if echo "$output" | grep -qF -- "$expected"; then
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

    if ! echo "$output" | grep -qF -- "$unexpected"; then
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
    assert_contains "tree shows line counts" "$output" "main.py (34)"
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
    assert_contains "symbols has Lines column" "$output" "| Lines"
    assert_contains "symbols has Signature column" "$output" "| Signature"
    assert_contains "symbols shows line span" "$output" "8-24"
    assert_contains "symbols shows member" "$output" "Application.__init__"
    assert_contains "symbols shows signature" "$output" "(self, name)"
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
    assert_contains "outline shows signature" "$output" "__init__(self, name)"
    assert_contains "outline shows main signature" "$output" "main()"
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
    assert_contains "definition has Lines column" "$output" "| Lines"
    assert_contains "definition shows line span" "$output" "8-24"
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
    assert_contains "deps shows imported names" "$output" "format_output, validate_input"
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

    # Default (medium) includes orientation + onboarding maps + tree + symbols + summaries
    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" primer 2>&1)
    assert_contains "primer has repo name" "$output" "# Repository Primer"
    assert_contains "primer has prompt orientation" "$output" "# Repository Context Instructions"
    assert_contains "primer has orientation" "$output" "## Orientation"
    assert_contains "primer has runtime boundaries" "$output" "## Runtime Boundaries"
    assert_contains "primer has behavioral contract" "$output" "## Behavioral Contract (Tests)"
    assert_contains "primer has critical path in orientation" "$output" "Critical path (ranked)"
    assert_contains "primer has tree" "$output" "## Tree"
    assert_contains "primer has symbols" "$output" "## Symbols"
    assert_contains "primer has module summaries" "$output" "## Module Summaries"
    assert_contains "primer summaries have symbols" "$output" "Application"
    assert_not_contains "primer default has no task" "$output" "## Task:"
    assert_not_contains "primer default no signatures" "$output" "## Signatures"
    assert_not_contains "primer default no deps" "$output" "## Internal Dependencies"
    assert_not_contains "primer default no critical path section" "$output" "## Critical Path Files"

    # Light: prompt + header + fast-start + boundaries + tree, no medium/heavy sections
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --light 2>&1)
    assert_contains "primer light has prompt" "$output" "# Repository Context Instructions"
    assert_contains "primer light has repo name" "$output" "# Repository Primer"
    assert_contains "primer light has orientation" "$output" "## Orientation"
    assert_contains "primer light has runtime boundaries" "$output" "## Runtime Boundaries"
    assert_contains "primer light has tree" "$output" "## Tree"
    assert_not_contains "primer light no behavioral contract" "$output" "## Behavioral Contract (Tests)"
    assert_not_contains "primer light no critical path" "$output" "## Critical Path Files"
    assert_not_contains "primer light no symbols" "$output" "## Symbols"
    assert_not_contains "primer light no summaries" "$output" "## Module Summaries"

    # Heavy: everything including signatures + deps + heuristic hotspots
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --heavy 2>&1)
    assert_contains "primer heavy has prompt" "$output" "# Repository Context Instructions"
    assert_contains "primer heavy has orientation" "$output" "## Orientation"
    assert_contains "primer heavy has runtime boundaries" "$output" "## Runtime Boundaries"
    assert_contains "primer heavy has behavioral contract" "$output" "## Behavioral Contract (Tests)"
    assert_not_contains "primer heavy no separate critical path" "$output" "## Critical Path Files"
    assert_contains "primer heavy has critical path in orientation" "$output" "Critical path (ranked)"
    assert_contains "primer heavy has tree" "$output" "## Tree"
    assert_contains "primer heavy has symbol map" "$output" "## Symbol Map"
    assert_not_contains "primer heavy no separate symbols" "$output" "## Symbols"
    assert_not_contains "primer heavy no separate signatures" "$output" "## Signatures"
    assert_contains "primer heavy has deps" "$output" "## Internal Dependencies"
    assert_contains "primer heavy has import topology" "$output" "## Import Topology"
    assert_contains "primer heavy topology key files" "$output" "### Key Files"
    assert_contains "primer heavy topology layers" "$output" "### Layer Map (Foundation -> Orchestration)"
    assert_contains "primer heavy topology edge table" "$output" "| Importer | Imported | Layer Drop | Score |"
    assert_contains "primer heavy has churn" "$output" "## Churn"
    assert_contains "primer heavy has hotspots" "$output" "## Heuristic Risk Hotspots"

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
    assert_contains "help lists show" "$output" "show"
    assert_contains "help lists context" "$output" "context"
    assert_contains "help lists diff" "$output" "diff"
    assert_contains "help lists files" "$output" "files"
    assert_contains "help lists callees" "$output" "callees"
    assert_contains "help lists related" "$output" "related"
    assert_contains "help lists churn" "$output" "churn"
    assert_contains "help lists notebook" "$output" "notebook"

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
    local status
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

    # Whole repo — includes non-Python via ctags
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures 2>&1)
    assert_contains "signatures whole repo has python" "$output" '### `src/main.py`'
    assert_contains "signatures whole repo has shell" "$output" '### `lib/config.sh`'
    assert_contains "signatures shell shows function" "$output" "load_config"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures --help 2>&1)
    assert_contains "signatures help" "$output" "Usage: rqs signatures"

    # Regression: piped output should exit cleanly when consumer closes early
    set +e
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures 2>&1 | head -n 5)
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: signatures piped output exits cleanly"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: signatures piped output exits cleanly\n    expected exit code 0, got $status"
        echo "  FAIL: signatures piped output exits cleanly"
    fi
    assert_not_contains "signatures piped has no BrokenPipeError" "$output" "BrokenPipeError"
    assert_not_contains "signatures piped has no traceback" "$output" "Traceback (most recent call last)"
}

# ── Test: Show ─────────────────────────────────────────────────────────────

test_show() {
    echo "Testing: show"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" show Application 2>&1)
    assert_contains "show header" "$output" "## Show:"
    assert_contains "show has class name" "$output" "Application"
    assert_contains "show has file path" "$output" "src/main.py"
    assert_contains "show has kind" "$output" "class"
    assert_contains "show has line range" "$output" "lines 8-24"
    assert_contains "show has class body" "$output" "def start(self):"
    assert_contains "show has python fence" "$output" '```python'

    # Multiple symbols
    output=$("$RQS" --repo "$FIXTURE_DIR" show Application format_output 2>&1)
    assert_contains "show multi has Application" "$output" "## Show: \`Application\`"
    assert_contains "show multi has format_output" "$output" "## Show: \`format_output\`"
    assert_contains "show multi format_output body" "$output" "[OUTPUT]"

    # Nonexistent symbol
    output=$("$RQS" --repo "$FIXTURE_DIR" show NonexistentSymbol12345 2>&1)
    assert_contains "show missing symbol" "$output" "no definition found"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" show --help 2>&1)
    assert_contains "show help" "$output" "Usage: rqs show"

    # Error: no args
    assert_exit_code "show no args" 1 "$RQS" --repo "$FIXTURE_DIR" show
}

# ── Test: Context ──────────────────────────────────────────────────────────

test_context() {
    echo "Testing: context"

    local output
    # Line 17 is inside Application.start()
    output=$("$RQS" --repo "$FIXTURE_DIR" context src/main.py 17 2>&1)
    assert_contains "context header" "$output" "## Context:"
    assert_contains "context shows enclosing symbol" "$output" "start"
    assert_contains "context shows file:line" "$output" "src/main.py:17"
    assert_contains "context has code" "$output" "validate_input"
    assert_contains "context has python fence" "$output" '```python'

    # Line 12 is inside Application.__init__
    output=$("$RQS" --repo "$FIXTURE_DIR" context src/main.py 12 2>&1)
    assert_contains "context __init__ enclosing" "$output" "__init__"
    assert_contains "context __init__ body" "$output" "self.name = name"

    # Line 9 is inside Application class (docstring line)
    output=$("$RQS" --repo "$FIXTURE_DIR" context src/main.py 9 2>&1)
    assert_contains "context class level" "$output" "Application"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" context --help 2>&1)
    assert_contains "context help" "$output" "Usage: rqs context"

    # Error: missing args
    assert_exit_code "context no args" 1 "$RQS" --repo "$FIXTURE_DIR" context
    assert_exit_code "context missing line" 1 "$RQS" --repo "$FIXTURE_DIR" context src/main.py
}

# ── Test: Diff ─────────────────────────────────────────────────────────────

test_diff() {
    echo "Testing: diff"

    # Fixture repo should be clean — no changes
    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" diff 2>&1)
    assert_contains "diff no changes" "$output" "no differences"

    # Diff against HEAD (also no changes)
    output=$("$RQS" --repo "$FIXTURE_DIR" diff HEAD 2>&1)
    assert_contains "diff HEAD no changes" "$output" "no differences"

    # Create a change, test diff, then revert
    echo "# temporary" >> "$FIXTURE_DIR/src/main.py"
    output=$("$RQS" --repo "$FIXTURE_DIR" diff 2>&1)
    assert_contains "diff header" "$output" "## Diff"
    assert_contains "diff has code fence" "$output" '```diff'
    assert_contains "diff shows change" "$output" "temporary"
    assert_contains "diff has stats" "$output" "files"
    # Revert
    (cd "$FIXTURE_DIR" && git checkout -- src/main.py)

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" diff --help 2>&1)
    assert_contains "diff help" "$output" "Usage: rqs diff"
}

# ── Test: Files ────────────────────────────────────────────────────────────

test_files() {
    echo "Testing: files"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" files "*.py" 2>&1)
    assert_contains "files header" "$output" "## Files:"
    assert_contains "files shows pattern" "$output" '`*.py`'
    assert_contains "files shows main.py" "$output" "src/main.py"
    assert_contains "files shows helpers.py" "$output" "src/utils/helpers.py"
    assert_contains "files has line counts" "$output" "lines"
    assert_contains "files has file count" "$output" "3 files"

    # Glob for shell files
    output=$("$RQS" --repo "$FIXTURE_DIR" files "*.sh" 2>&1)
    assert_contains "files sh shows config" "$output" "lib/config.sh"

    # No matches
    output=$("$RQS" --repo "$FIXTURE_DIR" files "*.xyz" 2>&1)
    assert_contains "files no matches" "$output" "no files matching"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" files --help 2>&1)
    assert_contains "files help" "$output" "Usage: rqs files"

    # Error: no args
    assert_exit_code "files no args" 1 "$RQS" --repo "$FIXTURE_DIR" files
}

# ── Test: Callees ──────────────────────────────────────────────────────────

test_callees() {
    echo "Testing: callees"

    local output
    # start() calls validate_input and format_output
    output=$("$RQS" --repo "$FIXTURE_DIR" callees start 2>&1)
    assert_contains "callees header" "$output" "## Callees:"
    assert_contains "callees shows start" "$output" "start"
    assert_contains "callees finds validate_input" "$output" "validate_input"
    assert_contains "callees finds format_output" "$output" "format_output"
    assert_contains "callees has table" "$output" "| Called Symbol"

    # main() calls Application and start
    output=$("$RQS" --repo "$FIXTURE_DIR" callees main 2>&1)
    assert_contains "callees main finds Application" "$output" "Application"
    assert_contains "callees main finds start" "$output" "start"

    # Nonexistent symbol
    output=$("$RQS" --repo "$FIXTURE_DIR" callees NonexistentFunc123 2>&1)
    assert_contains "callees missing symbol" "$output" "no definition found"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" callees --help 2>&1)
    assert_contains "callees help" "$output" "Usage: rqs callees"

    # Error: no args
    assert_exit_code "callees no args" 1 "$RQS" --repo "$FIXTURE_DIR" callees
}

# ── Test: Related ──────────────────────────────────────────────────────────

test_related() {
    echo "Testing: related"

    local output
    # main.py imports helpers.py
    output=$("$RQS" --repo "$FIXTURE_DIR" related src/main.py 2>&1)
    assert_contains "related header" "$output" "## Related:"
    assert_contains "related shows forward dep" "$output" "src/utils/helpers.py"
    assert_contains "related has imports section" "$output" "Imports"

    # helpers.py is imported by main.py
    output=$("$RQS" --repo "$FIXTURE_DIR" related src/utils/helpers.py 2>&1)
    assert_contains "related reverse dep" "$output" "src/main.py"
    assert_contains "related has imported by section" "$output" "Imported by"
    assert_contains "related has line counts" "$output" "lines"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" related --help 2>&1)
    assert_contains "related help" "$output" "Usage: rqs related"

    # Error: no args
    assert_exit_code "related no args" 1 "$RQS" --repo "$FIXTURE_DIR" related
    assert_exit_code "related nonexistent" 1 "$RQS" --repo "$FIXTURE_DIR" related nonexistent.py
}

# ── Test: Churn ─────────────────────────────────────────────────────────────

test_churn() {
    echo "Testing: churn"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" churn 2>&1)
    assert_contains "churn header" "$output" "## Churn"
    assert_contains "churn has description" "$output" "Lines = total lines added + deleted"
    assert_contains "churn shows file" "$output" "src/main.py"
    assert_contains "churn has table header" "$output" "| Commits"
    assert_contains "churn has author activity section" "$output" "### Author Activity"
    assert_contains "churn has author activity header" "$output" "| Author"

    # With options
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --top 2 2>&1)
    assert_contains "churn top-2 header" "$output" "## Churn"

    # --include filter
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --include "src/*" 2>&1)
    assert_contains "churn include has header" "$output" "## Churn"
    assert_contains "churn include shows src file" "$output" "src/main.py"
    assert_not_contains "churn include excludes lib" "$output" "lib/config.sh"
    assert_contains "churn include filter note" "$output" "include: src/*"

    # --exclude filter
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --exclude "*.py" 2>&1)
    assert_contains "churn exclude has header" "$output" "## Churn"
    assert_not_contains "churn exclude hides py files" "$output" "main.py"
    assert_contains "churn exclude filter note" "$output" "exclude: *.py"

    # --author filter (use git user.name from the fixture commit)
    local fixture_author
    fixture_author=$(cd "$FIXTURE_DIR" && git log --format="%an" -1)
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --author "$fixture_author" 2>&1)
    assert_contains "churn author has header" "$output" "## Churn"
    assert_contains "churn author filter note" "$output" "authors:"

    # --author no match
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --author "nonexistent_author_xyz" 2>&1)
    assert_contains "churn author no match" "$output" "no commits match"

    # --sort commits
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --sort commits 2>&1)
    assert_contains "churn sort commits header" "$output" "## Churn"
    assert_contains "churn sort commits note" "$output" "sorted by commit count"

    # --sort init
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --sort init 2>&1)
    assert_contains "churn sort init header" "$output" "## Churn"
    assert_contains "churn sort init note" "$output" "sorted by first appearance"

    # --sort lines (default, should not show sort note)
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --sort lines 2>&1)
    assert_contains "churn sort lines header" "$output" "## Churn"
    assert_not_contains "churn sort lines no sort note" "$output" "sorted by"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --help 2>&1)
    assert_contains "churn help" "$output" "Usage: rqs churn"
    assert_contains "churn help include" "$output" "--include"
    assert_contains "churn help exclude" "$output" "--exclude"
    assert_contains "churn help author" "$output" "--author"
    assert_contains "churn help sort" "$output" "--sort"
}

# ── Test: Notebook ──────────────────────────────────────────────────────────

test_notebook() {
    echo "Testing: notebook"

    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" notebook notebooks/analysis.ipynb 2>&1)

    # Header
    assert_contains "notebook header" "$output" "## Notebook:"
    assert_contains "notebook filename" "$output" "analysis.ipynb"
    assert_contains "notebook cell count" "$output" "6 cells"
    assert_contains "notebook kernel" "$output" "python3"

    # Markdown cell
    assert_contains "notebook markdown cell" "$output" "Cell 1"
    assert_contains "notebook markdown content" "$output" "Sample Analysis"
    assert_contains "notebook markdown body" "$output" "data processing"

    # Code cell with output
    assert_contains "notebook code cell" "$output" "Cell 2"
    assert_contains "notebook code fence" "$output" '```python'
    assert_contains "notebook code source" "$output" "import pandas"
    assert_contains "notebook output truncated" "$output" "truncated from 14"
    assert_contains "notebook output content" "$output" "col1"

    # Code cell with error
    assert_contains "notebook error cell" "$output" "Cell 3"
    assert_contains "notebook error ename" "$output" "AttributeError"
    assert_contains "notebook error evalue" "$output" "invalid_method"

    # Code cell with no output (empty outputs array)
    assert_contains "notebook empty output cell" "$output" "Cell 4"
    assert_contains "notebook empty output source" "$output" "x = 42"

    # Code cell with image output
    assert_contains "notebook image placeholder" "$output" "[image/png output]"
    assert_contains "notebook plot source" "$output" "plt.plot"

    # Raw cell
    assert_contains "notebook raw cell" "$output" "raw"
    assert_contains "notebook raw content" "$output" "Raw cell content"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" notebook --help 2>&1)
    assert_contains "notebook help" "$output" "Usage: rqs notebook"

    # Error: no args
    assert_exit_code "notebook no args" 1 "$RQS" --repo "$FIXTURE_DIR" notebook

    # Error: wrong extension
    assert_exit_code "notebook wrong extension" 1 "$RQS" --repo "$FIXTURE_DIR" notebook src/main.py

    # Error: nonexistent file
    assert_exit_code "notebook nonexistent" 1 "$RQS" --repo "$FIXTURE_DIR" notebook nonexistent.ipynb
}

# ── Test: Notebook Debug ────────────────────────────────────────────────────

test_notebook_debug() {
    echo "Testing: notebook --debug"

    local output

    # ── Debug test notebook with repo-local error ──
    output=$("$RQS" --repo "$FIXTURE_DIR" notebook notebooks/debug_test.ipynb --debug 2>&1)

    # Header and error count
    assert_contains "debug header" "$output" "## Notebook Debug:"
    assert_contains "debug filename" "$output" "debug_test.ipynb"
    assert_contains "debug error count" "$output" "2 errors found"
    assert_contains "debug error names" "$output" "ValueError"
    assert_contains "debug error names 2" "$output" "ZeroDivisionError"

    # Error summary
    assert_contains "debug ValueError summary" "$output" "ValueError: Input must not be empty"
    assert_contains "debug ZeroDivision summary" "$output" "ZeroDivisionError: division by zero"

    # Frame classification
    assert_contains "debug notebook-local label" "$output" "notebook-local"
    assert_contains "debug repo-local label" "$output" "repo-local"

    # Repo file in traceback
    assert_contains "debug repo file path" "$output" "src/utils/helpers.py"

    # Enclosing function source with >>> marker
    assert_contains "debug error line marker" "$output" ">>>"
    assert_contains "debug enclosing function" "$output" "validate_input"

    # Dependency trace section
    assert_contains "debug dependency trace" "$output" "Dependency Trace"

    # Diagnostic summary
    assert_contains "debug diagnostic summary" "$output" "Diagnostic Summary"
    assert_contains "debug suggested commands" "$output" "Suggested commands"
    assert_contains "debug suggested rqs context" "$output" "rqs context"

    # ── Clean notebook (no errors) ──
    output=$("$RQS" --repo "$FIXTURE_DIR" notebook notebooks/clean.ipynb --debug 2>&1)
    assert_contains "debug no errors" "$output" "No errors found"

    # ── Error cases ──
    assert_exit_code "debug wrong extension" 1 "$RQS" --repo "$FIXTURE_DIR" notebook src/main.py --debug
    assert_exit_code "debug nonexistent" 1 "$RQS" --repo "$FIXTURE_DIR" notebook nonexistent.ipynb --debug

    # ── --debug in help text ──
    output=$("$RQS" --repo "$FIXTURE_DIR" notebook --help 2>&1)
    assert_contains "debug in help" "$output" "--debug"
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
test_show
echo ""
test_context
echo ""
test_diff
echo ""
test_files
echo ""
test_callees
echo ""
test_related
echo ""
test_churn
echo ""
test_notebook
echo ""
test_notebook_debug
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
