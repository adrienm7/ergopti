# tools/build/generate_remap_runtime_vhd_fixture.py
"""Generate only pinned genuine portable input bytes; never regenerate an oracle."""

import argparse
import gzip
import hashlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile

import remap_runtime_vhd_fixture as fixture


GIT_OVERRIDES = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_NAMESPACE",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
)


def verify_checkout(root, expected):
    root = fixture.owner(root)
    environment = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    for name in GIT_OVERRIDES:
        environment.pop(name, None)
    for args, wanted in (
        (["rev-parse", "HEAD"], (expected + "\n").encode("ascii")),
        (["status", "--porcelain=v1", "--untracked-files=all", "--ignored"], b""),
    ):
        try:
            result = subprocess.run(
                [
                    "git",
                    "--no-optional-locks",
                    "-C",
                    str(root),
                    "-c",
                    "core.fsmonitor=false",
                    *args,
                ],
                env=environment,
                capture_output=True,
                check=False,
            )
        except OSError as error:
            raise fixture.FixtureRefusal("fixture_pin") from error
        fixture.require(result.returncode == 0 and result.stdout == wanted, "fixture_pin")


def payload(source, census):
    """Read every actual fixed source and preserve its independently retained digest."""
    source = fixture.owner(source)
    original = fixture.stamp(source.lstat())[:4]
    verify_checkout(source, census["upstream"])
    verify_checkout(
        source / "vendor/Karabiner-DriverKit-VirtualHIDDevice",
        census["virtual_hid_submodule"],
    )
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for row in census["files"]:
            fixture.require(fixture.canonical_name(row["path"]), "fixture_inventory")
            data = fixture.read_owned(source / row["path"], row["bytes"], "fixture_bytes")
            fixture.require(
                len(data) == row["bytes"]
                and hashlib.sha256(data).hexdigest() == row["sha256"]
                and hashlib.sha1(
                    b"blob " + str(len(data)).encode("ascii") + b"\x00" + data
                ).hexdigest()
                == row["git_blob_oid"],
                "fixture_bytes",
            )
            entry = tarfile.TarInfo(row["path"])
            entry.size = len(data)
            entry.mode = 0o644
            entry.mtime = entry.uid = entry.gid = 0
            entry.uname = entry.gname = ""
            archive.addfile(entry, io.BytesIO(data))
    fixture.require(fixture.stamp(source.lstat())[:4] == original, "fixture_path")
    raw = output.getvalue()
    fixture.archive_entries(raw, census)
    compressed = io.BytesIO()
    with gzip.GzipFile(
        filename="", mode="wb", compresslevel=9, mtime=0, fileobj=compressed
    ) as stream:
        stream.write(raw)
    result = compressed.getvalue()
    fixture.require(
        len(result) == fixture.ARCHIVE_BYTES
        and hashlib.sha256(result).hexdigest() == fixture.ARCHIVE_SHA256
        and result[:10] == b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff",
        "fixture_archive",
    )
    return result


def generate(source, destination, *, check=False):
    destination = fixture.owner(destination)
    census = fixture.manifest()
    archive = payload(source, census)
    # The independently frozen census is copied exactly, never regenerated from
    # a renderer, updated provider, output archive, or newly computed oracle.
    retained = fixture.read_owned(fixture.MANIFEST, fixture.MANIFEST_BOUND, "fixture_manifest")
    fixture.require(
        hashlib.sha256(retained).hexdigest() == fixture.MANIFEST_SHA256,
        "fixture_manifest",
    )
    files = (
        ("remap_runtime_vhd_pristine.tar.gz", archive),
        ("remap_runtime_vhd_pristine_manifest.json", retained),
    )
    for name, data in files:
        target = destination / name
        if check:
            fixture.require(
                fixture.read_owned(target, len(data), "fixture_archive") == data,
                "fixture_archive",
            )
        elif target == fixture.MANIFEST:
            # Retain the canonical independent input when output and input are
            # the same physical path; only a separate destination receives a copy.
            fixture.require(
                fixture.read_owned(target, len(data), "fixture_manifest") == data,
                "fixture_manifest",
            )
        else:
            try:
                descriptor = os.open(
                    target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644
                )
                with os.fdopen(descriptor, "wb") as stream:
                    fixture.require(stream.write(data) == len(data), "fixture_path")
            except OSError as error:
                raise fixture.FixtureRefusal("fixture_path") from error
    return 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        count = generate(args.source_root, args.output_root, check=args.check)
    except fixture.FixtureRefusal as error:
        print("Refused portable source generation: " + error.code, file=sys.stderr)
        return 1
    print(
        f"PASS offline genuine VHD fixture files={fixture.FILE_COUNT} outputs={count}; native=unexecuted"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
