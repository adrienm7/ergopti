"""Real TLS origin and CONNECT peers for the native NSURLSession executor.

The macOS receiving role owns one private CA file. It never modifies system
trust, keychains, proxy settings or DNS: a trusted request receives that CA
through the product's SSL_CERT_FILE enterprise-anchor channel, so no admin or
user authorization prompt is ever involved. The reserved origin name is
resolved only by the owned CONNECT recipient. stdin EOF/parent loss retires
listeners and connections before its terminal receipt.
The portable role exercises real peers without claiming native Apple acceptance.
"""

import http.server
import importlib.util
import json
import os
from pathlib import Path
import select
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


# An explicit private media type: CFNetwork does not sniff a declared body type.
WIRE_BODY_TYPE = "application/x-ergopti-native-wire"


class FixtureFailure(RuntimeError):
    pass


class CommandInputOwner:
    """Observe exact parent close even when communicate suppresses its error."""

    def __init__(self, owner):
        self.owner = owner
        self.close_failure = None
        self.close_uncertain = False

    def __getattr__(self, name):
        return getattr(self.owner, name)

    def close(self):
        if self.close_uncertain:
            raise FixtureFailure("Native fixture input close uncertainty remains")
        try:
            self.owner.close()
            if not self.owner.closed:
                raise FixtureFailure("Native fixture input close did not retire its owner")
        except BaseException as failure:
            self.close_failure = self.close_failure or failure
            self.close_uncertain = self.owner.closed
            raise


class WireFixture:
    def __init__(self, native=True):
        self.native = native
        self.closed = False
        self.root = Path(tempfile.mkdtemp(prefix="ergopti-native-http-wire-"))
        os.chmod(self.root, 0o700)
        self.host = "ergopti-native-" + uuid.uuid4().hex + ".test"
        self.ca = self.root / "ca.pem"
        self.command_file_debt = []
        self.command_group_debt = []
        self.servers = []
        self.started_servers = []
        self.server_threads = []
        self.server_starts = []
        self.server_shutdowns = []
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
        except BaseException:
            self.close()
            raise

    def _command(
        self,
        arguments,
        input_bytes=b"",
        timeout=15,
        deadline=None,
        passive_receiving=None,
    ):
        phase = "setup"
        status = None
        self.command_fact = None
        output = errors = owned = child = input_owner = input_observer = None
        failure = None
        result = None
        closure_refused = False
        group_settled = False
        try:
            if self.command_file_debt:
                phase = "settle"
                raise FixtureFailure("Native fixture command file closure debt remains")
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(arguments, timeout)
            if getattr(self, "command_group_debt", ()):
                phase = "settle"
                closure_refused = True
                raise FixtureFailure("Native fixture child closure debt remains")
            output = tempfile.TemporaryFile()
            errors = tempfile.TemporaryFile()
            if self.groups:

                def register(value):
                    nonlocal owned
                    owned = value
                    self.command_group_debt.append(value)

                try:
                    phase = "acquire"
                    self.groups.acquire_owned(
                        arguments,
                        self.native_groups,
                        register,
                        stdin=subprocess.PIPE,
                        stdout=output,
                        stderr=errors,
                    )
                    phase = "input"
                    owned.process.stdin.write(input_bytes)
                    try:
                        owned.process.stdin.close()
                    except BaseException:
                        closure_refused = True
                        if owned.process.stdin.closed:
                            self.command_file_debt.append(
                                {
                                    "stream": owned.process.stdin,
                                    "uncertain": True,
                                }
                            )
                        raise
                    phase = "wait"
                    wait_timeout = (
                        timeout if deadline is None else max(0, deadline - time.monotonic())
                    )
                    owned.wait_for_exit(wait_timeout)
                except BaseException as primary:
                    failure = primary
                finally:
                    try:
                        if owned is not None:
                            # Registration may have been interrupted after local
                            # acquisition. Retain that same owner before its sole
                            # original settlement attempt.
                            if not any(value is owned for value in self.command_group_debt):
                                self.command_group_debt.append(owned)
                            group_settled = owned.settle()
                            if group_settled is not True:
                                raise FixtureFailure("Native fixture child closure refused")
                    except BaseException as refused:
                        phase = "settle"
                        closure_refused = True
                        if failure is None:
                            failure = refused
                if failure is not None:
                    raise failure
                status = owned.process.returncode
            else:
                phase = "acquire"
                child = subprocess.Popen(
                    arguments,
                    stdin=subprocess.PIPE,
                    stdout=output,
                    stderr=errors,
                )
                input_owner = child.stdin
                input_observer = CommandInputOwner(input_owner)
                child.stdin = input_observer
                try:
                    phase = "wait"
                    wait_timeout = (
                        timeout if deadline is None else max(0, deadline - time.monotonic())
                    )
                    child.communicate(input_bytes, timeout=wait_timeout)
                except BaseException as primary:
                    failure = primary
                finally:
                    if input_observer.close_failure is not None:
                        closure_refused = True
                        if failure is None:
                            failure = input_observer.close_failure
                    try:
                        if child.poll() is None:
                            child.kill()
                        child.wait()
                    except BaseException as refused:
                        phase = "settle"
                        closure_refused = True
                        if failure is None:
                            failure = refused
                if failure is not None:
                    raise failure
                status = child.returncode
            phase = "exit"
            if status != 0:
                raise FixtureFailure("Native fixture command refused")
            output.seek(0)
            result = status, output.read(65536)
        except BaseException as refused:
            if failure is None:
                failure = refused
        finally:
            process = owned.process if owned is not None else child
            if input_observer is not None and input_observer.close_uncertain:
                self.command_file_debt.append({"stream": input_owner, "uncertain": True})
            streams = (
                input_owner if input_owner is not None else getattr(process, "stdin", None),
                errors,
                output,
            )
            for stream in streams:
                if stream is None or any(
                    debt["stream"] is stream and debt["uncertain"]
                    for debt in self.command_file_debt
                ):
                    continue
                try:
                    if not stream.closed:
                        stream.close()
                except BaseException as refused:
                    closure_refused = True
                    if failure is None:
                        failure = refused
                    if stream.closed and not any(
                        value["stream"] is stream for value in self.command_file_debt
                    ):
                        self.command_file_debt.append({"stream": stream, "uncertain": True})
                if not stream.closed:
                    closure_refused = True
                    if not any(value["stream"] is stream for value in self.command_file_debt):
                        self.command_file_debt.append({"stream": stream, "uncertain": False})
            if closure_refused and failure is None:
                failure = FixtureFailure("Native fixture command file closure refused")
        if group_settled is True:
            # Only this original owner's strong settlement ACK retires its record.
            for index, value in enumerate(self.command_group_debt):
                if value is owned:
                    del self.command_group_debt[index]
                    break
        self.command_fact = {
            "phase": "settle"
            if closure_refused
            else "deadline"
            if isinstance(failure, subprocess.TimeoutExpired)
            else phase
            if failure is not None
            else "complete",
            "status": status if type(status) is int and -65535 <= status <= 65535 else None,
        }
        # Optional receiving observes this same local owner only after its
        # original literalTrue ACK and original three capture closures. It has
        # no retirement authority and cannot pay debt or change a primary.
        if passive_receiving is not None:
            try:
                if (
                    group_settled is True
                    and owned is not None
                    and owned.reaped is True
                    and not closure_refused
                    and all(stream is not None and stream.closed is True for stream in streams)
                    and not self.command_file_debt
                    and not self.command_group_debt
                ):
                    receipt = owned.receipt()
                    if (
                        type(receipt) is not dict
                        or set(receipt)
                        != {
                            "worker_pid",
                            "group_id",
                            "closed",
                            "reservation_lost",
                            "signals",
                            "live_group_members",
                            "escaped_sessions_managed",
                        }
                        or type(receipt["worker_pid"]) is not int
                        or not 0 < receipt["worker_pid"] <= 2_147_483_647
                        or receipt["worker_pid"] != owned.process.pid
                        or type(receipt["group_id"]) is not int
                        or receipt["group_id"] != receipt["worker_pid"]
                        or any(
                            type(receipt[key]) is not bool
                            for key in (
                                "closed",
                                "reservation_lost",
                                "escaped_sessions_managed",
                            )
                        )
                        or type(receipt["signals"]) is not list
                        or len(receipt["signals"]) > 2
                        or any(
                            type(value) is not int or value not in (15, 9)
                            for value in receipt["signals"]
                        )
                        or type(receipt["live_group_members"]) is not list
                        or receipt["live_group_members"]
                    ):
                        raise FixtureFailure("Native fixture passive receipt bound refused")
                    receipt = {
                        **receipt,
                        "signals": list(receipt["signals"]),
                        "live_group_members": [],
                    }
                    passive_receiving(
                        {
                            "version": 1,
                            "command": dict(self.command_fact),
                            "exit_status": owned.process.returncode,
                            "original_failed": failure is not None,
                            "literal_true_settlement": True,
                            "stdin_closed": True,
                            "stderr_closed": True,
                            "stdout_closed": True,
                            "command_group_debt": False,
                            "command_file_debt": False,
                            "owner": receipt,
                            "stdout": result[1] if result is not None else None,
                        }
                    )
            except BaseException as observation_failure:
                if failure is None and (
                    not isinstance(observation_failure, Exception)
                    or (
                        type(observation_failure) is FixtureFailure
                        and observation_failure.args == ("Native fixture cancelled",)
                    )
                ):
                    failure = observation_failure
        if failure is not None:
            raise failure
        return result

    def _retire_command_files(self):
        retained = []
        for debt in self.command_file_debt:
            stream = debt["stream"]
            # CPython may retire its descriptor before a native close error.
            # A closed marker cannot settle that uncertainty or authorize retry.
            if debt["uncertain"]:
                retained.append(debt)
                continue
            try:
                if not stream.closed:
                    stream.close()
            except BaseException:
                if stream.closed:
                    debt["uncertain"] = True
            if not stream.closed or debt["uncertain"]:
                retained.append(debt)
        self.command_file_debt = retained
        return not retained

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
                "-sha256",
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
                    # A typed body is delivered at its headers. Without a type,
                    # CFNetwork withholds the response to sniff more body bytes,
                    # so a held 5-byte prefix never reached the native client.
                    self.send_header("Content-Type", WIRE_BODY_TYPE)
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
                    # Untyped, this held redirect would also wait for sniffing.
                    self.send_header("Content-Type", WIRE_BODY_TYPE)
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
                self.send_header("Content-Type", WIRE_BODY_TYPE)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(payload)
                self.wfile.flush()
                self.close_connection = True

        class TLSOrigin(Server):
            receiving_kind = "origin"

            def finish_request(self, request, client_address):
                # The handshake runs in this request's own thread. In
                # get_request it held the accept loop, so one client stalled
                # mid-handshake kept every later connection waiting for its
                # ten-second timeout, as long as the receiving client's own.
                try:
                    request.settimeout(10)
                    owner._receive("handshake_started")
                    connection = owner.context.wrap_socket(request, server_side=True)
                    owner._receive("handshake_complete")
                except BaseException:
                    owner._receive("handshake_refused")
                    request.close()
                    return
                try:
                    super().finish_request(connection, client_address)
                finally:
                    self.shutdown_request(connection)

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
        # Idle server polling must not consume the original bounded shutdown.
        server_poll_interval_seconds = 0.05
        for server in self.servers:
            worker = threading.Thread(
                target=server.serve_forever,
                kwargs={"poll_interval": server_poll_interval_seconds},
                daemon=True,
            )
            self.server_threads.append((server, worker))
            state = {"server": server, "worker": worker, "started": False, "failure": None}
            self.server_starts.append(state)
            try:
                worker.start()
                state["started"] = True
            except BaseException as failure:
                state["failure"] = failure
                raise
            self.started_servers.append(server)

    def profile(self):
        return {
            "version": 1,
            "host": self.host,
            "origin_port": self.origin_port,
            "ports": self.ports,
            "pac": self.pac,
            "pac_url": self.pac_url,
            "ca_file": str(self.ca),
        }

    def anchor_environment(self):
        """Return the enterprise-anchor variable that makes the origin trusted.

        Hosted runners cannot answer the authorization that a trust-settings
        change needs, so trust is granted per request through the same
        SSL_CERT_FILE contract a customer behind TLS inspection uses.
        """
        return {"SSL_CERT_FILE": str(self.ca)}

    def stats(self):
        limit = time.monotonic() + 3
        while time.monotonic() < limit:
            with self.lock:
                if not self.connections:
                    return {"version": 1, "records": list(self.records), "active": 0}
            time.sleep(0.01)
        with self.lock:
            return {"version": 1, "records": list(self.records), "active": len(self.connections)}

    def _retire_servers(self):
        # Public shutdown waits for the serving loop's acknowledgement. Start
        # all independent requests before waiting, so six idle poll intervals
        # do not accumulate; retain every exact worker across an interrupted
        # join or refusal. No socket is closed before both threads have retired.
        for state in self.server_shutdowns:
            if not state["started"]:
                if state["failure"] is not None:
                    raise state["failure"]
                raise FixtureFailure("Native fixture shutdown start closure refused")
        for state in self.server_starts:
            if not state["started"]:
                if state["failure"] is not None:
                    raise state["failure"]
                raise FixtureFailure("Native fixture server start closure refused")
        for server in self.started_servers:
            if any(state["server"] is server for state in self.server_shutdowns):
                continue
            state = {"server": server, "started": False, "returned": False, "failure": None}

            def shutdown(owned=state):
                try:
                    owned["server"].shutdown()
                    owned["returned"] = True
                except BaseException as failure:
                    owned["failure"] = failure

            worker = threading.Thread(target=shutdown, daemon=True)
            state["worker"] = worker
            self.server_shutdowns.append(state)
            try:
                worker.start()
                state["started"] = True
            except BaseException as failure:
                state["failure"] = failure
                raise
        for state in self.server_shutdowns:
            if not state["started"]:
                if state["failure"] is not None:
                    raise state["failure"]
                raise FixtureFailure("Native fixture shutdown start closure refused")
            state["worker"].join()
            if state["failure"] is not None:
                raise state["failure"]
            if not state["returned"] or state["worker"].is_alive():
                raise FixtureFailure("Native fixture shutdown closure refused")
        for server, worker in self.server_threads:
            if server in self.started_servers:
                worker.join()
                if worker.is_alive():
                    raise FixtureFailure("Native fixture serving thread closure refused")
        for server in self.servers:
            server.server_close()

    def close(self):
        if self.closed:
            return
        failures = []
        if not self._retire_command_files():
            failures.append("command")
        self._retire_servers()
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
        if getattr(self, "command_group_debt", ()):
            failures.append("child")
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
            if command == {"command": "stats"}:
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
