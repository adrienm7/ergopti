"""Regenerate only the finite, hash-pinned evidence packet in this handover."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import tarfile


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    entries = manifest["capsule"]["entries"]
    assert len(entries) == manifest["capsule"]["files"]
    members = {}
    for entry in entries:
        name = entry["proposed_member"]
        path = PurePosixPath(name)
        assert not path.is_absolute() and ".." not in path.parts
        assert name.startswith("evidence/") and name.endswith(".txt")
        assert name not in members
        source = (
            args.evidence_root / name
            if args.evidence_root is not None
            else Path(entry["source_path"])
        )
        assert source.is_file() and not source.is_symlink()
        data = source.read_bytes()
        assert len(data) == entry["bytes"] and sha256(data) == entry["sha256"]
        members[name] = data
    assert sum(map(len, members.values())) == manifest["capsule"]["bytes"]
    archive = io.BytesIO()
    with gzip.GzipFile(fileobj=archive, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.PAX_FORMAT) as tar:
            for name, data in sorted(members.items()):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o600
                info.mtime = 0
                tar.addfile(info, io.BytesIO(data))
    payload = archive.getvalue()
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as tar:
        assert tar.getnames() == sorted(members)
        for member in tar:
            assert member.isfile()
            assert tar.extractfile(member).read() == members[member.name]
    if args.output.exists():
        assert args.output.read_bytes() == payload, "Keep existing evidence immutable"
    else:
        args.output.write_bytes(payload)
    print(json.dumps({"files": len(members), "bytes": len(payload), "sha256": sha256(payload)}))


if __name__ == "__main__":
    main()
