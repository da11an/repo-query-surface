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
rqs primer              # Standard primer: orientation + fast-start map + tree + symbols + summaries
rqs tree                # Directory tree
rqs symbols             # Symbol index (classes, functions, types)
rqs outline src/app.py  # Structural outline of one file
rqs signatures src/     # Behavioral sketch (signatures + returns + docstrings)
rqs slice src/app.py 10 30   # Lines 10-30 with line numbers
rqs show MyClass process     # Full source of named symbols
rqs context src/app.py 42    # Enclosing function for line 42
rqs definition MyClass  # Where is MyClass defined?
rqs references MyClass  # Where is MyClass used?
rqs deps src/app.py     # Imports: internal vs external
rqs grep "TODO"         # Structured regex search
rqs diff main           # Changes compared to main branch
rqs files "*.py"        # List Python files with line counts
rqs callees process     # What does process() call?
rqs related src/app.py  # Files connected to app.py
rqs notebook nb/analysis.ipynb  # Notebook cells with truncated outputs
rqs prompt              # LLM orientation instructions
rqs prompt debug        # Orientation + debugging task framing

# Target a different repo:
rqs --repo /path/to/other/repo primer
```

## Commands

### `rqs primer [--light|--medium|--heavy] [--task TASK]`

The starting point. Generates a tiered markdown document combining prompt orientation with repository context. Three detail levels:

| Tier | Content |
|------|---------|
| `--light` | Prompt orientation + repo header + README summary + fast-start map + runtime boundaries + tree |
| `--medium` (default) | Light + behavioral contract from tests + critical path files + symbol index + module summaries |
| `--heavy` | Medium + signatures (whole repo) + dependency wiring + heuristic risk hotspots |

Use `--task TASK` to include task-specific framing (debug, feature, review, explain) — the same framing available via `rqs prompt`.

```bash
rqs primer                          # Standard (medium) primer
rqs primer --light                  # Quick orientation + control-flow map
rqs primer --heavy                  # Full behavioral + risk sketch
rqs primer --task debug             # Medium primer with debugging framing
rqs primer --light --task review    # Quick primer with code review framing
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

### `rqs signatures [file|dir]`

Behavioral sketch of Python files: class/function headers with decorators, first-line docstrings (as `#` comments), and return statements. Implementation details are stripped away, giving an LLM enough to understand API contracts and control flow without the noise of full source.

```bash
rqs signatures src/app.py      # One file
rqs signatures src/             # All .py files in a directory
rqs signatures                  # All .py files in the repo
```

Currently supports Python files via AST analysis.

### `rqs slice <file> <start> <end>`

Extract an exact code slice with line numbers and language-appropriate syntax highlighting.

```bash
rqs slice src/app.py 10 30
```

### `rqs show <symbol> [symbol...]`

Extract the full source code of one or more named symbols. Uses ctags to locate definitions and their line spans. Multiple symbols can be requested in one call.

```bash
rqs show Application              # One symbol
rqs show Application main         # Multiple symbols at once
rqs show format_output             # Functions from any file
```

### `rqs context <file> <line>`

Show the enclosing function or class for a given line number. Useful when you have a line number from a stack trace, grep result, or error message.

```bash
rqs context src/app.py 42         # What function is line 42 in?
```

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

### `rqs diff [ref] [--staged]`

Show git diff as structured markdown. Defaults to working tree changes. Accepts a branch, tag, or commit reference.

```bash
rqs diff                    # Unstaged working tree changes
rqs diff --staged           # Staged changes
rqs diff main               # Changes compared to main branch
rqs diff HEAD~3             # Changes in last 3 commits
```

### `rqs files <glob>`

List git-tracked files matching a glob pattern, with line counts. Useful for finding test files, configs, or files matching a naming convention.

```bash
rqs files "*.py"           # All Python files
rqs files "test_*"         # Test files
rqs files "src/**/*.js"    # JS files under src/
rqs files "*config*"       # Config-related files
```

### `rqs callees <symbol>`

Show what functions/methods a given symbol calls (outgoing edges). The inverse of `references` — instead of "who calls me?", it answers "what do I call?".

```bash
rqs callees process_request    # What does process_request call?
rqs callees Application.start  # What does start() call?
```

### `rqs related <file>`

Show files connected to a given file: files it imports (forward dependencies) and files that import it (reverse dependencies). A one-command "neighborhood" view.

```bash
rqs related src/main.py
```

### `rqs notebook <file> [--debug]`

Extract structured content from a Jupyter notebook (`.ipynb`). Renders markdown cells as-is, code cells in fenced blocks, and outputs with smart truncation: text outputs show the first N lines, error tracebacks show the error name plus last frames, and rich outputs (images, HTML) show placeholders.

With `--debug`, switches to error analysis mode: parses traceback frames, classifies each as notebook-local, repo-local, or external, extracts the enclosing function source for repo-local frames with a `>>>` marker on the error line, shows dependency chains for involved files, and produces a diagnostic summary with suggested `rqs` commands. If ctags is available, cross-references against the symbol table for richer context.

```bash
rqs notebook notebooks/analysis.ipynb
rqs notebook notebooks/analysis.ipynb --debug
RQS_NOTEBOOK_MAX_OUTPUT_LINES=20 rqs notebook demo.ipynb
```

Configuration:
- `RQS_NOTEBOOK_MAX_OUTPUT_LINES` — max text output lines before truncation (default: 10)
- `RQS_NOTEBOOK_MAX_TRACEBACK` — max traceback frames to show (default: 5)

### `rqs grep <pattern> [--scope dir] [--context N] [--max N]`

Structured regex search across tracked files. Results are grouped by file with line numbers.

```bash
rqs grep "TODO|FIXME"
rqs grep "class.*Error" --scope src/
rqs grep "def test_" --context 0 --max 20
```

### `rqs prompt [task]`

Generate LLM-facing orientation text. Explains how to read rqs output sections, how to request additional context using the command vocabulary, and optionally includes task-specific framing.

```bash
rqs prompt              # General orientation
rqs prompt debug        # + debugging approach
rqs prompt feature      # + feature design approach
rqs prompt review       # + code review approach
rqs prompt explain      # + code explanation approach
```

Paste the output at the start of an LLM conversation (before or after the primer) to give the LLM instructions for working with rqs context.

## Per-Repo Configuration

Create a `.rqsrc` file in the target repo root to override defaults:

```bash
RQS_TREE_DEPTH=6
RQS_GREP_CONTEXT=3
RQS_GREP_MAX_RESULTS=100
RQS_REF_MAX_RESULTS=50
RQS_PRIMER_TREE_DEPTH=4
RQS_PRIMER_MAX_SYMBOLS=1000
RQS_SYMBOL_KINDS="class,function,method,interface,type"
```

Only `RQS_`-prefixed key=value lines are accepted. No command substitution or shell expansion is allowed (validated before sourcing).

## Typical Workflow

1. **Generate a primer** and paste it into your LLM conversation:
   ```bash
   rqs primer --task debug | pbcopy              # Standard primer + debug framing
   rqs primer --light --task review | pbcopy      # Quick primer + review framing
   rqs primer --heavy | pbcopy                    # Full primer for deep analysis
   ```

2. The LLM reads the orientation and primer, understanding both the command vocabulary and the task at hand.

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
