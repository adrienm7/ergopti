"""Owned HTTP/TLS PAC peers; never edits account/system trust or proxy settings."""

import contextlib
import http.server
import json
from pathlib import Path
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time


SCRIPT = 'function FindProxyForURL(url,host){return "PROXY pac-source.invalid:23456";}'
MAXIMUM = 1048576
RETAINED_DEBT = []


class SourceFixture:
    """Two listener/thread owners retire before their temporary keys disappear."""

    def __init__(self):
        self.directory = tempfile.TemporaryDirectory(prefix="ergopti-pac-source-")
        self.root = Path(self.directory.name)
        self.servers = []
        self.threads = []
        self.request_threads = []
        self.shutdown_threads = []
        self.server_starts = []
        self.server_shutdowns = []
        self.request_starts = []
        self.cleanup_failure = None
        self.connections = set()
        self.lock = threading.Lock()
        self.records = []
        self.closed = False
        self.stop = threading.Event()
        try:
            self._certificates()
            self._listeners()
        except BaseException:
            try:
                self.close()
            except BaseException:
                RETAINED_DEBT.append(self)
            raise

    def _certificates(self):
        def openssl(*arguments):
            subprocess.run(
                ["/usr/bin/openssl", *arguments],
                check=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=30,
            )

        authority = self.root / "ca.conf"
        authority.write_text(
            "[req]\ndistinguished_name=dn\n[dn]\n[ca_ext]\n"
            "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n",
            encoding="utf-8",
        )
        openssl(
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-subj",
            "/CN=Owned PAC source CA",
            "-keyout",
            str(self.root / "ca.key"),
            "-out",
            str(self.root / "ca.pem"),
            "-config",
            str(authority),
            "-extensions",
            "ca_ext",
        )
        openssl(
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=Owned PAC source",
            "-keyout",
            str(self.root / "server.key"),
            "-out",
            str(self.root / "server.csr"),
        )
        extension = self.root / "extensions.conf"
        extension.write_text(
            "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n",
            encoding="utf-8",
        )
        openssl(
            "x509",
            "-req",
            "-in",
            str(self.root / "server.csr"),
            "-CA",
            str(self.root / "ca.pem"),
            "-CAkey",
            str(self.root / "ca.key"),
            "-CAcreateserial",
            "-days",
            "1",
            "-extfile",
            str(extension),
            "-out",
            str(self.root / "server.pem"),
        )

    def _listeners(self):
        owner = self
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root / "server.pem", self.root / "server.key")

        class Server(http.server.ThreadingHTTPServer):
            daemon_threads = False
            block_on_close = True

            def server_bind(self):
                # The owned numeric address needs no reverse DNS before READY.
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address[:2]

            def get_request(self):
                connection, address = super().get_request()
                with owner.lock:
                    owner.connections.add(connection)
                connection.settimeout(2)
                return connection, address

            def close_request(self, connection):
                try:
                    super().close_request(connection)
                except BaseException as failure:
                    owner._uncertain_cleanup(failure)
                    raise
                with owner.lock:
                    owner.connections.discard(connection)

            def process_request(self, request, address):
                thread = threading.Thread(
                    target=self.process_request_thread, args=(request, address)
                )
                state = {
                    "worker": thread,
                    "connection": request,
                    "attempted": False,
                    "started": False,
                    "failure": None,
                }
                with owner.lock:
                    owner.request_threads.append(thread)
                    owner.request_starts.append(state)
                try:
                    state["attempted"] = True
                    thread.start()
                    state["started"] = True
                except BaseException as failure:
                    state["failure"] = failure
                    raise

            def shutdown_request(self, request):
                with owner.lock:
                    uncertain = any(
                        state["connection"] is request
                        and not state["started"]
                        and state["failure"] is not None
                        for state in owner.request_starts
                    )
                if uncertain:
                    # BaseServer otherwise closes this acquired socket while
                    # an unacknowledged native request worker may still use it.
                    return
                super().shutdown_request(request)

            def handle_error(self, *_):
                pass  # Native cancellation/untrusted TLS are controlled refusals.

        class TLSServer(Server):
            def get_request(self):
                raw, address = super().get_request()
                try:
                    connection = context.wrap_socket(
                        raw, server_side=True, do_handshake_on_connect=False
                    )
                    with owner.lock:
                        owner.connections.discard(raw)
                        owner.connections.add(connection)
                    connection.do_handshake()
                    return connection, address
                except BaseException:
                    if "connection" in locals():
                        self.close_request(connection)
                    else:
                        self.close_request(raw)
                    raise

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *_):
                pass

            def do_GET(self):
                with owner.lock:
                    owner.records.append(
                        {
                            "path": self.path,
                            "authorization": self.headers.get("Authorization") is not None,
                        }
                    )
                mode = self.path.removeprefix("/source/")
                data = SCRIPT.encode()
                status = 200
                headers = {}
                if mode == "utf8-bom":
                    data = b"\xef\xbb\xbf" + data
                elif mode == "utf16-le":
                    data = b"\xff\xfe" + SCRIPT.encode("utf-16le")
                elif mode == "utf16-be":
                    data = b"\xfe\xff" + SCRIPT.encode("utf-16be")
                elif mode == "invalid-utf8":
                    data = b"\xc0\x80"
                elif mode == "invalid-utf16":
                    data = b"\xff\xfe\x00\xd8"
                elif mode == "nul":
                    data += b"\x00"
                elif mode == "empty":
                    data = b""
                elif mode == "oversized":
                    data = b"x" * (MAXIMUM + 1)
                elif mode == "unavailable":
                    status = 503
                elif mode in ("redirect", "foreign", "downgrade", "loop", "foreign-auth"):
                    status = 302
                    if mode == "redirect":
                        headers["Location"] = "/source/utf8"
                    elif mode == "loop":
                        headers["Location"] = "/source/loop"
                    else:
                        host = "localhost" if mode in ("foreign", "foreign-auth") else "127.0.0.1"
                        target = "authentication" if mode == "foreign-auth" else "utf8"
                        headers["Location"] = (
                            f"http://{host}:{owner.http.server_port}/source/{target}"
                        )
                elif mode == "authentication":
                    status = 401
                    headers["WWW-Authenticate"] = 'Basic realm="owned-pac-source"'
                elif mode == "truncated":
                    headers["Content-Length"] = str(len(data) + 1)
                elif mode == "held":
                    owner.stop.wait(2)
                elif mode != "utf8":
                    status = 404
                self.send_response(status)
                self.send_header("Content-Length", headers.pop("Content-Length", str(len(data))))
                self.send_header("Connection", "close")
                for name, value in headers.items():
                    self.send_header(name, value)
                self.end_headers()
                with contextlib.suppress(OSError):
                    self.wfile.write(data)
                self.close_connection = True

        self.http = Server(("127.0.0.1", 0), Handler)
        self.servers.append(self.http)
        self.https = TLSServer(("127.0.0.1", 0), Handler)
        self.servers.append(self.https)
        for server in self.servers:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
            self.threads.append(thread)
            state = {
                "server": server,
                "worker": thread,
                "attempted": False,
                "started": False,
                "failure": None,
            }
            self.server_starts.append(state)
            try:
                state["attempted"] = True
                thread.start()
                state["started"] = True
            except BaseException as failure:
                state["failure"] = failure
                raise

    def profile(self):
        return {
            "version": 1,
            "http_port": self.http.server_port,
            "https_port": self.https.server_port,
            "ca_file": str(self.root / "ca.pem"),
            "script": SCRIPT,
        }

    def stats(self):
        with self.lock:
            return {"version": 1, "records": list(self.records), "active": len(self.connections)}

    def _uncertain_cleanup(self, failure):
        with self.lock:
            if self.cleanup_failure is None:
                self.cleanup_failure = failure
        if self not in RETAINED_DEBT:
            RETAINED_DEBT.append(self)

    def _join(self, thread, deadline):
        try:
            thread.join(max(0, deadline - time.monotonic()))
        except BaseException as failure:
            # Interrupted native join acknowledgement cannot be repaired by
            # a later potentially stale Thread.is_alive observation.
            self._uncertain_cleanup(failure)
            raise

    def close(self):
        if self.cleanup_failure is not None:
            raise self.cleanup_failure
        if self.closed:
            return
        deadline = time.monotonic() + 3
        try:
            # A public start exception can follow actual native acquisition.
            # Missing ident/is_alive is never evidence that no child exists.
            for state in self.server_starts + self.server_shutdowns + self.request_starts:
                if not state["started"]:
                    if state["failure"] is not None:
                        raise state["failure"]
                    raise RuntimeError("PAC source thread start acknowledgement refused")
            self.stop.set()
            with self.lock:
                connections = list(self.connections)
            for connection in connections:
                with contextlib.suppress(OSError):
                    connection.shutdown(socket.SHUT_RDWR)
                try:
                    connection.close()
                except BaseException as failure:
                    self._uncertain_cleanup(failure)
                    raise
            # Shutdown acknowledgement is itself retained and bounded; failure
            # never releases temporary keys under a still-running native owner.
            for state in self.server_starts:
                server = state["server"]
                if any(owned["server"] is server for owned in self.server_shutdowns):
                    continue
                owned = {
                    "server": server,
                    "attempted": False,
                    "started": False,
                    "returned": False,
                    "failure": None,
                }

                def shutdown(owned=owned):
                    try:
                        owned["server"].shutdown()
                        owned["returned"] = True
                    except BaseException as failure:
                        owned["failure"] = failure

                thread = threading.Thread(target=shutdown)
                owned["worker"] = thread
                self.server_shutdowns.append(owned)
                self.shutdown_threads.append(thread)
                try:
                    owned["attempted"] = True
                    thread.start()
                    owned["started"] = True
                except BaseException as failure:
                    owned["failure"] = failure
                    raise
            for state in self.server_shutdowns:
                self._join(state["worker"], deadline)
                if state["failure"] is not None:
                    raise state["failure"]
                if not state["returned"] or state["worker"].is_alive():
                    raise RuntimeError("PAC source shutdown retirement refused")
            for state in self.server_starts:
                self._join(state["worker"], deadline)
                if state["worker"].is_alive():
                    raise RuntimeError("PAC source serving retirement refused")
            with self.lock:
                requests = list(self.request_starts)
            for state in requests:
                if not state["started"]:
                    raise state["failure"] or RuntimeError("PAC source request start refused")
                thread = state["worker"]
                self._join(thread, deadline)
                if thread.is_alive():
                    raise RuntimeError("PAC source request retirement refused")
            # Accept loops and all request owners are physically joined.
            for server in self.servers:
                try:
                    server.server_close()
                except BaseException as failure:
                    self._uncertain_cleanup(failure)
                    raise
            if self.cleanup_failure is not None:
                raise self.cleanup_failure
            try:
                self.directory.cleanup()
            except BaseException as failure:
                self._uncertain_cleanup(failure)
                raise
        except BaseException:
            if self not in RETAINED_DEBT:
                RETAINED_DEBT.append(self)
            raise
        self.closed = True
        if self in RETAINED_DEBT:
            RETAINED_DEBT.remove(self)


def main():
    fixture = SourceFixture()
    try:
        print(json.dumps(fixture.profile()), flush=True)
        while True:
            line = sys.stdin.readline(65537)
            if not line:
                break
            if (
                len(line) > 65536
                or not line.endswith("\n")
                or json.loads(line) != {"command": "stats"}
            ):
                raise RuntimeError("PAC source fixture command refused")
            print(json.dumps(fixture.stats()), flush=True)
    finally:
        fixture.close()
    print(json.dumps({"version": 1, "closed": True}), flush=True)


if __name__ == "__main__":
    main()
