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
- **Tree** — filtered directory structure (git-tracked files only)
- **Symbols** — classes, functions, types with file and line number
- **Outline** — structural hierarchy of a single file
- **Signatures** — behavioral sketch: headers, decorators, docstrings, returns (no implementation)
- **Slice** — exact code extract with line numbers
- **Definition** — where a symbol is defined (file, kind, line)
- **References** — where a symbol is used (excludes definitions)
- **Dependencies** — imports classified as internal (in-repo) or external (third-party/stdlib)
- **Grep** — regex search results grouped by file

## How to Request More Context

When you need additional information, respond with the exact command. The user will
run it and provide the output. Available commands:

| Command | When to use it |
|---------|---------------|
| `rqs tree <path> --depth N` | Explore directory structure |
| `rqs symbols <file\|dir>` | Index symbols in a file or directory |
| `rqs outline <file>` | See structural overview of a file |
| `rqs signatures <file\|dir>` | See API contracts (Python): signatures, returns, docstrings |
| `rqs slice <file> <start> <end>` | Read specific lines of code |
| `rqs definition <symbol>` | Find where something is defined |
| `rqs references <symbol>` | Find where something is used |
| `rqs deps <file>` | See what a file imports |
| `rqs grep <pattern> --scope <dir>` | Search for a pattern |

Request the **minimum context needed**. Start with structure (tree, symbols, signatures),
then drill into code (slice) only for the specific sections relevant to your analysis.
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

1. Start with the **primer** or **tree** to orient yourself
2. Use `rqs signatures` on suspect modules to understand API contracts
3. Use `rqs grep` to find error messages, log statements, or the failing pattern
4. Use `rqs definition` and `rqs references` to trace data flow
5. Use `rqs slice` to read the specific code paths involved
6. Use `rqs deps` to understand what a module depends on

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

1. Start with the **primer** to understand the overall architecture
2. Use `rqs signatures` on related modules to understand existing patterns
3. Use `rqs deps` to understand the dependency graph around the area of change
4. Use `rqs references` to find integration points and conventions
5. Use `rqs slice` to read the specific code you'd modify or extend

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

1. Start with `rqs signatures` on the files under review for a behavioral overview
2. Use `rqs deps` to check dependency hygiene
3. Use `rqs slice` to read the implementation in detail
4. Use `rqs references` to verify naming consistency and integration
5. Use `rqs grep` to check for patterns like TODO, FIXME, or error handling

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

1. Start with the **primer** or **tree** for architectural context
2. Use `rqs signatures` to understand the public API and structure
3. Use `rqs deps` to map out the dependency graph
4. Use `rqs outline` and `rqs slice` to walk through key code paths
5. Use `rqs definition` and `rqs references` to trace how components connect

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
