#!/usr/bin/env python3
"""
==============================================================================
MODULE: TOML Hotstrings Compiler
DESCRIPTION:
Reads the TOML hotstring files under ``static/ergopti_plus/_shared/hotstrings/`` and emits one
AHK file per category plus a thin ``hotstrings_generated.ahk`` entry-point
that ``#Include``s all per-category files. This replaces the runtime
regex-based TOML parser for the bundled categories — the driver boots without
touching the TOML payload at all.

FEATURES & RATIONALE:
1. Startup cost collapses: the bundled categories (~3 000 entries across five
   files) no longer go through a per-line regex parse at every ``.exe`` launch.
   The generated .ahk contains direct calls bound by Ahk2Exe into the
   executable.
2. Per-category split: each category lives in its own file
   (``generated_<category>.ahk``) so diffs and reviews are scoped to the
   relevant domain. ``hotstrings_generated.ahk`` becomes a thin entry-point
   that ``#Include``s all of them; existing consumers of that file require no
   change.
3. The runtime fallback in ``LoadHotstringsSection`` is kept intact so the
   user-level ``personal_hotstrings.toml`` (path overridable via the ini)
   still loads through the existing parser. Developers editing a bundled TOML
   locally can either re-run this compiler or temporarily rely on the fallback.
4. ``★`` substitution is preserved: triggers containing the default magic key
   character are wrapped in ``StrReplace(trigger, "★", MK)`` so the runtime
   ``ScriptInformation["MagicKey"]`` continues to drive the actual key seen
   by the hotstring engine. Triggers without ``★`` skip the StrReplace call
   altogether.
==============================================================================
"""

from __future__ import annotations

import sys
import tomllib
from pathlib import Path
from typing import Any

# ============================================
# ============================================
# ======= 1/ Constants =======
# ============================================
# ============================================

# Categories that are bundled with the repo and therefore compile-time known.
# ``personal`` is deliberately excluded: its TOML can live outside the repo
# (ScriptInformation["PersonalTomlPath"]) and must keep loading through the
# runtime parser.
BUNDLED_CATEGORIES: list[str] = [
    "distancesreduction",
    "sfbsreduction",
    "rolls",
    "autocorrection",
    "magickey",
]

# Literal magic-key marker used inside TOML triggers / outputs. Runtime
# substitution is done with ``StrReplace(trigger, MAGIC_KEY_MARKER, MK)``.
MAGIC_KEY_MARKER: str = "★"  # ★

def _category_file_header(category: str) -> str:
    """Return the file-path comment + module docstring for a per-category file."""
    return (
        f"; static/ergopti_plus/windows/lib/hotstrings/generated_{category}.ahk\n"
        "\n"
        "; ==============================================================================\n"
        f"; MODULE: Generated Hotstrings — {category}\n"
        "; DESCRIPTION:\n"
        "; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.\n"
        "; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root\n"
        "; whenever the bundled TOML files under ``static/ergopti_plus/_shared/hotstrings/`` change.\n"
        ";\n"
        "; Contains the ``_GenLoad_*`` loader functions and the partial\n"
        "; ``_GENERATED_HOTSTRINGS`` map entries for the ``" + category + "`` category.\n"
        "; Included automatically by ``hotstrings_generated.ahk``.\n"
        "; ==============================================================================\n"
    )


def _make_major_banner(title: str) -> str:
    """Generate a correctly-aligned major section banner for AHK files.

    The banner format follows the project convention:
      5 blank lines before, then 2 top lines, title, 2 bottom lines, all equal
      length = 7 + 1 + len(title) + 1 + 7 chars.
    """
    # Total expected length per linter: prefix(2) + leftEq(7) + 1 + title + 1 + rightEq(7)
    expected_len = 2 + 7 + 1 + len(title) + 1 + 7
    bar = "; " + "=" * (expected_len - 2)
    title_line = f"; {'=' * 7} {title} {'=' * 7}"
    # 6 newlines = end-of-previous-line \n + 5 blank lines, as required by
    # the lint-conventions rule "5 blank lines before a major section".
    return (
        "\n\n\n\n\n\n"
        f"{bar}\n"
        f"{bar}\n"
        f"{title_line}\n"
        f"{bar}\n"
        f"{bar}\n"
        "\n"
    )


# Pre-built banners for the two sections used in every per-category file.
_REGISTRY_BANNER: str = _make_major_banner("1/ Generated registry")
_LOADERS_BANNER: str = _make_major_banner("2/ Generated loaders")

# Header for the thin entry-point hotstrings_generated.ahk.
ENTRY_POINT_HEADER: str = """\
; static/ergopti_plus/windows/lib/hotstrings/hotstrings_generated.ahk

; ==============================================================================
; MODULE: Generated Hotstrings Registrar — Entry Point
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/ergopti_plus/_shared/hotstrings/`` change.
;
; This file is a thin entry-point that ``#Include``s one generated file per
; category. Consumers that already ``#Include`` this file require no change.
; ``LoadHotstringsSection`` consults ``_GENERATED_HOTSTRINGS`` first and only
; falls back to the TOML parser for the ``personal`` category and for sections
; this file does not cover (e.g. a freshly-added TOML file that has not yet
; been recompiled).
; ==============================================================================


"""


# ============================================
# ============================================
# ======= 2/ Escaping helpers =======
# ============================================
# ============================================


def ahk_escape(s: str) -> str:
    """Escape a Python string for use inside an AHK v2 double-quoted literal."""
    # The backtick is AHK's escape character, so it must be escaped first.
    return (
        s.replace("`", "``")
        .replace('"', '`"')
        .replace("\n", "`n")
        .replace("\r", "`r")
        .replace("\t", "`t")
        .replace(";", "`;")
    )


def ahk_bool(value: Any) -> str:
    """Format a Python truthy / falsy value as an AHK v2 bool literal."""
    return "true" if bool(value) else "false"


def trigger_expr(trigger: str) -> str:
    """Return the AHK expression that yields the runtime trigger string.

    When the trigger contains the magic-key marker we emit a ``StrReplace`` so
    the user's current ``ScriptInformation["MagicKey"]`` is applied at boot.
    Otherwise the literal string is enough — avoids one StrReplace per entry.
    """
    escaped = ahk_escape(trigger)
    if MAGIC_KEY_MARKER in trigger:
        return f'StrReplace("{escaped}", "★", _GenMK)'
    return f'"{escaped}"'


# ============================================
# ============================================
# ======= 3/ Entry emission =======
# ============================================
# ============================================


def compute_flags(entry: dict[str, Any]) -> str:
    """Replicate the flag derivation done by ``lib/toml_loader.ahk``."""
    flags = ""
    if entry.get("auto_expand", False):
        flags += "*"
    if not entry.get("is_word", False):
        flags += "?"
    if entry.get("is_case_sensitive_strict", False):
        flags += "C"
    return flags


def emit_entry(
    out: list[str], trigger: str, entry: dict[str, Any],
    is_repeat_section: bool = False, category: str = "", section: str = ""
) -> None:
    """Emit the two lines (options + call) for one TOML hotstring entry."""
    output = entry.get("output", "")
    flags = compute_flags(entry)
    # Counter-intuitive flag mapping preserved from the runtime loader:
    #   ``is_case_sensitive = true``  ➜ single-variant ``CreateHotstring``
    #   ``is_case_sensitive = false`` ➜ all-variants ``CreateCaseSensitiveHotstrings``
    is_case_sens = entry.get("is_case_sensitive", False)
    final_result = entry.get("final_result", False)
    # Only mark as a repeat trigger when the trigger itself contains the magic-key
    # marker — plain-text corrections in repeatcorrections (e.g. "ccê" → "ccu")
    # must not be gated by the repeat-specific word-position check.
    is_repeat = is_repeat_section and MAGIC_KEY_MARKER in trigger

    options_line = (
        '\t_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", '
        f'{ahk_bool(final_result)}, "IsRepeat", {ahk_bool(is_repeat)}'
        + (f', "Category", "{category}"' if category else "")
        + (f', "Section", "{section}"' if section else "")
        + ")"
    )
    out.append(options_line)
    out.append(
        '\tif IsSet(ExtraOptions) and ExtraOptions.Has("OnlyText") {\n'
        '\t\t_GenOpts["OnlyText"] := ExtraOptions["OnlyText"]\n'
        "\t}"
    )

    fn = "CreateHotstring" if is_case_sens else "CreateCaseSensitiveHotstrings"
    output_escaped = ahk_escape(output)
    out.append(
        f'\t{fn}("{flags}", {trigger_expr(trigger)}, "{output_escaped}", _GenOpts)'
    )


# ============================================
# ============================================
# ======= 4/ Section and file emission =======
# ============================================
# ============================================


def emit_section(
    out: list[str], category: str, section: str, entries: list[dict[str, Any]]
) -> str:
    """Emit one generated loader function; returns its AHK name for the registry."""
    fn_name = f"_GenLoad_{category}_{section}"
    out.append(f"{fn_name}(FeatureConfig, ExtraOptions := unset) {{")
    out.append("\tglobal ScriptInformation")
    # Prefix every local with ``_Gen`` so ``#Warn LocalSameAsGlobal`` does not
    # flag a clash with same-named top-level assignments elsewhere in the
    # driver (``MK`` in modules/hotstrings.ahk, ``Opts`` in the Rolls block…).
    out.append(
        '\t_GenTimeAct := FeatureConfig.HasOwnProp("TimeActivationSeconds") '
        "? FeatureConfig.TimeActivationSeconds : 0"
    )
    out.append('\t_GenMK := ScriptInformation["MagicKey"]')
    is_repeat_section = (category == "magickey" and section == "repeatcorrections")
    for entry_dict in entries:
        # Each TOML ``[[section]]`` row is a single-key mapping in the parsed form.
        for trigger, data in entry_dict.items():
            emit_entry(out, trigger, data, is_repeat_section=is_repeat_section, category=category, section=section)
    out.append("}")
    out.append("")
    return fn_name


def compile_category(root: Path, category: str) -> tuple[str, list[tuple[str, str]]]:
    """Compile every ``[[section]]`` block of one category.

    Args:
        root: Repository root path.
        category: Category name matching the TOML file stem.

    Returns:
        A 2-tuple of (ahk_file_content, registry_tuples). Returns an empty
        content string and empty list when the TOML file is absent.
    """
    toml_path = root / "static" / "drivers" / "_shared" / "hotstrings" / f"{category}.toml"
    if not toml_path.exists():
        print(f"[compile_hotstrings] skip (missing): {toml_path}", file=sys.stderr)
        return "", []
    with toml_path.open("rb") as fh:
        data = tomllib.load(fh)

    registry: list[tuple[str, str]] = []
    functions_out: list[str] = []
    for key, value in data.items():
        # ``_meta`` and ``_meta.sections`` are consumed by the runtime metadata
        # loader (ApplyTomlMetadataToFeatures), not by the hotstring registrar.
        if key.startswith("_"):
            continue
        if not isinstance(value, list):
            continue
        section = key.lower()
        fn_name = emit_section(functions_out, category, section, value)
        registry.append((f"{category}.{section}", fn_name))

    # Build the per-category registry partial map.
    registry_lines: list[str] = [f"global _GENERATED_HOTSTRINGS_{category.upper()} := Map("]
    for key, fn in registry:
        registry_lines.append(f'\t"{key}", {fn},')
    registry_lines.append(")")

    content = (
        _category_file_header(category)
        + _REGISTRY_BANNER
        + "\n".join(registry_lines)
        + _LOADERS_BANNER
        + "\n".join(functions_out)
        + "\n"
    )
    return content, registry


# ============================================
# ============================================
# ======= 5/ Top-level orchestration =======
# ============================================
# ============================================


def build(root: Path) -> tuple[dict[str, str], str]:
    """Compile all categories and build the entry-point file.

    Args:
        root: Repository root path.

    Returns:
        A 2-tuple of (per_category_files, entry_point_content).
        ``per_category_files`` maps ``generated_<category>.ahk`` filename to
        its AHK source. ``entry_point_content`` is the thin
        ``hotstrings_generated.ahk`` that ``#Include``s every per-category file
        and merges their partial maps into ``_GENERATED_HOTSTRINGS``.
    """
    per_category: dict[str, str] = {}
    all_registry: list[tuple[str, str]] = []
    included_categories: list[str] = []

    for category in BUNDLED_CATEGORIES:
        content, registry = compile_category(root, category)
        if not content:
            continue
        per_category[f"generated_{category}.ahk"] = content
        all_registry.extend(registry)
        included_categories.append(category)

    # Build the thin entry-point: #Include each per-category file, then merge
    # the partial maps into the single _GENERATED_HOTSTRINGS map consumed by
    # LoadHotstringsSection.
    include_lines = "\n".join(
        f'#Include generated_{cat}.ahk' for cat in included_categories
    )

    # Merge all partial maps into one global map using a helper function so the
    # entry-point file stays readable regardless of category count.
    merge_lines: list[str] = ["global _GENERATED_HOTSTRINGS := Map()"]
    for category in included_categories:
        merge_lines.append(
            f"for _k, _v in _GENERATED_HOTSTRINGS_{category.upper()}"
            f'\n\t_GENERATED_HOTSTRINGS[_k] := _v'
        )

    merge_banner = _make_major_banner(
        "1/ Merge per-category maps into _GENERATED_HOTSTRINGS"
    )
    entry_point = (
        ENTRY_POINT_HEADER
        + include_lines
        + merge_banner
        + "\n".join(merge_lines)
        + "\n"
    )
    return per_category, entry_point


def main() -> int:
    """Entry-point: compile hotstrings and write all generated AHK files.

    Returns:
        Exit code (0 on success).
    """
    root = Path(__file__).resolve().parent.parent
    hotstrings_dir = (
        root / "static" / "drivers" / "autohotkey" / "lib" / "hotstrings"
    )
    per_category, entry_point = build(root)

    total_bytes = 0
    for filename, content in per_category.items():
        path = hotstrings_dir / filename
        path.write_text(content, encoding="utf-8")
        size = len(content)
        total_bytes += size
        print(f"[compile_hotstrings] wrote {path} ({size:,} bytes)")

    entry_path = hotstrings_dir / "hotstrings_generated.ahk"
    entry_path.write_text(entry_point, encoding="utf-8")
    print(
        f"[compile_hotstrings] wrote {entry_path} ({len(entry_point):,} bytes)"
        f" — entry-point #Including {len(per_category)} category file(s)"
        f" ({total_bytes:,} bytes of hotstring code)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
