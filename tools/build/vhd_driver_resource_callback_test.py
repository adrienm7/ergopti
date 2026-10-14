"""Actual child signal-mask and callback-interruption resource controls."""

import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

import owned_runtime_product_build as product
import vhd_driver_resource_build_test as filesystem


class ResourceCurrentCallbackControls(unittest.TestCase):
    def setUp(self):
        self.fixture = filesystem.ResourceFilesystemControls()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.real_open, self.real_close = os.open, os.close
        self.opened = []
        self.original_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        self.original_handler = signal.getsignal(signal.SIGALRM)
        self.addCleanup(signal.pthread_sigmask, signal.SIG_SETMASK, self.original_mask)
        self.addCleanup(signal.signal, signal.SIGALRM, self.original_handler)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        self.expected_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())

    def open_parent(self, path, *args, **kwargs):
        fd = self.real_open(path, *args, **kwargs)
        if Path(path) == self.fixture.resources:
            self.opened.append(fd)
        return fd

    def test_actual_current_child_inherits_original_mask_not_descriptor_deferral(self):
        observations = []

        def current():
            run = subprocess.run(
                [
                    sys.executable,
                    "-B",
                    "-c",
                    "import json,signal; print(json.dumps(sorted(map(int, signal.pthread_sigmask(signal.SIG_BLOCK,set())))))",
                ],
                capture_output=True,
                check=False,
                timeout=5,
            )
            self.assertEqual(run.returncode, 0)
            self.assertEqual(run.stderr, b"")
            observed = json.loads(run.stdout)
            observations.append(observed)
            self.assertEqual(observed, sorted(map(int, self.expected_mask)))

        self.fixture.stage(current)
        self.assertGreater(len(observations), 1)
        self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), self.expected_mask)

    def test_current_interrupt_precedes_publish_and_retains_parent_cleanup(self):
        primary = RuntimeError("frozen source callback interruption")

        def handler(*_):
            raise primary

        signal.signal(signal.SIGALRM, handler)

        def current():
            if self.opened:
                signal.raise_signal(signal.SIGALRM)

        with patch.object(product.os, "open", side_effect=self.open_parent):
            with self.assertRaises(RuntimeError) as caught:
                self.fixture.stage(current)
        self.assertIs(caught.exception, primary)
        self.assertEqual(list(self.fixture.resources.iterdir()), [])
        self.assertEqual(len(self.opened), 1)
        with self.assertRaises(OSError) as closed:
            os.fstat(self.opened[0])
        self.assertEqual(closed.exception.errno, errno.EBADF)
        self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), self.expected_mask)


if __name__ == "__main__":
    unittest.main(verbosity=2)
