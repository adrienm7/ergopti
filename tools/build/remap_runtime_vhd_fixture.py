# tools/build/remap_runtime_vhd_fixture.py
"""Supply pinned genuine source inputs to portable controls; no native authority."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import stat
import subprocess
import sys
import tarfile
import tempfile

BUILD = Path(__file__).resolve().parent
FIXTURES = BUILD / "fixtures"
MANIFEST = FIXTURES / "remap_runtime_vhd_pristine_manifest.json"
ARCHIVE = FIXTURES / "remap_runtime_vhd_pristine.tar.gz"
MANIFEST_SHA256 = "b7ac1a92ca736a957116d032774a3182e32303bcef055e37863a366195026869"
ARCHIVE_SHA256 = "6389c53e3adb6cdfd13a80e0580758ac6cff4c985a26ff18dcec204be2aa5877"
SOURCE_TEST_SHA256 = "db23cdb25fbf0a021107765c0e797c61f6fb25f0a3cbfb52deb80722677f928d"
FILE_COUNT = 1019
SOURCE_BYTES = 10339208
TAR_BYTES = 11120640
ARCHIVE_BYTES = 1414078
MANIFEST_BOUND = 300000
GROUPS = {
    "source": ("FrozenProjectionControls", 10),
    "timer": (
        "PortableCustodyControls.test_genuine_canceled_timer_capture_blocks_reference_retirement",
        1,
    ),
    "callback": (
        "PortableCustodyControls.test_genuine_callback_capture_blocks_physical_close_until_destruction",
        1,
    ),
    "lower": (
        "PortableCustodyControls.test_actual_composed_lower_peer_request_manager_compile",
        1,
    ),
}


class FixtureRefusal(RuntimeError):
    """A fixture refusal cannot authorize source compilation or input capture."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


def require(condition, code):
    if not condition:
        raise FixtureRefusal(code)


def stamp(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def owner(path):
    path = Path(path)
    try:
        info = path.lstat()
        require(
            path.is_absolute()
            and path.resolve(strict=True) == path
            and stat.S_ISDIR(info.st_mode)
            and info.st_uid == os.getuid(),
            "fixture_path",
        )
    except OSError as error:
        raise FixtureRefusal("fixture_path") from error
    return path


def read_owned(path, bound, code):
    path = Path(path)
    try:
        before = path.lstat()
        require(
            path.is_absolute()
            and path.resolve(strict=True) == path
            and path.parent.resolve(strict=True) == path.parent
            and stat.S_ISREG(before.st_mode)
            and before.st_nlink == 1
            and before.st_uid == os.getuid(),
            "fixture_path",
        )
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            opened = os.fstat(stream.fileno())
            require(stamp(opened) == stamp(before) and opened.st_size <= bound, code)
            data = stream.read(bound + 1)
            final = os.fstat(stream.fileno())
            after = path.lstat()
            require(
                len(data) == opened.st_size
                and stamp(opened) == stamp(final) == stamp(after)
                and path.resolve(strict=True) == path,
                code,
            )
    except OSError as error:
        raise FixtureRefusal(code) from error
    return data


def manifest(path=MANIFEST):
    data = read_owned(path, MANIFEST_BOUND, "fixture_manifest")
    require(hashlib.sha256(data).hexdigest() == MANIFEST_SHA256, "fixture_manifest")
    result = json.loads(data)
    require(
        result["schema"] == 1
        and result["upstream"] == "9312593e1a3bf72b94c63c524ebabe2637442e8a"
        and result["virtual_hid_submodule"] == "bdfcb459b2eaca8ccda680a73b0dc898f330f4bb"
        and len(result["files"]) == FILE_COUNT
        and sum(row["bytes"] for row in result["files"]) == SOURCE_BYTES,
        "fixture_manifest",
    )
    return result


def canonical_name(name):
    if type(name) is not str:
        return False
    path = PurePosixPath(name)
    return (
        bool(name)
        and not path.is_absolute()
        and str(path) == name
        and ".." not in path.parts
        and "\\" not in name
    )


def archive_entries(raw_tar, census):
    """Check source-only members; the outer reader separately pins archive bytes."""
    require(type(raw_tar) is bytes and len(raw_tar) == TAR_BYTES, "fixture_inventory")
    rows = census["files"]
    require(len(rows) == FILE_COUNT, "fixture_inventory")
    result = []
    try:
        with tarfile.open(fileobj=io.BytesIO(raw_tar), mode="r:") as archive:
            for index, member in enumerate(archive):
                require(index < FILE_COUNT, "fixture_inventory")
                expected = rows[index]
                require(
                    canonical_name(member.name)
                    and member.name == expected["path"]
                    and member.isreg()
                    and member.type == tarfile.REGTYPE
                    and member.size == expected["bytes"]
                    and member.mode == 0o644
                    and member.uid == member.gid == member.mtime == 0
                    and member.uname == member.gname == "",
                    "fixture_inventory",
                )
                stream = archive.extractfile(member)
                require(stream is not None, "fixture_inventory")
                with stream:
                    data = stream.read(expected["bytes"] + 1)
                require(len(data) == expected["bytes"], "fixture_inventory")
                require(
                    hashlib.sha256(data).hexdigest() == expected["sha256"]
                    and hashlib.sha1(
                        b"blob " + str(len(data)).encode("ascii") + b"\x00" + data
                    ).hexdigest()
                    == expected["git_blob_oid"],
                    "fixture_bytes",
                )
                result.append((member.name, data))
            require(
                raw_tar[archive.offset :] == bytes(TAR_BYTES - archive.offset),
                "fixture_inventory",
            )
    except (tarfile.TarError, OSError, ValueError) as error:
        raise FixtureRefusal("fixture_inventory") from error
    require(len(result) == FILE_COUNT, "fixture_inventory")
    return tuple(result)


def sources(path=ARCHIVE, census=None):
    census = manifest() if census is None else census
    data = read_owned(path, ARCHIVE_BYTES, "fixture_archive")
    require(
        len(data) == ARCHIVE_BYTES and hashlib.sha256(data).hexdigest() == ARCHIVE_SHA256,
        "fixture_archive",
    )
    require(data[:10] == b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff", "fixture_archive")
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data), mode="rb") as stream:
            raw = stream.read(TAR_BYTES + 1)
    except (OSError, EOFError) as error:
        raise FixtureRefusal("fixture_archive") from error
    return archive_entries(raw, census)


def publish_sources(directory, entries):
    directory = owner(directory)
    require(not any(directory.iterdir()), "fixture_path")
    for name, data in entries:
        require(canonical_name(name), "fixture_path")
        target = directory / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        require(target.parent.resolve(strict=True) == target.parent, "fixture_path")
        try:
            descriptor = os.open(
                target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644
            )
            with os.fdopen(descriptor, "wb") as stream:
                require(stream.write(data) == len(data), "fixture_path")
        except OSError as error:
            raise FixtureRefusal("fixture_path") from error


def run_group(group, directory):
    require(type(group) is str and group in GROUPS, "fixture_group")
    directory = owner(directory)
    census = manifest()
    entries = sources(census=census)
    script = BUILD / "remap_runtime_vhd_test.py"
    require(
        hashlib.sha256(read_owned(script, 100000, "fixture_test")).hexdigest()
        == SOURCE_TEST_SHA256,
        "fixture_test",
    )
    selected, count = GROUPS[group]
    with tempfile.TemporaryDirectory(prefix="vhd-offline-source-", dir=directory) as temporary:
        source = Path(temporary).resolve(strict=True)
        publish_sources(source, entries)
        result = subprocess.run(
            [sys.executable]
            + (["-" + "O" * sys.flags.optimize] if sys.flags.optimize else [])
            + [str(script), "--source-root", str(source), selected],
            capture_output=True,
            text=True,
            check=False,
        )
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    require(
        result.returncode == 0
        and result.stdout == ""
        and f"Ran {count} test" in result.stderr
        and result.stderr.endswith("\nOK\n"),
        "fixture_controls",
    )
    print(f"PASS portable VHD group={group} tests={count}; native=unexecuted")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--group", required=True, choices=tuple(GROUPS))
    parser.add_argument("--owner", type=Path, required=True)
    args = parser.parse_args()
    try:
        run_group(args.group, args.owner)
    except FixtureRefusal as error:
        print("Refused offline VHD fixture: " + error.code, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
