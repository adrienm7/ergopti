#!/usr/bin/env python3
# tools/diagnostics/macos_sparkle_archive_fixture.py

"""Serve private Sparkle archives and observe actual owned macOS executables."""

import ctypes
import hashlib
import http.server
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import uuid


def publish(path, value):
    """Publish an exclusive receipt without exposing a partially written file."""
    stage = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    descriptor = os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write((json.dumps(value, sort_keys=True) + "\n").encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.link(stage, path)
    finally:
        stage.unlink()


def private_directory(path):
    """Admit only a physical, exclusively writable private fixture directory."""
    path = Path(path)
    metadata = path.lstat()
    if (
        not path.is_absolute()
        or not stat.S_ISDIR(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or metadata.st_uid != os.geteuid()
        or path.resolve() != path
    ):
        raise RuntimeError("Private Sparkle directory refused")
    return path


def serve(root, nonce):
    """Allow exactly two loopback-only resources; retain each served-byte digest."""
    root = private_directory(root)
    if len(nonce) != 32 or any(c not in "0123456789abcdef" for c in nonce):
        raise RuntimeError("Private Sparkle session refused")
    state = {"stopping": False, "requests": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_arguments):
            pass

        def do_GET(self):
            routes = {"/feed.xml": "feed.xml", "/archive.tar.xz": "archive.tar.xz"}
            if self.path not in routes:
                self.send_error(404)
                return
            self.connection.settimeout(5)
            descriptor = os.open(root / routes[self.path], os.O_RDONLY | os.O_NOFOLLOW)
            try:
                metadata = os.fstat(descriptor)
                if not stat.S_ISREG(metadata.st_mode) or not 0 < metadata.st_size <= 100_000_000:
                    raise RuntimeError("Private Sparkle resource refused")
                with os.fdopen(descriptor, "rb", closefd=False) as stream:
                    payload = stream.read(100_000_001)
                if len(payload) != metadata.st_size:
                    raise RuntimeError("Private Sparkle resource changed")
            finally:
                os.close(descriptor)
            state["requests"] += 1
            publish(
                root / ("request-%06d.json" % state["requests"]),
                {
                    "nonce": nonce,
                    "path": self.path,
                    "bytes": len(payload),
                    "sha256": hashlib.sha256(payload).hexdigest(),
                },
            )
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Cache-Control", "no-store")
            self.send_header(
                "Content-Type",
                "application/xml" if self.path == "/feed.xml" else "application/octet-stream",
            )
            self.end_headers()
            self.wfile.write(payload)

    # Sparkle 2.9.2 explicitly supports local-network testing. Only the private
    # fixture has NSAllowsLocalNetworking; archive EdDSA admission remains on.
    class PrivateServer(http.server.HTTPServer):
        def process_request(self, request, client_address):
            # BaseServer's error callback may raise before its own shutdown.
            # The native accepted socket has one unconditional physical owner.
            try:
                self.finish_request(request, client_address)
            finally:
                self.shutdown_request(request)

        def handle_error(self, _request, _address):
            raise RuntimeError("Private Sparkle resource handling refused")

    server = PrivateServer(("127.0.0.1", 0), Handler)
    try:
        server.timeout = 0.2
        signal.signal(signal.SIGTERM, lambda *_args: state.update(stopping=True))
        signal.signal(signal.SIGINT, lambda *_args: state.update(stopping=True))
        publish(
            root / "server-start.json",
            {
                "nonce": nonce,
                "pid": os.getpid(),
                "port": server.server_port,
            },
        )
        while not state["stopping"]:
            server.handle_request()
    finally:
        server.server_close()
        publish(
            root / "server-retired.json",
            {
                "nonce": nonce,
                "pid": os.getpid(),
                "requests": state["requests"],
            },
        )


def census(roots):
    """Read kernel executable paths, never process arguments or foreign secrets."""
    if sys.platform != "darwin":
        raise RuntimeError("Native Sparkle process observation requires macOS")
    admitted = [private_directory(root) for root in roots]
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    inventory = subprocess.run(
        ["/bin/ps", "-axo", "pid=,uid="],
        check=True,
        capture_output=True,
        text=True,
        timeout=5,
    )
    result = []
    for line in inventory.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or any(not field.isdecimal() for field in fields):
            raise RuntimeError("Native Sparkle process inventory refused")
        pid, owner = map(int, fields)
        if owner != os.geteuid():
            continue
        buffer = ctypes.create_string_buffer(4096)
        length = library.proc_pidpath(pid, buffer, len(buffer))
        if length <= 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            raise RuntimeError("Native Sparkle process census is incomplete")
        executable = os.fsdecode(buffer.value)
        if any(executable.startswith(str(root) + "/") for root in admitted):
            result.append({"pid": pid, "executable": executable})
    return sorted(result, key=lambda entry: entry["pid"])


def main(arguments):
    """Fail closed on unsupported native observations or malformed invocations."""
    if len(arguments) == 3 and arguments[0] == "serve":
        serve(arguments[1], arguments[2])
    elif len(arguments) >= 2 and arguments[0] == "census":
        print(json.dumps(census(arguments[1:]), sort_keys=True))
    else:
        raise RuntimeError("Private Sparkle operation refused")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception:
        print("Private Sparkle fixture refused.", file=sys.stderr)
        sys.exit(1)
