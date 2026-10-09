# tools/diagnostics/macos_ollama_bootstrap_owner_test.py
"""Actual private POSIX files and independent HMAC vectors; Darwin is unrun."""

import base64
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))
POLICY_PATH = Path(
    os.environ.get(
        "ERGOPTI_BOOTSTRAP_POLICY",
        SOURCE / "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json",
    )
)


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


BOOT = load(
    "bootstrap_owner", ROOT / "static/ergopti_plus/macos/platform/ollama_bootstrap_owner.py"
)
PROXY = load(
    "bootstrap_proxy", SOURCE / "static/ergopti_plus/_shared/python/network_proxy_policy.py"
)


@unittest.skipUnless(os.name == "posix", "Native file ownership requires POSIX")
class BootstrapOwnerControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.policy = BOOT.BootstrapPolicy(POLICY_PATH, PROXY.ProxyPolicy())
        self.calls = []
        self.operation = SimpleNamespace(
            image_ready=False,
            physically_retired=False,
            progress=lambda: self.calls.append("clock"),
            recheck_source=lambda: self.calls.append("source"),
        )
        self.session = BOOT.OWNER.EmptySession.acquire(
            self.root / "sessions", {"token": "12" * 32}, register=lambda value: None
        )
        self.bootstrap = None
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.operation.physically_retired = True
        if self.bootstrap is not None:
            self.bootstrap.retire()
        self.session.retire()

    def acquire(self, environment=None):
        with patch.dict(os.environ, environment or {}, clear=True):
            snapshot = self.policy.capture(60000)
        self.bootstrap = BOOT.EmptyNetworkBootstrap.acquire(
            self.session, snapshot, register=lambda value: None
        )
        self.session.bind_operation(self.operation)
        self.bootstrap.bind_operation(self.operation)
        return snapshot

    def release(self):
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        self.bootstrap.release_key(self.operation)
        return json.loads(self.bootstrap.path.read_bytes())

    def test_empty_files_before_actual_image_proof(self):
        self.acquire({"HTTPS_PROXY": "http://user:secret@proxy.invalid:8080"})
        self.assertEqual(self.session.path.read_bytes(), b"")
        self.assertEqual(self.bootstrap.path.read_bytes(), b"")
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.release_key(self.operation)
        self.assertEqual(self.bootstrap.path.read_bytes(), b"")
        self.assertEqual(self.calls, [])

    def test_private_authenticated_bytes_match_independent_vector(self):
        self.acquire(
            {
                "HTTPS_PROXY": "http://name:secret@proxy.invalid:8080",
                "SSL_CERT_FILE": "/private/cert.pem",
            }
        )
        outer = self.release()
        raw = base64.b64decode(outer["payload"], validate=True)
        session_digest = hashlib.sha256(self.session.path.read_bytes()).hexdigest()
        expected = hmac.new(
            bytes.fromhex("12" * 32),
            b"ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n" + session_digest.encode() + b"\n" + raw,
            hashlib.sha256,
        ).hexdigest()
        self.assertEqual(set(outer), {"version", "session_sha256", "payload", "mac"})
        self.assertEqual(outer["session_sha256"], session_digest)
        self.assertEqual(outer["mac"], expected)
        self.assertEqual(self.bootstrap.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.bootstrap.path.stat().st_nlink, 1)
        self.assertEqual(self.calls.count("source"), 4)

    def test_proxy_case_empty_bypass_and_certificate_capture_preserved(self):
        values = {
            "HTTPS_PROXY": "",
            "https_proxy": "http://private:token@relay:8080",
            "ALL_PROXY": "http://all:8080",
            "no_proxy": ".internal,127.0.0.0/8",
            "NO_PROXY": "",
            "SSL_CERT_FILE": "",
            "SSL_CERT_DIR": "/certs",
            "UNRELATED_SECRET": "never-copy",
            "ERGOPTI_OLLAMA_NATIVE_SESSION": "never-copy",
        }
        self.acquire(values)
        payload = json.loads(base64.b64decode(self.release()["payload"]))
        self.assertEqual(
            dict(payload["environment"]),
            {
                name: value
                for name, value in values.items()
                if name not in ("UNRELATED_SECRET", "ERGOPTI_OLLAMA_NATIVE_SESSION")
            },
        )
        self.assertEqual(len(payload["environment"]), len(dict(payload["environment"])))

    def test_capture_does_not_follow_later_environment_mutation(self):
        self.acquire({"https_proxy": "http://original:8080"})
        with patch.dict(os.environ, {"https_proxy": "http://foreign:8080"}):
            payload = json.loads(base64.b64decode(self.release()["payload"]))
        self.assertEqual(dict(payload["environment"]), {"https_proxy": "http://original:8080"})

    def test_custom_store_outside_home_raw_setting_and_actual_cwd(self):
        value = "/Volumes/External User Models/../original"
        cwd = os.getcwd()
        self.acquire({"OLLAMA_MODELS": value})
        fields = self.bootstrap.fields()
        payload = json.loads(base64.b64decode(self.release()["payload"]))
        self.assertEqual(payload["store"], {"mode": "environment", "value": value, "cwd": cwd})
        self.assertEqual(fields["models_path"], value)
        self.assertEqual(fields["store_cwd"], cwd)
        self.assertEqual(fields["proxy_url"], "")

    def test_relative_store_remains_relative(self):
        self.acquire({"OLLAMA_MODELS": "../models with spaces"})
        payload = json.loads(base64.b64decode(self.release()["payload"]))
        self.assertEqual(payload["store"]["value"], "../models with spaces")

    def test_empty_store_uses_original_default_without_materializing_path(self):
        self.acquire({"OLLAMA_MODELS": ""})
        payload = json.loads(base64.b64decode(self.release()["payload"]))
        self.assertEqual(payload["store"]["mode"], "default")
        self.assertEqual(payload["store"]["value"], "")

    def test_bound_operation_and_session_release_are_required(self):
        self.acquire()
        self.operation.image_ready = True
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.release_key(self.operation)
        self.session.release_key(self.operation)
        foreign = SimpleNamespace(image_ready=True, physically_retired=False)
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.release_key(foreign)
        self.assertEqual(self.bootstrap.path.read_bytes(), b"")

    def test_public_fields_contain_no_credentials(self):
        self.acquire({"HTTPS_PROXY": "http://user:very-private@relay:8080"})
        fields = self.bootstrap.fields()
        self.assertEqual(fields["bootstrap_device"], str(self.bootstrap.path.stat().st_dev))
        self.assertEqual(fields["bootstrap_inode"], str(self.bootstrap.path.stat().st_ino))
        self.assertNotIn("very-private", json.dumps(fields))
        self.assertEqual(self.bootstrap.name, "network-" + self.session.name[len("daemon-") :])
        self.assertFalse(os.get_inheritable(self.bootstrap._directory_fd))
        self.assertFalse(os.get_inheritable(self.bootstrap._file_fd))

    def test_active_owner_prevents_file_retirement(self):
        self.acquire()
        self.release()
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.retire()
        self.assertTrue(self.bootstrap.path.exists())
        self.operation.physically_retired = True
        self.bootstrap.retire()
        self.assertFalse(self.bootstrap.path.exists())

    def test_replaced_namespace_refuses_before_secret_write(self):
        self.acquire()
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        old = self.bootstrap.path.with_suffix(".held")
        self.bootstrap.path.rename(old)
        self.bootstrap.path.write_bytes(b"foreign")
        self.bootstrap.path.chmod(0o600)
        try:
            with self.assertRaises(BOOT.ImageRefusal):
                self.bootstrap.release_key(self.operation)
            self.assertEqual(old.read_bytes(), b"")
            self.assertEqual(self.bootstrap.path.read_bytes(), b"foreign")
        finally:
            self.bootstrap.path.unlink()
            old.rename(self.bootstrap.path)

    def test_partial_write_failure_keeps_exact_prefix_until_retirement(self):
        self.acquire()
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        original = os.write
        calls = 0

        def write(descriptor, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                return original(descriptor, data[:7])
            raise OSError("independent failure")

        with patch.object(BOOT.os, "write", write):
            with self.assertRaises(OSError):
                self.bootstrap.release_key(self.operation)
        self.assertEqual(self.bootstrap.path.read_bytes(), self.bootstrap._written)
        self.assertEqual(len(self.bootstrap._written), 7)
        self.operation.physically_retired = True
        self.bootstrap.retire()
        self.assertFalse(self.bootstrap.path.exists())

    def test_sigint_after_physical_close_records_debt_and_closes_other_fd(self):
        self.acquire()
        self.operation.physically_retired = True
        descriptors = [self.bootstrap._file_fd, self.bootstrap._directory_fd]
        original = os.close
        calls = 0

        def close(descriptor):
            nonlocal calls
            calls += 1
            original(descriptor)
            if calls == 1:
                os.kill(os.getpid(), signal.SIGINT)

        with patch.object(BOOT.os, "close", close):
            with self.assertRaises(BOOT.ImageRefusal):
                self.bootstrap.retire()
        self.assertEqual(calls, 2)
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.retire()
        self.bootstrap = None

    def test_invalid_token_and_budget_refused(self):
        self.acquire()
        for token in ("a" * 63, "A" * 64, "g" * 64, True):
            with self.assertRaises(BOOT.ImageRefusal):
                self.bootstrap.snapshot.authenticated_bytes(b"session", token)
        for budget in (0, -1, True, 1.5, 2**31):
            with self.assertRaises(BOOT.ImageRefusal):
                self.policy.capture(budget)

    def test_oversize_outer_envelope_refused_not_truncated(self):
        self.acquire(
            {
                name: '"' * self.policy.maximum_value_bytes
                for name in PROXY.ProxyPolicy().system_lookup_environment_exclusions
            }
        )
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.release_key(self.operation)
        self.assertEqual(self.bootstrap.path.read_bytes(), b"")

    def test_utf8_individual_values_and_raw_store_refuse_before_file_acquisition(self):
        for values in (
            {"HTTPS_PROXY": "a" * (self.policy.maximum_value_bytes + 1)},
            {"SSL_CERT_DIR": "é" * (self.policy.maximum_value_bytes // 2 + 1)},
            {"OLLAMA_MODELS": "a" * (self.policy.maximum_value_bytes + 1)},
        ):
            with patch.dict(os.environ, values, clear=True):
                with self.assertRaises(BOOT.ImageRefusal):
                    self.policy.capture(60000)
        self.assertEqual(self.session.path.read_bytes(), b"")

    def test_duplicate_policy_fields_and_source_digest_mismatch_refuse(self):
        raw = POLICY_PATH.read_bytes()
        bad = self.root / "duplicate.json"
        bad.write_bytes(raw[:-2] + b',"schema_version":1}\n')
        with self.assertRaises(BOOT.ImageRefusal):
            BOOT.BootstrapPolicy(bad, PROXY.ProxyPolicy())
        with self.assertRaises(BOOT.ImageRefusal):
            BOOT.BootstrapPolicy(
                POLICY_PATH, PROXY.ProxyPolicy(), expected_contract_sha256="0" * 64
            )
        BOOT.BootstrapPolicy(
            POLICY_PATH,
            PROXY.ProxyPolicy(),
            expected_contract_sha256=hashlib.sha256(raw).hexdigest(),
        )

    def test_envelope_authentication_rejects_foreign_session_mac_and_duplicate_keys(self):
        policy = self.policy.shared
        raw = b'{"source_alias":{},"listener":{}}'
        sealed = policy.seal(raw, b"original-session", "12" * 32)
        self.assertEqual(policy.authenticate(sealed, b"original-session", "12" * 32), raw)
        for session, token in ((b"foreign-session", "12" * 32), (b"original-session", "34" * 32)):
            with self.assertRaises(BOOT.POLICY.BootstrapRefusal):
                policy.authenticate(sealed, session, token)
        duplicate = sealed[:-2] + b',"version":1}\n'
        with self.assertRaises(BOOT.POLICY.BootstrapRefusal):
            policy.authenticate(duplicate, b"original-session", "12" * 32)


PEER = r"""
import base64, hashlib, hmac, json, os, pathlib, subprocess, sys, time
request = json.loads(sys.stdin.readline())
session = pathlib.Path(request['session_path'])
bootstrap = pathlib.Path(request['bootstrap_path'])
assert session.read_bytes() == bootstrap.read_bytes() == b''
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
try:
    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], request['inode'], flush=True)
    while True:
        line = sys.stdin.readline()
        if line == 'ACTIVATE\n':
            key = json.loads(session.read_bytes())['token']
            outer = json.loads(bootstrap.read_bytes())
            raw = base64.b64decode(outer['payload'], validate=True)
            digest = hashlib.sha256(session.read_bytes()).hexdigest()
            assert outer['session_sha256'] == digest
            assert outer['mac'] == hmac.new(bytes.fromhex(key), b'ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n' + digest.encode() + b'\n' + raw, hashlib.sha256).hexdigest()
            assert dict(json.loads(raw)['environment'])['HTTPS_PROXY'] == 'http://private:token@relay:8080'
            print('V1 ACTIVE', flush=True)
        elif line == 'CANCEL\n' or line == '':
            child.terminate()
            child.wait()
            mode = pathlib.Path(__file__).parent.parent.parent / 'mode'
            kind = mode.read_text()
            print('V1 OUTGOING_CLOSED 0', flush=True)
            if kind != 'missing-bootstrap':
                print('V1 BOOTSTRAP_CLOSED', 5 if kind == 'close-error' else 0, flush=True)
            print('V1 RETIRED 143 1 1 0 0 0 0', flush=True)
            if kind == 'held-eof':
                while not mode.with_name('release').exists(): time.sleep(.01)
            break
finally:
    if child.poll() is None:
        child.terminate()
        child.wait()
"""


@unittest.skipUnless(os.name == "posix", "Native protocol owner requires POSIX")
class BootstrapProtocolControls(unittest.TestCase):
    def setUp(self):
        self.fixture_module = load(
            "bootstrap_protocol_fixture",
            ROOT / "tools/diagnostics/macos_suspended_image_owner_test.py",
        )
        self.fixture = self.fixture_module.ActualOwnerControls("runTest")
        self.fixture.setUp()
        self.bootstrap = None
        self.addCleanup(self.cleanup)

    def cleanup(self):
        fixture = self.fixture
        fixture.mode.with_name("release").touch()
        if fixture.operation is not None:
            fixture.operation.settle(timeout=5)
            if fixture.operation._protocol_debt:
                # Only this independent peer fixture provides its known child
                # retirement in finally. Production debt remains refused.
                fixture.operation.process.wait(timeout=5)
                self.bootstrap._operation = None
        if self.bootstrap is not None:
            self.bootstrap.retire()
        fixture.doCleanups()

    def start(self, kind="normal"):
        fixture = self.fixture
        with patch.object(self.fixture_module, "PEER", PEER):
            fixture.build()
        fixture.mode.write_text(kind)
        fixture.empty_session()
        policy = BOOT.BootstrapPolicy(POLICY_PATH, PROXY.ProxyPolicy())
        with patch.dict(os.environ, {"HTTPS_PROXY": "http://private:token@relay:8080"}, clear=True):
            snapshot = policy.capture(60000)
        self.bootstrap = BOOT.EmptyNetworkBootstrap.acquire(
            fixture.session, snapshot, register=lambda value: None
        )
        request = {
            "version": 1,
            "remaining_ms": 3000,
            "device": "1",
            "inode": "9007199254740993",
            "session_path": str(fixture.session.path),
            **fixture.worker.fields(),
            **self.bootstrap.fields(),
        }
        fixture.operation = self.fixture_module.OWNER.SuspendedImageOwner(
            fixture.binary,
            request,
            fixture.session,
            lambda: None,
            fixture.worker,
            bootstrap=self.bootstrap,
            register=lambda value: setattr(fixture, "operation", value),
        )
        fixture.operation.start()
        self.assertTrue(fixture.operation.active)
        return fixture.operation

    def test_real_protocol_peer_checks_authenticated_bytes_after_image_before_active(self):
        operation = self.start()
        self.assertTrue(operation.settle(timeout=5))
        self.assertTrue(operation.physically_retired)
        self.assertEqual(operation.public_receipt()["bootstrap_close_errno"], 0)
        self.assertNotIn("private:token", json.dumps(operation.public_receipt()))

    def test_missing_bootstrap_close_remains_protocol_debt(self):
        operation = self.start("missing-bootstrap")
        self.assertFalse(operation.settle(timeout=5))
        self.assertFalse(operation.physically_retired)
        self.assertTrue(operation._protocol_debt)

    def test_bootstrap_close_failure_is_not_reported_as_success(self):
        operation = self.start("close-error")
        self.assertFalse(operation.settle(timeout=5))
        self.assertTrue(operation.physically_retired)
        self.assertEqual(operation.public_receipt()["bootstrap_close_errno"], 5)

    def test_marker_without_eof_cannot_retire_or_delete_bootstrap(self):
        operation = self.start("held-eof")
        self.assertFalse(operation.settle(timeout=0.05))
        self.assertFalse(operation.physically_retired)
        with self.assertRaises(BOOT.ImageRefusal):
            self.bootstrap.retire()
        self.assertTrue(self.bootstrap.path.exists())
        self.fixture.mode.with_name("release").touch()
        self.assertTrue(operation.settle(timeout=5))


if __name__ == "__main__":
    unittest.main()
