# tools/diagnostics/macos_ollama_daemon_authority_reader_test.py
"""Actual retained private session/authority reads and interruption closure."""

import importlib.util
import os
from pathlib import Path
import signal
import sys
import unittest
from unittest.mock import patch

specification = importlib.util.spec_from_file_location(
    "daemon_authority_reader_fixture",
    Path(__file__).with_name("macos_ollama_daemon_authority_test.py"),
)
FIXTURE = importlib.util.module_from_spec(specification)
specification.loader.exec_module(FIXTURE)


@unittest.skipUnless(os.name == "posix", "Actual POSIX namespace/descriptor evidence required")
class BoundReaderControls(unittest.TestCase):
    def setUp(self):
        self.case = FIXTURE.DaemonAuthorityControls("runTest")
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)
        self.case.publish()
        self.authority = FIXTURE.AUTH
        self.descriptors = []
        self.open = os.open

        def observed_open(*arguments, **options):
            descriptor = self.open(*arguments, **options)
            self.descriptors.append(descriptor)
            return descriptor

        control = patch.object(self.authority.os, "open", observed_open)
        control.start()
        self.addCleanup(control.stop)

    def read(self, progress=lambda: None):
        return self.authority.read_pair(
            self.case.session.directory,
            self.case.session.name,
            self.case.policy,
            os.geteuid(),
            progress=progress,
        )

    def assert_closed(self):
        self.assertEqual(len(self.descriptors), 3)
        for descriptor in self.descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_exact_session_bytes_and_original_authority_read_with_all_fds_closed(self):
        session, authority = self.read()
        self.assertEqual(session, self.case.session_data)
        self.assertEqual(
            authority,
            {"source_alias": self.case.alias.proof, "listener": self.case.operation.listener},
        )
        self.assert_closed()
        self.assertTrue(self.case.session.path.exists())
        self.assertTrue(self.case.authority.path.exists())

    def test_different_private_session_bytes_refuse_cross_session_replay(self):
        original = self.case.session.path.read_bytes()
        self.case.session.path.write_bytes(original.replace(b'"11434"', b'"11435"'))
        try:
            with self.assertRaises(RuntimeError):
                self.read()
            self.assert_closed()
        finally:
            self.case.session.path.write_bytes(original)

    def test_public_file_mode_refuses_without_reading_authority(self):
        self.case.session.path.chmod(0o644)
        try:
            with self.assertRaises(self.authority.ImageRefusal):
                self.read()
            self.assertEqual(len(self.descriptors), 2)
            for descriptor in self.descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
        finally:
            self.case.session.path.chmod(0o600)

    def test_fifo_sidecar_refuses_without_blocking_for_an_unowned_writer(self):
        path = self.case.authority.path
        held = path.with_suffix(".held")
        path.rename(held)
        os.mkfifo(path, 0o600)
        observed_open = self.authority.os.open

        def finite_open(filename, flags, *arguments, **options):
            if filename == path.name:
                # Refuse an unbounded test mutation before entering the kernel;
                # the actual positive control still opens the genuine FIFO.
                self.assertTrue(flags & os.O_NONBLOCK)
            return observed_open(filename, flags, *arguments, **options)

        try:
            with patch.object(self.authority.os, "open", finite_open):
                with self.assertRaises(self.authority.ImageRefusal):
                    self.read()
            self.assert_closed()
            self.assertEqual(held.read_bytes(), self.case.authority._written)
        finally:
            path.unlink()
            held.rename(path)

    def test_symlink_sidecar_refuses_instead_of_reopening_foreign_target(self):
        path = self.case.authority.path
        held = path.with_suffix(".held")
        path.rename(held)
        path.symlink_to(held)
        try:
            with self.assertRaises(OSError):
                self.read()
            self.assertEqual(len(self.descriptors), 2)
            for descriptor in self.descriptors:
                with self.assertRaises(OSError):
                    os.fstat(descriptor)
            self.assertEqual(held.read_bytes(), self.case.authority._written)
        finally:
            path.unlink()
            held.rename(path)

    def test_replacement_after_authentication_refuses_exact_final_vnode(self):
        path = self.case.authority.path
        held = path.with_suffix(".held")
        authenticate = self.authority.POLICY.authenticate

        def replace(*arguments):
            result = authenticate(*arguments)
            path.rename(held)
            path.write_bytes(held.read_bytes())
            path.chmod(0o600)
            return result

        try:
            with patch.object(self.authority.POLICY, "authenticate", replace):
                with self.assertRaises(self.authority.ImageRefusal):
                    self.read()
            self.assert_closed()
            self.assertNotEqual(path.stat().st_ino, held.stat().st_ino)
        finally:
            path.unlink()
            held.rename(path)

    def test_directory_replacement_refuses_original_held_namespace(self):
        path = self.case.session.directory
        held = path.with_name("held-sessions")
        authenticate = self.authority.POLICY.authenticate

        def replace(*arguments):
            result = authenticate(*arguments)
            path.rename(held)
            path.mkdir(mode=0o700)
            return result

        try:
            with patch.object(self.authority.POLICY, "authenticate", replace):
                with self.assertRaises(self.authority.ImageRefusal):
                    self.read()
            self.assert_closed()
            self.assertEqual(list(path.iterdir()), [])
        finally:
            path.rmdir()
            held.rename(path)

    def test_actual_sigint_after_first_close_records_debt_and_closes_remaining_fds(self):
        close = os.close
        calls = []

        def interrupt(descriptor):
            calls.append(descriptor)
            close(descriptor)
            if len(calls) == 1:
                os.kill(os.getpid(), signal.SIGINT)

        with patch.object(self.authority.os, "close", interrupt):
            with self.assertRaises(self.authority.ImageRefusal) as observed:
                self.read()
        self.assertIsInstance(observed.exception.cleanup, KeyboardInterrupt)
        self.assertIsNone(observed.exception.primary)
        self.assertEqual(len(calls), 3)
        self.assertEqual(len(set(calls)), 3)
        self.assert_closed()
        self.assertTrue(self.case.authority.path.exists())

    def test_primary_auth_failure_and_cleanup_failure_are_distinct(self):
        original = self.case.authority.path.read_bytes()
        self.case.authority.path.write_bytes(b"{}")
        close = os.close
        calls = []

        def refuse(descriptor):
            calls.append(descriptor)
            close(descriptor)
            if len(calls) == 1:
                raise OSError("independent close refusal")

        try:
            with patch.object(self.authority.os, "close", refuse):
                with self.assertRaises(self.authority.ImageRefusal) as observed:
                    self.read()
            self.assertIsNotNone(observed.exception.primary)
            self.assertIsInstance(observed.exception.cleanup, OSError)
            self.assertEqual(len(calls), 3)
            self.assert_closed()
        finally:
            self.case.authority.path.write_bytes(original)

    def test_original_clock_exhaustion_closes_without_authenticated_transport(self):
        calls = []

        def deadline():
            calls.append(True)
            if len(calls) == 4:
                raise RuntimeError("deadline")

        with patch.object(
            self.authority.POLICY, "authenticate", wraps=self.authority.POLICY.authenticate
        ) as transport:
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                self.read(deadline)
            transport.assert_not_called()
        for descriptor in self.descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertEqual(self.case.session.path.read_bytes(), self.case.session._written)
        self.assertEqual(self.case.authority.path.read_bytes(), self.case.authority._written)

    def acquisition_interrupt(self, target):
        source = Path(self.authority.__file__)
        sites = {
            index + 1
            for index, line in enumerate(source.read_text().splitlines())
            if "descriptors.append(descriptor)" in line
        }
        self.assertEqual(len(sites), 1)
        previous_trace = sys.gettrace()
        previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
        observations = []
        calls = 0

        def trace(frame, event, argument):
            nonlocal calls
            if (
                event == "line"
                and frame.f_code.co_filename == str(source)
                and frame.f_lineno in sites
            ):
                calls += 1
                if calls == target:
                    descriptor = frame.f_locals["descriptor"]
                    identity = os.fstat(descriptor)
                    os.kill(os.getpid(), signal.SIGINT)
                    observations.append((descriptor, identity.st_dev, identity.st_ino))
            return trace

        try:
            sys.settrace(trace)
            with self.assertRaises(KeyboardInterrupt):
                self.read()
        finally:
            sys.settrace(previous_trace)
        self.assertEqual(len(observations), 1)
        self.assertEqual(len(self.descriptors), target)
        self.assertEqual(signal.pthread_sigmask(signal.SIG_BLOCK, set()), previous_mask)
        for descriptor in self.descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)
        self.assertEqual(self.case.session.path.read_bytes(), self.case.session._written)
        self.assertEqual(self.case.authority.path.read_bytes(), self.case.authority._written)

    def test_sigint_after_directory_open_returns_is_deferred_until_owned(self):
        self.acquisition_interrupt(1)

    def test_sigint_after_session_open_returns_is_deferred_until_owned(self):
        self.acquisition_interrupt(2)

    def test_sigint_after_authority_open_returns_is_deferred_until_owned(self):
        self.acquisition_interrupt(3)


if __name__ == "__main__":
    unittest.main()
