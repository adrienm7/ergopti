# modules/llm/managed_ollama_serve.py
"""Own the admitted runtime image and private daemon session through retirement."""

import argparse
import hashlib
import importlib.util
import math
import os
from pathlib import Path
import secrets
import signal
import stat
import sys
import time

DRIVER = Path(__file__).absolute().parents[2]
SHARED = DRIVER.parent / "_shared"
# Source execution and actual outgoing model profiles must pass native CI before
# the canonical user-facing serve caller may activate this new native port.
NATIVE_PRODUCTION_QUALIFIED = False


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RUNTIME = load("ergopti_serve_runtime", Path(__file__).with_name("managed_ollama_runtime.py"))
OWNER = load("ergopti_serve_image_owner", DRIVER / "platform/suspended_image_owner.py")
ALIASES = load("ergopti_serve_alias_owner", DRIVER / "platform/source_alias_owner.py")
BOOT = load("ergopti_serve_bootstrap_owner", DRIVER / "platform/ollama_bootstrap_owner.py")
AUTHORITY = load("ergopti_serve_daemon_authority", DRIVER / "platform/ollama_daemon_authority.py")
PROXY = load("ergopti_serve_proxy_policy", SHARED / "python/network_proxy_policy.py")
NATIVE = load("ergopti_serve_native_helper", DRIVER / "platform/network/native_http.py")


class ServeRefusal(RuntimeError):
    """Fixed reason retains primary and cleanup failures without secret projection."""

    def __init__(self, reason, *, primary=None, cleanup=None):
        super().__init__(reason)
        self.primary, self.cleanup = primary, cleanup


class ServeOwner:
    """Production source, session and namespace ownership is never derived from UI.

    The installed catalogue supplies source bytes and policy fingerprints. The
    native guardian retains its existing trusted bundle boundary and proves the
    suspended original daemon image before private key or network bytes appear.
    No /dev/fd execution, source pathname fallback, model migration or inherited
    relay materialization is performed here.
    """

    def __init__(self, port, timeout, idle_timeout, retirement_timeout, *, register):
        if (
            type(port) is not int
            or not 1024 <= port <= 65535
            or any(
                type(value) not in (float, int) or not math.isfinite(value) or value <= 0
                for value in (timeout, idle_timeout, retirement_timeout)
            )
        ):
            raise ServeRefusal("protocol")
        self.port, self.idle_timeout = port, idle_timeout
        self.retirement_timeout = retirement_timeout
        self.deadline = time.monotonic() + timeout
        self.source_fd = None
        self.alias = self.session = self.bootstrap = self.authority = self.operation = None
        self._prepared = False
        self._started = False
        self._retirement_deadline = None
        self._cleanup_debt = None
        self.cancelled = False
        register(self)

    def progress(self):
        if self.cancelled:
            raise ServeRefusal("cancelled")
        if time.monotonic() >= self.deadline:
            raise ServeRefusal("deadline")

    def source_check(self):
        self.progress()
        if self.alias is None or self.source_fd is None:
            raise ServeRefusal("source")
        with self.alias.context():
            RUNTIME.native_verify(
                self.target,
                self.contract,
                self.asset,
                self.expected_receipt,
                self.deadline,
                source_alias=self.alias.proof,
                source_identity=self.identity,
            )
        self.progress()

    def prepare(self):
        if (
            self._prepared
            or self._started
            or self._retirement_deadline is not None
            or any(
                value is not None
                for value in (
                    self.source_fd,
                    self.alias,
                    self.session,
                    self.bootstrap,
                    self.authority,
                    self.operation,
                )
            )
        ):
            raise ServeRefusal("state")
        self.progress()
        contract_bytes, catalogue_bytes, host, self.contract, self.asset = RUNTIME.inputs()
        catalogue = RUNTIME.POLICY.metadata_bytes(catalogue_bytes)
        expected_policy = catalogue["repository_source_sha256"].get(
            "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json"
        )
        if expected_policy is None:
            raise ServeRefusal("source")
        # Capture exact inherited settings before any static system-proxy helper
        # can rewrite them. Custom stores remain raw, including relative paths.
        self.policy = BOOT.BootstrapPolicy(
            SHARED / "modules/llm/managed_ollama_bootstrap.json",
            PROXY.ProxyPolicy(),
            expected_contract_sha256=expected_policy,
        )
        snapshot = self.policy.capture(math.ceil(self.idle_timeout * 1000))
        self.target = RUNTIME.owned_directory()
        self.expected_receipt = RUNTIME.POLICY.receipt(
            contract_bytes, catalogue_bytes, host, self.asset
        )
        binary = RUNTIME.native_verify(
            self.target, self.contract, self.asset, self.expected_receipt, self.deadline
        )
        try:
            self.source_fd = os.open(binary, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            before = os.fstat(self.source_fd)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_uid != os.geteuid()
                or before.st_mode & 0o022
                or not before.st_mode & 0o111
                or before.st_nlink != 1
            ):
                raise ServeRefusal("source")
            self.identity = {"device": str(before.st_dev), "inode": str(before.st_ino)}
            digest = hashlib.sha256()
            offset = 0
            while chunk := os.pread(self.source_fd, 65536, offset):
                self.progress()
                digest.update(chunk)
                offset += len(chunk)
            after = os.fstat(self.source_fd)
            if digest.hexdigest() != self.asset["binary_sha256"] or (
                before.st_dev,
                before.st_ino,
                before.st_size,
                before.st_mtime_ns,
                before.st_ctime_ns,
            ) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise ServeRefusal("source")
            self.alias = ALIASES.AliasOwner.acquire(
                self.target,
                self.source_fd,
                self.identity,
                self.asset["binary_sha256"],
                register=lambda value: setattr(self, "alias", value),
                progress=self.progress,
            )
            data = {
                "version": 1,
                "token": secrets.token_hex(32),
                "port": str(self.port),
                "source_commit": self.asset["source_commit"],
                "asset_sha256": self.asset["sha256"],
                "binary_sha256": self.asset["binary_sha256"],
                **self.identity,
            }
            self.session = OWNER.EmptySession.acquire(
                self.target.parent / "ollama-native-sessions",
                data,
                register=lambda value: setattr(self, "session", value),
            )
            self.bootstrap = BOOT.EmptyNetworkBootstrap.acquire(
                self.session,
                snapshot,
                register=lambda value: setattr(self, "bootstrap", value),
            )
            self.authority = AUTHORITY.DaemonAuthority.acquire(
                self.session,
                register=lambda value: setattr(self, "authority", value),
            )
            self.progress()
            launcher = NATIVE._resolve_worker()
            public = {
                "version": 1,
                "executable": str(self.alias.executable),
                "arguments": ["serve"],
                **self.identity,
                "session_path": str(self.session.path),
                "remaining_ms": max(1, math.floor((self.deadline - time.monotonic()) * 1000)),
                "home": str(Path(os.environ["HOME"]).resolve(strict=True)),
                "network_policy": str(SHARED / "modules/network/proxy_policy.json"),
                "host": "127.0.0.1:" + str(self.port),
                **self.bootstrap.fields(),
            }
            self.operation = OWNER.SuspendedImageOwner(
                launcher,
                public,
                self.session,
                self.source_check,
                None,
                register=lambda value: setattr(self, "operation", value),
                bootstrap=self.bootstrap,
            )
            self.alias.bind_operation(self.operation)
            self.authority.bind_operation(self.operation)
            self._prepared = True
            return self
        except BaseException as primary:
            if not self.retire(timeout=self.retirement_timeout):
                raise ServeRefusal(
                    "operation", primary=primary, cleanup=self._cleanup_debt
                ) from primary
            raise

    def start(self):
        if not self._prepared or self._started or self._retirement_deadline is not None:
            raise ServeRefusal("state")
        self._started = True
        self.operation.start()
        self.authority.publish(self.operation, self.alias, self.policy.shared)
        return self

    def retire(self, timeout):
        """Unknown native retirement keeps the exact names and original source FD."""
        if self._retirement_deadline is None:
            if type(timeout) not in (float, int) or not math.isfinite(timeout) or timeout <= 0:
                raise ServeRefusal("protocol")
            self._retirement_deadline = time.monotonic() + timeout
        if self.operation is not None:
            try:
                settled = self.operation.settle(
                    timeout=max(0, self._retirement_deadline - time.monotonic())
                )
            except BaseException as error:
                if self._cleanup_debt is None:
                    self._cleanup_debt = error
                return False
            if self.operation.physically_retired is not True:
                return False
            if settled is not True and self._cleanup_debt is None:
                self._cleanup_debt = ServeRefusal("cleanup")
        for owner in (self.authority, self.bootstrap, self.session, self.alias):
            if owner is not None:
                try:
                    owner.retire()
                except BaseException as error:
                    if self._cleanup_debt is None:
                        self._cleanup_debt = error
        # A live/unknown alias retains the source FD. Retire numeric references
        # before an uncertain close; a reused descriptor is never closed again.
        if self.alias is None or (not self.alias._created and not self.alias._fds):
            descriptor = self.source_fd
            self.source_fd = None
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except BaseException as error:
                    if self._cleanup_debt is None:
                        self._cleanup_debt = error
        return self._cleanup_debt is None and self.source_fd is None

    def wait(self, retirement_timeout):
        while (
            self.operation._retired is None
            and self.operation._refused is None
            and not self.cancelled
        ):
            try:
                self.operation._pump(time.monotonic() + 1)
            except OWNER.ImageRefusal as error:
                if str(error) != "deadline":
                    raise
            if "stdout" in self.operation._eof and self.operation._retired is None:
                raise ServeRefusal("protocol")
        status = self.operation._retired[0] if self.operation._retired is not None else 78
        return status if self.retire(retirement_timeout) else 78


def serve(port, timeout, idle_timeout, retirement_timeout):
    if not NATIVE_PRODUCTION_QUALIFIED:
        raise ServeRefusal("unavailable")
    owner = ServeOwner(port, timeout, idle_timeout, retirement_timeout, register=lambda value: None)

    def cancelled(signum, frame):
        owner.cancelled = True

    previous = {
        name: signal.signal(name, cancelled)
        for name in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        try:
            owner.prepare().start()
            result = owner.wait(retirement_timeout)
        except BaseException as primary:
            if not owner.retire(retirement_timeout):
                raise ServeRefusal(
                    "operation", primary=primary, cleanup=owner._cleanup_debt
                ) from primary
            raise
        if not owner.retire(retirement_timeout):
            raise ServeRefusal("cleanup", cleanup=owner._cleanup_debt)
        return result
    finally:
        for name, handler in previous.items():
            signal.signal(name, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--retirement-timeout", type=float, required=True)
    arguments = parser.parse_args()
    if not 1024 <= arguments.port <= 65535 or any(
        not math.isfinite(value) or value <= 0
        for value in (arguments.timeout, arguments.idle_timeout, arguments.retirement_timeout)
    ):
        return 64
    try:
        return serve(
            arguments.port, arguments.timeout, arguments.idle_timeout, arguments.retirement_timeout
        )
    except Exception:
        print("Managed Ollama daemon admission refused.", file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
