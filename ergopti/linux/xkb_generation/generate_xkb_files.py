"""Regenerate the shipped Ergopti XKB files from the macOS bundles.

Each ``static/ergopti/macos/bundles/Ergopti_vX.Y.Z.bundle`` holds the Ergopti
.keylayout files of one version; this script converts every one of them with
the generic converter (keylayout_to_xkb.py) into
``static/ergopti/linux/vX_Y_Z/`` (symbols, XCompose and the key types file).

Ergopti++ (the "_plus_plus" files) is skipped: the installer stopped offering
it because its roll sequences saturate XCompose, and its committed files are
frozen as they are. Its rolls reuse the plain keysym of a letter as a Compose
trigger, which the generic converter refuses (that letter could no longer be
typed on its own anywhere else in the layout).

Only the naming is Ergopti's own here: the section id is the file stem and the
display name keeps the historical "Français — Ergopti[+|++] vX.Y.Z" form. The
conversion rules, the keycode table (shared mac_keycodes.json) and Ergopti's
keysym choices (its registry index entry) are the ones every registry layout
uses, so the files shipped here and a registry install of Ergopti agree.

Usage:
    python generate_xkb_files.py            # every bundle
    python generate_xkb_files.py --check    # exit 1 if a shipped file differs
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Tuple

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import keylayout_to_xkb  # noqa: E402

LINUX_DIR = SCRIPT_DIR.parent
BUNDLES_DIR = LINUX_DIR.parent / "macos" / "bundles"
STATIC_DIR = LINUX_DIR.parent.parent
KEYCODES_PATH = (
    STATIC_DIR / "ergopti_plus" / "_shared" / "modules" / "layouts" / "mac_keycodes.json"
)
REGISTRY_INDEX_PATH = STATIC_DIR / "layouts" / "registry" / "index.json"

# Registry entry whose keysym choices every Ergopti file uses.
ERGOPTI_REGISTRY_ID = "ergopti"
ERGOPTI_KEYCODE_CONVENTION = "iso"

_BUNDLE_RE = re.compile(r"^Ergopti_v(\d+)\.(\d+)\.(\d+)\.bundle$")


def bundle_version(bundle: Path) -> Tuple[int, int, int]:
    match = _BUNDLE_RE.match(bundle.name)
    if not match:
        raise ValueError("not an Ergopti bundle: %s" % bundle.name)
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def list_bundles() -> List[Path]:
    """Every Ergopti bundle, oldest first."""
    bundles = [path for path in BUNDLES_DIR.iterdir() if _BUNDLE_RE.match(path.name)]
    return sorted(bundles, key=bundle_version)


def display_name(stem: str, version: Tuple[int, int, int]) -> str:
    """Historical display name of a shipped variant.

    "_plus_plus_ansi" deliberately reads as Ergopti+: the shipped files have
    always been named that way and desktop pickers show this string.
    """
    lowered = stem.lower()
    is_plus_plus = lowered.endswith("plus_plus")
    is_plus = "plus" in lowered and not is_plus_plus
    label = "Ergopti++" if is_plus_plus else "Ergopti+" if is_plus else "Ergopti"
    return "Français — %s v%d.%d.%d" % ((label,) + version)


def convert_bundle(bundle: Path) -> Dict[str, keylayout_to_xkb.Conversion]:
    """Convert every .keylayout of ``bundle``; keys are the output file stems."""
    version = bundle_version(bundle)
    keycodes = keylayout_to_xkb.load_keycodes(KEYCODES_PATH, ERGOPTI_KEYCODE_CONVENTION)
    hints = keylayout_to_xkb.hints_from_index(REGISTRY_INDEX_PATH, ERGOPTI_REGISTRY_ID)
    results = {}
    for keylayout in sorted((bundle / "Contents" / "Resources").glob("*.keylayout")):
        if "_plus_plus" in keylayout.stem:
            continue
        layout_id = keylayout.stem.replace(".", "_")
        results[layout_id] = keylayout_to_xkb.convert(
            keylayout.read_text(encoding="utf-8"),
            keycodes,
            layout_id,
            display_name(keylayout.stem, version),
            hints,
        )
    return results


def output_dir(bundle: Path) -> Path:
    return LINUX_DIR / ("v%d_%d_%d" % bundle_version(bundle))


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="compare instead of writing")
    args = parser.parse_args(argv)
    differences = []
    for bundle in list_bundles():
        out_dir = output_dir(bundle)
        for layout_id, result in convert_bundle(bundle).items():
            if args.check and not out_dir.is_dir():
                continue
            if args.check:
                for suffix, content in (
                    (".xkb", result.symbols_text),
                    (".XCompose", result.compose_text),
                ):
                    path = out_dir / (layout_id + suffix)
                    if not path.is_file() or path.read_text(encoding="utf-8") != content:
                        differences.append(path)
            else:
                for path in keylayout_to_xkb.write_package(result, out_dir, layout_id):
                    print(path)
    if differences:
        for path in differences:
            print("out of date: %s" % path, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
