#!/usr/bin/env bash
# rqs_prompt.sh — generate LLM-facing orientation and task framing

cmd_prompt() {
    local task=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help)
                cat <<'EOF'
Usage: rqs prompt [task]

Generate LLM-facing orientation text explaining how to read rqs output
and how to request additional context.

Tasks:
  (none)      General orientation only
  debug       Debugging a specific issue
  feature     Designing a new feature
  review      Code review
  explain     Understanding unfamiliar code

EOF
                return 0
                ;;
            -*) rqs_error "prompt: unknown option '$1'" ;;
            *)
                if [[ -z "$task" ]]; then
                    task="$1"
                else
                    rqs_error "prompt: too many arguments"
                fi
                shift
                ;;
        esac
    done

    # ── Orientation ──
    cat <<'EOF'
# Repository Context Instructions

You are analyzing a codebase using structured queries. Context has been (or will be)
provided as markdown sections, each with a `##` header describing the content type.

## How to Read the Context

Each section you receive is labeled:
- **Tree** — directory structure with per-file line counts
- **Symbols** — classes, functions, types with line spans and signatures
- **Outline** — structural hierarchy of a single file with signatures and spans
- **Signatures** — behavioral sketch: headers, decorators, docstrings, returns (Python via AST; other languages via ctags)
- **Slice** — exact code extract with line numbers
- **Show** — full source of a named symbol (class, function, method) with line numbers
- **Context** — enclosing function/class for a given file:line, with full source
- **Definition** — where a symbol is defined (file, kind, line span)
- **References** — where a symbol is used (excludes definitions)
- **Dependencies** — imports classified as internal or external, with imported names
- **Grep** — regex search results grouped by file
- **Diff** — git diff output with change statistics
- **Files** — flat file list matching a glob pattern, with line counts
- **Callees** — what functions/methods a given symbol calls (outgoing edges)
- **Related** — files connected to a given file (imports and importers)
- **Notebook** — Jupyter notebook cells (markdown, code, concise output snippets)
- **Notebook Debug** — error analysis: traceback frames classified (notebook/repo/external), repo code with error line marked, dependency trace, diagnostic summary

Symbol tables and outlines include line spans (e.g. `8-24`), so you can go
directly to `rqs slice <file> <start> <end>` without an intermediate lookup.

## How to Request More Context

When you need additional information, respond with the exact command(s). The user
will run them and provide the output. Request everything you can anticipate needing
in a single response — each round trip is costly, so **batch related commands**
rather than asking one at a time.

| Command | When to use it |
|---------|---------------|
| `rqs tree <path> --depth N` | Explore directory structure |
| `rqs symbols <file\|dir>` | Index symbols in a file or directory |
| `rqs outline <file>` | See structural overview of a file |
| `rqs signatures <file\|dir>` | See behavioral sketch: signatures, returns, docstrings |
| `rqs slice <file> <start> <end>` | Read specific lines of code |
| `rqs show <symbol> [symbol...]` | Extract full source of named symbols (batches multiple) |
| `rqs context <file> <line>` | See enclosing function/class for a line number |
| `rqs definition <symbol>` | Find where something is defined |
| `rqs references <symbol>` | Find where something is used |
| `rqs deps <file>` | See what a file imports and from where |
| `rqs grep <pattern> --scope <dir>` | Search for a pattern |
| `rqs diff [ref] [--staged]` | See git diff (working tree, staged, or vs a ref) |
| `rqs files <glob>` | List files matching a pattern (e.g. `"*.py"`, `"*test*"`) |
| `rqs callees <symbol>` | What does this function call? (outgoing edges) |
| `rqs related <file>` | Files that import or are imported by this file |
| `rqs notebook <file> [--debug]` | Extract notebook content; `--debug` for error analysis with traceback cross-referencing |

Be targeted but not artificially minimal. If you know you'll need signatures and
deps for the same module, or slices of three related functions, request them all at
once. Avoid requesting context you won't use, but don't create unnecessary round
trips by asking for one thing at a time.
EOF

    # ── Task-specific section ──
    case "$task" in
        "")
            # No task — general orientation only
            ;;
        debug)
            cat <<'EOF'

## Task: Debug

You are helping debug an issue in this codebase. Approach:

1. Use the **primer** or **tree** to orient yourself
2. Use `rqs signatures` and `rqs deps` on suspect modules together
3. Use `rqs grep` to find error messages, log statements, or the failing pattern
4. Use `rqs definition` and `rqs references` to trace data flow; use `rqs callees` to see what a suspect function calls
5. Use `rqs show` to extract suspect functions by name — request all at once
6. Use `rqs context <file> <line>` when you have a line number from a stack trace or grep hit

When you identify the issue, explain:
- Where the bug is (file, line, function)
- Why it occurs (root cause)
- What the fix should be (with a code suggestion if possible)
EOF
            ;;
        feature)
            cat <<'EOF'

## Task: Feature Design

You are helping design a new feature for this codebase. Approach:

1. Use the **primer** to understand the overall architecture
2. Use `rqs signatures` on related modules to understand existing patterns, and `rqs deps` or `rqs related` to understand the dependency graph — request together
3. Use `rqs references` to find integration points and conventions
4. Use `rqs show` to read the functions/classes you'd modify or extend; use `rqs callees` to understand their outgoing dependencies

Provide:
- Where new code should go (existing file or new file, with rationale)
- What interfaces to implement or extend
- What existing patterns to follow
- A concrete implementation sketch
EOF
            ;;
        review)
            cat <<'EOF'

## Task: Code Review

You are reviewing code in this codebase. Approach:

1. Use `rqs diff` or `rqs diff <branch>` to see what changed
2. Use `rqs signatures` on the files under review for a behavioral overview
3. Use `rqs deps` to check dependency hygiene
4. Use `rqs show` to read specific functions or `rqs slice` for broader ranges
5. Use `rqs references` and `rqs grep` to verify naming consistency and patterns like TODO/FIXME

Assess:
- Correctness: Does the logic do what the signatures/docstrings claim?
- Design: Does it follow existing patterns? Appropriate abstractions?
- Edge cases: Error handling, boundary conditions, empty inputs
- Dependencies: Are new dependencies justified?
EOF
            ;;
        explain)
            cat <<'EOF'

## Task: Code Explanation

You are explaining how this codebase (or a specific part of it) works. Approach:

1. Use the **primer** or **tree** for architectural context
2. Use `rqs signatures` and `rqs deps` together to understand the public API, structure, and dependency graph
3. Use `rqs show` to read key classes and functions, or `rqs outline` for structural overview
4. Use `rqs definition` and `rqs references` to trace how components connect

Explain:
- High-level architecture and module responsibilities
- Key data flows and control paths
- Design decisions and their trade-offs
- How the components fit together
EOF
            ;;
        *)
            rqs_error "prompt: unknown task '$task' (valid: debug, feature, review, explain)"
            ;;
    esac
}
