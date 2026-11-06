"""Reconstruct exact worker payloads into a fresh external replay directory."""

import gzip
import hashlib
import importlib.util
import json
from pathlib import Path


def materialize(campaign, destination):
    """Authenticate all archives, then restore original bytes without mutation."""
    campaign, destination = Path(campaign).resolve(), Path(destination).resolve()
    if destination.is_relative_to(campaign) or destination.exists():
        raise ValueError("Select a fresh directory outside the frozen campaign")
    spec = importlib.util.spec_from_file_location(
        "dead_keys_custody", campaign / "check_custody.py"
    )
    custody = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(custody)
    receipt = custody.authenticate(campaign)
    encodings, _ = custody.encoding_aliases(campaign)
    formats, _ = custody.format_aliases(campaign)
    destination.mkdir(parents=True)
    for role in custody.ROLES:
        directory = destination / role
        directory.mkdir()
        manifest_raw = custody.member(campaign / role, "handoff.json").read_bytes()
        manifest = json.loads(manifest_raw)
        (directory / "handoff.json").write_bytes(manifest_raw)
        for item in manifest["files"]:
            key = (role, item["path"])
            if key in encodings:
                raw = gzip.decompress(
                    custody.member(campaign, encodings[key]["storage"]).read_bytes()
                )
            elif key in formats:
                raw = custody.member(campaign, formats[key]["original_copy"]).read_bytes()
            else:
                raw = custody.member(campaign / role, item["path"]).read_bytes()
            if hashlib.sha256(raw).hexdigest() != item["sha256"]:
                raise ValueError("Restored bytes differ from immutable handoff")
            target = directory / item["path"]
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
    (destination / "custody.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return destination
