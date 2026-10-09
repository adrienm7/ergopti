# tools/diagnostics/macos_managed_ollama_serve_test.py
"""Actual private serve composition over POSIX peers; native SDK/signing unrun."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))
DEPENDENCY = Path(os.environ.get("ERGOPTI_SERVE_DEPENDENCY", ROOT))


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


PEER = r"""
import base64, hashlib, hmac, json, os, pathlib, subprocess, sys
request = json.loads(sys.stdin.readline())
session = pathlib.Path(request['session_path'])
bootstrap = pathlib.Path(request['bootstrap_path'])
assert session.read_bytes() == bootstrap.read_bytes() == b''
assert request['proxy_url'] == '' and request['arguments'] == ['serve']
assert not any(name in request for name in ('token','environment','outgoing_worker'))
mode = pathlib.Path(__file__).parents[2] / 'mode'
if mode.read_text() == 'refuse':
    print('V1 REFUSED 116', flush=True)
    raise SystemExit(0)
child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
try:
    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], request['inode'], flush=True)
    while True:
        line = sys.stdin.readline()
        if line == 'ACTIVATE\n':
            raw_session = session.read_bytes()
            data = json.loads(raw_session)
            envelope = json.loads(bootstrap.read_bytes())
            raw = base64.b64decode(envelope['payload'], validate=True)
            message = b'ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n' + hashlib.sha256(raw_session).hexdigest().encode() + b'\n' + raw
            assert envelope['mac'] == hmac.new(bytes.fromhex(data['token']),message,hashlib.sha256).hexdigest()
            captured = json.loads(raw)
            assert captured['store']['value'] == request['models_path']
            assert captured['store']['cwd'] == request['store_cwd']
            assert captured['store']['mode'] == request['store_mode']
            print('V1 ACTIVE', flush=True)
        elif line == 'CANCEL\n' or line == '':
            child.terminate(); child.wait()
            print('V1 OUTGOING_CLOSED 0', flush=True)
            print('V1 BOOTSTRAP_CLOSED 0', flush=True)
            print('V1 RETIRED 143 1 1 0 0 0 0', flush=True)
            break
finally:
    if child.poll() is None:
        child.terminate(); child.wait()
"""


@unittest.skipUnless(os.name == "posix", "Actual private POSIX process/file owners required")
class ProductionServeControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        self.app = self.home / "Native.app"
        self.launcher = self.app / "Contents/MacOS/ErgoptiPlus"
        self.launcher.parent.mkdir(parents=True)
        self.launcher.write_text("#!" + sys.executable + "\n" + PEER)
        self.launcher.chmod(0o755)
        (self.app / "mode").write_text("normal")
        payload = self.app / "Contents/Resources/static/ergopti_plus"
        dependencies = [
            "macos/platform/suspended_image_owner.py",
            "macos/platform/ollama_bootstrap_owner.py",
            "macos/platform/trusted_native_guardian.py",
            "macos/platform/ollama_daemon_authority.py",
            "_shared/python/managed_ollama_bootstrap.py",
            "_shared/python/managed_ollama_daemon_authority.py",
            "_shared/python/managed_ollama_runtime.py",
            "_shared/python/managed_source_alias.py",
            "_shared/python/network_proxy_policy.py",
            "_shared/modules/network/proxy_policy.json",
            "_shared/modules/llm/managed_ollama_bootstrap.json",
        ]
        for relative in dependencies:
            target = payload / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(DEPENDENCY / "static/ergopti_plus" / relative, target)
        for relative in (
            "macos/platform/source_alias_owner.py",
            "macos/platform/network/native_http.py",
            "macos/modules/llm/managed_ollama_runtime.py",
            "macos/modules/llm/managed_bootstrap_http.py",
        ):
            target = payload / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / "static/ergopti_plus" / relative, target)
        destination = payload / "macos/modules/llm/managed_ollama_serve.py"
        shutil.copy2(
            ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_serve.py", destination
        )
        self.subject = load("actual_production_serve", destination)
        self.target = self.home / "Library/Application Support/Ergopti/ollama-native-http"
        self.target.mkdir(parents=True, mode=0o755)
        # The production alias policy requires an actual private owned ancestor.
        self.target.parent.chmod(0o700)
        self.binary = self.target / "ollama"
        self.binary.write_bytes(b"independent admitted runtime bytes; no Mach-O claim")
        self.binary.chmod(0o755)
        self.asset = {
            "source_commit": "ab" * 20,
            "sha256": "cd" * 32,
            "binary_sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "native_http_capability": 1,
        }
        contract = b'{"fixture":"native signature and catalogue ports are injected"}'
        catalogue = json.dumps(
            {
                "repository_source_sha256": {
                    "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json": hashlib.sha256(
                        (payload / "_shared/modules/llm/managed_ollama_bootstrap.json").read_bytes()
                    ).hexdigest()
                }
            }
        ).encode()
        self.input_values = (contract, catalogue, "macos-arm64", {}, self.asset)
        self.native_calls = []

        def native_verify(*arguments, **options):
            self.native_calls.append((arguments, options))
            return self.binary

        for control in (
            patch.object(self.subject.RUNTIME, "inputs", return_value=self.input_values),
            patch.object(self.subject.RUNTIME, "native_verify", side_effect=native_verify),
            patch.dict(
                os.environ,
                {
                    "HOME": str(self.home),
                    "ERGOPTI_LAUNCHER_EXECUTABLE": str(self.launcher),
                    "ERGOPTI_LAUNCHER_DEVICE": str(self.launcher.stat().st_dev),
                    "ERGOPTI_LAUNCHER_INODE": str(self.launcher.stat().st_ino),
                },
                clear=True,
            ),
        ):
            control.start()
            self.addCleanup(control.stop)
        self.owner = None
        self.addCleanup(self.retire)

    def retire(self):
        if self.owner is not None:
            self.owner.cancelled = False
            self.owner.retire(5)

    def prepare(self):
        self.owner = self.subject.ServeOwner(
            11434, 5, 60, 5, register=lambda value: setattr(self, "owner", value)
        )
        return self.owner.prepare()

    def test_prepare_retains_original_source_and_keeps_three_files_empty(self):
        owner = self.prepare()
        self.assertEqual(os.fstat(owner.source_fd).st_ino, self.binary.stat().st_ino)
        self.assertFalse(os.get_inheritable(owner.source_fd))
        self.assertEqual(self.binary.stat().st_nlink, 2)
        for child in (owner.session, owner.bootstrap, owner.authority):
            self.assertEqual(child.path.read_bytes(), b"")
        self.assertIsNone(owner.operation.process)
        self.assertIs(owner.operation.outgoing, None)
        self.assertIsNotNone(owner.operation._default_guardian._descriptor)

    def test_real_start_private_bootstrap_and_sealed_source_handoff(self):
        before = dict(os.environ)
        owner = self.prepare().start()
        self.assertTrue(owner.operation.active)
        self.assertTrue(owner.operation.image_ready)
        self.assertNotEqual(owner.operation.listener["pid"], owner.operation.process.pid)
        proof = self.subject.AUTHORITY.POLICY.authenticate(
            owner.authority.path.read_bytes(),
            owner.session.path.read_bytes(),
            owner.policy.shared,
            os.geteuid(),
        )
        self.assertEqual(proof["source_alias"], owner.alias.proof)
        self.assertEqual(proof["listener"], owner.operation.listener)
        self.assertEqual(dict(os.environ), before)
        self.assertTrue(self.native_calls[-1][1]["source_alias"])
        self.assertTrue(owner.retire(5))
        self.assertTrue(owner.operation.physically_retired)
        self.assertEqual(self.binary.stat().st_nlink, 1)
        self.assertFalse(owner.authority.path.exists())
        self.assertIsNone(owner.source_fd)

    def test_custom_store_outside_home_and_relative_store_preserve_raw_value(self):
        for setting in ("/external/shared models", "../models containing spaces"):
            with self.subTest(setting=setting), patch.dict(os.environ, {"OLLAMA_MODELS": setting}):
                owner = self.prepare().start()
                payload = json.loads(
                    owner.policy.shared.authenticate(
                        owner.bootstrap.path.read_bytes(),
                        owner.session._written,
                        owner.session.data["token"],
                    )
                )
                self.assertEqual(
                    payload["store"], {"mode": "environment", "value": setting, "cwd": os.getcwd()}
                )
                self.assertEqual(owner.operation.request["models_path"], setting)
                self.assertTrue(owner.retire(5))

    def test_default_store_does_not_materialize_user_models_or_mutate_environment(self):
        with patch.dict(os.environ, {"OLLAMA_MODELS": ""}):
            owner = self.prepare().start()
            payload = json.loads(
                owner.policy.shared.authenticate(
                    owner.bootstrap._written, owner.session._written, owner.session.data["token"]
                )
            )
            self.assertEqual(payload["store"], {"mode": "default", "value": "", "cwd": os.getcwd()})
            self.assertEqual(os.environ["OLLAMA_MODELS"], "")
            self.assertEqual(owner.operation.request["models_path"], "")
            self.assertFalse((self.home / ".ollama/models").exists())

    def test_explicit_proxy_certificate_and_bypass_original_case_and_bytes_survive(self):
        settings = {
            "HTTPS_PROXY": "http://user:synthetic-secret@relay.invalid:8080",
            "all_proxy": "socks5://other.invalid:1080",
            "NO_PROXY": ".corp.invalid",
            "SSL_CERT_FILE": "/external/account.pem",
            "SSL_CERT_DIR": "/external/hashed",
        }
        with patch.dict(os.environ, settings):
            owner = self.prepare().start()
            payload = json.loads(
                owner.policy.shared.authenticate(
                    owner.bootstrap._written, owner.session._written, owner.session.data["token"]
                )
            )
            self.assertEqual(dict(payload["environment"]), settings)
            public = json.dumps(owner.operation.request)
            self.assertNotIn("synthetic-secret", public)
            self.assertNotIn("account.pem", public)
            self.assertEqual(owner.operation.request["proxy_url"], "")

    def test_missing_source_bound_policy_fingerprint_refuses_before_fd_or_alias(self):
        values = list(self.input_values)
        values[1] = b'{"repository_source_sha256":{}}'
        with patch.object(self.subject.RUNTIME, "inputs", return_value=values):
            with self.assertRaisesRegex(self.subject.ServeRefusal, "source"):
                self.prepare()
        self.assertIsNone(self.owner.source_fd)
        self.assertEqual(self.binary.stat().st_nlink, 1)
        self.assertEqual(self.native_calls, [])

    def test_modified_policy_refuses_before_runtime_acquisition(self):
        path = self.subject.SHARED / "modules/llm/managed_ollama_bootstrap.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(RuntimeError, "policy"):
            self.prepare()
        self.assertIsNone(self.owner.source_fd)
        self.assertEqual(self.native_calls, [])

    def test_changed_retained_source_bytes_refuse_before_secret_creation(self):
        self.binary.write_bytes(b"foreign in-place runtime bytes")
        with self.assertRaisesRegex(self.subject.ServeRefusal, "source"):
            self.prepare()
        self.assertIsNone(self.owner.session)
        self.assertIsNone(self.owner.source_fd)
        self.assertEqual(self.binary.stat().st_nlink, 1)

    def test_duplicate_prepare_and_start_refuse_without_overwriting_owners(self):
        owner = self.prepare()
        session, descriptor = owner.session, owner.source_fd
        with self.assertRaisesRegex(self.subject.ServeRefusal, "state"):
            owner.prepare()
        self.assertIs(owner.session, session)
        self.assertEqual(owner.source_fd, descriptor)
        owner.start()
        with self.assertRaisesRegex(self.subject.ServeRefusal, "state"):
            owner.start()
        self.assertTrue(owner.operation.active)

    def test_pending_actual_guardian_never_releases_files_or_source(self):
        owner = self.prepare().start()
        descriptor = owner.source_fd
        with patch.object(owner.operation, "settle", return_value=False):
            self.assertFalse(owner.retire(5))
        self.assertEqual(owner.source_fd, descriptor)
        self.assertTrue(owner.alias.executable.exists())
        self.assertTrue(owner.authority.path.exists())
        self.assertTrue(owner.retire(5))

    def test_native_close_debt_cannot_be_returned_as_success(self):
        owner = self.prepare().start()
        self.assertTrue(owner.operation.settle(5))
        with patch.object(owner.operation, "settle", return_value=False):
            self.assertFalse(owner.retire(5))
        self.assertIsNotNone(owner._cleanup_debt)
        self.assertIsNone(owner.source_fd)
        self.assertFalse(owner.authority.path.exists())
        self.assertFalse(owner.retire(5))

    def test_startup_clock_and_cancellation_refuse_before_secret_release(self):
        owner = self.prepare()
        owner.cancelled = True
        with self.assertRaisesRegex(self.subject.ServeRefusal, "cancelled"):
            owner.start()
        self.assertIsNone(owner.operation.process)
        for child in (owner.session, owner.bootstrap, owner.authority):
            self.assertEqual(child.path.read_bytes(), b"")
        owner.cancelled = False
        self.assertTrue(owner.retire(5))

    def test_retired_fresh_owner_cannot_reacquire_source_or_private_files(self):
        self.owner = self.subject.ServeOwner(
            11434, 5, 60, 5, register=lambda value: setattr(self, "owner", value)
        )
        self.assertTrue(self.owner.retire(5))
        original_deadline = self.owner._retirement_deadline
        with self.assertRaisesRegex(self.subject.ServeRefusal, "state"):
            self.owner.prepare()
        self.assertEqual(self.owner._retirement_deadline, original_deadline)
        self.assertIsNone(self.owner.source_fd)
        self.assertIsNone(self.owner.session)
        self.assertIsNone(self.owner.bootstrap)
        self.assertIsNone(self.owner.authority)
        self.assertEqual(self.binary.stat().st_nlink, 1)
        self.assertEqual(self.native_calls, [])
        self.assertFalse((self.target.parent / "ollama-native-sessions").exists())

    def test_user_facing_native_activation_remains_unavailable(self):
        with self.assertRaisesRegex(self.subject.ServeRefusal, "unavailable"):
            self.subject.serve(11434, 5, 60, 5)
        self.assertEqual(self.native_calls, [])
        self.assertEqual(self.binary.stat().st_nlink, 1)


if __name__ == "__main__":
    unittest.main()
