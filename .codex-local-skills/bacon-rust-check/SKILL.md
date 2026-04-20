---
name: bacon-rust-check
description: Use this skill when the user wants Codex to use bacon to check a Rust project, validate a Cargo workspace with bacon, or prefer bacon over cargo for compile diagnostics. This skill covers finding the correct Cargo root, verifying that bacon is installed, falling back to Nix to provide bacon when requested, checking the local bacon CLI help before choosing flags, running the appropriate bacon check command from the Rust project root, and reporting actionable failures when bacon is missing or requires an interactive TTY.
---

# Bacon Rust Check

Use this skill when the user explicitly wants `bacon` involved in checking a Rust project.

## Workflow

1. Find the Rust project root before running anything.
   Use `rg --files -g 'Cargo.toml'` or equivalent and choose the Cargo manifest that matches the user's target.

2. Run bacon from the Cargo root.
   `bacon` should be launched in the directory containing the relevant `Cargo.toml` unless the repository clearly uses a workspace root for checks.

3. Verify the local bacon binary instead of assuming flags.
   Check `command -v bacon` first.
   If present, inspect `bacon --help` before choosing any non-default flags.

4. If `bacon` is missing and the user allows a fallback, use Nix to provide it.
   Prefer the repository development shell first when the repo is Nix-based:
   `nix develop -c bacon --help`
   If that does not expose `bacon`, try an explicit package shell:
   `nix shell nixpkgs#bacon -c bacon --help`
   After a Nix fallback succeeds, continue using that same invocation pattern for the actual check command.

5. Prefer a one-shot or headless bacon check only when the installed bacon version documents that mode.
   If the local help text exposes a non-interactive option, use it for automation.
   If it does not, fall back to `bacon check` and report that the installed bacon version may expect a TTY.

6. Respect repository bacon config when present.
   If `bacon.toml` or `.bacon.toml` exists, do not override its job setup unless the user asks.

## Command Pattern

Use this sequence:

```bash
command -v bacon
bacon --help
rg --files -g 'Cargo.toml'
cd /path/to/rust/project
bacon check
```

If the installed help output documents a non-interactive mode, adapt the last command to that supported form.

When `bacon` is not already installed, use one of these Nix-backed forms instead:

```bash
cd /path/to/rust/project
nix develop -c bacon --help
nix develop -c bacon check
```

```bash
cd /path/to/rust/project
nix shell nixpkgs#bacon -c bacon --help
nix shell nixpkgs#bacon -c bacon check
```

## Failure Handling

- If `bacon` is missing, say so plainly. If the user asked for or allowed a fallback, try the Nix path before giving up. Do not silently replace it with `cargo check` unless the user asks for that fallback.
- If multiple `Cargo.toml` files exist, choose the workspace root when that is the normal entry point; otherwise target the crate implied by the user's request.
- If `bacon` fails because it needs an interactive terminal, say that directly and include the exact command that was attempted.
- If a Nix fallback fails, report whether `nix develop` failed because the repo shell lacks `bacon` or whether `nix shell nixpkgs#bacon` failed because the package could not be resolved or fetched.
- When reporting results, summarize the first actionable compiler errors instead of dumping raw logs.
