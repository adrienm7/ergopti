"""Fixed native product compilation for the protected-runtime bundle owner.

This component compiles code only. It neither signs nor grants installation,
physical capture, or service authority. The packaging continuation must retain
the original signed runtime claim and invoke the genuine native validator.
"""

from dataclasses import dataclass
from pathlib import Path
import hashlib
import importlib.util
import io
import os
import signal
import re
import stat
import subprocess
import sys
import tarfile
import time


ARCHITECTURES = ("arm64", "x86_64")
LAUNCHER = "static/ergopti_plus/macos/launcher/Sources/"
SWIFT = LAUNCHER + "ErgoptiPlus/"
HELPER_SOURCES = (
    "tools/build/owned-runtime-installer/InstallerMain.swift",
    SWIFT + "OwnedRuntimeFirstInstallOwner.swift",
    SWIFT + "OwnedRuntimeBootstrapStageOwner.swift",
    SWIFT + "OwnedRuntimeInstallOwner.swift",
    SWIFT + "OwnedRuntimeInstallWorker.swift",
    SWIFT + "OwnedRuntimePublisherIdentity.swift",
    SWIFT + "OwnedRuntimeInstallJournal.swift",
    SWIFT + "OwnedRuntimeServiceLifecycleLock.swift",
    SWIFT + "LauncherConstants.swift",
)
VALIDATOR_SOURCES = (
    "tools/build/owned-runtime-installer/BuildValidationMain.swift",
    SWIFT + "OwnedRuntimeBuildValidationEntry.swift",
    SWIFT + "OwnedRuntimeInstallOwner.swift",
    SWIFT + "OwnedRuntimeInstallWorker.swift",
    SWIFT + "OwnedRuntimePublisherIdentity.swift",
    SWIFT + "LauncherConstants.swift",
)
LIFECYCLE_C = LAUNCHER + "CPOSIXCompatibility/OwnedRuntimeLifecycleContract.c"
LIFECYCLE_HEADER = LAUNCHER + "CPOSIXCompatibility/include/OwnedRuntimeLifecycleContract.h"
SIGNATURE_HEADER = LAUNCHER + "CPOSIXCompatibility/include/OwnedRuntimeSignatureCompatibility.h"
MODULE_SOURCE = "tools/build/owned-runtime-native/installed_physical_source.mm"
SHARED_PUBLISHER_HEADER = "tools/build/InstalledRuntimePublisher.hpp"
SOURCE_PATHS = tuple(
    dict.fromkeys(
        HELPER_SOURCES
        + VALIDATOR_SOURCES
        + (
            LIFECYCLE_C,
            LIFECYCLE_HEADER,
            SIGNATURE_HEADER,
            MODULE_SOURCE,
            SHARED_PUBLISHER_HEADER,
        )
    )
)
LUA_ARCHIVE_SHA256 = "9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30"
NATIVE_BACKEND = "tools/diagnostics/hs274_native_build.py"
NATIVE_BACKEND_SHA256 = "9695174913fec75b4f0ea1b58b1fed70a06f31fc88dcc7b521ca93eb730d9fe6"
HAMMERSPOON_COMMIT = "1469832361b4c3687ec7d589c1b4efe4d3b742ee"
# Actual Hammerspoon1.1.1 vendored source, not a standard-Lua ABI assumption.
HAMMERSPOON_HEADERS = (
    (
        "lua.h",
        15949,
        "f050dac0913175c9d01f3ccb6a47ca0e9ab5c06a",
        "341014ee8b49570fc01c1fb2afc6a7decc853525636c74e7a6a9507a933aa62e",
    ),
    (
        "lauxlib.h",
        9314,
        "5b977e2a39f13192dab2060cb4f4c1ce01bc1b5b",
        "2d9e18e577a6062646268e7f7228264c28bd9b972c186e1af81b8357179c0ab4",
    ),
    (
        "luaconf.h",
        23620,
        "f6301f4e29eda9418ff3b057dfaca5b26abcf518",
        "84dd524ace595e6077418bbf83e28e1d87d9bb002d9a7493db748782bf045db1",
    ),
    (
        "lualib.h",
        1116,
        "2625529076a8f47cd733a778665c6963908fed44",
        "4ea0f67d3e467f5d6a327616e22a3c2da8e03d47a3c3660916275f2842f521ea",
    ),
    (
        "lua.hpp",
        191,
        "ec417f59469c8672a13a726afe6186cccbe54895",
        "fd83f7e823cfbb03ac2da937ec83f01b4a6ddaac220a4fa1ffd6c6c3842c5890",
    ),
)


class ProductBuildRefusal(RuntimeError):
    pass


def require(condition, reason):
    if not condition:
        raise ProductBuildRefusal(reason)


def identity(info):
    # Reads may update access time; every identity/content metadata field stays
    # part of the retained admission, including nanosecond modification times.
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_uid,
        info.st_gid,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


@dataclass
class HeldSource:
    path: Path
    descriptor: int
    stamp: tuple
    data: bytes
    git_blob: str

    def current(self):
        require(self.path.resolve(strict=True) == self.path, "source acquired a linked ancestor")
        require(identity(os.fstat(self.descriptor)) == self.stamp, "held source metadata changed")
        require(identity(self.path.lstat()) == self.stamp, "source name or identity changed")
        require(
            os.pread(self.descriptor, len(self.data) + 1, 0) == self.data,
            "held source bytes changed",
        )

    def close(self):
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


def capture_source(repository, relative):
    require(relative in SOURCE_PATHS + (NATIVE_BACKEND,), "unknown product source")
    repository = Path(repository)
    require(
        repository.is_absolute() and repository.resolve(strict=True) == repository,
        "repository must be its canonical absolute path",
    )
    path = repository / relative
    for parent in (path, *path.parents):
        if parent == repository:
            break
        require(not parent.is_symlink(), "source has a linked ancestor")
    row = subprocess.run(
        ["git", "ls-files", "--stage", "-z", "--", relative],
        cwd=repository,
        capture_output=True,
        check=False,
    )
    require(row.returncode == 0 and row.stderr == b"", "Git source admission failed")
    records = row.stdout.split(b"\0")
    require(len(records) == 2 and records[-1] == b"", "source is not one tracked leaf")
    metadata, name = records[0].split(b"\t", 1)
    mode, blob, stage = metadata.split(b" ")
    require(
        mode == b"100644" and stage == b"0" and name == relative.encode(),
        "source is not a resolved regular tracked leaf",
    )
    captured = subprocess.run(
        ["git", "cat-file", "blob", blob.decode("ascii")],
        cwd=repository,
        capture_output=True,
        check=False,
    )
    require(captured.returncode == 0 and captured.stderr == b"", "Git blob admission failed")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        require(
            stat.S_ISREG(info.st_mode)
            and info.st_nlink == 1
            and info.st_uid == os.getuid()
            and 0 < info.st_size <= 4 * 1024 * 1024,
            "source is not a bounded owned ordinary leaf",
        )
        data = os.pread(descriptor, info.st_size + 1, 0)
        held = HeldSource(path, descriptor, identity(info), data, blob.decode("ascii"))
        held.current()
        require(data == captured.stdout, "source differs from its actual Git index blob")
        return held
    except BaseException:
        os.close(descriptor)
        raise


def compile_commands(repository, work, sdk, lua_headers):
    """Return the fixed roster; callers cannot supply source names or options."""
    repository, work, sdk, lua_headers = map(Path, (repository, work, sdk, lua_headers))
    require(
        all(
            p.is_absolute() and p.resolve(strict=True) == p
            for p in (repository, work, sdk, lua_headers)
        ),
        "noncanonical compile input",
    )
    require(
        work.is_dir()
        and sdk.is_dir()
        and re.fullmatch(r"MacOSX(?:[0-9]+(?:\.[0-9]+)*)?\.sdk", sdk.name) is not None
        and lua_headers.is_dir(),
        "invalid native compile roots",
    )
    require(not any(work.iterdir()), "native compile work directory is not exclusive")
    result = []
    for architecture in ARCHITECTURES:
        native_object = work / ("lifecycle_" + architecture + ".o")
        result.append(
            (
                "lifecycle_" + architecture,
                [
                    "/usr/bin/xcrun",
                    "clang",
                    "-arch",
                    architecture,
                    "-isysroot",
                    str(sdk),
                    "-mmacosx-version-min=13.0",
                    "-I",
                    str(repository / (LAUNCHER + "CPOSIXCompatibility/include")),
                    "-c",
                    str(repository / LIFECYCLE_C),
                    "-o",
                    str(native_object),
                ],
            )
        )
        for role, sources in (("installer", HELPER_SOURCES), ("validator", VALIDATOR_SOURCES)):
            command = [
                "/usr/bin/xcrun",
                "swiftc",
                "-parse-as-library",
                "-target",
                architecture + "-apple-macosx13.0",
                "-sdk",
                str(sdk),
            ]
            command += ["-import-objc-header", str(repository / SIGNATURE_HEADER)]
            command += [str(repository / source) for source in sources]
            if role == "installer":
                command.append(str(native_object))
            command += ["-o", str(work / (role + "_" + architecture))]
            result.append((role + "_" + architecture, command))
        result.append(
            (
                "module_" + architecture,
                [
                    "/usr/bin/xcrun",
                    "clang++",
                    "-arch",
                    architecture,
                    "-isysroot",
                    str(sdk),
                    "-mmacosx-version-min=13.0",
                    "-std=c++17",
                    "-fobjc-arc",
                    "-bundle",
                    "-undefined",
                    "dynamic_lookup",
                    "-I",
                    str(lua_headers),
                    "-I",
                    str(repository / "tools/build"),
                    "-framework",
                    "Foundation",
                    "-framework",
                    "Security",
                    str(repository / MODULE_SOURCE),
                    "-o",
                    str(work / ("module_" + architecture + ".so")),
                ],
            )
        )
    for role, suffix in (("installer", ""), ("validator", ""), ("module", ".so")):
        result.append(
            (
                role + "_universal",
                [
                    "/usr/bin/lipo",
                    "-create",
                    *[
                        str(work / (role + "_" + architecture + suffix))
                        for architecture in ARCHITECTURES
                    ],
                    "-output",
                    str(work / (role + suffix)),
                ],
            )
        )
    return tuple(result)


def source_receipt(sources):
    for held in sources:
        held.current()
    return tuple(
        {
            "path": str(held.path),
            "git_blob": held.git_blob,
            "bytes": len(held.data),
            "sha256": hashlib.sha256(held.data).hexdigest(),
        }
        for held in sources
    )


def _lua_headers(build_work):
    """Use the original LuaSocket owner's pinned archive, not an ambient ABI."""
    root = Path(build_work)
    require(
        root.is_absolute() and root.resolve(strict=True) == root, "Lua build input is not canonical"
    )
    archive = root / "lua.tar.gz"
    require(
        archive.resolve(strict=True) == archive and archive.is_file(),
        "Lua archive is not an ordinary input",
    )
    descriptor = os.open(archive, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = identity(os.fstat(descriptor))
        require(
            stat.S_ISREG(before[2]) and before[5] == 1 and 0 < before[6] <= 4 * 1024 * 1024,
            "Lua archive shape refused",
        )
        data = os.pread(descriptor, before[6] + 1, 0)
        require(
            hashlib.sha256(data).hexdigest() == LUA_ARCHIVE_SHA256
            and identity(os.fstat(descriptor)) == before
            and identity(archive.lstat()) == before,
            "Lua archive pin changed",
        )
    finally:
        os.close(descriptor)
    headers = root / "lua-5.4.7/src"
    require(headers.resolve(strict=True) == headers, "Lua header namespace changed")
    stamps = []
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as package:
        for name in ("lua.h", "luaconf.h", "lauxlib.h", "lualib.h"):
            member = package.getmember("lua-5.4.7/src/" + name)
            require(
                member.isfile() and 0 < member.size < 128 * 1024, "Lua header archive shape refused"
            )
            held = package.extractfile(member)
            require(held is not None, "Lua header absent from pinned archive")
            with held:
                expected = held.read(128 * 1024)
            path = headers / name
            require(path.resolve(strict=True) == path, "Lua header acquired a link")
            header_fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                stamp = identity(os.fstat(header_fd))
                require(
                    stat.S_ISREG(stamp[2])
                    and stamp[5] == 1
                    and os.pread(header_fd, 128 * 1024, 0) == expected
                    and identity(os.fstat(header_fd)) == stamp
                    and identity(path.lstat()) == stamp,
                    "Lua extracted header differs from pinned archive",
                )
                stamps.append((name, stamp))
            finally:
                os.close(header_fd)
    return headers, tuple(stamps)


def _current_hammerspoon_headers(root):
    require(
        root.resolve(strict=True) == root
        and root.is_dir()
        and set(p.name for p in root.iterdir()) == {r[0] for r in HAMMERSPOON_HEADERS},
        "Hammerspoon header namespace changed",
    )
    result = []
    for name, size, blob, digest in HAMMERSPOON_HEADERS:
        path = root / name
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            stamp = identity(os.fstat(descriptor))
            require(
                stat.S_ISREG(stamp[2])
                and stamp[3] == os.getuid()
                and stamp[5] == 1
                and stamp[6] == size,
                "Hammerspoon header custody changed",
            )
            data = os.pread(descriptor, size + 1, 0)
            require(
                len(data) == size
                and hashlib.sha256(data).hexdigest() == digest
                and hashlib.sha1(b"blob " + str(size).encode("ascii") + b"\0" + data).hexdigest()
                == blob
                and identity(os.fstat(descriptor)) == stamp
                and identity(path.lstat()) == stamp,
                "Hammerspoon header is not the exact source Git blob",
            )
            result.append((name, stamp, digest))
        finally:
            os.close(descriptor)
    return tuple(result)


def _acquire_hammerspoon_headers(owner, backend, deadline):
    root = owner / "hammerspoon_native_lua_headers"
    root.mkdir(mode=0o700)
    for name, _, _, _ in HAMMERSPOON_HEADERS:
        require(time.monotonic() < deadline, "Hammerspoon header acquisition budget expired")
        path = root / name
        require(not path.exists(), "Hammerspoon header destination already exists")
        url = (
            "https://raw.githubusercontent.com/Hammerspoon/hammerspoon/"
            + HAMMERSPOON_COMMIT
            + "/LuaSkin/lua-5.4.7/src/"
            + name
        )
        backend.run_phase(
            "production_hammerspoon_" + name.replace(".", "_"),
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
                "--tlsv1.2",
                "--max-filesize",
                "131072",
                "--output",
                str(path),
                url,
            ],
            owner,
            owner,
            deadline,
        )
    return root, _current_hammerspoon_headers(root)


def compile_native_parts(repository, owner, lua_build_work, deadline):
    """Compile both exact architectures inside the original live build budget.

    This function must run within the original compilation guardian. It never
    starts a new budget, signs products, executes the installer, or reads a
    caller-provided compiler/validator binary.
    """
    require(
        sys.platform == "darwin" and os.getuid() != 0 and os.geteuid() != 0,
        "native product build requires a non-root Darwin owner",
    )
    require(
        type(deadline) in (float, int) and time.monotonic() < deadline,
        "original native budget exhausted",
    )
    repository, owner = Path(repository), Path(owner)
    require(
        owner.is_absolute()
        and owner.resolve(strict=True) == owner
        and owner.is_dir()
        and stat.S_IMODE(owner.stat().st_mode) == 0o700
        and owner.stat().st_uid == os.getuid(),
        "native owner custody refused",
    )
    sources = []
    try:
        backend_source = capture_source(repository, NATIVE_BACKEND)
        sources.append(backend_source)
        require(
            hashlib.sha256(backend_source.data).hexdigest() == NATIVE_BACKEND_SHA256,
            "original native tool owner source differs",
        )
        spec = importlib.util.spec_from_file_location(
            "fixed_owned_product_native_backend", backend_source.path
        )
        require(spec is not None and spec.loader is not None, "native backend import refused")
        backend = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = backend
        exec(compile(backend_source.data, str(backend_source.path), "exec"), backend.__dict__)
        for relative in SOURCE_PATHS:
            sources.append(capture_source(repository, relative))
        before = source_receipt(sources)
        header_input = _lua_headers(lua_build_work)
        headers, hammerspoon_stamp = _acquire_hammerspoon_headers(owner, backend, deadline)
        backend.run_phase(
            "production_sdk",
            ["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
            owner,
            owner,
            deadline,
        )
        sdk_output = (owner / "production_sdk.stdout").read_bytes()
        require(
            sdk_output.endswith(b"\n")
            and sdk_output.count(b"\n") == 1
            and (owner / "production_sdk.stderr").read_bytes() == b"",
            "native SDK discovery did not return one closed path",
        )
        sdk = Path(sdk_output[:-1].decode("utf-8", "strict")).resolve(strict=True)
        work = owner / "native_production_parts"
        work.mkdir(mode=0o700)
        commands = compile_commands(repository, work, sdk, headers)
        for name, arguments in commands:
            require(
                source_receipt(sources) == before
                and _lua_headers(lua_build_work) == header_input
                and _current_hammerspoon_headers(headers) == hammerspoon_stamp
                and time.monotonic() < deadline,
                "native compilation input or budget changed",
            )
            try:
                backend.run_phase("production_" + name, arguments, work, owner, deadline)
            finally:
                require(
                    source_receipt(sources) == before
                    and _lua_headers(lua_build_work) == header_input
                    and _current_hammerspoon_headers(headers) == hammerspoon_stamp,
                    "source changed during native child",
                )
        for role, suffix in (("installer", ""), ("validator", ""), ("module", ".so")):
            output = work / (role + suffix)
            require(
                output.resolve(strict=True) == output
                and output.is_file()
                and output.stat().st_nlink == 1
                and output.stat().st_uid == os.getuid(),
                "native product output custody refused",
            )
            backend.run_phase(
                "production_" + role + "_architectures",
                ["/usr/bin/lipo", "-verify_arch", "arm64", "x86_64", str(output)],
                work,
                owner,
                deadline,
            )
        require(source_receipt(sources) == before, "final native source changed")
        return work, before
    finally:
        for held in sources:
            held.close()


INSTALLER_ID = "com.ergoptiplus.app.runtime-installer"
MODULE_ID = "com.ergoptiplus.app.installed-physical-source"
CORE_IDLE_FACTORY_SHA256 = "d30b414066703652ed8d59cf668c0db4f6d8fed0aeebb1f9eb7ac5ed46f6fc22"
CURRENT_SOURCE_FACTORY_SHA256 = "9caa7c6b7a89fd1420452b59c4c5697a7a2aaaa9293498652f6b8a6628094c9d"
SDK_SOURCE_SUPPLIER_SHA256 = "aeb2949e50e628ed6db88aaa9d4726c4d485a48d94adccb67ba1203563b1668f"


def _snapshot(root, deadline, *, resource_owner=None):
    """Retain every ordinary built leaf and directory, never a JSON authority."""
    root = Path(root)
    require(root.resolve(strict=True) == root and root.is_dir(), "product root changed")
    directories, files = {}, {}
    for parent, children, leaves in os.walk(root, followlinks=False):
        require(time.monotonic() < deadline, "product snapshot budget expired")
        parent = Path(parent)
        for name in children:
            directory = parent / name
            info = directory.lstat()
            require(
                stat.S_ISDIR(info.st_mode)
                and info.st_uid == os.getuid()
                and directory.resolve(strict=True) == directory,
                "product directory custody changed",
            )
        directory_info = parent.lstat()
        directories[parent.relative_to(root).as_posix()] = identity(directory_info)
        for name in leaves:
            path = parent / name
            acquire = os.open if resource_owner is None else resource_owner.open
            descriptor = acquire(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                info = os.fstat(descriptor)
                require(
                    stat.S_ISREG(info.st_mode)
                    and info.st_uid == os.getuid()
                    and info.st_nlink == 1
                    and 0 <= info.st_size <= 512 * 1024 * 1024,
                    "product leaf is not one bounded owned regular file",
                )
                digest = hashlib.sha256()
                offset = 0
                while offset < info.st_size:
                    require(time.monotonic() < deadline, "product hash budget expired")
                    data = os.pread(descriptor, min(65536, info.st_size - offset), offset)
                    require(bool(data), "product leaf truncated")
                    digest.update(data)
                    offset += len(data)
                require(
                    identity(os.fstat(descriptor)) == identity(info)
                    and identity(path.lstat()) == identity(info),
                    "product changed during read",
                )
                files[path.relative_to(root).as_posix()] = (identity(info), digest.hexdigest())
            finally:
                if resource_owner is None:
                    os.close(descriptor)
                else:
                    resource_owner.close_preserving(descriptor, sys.exc_info()[1])
    return directories, files


def _compiled_bytes(path, expected, deadline, *, resource_owner=None):
    acquire = os.open if resource_owner is None else resource_owner.open
    descriptor = acquire(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = identity(os.fstat(descriptor))
        require(
            before == expected[0]
            and stat.S_ISREG(before[2])
            and before[5] == 1
            and 0 < before[6] <= 512 * 1024 * 1024,
            "compiled leaf custody changed",
        )
        require(time.monotonic() < deadline, "compiled copy budget expired")
        data = os.pread(descriptor, before[6] + 1, 0)
        require(
            len(data) == before[6]
            and hashlib.sha256(data).hexdigest() == expected[1]
            and identity(os.fstat(descriptor)) == before
            and identity(Path(path).lstat()) == before,
            "compiled content or identity changed",
        )
        return data
    finally:
        if resource_owner is None:
            os.close(descriptor)
        else:
            resource_owner.close_preserving(descriptor, sys.exc_info()[1])


def _snapshot_leaf(path, deadline):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        before = os.fstat(descriptor)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.getuid()
            and before.st_nlink == 1
            and 0 < before.st_size <= 512 * 1024 * 1024,
            "compiled output shape changed",
        )
        digest = hashlib.sha256()
        offset = 0
        while offset < before.st_size:
            require(time.monotonic() < deadline, "compiled hash budget expired")
            data = os.pread(descriptor, min(65536, before.st_size - offset), offset)
            require(bool(data), "compiled output truncated")
            digest.update(data)
            offset += len(data)
        require(
            identity(os.fstat(descriptor)) == identity(before)
            and identity(Path(path).lstat()) == identity(before),
            "compiled output changed during read",
        )
        return identity(before), digest.hexdigest()
    finally:
        os.close(descriptor)


class _ResourceDescriptorScope:
    """Root resource descriptors before acquisition and retain ambiguous close debt."""

    def __init__(self, held_sources=()):
        # These are the original native HeldSource owners, already rooted by the
        # packaging continuation; no detached descriptor creates source scope.
        self.held_sources = held_sources
        self.prior_custody = None
        self.owners = []
        self.failures = []
        self.debt = False
        self.original_mask = None
        self.mask_restored = False

    def __enter__(self):
        try:
            self.original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            signal.pthread_sigmask(
                signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGALRM}
            )
        except BaseException as error:
            self.debt = True
            self.failures.append(error)
            self.__exit__(type(error), error, error.__traceback__)
            raise
        return self

    def callback(self, operation):
        """Keep retained FD owners while restoring the caller's child-process mask."""
        primary = None
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, self.original_mask)
            return operation()
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                signal.pthread_sigmask(
                    signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGALRM}
                )
            except BaseException as cleanup:
                self.debt = True
                self.failures.append(cleanup)
                if primary is None:
                    raise
                primary.add_note("Resource signal deferral also refused: " + type(cleanup).__name__)

    def open(self, path, flags, mode=0o777, *, dir_fd=None):
        owner = {"descriptor": None, "close_attempted": False, "closed": False, "debt": False}
        self.owners.append(owner)
        try:
            owner["descriptor"] = os.open(path, flags, mode, dir_fd=dir_fd)
        except BaseException as error:
            # An interrupted acquisition cannot invent proof that no descriptor
            # was allocated. The rooted record remains attached to the failure.
            owner["debt"] = self.debt = True
            self.failures.append(error)
            raise
        return owner["descriptor"]

    def close(self, descriptor):
        owner = next(row for row in self.owners if row["descriptor"] == descriptor)
        require(not owner["close_attempted"], "resource descriptor close already attempted")
        owner["close_attempted"] = True
        try:
            os.close(descriptor)
        except BaseException as error:
            # Retrying a close whose physical outcome is unknown could close an
            # unrelated reused descriptor. Retain debt and refuse publication.
            owner["debt"] = self.debt = True
            self.failures.append(error)
            raise
        owner["closed"] = True
        owner["descriptor"] = None

    def close_preserving(self, descriptor, primary):
        try:
            self.close(descriptor)
        except BaseException as cleanup:
            if primary is None:
                raise
            # The pending primary is rethrown by the original finally. Its
            # rooted scope still retains this close refusal and unknown outcome.
            primary.add_note("Resource close also refused: " + type(cleanup).__name__)

    def __exit__(self, kind, primary, trace):
        cleanup = None
        try:
            signal.pthread_sigmask(
                signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGALRM}
            )
        except BaseException as error:
            self.debt = True
            self.failures.append(error)
            cleanup = error
        for source in self.held_sources:
            if source.descriptor < 0:
                continue
            owner = {
                "descriptor": source.descriptor,
                "source": source,
                "close_attempted": True,
                "closed": False,
                "debt": False,
            }
            self.owners.append(owner)
            try:
                source.close()
            except BaseException as error:
                owner["debt"] = self.debt = True
                self.failures.append(error)
                if cleanup is None:
                    cleanup = error
            else:
                owner["closed"] = True
                owner["descriptor"] = None
            finally:
                # The genuine owner attempted this close exactly once. Unknown
                # physical outcome remains rooted above, never retried against
                # a descriptor number that may already have been reused.
                source.descriptor = -1
        for owner in reversed(self.owners):
            if owner["descriptor"] is not None and not owner["close_attempted"]:
                try:
                    self.close(owner["descriptor"])
                except BaseException as error:
                    if cleanup is None:
                        cleanup = error
        try:
            if self.original_mask is None:
                # Entry could not observe the caller mask. Retire every held FD
                # but never invent a restored mask or a positive cleanup result.
                self.debt = True
            else:
                signal.pthread_sigmask(signal.SIG_SETMASK, self.original_mask)
                self.mask_restored = True
        except BaseException as error:
            # A deferred handler can raise after the kernel restored the mask.
            # Observe that exact mask without changing it; retain any uncertainty.
            try:
                self.mask_restored = (
                    signal.pthread_sigmask(signal.SIG_BLOCK, set()) == self.original_mask
                )
            except BaseException as observation:
                self.failures.append(observation)
            self.debt = self.debt or not self.mask_restored
            self.failures.append(error)
            if cleanup is None:
                cleanup = error
        error = primary if primary is not None else cleanup
        if error is not None:
            prior = getattr(error, "_resource_custody", None)
            if prior is not None and prior is not self:
                self.prior_custody = prior
                self.debt = self.debt or prior.debt
            error._resource_custody = self
            if primary is not None:
                for secondary in self.failures:
                    if secondary is not primary:
                        primary.add_note(
                            "Resource custody also refused: " + type(secondary).__name__
                        )
                return False
            raise error
        require(not self.debt and self.mask_restored, "resource custody retirement unresolved")
        return False


def _retire_sdk_sources(held_sources, backend_source, primary):
    """Close original SDK source owners without replacing a pending resource refusal."""
    scope = _ResourceDescriptorScope((*held_sources, backend_source))
    try:
        scope.__enter__()
    except BaseException as acquisition:
        # __enter__ already attempted the rooted closures on deferral refusal.
        if primary is None:
            raise
        prior = getattr(primary, "_resource_custody", None)
        scope.prior_custody = prior
        scope.debt = scope.debt or (prior is not None and prior.debt)
        primary._resource_custody = scope
        primary.add_note("SDK source retirement also refused: " + type(acquisition).__name__)
        return
    scope.__exit__(
        type(primary) if primary is not None else None,
        primary,
        primary.__traceback__ if primary is not None else None,
    )


def _write_exclusive(path, data, mode, deadline, *, directory_descriptor=None, resource_owner=None):
    require(
        type(data) is bytes and type(mode) is int and mode in (0o644, 0o755),
        "output leaf bytes or mode refused",
    )
    if directory_descriptor is not None and resource_owner is None:
        with _ResourceDescriptorScope() as scope:
            return _write_exclusive(
                path,
                data,
                mode,
                deadline,
                directory_descriptor=directory_descriptor,
                resource_owner=scope,
            )
    if directory_descriptor is not None:
        require(
            type(path) is str and Path(path).name == path and path not in {".", ".."},
            "resource output is not one fixed leaf",
        )
    acquire = os.open if resource_owner is None else resource_owner.open
    descriptor = acquire(
        path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        mode,
        dir_fd=directory_descriptor,
    )
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            require(time.monotonic() < deadline, "product write budget expired")
            count = os.write(descriptor, data[offset : offset + 65536])
            require(count > 0, "output write refused")
            offset += count
        info = os.fstat(descriptor)
        require(
            stat.S_ISREG(info.st_mode)
            and info.st_uid == os.getuid()
            and info.st_nlink == 1
            and info.st_size == len(data)
            and identity(info)
            == identity(os.stat(path, dir_fd=directory_descriptor, follow_symlinks=False)),
            "output identity changed",
        )
        os.fsync(descriptor)
    finally:
        if resource_owner is None:
            os.close(descriptor)
        else:
            resource_owner.close_preserving(descriptor, sys.exc_info()[1])


VIRTUAL_HID_RESOURCE_NAMES = (
    "Karabiner-DriverKit-VirtualHIDDevice-8.5.0.pkg",
    "org.pqrs.service.daemon.Karabiner-VirtualHIDDevice-Daemon.plist",
)


def _stage_virtual_hid_resources(resources_parent, payload, deadline, current):
    """Copy only retained source resource bytes through exact owned directory descriptors."""
    require(callable(current), "source payload currentness absent")
    current()
    require(time.monotonic() < deadline, "resource copy budget expired")
    rows = payload.resources
    require(
        type(rows) is tuple
        and len(rows) == 2
        and all(type(row) is tuple and len(row) == 2 and type(row[1]) is bytes for row in rows)
        and tuple(row[0] for row in rows) == VIRTUAL_HID_RESOURCE_NAMES,
        "fixed source payload membership differs",
    )
    parent = Path(resources_parent)
    require(
        parent.is_absolute() and parent.resolve(strict=True) == parent, "resource parent redirects"
    )
    with _ResourceDescriptorScope() as scope:
        parent_fd = scope.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
        parent_info = os.fstat(parent_fd)
        require(
            stat.S_ISDIR(parent_info.st_mode) and parent_info.st_uid == os.getuid(),
            "resource parent is not owned",
        )
        parent_identity = (
            parent_info.st_dev,
            parent_info.st_ino,
            parent_info.st_uid,
            parent_info.st_mode,
        )
        scope.callback(current)
        os.mkdir("VirtualHIDDriverPayload", mode=0o755, dir_fd=parent_fd)
        destination_fd = scope.open(
            "VirtualHIDDriverPayload",
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_fd,
        )
        target = parent / "VirtualHIDDriverPayload"
        target_info = os.fstat(destination_fd)
        require(
            stat.S_ISDIR(target_info.st_mode) and target_info.st_uid == os.getuid(),
            "resource destination is not owned",
        )
        target_identity = (
            target_info.st_dev,
            target_info.st_ino,
            target_info.st_uid,
            target_info.st_mode,
        )

        def boundary():
            scope.callback(current)
            for held, named, expected in (
                (os.fstat(parent_fd), parent.lstat(), parent_identity),
                (os.fstat(destination_fd), target.lstat(), target_identity),
            ):
                require(
                    (held.st_dev, held.st_ino, held.st_uid, held.st_mode) == expected
                    and (named.st_dev, named.st_ino, named.st_uid, named.st_mode) == expected,
                    "resource directory custody changed",
                )
            require(parent.resolve(strict=True) == parent, "resource ancestor redirects")
            require(time.monotonic() < deadline, "resource copy budget expired")

        boundary()
        for name, data in rows:
            boundary()
            _write_exclusive(
                name,
                data,
                0o644,
                deadline,
                directory_descriptor=destination_fd,
                resource_owner=scope,
            )
            boundary()
        require(
            set(os.listdir(destination_fd)) == set(VIRTUAL_HID_RESOURCE_NAMES),
            "unowned resource member appeared",
        )
        snapshot = _snapshot(target, deadline, resource_owner=scope)
        require(
            set(snapshot[0]) == {"."} and set(snapshot[1]) == set(VIRTUAL_HID_RESOURCE_NAMES),
            "resource tree membership differs",
        )
        for name, data in rows:
            _compiled_bytes(target / name, snapshot[1][name], deadline, resource_owner=scope)
            require(
                snapshot[1][name][1] == hashlib.sha256(data).hexdigest(),
                "copied source payload bytes differ",
            )
        os.fsync(destination_fd)
        os.fsync(parent_fd)
        boundary()
        return target, snapshot


def _package_live(
    repository,
    owner,
    lua_build,
    record,
    directories,
    files,
    leaf,
    signing_identity,
    keychain,
    claim_current,
    deadline,
    *,
    source_current=None,
    staged_source=None,
    driver_payload=None,
    driver_payload_current=None,
):
    """Fixed continuation of the original signed scope; never install or start.

    Only the fixed builder continuation may call this private function after
    authenticating the original claim's exact record/member object identities.
    Its retained-current closure is checked around every tool and filesystem
    boundary. Native validation supplies actual CMS/load/CPU admission; a report
    or detached signed path cannot replace that validation.
    """
    import plistlib

    require(
        sys.platform == "darwin" and os.getuid() != 0 and os.getuid() == os.geteuid(),
        "production packaging requires an unprivileged native Darwin owner",
    )
    require(
        callable(claim_current) and time.monotonic() < deadline,
        "original signed claim or budget absent",
    )
    require(source_current is None or callable(source_current), "current source owner absent")
    claim_current()
    sdk = False
    if source_current is None:
        # The original schema-2 source/history admission remains exact.
        require(
            record["source_factory_sha256"] == CORE_IDLE_FACTORY_SHA256,
            "production Core requires the exact idle-gated source factory",
        )
    else:
        require(
            record.get("schema") == 3
            and record.get("source_factory_sha256") == CURRENT_SOURCE_FACTORY_SHA256
            and record.get("source_profile")
            in {"owned_vhd_broker_source_v2", "owned_installed_sdk_source_v1"},
            "production source requires the exact current factory profile",
        )
        sdk = record["source_profile"] == "owned_installed_sdk_source_v1"
        require(
            (sdk and record.get("sdk_supplier_sha256") == SDK_SOURCE_SUPPLIER_SHA256)
            or (not sdk and "sdk_supplier_sha256" not in record),
            "production SDK source supplier differs",
        )
        original_claim_current = claim_current

        def claim_current():
            # Both checks remain within the original signed scope. A metadata
            # record cannot substitute for the retained real source image.
            original_claim_current()
            source_current()

    if source_current is not None:
        source_current()
    if sdk:
        require(
            staged_source is not None
            and driver_payload is not None
            and driver_payload.image is staged_source
            and callable(driver_payload_current),
            "original staged SDK payload source absent",
        )
        driver_payload_current()
    else:
        require(
            staged_source is None and driver_payload is None and driver_payload_current is None,
            "legacy production cannot acquire SDK resource scope",
        )
    require(
        type(signing_identity) is str
        and re.fullmatch(r"[A-F0-9]{40}", signing_identity) is not None
        and type(leaf) is bytes
        and 0 < len(leaf) <= 65536,
        "actual signed principal or certificate missing",
    )
    keychain = Path(keychain)
    require(
        keychain.is_absolute()
        and keychain.resolve(strict=True) == keychain
        and keychain.is_file()
        and keychain.stat().st_uid == os.getuid(),
        "signing credential custody refused",
    )
    work, receipts = compile_native_parts(repository, owner, lua_build, deadline)
    claim_current()

    def snapshot(root, budget):
        if not sdk:
            return _snapshot(root, budget)
        with _ResourceDescriptorScope() as scope:
            return _snapshot(root, budget, resource_owner=scope)

    def compiled_bytes(path, expected, budget):
        if not sdk:
            return _compiled_bytes(path, expected, budget)
        with _ResourceDescriptorScope() as scope:
            return _compiled_bytes(path, expected, budget, resource_owner=scope)

    def write_exclusive(path, data, mode, budget):
        if not sdk:
            return _write_exclusive(path, data, mode, budget)
        with _ResourceDescriptorScope() as scope:
            return _write_exclusive(path, data, mode, budget, resource_owner=scope)

    compiled_snapshot = snapshot(work, deadline)
    # The validator is an inert native executable. It never acquires installer
    # authority; its direct zero status closes product validation only.
    backend_source = capture_source(repository, NATIVE_BACKEND)
    held_sources = []
    try:
        for path in SOURCE_PATHS:
            held_sources.append(capture_source(repository, path))
        require(
            source_receipt((backend_source, *held_sources)) == receipts,
            "compiled source closure changed before packaging",
        )
        specification = importlib.util.spec_from_file_location(
            "fixed_live_product_backend", backend_source.path
        )
        backend = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = backend
        exec(compile(backend_source.data, str(backend_source.path), "exec"), backend.__dict__)

        def current():
            claim_current()
            for name, stamp in compiled_snapshot[1].items():
                require(_snapshot_leaf(work / name, deadline) == stamp, "compiled artifact changed")
            require(
                time.monotonic() < deadline
                and source_receipt((backend_source, *held_sources)) == receipts,
                "live source/budget changed during packaging",
            )

        def phase(name, argv):
            current()
            try:
                backend.run_phase("production_" + name, argv, work, owner, deadline)
            finally:
                current()

        def payload_current():
            current()
            require(sdk and driver_payload.image is staged_source, "original SDK payload detached")
            driver_payload_current()
            current()

        stage = owner / "production_runtime_package"
        stage.mkdir(mode=0o700)
        installer = stage / "ErgoptiPlus-Runtime-Installer.app"
        for name in (
            "Contents",
            "Contents/MacOS",
            "Contents/Resources",
            "Contents/Resources/OwnedRuntime",
        ):
            (installer / name).mkdir(
                mode=0o755, parents=True, exist_ok=False if name == "Contents" else True
            )
        products = installer / "Contents/Resources/OwnedRuntime"
        for name, stamp in sorted(directories.items(), key=lambda row: (row[0].count("/"), row[0])):
            if name == "." or name == "Runtime":
                continue
            require(
                name.startswith("Runtime/") and stat.S_IMODE(stamp[3]) in (0o700, 0o755),
                "signed directory inventory escaped fixed Runtime products",
            )
            destination = products / name.removeprefix("Runtime/")
            destination.mkdir(mode=stat.S_IMODE(stamp[3]))
            current()
        for name, observation in sorted(files.items()):
            require(
                name.startswith("Runtime/"), "signed file inventory escaped fixed Runtime products"
            )
            destination = products / name.removeprefix("Runtime/")
            write_exclusive(
                destination, observation.data, stat.S_IMODE(observation.identity[3]), deadline
            )
            current()
        write_exclusive(
            installer / "Contents/MacOS/ErgoptiPlus-Runtime-Installer",
            compiled_bytes(work / "installer", compiled_snapshot[1]["installer"], deadline),
            0o755,
            deadline,
        )
        write_exclusive(
            installer / "Contents/Info.plist",
            plistlib.dumps(
                {
                    "CFBundleExecutable": "ErgoptiPlus-Runtime-Installer",
                    "CFBundleIdentifier": INSTALLER_ID,
                    "CFBundlePackageType": "APPL",
                    "CFBundleVersion": "1",
                    "CFBundleShortVersionString": "1.0",
                }
            ),
            0o644,
            deadline,
        )
        module = stage / "installed_physical_source.so"
        write_exclusive(
            module,
            compiled_bytes(work / "module.so", compiled_snapshot[1]["module.so"], deadline),
            0o755,
            deadline,
        )
        if sdk:
            _stage_virtual_hid_resources(
                installer / "Contents/Resources", driver_payload, deadline, payload_current
            )
        public_leaf = work / "approved_publisher.der"
        write_exclusive(public_leaf, leaf, 0o644, deadline)
        for name, identifier, target in (
            ("installer_sign", INSTALLER_ID, installer),
            ("module_sign", MODULE_ID, module),
        ):
            phase(
                name,
                [
                    "/usr/bin/codesign",
                    "--force",
                    "--sign",
                    signing_identity,
                    "--keychain",
                    str(keychain),
                    "--timestamp=none",
                    "--identifier",
                    identifier,
                    str(target),
                ],
            )
        before_validation = snapshot(stage, deadline)
        for name, option, target in (
            ("products_validate", "--products", products),
            ("installer_validate", "--installer", installer),
            ("module_validate", "--installed-source", module),
        ):
            phase(name, [str(work / "validator"), option, str(target), str(public_leaf)])
            require(
                (owner / ("production_" + name + ".stdout")).read_bytes() == b""
                and (owner / ("production_" + name + ".stderr")).read_bytes() == b"",
                "native product validator emitted an unrecognized stream",
            )
            require(
                snapshot(stage, deadline) == before_validation,
                "native validation changed product identities/content",
            )
        # Final app staging remains inside the original signed claim. No
        # detached path/report authorizes a later copy or validator execution.
        app = Path(repository) / "build/macos/ErgoptiPlus.app"
        helper_root = app / "Contents/Resources/OwnedRuntimeInstaller"
        module_root = app / "Contents/Resources/static/ergopti_plus/macos/adapters/native"
        for target in (app, helper_root.parent, module_root.parent):
            require(
                target.resolve(strict=True) == target and target.is_dir(),
                "fixed app staging parent is missing or linked",
            )
            for ancestor in (target, *target.parents):
                if ancestor == Path(repository):
                    break
                require(
                    ancestor.resolve(strict=True) == ancestor
                    and ancestor.is_dir()
                    and ancestor.stat().st_uid == os.getuid(),
                    "app staging ancestor custody changed",
                )
        require(
            not helper_root.exists() and not helper_root.is_symlink(),
            "owned installer destination already exists",
        )
        helper_root.mkdir(mode=0o755)
        if not module_root.exists():
            module_root.mkdir(mode=0o755)
        require(
            module_root.resolve(strict=True) == module_root
            and module_root.is_dir()
            and module_root.stat().st_uid == os.getuid(),
            "native module directory custody changed",
        )
        final_helper = helper_root / "ErgoptiPlus-Runtime-Installer.app"
        final_module = module_root / "installed_physical_source.so"
        require(
            not final_module.exists() and not final_module.is_symlink(),
            "native module destination already exists",
        )
        original_helper = snapshot(installer, deadline)
        final_helper.mkdir(mode=0o755)
        for relative, stamp in sorted(
            original_helper[0].items(), key=lambda row: (row[0].count("/"), row[0])
        ):
            if relative == ".":
                continue
            destination = final_helper / relative
            destination.mkdir(mode=stat.S_IMODE(stamp[2]))
        for relative, stamp in original_helper[1].items():
            current()
            require(
                snapshot(installer, deadline) == original_helper,
                "signed helper changed before final copy",
            )
            write_exclusive(
                final_helper / relative,
                compiled_bytes(installer / relative, stamp, deadline),
                stat.S_IMODE(stamp[0][2]),
                deadline,
            )
        current()
        write_exclusive(
            final_module,
            compiled_bytes(module, _snapshot_leaf(module, deadline), deadline),
            0o755,
            deadline,
        )
        main_payload_snapshot = None
        if sdk:
            main_payload_snapshot = _stage_virtual_hid_resources(
                app / "Contents/Resources", driver_payload, deadline, payload_current
            )
        final_helper_snapshot = snapshot(final_helper, deadline)
        final_module_snapshot = _snapshot_leaf(final_module, deadline)
        for name, option, target in (
            ("staged_installer_validate", "--installer", final_helper),
            ("staged_module_validate", "--installed-source", final_module),
        ):
            phase(name, [str(work / "validator"), option, str(target), str(public_leaf)])
            require(
                (owner / ("production_" + name + ".stdout")).read_bytes() == b""
                and (owner / ("production_" + name + ".stderr")).read_bytes() == b""
                and snapshot(final_helper, deadline) == final_helper_snapshot
                and _snapshot_leaf(final_module, deadline) == final_module_snapshot
                and snapshot(stage, deadline) == before_validation,
                "final staged native product validation or custody changed",
            )
        current()
        if main_payload_snapshot is not None:
            payload_current()
            require(
                snapshot(main_payload_snapshot[0], deadline) == main_payload_snapshot[1],
                "Main payload resources changed before outer signing handoff",
            )
        return {
            "root": str(stage),
            "source_receipts": receipts,
            "staged_helper": str(final_helper),
            "staged_module": str(final_module),
            "product_snapshot": before_validation,
            "status": "native_packaged_products_validated",
            "installation_qualified": False,
            "capture_qualified": False,
            "virtual_hid_qualified": False,
        }
    finally:
        if sdk:
            _retire_sdk_sources(held_sources, backend_source, sys.exc_info()[1])
        else:
            for source in held_sources:
                source.close()
            backend_source.close()
