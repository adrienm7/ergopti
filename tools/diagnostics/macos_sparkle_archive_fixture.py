#!/usr/bin/env python3
# tools/diagnostics/macos_sparkle_archive_fixture.py

"""Serve private Sparkle archives and observe actual owned macOS executables."""

import ctypes
import hashlib
import http.server
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import uuid


class NativeCensusRefusal(RuntimeError):
    """Bounded facts about this helper, never a process path or exception text."""

    def __init__(self, path_errno, bsd=None):
        helper_pid = os.getpid()
        if (
            type(path_errno) is not int
            or not 0 <= path_errno <= 4095
            or not 0 < helper_pid <= 2147483647
        ):
            raise RuntimeError("Native Sparkle diagnostic refused")
        super().__init__("Native Sparkle process census is incomplete")
        self.packet = {
            "schema": 1,
            "code": "path-unavailable",
            "helper_pid": helper_pid,
            "path_errno": path_errno,
        }
        if bsd is not None:
            if (
                type(bsd) is not dict
                or set(bsd) != {"bsd_bytes", "bsd_errno", "bsd_state"}
                or any(
                    type(bsd[key]) is not int or not 0 <= bsd[key] <= 4095
                    for key in ("bsd_bytes", "bsd_errno")
                )
                or type(bsd["bsd_state"]) is not str
                or bsd["bsd_state"] not in BSD_DIAGNOSTIC_STATES
                or (
                    bsd["bsd_state"] in BSD_PROCESS_STATES.values()
                    and (bsd["bsd_bytes"] != 136 or bsd["bsd_errno"] != 0)
                )
            ):
                raise RuntimeError("Native Sparkle diagnostic refused")
            self.packet["schema"] = 2
            self.packet.update(bsd)


BSD_PROCESS_STATES = {1: "creating", 2: "runnable", 3: "sleeping", 4: "stopped", 5: "zombie"}
BSD_DIAGNOSTIC_STATES = frozenset(BSD_PROCESS_STATES.values()) | {
    "unavailable",
    "identity-refused",
    "state-refused",
    "abi-refused",
    "diagnostic-refused",
}


def bsd_diagnostic(library, pid, owner):
    """Observe a bounded BSD snapshot; it never admits, skips or retires a PID.

    Official XNU proc_info.h defines PROC_PIDTBSDINFO=3. A nonzero argument
    admits a zombie reference, unlike proc_pidpath. State5 describes only the
    metadata snapshot; it is not proof of earlier PID identity or retirement.
    """
    facts = {"bsd_bytes": 0, "bsd_errno": 0, "bsd_state": "diagnostic-refused"}
    try:
        # Reuse the trusted sibling declaration rather than a second ABI layout.
        source = Path(__file__).with_name("macos_owned_process.py")
        spec = importlib.util.spec_from_file_location("sparkle_bsd_layout", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        record_type = module.ProcBSDInfo
        offsets = {
            "status": 4,
            "pid": 12,
            "uid": 20,
            "pgid": 100,
            "start_sec": 120,
            "start_usec": 128,
        }
        if ctypes.sizeof(record_type) != 136 or any(
            getattr(record_type, key).offset != offset for key, offset in offsets.items()
        ):
            facts["bsd_state"] = "abi-refused"
            return facts
        library.proc_pidinfo.argtypes = [
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint64,
            ctypes.c_void_p,
            ctypes.c_int,
        ]
        library.proc_pidinfo.restype = ctypes.c_int
        record = record_type()
        ctypes.set_errno(0)
        returned = library.proc_pidinfo(pid, 3, 1, ctypes.byref(record), 136)
        native_errno = ctypes.get_errno()
        if (
            type(returned) is not int
            or not 0 <= returned <= 4095
            or type(native_errno) is not int
            or not 0 <= native_errno <= 4095
        ):
            return facts
        facts.update(bsd_bytes=returned, bsd_errno=native_errno, bsd_state="unavailable")
        if returned != 136 or native_errno != 0:
            return facts
        if record.pid != pid or record.uid != owner:
            facts["bsd_state"] = "identity-refused"
            return facts
        facts["bsd_state"] = BSD_PROCESS_STATES.get(record.status, "state-refused")
        return facts
    except Exception:
        # Diagnostic failure cannot replace the original path refusal or expose
        # names, argv, native buffers, paths or exception text.
        return facts


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
            # Claim admitted handling before checking the stop cut. A stop here
            # either refuses new work or lets an already admitted response finish.
            self.server.active_handler_admitted = True
            if state["stopping"]:
                # A partial header can parse after stop-generated EOF. No new
                # resource read, publication or response may start after the cut.
                self.close_connection = True
                return
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
        def __init__(self, *arguments, **options):
            self.active_request = None
            self.active_handler_admitted = False
            self.active_stop_attempted = False
            self.stop_failure = None
            super().__init__(*arguments, **options)

        def request_stop(self, *_arguments):
            state["stopping"] = True
            request = self.active_request
            if request is None or self.active_stop_attempted or self.active_handler_admitted:
                return
            self.active_stop_attempted = True
            try:
                # This is the exact accepted socket, retained before the handler
                # reads headers. A flag alone cannot interrupt that blocking read.
                request.shutdown(socket.SHUT_RDWR)
            except OSError as failure:
                # A refused shutdown is never a close ACK or a successful stop.
                # Keep the first refusal until the original request physically exits.
                if self.stop_failure is None:
                    self.stop_failure = failure

        def process_request(self, request, client_address):
            if self.active_request is not None:
                raise RuntimeError("Private Sparkle accepted-socket owner is already active")
            self.active_handler_admitted = False
            self.active_stop_attempted = False
            self.active_request = request
            # BaseServer's error callback may raise before its own shutdown.
            # The native accepted socket has one unconditional physical owner.
            try:
                if not state["stopping"]:
                    self.finish_request(request, client_address)
            finally:
                # Header/body handling is now terminal; the local request still
                # owns its capability while canonical shutdown closes it below.
                self.active_request = None
                self.active_handler_admitted = False
                self.shutdown_request(request)

        def handle_error(self, _request, _address):
            raise RuntimeError("Private Sparkle resource handling refused")

    server = PrivateServer(("127.0.0.1", 0), Handler)
    try:
        server.timeout = 0.2
        signal.signal(signal.SIGTERM, server.request_stop)
        signal.signal(signal.SIGINT, server.request_stop)
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
        if server.stop_failure is not None:
            raise RuntimeError("Private Sparkle accepted-socket stop refused")
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
        ctypes.set_errno(0)
        length = library.proc_pidpath(pid, buffer, len(buffer))
        path_errno = ctypes.get_errno()
        if length <= 0:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                continue
            raise NativeCensusRefusal(path_errno, bsd_diagnostic(library, pid, owner))
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


def entrypoint(arguments):
    """Export fixed refusal facts without changing strict native admission."""
    try:
        main(arguments)
    except NativeCensusRefusal as failure:
        print(json.dumps(failure.packet, sort_keys=True))
        print("Private Sparkle fixture refused.", file=sys.stderr)
        return 1
    except Exception:
        print("Private Sparkle fixture refused.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    # The fixed CLI receipt has the same bytes on every control-test host.
    sys.stdout.reconfigure(newline="\n")
    sys.stderr.reconfigure(newline="\n")
    sys.exit(entrypoint(sys.argv[1:]))
