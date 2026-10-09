"""Portable real TLS peer controls; hosted Darwin receiving is separate."""

import ast
import contextlib
import http.server
import io
import json
from pathlib import Path
import re
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


def der_fields(data):
    """Read bounded canonical DER fields without treating embedded bytes as OIDs."""
    fields = []
    offset = 0
    if len(data) > 16384:
        raise ValueError("Certificate projection exceeds its bound")
    while offset < len(data):
        if len(data) - offset < 2:
            raise ValueError("Incomplete certificate field")
        tag, length = data[offset : offset + 2]
        offset += 2
        if length & 0x80:
            count = length & 0x7F
            if count == 0 or count > 3 or len(data) - offset < count or data[offset] == 0:
                raise ValueError("Noncanonical certificate length")
            length = int.from_bytes(data[offset : offset + count], "big")
            offset += count
            if length < 128:
                raise ValueError("Noncanonical certificate length")
        if length > len(data) - offset:
            raise ValueError("Incomplete certificate field")
        fields.append((tag, data[offset : offset + length]))
        offset += length
    return fields


class NumericBootstrapTLSPeerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="ergopti-numeric-tls-control-")
        cls.root = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.certificate = cls.root / "ca.pem"
        cls.key = cls.root / "key.pem"
        config = cls.root / "openssl.cnf"
        literals = re.findall(
            r'try Data\("((?:\\.|[^"\\])*)"\.utf8\)\.write\(to: config\)',
            SOURCE.read_text(encoding="utf-8"),
        )
        if len(literals) != 1:
            raise ValueError("Exactly one independent Swift certificate recipe is required")
        cls.config = json.loads('"' + literals[0] + '"')
        config.write_text(cls.config, encoding="utf-8")
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

    def certificate_ekus(self, certificate):
        result = subprocess.run(
            ["openssl", "x509", "-in", str(certificate), "-outform", "DER"],
            stdin=subprocess.DEVNULL,
            capture_output=True,
            check=True,
            timeout=10,
        )
        outer = der_fields(result.stdout)
        self.assertEqual([tag for tag, _ in outer], [0x30])
        certificate_fields = der_fields(outer[0][1])
        self.assertEqual([tag for tag, _ in certificate_fields], [0x30, 0x30, 0x03])
        extensions = [value for tag, value in der_fields(certificate_fields[0][1]) if tag == 0xA3]
        self.assertEqual(len(extensions), 1)
        wrapper = der_fields(extensions[0])
        self.assertEqual([tag for tag, _ in wrapper], [0x30])
        matches = []
        for tag, extension in der_fields(wrapper[0][1]):
            self.assertEqual(tag, 0x30)
            fields = der_fields(extension)
            self.assertIn([tag for tag, _ in fields], ([0x06, 0x04], [0x06, 0x01, 0x04]))
            if fields[0][1] == b"\x55\x1d\x25":  # X.509 extendedKeyUsage, 2.5.29.37.
                matches.append(fields[-1][1])
        if not matches:
            return []
        self.assertEqual(len(matches), 1)
        purposes = der_fields(matches[0])
        self.assertEqual([tag for tag, _ in purposes], [0x30])
        oids = der_fields(purposes[0][1])
        self.assertTrue(oids)
        self.assertTrue(all(tag == 0x06 for tag, _ in oids))
        return [oid for _, oid in oids]

    def test07ActualSwiftCertificateCarriesExplicitServerAuthEKU(self):
        # App anchors use Apple's stricter serverAuth policy, even though the
        # Linux OpenSSL verifier accepts an omitted EKU. Inspect the real DER.
        self.assertIn(b"\x2b\x06\x01\x05\x05\x07\x03\x01", self.certificate_ekus(self.certificate))

    def test08AbsentOrClientAuthEKUCannotCreditServerAuthentication(self):
        for name, replacement in (("absent", ""), ("client", "extendedKeyUsage=clientAuth\n")):
            with self.subTest(purpose=name):
                config = self.root / (name + ".cnf")
                certificate = self.root / (name + ".pem")
                key = self.root / (name + "-key.pem")
                self.assertEqual(self.config.count("extendedKeyUsage=serverAuth\n"), 1)
                config.write_text(
                    self.config.replace("extendedKeyUsage=serverAuth\n", replacement),
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
                        str(certificate),
                        "-keyout",
                        str(key),
                    ],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=True,
                    timeout=10,
                )
                purposes = self.certificate_ekus(certificate)
                self.assertNotIn(b"\x2b\x06\x01\x05\x05\x07\x03\x01", purposes)
                self.assertEqual(
                    purposes, [] if name == "absent" else [b"\x2b\x06\x01\x05\x05\x07\x03\x02"]
                )


if __name__ == "__main__":
    unittest.main()
