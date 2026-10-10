# docs/handovers/2026-10-10-group6-release-network/generate_capsule.py
"""Generate the frozen Group 6 source archive from independently hashed inputs."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile


def generate(source_root):
    """Refuse changed inputs and publish a deterministic source-only archive."""
    root = Path(__file__).resolve().parent
    inventory_bytes = (root / "source-inventory.json").read_bytes()
    inventory = json.loads(inventory_bytes)
    sources = []
    for entry in inventory["files"]:
        relative = Path(entry["path"])
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError("Source inventory escapes its private root")
        source = source_root / relative
        data = source.read_bytes()
        if len(data) != entry["bytes"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError("Frozen source input changed: " + relative.as_posix())
        sources.append((data, relative.as_posix()))
    output = root / "source-recovery.tar.gz"
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".source-recovery-", dir=root, delete=False) as raw:
            temporary = Path(raw.name)
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for data, name in sources:
                        # Archive the verified snapshot, never a later reopening
                        # or source filesystem metadata such as links or mode.
                        information = tarfile.TarInfo(name)
                        information.size = len(data)
                        information.mode = 0o600
                        archive.addfile(information, io.BytesIO(data))
            raw.flush()
        temporary.replace(output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    receipt = {
        "schema": 1,
        "scope": "SOURCE_RECOVERY_ONLY; native authority and qualification are not restored",
        "archive": output.name,
        "bytes": output.stat().st_size,
        "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        "inventory_sha256": hashlib.sha256(inventory_bytes).hexdigest(),
        "members": len(sources),
    }
    (root / "archive-receipt.json").write_text(json.dumps(receipt, indent="\t") + "\n")
    print(json.dumps(receipt))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    arguments = parser.parse_args()
    generate(arguments.source_root.resolve(strict=True))
