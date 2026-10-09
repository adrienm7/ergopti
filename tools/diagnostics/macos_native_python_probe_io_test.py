# tools/diagnostics/macos_native_python_probe_io_test.py
"""Actual POSIX od byte/pipe boundaries; not Hammerspoon or native Python image proof."""

import errno
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


class NativeProbeIOTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def launch(self, path):
        process = subprocess.Popen(
            ["/usr/bin/od", "-An", "-v", "-N", "4096", "-t", "x1", str(path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        def retire():
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(retire)
        return process

    def test_actual_reader_emits_exactly_bounded_literal_bytes(self):
        path = self.root / "candidate"
        literal = b"\xcf\xfa\xed\xfe\x0c\0\0\1" + bytes(range(256)) * 4096
        path.write_bytes(literal)
        child = self.launch(path)
        stdout, stderr = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 0)
        self.assertEqual(stderr, b"")
        self.assertEqual(bytes.fromhex(stdout.decode("ascii")), literal[:4096])
        self.assertLessEqual(len(stdout), 4096 * 4)

    def test_fifo_open_stays_in_child_until_actual_signal_and_wait(self):
        path = self.root / "candidate"
        os.mkfifo(path, 0o600)
        child = self.launch(path)
        with self.assertRaises(subprocess.TimeoutExpired):
            child.communicate(timeout=0.1)
        self.assertIsNone(child.poll())
        child.send_signal(signal.SIGTERM)
        stdout, stderr = child.communicate(timeout=5)
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertEqual((stdout, stderr), (b"", b""))

    def test_retargeted_fifo_does_not_borrow_a_replacement_file_receipt(self):
        path = self.root / "candidate"
        os.mkfifo(path, 0o600)
        child = self.launch(path)
        deadline = time.monotonic() + 5
        while True:
            try:
                writer = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
                break
            except OSError as error:
                if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                    raise
                time.sleep(0.01)
        self.addCleanup(os.close, writer)
        # The real FIFO rendezvous establishes a held reader, not a guessed
        # scheduler delay. Keep the writer open without supplying any bytes.
        with self.assertRaises(subprocess.TimeoutExpired):
            child.communicate(timeout=0.1)
        path.unlink()
        path.write_bytes(b"foreign replacement")
        with self.assertRaises(subprocess.TimeoutExpired):
            child.communicate(timeout=0.1)
        child.send_signal(signal.SIGTERM)
        stdout, stderr = child.communicate(timeout=5)
        self.assertEqual(child.returncode, -signal.SIGTERM)
        self.assertEqual((stdout, stderr), (b"", b""))
        self.assertEqual(path.read_bytes(), b"foreign replacement")


if __name__ == "__main__":
    unittest.main()
