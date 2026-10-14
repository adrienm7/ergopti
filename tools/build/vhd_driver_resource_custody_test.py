"""Finite real signal and file-descriptor custody controls; no native grant."""

import errno
import os
from pathlib import Path
import signal
import tempfile
import time
import unittest
from unittest.mock import patch

import owned_runtime_product_build as product
import vhd_driver_resource_build_test as filesystem


class ResourceDescriptorControls(unittest.TestCase):
    def setUp(self):
        self.fixture = filesystem.ResourceFilesystemControls()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.real_open, self.real_close = os.open, os.close
        self.opened, self.closed = [], []
        self.saved_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        self.addCleanup(signal.pthread_sigmask, signal.SIG_SETMASK, self.saved_mask)
        self.saved_handler = signal.getsignal(signal.SIGALRM)
        self.addCleanup(signal.signal, signal.SIGALRM, self.saved_handler)
        signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGALRM})
        self.primary = RuntimeError("frozen controlled interruption")

    def interrupted(self, *_):
        raise self.primary

    def close_recovery(self):
        # The original failing actor may retain a genuinely leaked test FD.
        # This test-owned cleanup is not credit for production retirement.
        for fd in self.opened:
            try:
                os.fstat(fd)
            except OSError as error:
                self.assertEqual(error.errno, errno.EBADF)
            else:
                self.real_close(fd)

    def test_parent_acquisition_interrupt_releases_actual_fd_before_delivery(self):
        signal.signal(signal.SIGALRM, self.interrupted)
        parent = self.fixture.resources

        def opened(path, *args, **kwargs):
            fd = self.real_open(path, *args, **kwargs)
            if Path(path) == parent:
                self.opened.append(fd)
                signal.raise_signal(signal.SIGALRM)
            return fd

        self.addCleanup(self.close_recovery)
        with patch.object(product.os, "open", side_effect=opened):
            with self.assertRaises(RuntimeError) as caught:
                self.fixture.stage()
        self.assertIs(caught.exception, self.primary)
        self.assertEqual(len(self.opened), 1)
        with self.assertRaises(OSError) as closed:
            os.fstat(self.opened[0])
        self.assertEqual(closed.exception.errno, errno.EBADF)
        self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), self.saved_mask)

    def test_destination_close_refusal_still_attempts_parent_close_once(self):
        parent_fd = destination_fd = None
        refusal = OSError("frozen controlled destination close refusal")

        def opened(path, *args, **kwargs):
            nonlocal parent_fd, destination_fd
            fd = self.real_open(path, *args, **kwargs)
            if Path(path) == self.fixture.resources:
                parent_fd = fd
                self.opened.append(fd)
            elif path == "VirtualHIDDriverPayload":
                destination_fd = fd
                self.opened.append(fd)
            return fd

        def close(fd):
            self.closed.append(fd)
            self.real_close(fd)
            if fd == destination_fd:
                raise refusal

        self.addCleanup(self.close_recovery)
        with (
            patch.object(product.os, "open", side_effect=opened),
            patch.object(product.os, "close", side_effect=close),
        ):
            with self.assertRaises(OSError) as caught:
                self.fixture.stage()
        self.assertIs(caught.exception, refusal)
        self.assertEqual(self.closed.count(destination_fd), 1)
        self.assertEqual(self.closed.count(parent_fd), 1)
        self.assertTrue(caught.exception._resource_custody.debt)

    def test_body_primary_survives_destination_close_refusal_with_debt(self):
        destination_fd = None
        refusal = OSError("frozen secondary close refusal")
        original = product._write_exclusive
        live = True

        def opened(path, *args, **kwargs):
            nonlocal destination_fd
            fd = self.real_open(path, *args, **kwargs)
            if path == "VirtualHIDDriverPayload":
                destination_fd = fd
            return fd

        def written(*args, **kwargs):
            nonlocal live
            original(*args, **kwargs)
            live = False

        def current():
            if not live:
                raise self.primary

        def close(fd):
            self.real_close(fd)
            if fd == destination_fd:
                raise refusal

        with (
            patch.object(product.os, "open", side_effect=opened),
            patch.object(product.os, "close", side_effect=close),
            patch.object(product, "_write_exclusive", side_effect=written),
        ):
            with self.assertRaises(RuntimeError) as caught:
                self.fixture.stage(current)
        self.assertIs(caught.exception, self.primary)
        self.assertIn(refusal, caught.exception._resource_custody.failures)
        self.assertTrue(caught.exception._resource_custody.debt)

    def test_dirfd_write_acquisition_interrupt_releases_leaf_before_delivery(self):
        signal.signal(signal.SIGALRM, self.interrupted)
        parent = self.real_open(self.fixture.resources, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(self.real_close, parent)

        def opened(path, *args, **kwargs):
            fd = self.real_open(path, *args, **kwargs)
            if path == "controlled-leaf":
                self.opened.append(fd)
                signal.raise_signal(signal.SIGALRM)
            return fd

        self.addCleanup(self.close_recovery)
        with patch.object(product.os, "open", side_effect=opened):
            with self.assertRaises(RuntimeError) as caught:
                product._write_exclusive(
                    "controlled-leaf",
                    b"frozen",
                    0o644,
                    time.monotonic() + 10,
                    directory_descriptor=parent,
                )
        self.assertIs(caught.exception, self.primary)
        with self.assertRaises(OSError) as closed:
            os.fstat(self.opened[0])
        self.assertEqual(closed.exception.errno, errno.EBADF)

    def test_dirfd_write_preserves_primary_and_records_leaf_close_refusal(self):
        parent = self.real_open(self.fixture.resources, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(self.real_close, parent)
        refusal = OSError("frozen secondary leaf close refusal")

        def close(fd):
            self.real_close(fd)
            raise refusal

        with (
            patch.object(product.os, "write", side_effect=self.primary),
            patch.object(product.os, "close", side_effect=close),
        ):
            with self.assertRaises(RuntimeError) as caught:
                product._write_exclusive(
                    "controlled-leaf",
                    b"frozen",
                    0o644,
                    time.monotonic() + 10,
                    directory_descriptor=parent,
                )
        self.assertIs(caught.exception, self.primary)
        self.assertIn(refusal, caught.exception._resource_custody.failures)
        self.assertTrue(caught.exception._resource_custody.debt)

    def test_read_close_refusal_records_debt_and_outer_descriptors_retire(self):
        parent_fd = destination_fd = None
        refusal = OSError("frozen read close refusal")

        def opened(path, *args, **kwargs):
            nonlocal parent_fd, destination_fd
            fd = self.real_open(path, *args, **kwargs)
            if Path(path) == self.fixture.resources:
                parent_fd = fd
                self.opened.append(fd)
            elif path == "VirtualHIDDriverPayload":
                destination_fd = fd
                self.opened.append(fd)
            return fd

        def close(fd):
            self.closed.append(fd)
            self.real_close(fd)

        # The real snapshot owns the first read after both exclusive writes.
        original_snapshot = product._snapshot

        def snapshot(*args, **kwargs):
            def refused_close(fd):
                self.closed.append(fd)
                self.real_close(fd)
                raise refusal

            with patch.object(product.os, "close", side_effect=refused_close):
                return original_snapshot(*args, **kwargs)

        self.addCleanup(self.close_recovery)
        with (
            patch.object(product.os, "open", side_effect=opened),
            patch.object(product.os, "close", side_effect=close),
            patch.object(product, "_snapshot", side_effect=snapshot),
        ):
            with self.assertRaises(OSError) as caught:
                self.fixture.stage()
        self.assertIs(caught.exception, refusal)
        self.assertTrue(caught.exception._resource_custody.debt)
        self.assertEqual(self.closed.count(destination_fd), 1)
        self.assertEqual(self.closed.count(parent_fd), 1)

    def test_mask_restore_refusal_cannot_publish_success_or_clear_debt(self):
        original = signal.pthread_sigmask
        refusal = OSError("frozen mask restoration refusal")

        def mask(how, values):
            if how == signal.SIG_SETMASK:
                raise refusal
            return original(how, values)

        with patch.object(signal, "pthread_sigmask", side_effect=mask):
            with self.assertRaises(OSError) as caught:
                self.fixture.stage()
        self.assertIs(caught.exception, refusal)
        custody = caught.exception._resource_custody
        self.assertTrue(custody.debt)
        self.assertFalse(custody.mask_restored)
        self.assertTrue(all(row["closed"] for row in custody.owners))

    def test_original_sink_failure_retains_exact_resource_exception_and_custody(self):
        import remap_runtime_build as build

        refusal = OSError("frozen resource primary")
        custody = object()
        refusal._resource_custody = custody

        def current():
            raise refusal

        from types import SimpleNamespace

        claim = SimpleNamespace(current=current)
        sink = object.__new__(build._ProductionSink)
        sink._distribution_claim = claim
        sink.production_module = SimpleNamespace(ProductBuildRefusal=RuntimeError)
        sink.current = lambda *_: self.fail("The refused claim crossed a later source boundary")
        sink.export_signed(
            {},
            object(),
            object(),
            {},
            {},
            b"not a certificate",
            "not identity",
            claim,
            time.monotonic() + 10,
        )
        self.assertEqual(sink.packaged.code, "production_packaging")
        self.assertIs(sink.packaged.resource_failure, refusal)
        self.assertIs(sink.packaged.resource_failure._resource_custody, custody)


if __name__ == "__main__":
    unittest.main(verbosity=2)
