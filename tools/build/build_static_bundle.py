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
	# Shared assets tree: locales, hotstrings TOMLs, WebView UI, LLM defaults,
	# DB schema, actions.toml, menu_manifest.json. The AHK driver reads all of
	# these via _SharedDir = _StaticDir + "\ergopti_plus\_shared".
	# prefetch.json is regenerated at runtime by the dashboards — skip it.
	(
		"static/ergopti_plus/_shared",
		"static/ergopti_plus/_shared",
		("prefetch.json",),
	),
	# Windows-driver data files (tap_hold defaults, generated config template).
	# Read via _DriverDir = _StaticDir + "\ergopti_plus\windows".
	# personal_shortcuts.ahk is a machine-specific forwarding stub written at
	# runtime by EnsurePersonalShortcutsFile() into %LOCALAPPDATA%\Ergopti\_generated\.
	# Bundling the dev-tree copy would embed a hardcoded absolute path valid only
	# on the developer's machine; every other install would boot with a stale
	# #Include pointing at a non-existent path. The stub is never read from the
	# extracted bundle (ErgoptiPlus.ahk loads it from %LOCALAPPDATA% via line 895),
	# so excluding it here is safe. paths.toml is similarly machine-specific.
	(
		"static/ergopti_plus/windows/_generated",
		"static/ergopti_plus/windows/_generated",
		("personal_shortcuts.ahk", "paths.toml"),
	),
	# Extensions tree: read-only enumeration by the tray menu via _ExtensionsDir.
	# Was "static/extensions", a path the static/ reorg removed. The bundler
	# warns-and-continues on a missing source, so the shipped .exe carried no
	# extension packs at all and CI stayed green.
	("static/ergopti_plus/extensions",         "static/ergopti_plus/extensions",         (".git*",)),
	# Driver icons and language flags read via _StaticDir + "\img\...".
	("static/img/logo",                        "static/img/logo",                        ()),
	("static/img/flags",                       "static/img/flags",                       ()),
	# Vendor DLLs that DllCall expects at _VendorDir (extracted as "vendor/").
	("static/ergopti_plus/windows/vendor",     "vendor",                                 ("*.ahk",)),
]

# Single-file assets pulled in alongside the trees above.
ASSET_FILES: list[tuple[str, str]] = [
	("static/version.json",    "static/version.json"),
	("static/favicon.ico",     "static/favicon.ico"),
	# Layout preview shown on the onboarding wizard's Step 2 (AHK + HS). The
	# rest of the ergopti_*.jpg variants are web-only marketing assets and
	# stay out of the bundle per the size-filter rationale above.
	("static/img/ergopti.jpg", "static/img/ergopti.jpg"),
]

# Generated native assets that must exist and reach their exact runtime path.
# Keeping this contract separate from ASSET_TREES prevents an existing vendor
# directory from making a release silently green when its required DLL is absent.
REQUIRED_ASSETS: tuple[tuple[str, str], ...] = (
	(
		"static/ergopti_plus/windows/vendor/ergopti_nav_owner.dll",
		"vendor/ergopti_nav_owner.dll",
	),
)




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
	for src_rel, _ in REQUIRED_ASSETS:
		if not (repo_root / src_rel).is_file():
			print(
				f"[bundle] ERROR: required asset '{src_rel}' does not exist. "
				"Run tools/build/build_windows_nav_owner.ps1 first.",
				file=sys.stderr,
			)
			return -1

	output.parent.mkdir(parents=True, exist_ok=True)
	count = 0
	bundled_paths: set[str] = set()
	with zipfile.ZipFile(output, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
		# Walk every declared tree and add matching files.
		for src_rel, dst_rel, excludes in ASSET_TREES:
			src_dir = repo_root / src_rel
			if not src_dir.is_dir():
				# Fail fast (§5.3). Warning-and-continuing is how a stale path in
				# ASSET_TREES shipped an .exe with no extension packs while CI
				# stayed green: every declared tree here is a runtime dependency of
				# the compiled driver, so a missing one is a broken build, not a
				# note. Remove the entry deliberately if a tree is retired.
				print(
					f"[bundle] ERROR: declared tree '{src_rel}' does not exist. "
					"Fix the path or remove it from ASSET_TREES.",
					file=sys.stderr,
				)
				return -1
			for path in sorted(src_dir.rglob("*")):
				if not path.is_file():
					continue
				rel = path.relative_to(src_dir)
				if _is_excluded(rel, excludes):
					continue
				arcname = f"{dst_rel}/{rel.as_posix()}"
				zf.write(path, arcname)
				bundled_paths.add(arcname)
				count += 1
		# Add single-file assets.
		for src_rel, dst_rel in ASSET_FILES:
			src_path = repo_root / src_rel
			if not src_path.is_file():
				print(f"[bundle] WARN: missing file '{src_rel}' — skipped.", file=sys.stderr)
				continue
			zf.write(src_path, dst_rel)
			bundled_paths.add(dst_rel)
			count += 1

	missing_bundle_paths = [dst_rel for _, dst_rel in REQUIRED_ASSETS if dst_rel not in bundled_paths]
	if missing_bundle_paths:
		print(
			"[bundle] ERROR: required runtime path(s) were not written: "
			+ ", ".join(missing_bundle_paths),
			file=sys.stderr,
		)
		return -1
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
		default=Path(__file__).resolve().parent.parent.parent,
		help="Repository root (default: two levels above tools/build/).",
	)
	parser.add_argument(
		"--output",
		type=Path,
		default=None,
		help="Output zip path (default: <repo>/static/ergopti_plus/windows/build/static_bundle.zip).",
	)
	args = parser.parse_args()

	repo_root = args.repo_root.resolve()
	output = (args.output or (repo_root / "static" / "ergopti_plus" / "windows" / "build" / "static_bundle.zip")).resolve()

	print(f"[bundle] Repo root  : {repo_root}")
	print(f"[bundle] Output     : {output}")
	count = build_bundle(repo_root, output)
	if count < 0:
		# A declared asset tree was missing — the zip on disk is incomplete and
		# must not be treated as a build product.
		output.unlink(missing_ok=True)
		return 1
	size_kb = output.stat().st_size / 1024
	print(f"[bundle] Files      : {count}")
	print(f"[bundle] Size       : {size_kb:.1f} KB")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
