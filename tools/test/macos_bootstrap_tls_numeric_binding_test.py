"""Portable real TLS peer controls; hosted Darwin receiving is separate."""

import ast
import contextlib
import http.server
import io
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT
    / "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedNetworkBootstrapTests.swift"
)


class ResolverRefusal(RuntimeError):
    pass


class NumericBootstrapTLSPeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-numeric-tls-control-")
        cls.root = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.certificate = cls.root / "ca.pem"
        cls.key = cls.root / "key.pem"
        config = cls.root / "openssl.cnf"
        config.write_text(
            "[req]\ndistinguished_name=dn\nprompt=no\nx509_extensions=extensions\n"
            "[dn]\nCN=Independent loopback\n[extensions]\nsubjectAltName=IP:127.0.0.1\n"
            "basicConstraints=critical,CA:TRUE\n"
            "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-config",
                str(config),
                "-out",
                str(cls.certificate),
                "-keyout",
                str(cls.key),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=True,
            timeout=10,
        )

    def script(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertEqual(source.count('let source = """'), 1)
        script = textwrap.dedent(source.split('let source = """\n', 1)[1].split('\n\t\t"""', 1)[0])
        tree = ast.parse(script)
        self.assertEqual(ast.unparse(tree.body[-2]), "print(server.server_address[1], flush=True)")
        self.assertEqual(ast.unparse(tree.body[-1]), "server.serve_forever()")
        return tree

    def peer(self, certificate=None):
        tree = self.script()
        # Execute the exact embedded constructor. Remove only its two terminal
        # statements so this owner can exercise and retire the physical socket.
        body = ast.Module(body=tree.body[:-2], type_ignores=[])
        scope = {}
        try:
            with mock.patch.object(
                sys, "argv", ["peer", str(certificate or self.certificate), str(self.key)]
            ):
                with mock.patch.object(
                    socket, "getfqdn", side_effect=ResolverRefusal("blocked resolver")
                ):
                    exec(compile(body, str(SOURCE), "exec"), scope)
        except BaseException:
            if "server" in scope:
                scope["server"].server_close()
            raise
        server = scope["server"]
        self.addCleanup(server.server_close)
        self.assertEqual(server.server_address, server.socket.getsockname())
        self.assertEqual(server.server_name, "127.0.0.1")
        self.assertEqual(server.server_port, server.server_address[1])
        self.assertGreater(server.server_port, 0)
        return server

    def exchange(self, context, hostname):
        server = self.peer()
        server.timeout = 3
        worker = threading.Thread(target=server.handle_request)
        worker.start()
        try:
            with socket.create_connection(server.server_address, timeout=3) as raw:
                with context.wrap_socket(raw, server_hostname=hostname) as client:
                    client.sendall(b"GET /independent HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
                    result = bytearray()
                    while data := client.recv(4096):
                        result.extend(data)
                    return bytes(result)
        finally:
            worker.join(4)
            self.assertFalse(worker.is_alive(), "the exact single-request TLS peer must retire")

    def test01ActualEmbeddedConstructorDoesNotCallBlockedResolver(self):
        self.peer()

    def test02OriginalHTTPServerCallsResolverBeforeReadiness(self):
        with mock.patch.object(socket, "getfqdn", side_effect=ResolverRefusal("blocked resolver")):
            with self.assertRaises(ResolverRefusal):
                http.server.HTTPServer(("127.0.0.1", 0), http.server.BaseHTTPRequestHandler)

    def test03RealTLSWithExactCustomCAReceivesOriginalBody(self):
        context = ssl.create_default_context(cafile=str(self.certificate))
        response = self.exchange(context, "127.0.0.1")
        self.assertTrue(response.startswith(b"HTTP/1.0 200 "))
        self.assertEqual(response.split(b"\r\n\r\n", 1)[1], b"independent-native-tls-body")

    def test04DefaultTrustStillRefusesPrivateCertificate(self):
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.exchange(ssl.create_default_context(), "127.0.0.1")

    def test05CustomCAStillRefusesDifferentHostname(self):
        context = ssl.create_default_context(cafile=str(self.certificate))
        with self.assertRaises(ssl.SSLCertVerificationError):
            self.exchange(context, "wrong-host.invalid")

    def test06CertificateFailureCannotBecomeReadiness(self):
        invalid = self.root / "invalid.pem"
        invalid.write_bytes(b"not a certificate\n")
        with self.assertRaises(ssl.SSLError):
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.peer(invalid)
        self.assertEqual(output.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
