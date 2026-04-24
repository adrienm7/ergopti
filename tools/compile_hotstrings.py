#!/usr/bin/env python3
"""
==============================================================================
MODULE: TOML Hotstrings Compiler
DESCRIPTION:
Reads the TOML hotstring files under ``static/drivers/hotstrings/`` and emits
a single ``static/drivers/autohotkey/lib/hotstrings_generated.ahk`` file that
registers every hotstring with literal ``CreateHotstring`` /
``CreateCaseSensitiveHotstrings`` calls. This replaces the runtime regex-based
TOML parser for the bundled categories — the driver boots without touching
the TOML payload at all.

FEATURES & RATIONALE:
1. Startup cost collapses: the bundled categories (~3 000 entries across five
   files) no longer go through a per-line regex parse at every ``.exe`` launch.
   The generated .ahk contains direct calls bound by Ahk2Exe into the
   executable.
2. The runtime fallback in ``LoadHotstringsSection`` is kept intact so the
   user-level ``personal.toml`` (path overridable via the ini) still loads
   through the existing parser. Developers editing a bundled TOML locally can
   either re-run this compiler or temporarily rely on the fallback path.
3. ``★`` substitution is preserved: triggers containing the default magic key
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

HEADER: str = """\
; static/drivers/autohotkey/lib/hotstrings_generated.ahk

; ==============================================================================
; MODULE: Generated Hotstrings Registrar
; DESCRIPTION:
; AUTO-GENERATED FILE — DO NOT EDIT BY HAND.
; Regenerate with ``python tools/compile_hotstrings.py`` from the repo root
; whenever the bundled TOML files under ``static/drivers/hotstrings/`` change.
;
; The generator reads the same TOML payload that the runtime parser used to
; consume on every startup and emits direct ``CreateHotstring`` /
; ``CreateCaseSensitiveHotstrings`` calls grouped per (category, section).
; ``LoadHotstringsSection`` consults ``_GENERATED_HOTSTRINGS`` first and only
; falls back to the TOML parser for the ``personal`` category and for sections
; this file does not cover (e.g. a freshly-added TOML file that has not yet
; been recompiled).
; ==============================================================================


"""

REGISTRY_HEADER: str = """
; =============================================
; =============================================
; ======= 1/ Generated registry =======
; =============================================
; =============================================

"""

FUNCTIONS_HEADER: str = """

; ===========================================
; ===========================================
; ======= 2/ Generated loaders =======
; ===========================================
; ===========================================

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


def emit_entry(out: list[str], trigger: str, entry: dict[str, Any]) -> None:
	"""Emit the two lines (options + call) for one TOML hotstring entry."""
	output = entry.get("output", "")
	flags = compute_flags(entry)
	# Counter-intuitive flag mapping preserved from the runtime loader:
	#   ``is_case_sensitive = true``  ➜ single-variant ``CreateHotstring``
	#   ``is_case_sensitive = false`` ➜ all-variants ``CreateCaseSensitiveHotstrings``
	is_case_sens = entry.get("is_case_sensitive", False)
	final_result = entry.get("final_result", False)

	options_line = (
		'\t_GenOpts := Map("TimeActivationSeconds", _GenTimeAct, "FinalResult", '
		f"{ahk_bool(final_result)})"
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
		"\t_GenTimeAct := FeatureConfig.HasOwnProp(\"TimeActivationSeconds\") "
		"? FeatureConfig.TimeActivationSeconds : 0"
	)
	out.append('\t_GenMK := ScriptInformation["MagicKey"]')
	for entry_dict in entries:
		# Each TOML ``[[section]]`` row is a single-key mapping in the parsed form.
		for trigger, data in entry_dict.items():
			emit_entry(out, trigger, data)
	out.append("}")
	out.append("")
	return fn_name


def compile_category(
	root: Path, out: list[str], category: str
) -> list[tuple[str, str]]:
	"""Compile every ``[[section]]`` block of one category; returns registry tuples."""
	toml_path = root / "static" / "drivers" / "hotstrings" / f"{category}.toml"
	if not toml_path.exists():
		print(f"[compile_hotstrings] skip (missing): {toml_path}", file=sys.stderr)
		return []
	with toml_path.open("rb") as fh:
		data = tomllib.load(fh)
	registry: list[tuple[str, str]] = []
	for key, value in data.items():
		# ``_meta`` and ``_meta.sections`` are consumed by the runtime metadata
		# loader (ApplyTomlMetadataToFeatures), not by the hotstring registrar.
		if key.startswith("_"):
			continue
		if not isinstance(value, list):
			continue
		section = key.lower()
		fn_name = emit_section(out, category, section, value)
		registry.append((f"{category}.{section}", fn_name))
	return registry




# ============================================
# ============================================
# ======= 5/ Top-level orchestration =======
# ============================================
# ============================================

def build(root: Path) -> str:
	"""Assemble the full ``hotstrings_generated.ahk`` content as a string."""
	functions_out: list[str] = []
	registry: list[tuple[str, str]] = []
	for category in BUNDLED_CATEGORIES:
		registry.extend(compile_category(root, functions_out, category))

	registry_lines: list[str] = ["global _GENERATED_HOTSTRINGS := Map("]
	for key, fn in registry:
		registry_lines.append(f'\t"{key}", {fn},')
	registry_lines.append(")")

	parts: list[str] = [HEADER, REGISTRY_HEADER, "\n".join(registry_lines), FUNCTIONS_HEADER]
	parts.append("\n".join(functions_out))
	return "\n".join(parts) + "\n"


def main() -> int:
	root = Path(__file__).resolve().parent.parent
	output_path = (
		root / "static" / "drivers" / "autohotkey" / "lib" / "hotstrings_generated.ahk"
	)
	content = build(root)
	output_path.write_text(content, encoding="utf-8")
	print(f"[compile_hotstrings] wrote {output_path} ({len(content):,} bytes)")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
