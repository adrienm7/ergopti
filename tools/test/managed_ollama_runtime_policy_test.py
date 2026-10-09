# tools/test/managed_ollama_runtime_policy_test.py
"""Independent source/catalogue/installed-byte receiving, without native credit."""

import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "runtime_policy", ROOT / "static/ergopti_plus/_shared/python/managed_ollama_runtime.py"
)
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class RuntimePolicyTests(unittest.TestCase):
    def setUp(self):
        self.owned = tempfile.TemporaryDirectory()
        self.addCleanup(self.owned.cleanup)
        self.directory = Path(self.owned.name) / "runtime"
        self.directory.mkdir()
        self.contract_bytes = (
            ROOT / "static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json"
        ).read_bytes()
        self.contract = json.loads(self.contract_bytes)
        self.binary = b"independent candidate bytes"
        self.library = b"independent genuine-byte receiving vector"
        self.asset = {
            "os": "darwin",
            "architecture": "arm64",
            "filename": "ollama-ergopti-native-http-darwin-arm64.tgz",
            "url": "",
            "sha256": "a" * 64,
            "bytes": 100,
            "version": "0.24.0",
            "source_commit": "c28ddc0a7b273cd286b680a6db0bef0c17bc0ec0",
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "native_http_capability": 1,
            "binary_sha256": hashlib.sha256(self.binary).hexdigest(),
            "runtime_libraries_sha256": {
                "lib/backend.dylib": hashlib.sha256(self.library).hexdigest()
            },
            "provenance_sha256": "b" * 64,
        }
        self.catalogue = {
            "schema_version": 1,
            "version": "0.24.0",
            "source_commit": self.asset["source_commit"],
            "capability": self.asset["capability"],
            "native_http_capability": 1,
            "runtime_contract_sha256": hashlib.sha256(self.contract_bytes).hexdigest(),
            "repository_commit": "c" * 40,
            "repository_source_sha256": {
                name: "e" * 64 for name in self.contract["source_fingerprint_paths"]
            },
            "publication": {"mode": "unpublished-ci"},
            "assets": {"macos-arm64": self.asset},
        }
        (self.directory / "ollama").write_bytes(self.binary)
        (self.directory / "LICENSE.ollama").write_text("independent license")
        (self.directory / "lib").mkdir()
        (self.directory / "lib/backend.dylib").write_bytes(self.library)

    def encode(self):
        return json.dumps(self.catalogue).encode()

    def test_source_qualified_unpublished_asset_and_exact_installed_bytes(self):
        contract, asset = POLICY.select_asset(self.contract_bytes, self.encode(), "macos-arm64")
        self.assertEqual(
            POLICY.verify_directory(self.directory, contract, asset), self.directory / "ollama"
        )
        receipt = POLICY.receipt(self.contract_bytes, self.encode(), "macos-arm64", asset)
        (self.directory / POLICY.RECEIPT_BASENAME).write_text(json.dumps(receipt))
        POLICY.verify_directory(self.directory, contract, asset, receipt)

    def test_changed_source_pin_or_ambiguous_metadata_refuses(self):
        self.catalogue["runtime_contract_sha256"] = "d" * 64
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.select_asset(self.contract_bytes, self.encode(), "macos-arm64")
        for data in (b'{"x":1,"x":1}', b'{"x":NaN}', b"[]"):
            with self.assertRaises(POLICY.RuntimeRefusal):
                POLICY.metadata_bytes(data)

    def test_binary_library_extra_file_and_escaping_link_refuse(self):
        binary = self.directory / "ollama"
        binary.write_bytes(b"foreign binary")
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.directory, self.contract, self.asset)
        binary.write_bytes(self.binary)
        extra = self.directory / "unexpected.dylib"
        extra.write_bytes(b"extra")
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.directory, self.contract, self.asset)
        extra.unlink()
        library = self.directory / "lib/backend.dylib"
        library.write_bytes(b"modified library")
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.directory, self.contract, self.asset)
        library.unlink()
        external = Path(self.owned.name) / "external.dylib"
        external.write_bytes(self.library)
        library.symlink_to(external)
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.directory, self.contract, self.asset)

    def test_confined_file_alias_keeps_exact_library_closure(self):
        alias = self.directory / "lib/alias.dylib"
        alias.symlink_to("backend.dylib")
        self.asset["runtime_libraries_sha256"]["lib/alias.dylib"] = hashlib.sha256(
            self.library
        ).hexdigest()
        POLICY.verify_directory(self.directory, self.contract, self.asset)
        (self.directory / "ollama").unlink()
        (self.directory / "ollama").symlink_to("lib/backend.dylib")
        self.asset["binary_sha256"] = hashlib.sha256(self.library).hexdigest()
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.verify_directory(self.directory, self.contract, self.asset)

    def test_traversal_bad_digest_bool_size_and_credential_url_refuse(self):
        for name, value in (
            ("bytes", True),
            ("binary_sha256", "bad"),
            ("runtime_libraries_sha256", {"../backend.dylib": "a" * 64}),
            ("url", "https://user:secret@example.test/" + self.asset["filename"]),
        ):
            original = self.asset[name]
            self.asset[name] = value
            with self.assertRaises(POLICY.RuntimeRefusal):
                POLICY.select_asset(self.contract_bytes, self.encode(), "macos-arm64")
            self.asset[name] = original

    def test_private_hmac_independent_vector_never_transmits_token(self):
        session = {
            "version": 1,
            "token": "a" * 64,
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "asset_sha256": "d" * 64,
            "device": "1",
            "inode": "2",
            "port": "11434",
        }
        headers, challenge = POLICY.authenticated_headers(
            session, "GET", "/api/ergopti-native-http-admission", challenge="e" * 64
        )
        self.assertEqual(
            dict(headers)["X-Ergopti-Native-Session"],
            "81847eb08c9c9c21dc36d6cad790aaeef26ff1bfb10e085d8cea5157aac0d95f",
        )
        self.assertNotIn(session["token"], dict(headers).values())
        changed, _ = POLICY.authenticated_headers(
            session, "POST", "/api/pull", b'{"model":"x"}', "f" * 32, challenge
        )
        mutated, _ = POLICY.authenticated_headers(
            session, "POST", "/api/pull", b'{"model":"y"}', "f" * 32, challenge
        )
        self.assertNotEqual(
            dict(changed)["X-Ergopti-Native-Session"], dict(mutated)["X-Ergopti-Native-Session"]
        )

    def test_signed_operation_ack_requires_exact_pid_source_and_zero_owners(self):
        session = {
            "version": 1,
            "token": "a" * 64,
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "asset_sha256": "d" * 64,
            "device": "1",
            "inode": "2",
            "port": "11434",
        }
        listener = {"pid": 123, "device": "1", "inode": "2"}
        data = {
            "version": 1,
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "pid": 123,
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "asset_sha256": "d" * 64,
            "device": "1",
            "inode": "2",
            "port": "11434",
            "lease_id": hashlib.sha256(b"a" * 64).hexdigest(),
            "operation_id": "f" * 32,
            "operation_state": "retired",
            "native_helpers": 0,
            "background_downloads": 0,
        }
        challenge = "e" * 64

        def signed(value):
            payload = json.dumps(value, separators=(",", ":")).encode()
            proof = hmac.new(
                b"a" * 64,
                b"ERGOPTI_NATIVE_RESPONSE_V1\n" + b"e" * 64 + b"\n" + payload,
                hashlib.sha256,
            ).hexdigest()
            return [("X-Ergopti-Native-Proof", proof)], payload

        headers, payload = signed(data)
        self.assertEqual(
            POLICY.authenticated_receipt(session, headers, payload, challenge, listener, "f" * 32),
            data,
        )
        with self.assertRaises(POLICY.RuntimeRefusal):
            POLICY.authenticated_receipt(
                session, headers, payload + b" ", challenge, listener, "f" * 32
            )
        for name, value in (
            ("pid", True),
            ("pid", 456),
            ("source_commit", "f" * 40),
            ("operation_id", "a" * 32),
            ("native_helpers", 1),
            ("background_downloads", False),
        ):
            changed = dict(data)
            changed[name] = value
            headers, payload = signed(changed)
            with self.assertRaises(POLICY.RuntimeRefusal):
                POLICY.authenticated_receipt(
                    session, headers, payload, challenge, listener, "f" * 32
                )


if __name__ == "__main__":
    unittest.main()
