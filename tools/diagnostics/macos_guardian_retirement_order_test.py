# tools/diagnostics/macos_guardian_retirement_order_test.py
"""Actual malformed POSIX peers cannot reopen retired source authority."""

import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load():
    path = ROOT / "tools/diagnostics/macos_ollama_bootstrap_owner_test.py"
    specification = importlib.util.spec_from_file_location("retirement_order_fixture", path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


@unittest.skipUnless(os.name == "posix", "Real private POSIX protocol peer required")
class RetirementOrderControls(unittest.TestCase):
    def setUp(self):
        self.module = load()
        self.case = self.module.BootstrapProtocolControls("runTest")
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)

    def malformed(self, first):
        needle = "    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], request['inode'], flush=True)"
        self.assertEqual(self.module.PEER.count(needle), 1)
        peer = self.module.PEER.replace(
            needle, "    print(" + repr(first) + ", flush=True)\n" + needle
        )
        with patch.object(self.module, "PEER", peer):
            with self.assertRaises(RuntimeError):
                self.case.start()
        operation = self.case.fixture.operation
        self.assertFalse(operation.active)
        self.assertFalse(operation.image_ready)
        self.assertTrue(operation._retirement_started)
        self.assertEqual(self.case.fixture.session.path.read_bytes(), b"")
        self.assertEqual(self.case.bootstrap.path.read_bytes(), b"")
        self.assertFalse(operation.settle(timeout=5))
        self.assertFalse(operation.physically_retired)
        self.assertTrue(operation._protocol_debt)

    def test_closed_bootstrap_then_ready_never_releases_private_files(self):
        self.malformed("V1 BOOTSTRAP_CLOSED 0")

    def test_closed_outgoing_then_ready_never_releases_private_files(self):
        self.malformed("V1 OUTGOING_CLOSED 0")

    def test_pending_retirement_then_ready_never_releases_private_files(self):
        self.malformed("V1 PENDING 16")

    def test_ready_then_close_in_one_pipe_write_refuses_key_writer(self):
        needle = "    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], request['inode'], flush=True)"
        replacement = "    os.write(1, ('V1 IMAGE_READY %s %s 123 456 %s %s\\nV1 BOOTSTRAP_CLOSED 0\\n' % (child.pid, os.geteuid(), request['device'], request['inode'])).encode())"
        peer = self.module.PEER.replace(needle, replacement)
        with patch.object(self.module, "PEER", peer):
            with self.assertRaises(RuntimeError):
                self.case.start()
        operation = self.case.fixture.operation
        self.assertTrue(operation.image_ready)
        self.assertTrue(operation._retirement_started)
        self.assertFalse(operation.active)
        self.assertEqual(self.case.fixture.session.path.read_bytes(), b"")
        self.assertEqual(self.case.bootstrap.path.read_bytes(), b"")

    def test_preimage_cancellation_can_close_and_retire_without_releasing_keys(self):
        needle = "    print('V1 IMAGE_READY', child.pid, os.geteuid(), '123', '456', request['device'], request['inode'], flush=True)"
        replacement = "    child.terminate(); child.wait()\n    print('V1 OUTGOING_CLOSED 0', flush=True)\n    print('V1 BOOTSTRAP_CLOSED 0', flush=True)\n    print('V1 RETIRED 143 1 1 0 0 0 0', flush=True)\n    raise SystemExit(0)"
        with patch.object(self.module, "PEER", self.module.PEER.replace(needle, replacement)):
            with self.assertRaises(RuntimeError):
                self.case.start()
        operation = self.case.fixture.operation
        self.assertTrue(operation._retirement_started)
        self.assertFalse(operation.image_ready)
        self.assertFalse(operation.active)
        self.assertFalse(operation._protocol_debt)
        self.assertEqual(self.case.fixture.session.path.read_bytes(), b"")
        self.assertEqual(self.case.bootstrap.path.read_bytes(), b"")
        self.assertTrue(operation.settle(timeout=5))
        self.assertTrue(operation.physically_retired)

    def test_duplicate_closed_marker_refuses_without_resetting_history(self):
        operation = self.case.start()
        operation._parse(b"V1 BOOTSTRAP_CLOSED 0")
        with self.assertRaises(RuntimeError):
            operation._parse(b"V1 BOOTSTRAP_CLOSED 0")
        self.assertTrue(operation._retirement_started)
        self.assertTrue(operation._protocol_debt)


if __name__ == "__main__":
    unittest.main()
