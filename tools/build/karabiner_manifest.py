# tools/build/karabiner_manifest.py
"""Read the same pinned package metadata used by direct Hammerspoon onboarding."""

import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit


MANIFEST = Path(__file__).resolve().parents[2] / "static/ergopti_plus/macos/vendor/karabiner-elements/manifest.json"
FIELDS = ("version", "file_name", "sha256", "source_url")


def read_manifest(path=MANIFEST):
    """Reject incomplete or unsafe package identity before a build downloads it."""
    manifest = json.loads(Path(path).read_text(encoding="utf-8"))
    if (not isinstance(manifest, dict) or set(manifest) != set(FIELDS)
            or any(not isinstance(manifest[key], str) or not manifest[key]
                   or any(character.isspace() for character in manifest[key]) for key in FIELDS)):
        raise ValueError("Invalid Karabiner package manifest fields")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", manifest["version"]):
        raise ValueError("Invalid Karabiner package version")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.dmg", manifest["file_name"]):
        raise ValueError("Invalid Karabiner package filename")
    if not re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"]):
        raise ValueError("Invalid Karabiner package checksum")
    url = urlsplit(manifest["source_url"])
    if (url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment
            or url.path.rsplit("/", 1)[-1] != manifest["file_name"]):
        raise ValueError("Invalid Karabiner package URL")
    return manifest


if __name__ == "__main__":
    if len(sys.argv) != 1:
        raise SystemExit("Usage: karabiner_manifest.py")
    manifest = read_manifest()
    print("\t".join(manifest[key] for key in FIELDS))
