"""Real TLS origin and CONNECT peers for the native NSURLSession executor.

The macOS receiving role owns one private CA/keychain.
It never modifies system proxy settings or DNS. The reserved origin name is
resolved only by the owned CONNECT recipient. stdin EOF/parent loss retires
listeners, connections and owned trust before its terminal receipt.
The portable role exercises real peers without claiming native Apple acceptance.
"""

import http.server
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class FixtureFailure(RuntimeError):
    pass


class WireFixture:
    def __init__(self, native=True):
        self.native = native
        self.closed = False
        self.root = Path(tempfile.mkdtemp(prefix="ergopti-native-http-wire-"))
        os.chmod(self.root, 0o700)
        self.host = "ergopti-native-" + uuid.uuid4().hex + ".test"
        self.keychain = self.root / "owned.keychain-db"
        self.ca = self.root / "ca.pem"
        self.trust_attempted = False
        self.keychain_created = False
        self.servers = []
        self.started_servers = []
        self.connections = set()
        self.records = []
        self.routes = {}
        self.lock = threading.Lock()
        # Fixed, bounded receiving counters never include targets or payloads.
        self.receiving_counts = dict.fromkeys(
            (
                "accept_origin",
                "accept_proxy",
                "accept_socks",
                "accept_pac",
                "handshake_started",
                "handshake_complete",
                "handshake_refused",
                "request_origin",
                "request_pac",
                "connect_complete",
                "connect_refused",
            ),
            0,
        )
        self.groups = None
        try:
            if native:
                if sys.platform != "darwin":
                    raise FixtureFailure("Native wire acceptance requires macOS")
                helper = (
                    Path(__file__).resolve().parents[5] / "tools/diagnostics/macos_owned_process.py"
                )
                spec = importlib.util.spec_from_file_location("wire_owned_native", helper)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                self.groups = module
                self.native_groups = module.NativeProcessGroups()
            self._certificates()
            self._servers()
            if native:
                self.keychain_created = True
                password = uuid.uuid4().hex
                self._command(
                    ["/usr/bin/security", "create-keychain", "-p", password, str(self.keychain)]
                )
                self._command(
                    ["/usr/bin/security", "unlock-keychain", "-p", password, str(self.keychain)]
                )
                _, current = self._command(["/usr/bin/security", "list-keychains", "-d", "user"])
                self.foreign_keychains = tuple(
                    path for path in shlex.split(current.decode()) if path != str(self.keychain)
                )
                if str(self.keychain) not in shlex.split(current.decode()):
                    self._command(
                        [
                            "/usr/bin/security",
                            "list-keychains",
                            "-d",
                            "user",
                            "-s",
                            *self.foreign_keychains,
                            str(self.keychain),
                        ]
                    )
        except BaseException:
            self.close()
            raise

    def _command(self, arguments, input_bytes=b"", tolerate=False, timeout=15):
        with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as errors:
            if self.groups:
                owned = None

                def register(value):
                    nonlocal owned
                    owned = value

                try:
                    self.groups.acquire_owned(
                        arguments,
                        self.native_groups,
                        register,
                        stdin=subprocess.PIPE,
                        stdout=output,
                        stderr=errors,
                    )
                    owned.process.stdin.write(input_bytes)
                    owned.process.stdin.close()
                    owned.wait_for_exit(timeout)
                finally:
                    if owned is not None and not owned.settle():
                        raise FixtureFailure("Native fixture child closure refused")
                status = owned.process.returncode
            else:
                child = subprocess.Popen(
                    arguments, stdin=subprocess.PIPE, stdout=output, stderr=errors
                )
                try:
                    child.communicate(input_bytes, timeout=timeout)
                finally:
                    if child.poll() is None:
                        child.kill()
                    child.wait()
                status = child.returncode
            if status != 0 and not tolerate:
                raise FixtureFailure("Native fixture command refused")
            output.seek(0)
            return status, output.read(65536)

    def _certificates(self):
        config = self.root / "cert.conf"
        config.write_text(
            "[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=ca\n"
            "[dn]\nCN=Ergopti owned native wire CA\n[ca]\nbasicConstraints=critical,CA:TRUE\n"
            "keyUsage=critical,keyCertSign,cRLSign\n[server]\nbasicConstraints=critical,CA:FALSE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"
            f"subjectAltName=DNS:{self.host},IP:127.0.0.1\n",
            encoding="utf-8",
        )
        openssl = "/usr/bin/openssl"
        self._command(
            [
                openssl,
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-config",
                str(config),
                "-keyout",
                str(self.root / "ca.key"),
                "-out",
                str(self.ca),
            ]
        )
        self._command(
            [
                openssl,
                "req",
                "-new",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-subj",
                "/CN=" + self.host,
                "-keyout",
                str(self.root / "server.key"),
                "-out",
                str(self.root / "server.csr"),
            ]
        )
        self._command(
            [
                openssl,
                "x509",
                "-req",
                "-days",
                "1",
                "-in",
                str(self.root / "server.csr"),
                "-CA",
                str(self.ca),
                "-CAkey",
                str(self.root / "ca.key"),
                "-CAcreateserial",
                "-extfile",
                str(config),
                "-extensions",
                "server",
                "-out",
                str(self.root / "server.pem"),
            ]
        )
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(self.root / "server.pem", self.root / "server.key")

    def trust(self, enabled):
        if not self.native:
            raise FixtureFailure("Portable fixture does not alter native trust")
        if enabled:
            self.trust_attempted = True
            self._command(
                [
                    "/usr/bin/sudo",
                    "-n",
                    "/usr/bin/security",
                    "add-trusted-cert",
                    "-d",
                    "-r",
                    "trustRoot",
                    "-k",
                    str(self.keychain),
                    str(self.ca),
                ]
            )
        elif self.trust_attempted:
            self._command(
                [
                    "/usr/bin/sudo",
                    "-n",
                    "/usr/bin/security",
                    "remove-trusted-cert",
                    "-d",
                    str(self.ca),
                ]
            )
            self.trust_attempted = False

    def _track(self, connection, enabled):
        with self.lock:
            if enabled:
                self.connections.add(connection)
            else:
                self.connections.discard(connection)

    def _receive(self, name):
        with self.lock:
            if name not in self.receiving_counts:
                raise FixtureFailure("Unknown native receiving counter")
            self.receiving_counts[name] = min(65535, self.receiving_counts[name] + 1)

    def receiving_facts(self):
        with self.lock:
            return {
                "version": 1,
                "active": min(65535, len(self.connections)),
                **self.receiving_counts,
            }

    def _servers(self):
        owner = self

        class Server(socketserver.ThreadingTCPServer):
            allow_reuse_address = True
            daemon_threads = True
            block_on_close = False
            receiving_kind = "proxy"

            def get_request(self):
                connection, address = super().get_request()
                owner._receive("accept_" + self.receiving_kind)
                return connection, address

        class Origin(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                owner._track(self.connection, True)

            def finish(self):
                try:
                    super().finish()
                finally:
                    self.connection.close()
                    owner._track(self.connection, False)

            def log_message(self, *_):
                pass

            def do_GET(self):
                owner._receive("request_origin")
                with owner.lock:
                    route = owner.routes.get(self.client_address[1], "direct")
                    owner.records.append({"event": "origin", "route": route, "path": self.path})
                if self.path in ("/held?case=eight", "/truncated?case=nine"):
                    self.send_response(200)
                    self.send_header(
                        "Content-Length", "1048576" if self.path == "/held?case=eight" else "20"
                    )
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(b"short")
                    self.wfile.flush()
                    if self.path == "/held?case=eight":
                        self.connection.settimeout(3)
                        try:
                            eof = self.connection.recv(1) == b""
                        except (ConnectionResetError, ssl.SSLEOFError):
                            eof = True
                        except OSError:
                            eof = False
                        with owner.lock:
                            owner.records.append({"event": "held_closed", "eof": eof})
                    self.close_connection = True
                    return
                if self.path in ("/redirect?case=five", "/downgrade?case=six"):
                    self.send_response(302)
                    location = (
                        f"https://{owner.host}:{owner.origin_port}/beta?case=two"
                        if self.path == "/redirect?case=five"
                        else f"http://{owner.host}:{owner.origin_port}/blocked"
                    )
                    self.send_header("Location", location)
                    self.send_header("Content-Length", "1048576")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.flush()
                    # The receiver must close on redirect headers. No full body
                    # or successful origin EOF is offered to a late successor.
                    self.connection.settimeout(3)
                    try:
                        eof = self.connection.recv(1) == b""
                    except (ConnectionResetError, ssl.SSLEOFError):
                        eof = True
                    except OSError:
                        eof = False
                    with owner.lock:
                        owner.records.append(
                            {"event": "redirect_closed", "path": self.path, "eof": eof}
                        )
                    self.close_connection = True
                    return
                payload = b"owned\x00native\xffwire"
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()
                self.close_connection = True

        class TLSOrigin(Server):
            receiving_kind = "origin"

            def get_request(self):
                raw, address = super().get_request()
                try:
                    raw.settimeout(10)
                    owner._receive("handshake_started")
                    connection = owner.context.wrap_socket(raw, server_side=True)
                    owner._receive("handshake_complete")
                    return connection, address
                except BaseException:
                    owner._receive("handshake_refused")
                    raw.close()
                    raise

            def handle_error(self, *_):
                pass  # The deliberate untrusted-CA test fails before HTTP.

        origin = TLSOrigin(("127.0.0.1", 0), Origin)
        self.origin_port = origin.server_address[1]
        self.servers.append(origin)

        def proxy_handler(label, auth=False):
            class Proxy(socketserver.BaseRequestHandler):
                def handle(self):
                    incoming = self.request
                    outgoing = None
                    owner._track(incoming, True)
                    try:
                        incoming.settimeout(10)
                        request = bytearray()
                        while not request.endswith(b"\r\n\r\n") and len(request) < 65536:
                            data = incoming.recv(1)
                            if not data:
                                return
                            request += data
                        first = bytes(request).split(b"\r\n", 1)[0]
                        expected = f"CONNECT {owner.host}:{owner.origin_port} HTTP/1.1".encode()
                        if first != expected:
                            owner._receive("connect_refused")
                            raise FixtureFailure("Proxy received a different target or method")
                        with owner.lock:
                            owner.records.append({"event": "connect", "route": label})
                        if auth:
                            incoming.sendall(
                                b'HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm="owned"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
                            )
                            owner._receive("connect_refused")
                            return
                        outgoing = socket.create_connection(
                            ("127.0.0.1", owner.origin_port), timeout=10
                        )
                        owner._track(outgoing, True)
                        with owner.lock:
                            owner.routes[outgoing.getsockname()[1]] = label
                        incoming.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                        owner._receive("connect_complete")
                        while True:
                            ready, _, _ = select.select([incoming, outgoing], [], [], 10)
                            if not ready:
                                return
                            for reader in ready:
                                data = reader.recv(65535)
                                if not data:
                                    return
                                (outgoing if reader is incoming else incoming).sendall(data)
                    except (OSError, FixtureFailure):
                        pass
                    finally:
                        if outgoing:
                            outgoing.close()
                            owner._track(outgoing, False)
                        try:
                            incoming.shutdown(socket.SHUT_RDWR)
                        except OSError:
                            pass
                        incoming.close()
                        owner._track(incoming, False)

            return Proxy

        self.ports = {}
        for label in ("first", "second", "auth"):
            server = Server(("127.0.0.1", 0), proxy_handler(label, label == "auth"))
            self.servers.append(server)
            self.ports[label] = server.server_address[1]

        class SOCKS5(socketserver.BaseRequestHandler):
            def handle(self):
                incoming = self.request
                outgoing = None
                owner._track(incoming, True)

                def exact(count):
                    result = bytearray()
                    while len(result) < count:
                        part = incoming.recv(count - len(result))
                        if not part:
                            raise FixtureFailure("SOCKS5 peer truncated its protocol")
                        result += part
                    return bytes(result)

                try:
                    incoming.settimeout(10)
                    greeting = exact(2)
                    if greeting[0] != 5 or greeting[1] == 0:
                        raise FixtureFailure("SOCKS5 peer version refused")
                    methods = exact(greeting[1])
                    with owner.lock:
                        owner.records.append(
                            {"event": "socks_greeting", "version": 5, "methods": list(methods)}
                        )
                    if 0 not in methods:
                        incoming.sendall(b"\x05\xff")
                        return
                    # Fragmented replies exercise the actual native consumer;
                    # all bytes below are literal SOCKS5 wire specifications.
                    incoming.sendall(b"\x05")
                    incoming.sendall(b"\x00")
                    prefix = exact(4)
                    if prefix != b"\x05\x01\x00\x03":
                        raise FixtureFailure("SOCKS5 peer must preserve remote DNS authority")
                    length = exact(1)[0]
                    target = exact(length).decode("ascii")
                    port_bytes = exact(2)
                    port = int.from_bytes(port_bytes, "big")
                    if target != owner.host or port != owner.origin_port:
                        raise FixtureFailure(
                            "SOCKS5 peer target differs from the owned TLS authority"
                        )
                    with owner.lock:
                        owner.records.append(
                            {
                                "event": "socks_connect",
                                "version": 5,
                                "command": 1,
                                "reserved": 0,
                                "address_type": 3,
                                "target": target,
                                "port": port,
                            }
                        )
                    outgoing = socket.create_connection(
                        ("127.0.0.1", owner.origin_port), timeout=10
                    )
                    owner._track(outgoing, True)
                    with owner.lock:
                        owner.routes[outgoing.getsockname()[1]] = "socks"
                    reply = b"\x05\x00\x00\x01\x7f\x00\x00\x01" + outgoing.getsockname()[
                        1
                    ].to_bytes(2, "big")
                    incoming.sendall(reply[:3])
                    incoming.sendall(reply[3:])
                    while True:
                        ready, _, _ = select.select([incoming, outgoing], [], [], 10)
                        if not ready:
                            return
                        for reader in ready:
                            data = reader.recv(65535)
                            if not data:
                                return
                            (outgoing if reader is incoming else incoming).sendall(data)
                except (OSError, UnicodeError, FixtureFailure):
                    pass
                finally:
                    if outgoing:
                        outgoing.close()
                        owner._track(outgoing, False)
                    try:
                        incoming.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    incoming.close()
                    owner._track(incoming, False)

        socks = Server(("127.0.0.1", 0), SOCKS5)
        socks.receiving_kind = "socks"
        self.servers.append(socks)
        self.ports["socks"] = socks.server_address[1]
        # An owned bound non-listening socket proves ECONNREFUSED while keeping
        # its port unavailable to an unrelated process throughout the test.
        self.refused = socket.socket()
        self.refused.bind(("127.0.0.1", 0))
        self.ports["refused"] = self.refused.getsockname()[1]
        self.pac = (
            "function FindProxyForURL(url, host) { "
            + "".join(
                "if (url == "
                + json.dumps(f"https://{self.host}:{self.origin_port}{path}")
                + ") return "
                + json.dumps(route)
                + "; "
                for path, route in [
                    ("/alpha?case=one", f"PROXY 127.0.0.1:{self.ports['first']}"),
                    ("/beta?case=two", f"PROXY 127.0.0.1:{self.ports['second']}"),
                    (
                        "/fallback?case=three",
                        f"PROXY 127.0.0.1:{self.ports['refused']}; PROXY 127.0.0.1:{self.ports['first']}",
                    ),
                    (
                        "/auth?case=four",
                        f"PROXY 127.0.0.1:{self.ports['auth']}; PROXY 127.0.0.1:{self.ports['second']}",
                    ),
                    (
                        "/certificate?case=seven",
                        f"PROXY 127.0.0.1:{self.ports['first']}; PROXY 127.0.0.1:{self.ports['second']}",
                    ),
                    ("/redirect?case=five", f"PROXY 127.0.0.1:{self.ports['first']}"),
                    ("/downgrade?case=six", f"PROXY 127.0.0.1:{self.ports['first']}"),
                    (
                        "/held?case=eight",
                        f"PROXY 127.0.0.1:{self.ports['first']}; PROXY 127.0.0.1:{self.ports['second']}",
                    ),
                    (
                        "/truncated?case=nine",
                        f"PROXY 127.0.0.1:{self.ports['first']}; PROXY 127.0.0.1:{self.ports['second']}",
                    ),
                    ("/socks?case=ten", f"SOCKS 127.0.0.1:{self.ports['socks']}"),
                ]
            )
            + f'return "PROXY 127.0.0.1:{self.ports["refused"]}"; }}'
        )

        class PAC(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                owner._receive("request_pac")
                if self.path != "/wpad.dat":
                    self.send_error(404)
                    return
                body = owner.pac.encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/x-ns-proxy-autoconfig")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        pac_server = Server(("127.0.0.1", 0), PAC)
        pac_server.receiving_kind = "pac"
        self.servers.append(pac_server)
        self.pac_url = f"http://127.0.0.1:{pac_server.server_address[1]}/wpad.dat"
        for server in self.servers:
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.started_servers.append(server)

    def profile(self):
        return {
            "version": 1,
            "host": self.host,
            "origin_port": self.origin_port,
            "ports": self.ports,
            "pac": self.pac,
            "pac_url": self.pac_url,
        }

    def stats(self):
        limit = time.monotonic() + 3
        while time.monotonic() < limit:
            with self.lock:
                if not self.connections:
                    return {"version": 1, "records": list(self.records), "active": 0}
            time.sleep(0.01)
        with self.lock:
            return {"version": 1, "records": list(self.records), "active": len(self.connections)}

    def close(self):
        if self.closed:
            return
        failures = []
        for server in self.servers:
            if server in self.started_servers:
                server.shutdown()
            server.server_close()
        with self.lock:
            connections = list(self.connections)
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()
        if hasattr(self, "refused"):
            self.refused.close()
        if self.trust_attempted:
            try:
                self.trust(False)
            except BaseException:
                failures.append("trust")
        if self.keychain_created:
            try:
                self._command(["/usr/bin/security", "delete-keychain", str(self.keychain)])
                _, current = self._command(["/usr/bin/security", "list-keychains", "-d", "user"])
                remaining = shlex.split(current.decode())
                if str(self.keychain) in remaining or any(
                    path not in remaining for path in getattr(self, "foreign_keychains", ())
                ):
                    raise FixtureFailure(
                        "Owned native fixture keychain search-list restoration refused"
                    )
                self.keychain_created = False
            except BaseException:
                failures.append("keychain")
        if failures:
            # Keep the private fixture packet when restoration is incomplete.
            raise FixtureFailure("Owned native fixture restoration refused")
        import shutil

        shutil.rmtree(self.root)
        self.closed = True


def main():
    parent = os.getppid()
    fixture = None

    def interrupted(*_):
        raise FixtureFailure("Native fixture cancelled")

    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, interrupted)
    try:
        fixture = WireFixture()
        print(json.dumps(fixture.profile()), flush=True)
        while os.getppid() == parent:
            ready, _, _ = select.select([sys.stdin], [], [], 0.1)
            if not ready:
                continue
            line = sys.stdin.buffer.readline(65537)
            if not line or len(line) > 65536:
                break
            command = json.loads(line)
            if command == {"command": "trust", "enabled": True}:
                fixture.trust(True)
                result = {"version": 1, "trusted": True}
            elif command == {"command": "trust", "enabled": False}:
                fixture.trust(False)
                result = {"version": 1, "trusted": False}
            elif command == {"command": "stats"}:
                result = fixture.stats()
            elif command == {"command": "stop"}:
                break
            else:
                raise FixtureFailure("Native fixture command refused")
            print(json.dumps(result), flush=True)
    except (FixtureFailure, OSError, ValueError):
        raise SystemExit("Native HTTP wire fixture refused") from None
    finally:
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, signal.SIG_IGN)
        closed = False
        if fixture:
            fixture.close()
            closed = True
        print(json.dumps({"version": 1, "closed": closed}), flush=True)


if __name__ == "__main__":
    main()
