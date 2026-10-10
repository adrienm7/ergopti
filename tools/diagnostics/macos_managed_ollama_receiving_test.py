# tools/diagnostics/macos_managed_ollama_receiving_test.py
"""Actual portable TLS registry peers; no native daemon or PAC credit."""

import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import signal
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

    def test_bootstrap_dependencies_are_original_retained_compiler_inputs(self):
        class CompilerBoundary(Exception):
            pass

        def inspect(arguments, *, timeout):
            self.assertEqual(timeout, 90)
            context = self.subject.outgoing_context
            retained = {str(path): (fd, expected) for path, fd, _, expected in context._inputs}
            for name in (
                "ManagedCertificateAuthorities.swift",
                "ManagedBootstrapPolicy.generated.swift",
            ):
                relative = "static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/" + name
                original = ROOT / relative
                copied = self.subject.work / name
                expected = hashlib.sha256(original.read_bytes()).hexdigest()
                self.assertIn(str(copied), arguments)
                self.assertEqual(copied.read_bytes(), original.read_bytes())
                self.assertEqual(self.subject.source_hashes[relative], expected)
                for path in (original, copied):
                    descriptor, frozen = retained[str(path)]
                    self.assertEqual(frozen, expected)
                    self.assertEqual(os.fstat(descriptor).st_ino, path.stat().st_ino)
                    self.assertFalse(os.get_inheritable(descriptor))
                    self.assertEqual(
                        os.pread(descriptor, path.stat().st_size, 0), path.read_bytes()
                    )
            raise CompilerBoundary()

        self.fixture._command.side_effect = inspect
        with (
            patch.object(RECEIVING, "load", return_value=self.wire),
            patch.object(RECEIVING, "Registry"),
            self.assertRaises(CompilerBoundary),
        ):
            self.subject.prepare()
        self.fixture._command.assert_called_once()
        self.assertEqual(self.subject.outgoing_context._inputs, [])

    def test_changed_bootstrap_dependency_refuses_before_compiler(self):
        original_copy = self.subject.copy_source

        def mutate(relative, destination):
            original_copy(relative, destination)
            if relative.endswith("/ManagedCertificateAuthorities.swift"):
                destination.write_bytes(b"foreign certificate policy")

        def compiler_must_not_run(*arguments, **options):
            raise AssertionError("changed bootstrap dependency reached compiler")

        self.subject.copy_source = mutate
        self.fixture._command.side_effect = compiler_must_not_run
        with (
            patch.object(RECEIVING, "load", return_value=self.wire),
            patch.object(RECEIVING, "Registry"),
            self.assertRaisesRegex(RECEIVING.QUALIFIED.QualificationRefusal, "source"),
        ):
            self.subject.prepare()
        self.fixture._command.assert_not_called()
        self.assertEqual(self.subject.outgoing_context._inputs, [])

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


class PayloadDependencyControls(unittest.TestCase):
    def test_original_redirect_policy_is_copied_and_hash_bound_before_bootstrap_download(self):
        with tempfile.TemporaryDirectory(prefix="ergopti-ollama-payload-") as directory:
            root = Path(directory)
            catalogue = root / "fixture-catalogue.json"
            catalogue.write_text('{"fixture":"payload-only-no-install"}\n', encoding="utf-8")
            subject = RECEIVING.Receiver.__new__(RECEIVING.Receiver)
            subject.root = ROOT
            subject.source_hashes = {}
            subject.options = SimpleNamespace(catalogue=catalogue)
            payload = subject.payload(root / "OwnedPayload.app")
            relative = "static/ergopti_plus/_shared/data/http/redirect_policy.json"
            original = ROOT / relative
            copied = payload / "_shared/data/http/redirect_policy.json"
            self.assertEqual(copied.read_bytes(), original.read_bytes())
            self.assertEqual(
                subject.source_hashes[relative], hashlib.sha256(original.read_bytes()).hexdigest()
            )
            runtime = RECEIVING.load(
                "payload_only_ollama_runtime",
                payload / "macos/modules/llm/managed_ollama_runtime.py",
            )
            self.assertEqual(runtime.BOOTSTRAP.REDIRECT_POLICY, copied)
            request = Mock(side_effect=AssertionError("payload prerequisite cannot reach network"))
            output = root / "must-not-be-created"
            # A deliberately invalid digest reaches the real policy read, then
            # refuses before file acquisition or any native request constructor.
            with self.assertRaises(runtime.BOOTSTRAP.BootstrapFailure) as refused:
                runtime.BOOTSTRAP.download(
                    "https://payload.invalid/input", output, "invalid", 1, 10, 1, request=request
                )
            self.assertEqual(refused.exception.reason, "integrity")
            request.assert_not_called()
            self.assertFalse(output.exists())


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

        def make_empty_session(deadline, port):
            path = create_session(deadline, port)
            return SimpleNamespace(
                path=path,
                data=self.session | {"port": str(port)},
                retire=lambda: None,
            )

        subject.make_empty_session = make_empty_session
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

    def test_duplicate_start_cannot_overwrite_live_session_or_source_owner(self):
        subject = RECEIVING.Receiver.__new__(RECEIVING.Receiver)
        live = SimpleNamespace(physically_retired=False)
        subject.daemon = live
        subject.make_empty_session = Mock()
        old_session = SimpleNamespace(path=self.root / "existing-session")
        subject.session_owner = old_session
        descriptor = os.open(self.binary, os.O_RDONLY)
        subject.binary_descriptor = descriptor
        try:
            with self.assertRaisesRegex(RuntimeError, "actual_receiver_start_state"):
                subject.start()
            subject.make_empty_session.assert_not_called()
            self.assertIs(subject.session_owner, old_session)
            self.assertIs(subject.daemon, live)
            self.assertEqual(subject.binary_descriptor, descriptor)
            self.assertIsNotNone(os.fstat(descriptor))
        finally:
            os.close(descriptor)

    def test_real_source_close_sigint_keeps_debt_without_closing_reused_fd(self):
        subject = RECEIVING.Receiver.__new__(RECEIVING.Receiver)
        subject.daemon = None
        descriptor = os.open(self.binary, os.O_RDONLY)
        subject.binary_descriptor = descriptor
        actual_close = os.close
        reused = None

        def interrupted(value):
            nonlocal reused
            actual_close(value)
            reused = os.open(self.binary, os.O_RDONLY)
            self.assertEqual(reused, value)
            signal.raise_signal(signal.SIGINT)

        try:
            with patch.object(RECEIVING.os, "close", side_effect=interrupted):
                with self.assertRaisesRegex(RuntimeError, "actual_source_close_debt"):
                    subject.stop()
            self.assertIsNone(subject.binary_descriptor)
            self.assertIsInstance(subject._source_close_debt, KeyboardInterrupt)
            self.assertIsNotNone(os.fstat(reused))
            with self.assertRaisesRegex(RuntimeError, "actual_source_close_debt"):
                subject.stop()
            self.assertIsNotNone(os.fstat(reused))
        finally:
            if reused is not None:
                actual_close(reused)


class BoundAliasOwnerControls(unittest.TestCase):
    def setUp(self):
        self.api = SimpleNamespace(discover=Mock(), open_request=Mock())
        self.expected = {
            "pid": 123,
            "uid": os.geteuid(),
            "start_seconds": "100",
            "start_microseconds": "250",
            "device": "1",
            "inode": "9007199254740993",
        }
        self.proof = {"version": 1, "nonce": "a" * 32}
        self.ports = RECEIVING.BoundAliasPorts(self.api, self.proof, self.expected)

    def test_zero_byte_discovery_binds_exact_acquired_child_before_hmac(self):
        self.api.discover.return_value = dict(self.expected)
        observed = self.ports.discover("/owned/ollama", "1", "9007199254740993", 11434, 5, 60)
        self.assertEqual(observed, self.expected)
        self.api.discover.assert_called_once_with(
            "/owned/ollama",
            "1",
            "9007199254740993",
            11434,
            5,
            60,
            source_alias=self.proof,
        )
        self.api.open_request.assert_not_called()

    def test_foreign_daemon_with_same_catalogue_inode_refuses_before_secret_request(self):
        self.api.discover.return_value = self.expected | {"pid": 124}
        with self.assertRaisesRegex(RuntimeError, "actual_acquired_daemon_listener"):
            self.ports.discover("/owned/ollama", "1", "9007199254740993", 11434, 5, 60)
        self.api.open_request.assert_not_called()

    def test_private_api_request_cannot_replace_original_child_start_tuple(self):
        with self.assertRaisesRegex(RuntimeError, "actual_acquired_daemon_listener"):
            self.ports.open_request(
                "/owned/ollama",
                "1",
                "9007199254740993",
                11434,
                self.expected | {"start_seconds": "101"},
                "GET",
                "/admission",
                [],
                "",
                5,
                60,
            )
        self.api.open_request.assert_not_called()


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


class TerminalFailureObservationControls(unittest.TestCase):
    """Exercise the real CLI catches and receipt writer with recording owners."""

    def receive(self, primary=None, cleanup=None):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            owner = SimpleNamespace(
                stage="prepare",
                output=output,
                receipt={
                    "version": 1,
                    "profile": "pac-inline",
                    "success": False,
                    "private_children_retired": False,
                    "native_trust_restored": False,
                },
                run=Mock(side_effect=primary),
                close=Mock(side_effect=cleanup),
            )
            arguments = [
                "receiving",
                "--archive",
                "private-archive",
                "--catalogue",
                "private-catalogue",
                "--launcher",
                "private-launcher",
                "--framework",
                "private-framework",
                "--output",
                str(output),
                "--profile",
                "pac-inline",
            ]
            with (
                patch.object(RECEIVING.sys, "argv", arguments),
                patch.object(RECEIVING.sys, "platform", "darwin"),
                patch.object(RECEIVING, "Receiver", return_value=owner),
            ):
                status = RECEIVING.main()
            owner.run.assert_called_once_with()
            owner.close.assert_called_once_with()
            return status, (output / "native-receiving.json").read_text()

    def test_primary_and_cleanup_failure_retain_both_closed_facts(self):
        status, raw = self.receive(
            RuntimeError("actual_archive_name"), OSError("private-path/token")
        )
        value = json.loads(raw)
        self.assertEqual(status, 1)
        self.assertFalse(value["success"])
        self.assertEqual(value["reason"], "native_receiving_cleanup_failed")
        self.assertEqual(value["failed_stage"], "prepare")
        self.assertEqual(
            value["primary_failure"],
            {"exception_class": "RuntimeError", "code": "actual_archive_name"},
        )
        self.assertEqual(value["cleanup_failure"], {"exception_class": "OSError", "code": None})
        self.assertFalse(value["native_trust_restored"])
        self.assertNotIn("private-path", raw)
        self.assertNotIn("token", raw)

    def test_cleanup_only_failure_never_claims_success_or_primary_failure(self):
        class PrivateExceptionName(Exception):
            pass

        status, raw = self.receive(cleanup=PrivateExceptionName("https://private.invalid/secret"))
        value = json.loads(raw)
        self.assertEqual(status, 1)
        self.assertFalse(value["success"])
        self.assertEqual(value["reason"], "native_receiving_cleanup_failed")
        self.assertEqual(value["cleanup_failure"], {"exception_class": "unknown", "code": None})
        self.assertNotIn("primary_failure", value)
        self.assertNotIn("failed_stage", value)
        self.assertNotIn("private.invalid", raw)
        self.assertNotIn("PrivateExceptionName", raw)

    def test_success_and_primary_only_failure_preserve_original_outcomes(self):
        status, raw = self.receive()
        value = json.loads(raw)
        self.assertEqual(status, 0)
        self.assertTrue(value["success"])
        self.assertEqual(value["reason"], "complete")
        self.assertNotIn("primary_failure", value)
        self.assertNotIn("cleanup_failure", value)
        status, raw = self.receive(primary=FileNotFoundError("private-input-name"))
        value = json.loads(raw)
        self.assertEqual(status, 1)
        self.assertFalse(value["success"])
        self.assertEqual(value["reason"], "native_receiving_failed")
        self.assertEqual(
            value["primary_failure"], {"exception_class": "FileNotFoundError", "code": None}
        )
        self.assertNotIn("cleanup_failure", value)
        self.assertNotIn("private-input-name", raw)


if __name__ == "__main__":
    unittest.main()
