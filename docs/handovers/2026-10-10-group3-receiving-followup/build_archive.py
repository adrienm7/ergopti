# docs/handovers/2026-10-10-group3-receiving-followup/build_archive.py
"""Build or verify the bounded Group 3 follow-up evidence archive."""

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
ARCHIVE = "receiving-followup.tar.gz"
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


def snapshot(source_root, packets):
    """Read only the explicitly enumerated regular files, refusing link traversal."""
    records, excluded, contents = [], [], {}
    for packet_index, packet in enumerate(packets, 1):
        folder = packet["root"]
        relative = PurePosixPath(folder)
        assert not relative.is_absolute() and ".." not in relative.parts
        assert relative.parts[0] in {
            "continuation-2026-10-10",
            "continuation-2026-10-10-recovery",
            "reviews",
            "recovery-2026-10-10",
        }
        directory = source_root / folder
        assert directory.is_dir() and not directory.is_symlink(), folder
        for parent in directory.parents:
            if parent == source_root:
                break
            assert not parent.is_symlink(), "symlink packet ancestor"
        assert packet["files"] and len({entry["path"] for entry in packet["files"]}) == len(
            packet["files"]
        )
        file_index = 0
        for entry in packet["files"]:
            original = PurePosixPath(entry["path"])
            assert not original.is_absolute() and ".." not in original.parts
            assert not any(
                part in {".git", "__pycache__", "node_modules", "cache", "config"}
                for part in original.parts
            )
            path = directory / original
            for parent in path.parents:
                if parent == directory:
                    break
                assert not parent.is_symlink(), "symlink member ancestor"
            assert not path.is_symlink(), "symlink packet member"
            assert "fetch" not in path.name and path.name not in {
                "hosts.yml",
                ".git-credentials",
                "credentials",
                "credential-helper",
            }
            metadata = path.stat()
            assert stat.S_ISREG(metadata.st_mode), "nonregular packet member"
            data = path.read_bytes()
            after = path.stat()
            assert (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
            ) == (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
                after.st_ctime_ns,
            ), "member changed while being read"
            assert (
                len(data) == metadata.st_size == entry["bytes"] and digest(data) == entry["sha256"]
            ), "reviewed member identity changed"
            assert exclusion(path, data) is None, "unreviewed executable/cache/archive member"
            assert not re.search(
                rb"https?://[^\s\"<>]+[?&](?:sig|signature|token|X-Amz-Signature|X-Amz-Credential|X-Goog-Signature|AWSAccessKeyId)=[^\s\"<>]+",
                data,
                re.I,
            ), "possible signed URL content"
            file_index += 1
            name = f"p{packet_index:02d}/f{file_index:04d}.txt"
            records.append(
                {
                    "packet": folder,
                    "original": original.as_posix(),
                    "sha256": digest(data),
                    "bytes": len(data),
                    "source_mode": stat.S_IMODE(metadata.st_mode),
                    "member": name,
                }
            )
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
    """Build only the reviewed explicit pinned file inventory, never walk new inputs."""
    assert inventory.resolve() == (HERE / "source-inventory.json").resolve(), (
        "capsule inventory path mismatch"
    )
    inventory_bytes = inventory.read_bytes()
    plan = json.loads(inventory_bytes)
    packets = plan["packets"]
    folders = [packet["root"] for packet in packets]
    assert isinstance(packets, list) and 1 <= len(packets) <= 32
    assert plan["packet_count"] == len(packets) == len(set(folders))
    records, _, contents = snapshot(source_root, packets)
    excluded = plan["excluded"]
    data = compressed_archive(contents)
    assert data == compressed_archive(contents), "archive reproduction differs"
    repeated_records, repeated_excluded, repeated_contents = snapshot(source_root, packets)
    assert (records, contents) == (repeated_records, repeated_contents)
    assert inventory.read_bytes() == inventory_bytes, "inventory changed during generation"
    manifest = {
        "kind": "GROUP3_FOLLOWUP_RECEIVING_EVIDENCE",
        "inventory_sha256": digest(inventory_bytes),
        "packets": folders,
        "pending_not_snapshotted": plan["pending_not_snapshotted"],
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
    names = ["README.md", "build_archive.py", "source-inventory.json", ARCHIVE, MANIFEST]
    (HERE / "files.sha256").write_text(
        "".join(digest((HERE / name).read_bytes()) + "  " + name + "\n" for name in names),
        encoding="utf-8",
    )
    print(
        json.dumps(
            {"members": len(records), "excluded": len(excluded), "archive_sha256": digest(data)}
        )
    )


def verify():
    """Verify archive identity, exact members, hashes and safe deterministic metadata."""
    manifest = json.loads((HERE / MANIFEST).read_bytes())
    plan_bytes = (HERE / "source-inventory.json").read_bytes()
    assert digest(plan_bytes) == manifest["inventory_sha256"], "capsule inventory identity changed"
    plan = json.loads(plan_bytes)
    assert plan["packet_count"] == len(plan["packets"]) == len(manifest["packets"])
    assert [packet["root"] for packet in plan["packets"]] == manifest["packets"]
    expected = {
        (packet["root"], entry["path"]): entry
        for packet in plan["packets"]
        for entry in packet["files"]
    }
    assert len(expected) == sum(len(packet["files"]) for packet in plan["packets"])
    assert len(manifest["members"]) == len(expected), "duplicate or omitted original mapping"
    assert {(record["packet"], record["original"]) for record in manifest["members"]} == set(
        expected
    )
    for record in manifest["members"]:
        pinned = expected[(record["packet"], record["original"])]
        assert (record["sha256"], record["bytes"]) == (pinned["sha256"], pinned["bytes"])
    data = (HERE / ARCHIVE).read_bytes()
    assert digest(data) == manifest["archive_sha256"]
    assert len(data) == manifest["archive_bytes"]
    assert 1 <= len(manifest["packets"]) <= 32 and len(manifest["packets"]) == len(
        set(manifest["packets"])
    )
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
