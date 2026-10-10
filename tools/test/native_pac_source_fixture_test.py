"""Real portable PAC peers, without claiming native URLSession qualification."""

import http.client
import importlib.util
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "static/ergopti_plus/macos/tests/support/native_pac_source_fixture.py"
SPEC = importlib.util.spec_from_file_location("pac_source_fixture", SOURCE)
PEERS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PEERS)


class PACSourcePeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = PEERS.SourceFixture()

    @classmethod
    def tearDownClass(cls):
        cls.fixture.close()
        assert cls.fixture.closed
        assert all(not thread.is_alive() for thread in cls.fixture.threads)
        assert all(not thread.is_alive() for thread in cls.fixture.request_threads)
        assert all(not thread.is_alive() for thread in cls.fixture.shutdown_threads)

    def request(self, path, tls=False, host="127.0.0.1", context=None):
        port = self.fixture.https.server_port if tls else self.fixture.http.server_port
        connection = (
            http.client.HTTPSConnection(host, port, timeout=3, context=context)
            if tls
            else http.client.HTTPConnection(host, port, timeout=3)
        )
        self.addCleanup(connection.close)
        connection.request("GET", "/source/" + path)
        return connection.getresponse()

    def test_utf_vectors_are_actual_complete_peer_bytes(self):
        for name, expected in [
            ("utf8", PEERS.SCRIPT.encode()),
            ("utf8-bom", b"\xef\xbb\xbf" + PEERS.SCRIPT.encode()),
            ("utf16-le", b"\xff\xfe" + PEERS.SCRIPT.encode("utf-16le")),
            ("utf16-be", b"\xfe\xff" + PEERS.SCRIPT.encode("utf-16be")),
        ]:
            with self.subTest(name=name):
                response = self.request(name)
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), expected)

    def test_invalid_vectors_are_not_silently_repaired(self):
        for path, expected in [
            ("invalid-utf8", b"\xc0\x80"),
            ("invalid-utf16", b"\xff\xfe\x00\xd8"),
            ("empty", b""),
            ("nul", PEERS.SCRIPT.encode() + b"\x00"),
        ]:
            with self.subTest(path=path):
                self.assertEqual(self.request(path).read(), expected)

    def test_oversized_and_non200_peers_are_real(self):
        response = self.request("oversized")
        self.assertEqual(int(response.getheader("Content-Length")), 1048577)
        self.assertEqual(len(response.read()), 1048577)
        self.assertEqual(self.request("unavailable").status, 503)

    def test_redirect_and_authentication_peers_preserve_authority_difference(self):
        same = self.request("redirect")
        self.assertEqual(same.status, 302)
        self.assertEqual(same.getheader("Location"), "/source/utf8")
        foreign = self.request("foreign")
        self.assertEqual(foreign.status, 302)
        self.assertEqual(
            foreign.getheader("Location"),
            f"http://localhost:{self.fixture.http.server_port}/source/utf8",
        )
        auth = self.request("authentication")
        self.assertEqual(auth.status, 401)
        self.assertEqual(auth.getheader("WWW-Authenticate"), 'Basic realm="owned-pac-source"')

    def test_default_trust_refuses_generated_anchor(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.request("utf8", tls=True, context=ssl.create_default_context())

    def test_owned_anchor_preserves_hostname_verification(self):
        context = ssl.create_default_context(cafile=str(self.fixture.root / "ca.pem"))
        self.assertEqual(
            self.request("utf8", tls=True, context=context).read(), PEERS.SCRIPT.encode()
        )
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.request("utf8", tls=True, host="localhost", context=context)

    def test_truncated_body_is_not_successful_eof(self):
        with self.assertRaises(http.client.IncompleteRead):
            self.request("truncated").read()

    def test_actual_stdin_eof_retires_owned_process_and_both_listeners(self):
        import json

        process = subprocess.Popen(
            [sys.executable, str(SOURCE)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            profile = json.loads(process.stdout.readline())
            output, error = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(error, "")
            self.assertEqual(json.loads(output), {"version": 1, "closed": True})
            for key in ["http_port", "https_port"]:
                with socket.socket() as peer:
                    peer.settimeout(1)
                    self.assertNotEqual(peer.connect_ex(("127.0.0.1", profile[key])), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=3)

    def interrupted_start_control(self, serving):
        original_thread = threading.Thread
        entered = threading.Event()
        release = threading.Event()
        target_entered = threading.Event()
        held = []
        primary = KeyboardInterrupt("controlled public start acknowledgement")

        class HeldBootstrap(original_thread):
            def __init__(self, *arguments, **options):
                super().__init__(*arguments, **options)
                held.append(self)

            def _bootstrap(self):
                entered.set()
                release.wait()
                super()._bootstrap()

            def start(self):
                with mock.patch.object(self._started, "wait", side_effect=primary):
                    super().start()

            def run(self):
                target_entered.set()
                super().run()

        owner = (
            PEERS.SourceFixture.__new__(PEERS.SourceFixture) if serving else PEERS.SourceFixture()
        )
        try:
            with mock.patch.object(PEERS.threading, "Thread", HeldBootstrap):
                with self.assertRaises(KeyboardInterrupt) as refusal:
                    owner.__init__() if serving else owner.close()
            self.assertIs(refusal.exception, primary)
            self.assertTrue(entered.wait(2))
            self.assertIsNone(held[0].ident)
            self.assertFalse(held[0]._started.is_set())
            states = owner.server_starts if serving else owner.server_shutdowns
            self.assertIs(states[0]["worker"], held[0])
            self.assertTrue(states[0]["attempted"])
            self.assertFalse(states[0]["started"])
            self.assertIs(states[0]["failure"], primary)
            self.assertFalse(owner.closed)
            self.assertTrue(owner.root.exists())
            self.assertTrue(all(server.socket.fileno() >= 0 for server in owner.servers))
            with mock.patch.object(PEERS.threading.Thread, "start") as acquire:
                with self.assertRaises(KeyboardInterrupt) as repeated:
                    owner.close()
            acquire.assert_not_called()
            self.assertIs(repeated.exception, primary)
        finally:
            # Only this control owns the bootstrap capability; its explicit
            # release never changes production acknowledgement/debt fields.
            release.set()
            if held:
                self.assertTrue(held[0]._started.wait(2))
                self.assertTrue(target_entered.wait(2))
            if not serving and held:
                held[0].join(2)
                self.assertFalse(held[0].is_alive())
            for state in owner.server_starts:
                if state["worker"].is_alive():
                    state["server"].shutdown()
                state["worker"].join(2)
                self.assertFalse(state["worker"].is_alive())
            for server in owner.servers:
                server.server_close()
            owner.directory.cleanup()
            if owner in PEERS.RETAINED_DEBT:
                PEERS.RETAINED_DEBT.remove(owner)

    def test_actual_serving_start_acquisition_without_acknowledgement_retains_debt(self):
        self.interrupted_start_control(serving=True)

    def test_actual_shutdown_start_acquisition_without_acknowledgement_retains_debt(self):
        self.interrupted_start_control(serving=False)

    def test_actual_listener_close_then_exception_never_retries_closed_reference(self):
        owner = PEERS.SourceFixture()
        server = owner.servers[0]
        actual = server.socket
        primary = OSError("controlled uncertain close acknowledgement")
        calls = []

        class UncertainClose:
            def __getattr__(self, name):
                return getattr(actual, name)

            def close(self):
                calls.append(True)
                actual.close()
                raise primary

        server.socket = UncertainClose()
        try:
            with self.assertRaises(OSError) as first:
                owner.close()
            self.assertIs(first.exception, primary)
            self.assertEqual(actual.fileno(), -1)
            self.assertTrue(owner.root.exists())
            self.assertFalse(owner.closed)
            with self.assertRaises(OSError) as repeated:
                owner.close()
            self.assertIs(repeated.exception, primary)
            self.assertEqual(len(calls), 1)
            self.assertIn(owner, PEERS.RETAINED_DEBT)
        finally:
            server.socket = actual
            for state in owner.server_starts + owner.server_shutdowns:
                state["worker"].join(2)
                self.assertFalse(state["worker"].is_alive())
            for owned in owner.servers:
                owned.server_close()
            owner.directory.cleanup()
            if owner in PEERS.RETAINED_DEBT:
                PEERS.RETAINED_DEBT.remove(owner)

    def test_actual_held_target_join_interruption_preserves_primary_without_retry(self):
        original_thread = threading.Thread
        entered = threading.Event()
        release = threading.Event()
        completed = threading.Event()
        held = []
        primary = KeyboardInterrupt("controlled public join acknowledgement interruption")

        class HeldTail(original_thread):
            def __init__(self, *arguments, **options):
                super().__init__(*arguments, **options)
                self.controlled = options["target"].__name__ == "serve_forever" and not held
                self.once = False
                if self.controlled:
                    held.append(self)

            def run(self):
                super().run()
                if self.controlled:
                    entered.set()
                    release.wait()
                    completed.set()

            def join(self, *arguments, **options):
                if self.controlled and not self.once:
                    self.once = True
                    if not entered.wait(2):
                        raise AssertionError("actual target never reached held tail")
                    raise primary
                return super().join(*arguments, **options)

        with mock.patch.object(PEERS.threading, "Thread", HeldTail):
            owner = PEERS.SourceFixture()
        try:
            with self.assertRaises(KeyboardInterrupt) as first:
                owner.close()
            self.assertIs(first.exception, primary)
            self.assertTrue(held[0].is_alive())
            self.assertFalse(release.is_set())
            self.assertTrue(owner.root.exists())
            self.assertFalse(owner.closed)
            with mock.patch.object(PEERS.threading.Thread, "start") as acquire:
                with self.assertRaises(KeyboardInterrupt) as repeated:
                    owner.close()
            acquire.assert_not_called()
            self.assertIs(repeated.exception, primary)
        finally:
            release.set()
            self.assertTrue(completed.wait(2))
            for state in owner.server_starts + owner.server_shutdowns:
                original_thread.join(state["worker"], 2)
                self.assertFalse(state["worker"].is_alive())
            for server in owner.servers:
                server.server_close()
            owner.directory.cleanup()
            if owner in PEERS.RETAINED_DEBT:
                PEERS.RETAINED_DEBT.remove(owner)

    def test_actual_request_start_without_acknowledgement_retains_worker_and_socket(self):
        original_thread = threading.Thread
        entered = threading.Event()
        release = threading.Event()
        refused = threading.Event()
        held = []
        errors = []
        primary = KeyboardInterrupt("controlled request start acknowledgement")

        class HeldRequest(original_thread):
            def __init__(self, *arguments, **options):
                super().__init__(*arguments, **options)
                self.controlled = options["target"].__name__ == "process_request_thread"
                if self.controlled:
                    held.append(self)

            def _bootstrap(self):
                if self.controlled:
                    entered.set()
                    release.wait()
                super()._bootstrap()

            def start(self):
                if not self.controlled:
                    return super().start()
                try:
                    with mock.patch.object(self._started, "wait", side_effect=primary):
                        return super().start()
                finally:
                    refused.set()

        owner = PEERS.SourceFixture()
        connection = None
        try:
            with (
                mock.patch.object(PEERS.threading, "Thread", HeldRequest),
                mock.patch.object(
                    threading, "excepthook", lambda args: errors.append(args.exc_value)
                ),
            ):
                connection = socket.create_connection(("127.0.0.1", owner.http.server_port), 2)
                connection.sendall(
                    b"GET /source/utf8 HTTP/1.1\r\nHost: owned\r\nConnection: close\r\n\r\n"
                )
                self.assertTrue(entered.wait(2))
                self.assertTrue(refused.wait(2))
                deadline = time.monotonic() + 2
                while owner.request_starts[0]["failure"] is None and time.monotonic() < deadline:
                    threading.Event().wait(0.001)
                with self.assertRaises(KeyboardInterrupt) as first:
                    owner.close()
                self.assertIs(first.exception, primary)
                self.assertIs(owner.request_starts[0]["worker"], held[0])
                self.assertIsNone(held[0].ident)
                self.assertFalse(owner.closed)
                self.assertTrue(owner.root.exists())
                self.assertTrue(all(server.socket.fileno() >= 0 for server in owner.servers))
                self.assertEqual(len(owner.connections), 1)
                release.set()
                self.assertTrue(held[0]._started.wait(2))
                original_thread.join(held[0], 2)
                self.assertFalse(held[0].is_alive())
                original_thread.join(owner.threads[0], 2)
            self.assertEqual(errors, [primary])
        finally:
            release.set()
            if connection is not None:
                connection.close()
            for thread in held:
                self.assertTrue(thread._started.wait(2))
                original_thread.join(thread, 2)
                self.assertFalse(thread.is_alive())
            for state in owner.server_starts:
                if state["worker"].is_alive():
                    state["server"].shutdown()
                original_thread.join(state["worker"], 2)
                self.assertFalse(state["worker"].is_alive())
            for owned_connection in owner.connections:
                owned_connection.close()
            for server in owner.servers:
                server.server_close()
            owner.directory.cleanup()
            if owner in PEERS.RETAINED_DEBT:
                PEERS.RETAINED_DEBT.remove(owner)

    def test_numeric_listener_binding_never_acquires_unused_reverse_dns(self):
        with mock.patch.object(
            PEERS.socket, "getfqdn", side_effect=RuntimeError("reverse DNS refused")
        ) as resolver:
            owner = PEERS.SourceFixture()
            try:
                self.assertEqual(owner.http.server_name, "127.0.0.1")
                self.assertEqual(owner.https.server_name, "127.0.0.1")
                self.assertGreater(owner.profile()["http_port"], 0)
                self.assertGreater(owner.profile()["https_port"], 0)
                resolver.assert_not_called()
            finally:
                owner.close()
            self.assertTrue(owner.closed)


if __name__ == "__main__":
    print("Planned cases: 14", flush=True)
    unittest.main()
