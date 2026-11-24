# tools/build/import-menu-fonts.py
"""Decode the tray menus' reading-font faces from their bundled WOFF2 sources.

Native menu text cannot use WOFF2: GDI's AddFontResourceEx and Core Text's font
registration read sfnt files (TrueType .ttf, CFF .otf). Each face named in
static/ergopti_plus/_shared/ui/fonts/menu_faces.json is decoded from its source
WOFF2 with fontTools, a lossless container change that keeps the font data and
its names (the SIL OFL treats a pure format conversion as the same font, so the
Reserved Font Names stay). The decode is refused when the file's sfnt flavour
does not match its extension, or when its name table does not carry the family
and PostScript names the manifest declares: the drivers select the face by them.

Run it after replacing a WOFF2 source, then commit the files it writes. It needs
`pip install fonttools brotli`; CI never runs it, tools/test/test-menu-font-faces.cjs
checks the committed files without it.
"""

import io
import json
from pathlib import Path
import sys

try:
    from fontTools.ttLib import TTFont, woff2
except ModuleNotFoundError:
    print(
        "[menu-fonts] REFUSED: needs fontTools and brotli (pip install fonttools brotli)",
        file=sys.stderr,
    )
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parents[2]
FONTS = REPO_ROOT / "static" / "ergopti_plus" / "_shared" / "ui" / "fonts"

# The sfnt flavour each file extension promises.
FLAVOURS = {".ttf": "\x00\x01\x00\x00", ".otf": "OTTO"}


def decode(face: dict) -> bytes:
    """Return the sfnt bytes of one face, refusing any mismatch with its declaration."""
    source = FONTS / face["source"]
    target = FONTS / face["file"]
    decoded = io.BytesIO()
    with source.open("rb") as handle:
        woff2.decompress(handle, decoded)
    data = decoded.getvalue()
    font = TTFont(io.BytesIO(data))
    expected = FLAVOURS.get(target.suffix)
    if expected is None or font.sfntVersion != expected:
        raise ValueError(
            f"{face['file']}: the decoded flavour {font.sfntVersion!r} does not match its extension"
        )
    names = font["name"]
    for name_id, field in ((1, "family"), (6, "postscript")):
        if names.getDebugName(name_id) != face[field]:
            raise ValueError(
                f"{face['file']}: name {name_id} is {names.getDebugName(name_id)!r}, not {face[field]!r}"
            )
    return data


def main() -> int:
    manifest = json.loads((FONTS / "menu_faces.json").read_text(encoding="utf-8"))
    for key, face in manifest["faces"].items():
        data = decode(face)
        (FONTS / face["file"]).write_bytes(data)
        print(f"[menu-fonts] {key}: wrote {face['file']} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
