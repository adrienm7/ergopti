#!/usr/bin/env python3
# tools/diagnostics/hs274_native_credential_owner.py
"""TEST-ONLY fixed native credential owner. SOURCE-ONLY until qualification.

The original helper remains byte-whole. These primitives do not emit a ready
record without physical child retirement and closed writer custody. Private
state preserves the original FIRST admission limitation; it is not an IPC FD.
"""

from array import array
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import re
import secrets
import socket
import stat
import struct
import subprocess
import sys
import time


LEGACY_SHA256 = "f2a492cd326b0808922e4abe0d8e864f5069b6aff772b9399a95e56855fe9bf8"
CPP_SHA256 = "7284c5c58f247ed987661f52eeb1e20f4ab3ea2f893ab361cdb09bd142599669"
DATABASE_NAME = "fixture.keychain-db"
LOCK_NAME = ".fl" + hashlib.sha1(DATABASE_NAME.encode("ascii")).digest()[:4].hex().upper()


class OwnerRefusal(Exception):
    """Closed refusal only; private arguments/output must never enter errors."""


def require(value):
    if not value:
        raise OwnerRefusal("native_owner_refused")


def full(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        stat.S_IMODE(value.st_mode),
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
        value.st_nlink,
    )


def same_authored_vnode(before, after):
    """Own rename may change ctime; every other held-vnode axis stays exact."""
    return full(before)[:6] + full(before)[7:] == full(after)[:6] + full(after)[7:]


def ancestry(path):
    require(path.is_absolute() and path.resolve(strict=True) == path)
    result = []
    for parent in reversed((path,) + tuple(path.parents)):
        value = parent.lstat()
        require(stat.S_ISDIR(value.st_mode))
        result.append((parent, full(value)[:4]))
    return tuple(result)


def current_ancestry(values):
    for path, observed in values:
        value = path.lstat()
        require(stat.S_ISDIR(value.st_mode) and full(value)[:4] == observed)


@contextmanager
def fixed_legacy():
    """Execute only the held original bytes; no subsequent path module import."""
    path = Path(__file__).parent / "hs274_native_signing_fixture.py"
    parents = ancestry(path.parent)
    before = path.lstat()
    require(
        stat.S_ISREG(before.st_mode)
        and before.st_uid == os.geteuid()
        and before.st_nlink == 1
        and 0 < before.st_size <= 1024 * 1024
    )
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    name = "native_credential_original_signer_f2a492"
    module = None
    try:
        require(full(os.fstat(descriptor)) == full(before))
        data = bytearray()
        while len(data) <= 1024 * 1024:
            chunk = os.read(descriptor, min(65536, 1024 * 1024 + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        data = bytes(data)
        require(
            len(data) == before.st_size
            and hashlib.sha256(data).hexdigest() == LEGACY_SHA256
            and full(os.fstat(descriptor)) == full(before)
            and full(path.lstat()) == full(before)
        )
        current_ancestry(parents)
        require(name not in sys.modules)
        specification = importlib.util.spec_from_loader(name, loader=None)
        module = importlib.util.module_from_spec(specification)
        module.__file__ = str(path)
        sys.modules[name] = module
        exec(compile(data, str(path), "exec"), module.__dict__)
        original = module.Held(path, full(before), data, parents, True)

        def current_source():
            require(
                sys.modules.get(name) is module
                and full(os.fstat(descriptor)) == full(before)
                and full(path.lstat()) == full(before)
            )
            current_ancestry(parents)
            module.current(original)

        current_source()
        yield module, current_source
        current_source()
    finally:
        if module is not None and sys.modules.get(name) is module:
            del sys.modules[name]
        os.close(descriptor)


def fixed_environment(home, temporary):
    """Native provider carries no ambient account/purpose credential."""
    for path in (home, temporary):
        require(isinstance(path, Path))
        ancestry(path)
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(home),
        "TMPDIR": str(temporary),
        "LANG": "C",
        "LC_ALL": "C",
    }


def account_environment(temporary):
    """Keep the real account keychain scope without importing ambient secrets."""
    account = pwd.getpwuid(os.geteuid())
    require(account.pw_uid == os.geteuid())
    home = Path(account.pw_dir).resolve(strict=True)
    require(home.is_absolute() and home.lstat().st_uid == os.geteuid())
    return fixed_environment(home, temporary)


def native_frame(password, package, leaf):
    require(
        type(password) is str
        and len(password) == 43
        and set(password) <= set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        and type(package) is bytes
        and 0 < len(package) <= 65536
        and type(leaf) is bytes
        and 0 < len(leaf) <= 8192
    )
    return (
        b"ERP1"
        + struct.pack("!III", 43, len(package), len(leaf))
        + password.encode("ascii")
        + package
        + leaf
    )


def compile_native_provider(legacy, owner_root, deadline, environment, source_guard):
    """Compile the sole pinned provider; no image/path/provider CLI override.

    This is a separate closed compiler endpoint, not an extension of the
    original helper's security/openssl whitelist. Failure leaves private state
    and retirement debt for the owner; it grants no native fixture authority.
    """
    source = legacy.ordinary(Path(__file__).parent / "hs274_native_credential_transaction.cpp")
    require(hashlib.sha256(source.data).hexdigest() == CPP_SHA256)
    launcher = legacy.ordinary(Path("/usr/bin/xcrun"), owned=False)
    compiler = None
    sdk = None
    sdk_ancestors = None
    image_path = owner_root / "native-credential-provider"
    require(not os.path.lexists(image_path))

    def guard():
        source_guard()
        legacy.current(source)
        legacy.current(launcher)
        if compiler is not None:
            legacy.current(compiler)
        if sdk_ancestors is not None:
            current_ancestry(sdk_ancestors)
            value = sdk.lstat()
            require(stat.S_ISDIR(value.st_mode))

    def run(arguments):
        guard()
        result = subprocess.run(
            arguments,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=legacy.remaining(deadline),
            check=False,
        )
        # subprocess.run has waited for the exact child; TimeoutExpired remains
        # a refusal and is never interpreted as an admitted compiler product.
        guard()
        legacy.remaining(deadline)
        require(
            result.returncode == 0 and len(result.stdout) + len(result.stderr) <= 2 * 1024 * 1024
        )
        return result.stdout

    discovered = run(["/usr/bin/xcrun", "--find", "clang++"])
    require(len(discovered) <= 4096 and discovered.endswith(b"\n") and discovered.count(b"\n") == 1)
    selected = Path(discovered[:-1].decode("utf-8", "strict"))
    require(selected.is_absolute() and ".." not in selected.parts)
    compiler = legacy.ordinary(selected.resolve(strict=True), owned=False)
    discovered_sdk = run(["/usr/bin/xcrun", "--show-sdk-path"])
    require(
        len(discovered_sdk) <= 4096
        and discovered_sdk.endswith(b"\n")
        and discovered_sdk.count(b"\n") == 1
    )
    selected_sdk = Path(discovered_sdk[:-1].decode("utf-8", "strict"))
    require(selected_sdk.is_absolute() and ".." not in selected_sdk.parts)
    sdk = selected_sdk.resolve(strict=True)
    sdk_ancestors = ancestry(sdk)
    require(sdk.name.startswith("MacOSX") and sdk.name.endswith(".sdk"))
    guard()
    # Resolving clang++ may yield the physical clang image. Language and C++
    # runtime are therefore explicit rather than inferred from argv[0]. These
    # arguments do not change any existing Source16/build SDK invocation.
    run(
        [
            str(compiler.path),
            "-x",
            "c++",
            "-std=c++17",
            "-stdlib=libc++",
            "-O0",
            "-isysroot",
            str(sdk),
            str(source.path),
            "-framework",
            "Security",
            "-framework",
            "CoreFoundation",
            "-lc++",
            "-o",
            str(image_path),
        ]
    )
    produced = legacy.ordinary(image_path)
    require(produced.identity[3] in (0o700, 0o755))
    descriptor = os.open(image_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(full(os.fstat(descriptor)) == produced.identity)
        os.fchmod(descriptor, 0o700)
        changed = os.fstat(descriptor)
        require(
            full(changed)[:3] == produced.identity[:3]
            and changed.st_nlink == 1
            and changed.st_size == produced.identity[4]
            and changed.st_mtime_ns == produced.identity[5]
        )
        image = legacy.ordinary(image_path, 0o700)
        require(image.identity == full(changed) and image.data == produced.data)
    finally:
        os.close(descriptor)
    guard()
    legacy.current(image)
    return image


def capture_generated_file(legacy, root, name, mode, limit, guard):
    """Original FIRST producer output policy; normalize only the held inode."""
    require(name in {"private-key.pem", "certificate.pem", "identity.p12", "public-leaf.der"})
    guard()
    original = legacy.ordinary(root / name, limit=limit)
    require(original.identity[3] in (0o600, 0o644))
    descriptor = os.open(original.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(full(os.fstat(descriptor)) == original.identity)
        os.fchmod(descriptor, mode)
        changed = os.fstat(descriptor)
        require(
            full(changed)[:3] == original.identity[:3]
            and changed.st_nlink == 1
            and changed.st_size == original.identity[4]
            and changed.st_mtime_ns == original.identity[5]
        )
        result = legacy.ordinary(original.path, mode, limit)
        require(result.identity == full(changed) and result.data == original.data)
    finally:
        os.close(descriptor)
    guard()
    legacy.current(result)
    return result


def generate_crypto_inputs(legacy, root, environment, guard, credentials, deadline):
    """Original fixed TEST-ONLY subject/algorithms and encrypted input roles."""
    password = secrets.token_urlsafe(32)
    crypto_environment = dict(environment)
    crypto_environment["ERGOPTI_TEST_ONLY_KEY_PASSWORD"] = password
    config = (
        b"[req]\ndistinguished_name=subject\nprompt=no\nx509_extensions=code_signing\n"
        b"[subject]\nCN=ErgoptiPlus Disposable Runtime Signing TEST ONLY\n"
        b"[code_signing]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
        b"extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n"
    )
    guard()
    legacy._write(root / "openssl.cnf", config, 0o600)
    credentials["openssl.cnf"] = legacy.ordinary(root / "openssl.cnf", 0o600, 8192)
    require(credentials["openssl.cnf"].data == config)
    guard()
    try:
        legacy.command(
            [
                "/usr/bin/openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:3072",
                "-sha256",
                "-days",
                "1",
                "-config",
                str(root / "openssl.cnf"),
                "-keyout",
                str(root / "private-key.pem"),
                "-passout",
                "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
                "-out",
                str(root / "certificate.pem"),
            ],
            deadline,
            guard,
            crypto_environment,
        )
        for name in ("private-key.pem", "certificate.pem"):
            credentials[name] = capture_generated_file(legacy, root, name, 0o600, 131072, guard)
        version = legacy.command(["/usr/bin/openssl", "version"], deadline, guard, environment)[0]
        require(version.startswith((b"LibreSSL ", b"OpenSSL 3.")))
        arguments = [
            "/usr/bin/openssl",
            "pkcs12",
            "-export",
            "-in",
            str(root / "certificate.pem"),
            "-inkey",
            str(root / "private-key.pem"),
            "-passin",
            "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
            "-passout",
            "env:ERGOPTI_TEST_ONLY_KEY_PASSWORD",
            "-keypbe",
            "PBE-SHA1-3DES",
            "-certpbe",
            "PBE-SHA1-3DES",
            "-out",
            str(root / "identity.p12"),
        ]
        if version.startswith(b"OpenSSL 3."):
            arguments += ["-macalg", "sha1"]
        legacy.command(arguments, deadline, guard, crypto_environment)
        credentials["identity.p12"] = capture_generated_file(
            legacy, root, "identity.p12", 0o600, 65536, guard
        )
        legacy.command(
            [
                "/usr/bin/openssl",
                "x509",
                "-in",
                str(root / "certificate.pem"),
                "-outform",
                "DER",
                "-out",
                str(root / "public-leaf.der"),
            ],
            deadline,
            guard,
            environment,
        )
        credentials["public-leaf.der"] = capture_generated_file(
            legacy, root, "public-leaf.der", 0o644, 8192, guard
        )
        guard()
        return password, credentials["identity.p12"].data, credentials["public-leaf.der"].data
    finally:
        crypto_environment.pop("ERGOPTI_TEST_ONLY_KEY_PASSWORD", None)
        # Python strings are not claimed to be securely erased. Secrets remain
        # process-memory-only; no state/receipt/transcript includes their values.


class NativeReply:
    """Retain the actual received vnode; scalar state cannot replace this FD.

    Internal only: the eventual fixed owner constructs every guard/route and
    launches the one pinned native image. No provider/profile CLI is admitted.
    """

    def __init__(self, root, channel, guard, deadline, remaining):
        self.root = root
        self.channel = channel
        self.guard = guard
        self.deadline = deadline
        self.remaining = remaining
        self.descriptor = None
        self.observed = None
        self.data = None
        self.close_debt = False
        self.root_ancestors = ancestry(root)
        root_value = root.lstat()
        require(
            stat.S_ISDIR(root_value.st_mode)
            and root_value.st_uid == os.geteuid()
            and stat.S_IMODE(root_value.st_mode) == 0o700
        )
        self.root_descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.root_close_identity = full(os.fstat(self.root_descriptor))[:4]
        self.descriptor_close_identity = None
        try:
            require(full(os.fstat(self.root_descriptor))[:4] == full(root_value)[:4])
            self.route()
        except BaseException:
            self.close()
            raise

    def route(self):
        self.guard()
        current_ancestry(self.root_ancestors)
        require(
            full(os.fstat(self.root_descriptor))[:4] == self.root_ancestors[-1][1]
            and stat.S_ISDIR(os.fstat(self.root_descriptor).st_mode)
        )

    def receive(self):
        """Require exactly one FD and a complete F+nonce across stream fragments."""
        self.route()
        challenge = bytearray()
        try:
            while len(challenge) < 33:
                self.channel.settimeout(self.remaining(self.deadline))
                self.route()
                data, ancillary, flags, _ = self.channel.recvmsg(
                    33 - len(challenge), socket.CMSG_SPACE(8 * array("i").itemsize)
                )
                delivered = []
                valid = bool(data) and flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC) == 0
                for level, kind, payload in ancillary:
                    if level != socket.SOL_SOCKET or kind != socket.SCM_RIGHTS:
                        valid = False
                        continue
                    received = array("i")
                    if len(payload) % received.itemsize:
                        valid = False
                        continue
                    received.frombytes(payload)
                    delivered.extend(received)
                # Account for every kernel-delivered descriptor before refusal.
                # No arbitrary ancillary record supplies custody authority.
                if not valid or len(delivered) > 1 or (delivered and self.descriptor is not None):
                    for descriptor in delivered:
                        os.close(descriptor)
                    require(False)
                if delivered:
                    self.descriptor = delivered[0]
                    self.descriptor_close_identity = full(os.fstat(self.descriptor))[:4]
                challenge.extend(data)
                self.route()
            require(
                len(challenge) == 33 and challenge[0] == ord("F") and self.descriptor is not None
            )
            value = os.fstat(self.descriptor)
            require(
                stat.S_ISREG(value.st_mode)
                and value.st_uid == os.geteuid()
                and stat.S_IMODE(value.st_mode) == 0o600
                and value.st_nlink == 1
                and 0 < value.st_size <= 4 * 1024 * 1024
                and fcntl.fcntl(self.descriptor, fcntl.F_GETFL) & os.O_ACCMODE == os.O_RDONLY
            )
            os.set_inheritable(self.descriptor, False)
            named = os.stat(
                "fixture.keychain-db", dir_fd=self.root_descriptor, follow_symlinks=False
            )
            require(stat.S_ISREG(named.st_mode) and full(named) == full(value))
            self.observed = full(value)
            data = bytearray()
            while len(data) < value.st_size:
                chunk = os.pread(self.descriptor, min(65536, value.st_size - len(data)), len(data))
                require(chunk)
                data.extend(chunk)
            self.data = bytes(data)
            self.current()
            # The fresh challenge is acknowledged only after actual FD custody,
            # complete bounded content and named/held route admission.
            self.channel.settimeout(self.remaining(self.deadline))
            self.channel.sendall(b"A" + bytes(challenge[1:]))
            self.current()
        except BaseException:
            # Child retirement/debt are the owner's obligation, not a path delete.
            self.close()
            raise

    def current(self):
        self.route()
        require(self.descriptor is not None and full(os.fstat(self.descriptor)) == self.observed)
        value = os.stat("fixture.keychain-db", dir_fd=self.root_descriptor, follow_symlinks=False)
        require(stat.S_ISREG(value.st_mode) and full(value) == self.observed)
        require(os.pread(self.descriptor, len(self.data) + 1, 0) == self.data)
        require(full(os.fstat(self.descriptor)) == self.observed)
        require(
            full(os.stat("fixture.keychain-db", dir_fd=self.root_descriptor, follow_symlinks=False))
            == self.observed
        )

    def close(self):
        for attribute, identity in (
            ("descriptor", self.descriptor_close_identity),
            ("root_descriptor", self.root_close_identity),
        ):
            descriptor = getattr(self, attribute)
            if descriptor is None:
                continue
            try:
                # A reused number naming a foreign vnode is never ours to close.
                require(identity is not None and full(os.fstat(descriptor))[:4] == identity)
            except (OwnerRefusal, OSError):
                self.close_debt = True
                continue
            # One close attempt. An ambiguous error retains debt; retrying a
            # descriptor number could close a later unrelated allocation.
            setattr(self, attribute, None)
            try:
                os.close(descriptor)
            except OSError:
                self.close_debt = True


class NativeProcess:
    """Fixed internal producer lifetime; no callable provider/profile argument.

    The owner must supply its already admitted compiler output and closed guard.
    This class alone never returns fixture readiness or cleanup authority.
    """

    def __init__(self, legacy, image, root, environment, guard, deadline):
        self.legacy = legacy
        self.image = image
        self.root = root
        self.environment = environment
        self.guard = guard
        self.deadline = deadline
        self.process = None
        self.channel = None
        self.reply = None
        self.retired = False
        self.failed = False
        self.debt = True

    def current_inputs(self):
        self.guard()
        self.legacy.current(self.image)
        require(self.image.identity[3] == 0o700 and self.image.owned)

    def run(self, password, package, leaf):
        require(self.process is None and self.channel is None and not self.retired)
        self.current_inputs()
        require(set(os.listdir(self.root)) == set())
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        self.channel = parent
        try:
            self.current_inputs()
            self.legacy.remaining(self.deadline)
            # Remain in the original SDK Guardian process group. No preexec,
            # daemon, session change, ambient token or caller-chosen image.
            self.process = subprocess.Popen(
                [str(self.image.path), str(self.root)],
                stdin=child,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=self.environment,
                close_fds=True,
            )
        except BaseException:
            self.failed = True
            self.abort()
            self.close()
            raise
        finally:
            child.close()
        try:
            self.current_inputs()
            parent.settimeout(self.legacy.remaining(self.deadline))
            parent.sendall(native_frame(password, package, leaf))
            self.reply = NativeReply(
                self.root, parent, self.current_inputs, self.deadline, self.legacy.remaining
            )
            self.reply.receive()
            self.current_inputs()
            out, error = self.process.communicate(timeout=self.legacy.remaining(self.deadline))
            # communicate() has waited for THIS physical child. A scalar ready
            # record, nonce ACK or SecKeychainRef release cannot replace it.
            self.retired = self.process.returncode is not None
            require(self.retired and self.process.returncode == 0 and out == b"" and error == b"")
            self.reply.current()
            parent.settimeout(self.legacy.remaining(self.deadline))
            data, ancillary, flags, _ = parent.recvmsg(
                1, socket.CMSG_SPACE(8 * array("i").itemsize)
            )
            # Unexpected final ancillary descriptors must be accounted for even
            # though they never acquire credential ownership.
            self.discard_ancillary(ancillary)
            require(data == b"" and ancillary == [] and flags == 0)
            self.reply.current()
            self.legacy.remaining(self.deadline)
            self.debt = False
            return self.reply
        except BaseException:
            self.failed = True
            self.abort()
            raise

    @staticmethod
    def discard_ancillary(ancillary):
        for level, kind, payload in ancillary:
            if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                values = array("i")
                values.frombytes(payload[: len(payload) - len(payload) % values.itemsize])
                for descriptor in values:
                    os.close(descriptor)

    def abort(self):
        # A failed native mutation has unresolved credential/transaction debt
        # even when its process is subsequently known to have exited.
        self.debt = True
        if self.process is None:
            return
        try:
            if self.process.poll() is None:
                self.process.kill()
                self.process.communicate(timeout=self.legacy.remaining(self.deadline))
            self.retired = self.process.poll() is not None
        except (OSError, subprocess.TimeoutExpired, self.legacy.FixtureRefusal):
            self.retired = False

    def close(self):
        if self.process is not None and not self.retired:
            self.abort()
        if self.reply is not None:
            self.reply.close()
            self.debt = self.debt or self.reply.close_debt
        if self.channel is not None:
            try:
                self.channel.close()
                self.channel = None
            except OSError:
                self.debt = True


class FirstNativeInventory:
    """FIRST output lock admission, then no mutable-phase inode recapture.

    The final database is bound to the native received FD. The lock's first
    named/held capture has the same attribution limitation as original Create;
    it is not a universal proof against concurrent replacement before capture.
    """

    def __init__(self, root, reply, guard):
        self.root = root
        self.reply = reply
        self.guard = guard
        self.lock_descriptor = None
        self.close_debt = False
        self.guard()
        self.reply.current()
        require(set(os.listdir(root)) == {DATABASE_NAME, LOCK_NAME})
        before = os.stat(LOCK_NAME, dir_fd=reply.root_descriptor, follow_symlinks=False)
        require(
            stat.S_ISREG(before.st_mode)
            and before.st_uid == os.geteuid()
            and before.st_nlink == 1
            and stat.S_IMODE(before.st_mode) == 0o600
            and before.st_size == 0
        )
        self.observed = full(before)
        self.lock_descriptor = os.open(
            LOCK_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=reply.root_descriptor
        )
        try:
            require(full(os.fstat(self.lock_descriptor)) == self.observed)
            self.current()
        except BaseException:
            self.close()
            raise

    def current(self):
        self.guard()
        self.reply.current()
        require(set(os.listdir(self.root)) == {DATABASE_NAME, LOCK_NAME})
        require(full(os.fstat(self.lock_descriptor)) == self.observed)
        named = os.stat(LOCK_NAME, dir_fd=self.reply.root_descriptor, follow_symlinks=False)
        require(stat.S_ISREG(named.st_mode) and full(named) == self.observed)
        require(os.pread(self.lock_descriptor, 1, 0) == b"")
        require(full(os.fstat(self.lock_descriptor)) == self.observed)

    def close(self):
        if self.lock_descriptor is None:
            return
        try:
            require(full(os.fstat(self.lock_descriptor))[:4] == self.observed[:4])
        except (OSError, OwnerRefusal):
            self.close_debt = True
            return
        descriptor, self.lock_descriptor = self.lock_descriptor, None
        try:
            os.close(descriptor)
        except OSError:
            self.close_debt = True


def delete_native_inventory(legacy, inventory, before_search, deadline, environment):
    """Delete only the exact held database through the fixed native endpoint.

    Caller must have physically reaped the native producer and all runtime
    consumers before this function. This never clears their outstanding debt.
    Any refusal leaves the remaining private route for explicit recovery.
    """
    require(type(before_search) is tuple)
    keychain = inventory.root / DATABASE_NAME
    inventory.current()
    pre = legacy.list_keychains(
        legacy.command(
            ["/usr/bin/security", "list-keychains", "-d", "user"],
            deadline,
            inventory.current,
            environment,
        )[0]
    )
    require(legacy.search_unchanged(before_search, pre, str(keychain)))
    deleted = False

    def delete_guard():
        nonlocal deleted
        if not deleted:
            # Exact held DB and lock, bytes, metadata and all ancestry remain
            # current immediately before the single native mutating endpoint.
            inventory.current()
            deleted = True
            return
        inventory.guard()
        inventory.reply.route()
        require(set(os.listdir(inventory.root)) == set())
        for descriptor, observed, data in (
            (inventory.reply.descriptor, inventory.reply.observed, inventory.reply.data),
            (inventory.lock_descriptor, inventory.observed, b""),
        ):
            value = os.fstat(descriptor)
            require(
                stat.S_ISREG(value.st_mode)
                and full(value)[:4] == observed[:4]
                and value.st_nlink == 0
                and value.st_size == len(data)
                and value.st_mtime_ns == observed[5]
            )
            # unlink legitimately changes ctime/nlink. It never authorizes
            # altered data, another inode, owner, mode or a replacement leaf.
            require(os.pread(descriptor, len(data) + 1, 0) == data)
            require(full(os.fstat(descriptor)) == full(value))

    legacy.command(
        ["/usr/bin/security", "delete-keychain", str(keychain)],
        deadline,
        delete_guard,
        environment,
    )
    delete_guard()
    post = legacy.list_keychains(
        legacy.command(
            ["/usr/bin/security", "list-keychains", "-d", "user"],
            deadline,
            delete_guard,
            environment,
        )[0]
    )
    require(legacy.foreign_list(pre, str(keychain)) == post and before_search == post)
    # Native performDelete owns both deletions. The wrapper never unlinks a
    # missing/replaced/foreign lock or tries a second speculative delete.
    inventory.close()
    inventory.reply.close()
    require(not inventory.close_debt and not inventory.reply.close_debt)
    inventory.guard()
    require(set(os.listdir(inventory.root)) == set())


class PrivateJournal:
    """Held local state writer, separate from native mutable output admission.

    A live descriptor pins each new local state vnode through atomic publish.
    Existing state may be replaced only after its exact prior currentness guard.
    No credential secret or native ready scalar becomes ownership authority.
    """

    PHASES = ("created", "compiled", "credentials", "native_started", "native_retired", "ready")

    def __init__(self, legacy, root, source_guard):
        self.legacy = legacy
        self.root = root
        self.source_guard = source_guard
        self.ancestors = ancestry(root)
        self.descriptor = None
        self.held = None
        self.close_debt = False
        self.failed = False
        self.retirement_debt = []
        self.phase = None
        self.path = root / ".state.json"
        require(not os.path.lexists(self.path) and not os.path.lexists(root / ".state.next"))
        self.route()

    def route(self):
        self.source_guard()
        current_ancestry(self.ancestors)
        value = self.root.lstat()
        require(
            stat.S_ISDIR(value.st_mode)
            and value.st_uid == os.geteuid()
            and stat.S_IMODE(value.st_mode) == 0o700
        )

    def current(self):
        self.route()
        if self.held is None:
            require(self.descriptor is None and not os.path.lexists(self.path))
            return
        require(
            self.descriptor is not None and full(os.fstat(self.descriptor)) == self.held.identity
        )
        self.legacy.current(self.held)

    def publish(self, record):
        require(not self.failed and not self.close_debt)
        require(
            type(record) is dict and record.get("schema") == 2 and type(record.get("schema")) is int
        )
        require(record.get("phase") in self.PHASES[:-1])
        expected = 0 if self.phase is None else self.PHASES.index(self.phase) + 1
        require(self.PHASES.index(record["phase"]) == expected)
        # Caller constructs the fixed closed record; serialization cannot copy
        # arbitrary exceptions, passwords, process output or environment values.
        require(
            set(record)
            == {"schema", "phase", "root", "directories", "before", "files", "native", "custody"}
        )
        data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        require(0 < len(data) <= 65536)
        self.current()
        temporary = self.root / ".state.next"
        require(not os.path.lexists(temporary))
        descriptor = None
        initial = None
        try:
            descriptor = os.open(
                temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
            )
            value = os.fstat(descriptor)
            initial = full(value)[:4]
            require(
                stat.S_ISREG(value.st_mode)
                and value.st_uid == os.geteuid()
                and stat.S_IMODE(value.st_mode) == 0o600
                and value.st_nlink == 1
                and value.st_size == 0
            )
            offset = 0
            while offset < len(data):
                written = os.write(descriptor, data[offset:])
                require(written > 0)
                offset += written
            final = os.fstat(descriptor)
            require(
                full(final)[:4] == initial and final.st_nlink == 1 and final.st_size == len(data)
            )
            require(full(temporary.lstat()) == full(final))
            self.current()
            os.replace(temporary, self.path)
            # The held writer, rather than a later named capture, attributes
            # this locally authored replacement to this exact publish operation.
            renamed = os.fstat(descriptor)
            require(
                same_authored_vnode(final, renamed) and full(self.path.lstat()) == full(renamed)
            )
            held = self.legacy.ordinary(self.path, 0o600, 65536)
            require(held.identity == full(renamed) and held.data == data)
            old_descriptor, old_held = self.descriptor, self.held
            self.descriptor, self.held = descriptor, held
            descriptor = None
            self.phase = record["phase"]
            if old_descriptor is not None:
                debt = (old_descriptor, old_held.identity[:4])
                self.retirement_debt.append(debt)
                value = os.fstat(old_descriptor)
                require(full(value)[:4] == old_held.identity[:4] and value.st_nlink == 0)
                try:
                    os.close(old_descriptor)
                except OSError:
                    self.close_debt = True
                else:
                    self.retirement_debt.remove(debt)
            require(not self.close_debt)
            self.current()
        except BaseException:
            self.failed = True
            if descriptor is not None:
                try:
                    require(initial is not None and full(os.fstat(descriptor))[:4] == initial)
                except (OSError, OwnerRefusal):
                    self.close_debt = True
                else:
                    try:
                        os.close(descriptor)
                    except OSError:
                        self.close_debt = True
            # No speculative unlink of temporary/state. A failed publication
            # retains private debt and the exact last successful journal phase.
            raise

    def close(self):
        if self.descriptor is None:
            return
        try:
            require(
                self.held is not None
                and full(os.fstat(self.descriptor))[:4] == self.held.identity[:4]
            )
        except (OSError, OwnerRefusal):
            self.close_debt = True
            return
        descriptor, self.descriptor = self.descriptor, None
        try:
            os.close(descriptor)
        except OSError:
            self.close_debt = True

    def finish_ready(self, record, public_data, guard, deadline):
        """Last setup operation: writer retirement precedes Ready publication.

        Refusal before rename leaves native_retired plus .state.next. The
        read-only descriptor survives until physical SDKGuardian retirement;
        it confers no writable custody. After rename, no callback/finally runs.
        """
        require(
            self.phase == "native_retired"
            and not self.failed
            and not self.close_debt
            and not self.retirement_debt
        )
        require(
            type(record) is dict
            and set(record)
            == {"schema", "phase", "root", "directories", "before", "files", "native", "custody"}
        )
        require(
            type(record["schema"]) is int and record["schema"] == 2 and record["phase"] == "ready"
        )
        require(
            type(public_data) is bytes
            and 0 < len(public_data) <= 512
            and public_data.endswith(b"\n")
        )
        data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        require(0 < len(data) <= 65536)
        self.current()
        guard()
        self.legacy.remaining(deadline)
        temporary = self.root / ".state.next"
        require(not os.path.lexists(temporary))
        writer = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        first = os.fstat(writer)
        require(
            stat.S_ISREG(first.st_mode)
            and first.st_uid == os.geteuid()
            and stat.S_IMODE(first.st_mode) == 0o600
            and first.st_nlink == 1
            and first.st_size == 0
        )
        offset = 0
        while offset < len(data):
            written = os.write(writer, data[offset:])
            require(written > 0)
            offset += written
        final = os.fstat(writer)
        require(
            full(final)[:4] == full(first)[:4]
            and final.st_nlink == 1
            and final.st_size == len(data)
        )
        reader = os.open(temporary, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        require(full(os.fstat(reader)) == full(final) and full(temporary.lstat()) == full(final))
        require(os.pread(reader, len(data) + 1, 0) == data)
        self.current()
        guard()
        self.legacy.remaining(deadline)
        # Retain no numeric writer for a speculative retry after close failure.
        # A remaining .state.next blocks the strict reader even if .debt cannot
        # be created. The SDKGuardian owns physical retirement on refusal.
        os.close(writer)
        self.close()
        require(not self.close_debt and not self.retirement_debt)
        self.route()
        guard()
        require(full(os.fstat(reader)) == full(final) and full(temporary.lstat()) == full(final))
        require(os.pread(reader, len(data) + 1, 0) == data)
        require(full(self.path.lstat()) == self.held.identity)
        self.legacy.remaining(deadline)
        os.replace(temporary, self.path)
        # No callbacks, object cleanup, context-manager exits or descriptor
        # close attempts are allowed past this boundary. Exceptions terminate
        # physically rather than unwinding into setup's refusal cleanup.
        try:
            renamed = os.fstat(reader)
            if not same_authored_vnode(final, renamed) or full(self.path.lstat()) != full(renamed):
                os._exit(1)
            if os.pread(reader, len(data) + 1, 0) != data:
                os._exit(1)
            if os.write(1, public_data) != len(public_data):
                os._exit(1)
        except BaseException:
            os._exit(1)
        os._exit(0)


def closed_ready_record(legacy, root):
    """Read only the original-policy private state, never a new IPC receipt.

    This separate cleanup-process boundary cannot resurrect setup's received
    descriptor. It preserves the original helper's closed owned-state trust
    model and requires exact earlier identities before any mutating endpoint.
    """
    state = legacy.ordinary(root / ".state.json", 0o600, 65536)

    def unique(pairs):
        result = {}
        for key, value in pairs:
            require(type(key) is str and key not in result)
            result[key] = value
        return result

    record = json.loads(state.data, object_pairs_hook=unique)
    require(
        type(record) is dict
        and set(record)
        == {"schema", "phase", "root", "directories", "before", "files", "native", "custody"}
    )
    require(type(record["schema"]) is int and record["schema"] == 2 and record["phase"] == "ready")

    def identity(values, count):
        require(type(values) is list and len(values) == count)
        require(all(type(value) is int and 0 <= value < 2**64 for value in values))
        return tuple(values)

    def file_entry(entry, mode, maximum):
        require(type(entry) is dict and set(entry) == {"identity", "sha256"})
        observed = identity(entry["identity"], 8)
        require(
            observed[2] == os.geteuid()
            and observed[3] == mode
            and 0 <= observed[4] <= maximum
            and observed[7] == 1
        )
        require(
            type(entry["sha256"]) is str
            and re.fullmatch("[a-f0-9]{64}", entry["sha256"]) is not None
        )
        return observed

    require(identity(record["root"], 4) == full(root.lstat())[:4])
    require(root.lstat().st_uid == os.geteuid() and stat.S_IMODE(root.lstat().st_mode) == 0o700)
    directories = record["directories"]
    require(type(directories) is dict and set(directories) == {"native-db", "tmp"})
    for name, values in directories.items():
        path = root / name
        info = path.lstat()
        require(stat.S_ISDIR(info.st_mode) and identity(values, 4) == full(info)[:4])
        require(info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o700)
        ancestry(path)
    custody = record["custody"]
    require(
        type(custody) is dict
        and set(custody) == {"sources", "tools", "root_ancestors", "home_ancestors"}
    )
    require(
        type(custody["sources"]) is dict
        and set(custody["sources"])
        == {"hs274_native_credential_owner.py", "hs274_native_credential_transaction.cpp"}
    )
    require(
        type(custody["tools"]) is dict
        and set(custody["tools"]) == {"/usr/bin/security", "/usr/bin/openssl", "/usr/bin/codesign"}
    )
    for entries, source_files in ((custody["sources"], True), (custody["tools"], False)):
        for name, saved in entries.items():
            require(type(saved) is dict and set(saved) == {"identity", "sha256"})
            observed = identity(saved["identity"], 8)
            require(
                type(saved["sha256"]) is str
                and re.fullmatch("[a-f0-9]{64}", saved["sha256"]) is not None
            )
            path = Path(__file__).parent / name if source_files else Path(name)
            item = legacy.ordinary(path, owned=source_files)
            require(
                item.identity == observed
                and hashlib.sha256(item.data).hexdigest() == saved["sha256"]
            )
    for name, current in (
        ("root_ancestors", ancestry(root)),
        ("home_ancestors", ancestry(Path(pwd.getpwuid(os.geteuid()).pw_dir).resolve(strict=True))),
    ):
        saved = custody[name]
        require(type(saved) is list and len(saved) == len(current))
        for entry, (path, observed) in zip(saved, current):
            require(type(entry) is list and len(entry) == 2 and type(entry[0]) is str)
            require(entry[0] == str(path) and identity(entry[1], 4) == observed)
    require(set(os.listdir(root / "tmp")) == set())
    before = record["before"]
    require(type(before) is list and len(before) <= 256)
    require(
        all(
            type(value) is str and Path(value).is_absolute() and ".." not in Path(value).parts
            for value in before
        )
    )
    require(len(set(before)) == len(before))
    require(
        type(record["files"]) is dict
        and set(record["files"]) == {"native-credential-provider", "public-leaf.der"}
    )
    for name, mode, maximum in (
        ("native-credential-provider", 0o700, 16 * 1024 * 1024),
        ("public-leaf.der", 0o644, 8192),
    ):
        values = file_entry(record["files"][name], mode, maximum)
        require(values[4] > 0)
        item = legacy.ordinary(root / name, mode, maximum)
        require(
            item.identity == values
            and hashlib.sha256(item.data).hexdigest() == record["files"][name]["sha256"]
        )
    native = record["native"]
    require(type(native) is dict and set(native) == {"database", "lock"})
    database = file_entry(native["database"], 0o600, 4 * 1024 * 1024)
    require(database[4] > 0)
    lock = file_entry(native["lock"], 0o600, 0)
    require(lock[4] == 0 and native["lock"]["sha256"] == hashlib.sha256(b"").hexdigest())
    # Validate strict saved metadata before opening any current cleanup handle.
    for name, values in ((DATABASE_NAME, database), (LOCK_NAME, lock)):
        value = (root / "native-db" / name).lstat()
        require(stat.S_ISREG(value.st_mode) and full(value) == values)
    require(set(os.listdir(root / "native-db")) == {DATABASE_NAME, LOCK_NAME})
    require(
        set(os.listdir(root))
        == {".state.json", "native-db", "tmp", "native-credential-provider", "public-leaf.der"}
    )
    legacy.current(state)
    return state, record


def record_setup_debt(root, ancestors):
    """Constant failure marker; never change native DB/lock admission metadata."""
    current_ancestry(ancestors)
    before = root.lstat()
    require(stat.S_ISDIR(before.st_mode) and full(before)[:4] == ancestors[-1][1])
    directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    marker = None
    marker_identity = None
    try:
        require(full(os.fstat(directory))[:4] == ancestors[-1][1])
        current_ancestry(ancestors)
        # Presence is itself failure, even if storage exhaustion interrupts the
        # bounded constant write. No existing marker is overwritten or removed.
        marker = os.open(
            ".debt", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory
        )
        value = os.fstat(marker)
        marker_identity = full(value)[:4]
        require(
            stat.S_ISREG(value.st_mode)
            and value.st_uid == os.geteuid()
            and stat.S_IMODE(value.st_mode) == 0o600
            and value.st_nlink == 1
        )
        require(os.write(marker, b"unsettled\n") == len(b"unsettled\n"))
        final = os.fstat(marker)
        require(
            full(final)[:4] == marker_identity
            and final.st_nlink == 1
            and final.st_size == len(b"unsettled\n")
        )
        require(full(os.stat(".debt", dir_fd=directory, follow_symlinks=False)) == full(final))
        current_ancestry(ancestors)
    finally:
        if marker is not None:
            require(marker_identity is not None and full(os.fstat(marker))[:4] == marker_identity)
            os.close(marker)
        require(full(os.fstat(directory))[:4] == ancestors[-1][1])
        os.close(directory)


def setup(root, public):
    """Fixed TEST-ONLY producer; no ready result on unconfirmed native effects."""
    require(sys.platform == "darwin" and root.is_absolute() and public.is_absolute())
    public_ancestors = ancestry(public)
    require(
        public not in root.parents
        and public.parent not in root.parents
        and root not in public.parents
        and root != public
        and root != public.parent
    )
    deadline = time.monotonic() + 30
    with fixed_legacy() as (legacy, legacy_current):
        legacy.create_private(root)
        root_ancestors = ancestry(root)
        for name in ("native-db", "tmp"):
            legacy.create_private(root / name)
        directory_ancestors = tuple(ancestry(root / name) for name in ("native-db", "tmp"))
        environment = account_environment(root / "tmp")
        home_ancestors = ancestry(Path(environment["HOME"]))
        source = legacy.ordinary(Path(__file__))
        native_source = legacy.ordinary(
            Path(__file__).parent / "hs274_native_credential_transaction.cpp"
        )
        require(hashlib.sha256(native_source.data).hexdigest() == CPP_SHA256)
        tools = tuple(
            legacy.ordinary(Path(path), owned=False)
            for path in ("/usr/bin/security", "/usr/bin/openssl", "/usr/bin/codesign")
        )
        credentials = {}
        journal = None
        native = None
        inventory = None

        def source_guard():
            legacy_current()
            current_ancestry(root_ancestors)
            current_ancestry(public_ancestors)
            current_ancestry(home_ancestors)
            for parents in directory_ancestors:
                current_ancestry(parents)
            for item in (source, native_source, *tools, *credentials.values()):
                legacy.current(item)

        def guard():
            source_guard()
            if journal is not None:
                journal.current()

        before = legacy.list_keychains(
            legacy.command(
                ["/usr/bin/security", "list-keychains", "-d", "user"], deadline, guard, environment
            )[0]
        )
        journal = PrivateJournal(legacy, root, source_guard)
        record = {
            "schema": 2,
            "phase": "created",
            "root": list(full(root.lstat())[:4]),
            "directories": {
                name: list(full((root / name).lstat())[:4]) for name in ("native-db", "tmp")
            },
            "before": list(before),
            "files": {},
            "native": None,
            "custody": {
                "sources": {
                    item.path.name: {
                        "identity": list(item.identity),
                        "sha256": hashlib.sha256(item.data).hexdigest(),
                    }
                    for item in (source, native_source)
                },
                "tools": {
                    str(item.path): {
                        "identity": list(item.identity),
                        "sha256": hashlib.sha256(item.data).hexdigest(),
                    }
                    for item in tools
                },
                "root_ancestors": [
                    [str(path), list(observed)] for path, observed in root_ancestors
                ],
                "home_ancestors": [
                    [str(path), list(observed)] for path, observed in home_ancestors
                ],
            },
        }

        def entry(item):
            return {
                "identity": list(item.identity),
                "sha256": hashlib.sha256(item.data).hexdigest(),
            }

        try:
            journal.publish(record)
            credentials["native-credential-provider"] = compile_native_provider(
                legacy, root, deadline, environment, guard
            )
            record["phase"] = "compiled"
            record["files"] = {name: entry(item) for name, item in credentials.items()}
            journal.publish(record)
            password, package, leaf = generate_crypto_inputs(
                legacy, root, environment, guard, credentials, deadline
            )
            record["phase"] = "credentials"
            record["files"] = {name: entry(item) for name, item in credentials.items()}
            journal.publish(record)
            native = NativeProcess(
                legacy,
                credentials["native-credential-provider"],
                root / "native-db",
                environment,
                guard,
                deadline,
            )
            record["phase"] = "native_started"
            journal.publish(record)
            reply = native.run(password, package, leaf)
            require(native.retired and not native.debt)
            inventory = FirstNativeInventory(root / "native-db", reply, guard)
            record["native"] = {
                "database": {
                    "identity": list(reply.observed),
                    "sha256": hashlib.sha256(reply.data).hexdigest(),
                },
                "lock": {
                    "identity": list(inventory.observed),
                    "sha256": hashlib.sha256(b"").hexdigest(),
                },
            }
            record["phase"] = "native_retired"
            journal.publish(record)
            password, package = None, None
            identity = hashlib.sha1(leaf).hexdigest().upper()
            keychain = root / "native-db" / DATABASE_NAME
            out = legacy.command(
                ["/usr/bin/security", "find-identity", "-p", "codesigning", str(keychain)],
                deadline,
                inventory.current,
                environment,
            )[0]
            identities = re.findall(rb"^\s*[0-9]+\) ([A-Fa-f0-9]{40}) ", out, re.M)
            require(len(identities) == 1 and identities[0].decode().upper() == identity)
            after = legacy.list_keychains(
                legacy.command(
                    ["/usr/bin/security", "list-keychains", "-d", "user"],
                    deadline,
                    inventory.current,
                    environment,
                )[0]
            )
            require(legacy.search_unchanged(before, after, str(keychain)))
            for name in ("openssl.cnf", "private-key.pem", "certificate.pem", "identity.p12"):
                inventory.current()
                legacy.current(credentials[name])
                credentials[name].path.unlink()
                require(not os.path.lexists(credentials[name].path))
                del credentials[name]
            inventory.current()
            public_leaf = credentials["public-leaf.der"]
            legacy._write(public / "public-leaf.der", public_leaf.data, 0o644)
            public_result = legacy.ordinary(public / "public-leaf.der", 0o644, 8192)
            require(public_result.data == leaf)
            inventory.current()
            require(set(os.listdir(root / "tmp")) == set())
            require(
                set(os.listdir(root))
                == {
                    ".state.json",
                    "native-db",
                    "tmp",
                    "native-credential-provider",
                    "public-leaf.der",
                }
            )
            inventory.close()
            require(not inventory.close_debt)
            native.close()
            require(not native.debt and not native.reply.close_debt)
            source_guard()
            legacy.remaining(deadline)
            record["phase"] = "ready"
            record["files"] = {name: entry(item) for name, item in credentials.items()}
            result = legacy.public_record(identity, hashlib.sha256(leaf).hexdigest())
            public_data = (json.dumps(result, sort_keys=True) + "\n").encode("ascii")

            def final_guard():
                source_guard()
                require(set(os.listdir(root / "native-db")) == {DATABASE_NAME, LOCK_NAME})
                for name, saved in (
                    (DATABASE_NAME, record["native"]["database"]),
                    (LOCK_NAME, record["native"]["lock"]),
                ):
                    path = root / "native-db" / name
                    observed = path.lstat()
                    require(
                        stat.S_ISREG(observed.st_mode)
                        and full(observed) == tuple(saved["identity"])
                    )
                    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                    try:
                        require(full(os.fstat(descriptor)) == tuple(saved["identity"]))
                        require(
                            hashlib.sha256(
                                os.pread(descriptor, saved["identity"][4] + 1, 0)
                            ).hexdigest()
                            == saved["sha256"]
                        )
                        require(
                            full(os.fstat(descriptor)) == tuple(saved["identity"])
                            and full(path.lstat()) == tuple(saved["identity"])
                        )
                    finally:
                        os.close(descriptor)

            journal.finish_ready(record, public_data, final_guard, deadline)
            require(False)
        except BaseException:
            # No failed native/state outcome becomes a cleanup-ready record.
            # Preserve the route and last phase; there is no path-based rollback.
            try:
                record_setup_debt(root, root_ancestors)
            except BaseException:
                # The original failure remains a failure. If this marker cannot
                # be written, cleanup still requires exact route/state checks
                # and the caller's actual SDK Guardian retirement; no successful
                # setup record is returned, and no mutation retry is attempted.
                pass
            if native is not None:
                native.failed = True
                native.abort()
                native.close()
            if inventory is not None:
                inventory.close()
            if journal is not None:
                journal.close()
            raise


def reopen_native_inventory(legacy, root, record, guard, deadline):
    """Original private-state trust model, explicitly distinct from live IPC.

    Physical outer SDKGuardian retirement is a caller prerequisite. Metadata
    authenticates the earlier fixed FIRST admission; it never proves it owns
    a native producer or substitutes for that producer's SCM_RIGHTS boundary.
    """
    reply = NativeReply(root / "native-db", None, guard, deadline, legacy.remaining)
    try:
        saved = record["native"]["database"]
        reply.descriptor = os.open(
            DATABASE_NAME, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=reply.root_descriptor
        )
        reply.observed = tuple(saved["identity"])
        reply.descriptor_close_identity = reply.observed[:4]
        require(full(os.fstat(reply.descriptor)) == reply.observed)
        reply.data = os.pread(reply.descriptor, reply.observed[4] + 1, 0)
        require(
            len(reply.data) == reply.observed[4]
            and hashlib.sha256(reply.data).hexdigest() == saved["sha256"]
        )
        reply.current()
        inventory = FirstNativeInventory(root / "native-db", reply, guard)
        require(inventory.observed == tuple(record["native"]["lock"]["identity"]))
        inventory.current()
        return inventory
    except BaseException:
        reply.close()
        raise


def bind_cleanup_captures(record, sources, tools, files, directory_ancestors, home_ancestors):
    """Bind every second capture to earlier authenticated saved custody.

    Capturing a different same-byte vnode after the strict reader is not a
    continuation of its authority. The caller performs no mutation beforehand.
    """
    for items, saved_entries, names in (
        (sources, record["custody"]["sources"], lambda item: item.path.name),
        (tools, record["custody"]["tools"], lambda item: str(item.path)),
        (files, record["files"], lambda item: item.path.name),
    ):
        require({names(item) for item in items} == set(saved_entries))
        for item in items:
            saved = saved_entries[names(item)]
            require(
                item.identity == tuple(saved["identity"])
                and hashlib.sha256(item.data).hexdigest() == saved["sha256"]
            )
    require(len(directory_ancestors) == 2)
    for name, parents in zip(("native-db", "tmp"), directory_ancestors):
        require(parents[-1][1] == tuple(record["directories"][name]))
    require(
        [[str(path), list(observed)] for path, observed in home_ancestors]
        == record["custody"]["home_ancestors"]
    )


def cleanup(root):
    """One strict native deletion after caller-owned consumers retire physically."""
    require(sys.platform == "darwin" and root.is_absolute())
    deadline = time.monotonic() + 30
    with fixed_legacy() as (legacy, legacy_current):
        root_ancestors = ancestry(root)
        state, record = closed_ready_record(legacy, root)
        directory_ancestors = tuple(ancestry(root / name) for name in ("native-db", "tmp"))
        environment = account_environment(root / "tmp")
        home_ancestors = ancestry(Path(environment["HOME"]))
        source = legacy.ordinary(Path(__file__))
        native_source = legacy.ordinary(
            Path(__file__).parent / "hs274_native_credential_transaction.cpp"
        )
        require(hashlib.sha256(native_source.data).hexdigest() == CPP_SHA256)
        tools = tuple(
            legacy.ordinary(Path(path), owned=False)
            for path in ("/usr/bin/security", "/usr/bin/openssl", "/usr/bin/codesign")
        )
        files = tuple(
            legacy.ordinary(root / name, record["files"][name]["identity"][3])
            for name in ("native-credential-provider", "public-leaf.der")
        )
        bind_cleanup_captures(
            record, (source, native_source), tools, files, directory_ancestors, home_ancestors
        )

        def guard():
            legacy_current()
            current_ancestry(root_ancestors)
            current_ancestry(home_ancestors)
            for parents in directory_ancestors:
                current_ancestry(parents)
            for item in (state, source, native_source, *tools, *files):
                legacy.current(item)
            require(
                set(os.listdir(root))
                == {
                    ".state.json",
                    "native-db",
                    "tmp",
                    "native-credential-provider",
                    "public-leaf.der",
                }
            )
            require(set(os.listdir(root / "tmp")) == set())

        inventory = None
        try:
            guard()
            inventory = reopen_native_inventory(legacy, root, record, guard, deadline)
            delete_native_inventory(
                legacy, inventory, tuple(record["before"]), deadline, environment
            )
            guard()
        finally:
            if inventory is not None:
                inventory.close()
                inventory.reply.close()
                require(not inventory.close_debt and not inventory.reply.close_debt)
        # No broad deletion. Each remaining original-policy local leaf and
        # directory remains current immediately before its one removal.
        remaining = list(files)
        for item in files:
            legacy_current()
            current_ancestry(root_ancestors)
            for other in (state, *remaining):
                legacy.current(other)
            require(
                set(os.listdir(root))
                == {".state.json", "native-db", "tmp"} | {other.path.name for other in remaining}
            )
            item.path.unlink()
            require(not os.path.lexists(item.path))
            remaining.remove(item)
        for name, parents in zip(("native-db", "tmp"), directory_ancestors):
            current_ancestry(root_ancestors)
            current_ancestry(parents)
            require(set(os.listdir(root / name)) == set())
            (root / name).rmdir()
            require(not os.path.lexists(root / name))
        current_ancestry(root_ancestors)
        require(set(os.listdir(root)) == {".state.json"})
        legacy.current(state)
        state.path.unlink()
        require(set(os.listdir(root)) == set())
        current_ancestry(root_ancestors)
        root.rmdir()
        require(not os.path.lexists(root))
        return {"schema": 1, "status": "removed", "test_only": True}


def main(arguments):
    """Only fixed setup/cleanup actions; no alternate image or provider route."""
    try:
        require(type(arguments) is list and len(arguments) in (2, 3))
        if arguments[0] == "setup" and len(arguments) == 3:
            setup(Path(arguments[1]), Path(arguments[2]))
            require(False)
        elif arguments[0] == "cleanup" and len(arguments) == 2:
            result = cleanup(Path(arguments[1]))
            data = (json.dumps(result, sort_keys=True) + "\n").encode("ascii")
            require(len(data) <= 512 and os.write(1, data) == len(data))
            return 0
        else:
            require(False)
    except Exception:
        # No paths, native diagnostics, secrets or exception text reach stdout.
        try:
            os.write(2, b"Native signing TEST-ONLY fixture refused: native_owner_refused\n")
        except OSError:
            pass
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
