# tools/test/fixtures/linux-connect-terminal-protocol.py

"""Independent protocol controls for the actual fixture method; native ABI unqualified."""

import argparse
import hashlib
import importlib.machinery
import importlib.util
import io
from pathlib import Path
from types import SimpleNamespace
import unittest
import sys
from unittest.mock import patch


class Endpoint:
    def __init__(self, failure=None):
        self.failure = failure

    def recv(self, count):
        assert count == 65536
        if self.failure is not None:
            raise self.failure
        return b""

    def sendall(self, data):
        raise AssertionError("No forwarding allowed after terminal EOF")

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        return False


class TerminalProtocol(unittest.TestCase):
    def fixture(self, client_failure=None, valid=True):
        client, backend = Endpoint(client_failure), Endpoint()
        handler = SimpleNamespace(
            server=SimpleNamespace(requests=[], tls_origin=SimpleNamespace(server_port=443)),
            path="first.corporate.invalid:443" if valid else "other.corporate.invalid:443",
            headers={},
            connection=client,
            close_connection=False,
            wfile=SimpleNamespace(flush=lambda: None),
            codes=[],
        )
        handler.send_response = handler.codes.append
        handler.send_header = lambda name, value: None
        handler.end_headers = lambda: None
        return handler, client, backend

    def invoke(self, handler, backend, selected):
        with patch.object(MODULE.socket, "create_connection", return_value=backend) as acquisition:
            with patch.object(MODULE.select, "select", return_value=(selected, [], [])):
                MODULE.HopHandler.do_CONNECT(handler)
        return acquisition

    def test_client_eof_ends_terminal_tunnel_before_http_reuse(self):
        handler, client, backend = self.fixture()
        acquired = self.invoke(handler, backend, [client])
        self.assertEqual(handler.codes, [200])
        self.assertTrue(handler.close_connection)
        acquired.assert_called_once_with(("127.0.0.1", 443), timeout=3)

    def test_backend_eof_ends_terminal_tunnel_before_http_reuse(self):
        handler, client, backend = self.fixture()
        self.invoke(handler, backend, [backend])
        self.assertEqual(handler.codes, [200])
        self.assertTrue(handler.close_connection)

    def test_bounded_idle_tunnel_is_terminal(self):
        handler, client, backend = self.fixture()
        self.invoke(handler, backend, [])
        self.assertEqual(handler.codes, [200])
        self.assertTrue(handler.close_connection)

    def test_refused_connect_keeps_original_no_backend_rule(self):
        handler, client, backend = self.fixture(valid=False)
        acquired = self.invoke(handler, backend, [])
        acquired.assert_not_called()
        self.assertEqual(handler.codes, [403])
        self.assertTrue(handler.close_connection)

    def test_unknown_reset_inside_forwarding_still_propagates(self):
        handler, client, backend = self.fixture(
            ConnectionResetError(104, "fixed independent reset")
        )
        with self.assertRaises(ConnectionResetError):
            self.invoke(handler, backend, [client])
        self.assertEqual(handler.codes, [200])
        self.assertTrue(handler.close_connection)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--expected-fixture-sha256", required=True)
    arguments = parser.parse_args()
    assert arguments.fixture.is_absolute()
    raw = arguments.fixture.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == arguments.expected_fixture_sha256
    loader = importlib.machinery.SourceFileLoader("owned_protocol_fixture", str(arguments.fixture))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    MODULE = importlib.util.module_from_spec(spec)
    loader.exec_module(MODULE)  # Only when root explicitly executes this control.
    # Only the new control framework output is adapted; every original case
    # body, assertion and five-case floor remains unchanged.
    transcript = io.StringIO()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(TerminalProtocol)
    result = unittest.TextTestRunner(stream=transcript, verbosity=2).run(suite)
    assert result.testsRun == 5
    if not result.wasSuccessful():
        sys.stderr.write(transcript.getvalue())  # Private original phase sink.
        raise SystemExit(1)
    print("CONNECT terminal protocol controls: 5 passed; 0 skipped; modeled socket/select only.")
