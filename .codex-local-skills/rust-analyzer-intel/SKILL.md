---
name: rust-analyzer-intel
description: Use this skill when working in a Rust codebase and you want rust-analyzer to extract structure instead of reading large files linearly. This skill covers using rust-analyzer to list symbols from a Rust file, inspect parse trees, gather project diagnostics, find unresolved references, and use structure-aware search so Codex can pull the relevant bits of a Rust project faster and with less fluff.
---

# Rust Analyzer Intel

Use this skill when the task is better served by Rust semantic tooling than by manually scanning source files.

## When To Use It

- The user wants a list of symbols from a Rust file or module.
- You need a quick structural view before opening a large Rust file.
- You want project diagnostics or unresolved references without running a full manual read.
- You need syntax-aware search in Rust code.

## Workflow

1. Confirm the tool shape locally before depending on a subcommand.
   Run `rust-analyzer --help` because subcommands are not stable across versions.

2. Find the relevant Cargo root or Rust file.
   Use `rg --files -g 'Cargo.toml' -g '*.rs'`.

3. Start with the narrowest semantic query that can answer the question.
   Prefer `symbols` or `parse --json` on a single file before opening a long file.

4. Escalate to project-wide analysis only when file-level output is not enough.
   Use `diagnostics`, `unresolved-references`, or `analysis-stats` on the Cargo root.

5. Open source files only after the semantic pass identifies the relevant area.
   This keeps context focused on the symbols or diagnostics that matter.

## Command Patterns

List symbols from a file:

```bash
rust-analyzer symbols < path/to/file.rs
```

Inspect the parsed structure of a file:

```bash
rust-analyzer parse --json < path/to/file.rs
```

Gather diagnostics for a crate or workspace:

```bash
cd /path/to/cargo-root
rust-analyzer diagnostics .
```

Find unresolved references:

```bash
cd /path/to/cargo-root
rust-analyzer unresolved-references .
```

Collect broader semantic stats when needed:

```bash
cd /path/to/cargo-root
rust-analyzer analysis-stats .
```

Run structured search when plain text grep is too noisy:

```bash
cd /path/to/cargo-root
rust-analyzer search 'SomeType($a)'
```

## Query Selection

- For file outline or quick triage: use `symbols`.
- For exact syntactic shape: use `parse --json`.
- For workspace health: use `diagnostics`.
- For missing names or broken links: use `unresolved-references`.
- For structural pattern search: use `search`.
- For rewrites only when explicitly needed: use `ssr`.

## Constraints

- `rust-analyzer symbols` and `parse` operate on stdin, so feed them a specific file.
- Project-wide commands should run from the directory containing the relevant `Cargo.toml`.
- Build scripts and proc macros can affect analysis quality. If results look incomplete, inspect `rust-analyzer --help` for supported flags on the installed version before retrying.
- Do not assume output schemas are stable across rust-analyzer versions.

## Reporting

- Return the smallest useful result: symbol list, relevant diagnostics, or matched structural pattern.
- Summarize the semantic findings first, then open only the files that those findings point to.
- If rust-analyzer is missing, say so plainly instead of pretending the result is authoritative.
