#!/usr/bin/env python3

from __future__ import annotations

import argparse
import pathlib
import subprocess
import tempfile
from collections import defaultdict
from dataclasses import dataclass, field
from typing import DefaultDict, List


@dataclass
class Entry:
    source: str
    name: str = ""
    path: str = ""
    kind: str = ""
    summary: str = ""
    params: List[str] = field(default_factory=list)
    returns: List[str] = field(default_factory=list)
    examples: List[str] = field(default_factory=list)


def parse_file(path: pathlib.Path, display_source: str) -> List[Entry]:
    if not path.exists():
        raise FileNotFoundError(f"doc source missing: {path}")

    entries: List[Entry] = []
    current: List[str] = []

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip("\n")
        stripped = line.lstrip()

        if stripped.startswith("##@"):
            current.append(stripped[3:].strip())
            continue

        if current:
            entry = build_entry(display_source, current)
            if entry.name:
                entries.append(entry)
            current = []

    if current:
        entry = build_entry(display_source, current)
        if entry.name:
            entries.append(entry)

    return entries


def build_entry(display_source: str, lines: List[str]) -> Entry:
    entry = Entry(source=display_source)

    for line in lines:
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()

        if key == "name":
            entry.name = value
        elif key == "path":
            entry.path = value
        elif key == "kind":
            entry.kind = value
        elif key == "summary":
            entry.summary = value
        elif key == "param":
            entry.params.append(value)
        elif key == "returns":
            entry.returns.append(value)
        elif key == "example":
            entry.examples.append(value)

    return entry


def format_nix(code: str, nixfmt: str | None) -> str:
    if not nixfmt:
        return code

    tmp_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".nix", delete=False, encoding="utf-8") as f:
            f.write(code)
            tmp_path = pathlib.Path(f.name)

        subprocess.run(
            [nixfmt, str(tmp_path)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        return tmp_path.read_text(encoding="utf-8").rstrip("\n")
    except Exception:
        return code
    finally:
        if tmp_path is not None:
            try:
                tmp_path.unlink()
            except FileNotFoundError:
                pass


def slugify(text: str) -> str:
    slug = text.strip().lower()
    out: List[str] = []
    last_dash = False

    for ch in slug:
        if ch.isalnum():
            out.append(ch)
            last_dash = False
        else:
            if not last_dash:
                out.append("-")
                last_dash = True

    return "".join(out).strip("-")


def render_entry(entry: Entry, nixfmt: str | None) -> List[str]:
    out: List[str] = []

    out.append(f"### {entry.name}")
    out.append("")
    if entry.summary:
        out.append(entry.summary)
        out.append("")

    if entry.path:
        out.append(f"- **Path:** `{entry.path}`")
    out.append(f"- **Kind:** `{entry.kind or 'unknown'}`")
    out.append(f"- **Source:** `{entry.source}`")
    out.append("")

    if entry.params:
        out.append("#### Parameters")
        out.append("")
        for param in entry.params:
            parts = param.split(" ", 2)
            if len(parts) == 1:
                name, typ, desc = parts[0], "", ""
            elif len(parts) == 2:
                name, typ, desc = parts[0], parts[1], ""
            else:
                name, typ, desc = parts
            if typ:
                out.append(f"- `{name}` *{typ}* — {desc}")
            else:
                out.append(f"- `{name}` — {desc}")
        out.append("")

    if entry.returns:
        out.append("#### Returns")
        out.append("")
        for ret in entry.returns:
            out.append(f"- {ret}")
        out.append("")

    if entry.examples:
        out.append("#### Examples")
        out.append("")
        for example in entry.examples:
            formatted = format_nix(example, nixfmt)
            out.append("```nix")
            out.append(formatted)
            out.append("```")
            out.append("")

    return out


def render(entries: List[Entry], title: str, nixfmt: str | None) -> str:
    grouped: DefaultDict[str, List[Entry]] = defaultdict(list)
    for entry in entries:
        grouped[entry.kind or "unknown"].append(entry)

    kind_order = ["function", "helper", "registry", "module", "unknown"]
    present_kinds = [k for k in kind_order if k in grouped]
    remaining_kinds = sorted(k for k in grouped.keys() if k not in kind_order)
    all_kinds = present_kinds + remaining_kinds

    out: List[str] = []
    out.append(f"# {title}")
    out.append("")

    out.append("## Table of contents")
    out.append("")
    for kind in all_kinds:
        kind_title = kind.capitalize()
        out.append(f"- [{kind_title}](#{slugify(kind_title)})")
        for entry in sorted(grouped[kind], key=lambda e: (e.path or e.name).lower()):
            toc_label = entry.path if entry.path else entry.name
            out.append(f"  - [{toc_label}](#{slugify(entry.name)})")
    out.append("")

    for kind in all_kinds:
        kind_title = kind.capitalize()
        out.append(f"## {kind_title}")
        out.append("")
        for entry in sorted(grouped[kind], key=lambda e: (e.path or e.name).lower()):
            out.extend(render_entry(entry, nixfmt))

    return "\n".join(out).rstrip() + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", default="Antinix API Reference")
    parser.add_argument("--output", required=True)
    parser.add_argument("--nixfmt", default=None)
    parser.add_argument("inputs", nargs="+")
    args = parser.parse_args()

    entries: List[Entry] = []
    for input_path in args.inputs:
        path = pathlib.Path(input_path)
        entries.extend(parse_file(path, input_path))

    if not entries:
        raise RuntimeError("No API doc entries found. Did you forget ##@ comments?")

    output = render(entries, args.title, args.nixfmt)
    pathlib.Path(args.output).write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
