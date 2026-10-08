# tools/test/managed_ollama_pull_test.py
"""Independent operation-lifecycle vectors; native ports have separate gates."""

import hashlib
import hmac
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "pull_owner", ROOT / "static/ergopti_plus/_shared/python/managed_ollama_pull.py"
)
PULL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PULL)
SESSION = {
    "version": 1,
    "token": "a" * 64,
    "source_commit": "b" * 40,
    "binary_sha256": "c" * 64,
    "asset_sha256": "d" * 64,
    "device": "1",
    "inode": "2",
    "port": "11434",
}
LISTENER = {
    "pid": 42,
    "uid": 1000,
    "start_seconds": "100",
    "start_microseconds": "1",
    "device": "1",
    "inode": "2",
}


class Response:
    def __init__(self, body, headers=(), listener=None):
        self.status, self.headers, self.listener = 200, list(headers), listener or dict(LISTENER)
        self.chunks = [body[index : index + 7] for index in range(0, len(body), 7)]
        self.closed = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.closed = True

    def read(self):
        return self.chunks.pop(0) if self.chunks else b""


class Ports:
    def __init__(self):
        self.requests, self.responses = [], []
        self.state, self.helpers, self.background = "active", 1, 1
        self.progress = b'{"status":"pulling manifest"}\n{"status":"pulling model","total":17,"completed":17}\n{"status":"success"}\n'
        self.invalid_proof = self.changed_start = False

    def discover(self, *args):
        self.discovery = args
        return dict(LISTENER)

    def open_request(
        self, executable, device, inode, port, listener, method, path, headers, body, timeout, idle
    ):
        self.requests.append((method, path, dict(headers), body, timeout, idle))
        if method == "POST":
            result = Response(self.progress)
        else:
            value = {
                "version": 1,
                "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
                "pid": 42,
                "source_commit": SESSION["source_commit"],
                "binary_sha256": SESSION["binary_sha256"],
                "asset_sha256": SESSION["asset_sha256"],
                "device": "1",
                "inode": "2",
                "port": "11434",
                "lease_id": hashlib.sha256(SESSION["token"].encode()).hexdigest(),
            }
            operation = dict(headers).get("X-Ergopti-Native-Operation")
            if operation:
                value.update(
                    operation_id=operation,
                    operation_state=self.state,
                    native_helpers=self.helpers,
                    background_downloads=self.background,
                )
            data = json.dumps(value, separators=(",", ":")).encode()
            challenge = dict(headers)["X-Ergopti-Native-Challenge"]
            signed = b"ERGOPTI_NATIVE_RESPONSE_V1\n" + challenge.encode() + b"\n" + data
            proof = hmac.new(SESSION["token"].encode(), signed, hashlib.sha256).hexdigest()
            if self.invalid_proof:
                proof = "f" * 64
            result = Response(data, [("X-Ergopti-Native-Proof", proof)])
            if self.changed_start:
                result.listener["start_seconds"] = "101"
        self.responses.append(result)
        return result


class OperationReceiving(unittest.TestCase):
    def setUp(self):
        self.ports = Ports()
        self.owner = PULL.PullOwner(SESSION, "/private/verified/ollama", self.ports, 60, 65536)

    def admit(self):
        self.owner.admit(5)

    def test_progress_and_local_http_exit_do_not_release_daemon_operation(self):
        self.admit()
        rows = []
        self.assertTrue(self.owner.pull("fixture/model:latest", rows.append))
        self.assertEqual(
            [row["status"] for row in rows], ["pulling manifest", "pulling model", "success"]
        )
        self.assertTrue(self.ports.responses[-1].closed)
        self.assertTrue(self.owner.request_finished)
        self.assertTrue(self.owner.pending)
        self.assertIsNone(
            self.ports.requests[-1][4], "no invented absolute limit on progressing model downloads"
        )
        self.assertFalse(self.owner.retirement(5))
        self.assertTrue(self.owner.pending)
        self.ports.state, self.ports.helpers, self.ports.background = "retired", 0, 0
        self.assertTrue(self.owner.retirement(5))
        self.assertFalse(self.owner.pending)

    def test_cancelled_emitter_closes_request_and_keeps_debt_until_authenticated_ack(self):
        self.admit()

        def cancel(_):
            raise KeyboardInterrupt()

        with self.assertRaises(KeyboardInterrupt):
            self.owner.pull("fixture/model", cancel)
        self.assertTrue(self.ports.responses[-1].closed)
        self.assertTrue(self.owner.pending)
        self.ports.state, self.ports.helpers, self.ports.background = "retired", 0, 0
        self.assertTrue(self.owner.retirement(5))

    def test_unknown_wrong_proof_changed_start_or_live_native_owner_cannot_release(self):
        self.admit()
        self.owner.pull("fixture", lambda _: None)
        self.ports.state, self.ports.helpers, self.ports.background = "retired", 0, 0
        for attribute, value in (
            ("state", "unknown"),
            ("helpers", 1),
            ("background", 1),
            ("invalid_proof", True),
            ("changed_start", True),
        ):
            original = getattr(self.ports, attribute)
            setattr(self.ports, attribute, value)
            with self.subTest(attribute=attribute), self.assertRaises(PULL.POLICY.RuntimeRefusal):
                self.owner.retirement(5)
            self.assertTrue(self.owner.pending)
            setattr(self.ports, attribute, original)

    def test_final_error_is_failure_even_if_stream_contains_prior_success(self):
        self.admit()
        self.ports.progress = b'{"status":"success"}\n{"error":"independent upstream failure"}\n'
        self.assertFalse(self.owner.pull("fixture", lambda _: None))
        self.assertTrue(self.owner.pending)

    def test_oversize_partial_duplicate_bool_and_unknown_progress_keep_debt(self):
        vectors = [
            b'{"status":"success"}',
            b'{"status":"x","status":"success"}\n',
            b'{"status":"x","total":true}\n',
            b'{"status":"x","unknown":1}\n',
            b"x" * 65537,
        ]
        for row in vectors:
            with self.subTest(row=row[:30]):
                ports = Ports()
                ports.progress = row
                owner = PULL.PullOwner(SESSION, "/private/verified/ollama", ports, 60, 65536)
                owner.admit(5)
                with self.assertRaises(PULL.POLICY.RuntimeRefusal):
                    owner.pull("fixture", lambda _: None)
                self.assertTrue(owner.pending)
                self.assertTrue(ports.responses[-1].closed)

    def test_initial_auth_refusal_cannot_dispatch_model_pull(self):
        self.ports.invalid_proof = True
        with self.assertRaises(PULL.POLICY.RuntimeRefusal):
            self.admit()
        with self.assertRaises(PULL.POLICY.RuntimeRefusal):
            self.owner.pull("fixture", lambda _: None)
        self.assertFalse(self.owner.submitted)
        self.assertEqual([row[0] for row in self.ports.requests], ["GET"])

    def test_operation_auth_bound_to_exact_body_and_never_sends_raw_token(self):
        self.admit()
        self.owner.pull("fixture/model:latest", lambda _: None)
        method, path, headers, body, _, _ = self.ports.requests[-1]
        self.assertEqual((method, path), ("POST", "/api/pull"))
        self.assertEqual(json.loads(body), {"model": "fixture/model:latest", "stream": True})
        self.assertEqual(
            headers["X-Ergopti-Native-Body-SHA256"], hashlib.sha256(body.encode()).hexdigest()
        )
        self.assertNotIn(SESSION["token"], headers.values())
        self.assertEqual(headers["X-Ergopti-Native-Operation"], self.owner.operation)

    def test_no_double_admission_pull_or_retirement_and_no_arbitrary_model_url(self):
        self.admit()
        with self.assertRaises(PULL.POLICY.RuntimeRefusal):
            self.admit()
        for model in ("", "https://secret@example.invalid/x", "bad\nname", "../model"):
            with self.subTest(model=model):
                with self.assertRaises(PULL.POLICY.RuntimeRefusal):
                    self.owner.pull(model, lambda _: None)
        self.owner.pull("fixture", lambda _: None)
        with self.assertRaises(PULL.POLICY.RuntimeRefusal):
            self.owner.pull("fixture", lambda _: None)
        self.ports.state, self.ports.helpers, self.ports.background = "retired", 0, 0
        self.owner.retirement(5)
        with self.assertRaises(PULL.POLICY.RuntimeRefusal):
            self.owner.retirement(5)


if __name__ == "__main__":
    unittest.main()
