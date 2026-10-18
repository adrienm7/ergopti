"""One test-only signed native HTTP callee recipe; never a release CLI role.

All processes use the existing fixture NativeProcessGroups protocol. Actual
unsettled-build retention needs native receiving; hashes are not settlement.
The builder never removes its root or introduces a second child owner.
"""

import hashlib
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[5]
MAC = "static/ergopti_plus/macos/"
SWIFT_INPUTS = tuple(
    MAC + "launcher/Sources/ErgoptiPlus/" + name
    for name in (
        "ManagedHTTPWorker.swift",
        "ManagedPACSource.swift",
        "ManagedCertificateAuthorities.swift",
        "ManagedBootstrapPolicy.generated.swift",
    )
) + (MAC + "tests/support/native_http_fixture_main.swift",)
HEADER_INPUTS = tuple(
    MAC + "launcher/Sources/CPOSIXCompatibility/include/" + name
    for name in (
        "CPOSIXCompatibility.h",
        "OwnedProgramCompatibility.h",
        "LoopbackListenerCompatibility.h",
        "OwnedImageAliasCompatibility.h",
        "OwnedSuspendedImageCompatibility.h",
        "OwnedListenerEventCompatibility.h",
        "OwnedRuntimeSignatureCompatibility.h",
        "OwnedInstalledConfiguration.h",
        "OwnedChildReapingCompatibility.h",
        "OwnedVHDReportSocketIdentity.h",
    )
)
RUNTIME_INPUTS = (
    MAC + "platform/network/native_http.py",
    MAC + "platform/network/managed_http.py",
    "static/ergopti_plus/_shared/python/network_proxy_policy.py",
    "static/ergopti_plus/_shared/modules/network/proxy_policy.json",
)
OWNER_INPUTS = (
    MAC + "tests/support/native_http_fixture_builder.py",
    MAC + "tests/support/native_http_wire_fixture.py",
    "tools/diagnostics/macos_owned_process.py",
)
SOURCE_INPUTS = SWIFT_INPUTS + HEADER_INPUTS + RUNTIME_INPUTS + OWNER_INPUTS
MODULE_MAP = (
    'module CPOSIXCompatibility {\n  umbrella header "CPOSIXCompatibility.h"\n  export *\n}\n'
).encode("utf-8")


class BuildRefused(RuntimeError):
    pass


def regular_bytes(path, *, maximum=8_388_608):
    """Read one regular, unaliased pathname without following its final link."""
    path = Path(path)
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise BuildRefused("Native fixture regular image/source refused")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        acquired = os.fstat(descriptor)
        if (
            not stat.S_ISREG(acquired.st_mode)
            or acquired.st_nlink != 1
            or (acquired.st_dev, acquired.st_ino) != (before.st_dev, before.st_ino)
        ):
            raise BuildRefused("Native fixture pathname changed during acquisition")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            content = stream.read(maximum + 1)
        after = path.lstat()
        final = os.fstat(descriptor)
        if (
            len(content) > maximum
            or not stat.S_ISREG(final.st_mode)
            or final.st_nlink != 1
            or not stat.S_ISREG(after.st_mode)
            or after.st_nlink != 1
            or (
                acquired.st_dev,
                acquired.st_ino,
                acquired.st_size,
                acquired.st_mtime_ns,
            )
            != (final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns)
            or (
                final.st_dev,
                final.st_ino,
            )
            != (after.st_dev, after.st_ino)
        ):
            raise BuildRefused("Native fixture image/source changed during read")
        return content, final
    finally:
        os.close(descriptor)


def _source(relative):
    path = ROOT / relative
    for parent in path.relative_to(ROOT).parents:
        if (ROOT / parent).is_symlink():
            raise BuildRefused("Native fixture source directory alias refused")
    return regular_bytes(path)[0]


def _digest(content):
    return hashlib.sha256(content).hexdigest()


def startup_deadline(arguments):
    """Fixed test role only; never accepts an executable or renews the budget.

    Activation requires a native receipt establishing that the Swift caller's
    systemUptime and Python monotonic share the Darwin clock/epoch.
    """
    if len(arguments) != 2 or arguments[0] != "--owned-native-callee-startup":
        raise BuildRefused("Native fixture startup role refused")
    try:
        deadline = float(arguments[1])
    except (TypeError, ValueError):
        raise BuildRefused("Native fixture startup deadline refused") from None
    now = time.monotonic()
    if not math.isfinite(deadline) or deadline <= now or deadline - now > 45:
        raise BuildRefused("Native fixture startup deadline refused")
    return deadline


class OwnedFixtureBuild:
    def __init__(self, fixture, *, parent=None, deadline=None):
        self.fixture = fixture
        self.deadline = deadline
        self.root = Path(tempfile.mkdtemp(prefix="ergopti-native-client-app-", dir=parent))
        os.chmod(self.root, 0o700)
        self.root_identity = self.root.lstat()
        self.app = self.root / "OwnedNativeHTTPFixture.app"
        self.resources = self.app / "Contents/Resources"
        self.executable = self.app / "Contents/MacOS/ErgoptiPlus"
        self.native = self.resources / "static/ergopti_plus/macos/platform/network"
        self.receipt_path = self.root / "source-receipt.json"
        self.receipt_digest = None
        self.identity = None
        self.image_digest = None
        self.source_hashes = {}
        self.staged_hashes = {}

    def _root_owned(self):
        current = self.root.lstat()
        if (
            not stat.S_ISDIR(current.st_mode)
            or (
                current.st_dev,
                current.st_ino,
            )
            != (self.root_identity.st_dev, self.root_identity.st_ino)
            or stat.S_IMODE(current.st_mode) != 0o700
        ):
            raise BuildRefused("Native fixture build root ownership refused")

    def _stage(self, original, relative):
        content = _source(original)
        target = self.root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
        self.source_hashes[original] = _digest(content)
        self.staged_hashes[str(relative)] = _digest(content)
        return target

    def _command(self, arguments, *, timeout=15):
        # The startup role uses the same absolute deadline at every admission.
        # The independent HTTP caller retains its existing 60s compiler cap.
        deadline = self.deadline
        if deadline is not None:
            now = time.monotonic()
            if now >= deadline:
                raise BuildRefused("Native fixture build startup deadline exhausted")
            deadline = min(deadline, now + timeout)
        observer = getattr(self, "passive_command_receiver", None)
        if observer is not None:
            if arguments[:2] == ["/usr/bin/xcrun", "swiftc"]:
                role = "compile"
            elif arguments[:-1] == ["/usr/bin/codesign", "--force", "--sign", "-"]:
                role = "sign"
            elif arguments[:-1] == ["/usr/bin/codesign", "--verify", "--strict"]:
                role = "strict_verify"
            else:
                raise BuildRefused("Native fixture passive command role refused")
            return self.fixture._command(
                arguments,
                timeout=timeout,
                deadline=deadline,
                passive_receiving=lambda fact: observer(role, fact),
            )
        return self.fixture._command(arguments, timeout=timeout, deadline=deadline)

    def _verify_sources(self):
        self._root_owned()
        for relative, digest in self.source_hashes.items():
            if _digest(_source(relative)) != digest:
                raise BuildRefused("Native fixture build source receipt diverged")
        for relative, digest in self.staged_hashes.items():
            path = self.root / relative
            for parent in path.relative_to(self.root).parents:
                if (self.root / parent).is_symlink():
                    raise BuildRefused("Native fixture staged directory alias refused")
            if _digest(regular_bytes(path)[0]) != digest:
                raise BuildRefused("Native fixture staged source receipt diverged")

    def build(self):
        if sys.platform != "darwin" or not self.fixture.native or self.fixture.groups is None:
            raise BuildRefused("Native fixture compilation requires its macOS child owner")
        self._root_owned()
        self.executable.parent.mkdir(parents=True)
        swift = [self._stage(path, Path(path).name) for path in SWIFT_INPUTS]
        compatibility = self.root / "CPOSIXCompatibility"
        # Keep the compiler's private include directory independent of the caller's umask.
        compatibility.mkdir(mode=0o700)
        compatibility.chmod(0o700)
        for path in HEADER_INPUTS:
            self._stage(path, Path("CPOSIXCompatibility") / Path(path).name)
        module = compatibility / "module.modulemap"
        module.write_bytes(MODULE_MAP)
        self.staged_hashes["CPOSIXCompatibility/module.modulemap"] = _digest(MODULE_MAP)
        for path in RUNTIME_INPUTS:
            self._stage(path, Path("OwnedNativeHTTPFixture.app/Contents/Resources") / path)
        for path in OWNER_INPUTS:
            self.source_hashes[path] = _digest(_source(path))
        self._verify_sources()
        self._command(
            [
                "/usr/bin/xcrun",
                "swiftc",
                "-parse-as-library",
                "-D",
                "ERGOPTI_MANAGED_HTTP_FIXTURE_DIAGNOSTICS",
                "-I",
                str(compatibility),
                "-framework",
                "SystemConfiguration",
                *map(str, swift),
                "-o",
                str(self.executable),
            ],
            timeout=60,
        )
        self._verify_sources()
        regular_bytes(self.executable)
        self._command(["/usr/bin/codesign", "--force", "--sign", "-", str(self.executable)])
        self._command(["/usr/bin/codesign", "--verify", "--strict", str(self.executable)])
        self._verify_sources()
        image, self.identity = regular_bytes(self.executable)
        if not self.identity.st_mode & 0o111:
            raise BuildRefused("Native fixture signed image is not executable")
        self.image_digest = _digest(image)
        receipt = {
            "version": 1,
            "source_hashes": self.source_hashes,
            "staged_hashes": self.staged_hashes,
            "binary_sha256": self.image_digest,
            "device": self.identity.st_dev,
            "inode": self.identity.st_ino,
        }
        encoded = json.dumps(receipt, sort_keys=True).encode("utf-8")
        self.receipt_path.write_bytes(encoded)
        self.receipt_digest = _digest(encoded)
        self.verify()
        if self.deadline is not None and time.monotonic() >= self.deadline:
            raise BuildRefused("Native fixture build startup deadline exhausted")
        return self

    def verify(self):
        if self.receipt_digest is None:
            raise BuildRefused("Native fixture build has no signed source receipt")
        self._verify_sources()
        if _digest(regular_bytes(self.receipt_path)[0]) != self.receipt_digest:
            raise BuildRefused("Native fixture signed source receipt changed")
        for parent in self.executable.relative_to(self.root).parents:
            if (self.root / parent).is_symlink():
                raise BuildRefused("Native fixture image directory alias refused")
        image, identity = regular_bytes(self.executable)
        if (
            (
                identity.st_dev,
                identity.st_ino,
            )
            != (self.identity.st_dev, self.identity.st_ino)
            or _digest(image) != self.image_digest
            or not identity.st_mode & 0o111
        ):
            raise BuildRefused("Native fixture signed image receipt changed")
        return self.executable

    @property
    def environment(self):
        self.verify()
        return {
            "ERGOPTI_LAUNCHER_EXECUTABLE": str(self.executable),
            "ERGOPTI_LAUNCHER_DEVICE": str(self.identity.st_dev),
            "ERGOPTI_LAUNCHER_INODE": str(self.identity.st_ino),
        }
