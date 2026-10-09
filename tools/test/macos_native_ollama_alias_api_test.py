# tools/test/macos_native_ollama_alias_api_test.py
"""Receive optional typed alias framing with real portable protocol peers only."""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


ORIGINAL = load("old_alias_wire_controls", ROOT / "tools/test/macos_native_ollama_api_test.py")


class AliasWireReceiving(unittest.TestCase):
    def setUp(self):
        self.owner = tempfile.TemporaryDirectory(prefix="ergopti-alias-wire-")
        self.addCleanup(self.owner.cleanup)
        self.directory = Path(self.owner.name)
        for relative in (
            "static/ergopti_plus/macos/platform/network/native_http.py",
            "static/ergopti_plus/macos/platform/network/native_ollama_api.py",
            "static/ergopti_plus/_shared/python/managed_source_alias.py",
        ):
            target = self.directory / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, target)
        self.api = load(
            "actual_alias_wire_port",
            self.directory / "static/ergopti_plus/macos/platform/network/native_ollama_api.py",
        )
        self.peer = self.directory / "peer"
        self.peer.write_text("#!" + sys.executable + "\n" + ORIGINAL.PEER, encoding="utf-8")
        self.peer.chmod(0o700)
        self.receipt = self.directory / "receipt.json"
        self.children = []
        actual_spawn = subprocess.Popen

        def spawn(*args, **options):
            child = actual_spawn(*args, **options)
            self.children.append(child)
            return child

        self.addCleanup(patch.stopall)
        patch.object(self.api.ENGINE, "_resolve_worker", return_value=str(self.peer)).start()
        patch.object(self.api.ENGINE.subprocess, "Popen", side_effect=spawn).start()
        patch.dict(
            os.environ, ERGOPTI_PEER_RECEIPT=str(self.receipt), ERGOPTI_PEER_MODE="good"
        ).start()
        self.proof = {
            "version": 1,
            "nonce": "0123456789abcdef0123456789abcdef",
            "directory_device": "123",
            "directory_inode": "1152921500312523020",
            "ancestor_device": "123",
            "ancestor_inode": "1152921500312523021",
            "lease_device": "123",
            "lease_inode": "1152921500312523022",
            "binary_sha256": "e" * 64,
        }

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.kill()
                child.wait()
                self.fail("Protocol peer survived alias completion")
            self.assertTrue(child.stdin.closed)
            self.assertTrue(child.stdout.closed)

    def discover(self, proof):
        return self.api.discover(
            "/private/verified/ollama", "123", "456", 11434, 2, 1, source_alias=proof
        )

    def test_exact_nine_field_proof_uses_private_stdin_and_unchanged_sdk_tuple(self):
        self.assertEqual(self.discover(self.proof), ORIGINAL.IDENTITY)
        receipt = json.loads(self.receipt.read_bytes())
        self.assertEqual(receipt["argv"], ["--managed-ollama-listener-probe", "2000"])
        actual = json.loads(receipt["raw"])
        self.assertEqual(actual["source_alias"], self.proof)
        self.assertEqual(actual["inode"], "456")
        self.assertTrue(receipt["raw"].endswith("\n"))
        self.assertNotIn(self.proof["nonce"], " ".join(receipt["argv"]))

    def test_alias_model_request_preserves_headers_body_idle_and_no_absolute_deadline(
        self,
    ):
        body = '{"model":"independent"}'
        headers = [
            ["X-Ergopti-Native-Session", "a" * 64],
            ["X-Ergopti-Native-Challenge", "b" * 64],
            ["X-Ergopti-Native-Body-SHA256", hashlib.sha256(body.encode()).hexdigest()],
            ["X-Ergopti-Native-Operation", "c" * 32],
        ]
        with self.api.open_request(
            "/private/verified/ollama",
            "123",
            "456",
            11434,
            dict(ORIGINAL.IDENTITY),
            "POST",
            "/api/pull",
            headers,
            body,
            None,
            2,
            source_alias=self.proof,
        ) as response:
            self.assertEqual(response.read(), b'{"status":"success"}\n')
            self.assertEqual(response.read(), b"")
            self.assertEqual(response.listener, ORIGINAL.IDENTITY)
        receipt = json.loads(self.receipt.read_bytes())
        actual = json.loads(receipt["raw"])
        self.assertEqual(receipt["argv"], ["--managed-ollama-api-worker", "2000", "none"])
        self.assertEqual(actual["source_alias"], self.proof)
        self.assertEqual(actual["body"], body)
        self.assertEqual(actual["headers"], headers)
        self.assertIsNone(actual["timeout_ms"])
        self.assertEqual(actual["idle_ms"], 2000)
        for value in (self.proof["nonce"], "a" * 64):
            self.assertNotIn(value, " ".join(receipt["argv"]))

    def test_malformed_alias_schema_refuses_before_any_child_or_private_bytes(self):
        for name, value in (
            ("version", True),
            ("nonce", "F" * 32),
            ("directory_inode", 1152921500312523020),
            ("ancestor_inode", "01"),
            ("lease_device", str(2**32)),
            ("lease_inode", str(2**64)),
            ("binary_sha256", "bad"),
        ):
            proof = self.proof | {name: value}
            with self.subTest(field=name):
                with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                    self.discover(proof)
        with self.assertRaises(self.api.ENGINE.NativeHTTPError):
            self.discover(self.proof | {"foreign": 1})
        self.assertEqual(self.children, [])
        self.assertFalse(self.receipt.exists())

    def test_missing_schema_source_refuses_without_protocol_peer(self):
        (self.directory / "static/ergopti_plus/_shared/python/managed_source_alias.py").unlink()
        with self.assertRaises(self.api.ENGINE.NativeHTTPError) as caught:
            self.discover(self.proof)
        self.assertEqual(caught.exception.reason, "unavailable")
        self.assertEqual(self.children, [])
        self.assertFalse(self.receipt.exists())

    def test_failure_after_alias_request_still_physically_reaps_peer(self):
        with patch.dict(os.environ, ERGOPTI_PEER_MODE="trailing"):
            with self.assertRaises(self.api.ENGINE.NativeHTTPError):
                self.discover(self.proof)
        self.assertEqual(len(self.children), 1)
        self.assertIsNotNone(self.children[0].poll())


if __name__ == "__main__":
    unittest.main()
