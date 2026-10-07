# tools/diagnostics/installed_vhd_reference_fixture.py
"""Owned native static-reference fixtures; never install or activate a driver.

The ordinary XCTest SDK Guardian owns every invocation. Privileged copy/cleanup
workers use a separate absolute 25-second limit and never signal foreign jobs.
"""

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import signal
import stat
import subprocess
import sys
import time
import types

ROOT = Path(__file__).resolve().parent
SECONDS = 25
DEPENDENCIES = {
    "installed_vhd_static_fixture": "b2b97f06c78ae087ed373768d46f09a30aaecfa95bd920164001b80874a5b461",
    "installed_vhd_signature_text": "0867b30ba045eb1d13e0dd16ac57bb68cacca81ad0a6ca9c1c7803d0c50c296e",
    "installed_vhd_ci_fixture": "41afbc7c0f80764b0c15c2e09ca2c6ac66f9982d1aa3345ba61e9868a849cda7",
}
MAX_NODES = 1024
ANCESTRY_SOURCE_SHA256 = "1623995409bd9099d8636e07bb061e183c2f5fe628f9b857d167f73033b69055"
MAX_BYTES = 134217728
DAEMON = "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app"
DEXT = "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext"
BINARY = "daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon"
CASES = (
    "official",
    "newer-reference",
    "same-signer-other-build",
    "unsigned",
    "adhoc",
    "bad-other-slice",
    "changed-plist",
    "changed-resource",
    "symlink-ancestor",
    "symlink-plist",
    "symlink-executable",
    "user-owned",
    "writable-file",
    "nonempty-acl",
    "writable-ancestor",
    "missing-daemon",
    "missing-dext",
    "missing-executable",
)


class Refusal(Exception):
    """A fixed refusal never supplies fixture, signing or installation authority."""


def require(value, code):
    if not value:
        raise Refusal(code)


def remaining(deadline):
    value = deadline - time.monotonic()
    require(value > 0, "deadline")
    return value


def member(name):
    require(
        type(name) is str
        and name
        and not name.startswith("/")
        and "\0" not in name
        and "\\" not in name,
        "relative_path",
    )
    parts = tuple(name.split("/"))
    require(all(part not in ("", ".", "..") for part in parts), "relative_path")
    return parts


def fixture_root(nonce):
    require(type(nonce) is str and re.fullmatch("[0-9a-f]{32}", nonce) is not None, "nonce")
    return Path("/Library/ErgoptiPlusNativeFixture-" + nonce)


def identity(s):
    return {
        "dev": s.st_dev,
        "ino": s.st_ino,
        "mode": s.st_mode,
        "uid": s.st_uid,
        "gid": s.st_gid,
    }


def inventory(path, *, allow_links=False, maximum_nodes=MAX_NODES, maximum_bytes=MAX_BYTES):
    """Hold each real no-follow inode while capturing bounded bytes and membership."""
    path = Path(path)
    result, consumed = {}, 0
    require(path.is_absolute() and not path.is_symlink(), "source_type")
    with contextlib.ExitStack() as stack:
        root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        stack.callback(os.close, root)
        require(identity(os.fstat(root)) == identity(path.lstat()), "source_changed")

        def walk(parent, relative):
            nonlocal consumed
            names = sorted(os.listdir(parent))
            for name in names:
                rel = name if not relative else relative + "/" + name
                member(rel)
                require(len(result) + 1 < maximum_nodes, "inventory_limit")
                before = os.stat(name, dir_fd=parent, follow_symlinks=False)
                row = {"identity": identity(before), "bytes": 0}
                result[rel] = row
                if stat.S_ISLNK(before.st_mode):
                    require(allow_links, "source_type")
                    row.update(kind="link", target=os.readlink(name, dir_fd=parent))
                    require(
                        identity(os.stat(name, dir_fd=parent, follow_symlinks=False))
                        == identity(before),
                        "source_changed",
                    )
                    continue
                require(
                    stat.S_ISDIR(before.st_mode)
                    or stat.S_ISREG(before.st_mode)
                    and before.st_nlink == 1,
                    "source_type",
                )
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
                with contextlib.ExitStack() as child:
                    child.callback(os.close, fd)
                    require(identity(os.fstat(fd)) == identity(before), "source_changed")
                    if stat.S_ISDIR(before.st_mode):
                        row["kind"] = "directory"
                        walk(fd, rel)
                    else:
                        require(
                            0 <= before.st_size <= maximum_bytes - consumed,
                            "inventory_limit",
                        )
                        digest = hashlib.sha256()
                        count = 0
                        while True:
                            block = os.read(fd, min(65536, before.st_size + 1 - count))
                            if not block:
                                break
                            count += len(block)
                            require(count <= before.st_size, "source_changed")
                            digest.update(block)
                        require(count == before.st_size, "source_changed")
                        consumed += count
                        row.update(kind="file", bytes=count, sha256=digest.hexdigest())
                    after = os.fstat(fd)
                    require(
                        identity(after) == identity(before)
                        and after.st_mtime_ns == before.st_mtime_ns
                        and after.st_ctime_ns == before.st_ctime_ns,
                        "source_changed",
                    )
                    require(
                        identity(os.stat(name, dir_fd=parent, follow_symlinks=False))
                        == identity(before),
                        "source_changed",
                    )
            require(sorted(os.listdir(parent)) == names, "source_changed")

        walk(root, "")
        require(identity(os.fstat(root)) == identity(path.lstat()), "source_changed")
    return result


def remove_tree(path, expected):
    """Refuse changed contents before unlinking the exact captured relative inventory."""
    path = Path(path)
    require(inventory(path, allow_links=True) == expected, "inventory_changed")
    root = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for rel in sorted(expected, key=lambda value: (-len(member(value)), value)):
            parts = member(rel)
            with contextlib.ExitStack() as held:
                parent = root
                for part in parts[:-1]:
                    parent = os.open(
                        part,
                        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                        dir_fd=parent,
                    )
                    held.callback(os.close, parent)
                require(
                    identity(os.stat(parts[-1], dir_fd=parent, follow_symlinks=False))
                    == expected[rel]["identity"],
                    "inventory_changed",
                )
                if expected[rel]["kind"] == "directory":
                    os.rmdir(parts[-1], dir_fd=parent)
                else:
                    os.unlink(parts[-1], dir_fd=parent)
        require(os.listdir(root) == [], "inventory_changed")
        require(identity(os.fstat(root)) == identity(path.lstat()), "inventory_changed")
        path.rmdir()
        require(not os.path.lexists(path), "cleanup_refused")
    finally:
        os.close(root)


def module(name):
    """Execute only immutable captured bytes from a fixed reviewed sibling."""
    require(name in DEPENDENCIES, "source_name")
    path = ROOT / (name + ".py")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_nlink == 1
            and not before.st_mode & 0o022
            and 0 < before.st_size <= 1048576,
            "source_type",
        )
        body = bytearray()
        while len(body) < before.st_size:
            block = os.read(fd, min(65536, before.st_size - len(body)))
            require(block, "source_changed")
            body.extend(block)
        require(
            identity(os.fstat(fd)) == identity(before) == identity(path.lstat()),
            "source_changed",
        )
        require(hashlib.sha256(body).hexdigest() == DEPENDENCIES[name], "source_changed")
        value = types.ModuleType("reference_" + name)
        value.__file__ = str(path)
        exec(compile(bytes(body), str(path), "exec"), value.__dict__)
        return value
    finally:
        os.close(fd)


def verify_package(version, body):
    pins = module("installed_vhd_static_fixture").PACKAGES
    require(type(version) is str and version in pins, "package_version")
    size, digest = pins[version]
    require(
        type(body) is bytes and len(body) == size and hashlib.sha256(body).hexdigest() == digest,
        "package_pin",
    )


def native(arguments, deadline):
    """Children inherit the actual SDK Guardian; root commands also share its bounded worker."""
    before = Path(arguments[0]).lstat()
    require(
        stat.S_ISREG(before.st_mode) and before.st_uid == 0 and not before.st_mode & 0o022,
        "native_image",
    )
    result = subprocess.run(
        arguments,
        check=False,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=remaining(deadline),
    )
    require(identity(Path(arguments[0]).lstat()) == identity(before), "native_image_changed")
    require(len(result.stdout) <= 131072 and len(result.stderr) <= 131072, "native_output")
    remaining(deadline)
    require(result.returncode == 0, "native_status")
    return result


def write_exclusive(path, body, mode=0o600):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    try:
        view = memoryview(body)
        while view:
            count = os.write(fd, view)
            require(count > 0, "write_refused")
            view = view[count:]
    finally:
        os.close(fd)


def prepare(owner, deadline):
    require(sys.platform == "darwin" and os.geteuid() != 0, "native_prerequisite")
    owner = Path(owner)
    require(
        owner.is_absolute()
        and owner.resolve(strict=True) == owner
        and owner.stat().st_uid == os.geteuid()
        and stat.S_IMODE(owner.stat().st_mode) == 0o700,
        "owner",
    )
    require(os.listdir(owner) == [], "owner_inventory")
    help_result = native(["/usr/sbin/pkgutil", "--help"], deadline)
    require(
        b"--expand-full" in help_result.stdout + help_result.stderr,
        "expand_prerequisite",
    )
    signature = module("installed_vhd_signature_text")
    packages = module("installed_vhd_static_fixture")
    for version in ("8.4.0", "8.5.0", "8.6.0"):
        package = owner / packages.package_name(version)
        downloaded = native(
            [
                "/usr/bin/curl",
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--max-time",
                str(max(1, int(remaining(deadline)))),
                "--output",
                str(package),
                packages.package_url(version),
            ],
            deadline,
        )
        require(downloaded.stdout == b"" and downloaded.stderr == b"", "download_output")
        body = package.read_bytes()
        verify_package(version, body)
        checked = native(["/usr/sbin/pkgutil", "--check-signature", str(package)], deadline)
        signature.observe_signature_text(
            version, checked.stdout, checked.stderr, checked.returncode
        )
        expanded = owner / ("expanded-" + version)
        result = native(
            ["/usr/sbin/pkgutil", "--expand-full", str(package), str(expanded)],
            deadline,
        )
        require(result.stdout == b"" and result.stderr == b"", "expand_output")
        payload = expanded / "Payload"
        verify_payload(version, payload)
        for relative in (DAEMON, DEXT):
            image = payload / relative
            validated = native(
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--strict",
                    "--all-architectures",
                    str(image),
                ],
                deadline,
            )
            require(validated.stdout == b"" and validated.stderr == b"", "codesign_output")
            for architecture in ("x86_64", "arm64"):
                native(
                    [
                        "/usr/bin/codesign",
                        "--display",
                        "--verbose=4",
                        "--arch",
                        architecture,
                        str(image),
                    ],
                    deadline,
                )
        require(package.read_bytes() == body, "package_changed")
    ancestry_source = ROOT / "installed-vhd-acl-ancestry.c"
    require(
        not ancestry_source.is_symlink()
        and hashlib.sha256(ancestry_source.read_bytes()).hexdigest() == ANCESTRY_SOURCE_SHA256,
        "ancestry_source",
    )
    compiler = native(
        [
            "/usr/bin/clang",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            str(ROOT / "installed-vhd-acl-ancestry.c"),
            "-o",
            str(owner / "ancestry"),
        ],
        deadline,
    )
    require(compiler.stdout == b"" and compiler.stderr == b"", "compiler_output")
    require(
        not ancestry_source.is_symlink()
        and hashlib.sha256(ancestry_source.read_bytes()).hexdigest() == ANCESTRY_SOURCE_SHA256,
        "ancestry_source_changed",
    )
    # Store only exact source inventory; this record is not package or fixture authority.
    record = {"schema": 1, "uid": os.geteuid(), "inventory": inventory(owner)}
    write_exclusive(owner / ".prepared.json", json.dumps(record, sort_keys=True).encode())
    return {
        "schema": 1,
        "status": "prepared",
        "package_versions": ["8.4.0", "8.5.0", "8.6.0"],
        "installation_qualified": False,
        "reference_qualified": False,
    }


# Frozen from the independently decoded genuine package inventories before helper code.
PAYLOADS = {
    "8.4.0": {
        "Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh": [
            33261,
            389,
            "0f881f6dc0aa1196226b0dced6c7cd88a4435c669a484b7f5e5d671844ea98c8",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh": [
            33261,
            1134,
            "e0e7e94053706c40db7a4b9b7095a5df5930c15adad4e95e7f424a947e6714f6",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature/CodeResources": [
            33188,
            2585,
            "c541af24a376259cd600371fd60911d2bd26765af00013c4078ee66eb0aa164c",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/embedded.provisionprofile": [
            33188,
            13383,
            "c38ad42248a52500e819a9b001c0e56f464bfb95935758db53f10e3fbc2bbc34",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist": [
            33188,
            1557,
            "06161b126db1c881dc757d05bf306150b29239553d0732498cbc58a16a532afa",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources/app.icns": [
            33188,
            317132,
            "a04f2c5b8a37caa88fec8b80d50d2459596df50273c5b406bba3bacf302bb032",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon": [
            33261,
            3472352,
            "711192222293d2669eaba5cf3ba1b2ffc466d87bcdcdf1b948b708cefa0e41f9",
        ],
        "Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature/CodeResources": [
            33188,
            3485,
            "1934d39fd459d63a4f55b95eb03d950b55546879c1be49e0571e9ae14c03e733",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature/CodeResources": [
            33188,
            2042,
            "f0deee2ab5184793a169caaed6be5d6280f70cf928c8905a71cfaaa229a33f78",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/embedded.provisionprofile": [
            33188,
            13551,
            "f00794ba8d3b24c8596b5662d7c32812cef7746f54cbfa983f19a235a7ced14c",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/._embedded.provisionprofile": [
            33188,
            491,
            "89f1cecc2e5c5a8451a0482c6a55b11ffc6361d2374ca5878c10132a2d206c62",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/Info.plist": [
            33188,
            1409,
            "60863adaa1ffe6b1c954df12dac7b563933389803752d44df24c788a8620b0db",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice": [
            33261,
            295984,
            "be3b9a779abbd7f08d622254909349bbf689a58043bd3b653493131b6e46d8bc",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/embedded.provisionprofile": [
            33188,
            12556,
            "966896faffd9bb1b6a839e63bef6e8d4c3b8c35eb1c0ccd528e2e311762178da",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/._embedded.provisionprofile": [
            33188,
            579,
            "31187b1fd98223fdbf4bdc8d46fb86da52ec03591de2e4f71275a7cec5aea14e",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist": [
            33188,
            1560,
            "8ea143bbec85cbf1bba736a3bfb4d4bd6ddc9c81a2b965914e2c61cc39f3eedf",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources/app.icns": [
            33188,
            888867,
            "2160478d48b3e91c134dfc2c6c376d5481b3ae2c360ff4c82d8c7258846fdf10",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager": [
            33261,
            320768,
            "9e70c724c425d3690358f2b0d723d4eba17af47311db561a1f74f95d3b1d4f7b",
        ],
    },
    "8.5.0": {
        "Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh": [
            33261,
            389,
            "0f881f6dc0aa1196226b0dced6c7cd88a4435c669a484b7f5e5d671844ea98c8",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh": [
            33261,
            1134,
            "e0e7e94053706c40db7a4b9b7095a5df5930c15adad4e95e7f424a947e6714f6",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature/CodeResources": [
            33188,
            2585,
            "c541af24a376259cd600371fd60911d2bd26765af00013c4078ee66eb0aa164c",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/embedded.provisionprofile": [
            33188,
            13383,
            "c38ad42248a52500e819a9b001c0e56f464bfb95935758db53f10e3fbc2bbc34",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist": [
            33188,
            1557,
            "0fb5e8877dbbf929dd5fb8f1cfce7fe737971bf355c39d29a4fc5c7c44e05f99",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources/app.icns": [
            33188,
            317132,
            "a04f2c5b8a37caa88fec8b80d50d2459596df50273c5b406bba3bacf302bb032",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon": [
            33261,
            3452416,
            "9620bd06cbbfbd377689fb5a0ba2f1e1bd346effe089fe49a083d7963f1a76ab",
        ],
        "Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature/CodeResources": [
            33188,
            3485,
            "27a82fb67a2a81adf149d3984a2cf32eb79312ad8dce1c34a212bd236ce7699d",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature/CodeResources": [
            33188,
            2042,
            "f0deee2ab5184793a169caaed6be5d6280f70cf928c8905a71cfaaa229a33f78",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/embedded.provisionprofile": [
            33188,
            13551,
            "f00794ba8d3b24c8596b5662d7c32812cef7746f54cbfa983f19a235a7ced14c",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/._embedded.provisionprofile": [
            33188,
            491,
            "89f1cecc2e5c5a8451a0482c6a55b11ffc6361d2374ca5878c10132a2d206c62",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/Info.plist": [
            33188,
            1409,
            "60863adaa1ffe6b1c954df12dac7b563933389803752d44df24c788a8620b0db",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice": [
            33261,
            295984,
            "1ad5457b892121eff4b9ecedd0528af0e6ea82928827ad76fb7c5b9c247c0b6e",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/embedded.provisionprofile": [
            33188,
            12556,
            "966896faffd9bb1b6a839e63bef6e8d4c3b8c35eb1c0ccd528e2e311762178da",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/._embedded.provisionprofile": [
            33188,
            579,
            "31187b1fd98223fdbf4bdc8d46fb86da52ec03591de2e4f71275a7cec5aea14e",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist": [
            33188,
            1560,
            "6c32907dabb6a45ef30b5e0ba943afc70a022e4be29ed6784e02d35ce4845f29",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources/app.icns": [
            33188,
            888867,
            "2160478d48b3e91c134dfc2c6c376d5481b3ae2c360ff4c82d8c7258846fdf10",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager": [
            33261,
            320768,
            "171adc21108409a8164a38df19e3a8191b240074b4db9b40063d5b1ac03ba19e",
        ],
    },
    "8.6.0": {
        "Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/deactivate_driver.sh": [
            33261,
            389,
            "0f881f6dc0aa1196226b0dced6c7cd88a4435c669a484b7f5e5d671844ea98c8",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/scripts/uninstall/remove_files.sh": [
            33261,
            1134,
            "e0e7e94053706c40db7a4b9b7095a5df5930c15adad4e95e7f424a947e6714f6",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/_CodeSignature/CodeResources": [
            33188,
            2585,
            "c541af24a376259cd600371fd60911d2bd26765af00013c4078ee66eb0aa164c",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/embedded.provisionprofile": [
            33188,
            13383,
            "c38ad42248a52500e819a9b001c0e56f464bfb95935758db53f10e3fbc2bbc34",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Info.plist": [
            33188,
            1561,
            "8b704495aa140e90abcd2d5719fc954d17cf369394312c04e5db9aea515def61",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/Resources/app.icns": [
            33188,
            317132,
            "a04f2c5b8a37caa88fec8b80d50d2459596df50273c5b406bba3bacf302bb032",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Library/Application Support/org.pqrs/Karabiner-DriverKit-VirtualHIDDevice/Applications/Karabiner-VirtualHIDDevice-Daemon.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Daemon": [
            33261,
            3478208,
            "2e3ebe948fa6a04b5ec66d52fa8581156715cfb15af769f2bdd7c2a2517e23bb",
        ],
        "Applications": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/_CodeSignature/CodeResources": [
            33188,
            3485,
            "85c57929d1ed85ab09895fcb320222558b9f660cdc86fb74e7d4771a34cdd0ce",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/_CodeSignature/CodeResources": [
            33188,
            2042,
            "9a468bd0bc1b04b5016d9efee06212881c4c3bfa53cfc124f1a185b87508fab9",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/embedded.provisionprofile": [
            33188,
            13551,
            "f00794ba8d3b24c8596b5662d7c32812cef7746f54cbfa983f19a235a7ced14c",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/._embedded.provisionprofile": [
            33188,
            491,
            "89f1cecc2e5c5a8451a0482c6a55b11ffc6361d2374ca5878c10132a2d206c62",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/Info.plist": [
            33188,
            1412,
            "9f16be73a90f2fbb0cc7ff25ed7af43803625b3d30fb5d4781ef48f1fa83433e",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Library/SystemExtensions/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.dext/org.pqrs.Karabiner-DriverKit-VirtualHIDDevice": [
            33261,
            295984,
            "c1aaf6d9f574a45b5e5e98e07805f5937fcf9291ba15a8241497bbfd014650ee",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/embedded.provisionprofile": [
            33188,
            12556,
            "966896faffd9bb1b6a839e63bef6e8d4c3b8c35eb1c0ccd528e2e311762178da",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/._embedded.provisionprofile": [
            33188,
            579,
            "31187b1fd98223fdbf4bdc8d46fb86da52ec03591de2e4f71275a7cec5aea14e",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Info.plist": [
            33188,
            1564,
            "bd8a1b23019563cce3ca58d04bcdeb00103098986ff40a3cb21c9c71ef7c33c4",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/Resources/app.icns": [
            33188,
            888867,
            "2160478d48b3e91c134dfc2c6c376d5481b3ae2c360ff4c82d8c7258846fdf10",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/PkgInfo": [
            33188,
            8,
            "82502191c9484b04d685374f9879a0066069c49b8acae7a04b01d38d07e8eca0",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS": [
            16877,
            0,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ],
        "Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager": [
            33261,
            295616,
            "55ac11d5f1be361736a58137ff2db1580a5e5eed2a2fad49f656c2632b6499ef",
        ],
    },
}


def verify_payload(version, payload):
    actual = inventory(payload)
    require(set(actual) == set(PAYLOADS[version]), "payload_inventory")
    for relative, (mode, size, digest) in PAYLOADS[version].items():
        row = actual[relative]
        require(row["identity"]["mode"] == mode, "payload_mode")
        if stat.S_ISREG(mode):
            require(row["bytes"] == size and row["sha256"] == digest, "payload_bytes")


def prepared(owner):
    record = json.loads((owner / ".prepared.json").read_bytes())
    require(
        set(record) == {"schema", "uid", "inventory"}
        and record["schema"] == 1
        and type(record["uid"]) is int
        and record["uid"] > 0,
        "prepared_record",
    )
    actual = inventory(owner)
    actual.pop(".prepared.json")
    require(actual == record["inventory"], "prepared_changed")
    return record


def ancestry(owner, record, deadline):
    executable = owner / "ancestry"
    expected = record["inventory"]["ancestry"]
    require(
        hashlib.sha256(executable.read_bytes()).hexdigest() == expected["sha256"]
        and identity(executable.lstat()) == expected["identity"],
        "ancestry_image",
    )
    child = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        output, errors = child.communicate(timeout=remaining(deadline))
    except BaseException:
        child.kill()
        child.communicate(timeout=3)
        raise
    require(
        child.returncode == 0 and errors == b"" and len(output) <= 16384,
        "ancestry_status",
    )
    packet = json.loads(output)
    require(packet["pid"] == child.pid, "ancestry_pid")
    require(
        module("installed_vhd_ci_fixture").native_state(packet) == "qualified",
        "protected_ancestry_prerequisite",
    )
    require(
        hashlib.sha256(executable.read_bytes()).hexdigest() == expected["sha256"]
        and identity(executable.lstat()) == expected["identity"],
        "ancestry_image_changed",
    )
    return packet


def copy_bundle(source, destination, deadline):
    """Read held ordinary bytes into independent exclusive root-owned fixture files."""
    rows = inventory(source)
    destination.mkdir(mode=0o755)
    for relative in sorted(rows, key=lambda value: (len(member(value)), value)):
        remaining(deadline)
        row, target = rows[relative], destination.joinpath(*member(relative))
        if row["kind"] == "directory":
            target.mkdir(mode=stat.S_IMODE(row["identity"]["mode"]))
        else:
            src = source.joinpath(*member(relative))
            fd = os.open(src, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                require(identity(os.fstat(fd)) == row["identity"], "copy_source_changed")
                data = bytearray()
                while len(data) < row["bytes"]:
                    block = os.read(fd, min(65536, row["bytes"] - len(data)))
                    require(block, "copy_source_changed")
                    data.extend(block)
                require(
                    hashlib.sha256(data).hexdigest() == row["sha256"]
                    and identity(os.fstat(fd)) == row["identity"],
                    "copy_source_changed",
                )
                write_exclusive(target, data, stat.S_IMODE(row["identity"]["mode"]))
            finally:
                os.close(fd)
    require(inventory(source) == rows, "copy_source_changed")


def changed_byte(path, offset):
    fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    try:
        value = os.pread(fd, 1, offset)
        require(len(value) == 1, "mutation_offset")
        require(os.pwrite(fd, bytes([value[0] ^ 1]), offset) == 1, "mutation_write")
    finally:
        os.close(fd)


def mutate(case, name, root, uid, deadline):
    executable = case / BINARY
    if name in ("unsigned", "adhoc"):
        image = case / "daemon.app"
        args = (
            ["/usr/bin/codesign", "--remove-signature", str(image)]
            if name == "unsigned"
            else ["/usr/bin/codesign", "--force", "--sign", "-", str(image)]
        )
        native(args, deadline)
    elif name == "bad-other-slice":
        # Independent 8.5 fat census: x86_64 at16384, arm64 at1753088.
        changed_byte(executable, 16384 if platform.machine() == "arm64" else 1753088)
    elif name == "changed-plist":
        changed_byte(case / "daemon.app/Contents/Info.plist", 0)
    elif name == "changed-resource":
        changed_byte(case / "daemon.app/Contents/_CodeSignature/CodeResources", 0)
    elif name == "symlink-ancestor":
        remove_tree(case / "daemon.app", inventory(case / "daemon.app"))
        os.symlink(str(root / "official/daemon.app"), case / "daemon.app")
    elif name in ("symlink-plist", "symlink-executable"):
        relative = "daemon.app/Contents/Info.plist" if name == "symlink-plist" else BINARY
        path = case / relative
        path.unlink()
        os.symlink(str(root / "official" / relative), path)
    elif name == "user-owned":
        os.chown(executable, uid, -1)
    elif name == "writable-file":
        os.chmod(executable, 0o666)
    elif name == "nonempty-acl":
        native(["/bin/chmod", "+a", f"user:{uid} allow read", str(executable)], deadline)
    elif name == "writable-ancestor":
        os.chmod(case, 0o775)
    elif name == "missing-daemon":
        remove_tree(case / "daemon.app", inventory(case / "daemon.app"))
    elif name == "missing-dext":
        remove_tree(case / "driver.dext", inventory(case / "driver.dext"))
    elif name == "missing-executable":
        executable.unlink()


def create_root(owner, nonce, deadline):
    require(os.geteuid() == 0 and sys.platform == "darwin", "privileged_prerequisite")
    owner = Path(owner)
    record = prepared(owner)
    require(
        owner.stat().st_uid == record["uid"]
        and record["uid"] == int(os.environ.get("SUDO_UID", "0")),
        "privileged_source_owner",
    )
    sample = ancestry(owner, record, deadline)
    root = fixture_root(nonce)
    library = os.open("/Library", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        require(
            identity(os.fstat(library))
            == {
                "dev": sample["nodes"][1]["identity"]["device"],
                "ino": sample["nodes"][1]["identity"]["inode"],
                "mode": sample["nodes"][1]["identity"]["mode"],
                "uid": sample["nodes"][1]["identity"]["uid"],
                "gid": sample["nodes"][1]["identity"]["gid"],
            },
            "library_changed",
        )
        os.mkdir(root.name, 0o755, dir_fd=library)
        captured = identity(root.lstat())
        require(captured["uid"] == 0 and not captured["mode"] & 0o022, "fixture_owner")
        for name in CASES:
            remaining(deadline)
            case = root / name
            case.mkdir(mode=0o755)
            version = (
                "8.6.0"
                if name == "newer-reference"
                else "8.4.0"
                if name == "same-signer-other-build"
                else "8.5.0"
            )
            payload = owner / ("expanded-" + version) / "Payload"
            copy_bundle(payload / DAEMON, case / "daemon.app", deadline)
            copy_bundle(payload / DEXT, case / "driver.dext", deadline)
            mutate(case, name, root, record["uid"], deadline)
        require(
            identity(root.lstat()) == captured
            and identity(os.fstat(library)) == identity(Path("/Library").lstat()),
            "fixture_changed",
        )
        require(prepared(owner) == record, "prepared_changed")
        rows = inventory(root, allow_links=True)
        state = {
            "schema": 1,
            "nonce": nonce,
            "identity": captured,
            "inventory": rows,
            "owner": str(owner),
            "owner_identity": identity(owner.lstat()),
            "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        }
        write_exclusive(root / ".fixture.json", json.dumps(state, sort_keys=True).encode())
        return {
            "schema": 1,
            "status": "created",
            "fixture_root": str(root),
            "identity": captured,
            "cases": list(CASES),
            "installation_qualified": False,
            "reference_qualified": False,
        }
    finally:
        os.close(library)


def cleanup_root(owner, nonce, expected_identity, deadline):
    require(os.geteuid() == 0 and sys.platform == "darwin", "privileged_prerequisite")
    owner = Path(owner)
    prepared(owner)
    root = fixture_root(nonce)
    require(identity(root.lstat()) == expected_identity, "fixture_changed")
    control = root / ".fixture.json"
    require(
        control.lstat().st_uid == 0
        and stat.S_IMODE(control.lstat().st_mode) == 0o600
        and control.lstat().st_nlink == 1,
        "fixture_control",
    )
    record = json.loads(control.read_bytes())
    require(
        set(record)
        == {
            "schema",
            "nonce",
            "identity",
            "inventory",
            "owner",
            "owner_identity",
            "source_sha256",
        }
        and record["schema"] == 1
        and record["nonce"] == nonce
        and record["identity"] == expected_identity,
        "fixture_control",
    )
    require(
        record["owner"] == str(owner)
        and record["owner_identity"] == identity(owner.lstat())
        and record["source_sha256"] == hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "fixture_owner_changed",
    )
    rows = inventory(root, allow_links=True)
    control_row = rows.pop(".fixture.json")
    require(rows == record["inventory"], "inventory_changed")
    rows[".fixture.json"] = control_row
    remaining(deadline)
    remove_tree(root, rows)
    return {
        "schema": 1,
        "status": "removed",
        "fixture_root": str(root),
        "installation_qualified": False,
        "reference_qualified": False,
    }


def privileged(action, owner, nonce, deadline, expected=None):
    script = Path(__file__).resolve(strict=True)
    digest = hashlib.sha256(script.read_bytes()).hexdigest()
    python = Path(sys.executable).resolve(strict=True)
    require(
        python.stat().st_uid == 0 and not python.stat().st_mode & 0o022,
        "privileged_python",
    )
    args = [
        "/usr/bin/sudo",
        "-n",
        str(python),
        "-I",
        "-B",
        str(script),
        "root-" + action,
        nonce,
        digest,
    ]
    args += (
        [str(owner)] if action == "create" else [str(owner), json.dumps(expected, sort_keys=True)]
    )
    result = native(args, deadline)
    require(
        result.stderr == b"" and hashlib.sha256(script.read_bytes()).hexdigest() == digest,
        "privileged_output",
    )
    return json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "action",
        choices=("prepare", "create", "cleanup", "root-create", "root-cleanup"),
    )
    parser.add_argument("arguments", nargs="+")
    options = parser.parse_args()
    deadline = time.monotonic() + SECONDS

    def interrupted(_signum, _frame):
        raise Refusal("deadline")

    previous = signal.signal(signal.SIGALRM, interrupted)
    signal.setitimer(signal.ITIMER_REAL, SECONDS)
    attempted_root = None
    try:
        args = options.arguments
        if options.action == "prepare":
            require(len(args) == 1, "arguments")
            result = prepare(Path(args[0]), deadline)
        elif options.action == "create":
            require(len(args) == 1, "arguments")
            nonce = secrets.token_hex(16)
            attempted_root = str(fixture_root(nonce))
            result = privileged("create", Path(args[0]), nonce, deadline)
        elif options.action == "cleanup":
            require(len(args) == 3, "arguments")
            attempted_root = str(fixture_root(args[1]))
            result = privileged("cleanup", Path(args[0]), args[1], deadline, json.loads(args[2]))
        else:
            require(
                len(args) == (3 if options.action == "root-create" else 4)
                and hashlib.sha256(Path(__file__).read_bytes()).hexdigest() == args[1],
                "source_changed",
            )
            attempted_root = str(fixture_root(args[0]))
            if options.action == "root-create":
                os.umask(0o022)
                result = create_root(Path(args[2]), args[0], deadline)
            else:
                result = cleanup_root(Path(args[2]), args[0], json.loads(args[3]), deadline)
        remaining(deadline)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (Refusal, OSError, ValueError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, Refusal) else type(error).__name__
        print(
            json.dumps(
                {
                    "schema": 1,
                    "status": "refused",
                    "reason": code,
                    "fixture_root": attempted_root,
                    "installation_qualified": False,
                    "reference_qualified": False,
                }
            )
        )
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == "__main__":
    sys.exit(main())
