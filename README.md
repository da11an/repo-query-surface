# repo-query-surface

A Linux-native CLI for exposing **structured, queryable repository context** to large language models (LLMs) without granting direct repository access.

Generate a compact primer of any git repo — tree, symbols, dependencies — then drill into specifics with precise commands. All output is markdown, optimized for LLM context windows.

---

## Requirements

- **bash** 4+
- **git**
- **python3** (stdlib only, no pip packages)
- **[universal-ctags](https://ctags.io/)** (recommended, for symbol extraction)
- Standard Unix tools: `grep`, `sed`, `awk`, `file`, `find`

All of these ship with or are available on RHEL/Fedora/Ubuntu/Debian. If `universal-ctags` is not installed, `rqs` falls back to grep-based heuristics for symbol commands.

### Installing universal-ctags

```bash
# Fedora / RHEL
sudo dnf install universal-ctags

# Ubuntu / Debian
sudo apt install universal-ctags

# macOS (Homebrew)
brew install universal-ctags
```

## Setup

Clone the repo and add `bin/` to your `PATH`, or invoke it directly:

```bash
git clone <url> repo-query-surface
export PATH="$PWD/repo-query-surface/bin:$PATH"
```

No compilation, no virtual environments, no dependencies to install.

## Quick Start

```bash
# From inside any git repository:
rqs primer              # Full primer: tree + symbols + deps + command reference
rqs tree                # Directory tree
rqs symbols             # Symbol index (classes, functions, types)
rqs outline src/app.py  # Structural outline of one file
rqs slice src/app.py 10 30   # Lines 10-30 with line numbers
rqs definition MyClass  # Where is MyClass defined?
rqs references MyClass  # Where is MyClass used?
rqs deps src/app.py     # Imports: internal vs external
rqs grep "TODO"         # Structured regex search

# Target a different repo:
rqs --repo /path/to/other/repo primer
```

## Commands

### `rqs primer`

The starting point. Generates a single markdown document containing:
- Repository tree (depth-limited)
- Symbol index (classes, functions, types)
- Module summaries (file counts and types per directory)
- Internal dependency wiring
- Command reference card

Paste this into an LLM conversation to give it structural awareness of the repo, then use the other commands to answer its follow-up questions.

```bash
rqs primer
rqs primer --tree-depth 2 --max-symbols 200
```

### `rqs tree [path] [--depth N]`

Filtered directory tree. Respects `.gitignore`, excludes common noise (`node_modules`, `__pycache__`, etc.).

```bash
rqs tree                    # Full repo
rqs tree src/ --depth 2     # Just src/, 2 levels deep
```

### `rqs symbols [file|dir] [--kinds LIST]`

Symbol index via ctags. Shows classes, functions, methods, types — grouped by file, with line numbers.

```bash
rqs symbols                        # Whole repo
rqs symbols src/                   # One directory
rqs symbols src/app.py             # One file
rqs symbols --kinds class,function # Filter by kind
```

### `rqs outline <file>`

Structural outline of a single file. Shows symbol hierarchy with line spans.

```bash
rqs outline lib/render.py
```

### `rqs slice <file> <start> <end>`

Extract an exact code slice with line numbers and language-appropriate syntax highlighting.

```bash
rqs slice src/app.py 10 30
```

Limited to 200 lines per slice (configurable via `RQS_SLICE_MAX_LINES`).

### `rqs definition <symbol>`

Find where a symbol is defined. Returns file path, kind, and line number.

```bash
rqs definition Application
```

### `rqs references <symbol> [--max N]`

Find usage / call sites of a symbol (excludes the definition itself).

```bash
rqs references format_output
rqs references format_output --max 10
```

### `rqs deps <file>`

Show imports for a file, classified as **internal** (exists in the repo) or **external** (third-party / stdlib). Uses Python AST analysis for `.py` files, regex patterns for other languages.

```bash
rqs deps src/main.py
```

Supported languages: Python, JavaScript/TypeScript, Go, Ruby, Rust, Java, C/C++, Shell, CSS/SCSS.

### `rqs grep <pattern> [--scope dir] [--context N] [--max N]`

Structured regex search across tracked files. Results are grouped by file with line numbers.

```bash
rqs grep "TODO|FIXME"
rqs grep "class.*Error" --scope src/
rqs grep "def test_" --context 0 --max 20
```

## Per-Repo Configuration

Create a `.rqsrc` file in the target repo root to override defaults:

```bash
RQS_TREE_DEPTH=6
RQS_GREP_CONTEXT=3
RQS_GREP_MAX_RESULTS=100
RQS_SLICE_MAX_LINES=300
RQS_REF_MAX_RESULTS=50
RQS_PRIMER_TREE_DEPTH=4
RQS_PRIMER_MAX_SYMBOLS=1000
RQS_SYMBOL_KINDS="class,function,method,interface,type"
```

Only `RQS_`-prefixed key=value lines are accepted. No command substitution or shell expansion is allowed (validated before sourcing).

## Typical Workflow

1. **Generate a primer** and paste it into your LLM conversation:
   ```bash
   rqs primer | pbcopy   # macOS
   rqs primer | xclip    # Linux
   ```

2. The LLM reads the primer and asks follow-up questions using the command vocabulary it saw in the reference card.

3. **You run the commands it asks for** and paste the output back:
   ```bash
   rqs slice src/auth.py 45 80
   rqs deps src/auth.py
   rqs references validate_token
   ```

4. Repeat until the LLM has enough context to answer your question, review code, or suggest changes.

The human controls what context is generated, what is shared, and when iteration stops.

## Running Tests

```bash
tests/run_tests.sh
```

Runs 50 assertions against a synthetic fixture repo. Requires `git`, `python3`, and `universal-ctags`.

---

## Philosophy

LLMs do not reason effectively over raw source trees or large code dumps.
They reason over **intent, structure, boundaries, and behavior**.

This project treats a repository not as text to ingest, but as a system to be **interrogated**.

### Structure Before Detail
High-level structure (modules, symbols, dependencies) is more valuable than full file contents.
Raw code is disclosed only when necessary and only in precise slices.

### Deterministic Context
All context is produced using basic, ubiquitous tools (`grep`, `ctags`, `sed`, `python`).
No opaque indexing, no embeddings, no hidden state.

### Fixed Query Surface
The LLM requests context using a small, predefined set of commands — not free-form "show me more code." This keeps interactions auditable, token-efficient, and free of accidental over-disclosure.

### Incremental Disclosure
Start with a static primer, then iteratively reveal deeper context only as required.

### Human-in-the-Loop
A human controls what context is generated, what is shared, and when iteration stops. This is assisted reasoning, not autonomous code understanding.
