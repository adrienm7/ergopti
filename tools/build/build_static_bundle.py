#!/usr/bin/env python3
"""
==============================================================================
MODULE: Static Bundle Builder
DESCRIPTION:
Assembles the runtime assets the compiled ErgoptiPlus.exe reads into a single
zip archive. The compiled AHK script embeds this archive via FileInstall and
extracts it on first launch (infra/bundle.ahk), so the EXE is self-contained.
What ships is declared in tools/build/windows_bundle_manifest.json; this script
only resolves and writes it.

FEATURES & RATIONALE:
1. One declaration: the manifest is the single source of the file set, so the
        build and tools/test/test-windows-bundle-manifest.cjs (which proves every
        path the Windows sources read is shipped) see the same selection.
2. Mirror the dev layout: each include keeps its repository-relative shape, so
        every _StaticDir, _SharedDir and _VendorDir read site resolves the same
        file from source and from the extracted bundle.
3. Ship only what the driver reads: first launch extracts every entry with
        Expand-Archive, whose cost grows with the file count, so test corpora, Lua
        modules, documentation and other-driver data stay out.
4. Fail fast: a missing include source or required asset, an unknown manifest
        key or a shipped path under a not_shipped entry aborts the build instead of
        producing an exe that breaks on a user's machine.
5. --list prints the resolved selection as JSON without writing the zip.
==============================================================================
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

# Repository root: tools/build/ is two levels below it.
DEFAULT_REPO_ROOT = Path(__file__).resolve().parent.parent.parent

MANIFEST_REL = "tools/build/windows_bundle_manifest.json"

DEFAULT_OUTPUT_REL = "static/ergopti_plus/windows/build/static_bundle.zip"

MANIFEST_SCHEMA_VERSION = 1

# Maximum deflate effort: the zip is built once per release and embedded in the
# exe, so a smaller archive is worth the extra build time.
ZIP_COMPRESS_LEVEL = 9


# =================================
# =================================
# ======= 1/ Manifest Model =======
# =================================
# =================================


class BundleError(Exception):
    """A manifest or source-tree state that must stop the build."""


@dataclass(frozen=True)
class Include:
    """A file or directory copied to ``dest`` inside the zip."""

    source: str
    dest: str


@dataclass(frozen=True)
class ExcludeGroup:
    """Files under an include that stay out of the zip."""

    name: str
    patterns: tuple[re.Pattern[str], ...]
    exceptions: tuple[re.Pattern[str], ...]
    may_be_empty: bool

    def matches(self, repo_path: str) -> bool:
        """Returns True when ``repo_path`` is excluded by this group."""
        if not any(p.fullmatch(repo_path) for p in self.patterns):
            return False
        return not any(p.fullmatch(repo_path) for p in self.exceptions)


@dataclass(frozen=True)
class Manifest:
    """The validated content of windows_bundle_manifest.json."""

    includes: tuple[Include, ...]
    excludes: tuple[ExcludeGroup, ...]
    not_shipped: tuple[str, ...]
    required: tuple[Include, ...]


def glob_to_regex(pattern: str) -> re.Pattern[str]:
    """Compiles a manifest glob matched against a whole repository-relative path.

    ``**/`` spans zero or more directories, a trailing ``**`` spans the rest of
    the path, and ``*`` and ``?`` never cross a ``/``.
    """
    if not pattern or pattern.startswith("/") or "\\" in pattern:
        raise BundleError(f"invalid glob {pattern!r}: use a relative path with '/' separators")
    parts: list[str] = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            parts.append("(?:[^/]+/)*")
            i += 3
        elif pattern.startswith("**", i):
            parts.append(".*")
            i += 2
        elif pattern[i] == "*":
            parts.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            parts.append("[^/]")
            i += 1
        else:
            parts.append(re.escape(pattern[i]))
            i += 1
    return re.compile("".join(parts))


def _require_keys(entry: object, where: str, required: set[str], optional: set[str]) -> dict:
    """Rejects a manifest object with a missing or unknown key."""
    if not isinstance(entry, dict):
        raise BundleError(f"{where} must be an object")
    missing = required - entry.keys()
    unknown = entry.keys() - required - optional
    if missing:
        raise BundleError(f"{where} lacks {sorted(missing)}")
    if unknown:
        raise BundleError(f"{where} has unknown key(s) {sorted(unknown)}")
    return entry


def _require_text(value: object, where: str) -> str:
    """Returns a non-empty string or raises."""
    if not isinstance(value, str) or not value.strip():
        raise BundleError(f"{where} must be a non-empty string")
    return value


def _require_patterns(value: object, where: str) -> tuple[re.Pattern[str], ...]:
    """Compiles a non-empty list of globs."""
    if not isinstance(value, list) or not value:
        raise BundleError(f"{where} must be a non-empty list of globs")
    return tuple(glob_to_regex(_require_text(g, where)) for g in value)


def _parse_include(entry: object, where: str) -> Include:
    """Validates one include or required entry."""
    fields = _require_keys(entry, where, {"source", "dest"}, {"why"})
    if "why" in fields:
        _require_text(fields["why"], f"{where}.why")
    return Include(
        source=_require_text(fields["source"], f"{where}.source").rstrip("/"),
        dest=_require_text(fields["dest"], f"{where}.dest").rstrip("/"),
    )


def load_manifest(path: Path) -> Manifest:
    """Reads and validates the bundle manifest."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BundleError(f"cannot read the bundle manifest {path}: {exc}") from exc
    _require_keys(
        data,
        "manifest",
        {"schema_version", "include", "exclude", "not_shipped", "required"},
        {"$comment"},
    )
    if data["schema_version"] != MANIFEST_SCHEMA_VERSION:
        raise BundleError(
            f"manifest schema_version {data['schema_version']!r} is not {MANIFEST_SCHEMA_VERSION}"
        )

    includes = tuple(
        _parse_include(entry, f"include[{i}]") for i, entry in enumerate(data["include"])
    )
    if not includes:
        raise BundleError("manifest declares no include")

    excludes: list[ExcludeGroup] = []
    for i, entry in enumerate(data["exclude"]):
        where = f"exclude[{i}]"
        fields = _require_keys(entry, where, {"name", "globs", "why"}, {"except", "may_be_empty"})
        _require_text(fields["why"], f"{where}.why")
        may_be_empty = fields.get("may_be_empty", False)
        if not isinstance(may_be_empty, bool):
            raise BundleError(f"{where}.may_be_empty must be a boolean")
        excludes.append(
            ExcludeGroup(
                name=_require_text(fields["name"], f"{where}.name"),
                patterns=_require_patterns(fields["globs"], f"{where}.globs"),
                exceptions=(
                    _require_patterns(fields["except"], f"{where}.except")
                    if "except" in fields
                    else ()
                ),
                may_be_empty=may_be_empty,
            )
        )
    names = [group.name for group in excludes]
    if len(names) != len(set(names)):
        raise BundleError(f"duplicate exclude group name in {names}")

    not_shipped: list[str] = []
    for i, entry in enumerate(data["not_shipped"]):
        fields = _require_keys(entry, f"not_shipped[{i}]", {"path", "why"}, set())
        _require_text(fields["why"], f"not_shipped[{i}].why")
        not_shipped.append(_require_text(fields["path"], f"not_shipped[{i}].path").rstrip("/"))

    required = tuple(
        _parse_include(entry, f"required[{i}]") for i, entry in enumerate(data["required"])
    )
    return Manifest(includes, tuple(excludes), tuple(not_shipped), required)


# ==================================
# ==================================
# ======= 2/ Selection Logic =======
# ==================================
# ==================================


@dataclass(frozen=True)
class Selection:
    """The resolved bundle: (source, arcname) pairs and per-group exclusion counts."""

    files: tuple[tuple[Path, str], ...]
    excluded: dict[str, int]


def _is_under(repo_path: str, prefix: str) -> bool:
    """True when ``repo_path`` is ``prefix`` itself or lies below it."""
    return repo_path == prefix or repo_path.startswith(prefix + "/")


def resolve(repo_root: Path, manifest: Manifest) -> Selection:
    """Resolves the manifest against the working tree."""
    files: list[tuple[Path, str]] = []
    excluded = {group.name: 0 for group in manifest.excludes}
    arcnames: dict[str, str] = {}
    for include in manifest.includes:
        source = repo_root / include.source
        if source.is_file():
            candidates = [(source, include.dest)]
        elif source.is_dir():
            candidates = [
                (path, f"{include.dest}/{path.relative_to(source).as_posix()}")
                for path in sorted(source.rglob("*"))
                if path.is_file()
            ]
        else:
            # Every include is a runtime dependency: a stale path once shipped an
            # exe without extension packs while CI stayed green.
            raise BundleError(f"include source '{include.source}' does not exist")
        for path, arcname in candidates:
            repo_path = path.relative_to(repo_root).as_posix()
            group = next((g for g in manifest.excludes if g.matches(repo_path)), None)
            if group is not None:
                excluded[group.name] += 1
                continue
            for blocked in manifest.not_shipped:
                if _is_under(repo_path, blocked):
                    raise BundleError(
                        f"'{repo_path}' is declared not_shipped but an include ships it"
                    )
            if arcname in arcnames:
                raise BundleError(
                    f"'{arcname}' is shipped from both '{arcnames[arcname]}' and '{repo_path}'"
                )
            arcnames[arcname] = repo_path
            files.append((path, arcname))

    for required in manifest.required:
        if not (repo_root / required.source).is_file():
            raise BundleError(
                f"required asset '{required.source}' does not exist; build or restore it"
            )
        if arcnames.get(required.dest) != required.source:
            raise BundleError(
                f"required asset '{required.source}' is not shipped at '{required.dest}'"
            )
    return Selection(tuple(files), excluded)


def write_bundle(selection: Selection, output: Path) -> None:
    """Writes the archive and compiled inventory from the same immutable bytes."""
    output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with zipfile.ZipFile(
        output, mode="w", compression=zipfile.ZIP_DEFLATED, compresslevel=ZIP_COMPRESS_LEVEL
    ) as archive:
        for path, arcname in selection.files:
            data = path.read_bytes()
            archive.writestr(
                zipfile.ZipInfo.from_file(path, arcname),
                data,
                compress_type=zipfile.ZIP_DEFLATED,
                compresslevel=ZIP_COMPRESS_LEVEL,
            )
            escaped = arcname.replace("`", "``").replace('"', '`"')
            rows.append(
                f'        ["{escaped}", {len(data)}, "{hashlib.sha256(data).hexdigest()}"],'
            )
    if not rows:
        raise BundleError("cannot compile an empty runtime inventory")
    inventory = (
        "; build/bundle_inventory.ahk\n"
        "; AUTO-GENERATED by tools/build/build_static_bundle.py.\n"
        "; DO NOT EDIT BY HAND. Embedded assets must match these exact bytes.\n\n"
        "; ===========================================\n"
        "; ===========================================\n"
        "; ======= 1/ Compiled asset inventory =======\n"
        "; ===========================================\n"
        "; ===========================================\n\n"
        "_Bundle_CompiledAssetInventory() {\n    return [\n"
        + "\n".join(rows[:-1] + [rows[-1].rstrip(",")])
        + "\n    ]\n}\n"
    )
    output.with_name("bundle_inventory.ahk").write_text(
        inventory, encoding="utf-8-sig", newline="\n"
    )


# =================================
# =================================
# ======= 3/ CLI Entrypoint =======
# =================================
# =================================


def main() -> int:
    parser = argparse.ArgumentParser(description="Assemble the ErgoptiPlus.exe static bundle.")
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=DEFAULT_REPO_ROOT,
        help="Repository root (default: two levels above tools/build/).",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help=f"Output zip path (default: <repo>/{DEFAULT_OUTPUT_REL}).",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="Print the resolved selection as JSON instead of writing the zip.",
    )
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    try:
        selection = resolve(repo_root, load_manifest(repo_root / MANIFEST_REL))
    except BundleError as exc:
        print(f"[bundle] ERROR: {exc}", file=sys.stderr)
        return 1

    if args.list:
        listing = {
            "files": [
                {"source": path.relative_to(repo_root).as_posix(), "arcname": arcname}
                for path, arcname in selection.files
            ],
            "excluded": selection.excluded,
        }
        json.dump(listing, sys.stdout, indent=1)
        sys.stdout.write("\n")
        return 0

    output = (args.output or repo_root / DEFAULT_OUTPUT_REL).resolve()
    print(f"[bundle] Repo root  : {repo_root}")
    print(f"[bundle] Output     : {output}")
    for name, count in selection.excluded.items():
        print(f"[bundle] Excluded   : {count:4d} file(s) by {name}")
    try:
        write_bundle(selection, output)
    except (OSError, BundleError) as exc:
        # A partial archive or a stale inventory must never be embedded.
        output.unlink(missing_ok=True)
        output.with_name("bundle_inventory.ahk").unlink(missing_ok=True)
        print(f"[bundle] ERROR: cannot write {output}: {exc}", file=sys.stderr)
        return 1
    print(f"[bundle] Files      : {len(selection.files)}")
    print(f"[bundle] Size       : {output.stat().st_size / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
