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

    # ── Budgeted tree tests ──

    # --budget header
    output=$("$RQS" --repo "$FIXTURE_DIR" tree --budget 10)
    assert_contains "tree budget header" "$output" "budget: 10 lines"

    # Small budget shows collapsed dir annotation
    output=$("$RQS" --repo "$FIXTURE_DIR" tree --budget 5)
    # With a small budget, at least some dirs should be collapsed with file count
    # The fixture has nested dirs, so at budget 5 some should show "(N files)"
    local has_annotation
    has_annotation=$(echo "$output" | grep -c "files)" || true)
    if [[ "$has_annotation" -gt 0 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: tree budget=5 has collapsed annotation"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: tree budget=5 has collapsed annotation\n    expected collapsed dir with (N files)"
        echo "  FAIL: tree budget=5 has collapsed annotation"
    fi

    # No --budget → backward compatible (no "budget:" in output)
    output=$("$RQS" --repo "$FIXTURE_DIR" tree)
    assert_not_contains "tree no-budget backward compat" "$output" "budget:"

    # ── Churn-data integration test ──
    local churn_tmpfile
    churn_tmpfile=$(mktemp)
    # Write synthetic churn JSON
    cat > "$churn_tmpfile" <<'CHURN_JSON'
{"src/main.py": {"commits": 100, "lines": 5000}, "src/utils/helpers.py": {"commits": 50, "lines": 2000}}
CHURN_JSON
    output=$("$RQS" --repo "$FIXTURE_DIR" tree --budget 8 --churn-data "$churn_tmpfile")
    assert_contains "tree churn-data header" "$output" "churn-informed"
    rm -f "$churn_tmpfile"

    # ── Overflow test: repo with many files ──
    local overflow_dir
    overflow_dir=$(mktemp -d)
    (
        cd "$overflow_dir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Tester"
        for d in alpha bravo charlie delta echo foxtrot; do
            mkdir -p "$d"
            for n in $(seq 1 6); do
                echo "line" > "$d/file${n}.txt"
            done
        done
        git add -A && git commit -q -m "init"
    ) >/dev/null 2>&1
    output=$("$RQS" --repo "$overflow_dir" tree --budget 10)
    assert_contains "tree overflow has collapsed dirs" "$output" "files)"
    # Count tree body lines (between ``` markers)
    local tree_lines
    tree_lines=$(echo "$output" | sed -n '/^```$/,/^```$/p' | grep -v '^```$' | wc -l)
    if [[ "$tree_lines" -le 12 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: tree overflow line count within budget ($tree_lines lines)"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: tree overflow line count within budget\n    expected <= 12 lines, got $tree_lines"
        echo "  FAIL: tree overflow line count within budget ($tree_lines lines)"
    fi
    rm -rf "$overflow_dir"
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

    # Default primer includes all sections
    local output
    output=$("$RQS" --repo "$FIXTURE_DIR" primer 2>&1)
    assert_contains "primer has repo name" "$output" "# Repository Primer"
    assert_contains "primer has prompt orientation" "$output" "# Repository Context Instructions"
    assert_contains "primer has orientation" "$output" "## Orientation"
    assert_contains "primer has runtime boundaries" "$output" "## Runtime Boundaries"
    assert_contains "primer has behavioral contract" "$output" "## Behavioral Contract (Tests)"
    assert_contains "primer has critical path in orientation" "$output" "Critical path (ranked)"
    assert_contains "primer has tree" "$output" "## Tree"
    assert_contains "primer has churn" "$output" "## Churn"
    assert_contains "primer has symbol map" "$output" "## Symbol Map"
    assert_contains "primer has module summaries" "$output" "## Module Summaries"
    assert_contains "primer summaries have symbols" "$output" "Application"
    assert_contains "primer has deps" "$output" "## Internal Dependencies"
    assert_contains "primer has import topology" "$output" "## Import Topology"
    assert_contains "primer topology key files" "$output" "### Key Files"
    assert_contains "primer topology layers" "$output" "### Layer Map (Foundation -> Orchestration)"
    assert_contains "primer topology edge table" "$output" "| Importer | Imported | Layer Drop | Score |"
    assert_contains "primer has hotspots" "$output" "## Heuristic Risk Hotspots"
    assert_not_contains "primer has no task by default" "$output" "## Task:"
    assert_not_contains "primer no separate critical path section" "$output" "## Critical Path Files"
    assert_not_contains "primer no separate symbols" "$output" "## Symbols"
    assert_not_contains "primer no separate signatures" "$output" "## Signatures"

    # ── Churn before tree ordering ──
    local churn_line tree_line
    churn_line=$(echo "$output" | grep -n "^## Churn" | head -1 | cut -d: -f1)
    tree_line=$(echo "$output" | grep -n "^## Tree" | head -1 | cut -d: -f1)
    if [[ -n "$churn_line" && -n "$tree_line" && "$churn_line" -lt "$tree_line" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: primer churn before tree"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: primer churn before tree\n    churn at line $churn_line, tree at line $tree_line"
        echo "  FAIL: primer churn before tree"
    fi

    # Tree is budgeted and churn-informed
    assert_contains "primer tree budgeted" "$output" "budget:"

    # Symbol map is budgeted
    assert_contains "primer symbol map budgeted" "$output" "Budgeted symbol map"

    # Task flag
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --task debug 2>&1)
    assert_contains "primer task debug" "$output" "## Task: Debug"
    assert_contains "primer task debug has prompt" "$output" "# Repository Context Instructions"

    # Task + primer still has all sections
    output=$("$RQS" --repo "$FIXTURE_DIR" primer --task review 2>&1)
    assert_contains "primer task review" "$output" "## Task: Code Review"
    assert_contains "primer task review has tree" "$output" "## Tree"
    assert_contains "primer task review has churn" "$output" "## Churn"
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

    # ── Budgeted signatures tests ──

    # --budget header contains "Budgeted symbol map"
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures --budget 50 2>&1)
    assert_contains "signatures budget header" "$output" "Budgeted symbol map"
    assert_contains "signatures budget files in detail" "$output" "files in detail"

    # No --budget → backward compatible (no "Budgeted" in output)
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures 2>&1)
    assert_not_contains "signatures no-budget backward compat" "$output" "Budgeted"

    # --budget with --churn-data → output contains "churn-ranked"
    local churn_sig_tmp
    churn_sig_tmp=$(mktemp)
    cat > "$churn_sig_tmp" <<'CHURN_JSON'
{"src/main.py": {"commits": 100, "lines": 5000}, "src/utils/helpers.py": {"commits": 50, "lines": 2000}}
CHURN_JSON
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures --budget 50 --churn-data "$churn_sig_tmp" 2>&1)
    assert_contains "signatures churn-ranked" "$output" "churn-ranked"
    # High-churn file appears in output
    assert_contains "signatures churn high-churn file" "$output" "src/main.py"
    rm -f "$churn_sig_tmp"

    # ── Overflow test: many files, small budget ──
    local sig_overflow_dir
    sig_overflow_dir=$(mktemp -d)
    (
        cd "$sig_overflow_dir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Tester"
        mkdir -p pkg
        for n in $(seq 1 20); do
            cat > "pkg/mod${n}.py" <<PYEOF
class Widget${n}:
    pass

def process_${n}(data):
    return data

def transform_${n}(x, y):
    return x + y

def validate_${n}(item):
    return True
PYEOF
        done
        git add -A && git commit -q -m "init"
    ) >/dev/null 2>&1
    output=$("$RQS" --repo "$sig_overflow_dir" signatures --budget 30 2>&1)
    assert_contains "signatures overflow has budget header" "$output" "Budgeted symbol map"
    # Count total output lines (budget + overhead tolerance)
    local sig_lines
    sig_lines=$(echo "$output" | wc -l)
    if [[ "$sig_lines" -le 40 ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: signatures overflow within budget ($sig_lines lines)"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: signatures overflow within budget\n    expected <= 40 lines, got $sig_lines"
        echo "  FAIL: signatures overflow within budget ($sig_lines lines)"
    fi
    rm -rf "$sig_overflow_dir"

    # ── Catalog format test ──
    # Small budget with multiple files → shows catalog or detail indicator
    output=$("$RQS" --repo "$FIXTURE_DIR" signatures --budget 20 2>&1)
    assert_contains "signatures small budget detail indicator" "$output" "files in detail"

    # ── Span prioritization test ──
    # Large-span function at end of file should surface before small ones
    local span_dir
    span_dir=$(mktemp -d)
    (
        cd "$span_dir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Tester"
        # 10 small functions (2 lines each), then one large class (many methods)
        {
            for n in $(seq 1 10); do
                echo "def tiny_${n}():"
                echo "    pass"
                echo ""
            done
            echo "class BigDispatcher:"
            echo '    """The main dispatcher."""'
            for n in $(seq 1 8); do
                echo "    def handle_${n}(self, data):"
                echo "        return data"
                echo ""
            done
        } > big.py
        git add -A && git commit -q -m "init"
    ) >/dev/null 2>&1
    output=$("$RQS" --repo "$span_dir" signatures --budget 80 2>&1)
    # BigDispatcher has the largest block (class + methods), surfaces first
    assert_contains "signatures span-priority surfaces large block" "$output" "BigDispatcher"
    rm -rf "$span_dir"
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
    # Sustained section requires >= 3 buckets; fixture has 1 commit so it should not appear
    assert_not_contains "churn no sustained for shallow history" "$output" "### Sustained Development"
    # Co-change clusters require >= 2 co-commits; fixture has 1 commit so none
    assert_not_contains "churn no clusters for shallow history" "$output" "### Co-change Clusters"

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

    # --min-lines filter
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --min-lines 50 2>&1)
    assert_contains "churn min-lines header" "$output" "## Churn"
    assert_contains "churn min-lines filter note" "$output" "min 50 lines"

    # --min-lines very high (filters everything)
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --min-lines 999999 2>&1)
    assert_contains "churn min-lines no match" "$output" "no files match"

    # Sustained continuity with bucket_size > 1 (regression: use bucket index, not commit index)
    local churn_tmpdir
    churn_tmpdir=$(mktemp -d)
    (
        cd "$churn_tmpdir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Tester"
        echo "v1" > app.py
        echo "v1" > util.py
        git add -A && git commit -q -m "c1"
        echo "v2" >> app.py
        git add -A && git commit -q -m "c2"
        echo "v3" >> app.py
        echo "v2" >> util.py
        git add -A && git commit -q -m "c3"
        echo "v4" >> app.py
        git add -A && git commit -q -m "c4"
        echo "v5" >> app.py
        echo "v3" >> util.py
        git add -A && git commit -q -m "c5"
        echo "v6" >> app.py
        git add -A && git commit -q -m "c6"
    ) >/dev/null 2>&1
    # 6 commits, bucket 2 → 3 buckets; app.py active in all 3 → continuity 100%
    output=$("$RQS" --repo "$churn_tmpdir" churn --bucket 2 2>&1)
    assert_contains "churn sustained with bucket>1" "$output" "### Sustained Development Files"
    assert_contains "churn sustained shows app.py" "$output" "app.py"
    # Active fraction denominator should be bucket count (3), not commit count
    assert_contains "churn sustained bucket-index fraction" "$output" "/3"
    assert_not_contains "churn sustained no commit-index fraction" "$output" "/6"
    rm -rf "$churn_tmpdir"

    # ── Sustained development budget test ──
    # Generate synthetic git log: 100 files each appearing in commits 0 and 1,
    # so all have possible>=2. 4 commits total, bucket=1.
    # Commits touch 1 file each to avoid co-change explosion.
    local synth_log
    synth_log=$(python3 -c "
# Commit 0: files 0-99 (all files first appear here)
print('COMMIT\tTester')
for n in range(100):
    print(f'10\t5\tfile{n}.py')
# Commits 1-3: each touches all 100 files again (1 file per line, no co-change issue
# since MAX_FILES_PER_COMMIT=50 skips these for clustering)
for c in range(1, 4):
    print('COMMIT\tTester')
    for n in range(100):
        print(f'10\t5\tfile{n}.py')
")
    output=$(echo "$synth_log" | python3 "$RQS_ROOT/lib/render.py" churn --bucket 1 --min-continuity 0 --top 20 2>&1)
    assert_contains "churn sustained budget has section" "$output" "### Sustained Development Files"
    # Should show "showing X of Y" since 100 files > 94-row budget
    assert_contains "churn sustained budget truncated" "$output" "showing 94 of 100"

    # ── Churn-summary mode test ──
    local churn_summary_output
    churn_summary_output=$(cd "$FIXTURE_DIR" && git log --pretty=format:COMMIT%x09%an --numstat 2>&1 \
        | python3 "$RQS_ROOT/lib/render.py" churn-summary)
    # Should be valid JSON with commits and lines keys
    local is_valid_json
    is_valid_json=$(echo "$churn_summary_output" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    assert isinstance(d, dict)
    for v in d.values():
        assert 'commits' in v and 'lines' in v
    print('yes')
except:
    print('no')
" 2>&1)
    if [[ "$is_valid_json" == "yes" ]]; then
        PASS=$((PASS + 1))
        echo "  PASS: churn-summary produces valid JSON"
    else
        FAIL=$((FAIL + 1))
        ERRORS="${ERRORS}\n  FAIL: churn-summary produces valid JSON\n    got: $churn_summary_output"
        echo "  FAIL: churn-summary produces valid JSON"
    fi
    # No XML wrapper tags
    assert_not_contains "churn-summary no xml open tag" "$churn_summary_output" "<churn-summary>"
    assert_not_contains "churn-summary no xml close tag" "$churn_summary_output" "</churn-summary>"

    # Help
    output=$("$RQS" --repo "$FIXTURE_DIR" churn --help 2>&1)
    assert_contains "churn help" "$output" "Usage: rqs churn"
    assert_contains "churn help include" "$output" "--include"
    assert_contains "churn help exclude" "$output" "--exclude"
    assert_contains "churn help author" "$output" "--author"
    assert_contains "churn help sort" "$output" "--sort"
    assert_contains "churn help min-lines" "$output" "--min-lines"
    assert_contains "churn help min-coupling" "$output" "--min-coupling"
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

# ── Test: Primer Insights (entrypoints, test detection) ────────────────────

test_primer_insights() {
    echo "Testing: primer insights"

    # Create a repo with C main(), CI scripts, Lua tests, and test/ dir
    local insights_dir
    insights_dir=$(mktemp -d)
    (
        cd "$insights_dir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Tester"

        # Runtime entrypoint: C main() and internal include graph
        mkdir -p src/app
        cat > src/app/core.h <<'HEOF'
#pragma once
int core_add(int a, int b);
HEOF
        cat > src/app/core.c <<'CCEOF'
#include "core.h"
int core_add(int a, int b) {
    return a + b;
}
CCEOF
        cat > src/app/main.c <<'CEOF'
#include <stdio.h>
#include "core.h"
int main(int argc, char *argv[]) {
    printf("sum=%d\n", core_add(1, 1));
    return 0;
}
CEOF

        # CI script (should be demoted)
        mkdir -p .github/workflows
        cat > .github/workflows/ci.sh <<'SHEOF'
#!/bin/bash
set -euo pipefail
case "$1" in
    build) make ;;
    test) make test ;;
esac
SHEOF
        chmod +x .github/workflows/ci.sh

        # Lua test files in test/ (no 's')
        mkdir -p test/functional
        cat > test/functional/eval_spec.lua <<'LUAEOF'
local helpers = require('test.helpers')
describe('eval', function()
    it('evaluates expressions', function()
        local result = eval('1+1')
        eq(2, result)
    end)
    it('handles errors', function()
        ok(false)
    end)
end)
LUAEOF

        git add -A && git commit -q -m "init"
    ) >/dev/null 2>&1

    local output
    output=$("$RQS" --repo "$insights_dir" primer 2>&1)

    # C main.c should appear as entrypoint
    assert_contains "insights c-main entrypoint" "$output" "src/app/main.c"
    assert_contains "insights c-main signal" "$output" "c-main"
    # C include graph should contribute fan-in for core.h
    assert_contains "insights c include target in critical path" "$output" "src/app/core.h"
    assert_contains "insights c include fanin signal" "$output" "imported-by 2"

    # CI script should not appear in entrypoints section
    local entrypoints_section
    entrypoints_section=$(echo "$output" | sed -n '/Likely entrypoints/,/Dispatch surface/p')
    assert_not_contains "insights ci not in entrypoints" "$entrypoints_section" ".github/workflows/ci.sh"

    # Lua test files should be detected
    # Behavioral Contract should show more than 0/1 test files
    assert_contains "insights lua tests detected" "$output" "Test files detected"
    # Should find the it() test cases
    assert_contains "insights lua test cases" "$output" "Named test cases detected: 2"
    # Should find eq/ok assertions
    assert_contains "insights lua assertions" "$output" "Assertion-like checks detected"

    rm -rf "$insights_dir"
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
test_primer_insights
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
