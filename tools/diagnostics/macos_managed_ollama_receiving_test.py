# tools/diagnostics/macos_managed_ollama_receiving_test.py
"""Actual portable TLS registry peers; no native daemon or PAC credit."""

import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import ssl
import unittest
import tempfile
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT = Path(os.environ.get("ERGOPTI_RECEIVING_REPOSITORY", Path(__file__).resolve().parents[2]))


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


RECEIVING = load(
    "registry_receiving", Path(__file__).with_name("macos_managed_ollama_receiving.py")
)
WIRE = load(
    "registry_wire", ROOT / "static/ergopti_plus/macos/tests/support/native_http_wire_fixture.py"
)
MODEL = load("registry_model", ROOT / "tools/diagnostics/ollama_native_tiny_gguf.py")


class StandaloneCompilerControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.subject = RECEIVING.Receiver.__new__(RECEIVING.Receiver)
        self.subject.root = ROOT
        self.subject.mac = ROOT / "static/ergopti_plus/macos"
        self.subject.work = Path(temporary.name)
        self.subject.source_hashes = {}
        self.subject.payload = Mock(return_value=self.subject.work / "payload")
        self.fixture = SimpleNamespace(_command=Mock())
        self.wire = SimpleNamespace(WireFixture=Mock(return_value=self.fixture))

    def test_exact_public_headers_and_system_framework_at_compiler_boundary(self):
        class CompilerBoundary(Exception):
            pass

        def inspect(arguments, *, timeout):
            self.assertEqual(timeout, 90)
            self.assertEqual(arguments[:3], ["/usr/bin/xcrun", "swiftc", "-parse-as-library"])
            self.assertIn("-I", arguments)
            module = Path(arguments[arguments.index("-I") + 1])
            self.assertEqual(module, self.subject.work / "CPOSIXCompatibility")
            self.assertEqual(module.stat().st_mode & 0o777, 0o700)
            self.assertEqual(
                (module / "module.modulemap").read_text(),
                "module CPOSIXCompatibility {\n"
                '  umbrella header "CPOSIXCompatibility.h"\n'
                "  export *\n}\n",
            )
            for name in [
                "CPOSIXCompatibility.h",
                "OwnedProgramCompatibility.h",
                "LoopbackListenerCompatibility.h",
            ]:
                relative = (
                    "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include/" + name
                )
                original = (ROOT / relative).read_bytes()
                self.assertEqual((module / name).read_bytes(), original)
                self.assertEqual(
                    self.subject.source_hashes[relative],
                    hashlib.sha256(original).hexdigest(),
                )
            self.assertEqual(arguments[arguments.index("-framework") + 1], "SystemConfiguration")
            raise CompilerBoundary()

        self.fixture._command.side_effect = inspect
        with (
            patch.object(RECEIVING, "load", return_value=self.wire),
            patch.object(RECEIVING, "Registry"),
            self.assertRaises(CompilerBoundary),
        ):
            self.subject.prepare()
        self.fixture._command.assert_called_once()

    def test_changed_public_header_copy_refuses_before_compiler(self):
        original_copy = self.subject.copy_source

        def mutate(relative, destination):
            original_copy(relative, destination)
            if relative.endswith("/CPOSIXCompatibility.h"):
                destination.write_bytes(b"foreign declarations")

        self.subject.copy_source = mutate
        with (
            patch.object(RECEIVING, "load", return_value=self.wire),
            patch.object(RECEIVING, "Registry"),
            self.assertRaisesRegex(RuntimeError, "compatibility_source_copy"),
        ):
            self.subject.prepare()
        self.fixture._command.assert_not_called()


class RetainedSourceControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "ollama"
        self.binary.write_bytes(b"independent source bytes; filesystem policy only")
        self.binary.chmod(0o755)
        observed = self.binary.stat()
        self.session = {
            "version": 1,
            "token": "a" * 64,
            "port": "11434",
            "source_commit": "b" * 40,
            "asset_sha256": "c" * 64,
            "binary_sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "device": str(observed.st_dev),
            "inode": str(observed.st_ino),
        }

    def test_actual_readonly_descriptor_and_hash_preserve_exec_offset(self):
        descriptor = RECEIVING.retained_source(self.binary, self.session)
        try:
            RECEIVING.check_retained_source(self.binary, descriptor, self.session)
            self.assertEqual(os.lseek(descriptor, 0, os.SEEK_CUR), 0)
            self.assertEqual(os.pread(descriptor, 11, 0), b"independent")
            with self.assertRaises(OSError):
                os.write(descriptor, b"changed")
        finally:
            os.close(descriptor)

    def test_pre_exec_changed_pathname_refuses_before_private_env_dispatch(self):
        groups = SimpleNamespace(acquire_owned=Mock())
        subject = RECEIVING.Receiver.__new__(RECEIVING.Receiver)
        subject.binary = self.binary
        subject.work = self.root
        subject.http_environment = {}
        subject.http_payload = self.root
        subject.options = SimpleNamespace(profile="pac-inline")
        subject.daemon = None
        subject.receipt = {}
        subject.fixture = SimpleNamespace(groups=groups, native_groups=object())
        session_path = self.root / "private-session.json"

        def create_session(deadline, port):
            session_path.write_text(json.dumps(self.session | {"port": str(port)}))
            self.binary.unlink()
            self.binary.write_bytes(b"foreign pathname replacement")
            self.binary.chmod(0o755)
            return session_path

        subject.runtime = SimpleNamespace(
            create_session=create_session,
            POLICY=load(
                "source_receiving_policy",
                ROOT / "static/ergopti_plus/_shared/python/managed_ollama_runtime.py",
            ),
        )
        original_descriptor = os.open(self.binary, os.O_RDONLY)
        try:
            with self.assertRaisesRegex(RuntimeError, "actual_retained_source_identity"):
                subject.start()
            groups.acquire_owned.assert_not_called()
            self.assertEqual(self.binary.read_bytes(), b"foreign pathname replacement")
        finally:
            subject.stop()
            os.close(original_descriptor)

    def test_held_descriptor_refuses_changed_path_and_changed_bytes(self):
        descriptor = RECEIVING.retained_source(self.binary, self.session)
        try:
            self.binary.write_bytes(b"changed in place")
            with self.assertRaisesRegex(RuntimeError, "actual_retained_source_bytes"):
                RECEIVING.check_retained_source(self.binary, descriptor, self.session)
            self.binary.unlink()
            self.binary.write_bytes(b"foreign replacement")
            self.binary.chmod(0o755)
            with self.assertRaisesRegex(RuntimeError, "actual_retained_source_identity"):
                RECEIVING.check_retained_source(self.binary, descriptor, self.session)
        finally:
            os.close(descriptor)


class ActualPeerReceiving(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.addCleanup(self.fixture.close)
        self.registry = RECEIVING.Registry(self.fixture)
        self.model = MODEL.model_bytes()
        self.assertEqual(
            hashlib.sha256(self.model).hexdigest(),
            "a85aba87b0e9e724d0b499d12d4dcb9fd2ede378c96ffad75a70a919f2c00c0a",
        )
        self.model_digest = "sha256:" + hashlib.sha256(self.model).hexdigest()
        self.config = b'{"architecture":"llama"}'
        config_digest = "sha256:" + hashlib.sha256(self.config).hexdigest()
        self.manifest = json.dumps(
            {
                "schemaVersion": 2,
                "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
                "config": {
                    "mediaType": "application/vnd.docker.container.image.v1+json",
                    "digest": config_digest,
                    "size": len(self.config),
                },
                "layers": [
                    {
                        "mediaType": "application/vnd.ollama.image.model",
                        "digest": self.model_digest,
                        "size": len(self.model),
                    }
                ],
            }
        ).encode()
        self.registry.set_model(
            self.manifest, {self.model_digest: self.model, config_digest: self.config}
        )
        self.context = ssl.create_default_context(cafile=str(self.fixture.ca))

    def connect(self):
        connection = http.client.HTTPSConnection(
            "127.0.0.1", self.fixture.origin_port, context=self.context, timeout=3
        )
        self.addCleanup(connection.close)
        return connection

    def test_actual_redirect_retains_literal_full_path_and_query_and_exact_manifest(self):
        connection = self.connect()
        path = "/v2/library/native-pulled/manifests/latest"
        connection.request("GET", path)
        response = connection.getresponse()
        self.assertEqual(response.status, 302)
        self.assertEqual(
            response.getheader("Location"),
            f"https://{self.fixture.host}:{self.fixture.origin_port}{path}?native=manifest",
        )
        self.assertEqual(response.read(), b"")
        connection.request("GET", path + "?native=manifest")
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), self.manifest)

    def test_actual_head_range_size_digest_and_location_use_real_blob_bytes(self):
        connection = self.connect()
        path = "/v2/library/native-pulled/blobs/" + self.model_digest
        connection.request("HEAD", path)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Content-Length"), "51072")
        self.assertEqual(response.read(), b"")
        connection.request("GET", path + "?native=blob", headers={"Range": "bytes=2-17"})
        response = connection.getresponse()
        self.assertEqual(response.status, 206)
        self.assertEqual(response.getheader("Content-Range"), "bytes 2-17/51072")
        self.assertEqual(response.read(), self.model[2:18])

    def test_cancelled_actual_tls_body_reports_eof_and_zero_socket_debt(self):
        connection = self.connect()
        path = "/v2/library/native-cancel/blobs/" + self.registry.held_digest + "?native=blob"
        connection.request("GET", path, headers={"Range": "bytes=0-51071"})
        response = connection.getresponse()
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read(1024)), 1024)
        response.close()
        connection.close()
        snapshot = self.fixture.stats()
        self.assertEqual(snapshot["active"], 0)
        self.assertIn({"event": "held_closed", "closed": True}, snapshot["records"])

    def test_pac_discriminates_initial_manifest_redirect_and_blob_full_urls(self):
        pac = self.registry.pac()
        base = f"https://{self.fixture.host}:{self.fixture.origin_port}"
        manifest = "/v2/library/native-pulled/manifests/latest"
        self.assertIn(
            "if (url == "
            + json.dumps(base + manifest)
            + ") return "
            + json.dumps(f"PROXY 127.0.0.1:{self.fixture.ports['first']}"),
            pac,
        )
        self.assertIn(
            "if (url == "
            + json.dumps(base + manifest + "?native=manifest")
            + ") return "
            + json.dumps(f"PROXY 127.0.0.1:{self.fixture.ports['second']}"),
            pac,
        )
        self.assertIn(
            f"PROXY 127.0.0.1:{self.fixture.ports['refused']}; PROXY 127.0.0.1:{self.fixture.ports['second']}",
            pac,
        )
        self.assertNotIn("FindProxyForURL(url, host) { return", pac)


if __name__ == "__main__":
    unittest.main()
