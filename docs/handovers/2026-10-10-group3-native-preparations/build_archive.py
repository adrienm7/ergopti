# docs/handovers/2026-10-10-group3-native-preparations/build_archive.py
"""Build or verify the bounded inactive Group 3 preparation archive."""

import argparse
import gzip
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile


HERE = Path(__file__).resolve().parent
ARCHIVE = "native-preparations.tar.gz"
MANIFEST = "members.json"
EXCLUDED_SUFFIXES = {
    ".pyc",
    ".pyo",
    ".o",
    ".obj",
    ".a",
    ".so",
    ".dll",
    ".dylib",
    ".exe",
    ".tar",
    ".tgz",
    ".gz",
    ".bz2",
    ".xz",
    ".zst",
    ".zip",
    ".deb",
    ".rpm",
    ".apk",
}


def digest(data):
    """Return the byte identity used for members and the compressed archive."""
    return hashlib.sha256(data).hexdigest()


def exclusion(path, data):
    """Exclude caches, executables, libraries, packages and nested archives."""
    if "__pycache__" in path.parts or path.suffix in {".pyc", ".pyo"}:
        return "python-cache"
    if path.name == "cookie_experiment":
        return "compiled-cookie-executable"
    if any(part in EXCLUDED_SUFFIXES for part in path.suffixes):
        return "object-library-package-or-nested-archive"
    if data.startswith((b"\x7fELF", b"MZ", b"\xca\xfe\xba\xbe", b"\xcf\xfa\xed\xfe")):
        return "compiled-binary-signature"
    return None


def snapshot(source_root, folders):
    """Read only the explicitly enumerated regular files, refusing link traversal."""
    records, excluded, contents = [], [], {}
    for packet_index, folder in enumerate(folders, 1):
        relative = PurePosixPath(folder)
        assert not relative.is_absolute() and ".." not in relative.parts
        directory = source_root / folder
        assert directory.is_dir() and not directory.is_symlink(), folder
        for parent in directory.parents:
            if parent == source_root:
                break
            assert not parent.is_symlink(), "symlink packet ancestor"
        file_index = 0
        for path in sorted(directory.rglob("*")):
            assert not path.is_symlink(), "symlink packet member: " + str(path)
            if path.is_dir():
                continue
            metadata = path.stat()
            assert stat.S_ISREG(metadata.st_mode), "nonregular packet member"
            data = path.read_bytes()
            assert len(data) == metadata.st_size, "member changed while being read"
            record = {
                "packet": folder,
                "original": path.relative_to(directory).as_posix(),
                "sha256": digest(data),
                "bytes": len(data),
                "source_mode": stat.S_IMODE(metadata.st_mode),
            }
            reason = exclusion(path, data)
            if reason:
                record["reason"] = reason
                excluded.append(record)
                continue
            file_index += 1
            name = f"p{packet_index:02d}/f{file_index:04d}.txt"
            record["member"] = name
            records.append(record)
            contents[name] = data
    return records, excluded, contents


def compressed_archive(contents):
    """Serialize inert regular members with deterministic tar and gzip metadata."""
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0, compresslevel=9) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name, data in sorted(contents.items()):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                member.mode = 0o444
                member.uid = member.gid = member.mtime = 0
                member.uname = member.gname = ""
                archive.addfile(member, io.BytesIO(data))
    return output.getvalue()


def build(source_root, inventory):
    """Build from the exact 28-folder inventory and verify source stability."""
    folders = json.loads(inventory.read_bytes())
    assert isinstance(folders, list) and len(folders) == 28 and len(set(folders)) == 28
    assert all(isinstance(folder, str) for folder in folders)
    records, excluded, contents = snapshot(source_root, folders)
    data = compressed_archive(contents)
    assert data == compressed_archive(contents), "archive reproduction differs"
    repeated_records, repeated_excluded, repeated_contents = snapshot(source_root, folders)
    assert (records, excluded, contents) == (repeated_records, repeated_excluded, repeated_contents)
    manifest = {
        "kind": "INACTIVE_GROUP3_NATIVE_PREPARATIONS",
        "inventory_sha256": digest(inventory.read_bytes()),
        "packets": folders,
        "archive": ARCHIVE,
        "archive_sha256": digest(data),
        "archive_bytes": len(data),
        "member_count": len(records),
        "retained_bytes": sum(record["bytes"] for record in records),
        "members": records,
        "excluded": excluded,
        "representation": "Exact source bytes in inert .txt members; source names/modes mapped here.",
        "limits": "No production adoption or full native qualification; excluded artifacts unavailable.",
    }
    (HERE / ARCHIVE).write_bytes(data)
    (HERE / MANIFEST).write_text(json.dumps(manifest, indent="\t") + "\n", encoding="utf-8")
    verify()
    print(
        json.dumps(
            {"members": len(records), "excluded": len(excluded), "archive_sha256": digest(data)}
        )
    )


def verify():
    """Verify archive identity, exact members, hashes and safe deterministic metadata."""
    manifest = json.loads((HERE / MANIFEST).read_bytes())
    data = (HERE / ARCHIVE).read_bytes()
    assert digest(data) == manifest["archive_sha256"]
    assert len(data) == manifest["archive_bytes"]
    assert len(manifest["packets"]) == len(set(manifest["packets"])) == 28
    records = {record["member"]: record for record in manifest["members"]}
    assert len(records) == manifest["member_count"] == len(manifest["members"])
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        names = []
        for member in archive:
            assert member.isfile() and re.fullmatch(r"p[0-9]{2}/f[0-9]{4}\.txt", member.name)
            assert member.name in records and member.name not in seen
            assert (member.uid, member.gid, member.mtime, member.mode) == (0, 0, 0, 0o444)
            assert member.uname == member.gname == ""
            raw = archive.extractfile(member).read()
            record = records[member.name]
            assert len(raw) == record["bytes"] and digest(raw) == record["sha256"]
            assert record["packet"] in manifest["packets"]
            original = PurePosixPath(record["original"])
            assert not original.is_absolute() and ".." not in original.parts
            seen.add(member.name)
            names.append(member.name)
        assert names == sorted(names)
    assert seen == set(records)
    assert sum(record["bytes"] for record in records.values()) == manifest["retained_bytes"]


def main():
    """Expose archive-only build/verification; never execute retained source."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true")
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    if args.verify:
        assert args.source_root is None and args.inventory is None
        verify()
        print("ARCHIVE_VERIFIED")
    else:
        assert args.source_root is not None and args.inventory is not None
        build(args.source_root, args.inventory)


if __name__ == "__main__":
    main()
