# modules/llm/managed_ollama_runtime.py
"""Native ports for a source-qualified, runtime-only Ollama installation."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import platform
import secrets
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
    """One explicit-environment request; curl is reaped before data delivery."""

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
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-ollama-explicit-")
        self.body = None
        child = None
        metadata = None
        try:
            root = Path(self.owner.name)
            body = (root / "body").open("xb+")
            metadata = (root / "headers").open("xb+")
            self.body = body
            environment = dict(os.environ)
            scheme = urlsplit(url).scheme
            environment[scheme + "_proxy"] = proxy
            # The canonical shared policy evaluated bypass for this exact hop.
            # A second curl parser must not reinterpret a different rule.
            environment["no_proxy"] = environment["NO_PROXY"] = ""
            quoted = url.replace("\\", "\\\\").replace('"', '\\"')
            configuration = ('url = "' + quoted + '"\n').encode("utf-8")
            child = subprocess.Popen(
                [
                    "/usr/bin/curl",
                    "--silent",
                    "--fail",
                    "--config",
                    "-",
                    "--connect-timeout",
                    str(min(connect_timeout, timeout)),
                    "--max-time",
                    str(timeout),
                    "--speed-limit",
                    str(minimum_bytes_per_second),
                    "--speed-time",
                    str(max(1, int(idle_timeout))),
                    "--header",
                    "Accept-Encoding: identity",
                    "--output",
                    "/dev/fd/" + str(body.fileno()),
                    "--dump-header",
                    "/dev/fd/" + str(metadata.fileno()),
                    "--write-out",
                    "%{http_code}",
                ],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                pass_fds=(body.fileno(), metadata.fileno()),
                env=environment,
            )
            try:
                status, _ = child.communicate(configuration, timeout=timeout)
                if child.returncode != 0 or len(status) != 3 or not status.isdigit():
                    raise BOOTSTRAP.BootstrapFailure("connect")
                metadata.seek(0)
                raw = metadata.read(65537)
                if len(raw) > 65536:
                    raise BOOTSTRAP.BootstrapFailure("protocol")
                blocks = [block for block in raw.split(b"\r\n\r\n") if block.startswith(b"HTTP/")]
                if not blocks:
                    raise BOOTSTRAP.BootstrapFailure("protocol")
                lines = blocks[-1].split(b"\r\n")
                if lines[0].split(b" ")[1] != status:
                    raise BOOTSTRAP.BootstrapFailure("protocol")
                self.status = int(status)
                self.headers = []
                for line in lines[1:]:
                    name, separator, value = line.partition(b":")
                    if not separator or not name or any(byte < 33 or byte >= 127 for byte in name):
                        raise BOOTSTRAP.BootstrapFailure("protocol")
                    self.headers.append((name.decode("ascii"), value.decode("latin-1").strip()))
                body.flush()
                body.seek(0)
            finally:
                metadata.close()
                if child.poll() is None:
                    child.kill()
                child.wait()
                if child.stdin and not child.stdin.closed:
                    child.stdin.close()
                if child.stdout and not child.stdout.closed:
                    child.stdout.close()
        except BaseException:
            if child is not None and child.poll() is None:
                child.kill()
                child.wait()
            if metadata is not None:
                metadata.close()
            self.close()
            raise

    def read(self, maximum=65535):
        return self.body.read(maximum)

    def close(self):
        if self.body is not None:
            self.body.close()
        self.owner.cleanup()

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
