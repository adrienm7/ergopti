# tools/build/check_layout_extension_payload.py
"""Prove a packaged layout registry carries every hotstring file its extensions bind.

A layout extension's manifest binds hotstring files to the historical
categories they replaced (`[extension.hotstring_bindings.<stem>]`): the
Ergopti pack ships its suffixes and its magic-key replacement this way. The
driver refuses a pack whose bound file is missing, so a package that dropped
one would boot with those sections gone. This check reads the source
registry's manifests, then requires each bound file in the packaged registry
as a regular file with the source bytes, and each bound section among the
file's declared sections. It prints one receipt line per bound file.
"""

import hashlib
from pathlib import Path
import stat
import sys

try:
    import tomllib
except ModuleNotFoundError:
    # tomllib is Python 3.11; the macOS developer build already requires 3.11.4.
    print(
        "[layout-extension-payload] REFUSED: needs Python 3.11 or newer (tomllib)", file=sys.stderr
    )
    sys.exit(1)


MANIFEST_NAME = "manifest.toml"
HOTSTRINGS_SUBDIR = "hotstrings"


def bound_files(source):
    """Yield (extension id, stem, declared sections) for every source binding, sorted."""
    manifests = sorted(source.glob("*/" + MANIFEST_NAME))
    for manifest in manifests:
        document = tomllib.loads(manifest.read_text(encoding="utf-8"))
        bindings = document.get("extension", {}).get("hotstring_bindings", {})
        if not isinstance(bindings, dict):
            raise ValueError(f"{manifest}: hotstring_bindings is not a table")
        for stem in sorted(bindings):
            sections = bindings[stem].get("sections", [])
            if not isinstance(sections, list) or not all(isinstance(s, str) for s in sections):
                raise ValueError(f"{manifest}: binding {stem} declares invalid sections")
            yield manifest.parent.name, stem, sections


def check(source, packaged):
    """Return the receipt lines of a complete packaged registry; raise on the first gap."""
    receipts = []
    for extension, stem, sections in bound_files(source):
        relative = Path(extension, HOTSTRINGS_SUBDIR, stem + ".toml")
        shipped = packaged / relative
        try:
            mode = shipped.lstat().st_mode
        except FileNotFoundError:
            raise ValueError(f"packaged registry lacks the bound file {relative}") from None
        if not stat.S_ISREG(mode):
            raise ValueError(f"packaged bound file {relative} is not a regular file")
        payload = shipped.read_bytes()
        if payload != (source / relative).read_bytes():
            raise ValueError(f"packaged bound file {relative} differs from its source")
        declared = tomllib.loads(payload.decode("utf-8")).get("_meta", {}).get("sections_order", [])
        missing = [section for section in sections if section not in declared]
        if missing:
            raise ValueError(f"packaged bound file {relative} lacks sections {missing}")
        receipts.append(
            f"{relative.as_posix()} sha256={hashlib.sha256(payload).hexdigest()}"
            f" sections={','.join(sections) or '*'}"
        )
    if not receipts:
        raise ValueError(f"source registry {source} binds no hotstring file")
    return receipts


def main(argv):
    if len(argv) != 2:
        print(
            "usage: check_layout_extension_payload.py <source registry> <packaged registry>",
            file=sys.stderr,
        )
        return 2
    try:
        receipts = check(Path(argv[0]), Path(argv[1]))
    except (OSError, ValueError, tomllib.TOMLDecodeError) as error:
        print(f"[layout-extension-payload] REFUSED: {error}", file=sys.stderr)
        return 1
    for line in receipts:
        print(f"[layout-extension-payload] {line}")
    print(f"[layout-extension-payload] PASS bound={len(receipts)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
