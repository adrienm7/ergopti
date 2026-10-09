"""Real peer controls on portable hosts; Apple receiving runs in Swift tests."""

import importlib.util
from pathlib import Path
import socket
import ssl
import unittest
import urllib.request

spec = importlib.util.spec_from_file_location(
    "wire_fixture", Path(__file__).with_name("native_http_wire_fixture.py")
)
wire = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wire)


class RealPeerControls(unittest.TestCase):
    def setUp(self):
        self.fixture = wire.WireFixture(native=False)
        self.addCleanup(self.fixture.close)

    def connect(self, route):
        connection = socket.create_connection(("127.0.0.1", self.fixture.ports[route]), timeout=3)
        connection.sendall(
            f"CONNECT {self.fixture.host}:{self.fixture.origin_port} HTTP/1.1\r\nHost: reserved\r\n\r\n".encode()
        )
        response = bytearray()
        while not response.endswith(b"\r\n\r\n"):
            response += connection.recv(1)
        return connection, bytes(response)

    def socks_connect(self):
        connection = socket.create_connection(("127.0.0.1", self.fixture.ports["socks"]), timeout=3)

        def exact(count):
            result = bytearray()
            while len(result) < count:
                part = connection.recv(count - len(result))
                self.assertTrue(
                    part, "Independent SOCKS5 wire control cannot accept truncated replies"
                )
                result += part
            return bytes(result)

        connection.sendall(b"\x05")
        connection.sendall(b"\x01\x00")
        self.assertEqual(exact(2), b"\x05\x00")
        authority = self.fixture.host.encode("ascii")
        connection.sendall(
            b"\x05\x01\x00\x03"
            + bytes([len(authority)])
            + authority
            + self.fixture.origin_port.to_bytes(2, "big")
        )
        response = exact(10)
        self.assertEqual(response[:8], b"\x05\x00\x00\x01\x7f\x00\x00\x01")
        self.assertGreater(int.from_bytes(response[8:], "big"), 0)
        return connection

    def testActualTLSProxyRecipientBinaryBodyAndFetchedLiteralPAC(self):
        context = ssl.create_default_context(cafile=str(self.fixture.ca))
        for route, path in [
            ("first", "/alpha?case=one"),
            ("second", "/beta?case=two"),
            ("socks", "/socks?case=ten"),
        ]:
            if route == "socks":
                raw = self.socks_connect()
            else:
                raw, head = self.connect(route)
                self.assertIn(b"200 Connection Established", head)
            with context.wrap_socket(raw, server_hostname=self.fixture.host) as tls:
                tls.sendall(
                    f"GET {path} HTTP/1.1\r\nHost: {self.fixture.host}\r\nConnection: close\r\n\r\n".encode()
                )
                response = bytearray()
                while True:
                    part = tls.recv(65536)
                    if not part:
                        break
                    response += part
                self.assertEqual(
                    bytes(response).split(b"\r\n\r\n", 1)[1], b"owned\x00native\xffwire"
                )
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertEqual(
            [row["route"] for row in snapshot["records"] if row["event"] == "origin"],
            ["first", "second", "socks"],
        )
        self.assertEqual(
            [row["path"] for row in snapshot["records"] if row["event"] == "origin"],
            ["/alpha?case=one", "/beta?case=two", "/socks?case=ten"],
        )
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(self.fixture.pac_url, timeout=3) as response:
            self.assertEqual(response.read().decode(), self.fixture.pac)
        self.assertIn("/alpha?case=one", self.fixture.pac)
        self.assertIn("/beta?case=two", self.fixture.pac)
        self.assertEqual(
            [row for row in snapshot["records"] if row["event"] == "socks_greeting"],
            [{"event": "socks_greeting", "version": 5, "methods": [0]}],
        )
        self.assertEqual(
            [row for row in snapshot["records"] if row["event"] == "socks_connect"],
            [
                {
                    "event": "socks_connect",
                    "version": 5,
                    "command": 1,
                    "reserved": 0,
                    "address_type": 3,
                    "target": self.fixture.host,
                    "port": self.fixture.origin_port,
                }
            ],
        )

    def testBoundRefusalAndActual407DoNotDeliverOriginBytes(self):
        with self.assertRaises(ConnectionRefusedError):
            socket.create_connection(("127.0.0.1", self.fixture.ports["refused"]), timeout=3)
        raw, header = self.connect("auth")
        with raw:
            self.assertIn(b"407 Proxy Authentication Required", header)
            self.assertEqual(raw.recv(1024), b"")
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertEqual(snapshot["records"], [{"event": "connect", "route": "auth"}])

    def testRealUntrustedCAFailsBeforeOriginHTTPAndPhysicallyClosesPeer(self):
        raw, _ = self.connect("first")
        try:
            with self.assertRaises(ssl.SSLCertVerificationError):
                ssl.create_default_context().wrap_socket(raw, server_hostname=self.fixture.host)
        finally:
            raw.close()
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertEqual(snapshot["records"], [{"event": "connect", "route": "first"}])


if __name__ == "__main__":
    print(
        "Selected: 3 actual portable TLS/CONNECT/SOCKS5 peer controls. Native Apple networking/trust: not executed.",
        flush=True,
    )
    unittest.main(verbosity=2)
