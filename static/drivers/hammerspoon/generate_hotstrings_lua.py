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
                        bool(item.get("auto_expand", False)),
                        bool(item.get("is_case_sensitive", False)),
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
                                bool(tv.get("auto_expand", False)),
                                bool(tv.get("is_case_sensitive", False)),
                            )
                        )
        return entries

    if isinstance(data, dict):
        # simple mapping: key -> string
        if all(isinstance(v, str) for v in data.values()):
            for k, v in data.items():
                entries.append((k, v, False, False, False))
            return entries

        # mixed: keys may map to dicts or lists
        for k, v in data.items():
            if isinstance(v, str):
                entries.append((k, v, False, False, False))
            elif isinstance(v, dict):
                out = v.get("output") or v.get("value")
                if out is not None:
                    entries.append(
                        (
                            k,
                            out,
                            bool(v.get("is_word", False)),
                            bool(v.get("auto_expand", False)),
                            bool(v.get("is_case_sensitive", False)),
                        )
                    )
                elif "input" in v and "output" in v:
                    entries.append(
                        (
                            v["input"],
                            v["output"],
                            bool(v.get("is_word", False)),
                            bool(v.get("auto_expand", False)),
                            bool(v.get("is_case_sensitive", False)),
                        )
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
                                    bool(tv.get("auto_expand", False)),
                                    bool(tv.get("is_case_sensitive", False)),
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
                                bool(item.get("auto_expand", False)),
                                bool(item.get("is_case_sensitive", False)),
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
                                        bool(tv.get("auto_expand", False)),
                                        bool(
                                            tv.get("is_case_sensitive", False)
                                        ),
                                    )
                                )
    return entries


def main():
    script_dir = Path(__file__).resolve().parent
    hotstrings_dir = script_dir.parent / "hotstrings"
    out_dir = script_dir / "generated_hotstrings"
    out_dir.mkdir(exist_ok=True)

    toml_files = list(hotstrings_dir.rglob("*.toml"))
    descriptions: dict[str, str] = {}
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
        for inp, out, is_word, auto_expand, case_sensitive in entries:
            # emit named-argument table for clarity: { is_word=..., auto_expand=..., is_case_sensitive=... }
            is_word_lua = "true" if is_word else "false"
            auto_lua = "true" if auto_expand else "false"
            case_lua = "true" if case_sensitive else "false"
            opts_table = f"{{is_word = {is_word_lua}, auto_expand = {auto_lua}, is_case_sensitive = {case_lua}}}"
            lines.append(
                f"keymap.add({escape_lua(inp)}, {escape_lua(out)}, {opts_table})"
            )

        out_file.write_text("\n".join(lines), encoding="utf-8")
        print("Wrote", out_file)
        # extract description: top-level or common nested sections (metadata, meta, info)
        desc = None
        if isinstance(parsed, dict):
            for key in ("description", "desc", "title"):
                v = parsed.get(key)
                if isinstance(v, str) and v.strip():
                    desc = v.strip()
                    break
            if not desc:
                # common nested containers
                for container in ("metadata", "meta", "info", "header"):
                    c = parsed.get(container)
                    if isinstance(c, dict):
                        for key in ("description", "desc", "title"):
                            v = c.get(key)
                            if isinstance(v, str) and v.strip():
                                desc = v.strip()
                                break
                    if desc:
                        break
            if not desc:
                # scan first-level child tables for a description
                for v in parsed.values():
                    if isinstance(v, dict):
                        for key in ("description", "desc", "title"):
                            dv = v.get(key)
                            if isinstance(dv, str) and dv.strip():
                                desc = dv.strip()
                                break
                    if desc:
                        break
        if desc:
            descriptions[name] = desc

    # write descriptions table for menu consumption
    if descriptions:
        desc_file = out_dir / "_descriptions.lua"
        desc_lines = []
        desc_lines.append("-- Generated descriptions for hotstrings")
        desc_lines.append("return {")
        for k in sorted(descriptions.keys()):
            v = descriptions[k]
            desc_lines.append(f"  {k} = {escape_lua(v)},")
        desc_lines.append("}")
        desc_file.write_text("\n".join(desc_lines), encoding="utf-8")
        print("Wrote", desc_file)


if __name__ == "__main__":
    main()
