"""Shared paths and loaders for the converter tests."""

from __future__ import annotations

import json
import sys
from pathlib import Path

GENERATION_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(GENERATION_DIR))

import generate_xkb_files  # noqa: E402,F401
import keylayout_to_xkb  # noqa: E402,F401

STATIC_DIR = GENERATION_DIR.parents[2]
LINUX_DIR = GENERATION_DIR.parent
REGISTRY_DIR = STATIC_DIR / "layouts" / "registry"
INDEX_PATH = REGISTRY_DIR / "index.json"
KEYCODES_PATH = (
    STATIC_DIR / "ergopti_plus" / "_shared" / "modules" / "layouts" / "mac_keycodes.json"
)


def registry_entries() -> list:
    return json.loads(INDEX_PATH.read_text(encoding="utf-8"))["layouts"]


def registry_entry(layout_id: str) -> dict:
    for entry in registry_entries():
        if entry["id"] == layout_id:
            return entry
    raise KeyError(layout_id)


def registry_keylayout(layout_id: str) -> str:
    entry = registry_entry(layout_id)
    return (REGISTRY_DIR / entry["file"]).read_text(encoding="utf-8")


def convert_registry_layout(layout_id: str):
    entry = registry_entry(layout_id)
    return keylayout_to_xkb.convert(
        registry_keylayout(layout_id),
        keylayout_to_xkb.load_keycodes(KEYCODES_PATH, entry["keycode_convention"]),
        layout_id,
        "%s %s" % (entry["name"], entry["version"]),
        keylayout_to_xkb.XkbHints.from_entry(entry),
    )
