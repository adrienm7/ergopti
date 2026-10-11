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
                "OwnedImageAliasCompatibility.h",
                "OwnedSuspendedImageCompatibility.h",
                "OwnedListenerEventCompatibility.h",
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
            self.assertEqual(
                {path.name for path in module.glob("*.h")},
                {
                    "CPOSIXCompatibility.h",
                    "OwnedProgramCompatibility.h",
                    "LoopbackListenerCompatibility.h",
                    "OwnedImageAliasCompatibility.h",
                    "OwnedSuspendedImageCompatibility.h",
                    "OwnedListenerEventCompatibility.h",
                },
            )
            self.assertIn(
                '#include "OwnedListenerEventCompatibility.h"',
                (module / "CPOSIXCompatibility.h").read_text(),
            )
            retained = {
                str(path): (descriptor, expected)
                for path, descriptor, _, expected in self.subject.outgoing_context._inputs
            }
            for name in (
                "CPOSIXCompatibility.h",
                "OwnedProgramCompatibility.h",
                "LoopbackListenerCompatibility.h",
                "OwnedImageAliasCompatibility.h",
                "OwnedSuspendedImageCompatibility.h",
                "OwnedListenerEventCompatibility.h",
            ):
                original = (
                    ROOT
                    / "static/ergopti_plus/macos/launcher/Sources/CPOSIXCompatibility/include"
                    / name
                )
                for path in (original, module / name):
                    self.assertIn(str(path), retained)
                    descriptor, expected = retained[str(path)]
                    self.assertEqual(expected, hashlib.sha256(path.read_bytes()).hexdigest())
                    self.assertEqual(os.fstat(descriptor).st_ino, path.stat().st_ino)
                    self.assertFalse(os.get_inheritable(descriptor))
                    self.assertEqual(
                        os.pread(descriptor, path.stat().st_size, 0), path.read_bytes()
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

    def test_original_compiler_exception_leaves_exact_prepare_checkpoint(self):
        class CompilerBoundary(Exception):
            pass

        primary = CompilerBoundary("private compiler text must not be projected")
        self.fixture._command.side_effect = primary
        with (
            patch.object(RECEIVING, "load", return_value=self.wire),
            patch.object(RECEIVING, "Registry"),
        ):
            with self.assertRaises(CompilerBoundary) as raised:
                self.subject.prepare()
        self.assertIs(raised.exception, primary)
        self.assertEqual(self.subject.prepare_phase, "outgoing_compile")
        self.fixture._command.assert_called_once()
        self.assertEqual(self.fixture._command.call_args.kwargs, {"timeout": 90})
        self.assertEqual(self.subject.outgoing_context._inputs, [])


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


class FatalFailureObservationControls(unittest.TestCase):
    def run_main(self, primary=None, cleanup=None, step="outgoing_compile"):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        output = Path(temporary.name)
        calls = []
        owner = SimpleNamespace(output=output, stage="prepare", prepare_phase=step, receipt={})

        def run():
            calls.append("run")
            if primary is not None:
                raise primary

        def close():
            calls.append("close")
            if cleanup is not None:
                raise cleanup

        owner.run, owner.close = run, close
        arguments = [
            "native-receiving",
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
        ):
            with patch.object(RECEIVING, "Receiver", return_value=owner) as constructor:
                status = RECEIVING.main()
        constructor.assert_called_once()
        self.assertEqual(calls, ["run", "close"])
        result = json.loads((output / "native-receiving.json").read_text())
        return status, result

    def test_primary_and_cleanup_failures_remain_independent_and_fatal(self):
        status, result = self.run_main(
            RuntimeError("actual_native_command"),
            RECEIVING.QUALIFIED.QualificationRefusal("cleanup"),
        )
        self.assertEqual(status, 1)
        self.assertIs(result["success"], False)
        self.assertEqual(result["reason"], "native_receiving_cleanup_failed")
        self.assertEqual(result["failed_stage"], "prepare")
        self.assertEqual(result["prepare_phase"], "outgoing_compile")
        self.assertEqual(
            result["primary_failure"], {"family": "receiver", "code": "actual_native_command"}
        )
        self.assertEqual(result["cleanup_failure"], {"family": "qualification", "code": "cleanup"})

    def test_primary_only_keeps_original_failure_reason(self):
        status, result = self.run_main(RuntimeError("compatibility_source_copy"))
        self.assertEqual(status, 1)
        self.assertIs(result["success"], False)
        self.assertEqual(result["reason"], "native_receiving_failed")
        self.assertEqual(
            result["primary_failure"], {"family": "receiver", "code": "compatibility_source_copy"}
        )
        self.assertNotIn("cleanup_failure", result)

    def test_cleanup_only_reports_closed_os_code_without_private_filename(self):
        status, result = self.run_main(
            cleanup=PermissionError(13, "private-message", "/private/key-path")
        )
        self.assertEqual(status, 1)
        self.assertIs(result["success"], False)
        self.assertEqual(result["reason"], "native_receiving_cleanup_failed")
        self.assertNotIn("primary_failure", result)
        self.assertNotIn("prepare_phase", result)
        self.assertEqual(result["cleanup_failure"], {"family": "os", "code": "permission"})
        self.assertNotIn("private", json.dumps(result))

    def test_raw_messages_foreign_types_and_raw_stage_never_reach_receipt(self):
        class Foreign(RuntimeError):
            def __str__(self):
                raise AssertionError("foreign exception text was accessed")

        for primary, expected in [
            (Foreign("actual_native_command"), {"family": "unknown", "code": "unknown"}),
            (
                RECEIVING.subprocess.TimeoutExpired(["private-key", "secret"], 15),
                {"family": "command", "code": "deadline"},
            ),
            (
                RECEIVING.subprocess.CalledProcessError(
                    1, ["private-key", "secret"], output=b"private"
                ),
                {"family": "command", "code": "refused"},
            ),
            (
                RuntimeError("private-key /path?token=secret"),
                {"family": "receiver", "code": "unknown"},
            ),
            (
                RuntimeError("actual_native_command", "secret"),
                {"family": "receiver", "code": "unknown"},
            ),
            (
                RECEIVING.QUALIFIED.QualificationRefusal("private-key"),
                {"family": "qualification", "code": "unknown"},
            ),
        ]:
            with self.subTest(kind=type(primary).__name__):
                status, result = self.run_main(primary, step="/private/secret-stage")
                self.assertEqual(status, 1)
                self.assertEqual(result["primary_failure"], expected)
                self.assertEqual(result["prepare_phase"], "unknown")
                self.assertNotIn("secret", json.dumps(result))
                self.assertNotIn("private", json.dumps(result))

    def test_wrapped_qualification_and_cancellation_have_closed_facts(self):
        primary = RECEIVING.QUALIFIED.QualificationRefusal(
            "operation",
            primary=RuntimeError("actual_native_command"),
            cleanup=OSError(5, "private cleanup errno text"),
        )
        status, result = self.run_main(primary, KeyboardInterrupt("private-cancel-text"))
        self.assertEqual(status, 1)
        self.assertEqual(
            result["primary_failure"],
            {
                "family": "qualification",
                "code": "operation",
                "operation_primary": {"family": "receiver", "code": "actual_native_command"},
                "operation_cleanup": {"family": "os", "code": "unknown"},
            },
        )
        self.assertEqual(
            result["cleanup_failure"], {"family": "cancellation", "code": "interrupted"}
        )
        self.assertNotIn("private", json.dumps(result))

    def test_success_keeps_original_complete_verdict_and_no_failure_fields(self):
        status, result = self.run_main()
        self.assertEqual(status, 0)
        self.assertIs(result["success"], True)
        self.assertEqual(result["reason"], "complete")
        self.assertNotIn("primary_failure", result)
        self.assertNotIn("cleanup_failure", result)
        self.assertNotIn("prepare_phase", result)


if __name__ == "__main__":
    unittest.main()
