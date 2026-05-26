#!/usr/bin/env python3
"""
==============================================================================
MODULE: Static Bundle Builder
DESCRIPTION:
Assembles every runtime asset the compiled ErgoptiPlus.exe needs into a single
zip archive. The compiled AHK script embeds this archive via FileInstall and
extracts it next to the executable on first launch, so the EXE is fully
self-contained (no separate "resources" folder shipped alongside).

FEATURES & RATIONALE:
1. Single artefact: one zip is far easier to embed via Ahk2Exe than a few
	dozen individual FileInstall directives, and adding a new asset family is
	a one-line change to ASSET_TREES.
2. Mirror the dev layout: the zip extracts so that A_ScriptDir/static/ has the
	exact same shape as <repo>/static/. That keeps every _StaticDir-based read
	site working in both dev (uncompiled) and release (compiled) modes.
3. Filter web-only weight: layout JPGs and other website-only assets stay out
	of the driver bundle so the EXE does not balloon with files it never reads.
==============================================================================
"""

from __future__ import annotations

import argparse
import fnmatch
import sys
import zipfile
from pathlib import Path




# ====================================
# ====================================
# ======= 1/ Bundle Definition =======
# ====================================
# ====================================

# Asset trees the runtime reads, declared as (source_relative_to_repo,
# destination_inside_zip, glob_patterns_to_exclude). The destination mirrors
# the runtime layout: everything under "static/..." gets extracted as a
# sibling of the EXE; everything under "vendor/..." sits next to the EXE so
# DllCall(A_ScriptDir . "\vendor\sqlite3.dll", ...) keeps resolving.
ASSET_TREES: list[tuple[str, str, tuple[str, ...]]] = [
	# Hotstring TOMLs live in _shared since item 1.3.5 — bundled via _shared tree below.
	# Locale files for the i18n module and every WebView panel.
	("static/locales",                          "static/locales",                          ()),
	# Driver icons (on/off) and language flags.
	("static/img/logo",                         "static/img/logo",                         ()),
	("static/img/flags",                        "static/img/flags",                        ()),
	# Gestures shared definitions (Hammerspoon + AHK).
	("static/shared",                           "static/shared",                           ()),
	# Extensions tree (read-only enumeration by the tray menu).
	("static/extensions",                       "static/extensions",                       (".git*",)),
	# _shared driver assets: WebView HTML/CSS/JS, LLM defaults, DB schema.
	# prefetch.json is regenerated at runtime by the dashboards, so we leave
	# any stale snapshot behind rather than shipping a frozen copy.
	("static/drivers/_shared",                  "static/drivers/_shared",                  ("prefetch.json",)),
	# Vendor DLLs that DllCall expects to find next to the EXE.
	("static/drivers/autohotkey/vendor",        "vendor",                                  ("*.ahk",)),
]

# Single-file assets pulled in alongside the trees above.
ASSET_FILES: list[tuple[str, str]] = [
	("static/menu_manifest.json", "static/menu_manifest.json"),
	("static/version.json",       "static/version.json"),
	("static/favicon.ico",        "static/favicon.ico"),
	# Layout preview shown on the onboarding wizard's Step 2 (AHK + HS). The
	# rest of the ergopti_*.jpg variants are web-only marketing assets and
	# stay out of the bundle per the size-filter rationale above.
	("static/img/ergopti.jpg",    "static/img/ergopti.jpg"),
]




# ===================================
# ===================================
# ======= 2/ Filter Helpers =========
# ===================================
# ===================================

def _is_excluded(rel_path: Path, patterns: tuple[str, ...]) -> bool:
	"""Returns True if any path component matches any exclusion glob."""
	if not patterns:
		return False
	posix = rel_path.as_posix()
	name = rel_path.name
	for pattern in patterns:
		if fnmatch.fnmatch(name, pattern) or fnmatch.fnmatch(posix, pattern):
			return True
	return False




# ==========================================
# ==========================================
# ======= 3/ Bundle Assembly Logic =========
# ==========================================
# ==========================================

def build_bundle(repo_root: Path, output: Path) -> int:
	"""Writes the bundle zip and returns the number of files included."""
	output.parent.mkdir(parents=True, exist_ok=True)
	count = 0
	with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
		# Walk every declared tree and add matching files.
		for src_rel, dst_rel, excludes in ASSET_TREES:
			src_dir = repo_root / src_rel
			if not src_dir.is_dir():
				print(f"[bundle] WARN: missing directory '{src_rel}' — skipped.", file=sys.stderr)
				continue
			for path in sorted(src_dir.rglob("*")):
				if not path.is_file():
					continue
				rel = path.relative_to(src_dir)
				if _is_excluded(rel, excludes):
					continue
				arcname = f"{dst_rel}/{rel.as_posix()}"
				zf.write(path, arcname)
				count += 1
		# Add single-file assets.
		for src_rel, dst_rel in ASSET_FILES:
			src_path = repo_root / src_rel
			if not src_path.is_file():
				print(f"[bundle] WARN: missing file '{src_rel}' — skipped.", file=sys.stderr)
				continue
			zf.write(src_path, dst_rel)
			count += 1
	return count




# =================================
# =================================
# ======= 4/ CLI Entrypoint =======
# =================================
# =================================

def main() -> int:
	parser = argparse.ArgumentParser(description="Assemble ErgoptiPlus.exe static bundle.")
	parser.add_argument(
		"--repo-root",
		type=Path,
		default=Path(__file__).resolve().parent.parent,
		help="Repository root (default: parent of tools/).",
	)
	parser.add_argument(
		"--output",
		type=Path,
		default=None,
		help="Output zip path (default: <repo>/static/drivers/autohotkey/build/static_bundle.zip).",
	)
	args = parser.parse_args()

	repo_root = args.repo_root.resolve()
	output = (args.output or (repo_root / "static" / "drivers" / "autohotkey" / "build" / "static_bundle.zip")).resolve()

	print(f"[bundle] Repo root  : {repo_root}")
	print(f"[bundle] Output     : {output}")
	count = build_bundle(repo_root, output)
	size_kb = output.stat().st_size / 1024
	print(f"[bundle] Files      : {count}")
	print(f"[bundle] Size       : {size_kb:.1f} KB")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
