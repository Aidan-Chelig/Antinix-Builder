# API Reference Spec

This document defines the contract for the Antinix API reference generator and the `##@` docgen comments it consumes.

The goal is not to create a general documentation system. The goal is to keep the public Nix API documented in-place, close to the code that defines it, with a format simple enough to maintain by hand.

## Scope

The API reference app is built from [docs/api-reference.nix](/home/icy/development/rework/docs/api-reference.nix), which runs [tools/generate-api-docs.py](/home/icy/development/rework/tools/generate-api-docs.py) over a fixed allowlist of source files.

Today the generator only reads files explicitly listed in `docSources` inside `docs/api-reference.nix`. Adding `##@` comments to some other file does nothing until that file is added to that list.

This is intentional. The published API reference is curated, not repo-wide.

## Build Surface

Regenerate the reference with:

```bash
nix build .#api-reference
```

The result is a single Markdown file, `API.md`, grouped by entry kind and rendered from the in-source `##@` blocks.

## Docgen Block Format

The generator only understands contiguous lines that begin with `##@`.

Example:

```nix
##@ name: mkSystem
##@ path: lib.mkSystem
##@ kind: function
##@ summary: Build a system spec and produce rootfs and image artifacts.
##@ param: name string? System name used for artifact naming.
##@ returns: attrset containing config, rootfs, image, and debug helpers.
##@ example: antinixLib.mkSystem { name = "demo"; init = "openrc"; }
```

Each line is parsed as `key: value`. Unknown keys are ignored. A block without `name:` is discarded.

Supported keys are:

- `name`: Display title for the entry. Required.
- `path`: Public API path shown in the generated reference.
- `kind`: Grouping bucket. Current common values are `function`, `helper`, `registry`, and `module`.
- `summary`: One-line description of the entry.
- `param`: A parameter record rendered in the Parameters section.
- `returns`: A return value record rendered in the Returns section.
- `example`: A Nix example rendered in a fenced code block.

## Parsing Rules

The parser behavior is intentionally strict and simple:

- A doc block begins on the first `##@` line.
- A doc block ends on the first following line that does not start with `##@`.
- Blank lines terminate a block.
- Normal `#` comments, code, or whitespace between `##@` lines terminate the block.
- Multiple `param`, `returns`, and `example` lines are allowed.
- A colon is required to split key from value.
- The generator does not inspect the code that follows. It only records the comment block and the source file path.

This means placement matters. Keep each `##@` block contiguous and directly above the public value it documents.

## Where To Use `##@` Comments

Use `##@` comments on public, consumer-facing API surface that appears in the generated reference.

Good targets:

- Top-level flake outputs such as `flake.libFor` and `flake.lib`.
- Public library entrypoints in [lib/default.nix](/home/icy/development/rework/lib/default.nix).
- Public builders such as `mkSystem`, `mkInitrd`, `mkRunVm`, and image builders.
- Public profile functions exposed through `lib.profiles.*`.
- Public schema helpers exposed through `lib.schema.*`.
- Public submodules or registries that are useful to navigate as modules in the rendered reference.

Do not use `##@` for:

- Private locals inside a file.
- Short-lived implementation helpers.
- Internal intermediate values that are not part of the supported API.
- Every nested attribute in a large returned attrset unless that nested attribute is intentionally part of the public API surface.

The generated reference should describe how consumers use Antinix, not every internal binding.

## When To Add Or Update Comments

Add or update `##@` blocks when:

- You add a new public function, helper, registry, or module in an allowlisted file.
- You change a public function signature.
- You add, remove, or rename a meaningful parameter.
- You change the behavior or return shape in a way a consumer needs to know.
- You expose a new public output on a returned attrset, such as a new `mkSystem` result field.

You usually do not need to update docs for:

- Refactors that do not change consumer-visible behavior.
- Internal helper changes.
- Pure formatting or naming cleanup inside implementation details.

As a rule: if a user of the public Nix API would need to change how they call something, the `##@` block should change in the same commit.

## Placement Rules

Place each block immediately above the thing it documents.

Patterns already used in this repo:

- A block above a top-level exported attr, as in [flake.nix](/home/icy/development/rework/flake.nix:71).
- A block above a public function definition, as in [lib/system/mk-system.nix](/home/icy/development/rework/lib/system/mk-system.nix:79).
- A block inside a returned attrset for a public nested module, as in [lib/system/mk-system.nix](/home/icy/development/rework/lib/system/mk-system.nix:428).

Keep the block physically close to the exported value so future edits naturally update both.

## Writing Rules

Keep entries compact and factual.

- `summary` should be one sentence.
- Prefer describing user-visible behavior, not implementation detail.
- Use `path` for the public path a consumer should think in, not a local variable name.
- List parameters in the same language and naming the code uses.
- Include `?` in the type when the parameter is optional if that improves clarity.
- Use `returns` to describe the shape or role of the returned value, not implementation trivia.
- Add an `example` when the call shape is non-obvious or the function is central enough to justify one.

## Parameter Line Format

The renderer splits each `param:` line into three parts:

```text
name type description...
```

Examples:

- `##@ param: system string Host platform to target.`
- `##@ param: imageSize string? Optional size passed to the ext4 builder.`
- `##@ param: extraPackages list? Additional packages included alongside Labwc.`

If the description is missing, the entry still renders, but it is lower quality. Prefer full descriptions for public functions.

## Kind Guidelines

Use these kinds consistently:

- `function`: Callable public builder or profile function.
- `helper`: Small constructor or predicate helper, typically under `lib.schema`.
- `registry`: Attrset namespace whose main value is discoverability, such as available init systems.
- `module`: Public attrset/module-like namespace or returned submodule.

If a new kind is introduced, the generator will still render it, but it will appear after the known kinds. Add a new kind only if the distinction is useful to readers.

## Source Selection Rules

Only add a file to `docs/api-reference.nix` when it defines stable public API that belongs in the published reference.

Good candidates:

- Public library entrypoints.
- Public profile namespaces.
- Public schema and builder APIs.

Bad candidates:

- Low-level implementation files.
- One-off example flakes.
- Files whose contents are primarily internal wiring.

The allowlist should stay intentionally small.

## Examples

Minimal module entry:

```nix
##@ name: profiles
##@ path: lib.profiles
##@ kind: module
##@ summary: Reusable system fragments for boot, virtualization, runtime, session, and graphical setups.
##@ returns: Attrset exposing boot, vm, runtime, session, and graphical profile helpers.
```

Function entry with parameters:

```nix
##@ name: qemuGuest
##@ path: lib.profiles.vm.qemuGuest
##@ kind: function
##@ summary: Add VM-oriented defaults for console, networking, and device setup.
##@ param: graphics bool? Enable graphical console support.
##@ param: enableUdev bool? Install and start udev support.
##@ returns: Fragment suitable for VM-focused systems.
```

Nested returned module entry:

```nix
##@ name: patcher
##@ path: system.debug.patcher
##@ kind: module
##@ summary: Prewired rootfs-patcher debug inputs and dry-run launchers for this system's rootfs tree.
##@ returns: Attrset exposing `mergePlan`, `rewritePlan`, `processPlan`, and generated patcher inputs.
```

## Non-Goals

This system does not currently:

- Validate that a documented symbol actually exists.
- Validate parameter names against function arguments.
- Infer docs from code.
- Follow comments across files automatically.
- Generate per-file or per-module ownership metadata.

Because of that, accuracy depends on keeping the `##@` blocks maintained alongside code changes.

## Maintenance Rule

When you change public API, update the `##@` block in the same patch and regenerate `API.md`.

That is the contract.
