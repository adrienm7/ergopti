# tools/diagnostics/macos_ollama_daemon_authority_test.py
"""Real POSIX authority files and independent sealed policy; native SDK unrun."""

import base64
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("ERGOPTI_SOURCE_ROOT", ROOT))


def load(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


AUTH = load(
    "native_daemon_authority",
    ROOT / "static/ergopti_plus/macos/platform/ollama_daemon_authority.py",
)
BOOT = load(
    "native_daemon_bootstrap", ROOT / "static/ergopti_plus/macos/platform/ollama_bootstrap_owner.py"
)
PROXY = load("daemon_proxy", SOURCE / "static/ergopti_plus/_shared/python/network_proxy_policy.py")
ALIASES = load(
    "daemon_alias_owner", SOURCE / "static/ergopti_plus/macos/platform/source_alias_owner.py"
)


@unittest.skipUnless(os.name == "posix", "Actual POSIX file ownership required")
class DaemonAuthorityControls(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.runtime = self.root / "runtime"
        self.runtime.mkdir(mode=0o755)
        self.binary = self.runtime / "ollama"
        self.binary.write_bytes(b"independent executable image; no native SDK credit")
        self.binary.chmod(0o755)
        self.binary_fd = os.open(self.binary, os.O_RDONLY | os.O_CLOEXEC)
        actual = os.fstat(self.binary_fd)
        self.session_data = {
            "version": 1,
            "token": "12" * 32,
            "source_commit": "ab" * 20,
            "asset_sha256": "cd" * 32,
            "binary_sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "device": str(actual.st_dev),
            "inode": str(actual.st_ino),
            "port": "11434",
        }
        self.operation = SimpleNamespace(
            image_ready=False,
            active=False,
            physically_retired=False,
            _retirement_started=False,
            progress=lambda: None,
            listener={
                "pid": os.getpid(),
                "uid": os.geteuid(),
                "start_seconds": "123",
                "start_microseconds": "456",
                "device": str(actual.st_dev),
                "inode": str(actual.st_ino),
            },
        )
        self.alias = self.session = self.authority = None
        self.addCleanup(self.retire)
        self.alias = ALIASES.AliasOwner.acquire(
            self.runtime,
            self.binary_fd,
            {key: self.session_data[key] for key in ("device", "inode")},
            self.session_data["binary_sha256"],
            register=lambda value: setattr(self, "alias", value),
            progress=lambda: None,
        )
        self.alias.bind_operation(self.operation)
        self.session = AUTH.OWNER.EmptySession.acquire(
            self.root / "sessions",
            self.session_data,
            register=lambda value: setattr(self, "session", value),
        )
        self.session.bind_operation(self.operation)
        self.authority = AUTH.DaemonAuthority.acquire(
            self.session, register=lambda value: setattr(self, "authority", value)
        )
        self.authority.bind_operation(self.operation)

        def check_source():
            with self.alias.context():
                pass

        self.operation.recheck_source = check_source
        self.policy = BOOT.POLICY.BootstrapPolicy(
            ROOT / "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json",
            PROXY.ProxyPolicy(),
        )

    def retire(self):
        self.operation.physically_retired = True
        try:
            for value in (self.authority, self.session, self.alias):
                if value is not None:
                    value.retire()
        finally:
            os.close(self.binary_fd)

    def activate(self):
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        self.operation.active = True

    def publish(self):
        self.activate()
        self.authority.publish(self.operation, self.alias, self.policy)
        return self.authority.path.read_bytes()

    def test_private_same_nonce_fd_and_namespace(self):
        self.assertEqual(self.authority.name, self.session.name.replace("daemon-", "source-", 1))
        self.assertEqual(self.authority.path.read_bytes(), b"")
        observed = os.fstat(self.authority._file_fd)
        self.assertEqual(observed.st_mode & 0o777, 0o600)
        self.assertEqual(observed.st_nlink, 1)
        self.assertFalse(os.get_inheritable(self.authority._file_fd))
        self.assertFalse(os.get_inheritable(self.authority._directory_fd))
        self.assertNotEqual(
            self.authority._file_identity.st_ino, self.session._file_identity.st_ino
        )

    def test_image_ready_without_active_cannot_publish(self):
        self.operation.image_ready = True
        self.session.release_key(self.operation)
        with self.assertRaises(AUTH.ImageRefusal):
            self.authority.publish(self.operation, self.alias, self.policy)
        self.assertEqual(self.authority.path.read_bytes(), b"")

    def test_foreign_operation_and_foreign_alias_binding_refuse(self):
        self.activate()
        with self.assertRaises(AUTH.ImageRefusal):
            self.authority.publish(SimpleNamespace(**vars(self.operation)), self.alias, self.policy)
        self.alias._operation = object()
        try:
            with self.assertRaises(AUTH.ImageRefusal):
                self.authority.publish(self.operation, self.alias, self.policy)
        finally:
            self.alias._operation = self.operation
        self.assertEqual(self.authority.path.read_bytes(), b"")

    def test_actual_write_and_independent_hmac_match_original_session(self):
        wire = self.publish()
        outer = json.loads(wire)
        raw = base64.b64decode(outer["payload"], validate=True)
        session_bytes = self.session.path.read_bytes()
        canonical = json.loads(
            (
                ROOT / "static/ergopti_plus/_shared/modules/llm/managed_ollama_bootstrap.json"
            ).read_bytes()
        )
        digest = hashlib.sha256(session_bytes).hexdigest()
        message = canonical["hmac_domain"].encode("ascii") + digest.encode("ascii") + b"\n" + raw
        self.assertEqual(outer["session_sha256"], digest)
        self.assertEqual(
            outer["mac"],
            hmac.new(
                bytes.fromhex(self.session_data["token"]), message, hashlib.sha256
            ).hexdigest(),
        )
        self.assertEqual(
            AUTH.POLICY.authenticate(wire, session_bytes, self.policy, os.geteuid()),
            {"source_alias": self.alias.proof, "listener": self.operation.listener},
        )

    def test_different_session_bytes_refuse_replay(self):
        wire = self.publish()
        changed = dict(self.session_data, port="11435")
        raw = (json.dumps(changed, sort_keys=True, separators=(",", ":")) + "\n").encode()
        with self.assertRaises(RuntimeError):
            AUTH.POLICY.authenticate(wire, raw, self.policy, os.geteuid())

    def test_exact_identity_types_and_uint64(self):
        value = {"source_alias": self.alias.proof, "listener": dict(self.operation.listener)}
        value["listener"]["start_seconds"] = str(2**64 - 1)
        self.assertEqual(
            AUTH.POLICY.validate(value, self.session_data, os.geteuid())["listener"][
                "start_seconds"
            ],
            str(2**64 - 1),
        )
        for name, wrong in (
            ("pid", True),
            ("uid", False),
            ("inode", "00"),
            ("device", "4294967296"),
            ("start_microseconds", "1000000"),
            ("start_seconds", str(2**64)),
        ):
            with self.subTest(name=name):
                mutated = {
                    "source_alias": self.alias.proof,
                    "listener": value["listener"] | {name: wrong},
                }
                with self.assertRaises(AUTH.POLICY.AuthorityRefusal):
                    AUTH.POLICY.validate(mutated, self.session_data, os.geteuid())

    def test_wrong_alias_binary_and_extra_authority_fields_refuse(self):
        for value in (
            {
                "source_alias": self.alias.proof | {"binary_sha256": "ef" * 32},
                "listener": self.operation.listener,
            },
            {
                "source_alias": self.alias.proof,
                "listener": self.operation.listener,
                "source_qualified": True,
            },
            {
                "source_alias": self.alias.proof,
                "listener": self.operation.listener | {"accepted": True},
            },
        ):
            with self.subTest(value=sorted(value)):
                with self.assertRaises(AUTH.POLICY.AuthorityRefusal):
                    AUTH.POLICY.validate(value, self.session_data, os.geteuid())

    def test_network_payload_is_not_daemon_authority(self):
        self.activate()
        wire = self.policy.seal(
            b'{"environment":[],"store":{},"idle_timeout_ms":60000}',
            self.session._written,
            self.session_data["token"],
        )
        with self.assertRaises(RuntimeError):
            AUTH.POLICY.authenticate(wire, self.session._written, self.policy, os.geteuid())

    def test_duplicate_authenticated_payload_keys_refuse(self):
        self.activate()
        value = {"source_alias": self.alias.proof, "listener": self.operation.listener}
        raw = json.dumps(value).encode()
        raw = raw.replace(b'"source_alias":', b'"source_alias":null,"source_alias":', 1)
        wire = self.policy.seal(raw, self.session._written, self.session_data["token"])
        with self.assertRaises(RuntimeError):
            AUTH.POLICY.authenticate(wire, self.session._written, self.policy, os.geteuid())

    def test_pending_retirement_prevents_publish_and_deletion(self):
        self.activate()
        self.operation._retirement_started = True
        with self.assertRaises(AUTH.ImageRefusal):
            self.authority.publish(self.operation, self.alias, self.policy)
        with self.assertRaises(AUTH.ImageRefusal):
            self.authority.retire()
        self.assertTrue(self.authority.path.exists())
        self.assertEqual(self.authority.path.read_bytes(), b"")
        self.assertIsNotNone(self.authority._file_fd)

    def test_existing_namespace_is_never_overwritten(self):
        before = self.authority.path.stat()
        with self.assertRaises(FileExistsError):
            AUTH.DaemonAuthority.acquire(self.session, register=lambda value: None)
        self.assertEqual(self.authority.path.stat().st_ino, before.st_ino)
        self.assertEqual(self.authority.path.read_bytes(), b"")

    def test_unknown_sibling_purpose_refuses_without_register(self):
        calls = []
        with self.assertRaises(AUTH.ImageRefusal):
            AUTH.OWNER.EmptySession.acquire_sibling(self.session, "foreign", register=calls.append)
        self.assertEqual(calls, [])

    def test_named_sidecar_replacement_refuses_without_foreign_write(self):
        saved = self.authority.path.with_suffix(".owned")
        self.authority.path.rename(saved)
        self.authority.path.write_bytes(b"foreign authority")
        try:
            self.activate()
            with self.assertRaises(AUTH.ImageRefusal):
                self.authority.publish(self.operation, self.alias, self.policy)
            self.assertEqual(self.authority.path.read_bytes(), b"foreign authority")
            self.assertEqual(saved.read_bytes(), b"")
        finally:
            self.authority.path.unlink()
            saved.rename(self.authority.path)

    def test_final_retirement_removes_only_original_files_and_closes_descriptors(self):
        self.publish()
        held = self.authority._file_fd
        self.operation.physically_retired = True
        self.authority.retire()
        self.assertFalse(self.authority.path.exists())
        self.assertTrue(self.session.path.exists())
        with self.assertRaises(OSError):
            os.fstat(held)
        self.authority.retire()


if __name__ == "__main__":
    unittest.main()
