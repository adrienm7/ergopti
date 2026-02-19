#!/usr/bin/env python3
"""
Generate Lua modules for Hammerspoon from TOML hotstrings.

Usage:
    python3 generate_hotstrings_lua.py

This script walks the ../hotstrings directory, parses TOML files,
and writes a Lua file per TOML in generated_hotstrings/ which calls
`keymap.add(input, output, is_word)` for each entry.
"""

from __future__ import annotations

import tomllib
from pathlib import Path


def escape_lua(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def extract_entries(data):
    entries = []
    # case: list of tables
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and "input" in item and "output" in item:
                entries.append(
                    (
                        item["input"],
                        item["output"],
                        bool(item.get("is_word", False)),
                    )
                )
            elif isinstance(item, dict):
                # item like { "trigger" = { output=..., is_word=... }, ... }
                for tk, tv in item.items():
                    if isinstance(tv, dict) and "output" in tv:
                        entries.append(
                            (
                                tk,
                                tv.get("output"),
                                bool(tv.get("is_word", False)),
                            )
                        )
        return entries

    if isinstance(data, dict):
        # simple mapping: key -> string
        if all(isinstance(v, str) for v in data.values()):
            for k, v in data.items():
                entries.append((k, v, False))
            return entries

        # mixed: keys may map to dicts or lists
        for k, v in data.items():
            if isinstance(v, str):
                entries.append((k, v, False))
            elif isinstance(v, dict):
                out = v.get("output") or v.get("value")
                if out is not None:
                    entries.append((k, out, bool(v.get("is_word", False))))
                elif "input" in v and "output" in v:
                    entries.append(
                        (v["input"], v["output"], bool(v.get("is_word", False)))
                    )
                else:
                    # v may be a mapping of triggers -> {output=..., is_word=...}
                    for tk, tv in v.items():
                        if isinstance(tv, dict) and "output" in tv:
                            entries.append(
                                (
                                    tk,
                                    tv.get("output"),
                                    bool(tv.get("is_word", False)),
                                )
                            )
            elif isinstance(v, list):
                for item in v:
                    if (
                        isinstance(item, dict)
                        and "input" in item
                        and "output" in item
                    ):
                        entries.append(
                            (
                                item["input"],
                                item["output"],
                                bool(item.get("is_word", False)),
                            )
                        )
                    elif isinstance(item, dict):
                        # item like { "trigger" = { output=..., is_word=... }, ... }
                        for tk, tv in item.items():
                            if isinstance(tv, dict) and "output" in tv:
                                entries.append(
                                    (
                                        tk,
                                        tv.get("output"),
                                        bool(tv.get("is_word", False)),
                                    )
                                )
    return entries


def main():
    script_dir = Path(__file__).resolve().parent
    hotstrings_dir = script_dir.parent / "hotstrings"
    out_dir = script_dir / "generated_hotstrings"
    out_dir.mkdir(exist_ok=True)

    toml_files = list(hotstrings_dir.rglob("*.toml"))
    for toml_path in toml_files:
        try:
            text = toml_path.read_text(encoding="utf-8")
            parsed = tomllib.loads(text)
        except Exception as e:
            print(f"Skipping {toml_path}: cannot parse TOML ({e})")
            continue

        entries = extract_entries(parsed)
        if not entries:
            continue

        rel = toml_path.relative_to(hotstrings_dir)
        name = "_".join(rel.with_suffix("").parts)
        out_file = out_dir / f"{name}.lua"

        lines = []
        lines.append("-- Generated from " + str(toml_path))
        lines.append('local keymap = require("keymap")')
        lines.append("")
        for inp, out, is_word in entries:
            lines.append(
                f"keymap.add({escape_lua(inp)}, {escape_lua(out)}, {'false' if is_word else 'true'})"
            )

        out_file.write_text("\n".join(lines), encoding="utf-8")
        print("Wrote", out_file)


if __name__ == "__main__":
    main()
