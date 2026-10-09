# tools/test/macos_managed_ollama_pull_caller_test.py
"""Portable receipt/file and injected-lifecycle receiving, not native SDK credit."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "static/ergopti_plus/macos/modules/llm/managed_ollama_pull.py"
specification = importlib.util.spec_from_file_location("managed_pull_caller_receiving", SOURCE)
CALLER = importlib.util.module_from_spec(specification)
sys.modules[specification.name] = CALLER
specification.loader.exec_module(CALLER)


class ReservedFileTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.path = Path(self.root.name) / "receipt"
        self.path.touch(mode=0o600)
        self.path.chmod(0o600)

    def test_existing_empty_exact_file_publication(self):
        expected = self.path.stat().st_ino
        with CALLER.RECEIPT.ReservedReceipt(self.path) as receipt:
            descriptor = receipt.descriptor
            receipt.publish({"nonce": "independent", "state": "retired"})
            with self.assertRaises(CALLER.RECEIPT.ReceiptRefusal):
                receipt.publish({"state": "retired"})
        self.assertEqual(self.path.stat().st_ino, expected)
        self.assertEqual(
            json.loads(self.path.read_text()), {"nonce": "independent", "state": "retired"}
        )
        with self.assertRaises(OSError):
            os.fstat(descriptor)

    def test_nonempty_private_file_preserved(self):
        self.path.write_bytes(b"foreign")
        with self.assertRaises(CALLER.RECEIPT.ReceiptRefusal):
            CALLER.RECEIPT.ReservedReceipt(self.path)
        self.assertEqual(self.path.read_bytes(), b"foreign")

    def test_symlink_hardlink_and_public_modes_refused(self):
        for kind in ("symlink", "hardlink", "public"):
            with self.subTest(kind=kind):
                target = Path(self.root.name) / kind
                if kind == "symlink":
                    target.symlink_to(self.path)
                elif kind == "hardlink":
                    os.link(self.path, target)
                else:
                    target.touch(mode=0o644)
                    target.chmod(0o644)
                with self.assertRaises((OSError, CALLER.RECEIPT.ReceiptRefusal)):
                    CALLER.RECEIPT.ReservedReceipt(target)
                target.unlink()

    def test_replacement_after_admission_is_not_overwritten(self):
        with CALLER.RECEIPT.ReservedReceipt(self.path) as receipt:
            self.path.unlink()
            self.path.write_bytes(b"external-replacement")
            with self.assertRaises(CALLER.RECEIPT.ReceiptRefusal):
                receipt.publish({"state": "retired"})
        self.assertEqual(self.path.read_bytes(), b"external-replacement")

    def test_oversize_receipt_keeps_reserved_file_empty(self):
        with CALLER.RECEIPT.ReservedReceipt(self.path) as receipt:
            with self.assertRaises(CALLER.RECEIPT.ReceiptRefusal):
                receipt.publish({"state": "x" * 4096})
        self.assertEqual(self.path.read_bytes(), b"")


class Owner:
    def __init__(self, *, cancel=False, unknown=False):
        self.session = {
            "source_commit": "a" * 40,
            "binary_sha256": "b" * 64,
            "asset_sha256": "c" * 64,
        }
        self.operation = "d" * 32
        self.listener = {"pid": 123}
        self.admitted = True
        self.submitted = self.request_finished = self.retired = False
        self.cancel, self.unknown = cancel, unknown
        self.calls = []

    @property
    def pending(self):
        return self.submitted and not self.retired

    def pull(self, model, emit, timeout):
        self.calls.append(("pull", model, timeout))
        self.submitted = True
        try:
            emit({"completed": 1024, "total": 2048})
            if self.cancel:
                raise CALLER.Cancelled()
            return True
        finally:
            self.request_finished = True

    def retirement(self, timeout):
        self.calls.append(("retirement", timeout))
        if self.unknown:
            raise CALLER.POLICY.RuntimeRefusal("session")
        self.retired = True
        return True


class CallerOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.path = Path(self.root.name) / "receipt"
        self.path.touch(mode=0o600)
        self.path.chmod(0o600)
        self.value = {
            "version": 1,
            "model": "owned/test:tiny",
            "port": 11434,
            "nonce": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "receipt_path": str(self.path),
        }

    def run_owner(self, owner=None, factory=None):
        with CALLER.RECEIPT.ReservedReceipt(self.path) as receipt:
            status = CALLER.execute(
                self.value,
                owner_factory=factory or (lambda *args: owner),
                idle_timeout=60,
                maximum_bytes=65536,
                deadline=time.monotonic() + 30,
                retirement_timeout=1,
                cancellation=CALLER.Cancellation(),
                emit=lambda _: None,
                private_receipt=receipt,
            )
        return status, json.loads(self.path.read_text())

    def test_success_waits_authenticated_daemon_retirement_without_absolute_pull_clock(self):
        owner = Owner()
        status, receipt = self.run_owner(owner)
        self.assertEqual(status, 0)
        self.assertEqual(owner.calls[0], ("pull", "owned/test:tiny", None))
        self.assertEqual(owner.calls[1][0], "retirement")
        self.assertEqual(receipt["state"], "retired")
        self.assertIs(receipt["request_reaped"], True)
        self.assertIs(receipt["daemon_operation_retired"], True)
        self.assertEqual(receipt["operation"], "d" * 32)

    def test_cancel_after_local_request_requires_daemon_ack(self):
        owner = Owner(cancel=True)
        status, receipt = self.run_owner(owner)
        self.assertEqual(status, 130)
        self.assertEqual(len(owner.calls), 2)
        self.assertIs(owner.retired, True)
        self.assertEqual(receipt["worker_status"], 130)
        self.assertEqual(receipt["state"], "retired")

    def test_unknown_daemon_work_keeps_debt_after_request_reap(self):
        owner = Owner(unknown=True)
        status, receipt = self.run_owner(owner)
        self.assertEqual(status, 78)
        self.assertIs(receipt["request_reaped"], True)
        self.assertIs(receipt["daemon_operation_retired"], False)
        self.assertEqual(receipt["state"], "pending")

    def test_pre_submission_refusal_closes_only_empty_operation(self):
        def refuse(*unused):
            raise CALLER.POLICY.RuntimeRefusal("session")

        status, receipt = self.run_owner(factory=refuse)
        self.assertEqual(status, 78)
        self.assertEqual(receipt["state"], "retired")
        self.assertIs(receipt["source_admitted"], False)
        self.assertEqual(receipt["operation"], "")

    def test_distinct_dynamic_policy_refusal_still_tries_next_actual_private_lease(self):
        self.assertIsNot(CALLER.POLICY.RuntimeRefusal, CALLER.SESSIONS.POLICY.RuntimeRefusal)
        root = Path(self.root.name)
        binary = root / "ollama-native-http/ollama"
        binary.parent.mkdir()
        binary.write_bytes(b"portable binary stand-in; no native verification claim")
        sessions = root / "ollama-native-sessions"
        sessions.mkdir(mode=0o700)
        sessions.chmod(0o700)
        actual = binary.stat()
        session = {
            "version": 1,
            "token": "a" * 64,
            "port": "11434",
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "asset_sha256": "d" * 64,
            "device": str(actual.st_dev),
            "inode": str(actual.st_ino),
        }
        for name, token in (("daemon-a.json", "e" * 64), ("daemon-b.json", "a" * 64)):
            path = sessions / name
            path.write_text(json.dumps(session | {"token": token}))
            path.chmod(0o600)
        asset = {
            "source_commit": "b" * 40,
            "binary_sha256": "c" * 64,
            "sha256": "d" * 64,
            "capability": "ERGOPTI_OLLAMA_NATIVE_HTTP_V1",
            "native_http_capability": 1,
        }
        attempted = []

        class AdmissionOwner:
            def __init__(self, lease, *unused):
                self.lease = lease

            def admit(self, remaining):
                attempted.append(self.lease["token"])
                if self.lease["token"] == "e" * 64:
                    raise CALLER.POLICY.RuntimeRefusal("session")

        with (
            patch.object(
                CALLER.RUNTIME,
                "inputs",
                return_value=(b"contract", b"catalogue", "macos-arm64", {}, asset),
            ),
            patch.object(CALLER.RUNTIME, "native_verify", return_value=binary),
            patch.object(CALLER.PULL, "PullOwner", AdmissionOwner),
        ):
            selected = CALLER.select_owner(self.value, time.monotonic() + 30, 60, 65536)
        self.assertEqual(attempted, ["e" * 64, "a" * 64])
        self.assertEqual(selected.lease["token"], "a" * 64)

    def test_latched_cancellation_cannot_interrupt_retirement(self):
        cancellation = CALLER.Cancellation()
        with self.assertRaises(CALLER.Cancelled):
            cancellation.signal(signal.SIGTERM, None)
        cancellation.retiring = True
        cancellation.signal(signal.SIGTERM, None)
        self.assertIs(cancellation.requested, True)


if __name__ == "__main__":
    unittest.main()
