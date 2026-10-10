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
import re
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
        self.keychain = self.root / "owned.keychain-db"
        self.ca = self.root / "ca.pem"
        self.trust_attempted = False
        self.trust_query_executable = None
        self.authorization_observation = False
        self.command_file_debt = []
        self.keychain_created = False
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

    def _command(
        self,
        arguments,
        input_bytes=b"",
        tolerate=False,
        timeout=15,
        deadline=None,
        merge_errors=False,
        security_failure_observation=False,
    ):
        phase = "setup"
        status = None
        self.command_fact = None
        output = errors = owned = child = input_owner = input_observer = None
        failure = None
        result = None
        closure_refused = False
        security_failure = None
        try:
            if self.command_file_debt:
                phase = "settle"
                raise FixtureFailure("Native fixture command file closure debt remains")
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(arguments, timeout)
            output = tempfile.TemporaryFile()
            errors = tempfile.TemporaryFile()
            if self.groups:

                def register(value):
                    nonlocal owned
                    owned = value

                try:
                    phase = "acquire"
                    self.groups.acquire_owned(
                        arguments,
                        self.native_groups,
                        register,
                        stdin=subprocess.PIPE,
                        stdout=output,
                        stderr=output if merge_errors else errors,
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
                    owned.wait_for_exit(
                        timeout if deadline is None else max(0, deadline - time.monotonic())
                    )
                except BaseException as primary:
                    failure = primary
                finally:
                    try:
                        if owned is not None and not owned.settle():
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
                    stderr=output if merge_errors else errors,
                )
                input_owner = child.stdin
                input_observer = CommandInputOwner(input_owner)
                child.stdin = input_observer
                try:
                    phase = "wait"
                    child.communicate(
                        input_bytes,
                        timeout=timeout
                        if deadline is None
                        else max(0, deadline - time.monotonic()),
                    )
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
            if status != 0 and not tolerate:
                if security_failure_observation:
                    try:
                        errors.seek(0)
                        security_failure = self._security_failure_fact(errors.read(1025))
                    except (OSError, ValueError):
                        security_failure = {"version": 1, "observed": 0, "category": None}
                    except BaseException as observation_failure:
                        raise FixtureFailure(
                            "Native fixture command refused"
                        ) from observation_failure
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
        if security_failure is not None:
            # Closed categories are observations, never a command success or an
            # API OSStatus. Publication follows exact child and file retirement.
            if closure_refused:
                security_failure = {"version": 1, "observed": 0, "category": None}
            try:
                print(
                    "# native_http_security_failure "
                    + json.dumps({**security_failure, **self.command_fact}, sort_keys=True),
                    flush=True,
                )
            except BaseException as observation_failure:
                if failure is not None:
                    raise failure from observation_failure
                raise
        if failure is not None:
            raise failure
        return result

    @staticmethod
    def _security_failure_fact(raw):
        # Apple SecBase.cssmPerror prints exactly "callee: message\n". Keep
        # only the public removal callee, never its localized message or path.
        fact = {"version": 1, "observed": 0, "category": None}
        if not isinstance(raw, bytes) or len(raw) > 1024:
            return fact
        if re.fullmatch(rb"SecTrustSettingsRemoveTrustSettings: [\x20-\x7e]+\n", raw):
            fact.update(observed=1, category="trust_settings_remove")
        return fact

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
            # Observation, acquisition and physical query settlement all consume
            # the original removal budget. Neither refusal nor retry renews it.
            deadline = time.monotonic() + 15
            self._observe_admin_trust(deadline)
            if self.authorization_observation:
                self._observe_admin_authorization(deadline)
            arguments = [
                "/usr/bin/sudo",
                "-n",
                "/usr/bin/security",
                "remove-trusted-cert",
                "-d",
                str(self.ca),
            ]
            if time.monotonic() >= deadline:
                self.command_fact = {"phase": "deadline", "status": None}
                raise subprocess.TimeoutExpired(arguments, 15)
            self.command_fact = None
            try:
                self._command(arguments, deadline=deadline, security_failure_observation=True)
            except BaseException as primary:
                removal_fact = self.command_fact
                if removal_fact is not None and removal_fact["phase"] == "exit":
                    # A fresh read-only query can observe state after this exact
                    # retired CLI; it cannot erase the original failure/debt.
                    try:
                        self._observe_admin_trust(deadline, after=True)
                    except BaseException as observation_failure:
                        raise primary from observation_failure
                    finally:
                        self.command_fact = removal_fact
                raise
            self.trust_attempted = False

    @staticmethod
    def _admin_trust_fact(raw):
        if not isinstance(raw, bytes) or len(raw) > 1024:
            raise FixtureFailure("Native admin trust observation refused")

        def unique_fields(pairs):
            if len({key for key, _ in pairs}) != len(pairs):
                raise FixtureFailure("Native admin trust observation refused")
            return dict(pairs)

        try:
            fields = json.loads(raw, object_pairs_hook=unique_fields)
        except (ValueError, UnicodeError) as failure:
            raise FixtureFailure("Native admin trust observation refused") from failure
        if not isinstance(fields, dict) or set(fields) != {
            "version",
            "export_status",
            "entry_count",
            "owned_status",
            "owned_present",
        }:
            raise FixtureFailure("Native admin trust observation refused")
        if type(fields["version"]) is not int or fields["version"] != 1:
            raise FixtureFailure("Native admin trust observation refused")
        for key in ("export_status", "owned_status"):
            if type(fields[key]) is not int or not -(2**31) <= fields[key] < 2**31:
                raise FixtureFailure("Native admin trust observation refused")
        count, present = fields["entry_count"], fields["owned_present"]
        if count is not None and (type(count) is not int or not 0 <= count <= 65535):
            raise FixtureFailure("Native admin trust observation refused")
        if present is not None and (type(present) is not int or present not in (0, 1)):
            raise FixtureFailure("Native admin trust observation refused")
        expected_presence = (
            1
            if fields["owned_status"] == 0
            else 0
            if fields["owned_status"] in (-25300, -25263)
            else None
        )
        if present != expected_presence:
            raise FixtureFailure("Native admin trust observation refused")
        if fields["export_status"] == -25263:
            if count != 0:
                raise FixtureFailure("Native admin trust observation refused")
        elif fields["export_status"] != 0 and count is not None:
            raise FixtureFailure("Native admin trust observation refused")
        if present == 1 and count == 0:
            raise FixtureFailure("Native admin trust observation refused")
        return fields

    def _observe_admin_trust(self, deadline, *, after=False):
        if self.trust_query_executable is None:
            return
        fact = {"version": 1, "observed": 0}
        try:
            with self.ca.open("rb") as certificate:
                pem = certificate.read(16385)
            if len(pem) > 16384:
                raise FixtureFailure("Owned native CA observation refused")
            der = ssl.PEM_cert_to_DER_cert(pem.decode("ascii"))
            # The signed fixture worker is already owned and source-bound by the
            # receiving setup; this mode never changes trust or keychain state.
            _, output = self._command(
                [str(self.trust_query_executable), "--fixture-admin-trust-query"],
                input_bytes=der,
                deadline=min(deadline, time.monotonic() + 2),
            )
            fact = {"observed": 1, **self._admin_trust_fact(output)}
        except Exception:
            if self.command_fact and self.command_fact["phase"] == "settle":
                # Unknown output cannot retire an unsettled query's authority.
                raise
        try:
            prefix = "# native_http_admin_trust_after " if after else "# native_http_admin_trust "
            print(prefix + json.dumps(fact, sort_keys=True), flush=True)
        except (OSError, ValueError):
            pass

    @staticmethod
    def _admin_authorization_fact(status, raw):
        if type(status) is not int or not isinstance(raw, bytes) or len(raw) > 1024:
            raise FixtureFailure("Native admin authorization observation refused")
        # The public CLI defaults to noninteractive authorization. Its fixed
        # NO line carries the OSStatus that a mere shell exit code would lose.
        failed = re.fullmatch(rb"NO \((-?[0-9]+)\) \n", raw)
        if failed is not None:
            value = int(failed[1])
            if status != 255 or value == 0 or not -(2**31) <= value < 2**31:
                raise FixtureFailure("Native admin authorization observation refused")
        elif status == 0 and raw == b'YES (0) { 1: "com.apple.trust-settings.admin" } \n':
            value = 0
        else:
            raise FixtureFailure("Native admin authorization observation refused")
        return {
            "version": 1,
            "observed": 1,
            "command_status": status,
            "authorization_status": value,
            "interaction_allowed": 0,
        }

    def _observe_admin_authorization(self, deadline):
        fact = {"version": 1, "observed": 0, "interaction_allowed": 0}
        try:
            status, output = self._command(
                [
                    "/usr/bin/sudo",
                    "-n",
                    "/usr/bin/security",
                    "authorize",
                    "-P",
                    "com.apple.trust-settings.admin",
                ],
                tolerate=True,
                deadline=min(deadline, time.monotonic() + 2),
                merge_errors=True,
            )
            fact = self._admin_authorization_fact(status, output)
        except Exception:
            if self.command_fact and self.command_fact["phase"] == "settle":
                raise
        try:
            print(
                "# native_http_admin_authorization " + json.dumps(fact, sort_keys=True), flush=True
            )
        except (OSError, ValueError):
            pass

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
            worker = threading.Thread(target=server.serve_forever, daemon=True)
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

    def _report_restoration_failure(self, operation):
        fact = self.command_fact or {"phase": "unknown", "status": None}
        try:
            print(
                "# native_http_restoration_failure "
                + json.dumps({"version": 1, "operation": operation, **fact}, sort_keys=True),
                file=sys.stderr,
                flush=True,
            )
        except (OSError, ValueError):
            pass

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
        if self.trust_attempted:
            self.command_fact = None
            try:
                self.trust(False)
            except BaseException:
                failures.append("trust")
                self._report_restoration_failure("trust")
        if self.keychain_created:
            self.command_fact = None
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
                self._report_restoration_failure("keychain")
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
