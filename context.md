<prompt>
<instructions>
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

| Command                                  | When to use it                                                            |
|------------------------------------------|---------------------------------------------------------------------------|
| `rqs tree <path> --depth N`              | Explore directory structure                                                |
| `rqs symbols <file\|dir>`                | Index symbols in a file or directory                                      |
| `rqs outline <file>`                     | See structural overview of a file                                         |
| `rqs signatures <file\|dir>`             | See behavioral sketch: signatures, returns, docstrings                    |
| `rqs slice <file> <start> <end>`         | Read specific lines of code                                               |
| `rqs show <symbol> [symbol...]`          | Extract full source of named symbols (batches multiple)                   |
| `rqs context <file> <line>`              | See enclosing function/class for a line number                            |
| `rqs definition <symbol>`                | Find where something is defined                                           |
| `rqs references <symbol>`                | Find where something is used                                              |
| `rqs deps <file>`                        | See what a file imports and from where                                    |
| `rqs grep <pattern> --scope <dir>`       | Search for a pattern                                                      |
| `rqs diff [ref] [--staged]`              | See git diff (working tree, staged, or vs a ref)                          |
| `rqs files <glob>`                       | List files matching a pattern (e.g. `"*.py"`, `"*test*"`)                 |
| `rqs callees <symbol>`                   | What does this function call? (outgoing edges)                            |
| `rqs related <file>`                     | Files that import or are imported by this file                            |
| `rqs notebook <file> [--debug]`          | Extract notebook content; `--debug` for error analysis with traceback cross-referencing |

Be targeted but not artificially minimal. If you know you'll need signatures and
deps for the same module, or slices of three related functions, request them all at
once. Avoid requesting context you won't use, but don't create unnecessary round
trips by asking for one thing at a time.
</instructions>
</prompt>

<repository_primer>
# Repository Primer: `repo-query-surface`

A Linux-native CLI for exposing **structured, queryable repository context** to large language models (LLMs) without granting direct repository access.

<orientation>
## Orientation
> Entrypoints, dispatch surface, and critical-path ranking.

**Likely entrypoints:**
- `bin/rqs` (score 13; bin, executable, case-dispatch)
- `lib/primer_insights.py` (score 5; cli-parser, __main__)
- `lib/rqs_deps.sh` (score 4; case-dispatch)
- `lib/rqs_outline.sh` (score 4; case-dispatch)
- `lib/rqs_prompt.sh` (score 4; case-dispatch)
- `lib/rqs_related.sh` (score 4; case-dispatch)

**Dispatch surface:**
| Command      | Entrypoint | Handler          |
|--------------|------------|------------------|
| `--repo`     | `bin/rqs`  | *(not resolved)* |
| `callees`    | `bin/rqs`  | `cmd_callees`    |
| `churn`      | `bin/rqs`  | `cmd_churn`      |
| `context`    | `bin/rqs`  | `cmd_context`    |
| `definition` | `bin/rqs`  | `cmd_definition` |
| `deps`       | `bin/rqs`  | `cmd_deps`       |
| `diff`       | `bin/rqs`  | `cmd_diff`       |
| `files`      | `bin/rqs`  | `cmd_files`      |
| `grep`       | `bin/rqs`  | `cmd_grep`       |
| `notebook`   | `bin/rqs`  | `cmd_notebook`   |
| `outline`    | `bin/rqs`  | `cmd_outline`    |
| `primer`     | `bin/rqs`  | `cmd_primer`     |
| `prompt`     | `bin/rqs`  | `cmd_prompt`     |
| `references` | `bin/rqs`  | `cmd_references` |
| `related`    | `bin/rqs`  | `cmd_related`    |
| `show`       | `bin/rqs`  | `cmd_show`       |
| `signatures` | `bin/rqs`  | `cmd_signatures` |
| `slice`      | `bin/rqs`  | `cmd_slice`      |
| `symbols`    | `bin/rqs`  | `cmd_symbols`    |
| `tree`       | `bin/rqs`  | `cmd_tree`       |

**Critical path (ranked):**
|  # | File                     | Score | Signals                  |
|----|--------------------------|-------|--------------------------|
|  1 | `lib/primer_insights.py` |  11.5 | entrypoint               |
|  2 | `tests/run_tests.sh`     |   9.5 | entrypoint               |
|  3 | `bin/rqs`                |   8.6 | entrypoint, test-touch 1 |
|  4 | `lib/rqs_deps.sh`        |   8.4 | entrypoint               |
|  5 | `lib/rqs_related.sh`     |   8.4 | entrypoint               |
|  6 | `lib/rqs_prompt.sh`      |   8.2 | entrypoint               |
|  7 | `lib/rqs_outline.sh`     |   7.8 | entrypoint               |
|  8 | `lib/render.py`          |   7.5 | test-touch 1             |
|  9 | `lib/rqs_primer.sh`      |   5.0 | size/symbol density      |
| 10 | `lib/rqs_common.sh`      |   4.2 | test-touch 1             |
</orientation>

<runtime_boundaries>
## Runtime Boundaries
> Guardrails and operational constraints inferred from implementation patterns.
- Strict shell fail-fast mode: `bin/rqs:5`, `lib/rqs_common.sh:4`
- Repository boundary enforcement: `bin/rqs:32`, `lib/primer_insights.py:336`
- Layered config loading: `README.md:270`, `bin/rqs:98`
- CLI input validation: `lib/primer_insights.py:338`, `lib/rqs_callees.sh:27`
</runtime_boundaries>

<behavioral_contract>
## Behavioral Contract (Tests)
> What the test suite explicitly validates today.
- Test files detected: 9
- Named test cases detected: 22
- Assertion-like checks detected: 264

**Most exercised command surfaces:**
- `context` (3 references)
- `slice` (2 references)
- `tree` (1 references)
- `prompt` (1 references)
- `signatures` (1 references)
- `show` (1 references)
- `diff` (1 references)
- `files` (1 references)
- `callees` (1 references)
- `related` (1 references)
</behavioral_contract>

<heuristic_risk_hotspots>
## Heuristic Risk Hotspots
> Areas where behavior may be approximate, suppressed, or brittle under edge conditions.
| File                         | Signal             | Snippet                                                                                                |
|------------------------------|--------------------|--------------------------------------------------------------------------------------------------------|
| `README.md:17`               | heuristic/fallback | `All of these ship with or are available on RHEL/Fedora/Ubuntu/Debian. If `universal-ctags` is not...` |
| `README.md:58`               | todo/fixme         | `rqs grep "TODO"         # Structured regex search`                                                    |
| `README.md:81`               | heuristic/fallback | `| `--heavy` | Medium + signatures (whole repo) + dependency wiring + import topology + heuristic ...` |
| `README.md:249`              | todo/fixme         | `rqs grep "TODO|FIXME"`                                                                                |
| `lib/primer_insights.py:9`   | heuristic/fallback | `- Heuristic/risk hotspots`                                                                            |
| `lib/primer_insights.py:579` | heuristic/fallback | `if line.startswith("#") and any(kw in line.lower() for kw in ("fallback", "heuristic", "todo", "f...` |
| `lib/primer_insights.py:621` | heuristic/fallback | `print("- *(no likely entrypoints detected by current heuristics)*")`                                  |
| `lib/primer_insights.py:626` | heuristic/fallback | `signals = ", ".join(ep.signals[:3]) if ep.signals else "heuristic"`                                   |
| `lib/primer_insights.py:725` | heuristic/fallback | `_open_tag("heuristic_risk_hotspots")`                                                                 |
| `lib/primer_insights.py:726` | heuristic/fallback | `print("## Heuristic Risk Hotspots")`                                                                  |
| `lib/primer_insights.py:729` | heuristic/fallback | `print("- *(no obvious hotspots detected by heuristics)*")`                                            |
| `lib/primer_insights.py:730` | heuristic/fallback | `_close_tag("heuristic_risk_hotspots")`                                                                |
</heuristic_risk_hotspots>


<tree>
## Tree: `.`
> Filtered directory structure from git-tracked files (depth: 3, 37 files). Request `rqs tree <path> --depth N` to explore subdirectories.
```
./
├─ .gitignore (3)
├─ LICENSE (21)
├─ README.md (340)
├─ bin/
│  └─ rqs (187)
├─ conf/
│  ├─ defaults.conf (32)
│  ├─ ignore_patterns.conf (45)
│  └─ import_patterns.conf (42)
├─ lib/
│  ├─ primer_insights.py (796)
│  ├─ render.py (2177)
│  ├─ rqs_callees.sh (44)
│  ├─ rqs_common.sh (225)
│  ├─ rqs_context.sh (65)
│  ├─ rqs_definition.sh (67)
│  ├─ rqs_deps.sh (228)
│  ├─ rqs_diff.sh (52)
│  ├─ rqs_files.sh (50)
│  ├─ rqs_grep.sh (53)
│  ├─ rqs_notebook.sh (82)
│  ├─ rqs_outline.sh (97)
│  ├─ rqs_primer.sh (744)
│  ├─ rqs_prompt.sh (206)
│  ├─ rqs_references.sh (43)
│  ├─ rqs_related.sh (225)
│  ├─ rqs_show.sh (42)
│  ├─ rqs_signatures.sh (56)
│  ├─ rqs_slice.sh (97)
│  ├─ rqs_symbols.sh (106)
│  └─ rqs_tree.sh (30)
└─ tests/
   ├─ fixtures/
   │  └─ sample-repo/
   └─ run_tests.sh (785)
```
</tree>

<summaries>
## Module Summaries

### `./`
*3 files, 1 .md*

### `bin/`
*1 files*

### `conf/`
*3 files, 3 .conf*

### `lib/`
*21 files, 2 .py, 19 .sh*
`_xml_escape_attr`, `_open_tag`, `_close_tag`, `DispatchEntry`, `Entrypoint`, `run_git_ls_files`, `safe_read_text`, `safe_line_count`, `is_text_candidate`, `_is_fixture`, ... (89 total)

### `tests/`
*9 files, 3 .ipynb, 1 .md, 3 .py, 2 .sh*
`Application`, `main`, `format_output`, `validate_input`, `parse_config`
</summaries>

<signatures>
## Symbol Map
> Symbols, signatures, and structure with line spans per file. Request `rqs slice <file> <start> <end>` to see full code.
<file path="lib/primer_insights.py" language="python">

### `lib/primer_insights.py`
```python
# primer_insights.py — deterministic onboarding insights for rqs primer.

def _xml_escape_attr(value: object) -> str:  # L40-45
    return (str(value)

def _open_tag(name: str, **attrs: object) -> None:  # L48-53
    ...

def _close_tag(name: str) -> None:  # L56-57
    ...

@dataclass
class DispatchEntry:  # L61-65

@dataclass
class Entrypoint:  # L69-72

def run_git_ls_files(repo_root: str) -> List[str]:  # L75-89
    return files[:MAX_SCAN_FILES]
        return []
        return []

def safe_read_text(repo_root: str, rel_path: str) -> str:  # L92-103
    return data.decode("utf-8", errors="ignore")
        return ""
        return ""

def safe_line_count(repo_root: str, rel_path: str) -> int:  # L106-112
            return sum(1 for _ in fh)
        return 0

def is_text_candidate(rel_path: str) -> bool:  # L115-124
    return False
        return True
        return True
        return True

def _is_fixture(rel: str) -> bool:  # L127-128
    return "tests/fixtures/" in rel or rel.startswith("tests/fixtures/")

def find_entrypoints(repo_root: str, files: Sequence[str], texts: Dict[str, str]) -> List[Entrypoint]:  # L131-176
    return entrypoints[:8]

def _resolve_shell_source_path(source_token: str, entry_file: str, file_set: Set[str]) -> str:  # L179-200
    return token
        return ""
        return token
            return candidate
                return lib_candidate

def parse_shell_dispatch(entry_file: str, text: str, file_set: Set[str]) -> List[DispatchEntry]:  # L203-258
    return results

def parse_dispatch(entrypoints: Sequence[Entrypoint], texts: Dict[str, str], file_set: Set[str]) -> List[DispatchEntry]:  # L261-287
    return result

def find_test_files(files: Sequence[str]) -> List[str]:  # L290-299
    return sorted(set(tests))

def extract_test_case_count(rel: str, text: str) -> int:  # L302-310
    return 0
        return len(re.findall(r"^\s*test_[A-Za-z0-9_]+\s*\(\)\s*\{", text, flags=re.MULTILINE))
        return len(re.findall(r"^\s*def\s+test_[A-Za-z0-9_]+\s*\(", text, flags=re.MULTILINE))
        return len(re.findall(r"\b(?:it|test)\s*\(\s*[\"']", text))

def extract_assert_count(rel: str, text: str) -> int:  # L313-321
    return 0
        return len(re.findall(r"\bassert_[A-Za-z0-9_]+\b", text))
        return len(re.findall(r"\bassert\b", text))
        return len(re.findall(r"\bexpect\s*\(", text))

def extract_rqs_command_hits(test_texts: Dict[str, str]) -> Counter:  # L324-330
    return hits

def find_runtime_boundaries(texts: Dict[str, str]) -> List[Tuple[str, List[Tuple[str, int, str]]]]:  # L333-358
    return findings

def resolve_internal_dep(rel: str, dep: str, file_set: Set[str]) -> str:  # L361-426
    return ""
        return ""
        return ""
        return ""
            return ""
            return ""
            return ""
                return c
                return c
                return c

def extract_internal_edges(files: Sequence[str], texts: Dict[str, str], file_set: Set[str]) -> Dict[str, Set[str]]:  # L429-468
    return edges

def build_critical_scores(
    files: Sequence[str],  # L471-557
    return scores[:12]

def find_risk_hotspots(texts: Dict[str, str]) -> List[Tuple[str, int, str, str]]:  # L560-590
    return hotspots
                return hotspots

def render_orientation(
    entrypoints: Sequence[Entrypoint],  # L593-664
    ...

def render_runtime_boundaries(findings: Sequence[Tuple[str, List[Tuple[str, int, str]]]]) -> None:  # L667-679
    ...

def render_behavioral_contract(
    test_files: Sequence[str],  # L682-706
        return

def render_risk_hotspots(hotspots: Sequence[Tuple[str, int, str, str]]) -> None:  # L710-735
        return

def main() -> None:  # L739-792
    ...
```
</file>
<file path="lib/render.py" language="python">

### `lib/render.py`
```python
# render.py — Markdown rendering layer for repo-query-surface.

def _xml_escape_attr(value):  # L19-27
    # Escape attribute values for XML-style wrapper tags.
    return (str(value)
        return ""

def _open_tag(tag, **attrs):  # L30-36
    # Emit a simple XML-style opening tag.

def _close_tag(tag):  # L39-41
    # Emit a simple XML-style closing tag.

def build_tree(file_list, max_depth):  # L47-65
    # Build a nested dict tree from a flat list of file paths.
    return tree, dirs

def render_tree_lines(tree, dirs, prefix="", path_prefix="", line_counts=None):  # L68-88
    # Render tree dict into indented lines with box-drawing characters.
    return lines

def render_tree(args):  # L91-130
        return

def _parse_exuberant_tag_line(line: str):  # L150-217
    # Parse a single classic-format Exuberant/Universal ctags line into our tag dict.
    return tag
        return None
        return None
        return None

def parse_ctags_json(lines):  # L219-243
    # Parse ctags output (Universal JSON or classic) into structured records.
    return symbols

def render_symbols(args):  # L245-322
        return

def render_outline(args):  # L328-366
        return

def render_slice(args):  # L372-402
        return

def render_definition(args):  # L408-441
        return

def render_references(args):  # L447-459
        return

def render_deps(args):  # L465-499
        return

def render_grep(args):  # L505-550
        return
        return

def render_summaries(args):  # L556-591
    # Render module/directory summaries from JSON input.
        return
        return

def render_primer(args):  # L597-605
    # Render complete primer from JSON sections.
        return

def _get_docstring_first_line(node):  # L611-621
    # Extract the first line of a docstring from an AST node, or None.
    return None
            return first

def _reconstruct_decorator(node, source_lines):  # L624-626
    # Reconstruct a decorator from source lines.
    return source_lines[node.lineno - 1].rstrip()

def _reconstruct_def_line(node, source_lines):  # L629-636
    # Reconstruct the def/class line from source, handling multi-line.
    return "\n".join(lines)

def _extract_return_lines(node, source_lines):  # L639-648
    # Extract return statement lines from a function body (top-level only, not nested).
    return returns

def _is_direct_child_return(func_node, return_node):  # L651-661
    # Check if a return node belongs directly to func_node (not a nested def).
    return False
            return True
            return True

def _extract_signatures_from_file(filepath, source_lines, indent="", with_spans=False):  # L664-674
    # Extract signatures from a parsed AST file.
    return _extract_signatures_from_body(tree.body, source_lines, indent, is_module=True, with_spans=with_spans)
        return [f"{indent}# (syntax error, could not parse)"]

def _extract_signatures_from_body(body, source_lines, indent="", is_module=False, with_spans=False):  # L677-739
    # Extract signatures from a list of AST body nodes.
    return lines

def _format_ctags_signatures(symbols):  # L758-778
    # Format ctags symbols as signature-style lines.
    return lines
        return []

def _run_ctags_on_file(repo_root, filepath):  # L781-803
    # Run ctags on a single file and return parsed symbols.
    return []
            return parse_ctags_json(result.stdout.strip().split("\n"))
            return parse_ctags_json(result.stdout.strip().split("\n"))

def render_signatures(args):  # L806-897
    # Render file signatures from file list on stdin.
        return
        return

def render_show(args):  # L903-984
    # Render full source of named symbols.
        return

def render_context(args):  # L990-1077
    # Render the enclosing symbol for a given file:line.
        return
        return
        return

def render_diff(args):  # L1083-1117
    # Render git diff output as structured markdown.
        return

def render_files(args):  # L1123-1152
    # Render file list matching a glob pattern, with line counts.
        return

def render_callees(args):  # L1158-1261
    # Render what a function/method calls.
        return
        return
        return
        return

def _extract_python_calls(filepath, source_lines, start, end, symbol_name):  # L1264-1294
    # Extract function/method call names from a Python function body using AST.
    return calls
        return _extract_range_calls(source_lines, start, end)
        return []

def _get_call_name(call_node):  # L1297-1304
    # Extract the function name from an ast.Call node.
    return None
        return func.id
        return func.attr

def _extract_range_calls(source_lines, start, end):  # L1307-1320
    # Fallback: extract call-like patterns from source lines via regex.
    return calls

def _extract_regex_calls(source_lines, start, end, known_symbols, symbol_name):  # L1323-1332
    # Extract call-like patterns and filter against known symbols.
    return calls

def render_related(args):  # L1338-1393
    # Render files related to a given file (forward + reverse deps).

def _truncate_text(text, max_lines):  # L1399-1409
    # Truncate text to max_lines, returning (truncated_text, total_lines).
    return truncated, total
        return "\n".join(lines), total

def _render_notebook_outputs(outputs, max_lines, max_tb):  # L1412-1487
    # Render cell outputs with truncation. Returns list of output strings.
    return result

def render_notebook(args):  # L1490-1579
    # Render a Jupyter notebook as structured markdown.
        return

def _parse_traceback_frames(traceback_lines):  # L1600-1659
    # Parse traceback lines into structured frame dicts.
    return frames

def _classify_frame(frame, repo_root, tracked_files):  # L1662-1686
    # Classify a frame as notebook, repo, or external.
    return frame
        return frame
        return frame
                return frame

def _render_repo_frame_details(repo_frames, repo_root, all_tags):  # L1689-1765
    # Render enclosing function source for repo-local frames with >>> marker.
    return lines

def _is_internal_module(module_name, rel_path, tracked_files):  # L1768-1786
    # Check if a module name maps to a tracked file in the repo.
    return False
            return True

def _render_dependency_trace(repo_frames, repo_root, tracked_files):  # L1789-1842
    # Render import analysis for files involved in the traceback.
    return lines

def _render_diagnostic_summary(cell_index, ename, evalue, frames, repo_frames, filepath):  # L1845-1872
    # Render bullet-point diagnostic summary with suggested commands.
    return lines

def _render_debug_error(cell_index, cell, repo_root, tracked_files, all_tags, filepath):  # L1875-1930
    # Render all debug sections for one error cell.
    return lines

def _render_notebook_debug_no_errors(cells, filepath):  # L1933-1938
    # Render 'no errors found' summary.

def render_notebook_debug(args):  # L1941-2007
    # Render notebook error analysis with traceback cross-referencing.
        return
        return

def _parse_churn_log(content):  # L2016-2040
    # Parse git log --pretty=format:COMMIT --numstat into chronological commit list.
    return commits

def render_churn(args):  # L2043-2121
    # Render file modification heatmap from git log --numstat output.
        return

def main():  # L2151-2168
    ...
```
</file>
<file path="bin/rqs" language="text">

### `bin/rqs`
```
function: resolve_target_repo [L17]
```
</file>
<file path="lib/rqs_callees.sh" language="bash">

### `lib/rqs_callees.sh`
```bash
function: cmd_callees [L4]
```
</file>
<file path="lib/rqs_common.sh" language="bash">

### `lib/rqs_common.sh`
```bash
function: rqs_build_ignore_regex [L8]
function: patterns= [L10]
function: rqs_load_config [L23]
function: rqs_validate_rqsrc [L40]
function: rqs_list_files [L63]
function: rqs_is_text_file [L70]
function: rqs_resolve_path [L82]
function: rqs_relative_path [L107]
function: rqs_detect_ctags [L119]
function: rqs_has_ctags [L149]
function: rqs_ctags_args [L154]
function: rqs_cache_dir [L167]
function: rqs_cache_ctags [L171]
function: rqs_run_ctags_file [L201]
function: rqs_render [L210]
function: rqs_error [L218]
function: rqs_warn [L223]
```
</file>
<file path="lib/rqs_context.sh" language="bash">

### `lib/rqs_context.sh`
```bash
function: cmd_context [L4]
```
</file>
<file path="lib/rqs_definition.sh" language="bash">

### `lib/rqs_definition.sh`
```bash
function: cmd_definition [L4]
function: definition_grep_fallback [L42]
```
</file>
<file path="lib/rqs_deps.sh" language="bash">

### `lib/rqs_deps.sh`
```bash
function: cmd_deps [L4]
function: deps_python_ast [L61]
function: f.read [L74]
function: set [L80]
function: result.stdout.strip [L84]
function: deps_regex [L133]
function: is_internal_dep [L173]
function: candidates= [L188]
```
</file>
<file path="lib/rqs_diff.sh" language="bash">

### `lib/rqs_diff.sh`
```bash
function: cmd_diff [L4]
function: diff_args= [L36]
```
</file>
<file path="lib/rqs_files.sh" language="bash">

### `lib/rqs_files.sh`
```bash
function: cmd_files [L4]
```
</file>
<file path="lib/rqs_grep.sh" language="bash">

### `lib/rqs_grep.sh`
```bash
function: cmd_grep [L4]
```
</file>
<file path="lib/rqs_notebook.sh" language="bash">

### `lib/rqs_notebook.sh`
```bash
function: cmd_notebook [L4]
```
</file>
<file path="lib/rqs_outline.sh" language="bash">

### `lib/rqs_outline.sh`
```bash
function: cmd_outline [L4]
function: outline_grep_fallback [L52]
```
</file>
<file path="lib/rqs_primer.sh" language="bash">

### `lib/rqs_primer.sh`
```bash
function: cmd_primer [L4]
function: primer_strategy_context [L109]
function: primer_readme_summary [L114]
function: primer_symbol_index [L136]
function: primer_module_summaries [L156]
function: [line.strip [L172]
function: line.strip [L172]
function: dirs.keys [L206]
function: primer_dependency_wiring [L221]
function: dep_files= [L236]
function: dep_imports= [L237]
```
</file>
<file path="lib/rqs_prompt.sh" language="bash">

### `lib/rqs_prompt.sh`
```bash
function: cmd_prompt [L4]
```
</file>
<file path="lib/rqs_references.sh" language="bash">

### `lib/rqs_references.sh`
```bash
function: cmd_references [L4]
```
</file>
<file path="lib/rqs_related.sh" language="bash">

### `lib/rqs_related.sh`
```bash
function: cmd_related [L4]
function: related_python_forward [L67]
function: f.read [L80]
function: set [L84]
function: result.stdout.strip [L88]
function: set [L115]
function: related_regex_forward [L133]
function: candidates= [L157]
function: related_reverse [L177]
function: patterns= [L187]
function: found= [L212]
```
</file>
<file path="lib/rqs_show.sh" language="bash">

### `lib/rqs_show.sh`
```bash
function: cmd_show [L4]
function: symbols= [L5]
```
</file>
<file path="lib/rqs_signatures.sh" language="bash">

### `lib/rqs_signatures.sh`
```bash
function: cmd_signatures [L4]
```
</file>
<file path="lib/rqs_slice.sh" language="bash">

### `lib/rqs_slice.sh`
```bash
function: cmd_slice [L4]
```
</file>
<file path="lib/rqs_symbols.sh" language="bash">

### `lib/rqs_symbols.sh`
```bash
function: cmd_symbols [L4]
function: symbols_grep_fallback [L66]
```
</file>
<file path="lib/rqs_tree.sh" language="bash">

### `lib/rqs_tree.sh`
```bash
function: cmd_tree [L4]
```
</file>
<file path="tests/run_tests.sh" language="bash">

### `tests/run_tests.sh`
```bash
function: setup_fixture [L16]
function: cleanup_fixture [L22]
function: assert_contains [L31]
function: assert_not_contains [L46]
function: assert_exit_code [L61]
function: test_tree [L80]
function: test_symbols [L107]
function: test_outline [L125]
function: test_slice [L141]
function: test_definition [L160]
function: test_references [L174]
function: test_deps [L186]
function: test_grep [L200]
function: test_primer [L218]
function: test_help [L285]
function: test_prompt [L314]
function: test_signatures [L349]
function: test_show [L400]
function: test_context [L433]
function: test_diff [L465]
function: test_files [L494]
function: test_callees [L524]
function: test_related [L555]
function: test_churn [L582]
function: test_notebook [L603]
function: test_notebook_debug [L660]
function: test_errors [L713]
```
</file>
</signatures>

## Internal Dependencies

*(no internal dependencies detected)*

<churn>
## Churn
> 16 commits, 37 files touched. Commits = number of commits that modified the file. Lines = total lines added + deleted. History = per-file activity binned into 2 buckets of 10 commits each (oldest → newest), shaded by lines changed relative to the global max.

| Commits | Lines | History | File                                                    |
|---------|-------|---------|---------------------------------------------------------|
|       8 |  2099 | `█░`    | `lib/render.py`                                         |
|       9 |   939 | `░░`    | `lib/rqs_primer.sh`                                     |
|       3 |   801 | `▒░`    | `lib/primer_insights.py`                                |
|       9 |   777 | `▒░`    | `tests/run_tests.sh`                                    |
|       8 |   520 | `░░`    | `README.md`                                             |
|       3 |   272 | `░░`    | `lib/rqs_prompt.sh`                                     |
|       3 |   237 | `░░`    | `lib/rqs_common.sh`                                     |
|       2 |   232 | `░ `    | `lib/rqs_deps.sh`                                       |
|       2 |   231 | `░ `    | `lib/rqs_related.sh`                                    |
|       4 |   183 | `░ `    | `bin/rqs`                                               |
|       3 |   113 | `░ `    | `lib/rqs_slice.sh`                                      |
|       2 |   110 | `░ `    | `lib/rqs_symbols.sh`                                    |
|       1 |   104 | `░ `    | `tests/fixtures/sample-repo/notebooks/analysis.ipynb`   |
|       1 |    97 | `░ `    | `lib/rqs_outline.sh`                                    |
|       3 |    88 | `░ `    | `lib/rqs_signatures.sh`                                 |
|       1 |    82 | `░ `    | `lib/rqs_notebook.sh`                                   |
|       1 |    78 | `░ `    | `tests/fixtures/sample-repo/notebooks/debug_test.ipynb` |
|       1 |    67 | `░ `    | `lib/rqs_definition.sh`                                 |
|       1 |    65 | `░ `    | `lib/rqs_context.sh`                                    |
|       2 |    60 | `░░`    | `lib/rqs_files.sh`                                      |
</churn>

</repository_primer>
