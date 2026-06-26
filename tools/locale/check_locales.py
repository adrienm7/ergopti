#!/usr/bin/env python3
"""
==============================================================================
MODULE: Locale Consistency Checker
DESCRIPTION:
Verifies that every locale file under ``static/ergopti_plus/_shared/data/locales/``
exposes exactly the same set of keys as ``en.json`` — no extra (stale) keys, no
missing ones.

FEATURES & RATIONALE:
1. Parity gate: locale key parity is enforced in CI by the AHK meta-test
	``test_locale_json_valid.ahk`` (run by run_all.ahk in the test-ahk job). This
	script is the manual developer tool that ASSERTS the same parity locally and,
	via ``--fix``, PRODUCES it — catching forgotten translations and dead keys.
2. ``--fix`` mode: rewrites each locale so its key set matches ``en.json``
	exactly. Extra keys are dropped; missing keys are inserted with the
	English value as a placeholder so translators have a clear "to do" list
	and the running app degrades gracefully to English fallback meanwhile.
3. Untranslated-count report: orthogonal signal — counts keys whose value
	equals the English source. Informational only; does NOT fail CI because
	some locales legitimately share words with English (cognates, brand
	names, keycap labels…).
==============================================================================
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Make tools/lib importable (repo root on sys.path) for the shared-tree SSOT.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from tools.lib.paths import shared  # noqa: E402




# ====================================
# ====================================
# ======= 1/ Path resolution =========
# ====================================
# ====================================

# Locale directory lives at <repo>/static/ergopti_plus/_shared/data/locales/ and the
# canonical reference is en.json — every other file must mirror its key set exactly.
LOCALES_DIR  = shared("data/locales")
REFERENCE    = "en"




# =========================================
# =========================================
# ======= 2/ JSON I/O helpers ============
# =========================================
# =========================================

def load_locale(path: Path) -> dict[str, str]:
	"""Load a locale JSON file as a flat dict. Raises on malformed input."""
	with path.open(encoding="utf-8-sig") as f:
		data = json.load(f)
	if not isinstance(data, dict):
		raise ValueError(f"{path.name}: top-level value must be an object")
	return data


def dump_locale(path: Path, data: dict[str, str]) -> None:
	"""Write back a locale as alphabetically-sorted, tab-indented JSON.

	Matches the existing project convention so ``--fix`` produces diffs that
	only touch the keys that genuinely changed.
	"""
	sorted_data = {k: data[k] for k in sorted(data)}
	# Write WITHOUT a BOM (encoding "utf-8", not "utf-8-sig"): the committed locale
	# files have no BOM, and the macOS lib.locale reader mis-parses a leading BOM
	# (it lands on the first key name, so the first lookup silently returns empty).
	# Reading still uses utf-8-sig so a stray BOM is tolerated on input.
	with path.open("w", encoding="utf-8", newline="\n") as f:
		json.dump(sorted_data, f, ensure_ascii=False, indent="\t")
		f.write("\n")




# ===========================================
# ===========================================
# ======= 3/ Comparison core ================
# ===========================================
# ===========================================

def compare(reference: dict[str, str], locale: dict[str, str]) -> tuple[list[str], list[str], int]:
	"""Compare a locale against the reference.

	Returns:
		missing  — keys present in the reference but absent from the locale.
		extra    — keys present in the locale but absent from the reference.
		same_val — number of keys whose value equals the reference (still EN).
	"""
	ref_keys = set(reference)
	loc_keys = set(locale)
	missing  = sorted(ref_keys - loc_keys)
	extra    = sorted(loc_keys - ref_keys)
	# Count keys that exist in both AND share the same value — those are
	# almost certainly untranslated leftovers, modulo cognates and brand names.
	same_val = sum(1 for k in ref_keys & loc_keys if locale[k] == reference[k])
	return missing, extra, same_val




# ==========================================
# ==========================================
# ======= 4/ Fix mode ======================
# ==========================================
# ==========================================

def fix_locale(reference: dict[str, str], locale: dict[str, str]) -> dict[str, str]:
	"""Return a copy of locale with extra keys removed and missing keys filled
	with the English value as a translation placeholder.

	The English fallback means a freshly-added key surfaces in EN until a
	translator picks it up — better than crashing or rendering the raw dotted
	key in production.
	"""
	out: dict[str, str] = {}
	for k in reference:
		out[k] = locale.get(k, reference[k])
	return out




# ========================================
# ========================================
# ======= 5/ CLI entry point =============
# ========================================
# ========================================

def main(argv: list[str]) -> int:
	parser = argparse.ArgumentParser(
		description="Check (or fix) the key set of every locale against en.json."
	)
	parser.add_argument(
		"--fix",
		action="store_true",
		help="Rewrite each locale so its key set matches en.json exactly.",
	)
	args = parser.parse_args(argv)

	ref_path = LOCALES_DIR / f"{REFERENCE}.json"
	if not ref_path.is_file():
		print(f"ERROR: reference locale not found at {ref_path}", file=sys.stderr)
		return 2
	reference = load_locale(ref_path)
	ref_count = len(reference)
	print(f"Reference {REFERENCE}.json: {ref_count} keys")
	print()
	print(f"{'Locale':<8}{'Total':>8}{'Missing':>10}{'Extra':>8}{'Untranslated':>15}")

	failed = False
	locale_files = sorted(LOCALES_DIR.glob("*.json"))
	# A leading UTF-8 BOM breaks the macOS lib.locale reader (the BOM attaches to
	# the first key, so its first lookup returns empty). Guard against it on EVERY
	# file, reference included — --fix rewrites them BOM-free via dump_locale.
	for path in locale_files:
		if path.read_bytes()[:3] == b"\xef\xbb\xbf":
			if args.fix:
				dump_locale(path, load_locale(path))
				print(f"  -> {path.name}: stripped UTF-8 BOM")
			else:
				print(f"  - BOM: {path.name} starts with a UTF-8 BOM (run --fix)")
				failed = True

	for path in locale_files:
		code = path.stem
		if code == REFERENCE:
			continue
		locale = load_locale(path)
		missing, extra, same_val = compare(reference, locale)
		status = "OK" if not missing and not extra else "FAIL"
		print(
			f"{code:<8}{len(locale):>8}{len(missing):>10}{len(extra):>8}"
			f"{same_val:>15}    {status}"
		)
		if missing or extra:
			failed = True
			if args.fix:
				fixed = fix_locale(reference, locale)
				dump_locale(path, fixed)
				print(f"  -> {path.name}: rewrote (added {len(missing)}, removed {len(extra)})")
			else:
				for k in missing[:5]:
					print(f"  - missing: {k}")
				if len(missing) > 5:
					print(f"  - ... and {len(missing) - 5} more missing")
				for k in extra[:5]:
					print(f"  - extra:   {k}")
				if len(extra) > 5:
					print(f"  - ... and {len(extra) - 5} more extra")

	print()
	if failed and not args.fix:
		print("ERROR: locale key sets diverge from en.json. Run with --fix to auto-correct.")
		return 1
	if failed and args.fix:
		print("Locales fixed. Re-run without --fix to verify.")
		return 0
	print("All locales mirror en.json's key set.")
	return 0


if __name__ == "__main__":
	sys.exit(main(sys.argv[1:]))
