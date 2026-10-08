# tools/test/macos_managed_ollama_explicit_stream_test.py
"""Actual curl/private-pipe receiving over a controlled relay, not macOS credit."""

import argparse
import hashlib
import importlib.util
import os
from pathlib import Path
import socket
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

parser = argparse.ArgumentParser(add_help=False)
parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
parser.add_argument("--source", type=Path)
options, arguments = parser.parse_known_args()
SOURCE = options.repository / "static/ergopti_plus/macos/modules/llm/managed_ollama_runtime.py"
specification = importlib.util.spec_from_file_location("receiving_ollama_explicit", SOURCE)
RUNTIME = importlib.util.module_from_spec(specification)
sys.modules[specification.name] = RUNTIME
exec(
    compile((options.source or SOURCE).read_bytes(), str(options.source or SOURCE), "exec"),
    RUNTIME.__dict__,
)


class Relay:
    """An actual HTTP recipient whose held response detects physical peer closure."""

    def __init__(self, response, hold=False):
        self.socket = socket.socket()
        self.socket.bind(("127.0.0.1", 0))
        self.socket.listen()
        self.socket.settimeout(4)
        self.port = self.socket.getsockname()[1]
        self.response, self.hold = response, hold
        self.closed = threading.Event()
        self.request = b""
        self.error = None
        self.thread = threading.Thread(target=self.run)
        self.thread.start()

    def run(self):
        try:
            connection, _ = self.socket.accept()
            with connection:
                connection.settimeout(4)
                while b"\r\n\r\n" not in self.request:
                    self.request += connection.recv(4096)
                try:
                    connection.sendall(self.response)
                    if self.hold:
                        while connection.recv(4096):
                            pass
                        self.closed.set()
                except (BrokenPipeError, ConnectionResetError):
                    self.closed.set()
        except BaseException as error:
            self.error = error

    def close(self):
        self.thread.join(5)
        self.socket.close()
        if self.thread.is_alive():
            raise AssertionError("Owned relay thread did not retire")

    @property
    def proxy(self):
        return "http://127.0.0.1:" + str(self.port)


class ExplicitCurlReceiving(unittest.TestCase):
    def setUp(self):
        self.children = []
        actual = RUNTIME.subprocess.Popen

        def receiving(*args, **kwargs):
            child = actual(*args, **kwargs)
            self.children.append(child)
            return child

        watcher = patch.object(RUNTIME.subprocess, "Popen", side_effect=receiving)
        watcher.start()
        self.addCleanup(watcher.stop)

    def relay(self, response, hold=False):
        relay = Relay(response, hold)
        self.addCleanup(relay.close)
        return relay

    def response(self, relay, timeout=3):
        return RUNTIME.CurlResponse(
            "http://private-source.invalid/artifact?private=query",
            headers=(("Accept-Encoding", "identity"),),
            timeout=timeout,
            idle_timeout=timeout,
            direct=False,
            proxy=relay.proxy,
            connect_timeout=timeout,
            minimum_bytes_per_second=1,
        )

    def test_user_curlrc_cannot_override_exact_selected_relay(self):
        accepted = self.relay(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nowned")
        foreign = self.relay(b"HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\nforeign")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".curlrc").write_text('proxy = "' + foreign.proxy + '"\n')
            with patch.dict(
                os.environ,
                {"HOME": temporary, "CURL_HOME": temporary, "XDG_CONFIG_HOME": temporary},
            ):
                with self.response(accepted) as response:
                    received = bytearray()
                    while chunk := response.read():
                        received.extend(chunk)
                    self.assertEqual(received, b"owned")
        self.assertIn(b"GET http://private-source.invalid/artifact?private=query", accepted.request)
        self.assertEqual(foreign.request, b"")
        self.assertEqual(self.children[-1].args[1], "-q")

    def test_actual_relay_streams_exact_bytes_and_reaps(self):
        payload = b"independent\x00asset"
        relay = self.relay(
            b"HTTP/1.1 200 OK\r\nContent-Length: 17\r\nX-Receipt: independent\r\n\r\n" + payload
        )
        with self.response(relay) as response:
            self.assertEqual(response.status, 200)
            self.assertIn(("X-Receipt", "independent"), response.headers)
            received = bytearray()
            while chunk := response.read(3):
                received.extend(chunk)
            self.assertEqual(received, payload)
            self.assertEqual(self.children[-1].returncode, 0)
            self.assertTrue(self.children[-1].stdout.closed)
        self.assertIn(b"Accept-Encoding: identity\r\n", relay.request)
        self.assertIn(b"http://private-source.invalid/artifact?private=query", relay.request)

    def test_pinned_body_cap_closes_held_oversize_before_original_deadline(self):
        relay = self.relay(
            b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n" + b"x" * 1024, hold=True
        )
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "asset"
            started = time.monotonic()
            with self.assertRaises(RUNTIME.BOOTSTRAP.BootstrapFailure) as failure:
                RUNTIME.BOOTSTRAP.download(
                    "http://private-source.invalid/artifact",
                    output,
                    hashlib.sha256(b"literal").hexdigest(),
                    7,
                    started + 3,
                    3,
                    request=lambda *args, **kwargs: self.response(relay),
                )
            self.assertEqual(failure.exception.reason, "integrity")
            self.assertFalse(output.exists())
            self.assertTrue(relay.closed.wait(1))
            self.assertLess(time.monotonic() - started, 2)

    def test_redirect_headers_are_returned_before_held_body_and_close(self):
        relay = self.relay(
            b"HTTP/1.1 302 Found\r\nLocation: /next\r\nContent-Length: 1000000\r\n\r\n", hold=True
        )
        started = time.monotonic()
        with self.response(relay) as response:
            self.assertEqual(response.status, 302)
            self.assertIn(("Location", "/next"), response.headers)
        self.assertTrue(relay.closed.wait(1))
        self.assertLess(time.monotonic() - started, 2)
        self.assertIsNotNone(self.children[-1].returncode)

    def test_header_cap_closes_held_metadata_before_original_deadline(self):
        headers = b"X-Fill: " + b"x" * 1000 + b"\r\n"
        relay = self.relay(
            b"HTTP/1.1 200 OK\r\n" + headers * 66 + b"Content-Length: 1000000\r\n\r\n", hold=True
        )
        started = time.monotonic()
        with self.assertRaises(RUNTIME.BOOTSTRAP.BootstrapFailure) as failure:
            self.response(relay)
        self.assertEqual(failure.exception.reason, "protocol")
        self.assertTrue(relay.closed.wait(1))
        self.assertLess(time.monotonic() - started, 2)

    def test_incomplete_body_requires_real_curl_success_and_reap(self):
        relay = self.relay(b"HTTP/1.1 200 OK\r\nContent-Length: 17\r\n\r\nshort")
        with self.assertRaises(RUNTIME.BOOTSTRAP.BootstrapFailure) as failure:
            with self.response(relay) as response:
                while response.read():
                    pass
        self.assertEqual(failure.exception.reason, "connect")
        self.assertNotEqual(self.children[-1].returncode, 0)
        self.assertTrue(self.children[-1].stdout.closed)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *arguments])
