"""Portable physical peers and passive owned-child receiving facts."""

import importlib.util
import contextlib
import io
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
import urllib.request
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SUPPORT = ROOT / "static/ergopti_plus/macos/tests/support"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


WIRE = load("receiving_fact_wire", SUPPORT / "native_http_wire_fixture.py")
CLIENT = load("receiving_fact_client", SUPPORT / "native_http_wire_client_receiving.py")


class NativeHTTPReceivingFactsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

    def wait_counter(self, name, value):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            if self.fixture.receiving_facts()[name] == value:
                return
            time.sleep(0.01)
        self.assertEqual(self.fixture.receiving_facts()[name], value)

    def proxy(self):
        raw = socket.create_connection(("127.0.0.1", self.fixture.ports["first"]), timeout=3)
        raw.sendall(
            f"CONNECT {self.fixture.host}:{self.fixture.origin_port} HTTP/1.1\r\n\r\n".encode()
        )
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            part = raw.recv(1)
            self.assertTrue(part)
            header.extend(part)
        self.assertIn(b"200 Connection Established", header)
        return raw

    def test01RealProxyTLSOriginCountsWithoutChangingOriginalRecords(self):
        context = ssl.create_default_context(cafile=str(self.fixture.ca))
        with self.proxy() as raw:
            with context.wrap_socket(raw, server_hostname=self.fixture.host) as tls:
                tls.sendall(b"GET /alpha?case=one HTTP/1.0\r\n\r\n")
                response = bytearray()
                while part := tls.recv(4096):
                    response.extend(part)
        self.assertEqual(response.split(b"\r\n\r\n", 1)[1], b"owned\x00native\xffwire")
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertEqual(
            snapshot["records"],
            [
                {"event": "connect", "route": "first"},
                {"event": "origin", "route": "first", "path": "/alpha?case=one"},
            ],
        )
        facts = self.fixture.receiving_facts()
        for key in (
            "accept_proxy",
            "accept_origin",
            "handshake_started",
            "handshake_complete",
            "request_origin",
            "connect_complete",
        ):
            self.assertEqual(facts[key], 1)
        self.assertEqual(facts["handshake_refused"], 0)

    def test02ActualUntrustedHandshakeHasNoOriginRequest(self):
        with self.proxy() as raw:
            with self.assertRaises(ssl.SSLCertVerificationError):
                ssl.create_default_context().wrap_socket(raw, server_hostname=self.fixture.host)
        self.wait_counter("handshake_refused", 1)
        self.assertEqual(self.fixture.stats()["active"], 0)
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["handshake_started"], 1)
        self.assertEqual(facts["handshake_complete"], 0)
        self.assertEqual(facts["request_origin"], 0)

    def test03MalformedConnectIsObservedWithoutRelaxingStrictRecipient(self):
        with socket.create_connection(("127.0.0.1", self.fixture.ports["first"]), timeout=3) as raw:
            raw.sendall(b"CONNECT wrong.invalid:443 HTTP/1.0\r\n\r\n")
            self.assertEqual(raw.recv(1), b"")
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["connect_refused"], 1)
        self.assertEqual(facts["connect_complete"], 0)
        self.assertEqual(self.fixture.stats()["records"], [])

    def test04ActualPACRequestCountsRemainSeparateFromTLS(self):
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(self.fixture.pac_url, timeout=3) as response:
            self.assertEqual(response.read().decode(), self.fixture.pac)
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_pac"], 1)
        self.assertEqual(facts["request_pac"], 1)
        self.assertEqual(facts["handshake_started"], 0)
        self.assertEqual(self.fixture.stats()["records"], [])

    def test05PassiveOwnerFactsRequireActualReapAndBothPipeClosures(self):
        process = subprocess.Popen(
            [sys.executable, "-c", "pass"], stdin=subprocess.PIPE, stdout=subprocess.PIPE
        )
        receiver = SimpleNamespace(_process=process, _closed=False)
        try:
            facts = CLIENT.worker_receiving_facts(receiver)
            self.assertEqual(facts["settled"], 0)
            process.communicate(timeout=3)
            facts = CLIENT.worker_receiving_facts(receiver)
            self.assertEqual(facts["reaped"], 1)
            self.assertEqual(facts["exit_complete"], 1)
            self.assertEqual(facts["exit_deadline"], 0)
            self.assertEqual(facts["exit_killed"], 0)
            self.assertEqual(facts["stdin_closed"], 1)
            self.assertEqual(facts["stdout_closed"], 1)
            self.assertEqual(facts["settled"], 0)
            receiver._closed = True
            self.assertEqual(CLIENT.worker_receiving_facts(receiver)["settled"], 1)
            receiver._process = SimpleNamespace(
                returncode=None, stdin=process.stdin, stdout=process.stdout
            )
            self.assertEqual(CLIENT.worker_receiving_facts(receiver)["settled"], 0)
            receiver._process = process
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            for stream in (process.stdin, process.stdout):
                stream.close()

    def test06CountersAreFixedBoundedAndSnapshotsCannotAlterOwner(self):
        self.fixture.receiving_counts["accept_proxy"] = 65535
        self.fixture._receive("accept_proxy")
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_proxy"], 65535)
        facts["accept_proxy"] = 0
        self.assertEqual(self.fixture.receiving_facts()["accept_proxy"], 65535)
        with self.assertRaises(WIRE.FixtureFailure):
            self.fixture._receive("unapproved")
        self.assertEqual(
            set(facts),
            {
                "version",
                "active",
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
            },
        )
        self.assertTrue(all(type(value) is int and 0 <= value <= 65535 for value in facts.values()))

    def test07RestorationRefusalRemainsPrimaryWhenDiagnosticOutputFails(self):
        primary = RuntimeError("controlled restoration refusal")

        def refused():
            raise primary

        fixture = SimpleNamespace(
            close=refused,
            closed=False,
            trust_attempted=True,
            keychain_created=True,
            receiving_facts=lambda: {"active": 2},
        )
        owner = SimpleNamespace(fixture=fixture)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(RuntimeError) as refusal:
                CLIENT.RealNativeClientReceiving.tearDownClass.__func__(owner)
        self.assertIs(refusal.exception, primary)
        self.assertEqual(
            json.loads(output.getvalue().removeprefix("# native_http_fixture_closure ")),
            {"version": 1, "closed": 0, "trust_unsettled": 1, "keychain_unsettled": 1, "active": 2},
        )
        with mock.patch("builtins.print", side_effect=BrokenPipeError()):
            with self.assertRaises(RuntimeError) as refusal:
                CLIENT.RealNativeClientReceiving.tearDownClass.__func__(owner)
        self.assertIs(refusal.exception, primary)

    def test08Actual407RefusalCannotClaimCompletedConnect(self):
        with socket.create_connection(("127.0.0.1", self.fixture.ports["auth"]), timeout=3) as raw:
            raw.sendall(
                f"CONNECT {self.fixture.host}:{self.fixture.origin_port} HTTP/1.1\r\n\r\n".encode()
            )
            response = bytearray()
            while part := raw.recv(4096):
                response.extend(part)
        self.assertTrue(response.startswith(b"HTTP/1.1 407 Proxy Authentication Required\r\n"))
        self.assertIn(b'Proxy-Authenticate: Basic realm="owned"\r\n', response)
        self.assertEqual(self.fixture.stats()["active"], 0)
        self.assertEqual(self.fixture.stats()["records"], [{"event": "connect", "route": "auth"}])
        facts = self.fixture.receiving_facts()
        self.assertEqual(facts["accept_proxy"], 1)
        self.assertEqual(facts["connect_refused"], 1)
        self.assertEqual(facts["connect_complete"], 0)
        self.assertEqual(facts["accept_origin"], 0)
        self.assertEqual(facts["handshake_started"], 0)
        self.assertEqual(facts["request_origin"], 0)


if __name__ == "__main__":
    unittest.main()
