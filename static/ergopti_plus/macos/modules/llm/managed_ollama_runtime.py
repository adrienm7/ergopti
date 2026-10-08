# modules/llm/managed_ollama_runtime.py
"""Native ports for a source-qualified, runtime-only Ollama installation."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import secrets
import select
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import functools
from urllib.parse import urlsplit

DRIVER = Path(__file__).resolve().parents[2]
SHARED = DRIVER.parent / "_shared"


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    sys.modules[name] = module
    specification.loader.exec_module(module)
    return module


POLICY = load("ergopti_managed_ollama_policy", SHARED / "python/managed_ollama_runtime.py")
BOOTSTRAP = load(
    "ergopti_managed_ollama_bootstrap", DRIVER / "modules/llm/managed_bootstrap_http.py"
)
PROXY = load("ergopti_managed_ollama_proxy", SHARED / "python/network_proxy_policy.py")


class CurlResponse:
    """Stream one explicit relay request; close and reap before its successor."""

    def __init__(
        self,
        url,
        *,
        headers,
        timeout,
        idle_timeout,
        direct,
        proxy,
        connect_timeout,
        minimum_bytes_per_second,
    ):
        self.child = None
        self._header_fd = None
        self._header_eof = self._body_eof = self._complete = False
        self._header_count = 0
        self._pending_headers = bytearray()
        self._deadline = time.monotonic() + timeout
        self._idle_timeout = idle_timeout
        writer = None
        try:
            environment = dict(os.environ)
            scheme = urlsplit(url).scheme
            environment[scheme + "_proxy"] = proxy
            # Only the canonical policy decides the bypass for this exact hop.
            environment["no_proxy"] = environment["NO_PROXY"] = ""

            def quoted(value):
                if not isinstance(value, str) or any(ord(c) < 32 or ord(c) == 127 for c in value):
                    raise BOOTSTRAP.BootstrapFailure("protocol")
                return value.replace("\\", "\\\\").replace('"', '\\"')

            configuration = ['url = "' + quoted(url) + '"']
            for name, value in headers:
                if not name or any(
                    c
                    not in "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                    for c in name
                ):
                    raise BOOTSTRAP.BootstrapFailure("protocol")
                configuration.append('header = "' + quoted(name + ": " + value) + '"')
            data = ("\n".join(configuration) + "\n").encode("utf-8")
            if len(data) > 65536:
                raise BOOTSTRAP.BootstrapFailure("protocol")
            self._header_fd, writer = os.pipe()
            self.child = subprocess.Popen(
                [
                    "/usr/bin/curl",
                    "-q",
                    "--silent",
                    "--fail",
                    "--config",
                    "-",
                    "--connect-timeout",
                    str(min(connect_timeout, self._remaining())),
                    "--max-time",
                    str(self._remaining()),
                    "--speed-limit",
                    str(minimum_bytes_per_second),
                    "--speed-time",
                    str(max(1, int(idle_timeout))),
                    "--suppress-connect-headers",
                    "--no-buffer",
                    "--output",
                    "-",
                    "--dump-header",
                    "/dev/fd/" + str(writer),
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                pass_fds=(writer,),
                env=environment,
            )
            os.close(writer)
            writer = None
            self._send(data)
            while True:
                self._wait([self._header_fd])
                self._headers_chunk()
                while b"\r\n\r\n" in self._pending_headers:
                    block, _, rest = self._pending_headers.partition(b"\r\n\r\n")
                    self._pending_headers = bytearray(rest)
                    lines = block.split(b"\r\n")
                    tokens = lines[0].split(b" ")
                    if (
                        len(tokens) < 2
                        or not tokens[0].startswith(b"HTTP/")
                        or len(tokens[1]) != 3
                        or not tokens[1].isdigit()
                    ):
                        raise BOOTSTRAP.BootstrapFailure("protocol")
                    status = int(tokens[1])
                    if 100 <= status < 200:
                        continue
                    if not 200 <= status <= 599:
                        raise BOOTSTRAP.BootstrapFailure("protocol")
                    self.status, self.headers = status, []
                    for line in lines[1:]:
                        name, separator, value = line.partition(b":")
                        if (
                            not separator
                            or not name
                            or any(byte < 33 or byte >= 127 for byte in name)
                        ):
                            raise BOOTSTRAP.BootstrapFailure("protocol")
                        self.headers.append((name.decode("ascii"), value.decode("latin-1").strip()))
                    return
                if self._header_eof:
                    raise BOOTSTRAP.BootstrapFailure("connect")
        except BaseException:
            self.close()
            raise
        finally:
            if writer is not None:
                os.close(writer)

    def _remaining(self):
        remaining = self._deadline - time.monotonic()
        if remaining <= 0:
            raise BOOTSTRAP.BootstrapFailure("deadline")
        return remaining

    def _wait(self, descriptors, *, writable=False):
        budget = min(self._remaining(), self._idle_timeout)
        ready = select.select(
            [] if writable else descriptors, descriptors if writable else [], [], budget
        )
        selected = ready[1] if writable else ready[0]
        if not selected:
            raise BOOTSTRAP.BootstrapFailure("deadline")
        return selected

    def _send(self, data):
        descriptor = self.child.stdin.fileno()
        os.set_blocking(descriptor, False)
        offset = 0
        while offset < len(data):
            self._wait([descriptor], writable=True)
            try:
                offset += os.write(descriptor, data[offset : offset + 4096])
            except BlockingIOError:
                continue
        self.child.stdin.close()

    def _headers_chunk(self):
        chunk = os.read(self._header_fd, 4096)
        self._header_count += len(chunk)
        if self._header_count > 65536:
            raise BOOTSTRAP.BootstrapFailure("protocol")
        self._pending_headers.extend(chunk)
        self._header_eof = not chunk

    def read(self, maximum=65535):
        if self._complete:
            return b""
        if type(maximum) is not int or not 1 <= maximum <= 65535:
            raise BOOTSTRAP.BootstrapFailure("protocol")
        try:
            while not self._body_eof or not self._header_eof:
                descriptors = []
                if not self._header_eof:
                    descriptors.append(self._header_fd)
                if not self._body_eof:
                    descriptors.append(self.child.stdout.fileno())
                selected = self._wait(descriptors)
                if self._header_fd in selected:
                    self._headers_chunk()
                if self.child.stdout.fileno() in selected:
                    chunk = os.read(self.child.stdout.fileno(), maximum)
                    self._body_eof = not chunk
                    if chunk:
                        return chunk
            if self.child.wait(timeout=self._remaining()) != 0:
                raise BOOTSTRAP.BootstrapFailure("connect")
            self._complete = True
            self.close()
            return b""
        except BaseException:
            self.close()
            raise

    def close(self):
        if self.child is not None:
            if self.child.poll() is None:
                self.child.kill()
            self.child.wait()
            for stream in (self.child.stdin, self.child.stdout):
                if stream is not None and not stream.closed:
                    stream.close()
        if self._header_fd is not None:
            descriptor, self._header_fd = self._header_fd, None
            os.close(descriptor)

    def __enter__(self):
        return self

    def __exit__(self, *arguments):
        self.close()


def runtime_request(
    url, *, headers, timeout, idle_timeout, direct, connect_timeout, minimum_bytes_per_second
):
    mode, proxy = PROXY.ProxyPolicy().route(url, dict(os.environ))
    if mode == "environment":
        return CurlResponse(
            url,
            headers=headers,
            timeout=timeout,
            idle_timeout=idle_timeout,
            direct=False,
            proxy=proxy,
            connect_timeout=connect_timeout,
            minimum_bytes_per_second=minimum_bytes_per_second,
        )
    return BOOTSTRAP._native_request(
        url, headers=headers, timeout=timeout, idle_timeout=idle_timeout, direct=mode == "direct"
    )


def inputs():
    if sys.platform != "darwin":
        raise POLICY.RuntimeRefusal("unavailable")
    architecture = {"arm64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    if architecture is None:
        raise POLICY.RuntimeRefusal("unavailable")
    host = "macos-" + architecture
    contract_bytes = (SHARED / "modules/llm/managed_ollama_runtime.json").read_bytes()
    catalogue_bytes = (SHARED / "modules/llm/managed_ollama_release.json").read_bytes()
    contract, asset = POLICY.select_asset(contract_bytes, catalogue_bytes, host)
    return contract_bytes, catalogue_bytes, host, contract, asset


def owned_directory():
    home = os.environ.get("HOME", "")
    if not home.startswith("/"):
        raise POLICY.RuntimeRefusal("runtime")
    return Path(home) / "Library/Application Support/Ergopti/ollama-native-http"


def native_verify(root, contract, asset, expected_receipt, deadline):
    binary = POLICY.verify_directory(root, contract, asset, expected_receipt)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise POLICY.RuntimeRefusal("deadline")
    # Same signing policy as the existing release: configured certificate or
    # genuine ad-hoc signature. Catalogue bytes remain the artifact identity.
    process = subprocess.Popen(
        ["/usr/bin/codesign", "--verify", "--strict", str(binary)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        if process.wait(timeout=remaining) != 0:
            raise POLICY.RuntimeRefusal("signature")
    finally:
        if process.poll() is None:
            process.kill()
        process.wait()
    with binary.open("rb") as stream:
        header = stream.read(32)
    import struct

    expected_cpu = {"arm64": 0x0100000C, "amd64": 0x01000007}[asset["architecture"]]
    if (
        len(header) != 32
        or header[:4] != b"\xcf\xfa\xed\xfe"
        or struct.unpack_from("<I", header, 4)[0] != expected_cpu
    ):
        raise POLICY.RuntimeRefusal("architecture")
    return binary


def install(
    deadline, idle_timeout, fixture_url=None, connect_timeout=None, minimum_bytes_per_second=None
):
    """Download actual catalogue bytes and publish only a new owned directory.

    A manual native receiver may inject its own exact loopback fixture URL;
    hashes and source qualification always come from the unchanged catalogue.
    The production command exposes no fixture URL option.
    """
    contract_bytes, catalogue_bytes, host, contract, asset = inputs()
    url = asset["url"]
    if fixture_url is not None:
        publication = POLICY.metadata_bytes(catalogue_bytes)["publication"]
        parsed = urlsplit(fixture_url)
        if (
            url
            or publication.get("mode") != "unpublished-ci"
            or parsed.scheme != "http"
            or parsed.hostname != "127.0.0.1"
            or not parsed.port
            or parsed.username
            or parsed.password
            or parsed.fragment
            or parsed.path.rsplit("/", 1)[-1] != asset["filename"]
        ):
            raise POLICY.RuntimeRefusal("unavailable")
        url = fixture_url
    if not url:
        raise POLICY.RuntimeRefusal("unavailable")
    target = owned_directory()
    expected_receipt = POLICY.receipt(contract_bytes, catalogue_bytes, host, asset)
    if target.exists() or target.is_symlink():
        # An existing foreign/modified runtime is never displaced silently.
        return native_verify(target, contract, asset, expected_receipt, deadline)
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if target.parent.is_symlink():
        raise POLICY.RuntimeRefusal("runtime")
    with tempfile.TemporaryDirectory(prefix=".ollama-native-http-", dir=target.parent) as temporary:
        root = Path(temporary)
        archive = root / asset["filename"]
        if (
            connect_timeout is None
            or type(minimum_bytes_per_second) is not int
            or minimum_bytes_per_second <= 0
        ):
            raise POLICY.RuntimeRefusal("protocol")
        request = functools.partial(
            runtime_request,
            connect_timeout=connect_timeout,
            minimum_bytes_per_second=minimum_bytes_per_second,
        )
        BOOTSTRAP.download(
            url, archive, asset["sha256"], asset["bytes"], deadline, idle_timeout, request=request
        )
        stage = root / "runtime"
        stage.mkdir(mode=0o700)
        with tarfile.open(archive) as source:
            source.extractall(stage, filter="data")
        native_verify(stage, contract, asset, None, deadline)
        receipt_path = stage / POLICY.RECEIPT_BASENAME
        with receipt_path.open("x", encoding="utf-8") as stream:
            os.chmod(receipt_path, 0o600)
            stream.write(json.dumps(expected_receipt, sort_keys=True) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        native_verify(stage, contract, asset, expected_receipt, deadline)
        # macOS renameatx_np(RENAME_EXCL) makes the final publication exclusive
        # at the kernel boundary; an intervening foreign target survives.
        import ctypes

        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        libc.renameatx_np.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        libc.renameatx_np.restype = ctypes.c_int
        if libc.renameatx_np(-2, os.fsencode(stage), -2, os.fsencode(target), 0x00000004) != 0:
            raise POLICY.RuntimeRefusal("publish")
    return native_verify(target, contract, asset, expected_receipt, deadline)


def create_session(deadline, port):
    if type(port) is not int or not 1024 <= port <= 65535:
        raise POLICY.RuntimeRefusal("session")
    contract_bytes, catalogue_bytes, host, contract, asset = inputs()
    target = owned_directory()
    binary = native_verify(
        target,
        contract,
        asset,
        POLICY.receipt(contract_bytes, catalogue_bytes, host, asset),
        deadline,
    )
    identity = binary.stat(follow_symlinks=False)
    data = {
        "version": 1,
        "token": secrets.token_hex(32),
        "source_commit": asset["source_commit"],
        "binary_sha256": asset["binary_sha256"],
        "asset_sha256": asset["sha256"],
        "device": str(identity.st_dev),
        "inode": str(identity.st_ino),
    }
    data["port"] = str(port)
    sessions = target.parent / "ollama-native-sessions"
    sessions.mkdir(mode=0o700, exist_ok=True)
    if (
        sessions.is_symlink()
        or sessions.stat().st_uid != os.geteuid()
        or sessions.stat().st_mode & 0o077
    ):
        raise POLICY.RuntimeRefusal("session")
    descriptor, path = tempfile.mkstemp(prefix="daemon-", suffix=".json", dir=sessions)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(json.dumps(data, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    # Only a private lease pathname crosses the command boundary. Bearer bytes
    # never leave the caller-owned file or native private request pipe.
    return str(path)


def cancelled(signum, frame):
    raise POLICY.RuntimeRefusal("cancelled")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "verify", "create-session"))
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--port", type=int)
    parser.add_argument("--connect-timeout", type=float, required=True)
    parser.add_argument("--minimum-bytes-per-second", type=int, required=True)
    arguments = parser.parse_args()
    import math

    if any(
        not math.isfinite(value) or value <= 0
        for value in (arguments.timeout, arguments.idle_timeout, arguments.connect_timeout)
    ):
        raise SystemExit(64)
    if arguments.minimum_bytes_per_second <= 0:
        raise SystemExit(64)
    for name in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(name, cancelled)
    try:
        deadline = time.monotonic() + arguments.timeout
        if arguments.action == "install":
            answer = install(
                deadline,
                arguments.idle_timeout,
                connect_timeout=arguments.connect_timeout,
                minimum_bytes_per_second=arguments.minimum_bytes_per_second,
            )
        elif arguments.action == "create-session":
            answer = create_session(deadline, arguments.port)
        else:
            contract_bytes, catalogue_bytes, host, contract, asset = inputs()
            answer = native_verify(
                owned_directory(),
                contract,
                asset,
                POLICY.receipt(contract_bytes, catalogue_bytes, host, asset),
                deadline,
            )
        print(answer)
    except (
        POLICY.RuntimeRefusal,
        BOOTSTRAP.BootstrapFailure,
        OSError,
        ValueError,
        TypeError,
        KeyError,
        subprocess.TimeoutExpired,
    ):
        print("Managed Ollama runtime admission refused.", file=sys.stderr)
        raise SystemExit(78)
