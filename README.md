# repo-query-surface

A Linux-native approach for exposing **structured, queryable repository context** to large language models (LLMs) without granting direct repository access.

---

## Philosophy

LLMs do not reason effectively over raw source trees or large code dumps.  
They reason over **intent, structure, boundaries, and behavior**.

This project treats a repository not as text to ingest, but as a system to be **interrogated**.

The goal is to translate a codebase into a **semantic surface** that:
- is small enough to fit in an LLM context window
- preserves architectural signal
- can be incrementally expanded on demand
- mirrors how experienced engineers explore unfamiliar code

---

## Core Principles

### 1. Structure Before Detail
High-level structure (modules, symbols, dependencies) is more valuable than full file contents.  
Raw code is disclosed only when necessary and only in precise slices.

### 2. Deterministic Context
All context is produced using basic, ubiquitous tools (`find`, `grep`, `ctags`, `sed`, `python`).
No opaque indexing, no embeddings, no hidden state.

If a human can reproduce it on a Linux shell, the LLM can reason about it.

### 3. Fixed Query Surface
The LLM does not ask for “more code” in free form.
It requests additional context using a small, predefined set of commands
(e.g. file slices, symbol lookups, call sites).

This keeps interactions:
- auditable
- token-efficient
- free of accidental over-disclosure

### 4. Incremental Disclosure
Start with a static primer:
- repository tree
- symbol index
- module summaries
- dependency wiring

Then iteratively reveal deeper context only as required to answer a specific question.

### 5. Human-in-the-Loop by Design
A human controls:
- what context is generated
- what context is shared
- when iteration stops

This is not autonomous code understanding.
It is **assisted reasoning**.

---

## What This Is Not

- Not a code ingestion pipeline
- Not a vector database
- Not an “upload your repo to an LLM” solution
- Not language- or vendor-specific

---

## Mental Model

Think of this as providing an LLM with:
- a symbol table
- an architectural map
- a controlled debugger view

Not a filesystem.

---

## Outcome

With this approach, an LLM can:
- reason about unfamiliar repositories
- answer design and debugging questions
- suggest changes with awareness of boundaries
- request exactly the context it needs—no more, no less

All while keeping the repository local, private, and under human control.

