# tools/diagnostics/apple_shortcuts_cold_cli_probe_test.py
"""Portable real-body ownership controls; POSIX mode ports are explicitly modeled."""

from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

import apple_shortcuts_cold_cli_probe as subject
import macos_owned_process as genuine_owner


class GroupPort:
    """Record the native owner's contract without claiming a Darwin process."""

    def __init__(self):
        self.process = SimpleNamespace(pid=200, returncode=None)
        self.observation = SimpleNamespace(si_pid=200, si_code=1, si_status=0)
        self.ack = True
        self.retired_exit = 0
        self.settle_calls = 0
        self.observe_error = None
        self.settle_error = None

    def observe_exit(self):
        if self.observe_error:
            raise self.observe_error
        return self.observation

    def settle(self):
        self.settle_calls += 1
        if self.settle_error:
            raise self.settle_error
        if self.ack:
            self.process.returncode = self.retired_exit
        return self.ack

    def receipt(self):
        return {
            "worker_pid": 200,
            "group_id": 200,
            "closed": self.process.returncode is not None,
            "reservation_lost": False,
            "signals": [],
            "live_group_members": [],
            "escaped_sessions_managed": False,
        }


class ColdCliControls(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.parent = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.real_lstat = Path.lstat
        self.real_fstat = os.fstat
        self.stack.enter_context(
            mock.patch.object(subject.os, "getuid", return_value=7, create=True)
        )
        self.stack.enter_context(
            mock.patch.object(subject.os, "O_NOFOLLOW", getattr(os, "O_NOFOLLOW", 0), create=True)
        )
        self.stack.enter_context(
            mock.patch.object(Path, "lstat", lambda path: self.modeled_lstat(path))
        )
        self.stack.enter_context(mock.patch.object(subject.os, "fstat", self.modeled_fstat))
        self.group = GroupPort()
        self.acquire_calls = []
        self.stdout = b"PRIVATE name\n(uuid-fixture)"
        self.stderr = b"PRIVATE diagnostic"
        self.acquire_error = None
        self.error_after_register = None
        self.ownership = SimpleNamespace(
            OwnedProcessInterrupted=genuine_owner.OwnedProcessInterrupted,
            acquire_owned=self.acquire,
        )
        self.attempts = []
        self.addCleanup(self.release_owned)

    def modeled_lstat(self, path):
        info = self.real_lstat(path)
        values = list(info)
        if path.parent == self.parent and path.name.startswith("ergopti-shortcuts-cold-"):
            values[0] = stat.S_IFDIR | 0o700
            values[4] = 7
        return os.stat_result(values)

    def modeled_fstat(self, descriptor):
        info = self.real_fstat(descriptor)
        values = list(info)
        values[0] = stat.S_IFREG | 0o600
        values[4] = 7
        return os.stat_result(values)

    def acquire(self, arguments, native, register, **options):
        self.acquire_calls.append(arguments)
        self.assertEqual(arguments, ["/usr/bin/shortcuts", "list", "--show-identifiers"])
        if self.acquire_error:
            raise self.acquire_error
        register(self.group)
        options["stdout"].write(self.stdout)
        options["stderr"].write(self.stderr)
        if self.error_after_register:
            raise self.error_after_register
        return self.group

    def attempt(self):
        value = subject.ColdCliAttempt(self.parent, self.ownership)
        self.attempts.append(value)
        return value

    def release_owned(self):
        # Recording fixtures acknowledge their own model before releasing files.
        for attempt in self.attempts:
            self.group.ack = True
            self.group.retired_exit = 0
            self.group.settle_error = None
            attempt.retire()
            attempt.close_captures()

    def test_one_fixed_cli_only_and_closed_hashes_never_qualify_feature(self):
        attempt = self.attempt()
        attempt.execute(object())
        report = attempt.report()
        self.assertEqual(self.acquire_calls, [["/usr/bin/shortcuts", "list", "--show-identifiers"]])
        self.assertEqual(self.group.settle_calls, 1)
        self.assertEqual(
            report["captures"]["stdout"],
            {"bytes": len(self.stdout), "sha256": hashlib.sha256(self.stdout).hexdigest()},
        )
        self.assertEqual(report["captures"]["stderr"]["bytes"], len(self.stderr))
        self.assertEqual(report["retired_exit"], 0)
        self.assertIs(report["feature_qualified"], False)
        self.assertIs(report["automation_cancellation_qualified"], False)
        self.assertIs(report["groups"][0]["escaped_sessions_managed"], False)
        self.assertEqual(report["permission"], "not_determined")

    def test_empty_native_stdout_is_an_observation_not_provider_admission(self):
        self.stdout = b""
        self.stderr = b""
        attempt = self.attempt()
        attempt.execute(object())
        self.assertEqual(
            attempt.report()["captures"]["stdout"],
            {
                "bytes": 0,
                "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            },
        )
        self.assertIs(attempt.report()["invocation_qualified"], False)

    def test_raw_captures_remain_private_and_are_never_in_public_report(self):
        attempt = self.attempt()
        attempt.execute(object())
        text = json.dumps(attempt.report())
        for private in (
            "PRIVATE",
            "uuid-fixture",
            str(attempt.private_root),
            "accepts_input",
            "choices",
        ):
            self.assertNotIn(private, text)
        self.assertEqual((attempt.private_root / "stdout").read_bytes(), self.stdout)
        self.assertEqual(self.modeled_lstat(attempt.private_root).st_mode & 0o777, 0o700)

    def test_capture_uses_original_fd_after_real_body_retirement_port(self):
        attempt = self.attempt()
        with mock.patch.object(
            subject.os, "open", side_effect=AssertionError("No capture path reopen")
        ):
            attempt.execute(object())
        self.assertTrue(attempt.capture_facts["available"])

    def test_failure_before_acquisition_has_no_fabricated_process(self):
        error = OSError("PRIVATE before acquire")
        self.acquire_error = error
        attempt = self.attempt()
        with self.assertRaises(OSError) as raised:
            attempt.execute(object())
        self.assertIs(raised.exception, error)
        self.assertEqual(attempt.groups, [])
        self.assertIsNone(attempt.report()["retired_exit"])
        self.assertTrue(all(stream.closed for stream in attempt.streams))

    def test_failed_handoff_after_registration_keeps_exact_owner(self):
        error = genuine_owner.OwnedProcessInterrupted("PRIVATE handoff")
        self.error_after_register = error
        attempt = self.attempt()
        with self.assertRaises(genuine_owner.OwnedProcessInterrupted) as raised:
            attempt.execute(object())
        self.assertIs(raised.exception, error)
        self.assertEqual(attempt.groups, [self.group])
        self.assertEqual(self.group.settle_calls, 1)

    def test_capture_failure_preserves_first_exception_and_exact_retirement(self):
        error = OSError("PRIVATE observe")
        self.group.observe_error = error
        attempt = self.attempt()
        with self.assertRaises(OSError) as raised:
            attempt.execute(object())
        self.assertIs(raised.exception, error)
        self.assertTrue(attempt.retirement_ack)

    def test_timeout_budget_twenty_is_permanent_after_retirement_ack(self):
        self.group.observation = None
        attempt = self.attempt()
        times = iter([0, 0, 20, 20])
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(
                object(), clock=lambda: next(times), sleep=lambda _: self.fail("No extra budget")
            )
        self.assertEqual(raised.exception.cause, "deadline")
        self.assertEqual(attempt.report()["failure"], "deadline")
        self.assertEqual(attempt.report()["elapsed_us"], 20000000)
        self.assertTrue(attempt.report()["retirement_ack"])

    def test_live_output_bound_is_not_repaired_by_cleanup(self):
        self.stdout = b"x" * 65537
        self.group.observation = None
        attempt = self.attempt()
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(object())
        self.assertEqual(raised.exception.cause, "output_bound")
        self.assertFalse(attempt.capture_facts["available"])

    def test_retirement_false_retains_native_owner_and_both_captures(self):
        self.group.ack = False
        attempt = self.attempt()
        with mock.patch.object(
            subject.os, "read", side_effect=AssertionError("Never read live output")
        ):
            with self.assertRaises(subject.ObservationRefused) as raised:
                attempt.execute(object())
        self.assertEqual(raised.exception.cause, "retirement_refused")
        self.assertFalse(attempt.retirement_ack)
        self.assertFalse(any(stream.closed for stream in attempt.streams))
        self.assertEqual(attempt.groups, [self.group])
        self.assertFalse(attempt.report()["groups"][0]["closed"])

    def test_retirement_throw_is_separate_and_cannot_mask_primary_cancel(self):
        self.group.settle_error = OSError("PRIVATE retire")
        error = KeyboardInterrupt("PRIVATE primary")
        self.error_after_register = error
        attempt = self.attempt()
        with self.assertRaises(KeyboardInterrupt) as raised:
            attempt.execute(object())
        self.assertIs(raised.exception, error)
        self.assertEqual(attempt.report()["cleanup_failure"], "cleanup_refused")
        self.assertFalse(attempt.retirement_ack)

    def test_recording_true_without_actual_terminal_cannot_grant_retirement(self):
        self.group.retired_exit = None
        attempt = self.attempt()
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(object())
        self.assertEqual(raised.exception.cause, "retirement_refused")
        self.assertFalse(attempt.retirement_ack)
        self.assertFalse(any(stream.closed for stream in attempt.streams))

    def test_partial_capture_acquisition_closes_only_its_existing_original(self):
        real_fdopen = os.fdopen
        acquired = []

        def fdopen(descriptor, *args, **kwargs):
            if acquired:
                raise OSError("PRIVATE second capture")
            stream = real_fdopen(descriptor, *args, **kwargs)
            acquired.append(stream)
            return stream

        with mock.patch.object(subject.os, "fdopen", side_effect=fdopen):
            with self.assertRaises(OSError):
                self.attempt()
        self.assertEqual(len(acquired), 1)
        self.assertTrue(acquired[0].closed)
        self.assertEqual(self.acquire_calls, [])

    def test_foreign_boolean_and_invalid_native_tuple_refuse(self):
        for field, value in (("si_pid", 201), ("si_pid", True), ("si_code", 6), ("si_status", 256)):
            with self.subTest(field=field, value=value):
                self.group = GroupPort()
                setattr(self.group.observation, field, value)
                attempt = self.attempt()
                with self.assertRaises(subject.ObservationRefused) as raised:
                    attempt.execute(object())
                self.assertEqual(raised.exception.cause, "terminal_shape_refused")

    def test_native_nonzero_and_signal_keep_exact_terminal_and_exit(self):
        for code, status, retired in ((1, 37, 37), (2, 15, -15)):
            with self.subTest(code=code):
                self.group = GroupPort()
                self.group.observation.si_code = code
                self.group.observation.si_status = status
                self.group.retired_exit = retired
                attempt = self.attempt()
                with self.assertRaises(subject.ObservationRefused) as raised:
                    attempt.execute(object())
                self.assertEqual(raised.exception.cause, "native_exit_refused")
                self.assertEqual(
                    attempt.report()["terminal_before_retirement"],
                    {"pid": 200, "code": code, "status": status},
                )
                self.assertEqual(attempt.report()["retired_exit"], retired)

    def test_terminal_zero_cannot_hide_different_actual_retired_exit(self):
        self.group.retired_exit = 9
        attempt = self.attempt()
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(object())
        self.assertEqual(raised.exception.cause, "native_exit_refused")

    def test_optional_capture_io_preserves_all_original_cancellations(self):
        for error in (
            genuine_owner.OwnedProcessInterrupted("private"),
            KeyboardInterrupt("private"),
            SystemExit(4),
        ):
            with self.subTest(kind=type(error).__name__):
                self.group = GroupPort()
                self.error_after_register = error
                attempt = self.attempt()
                with mock.patch.object(subject.os, "read", side_effect=OSError("PRIVATE capture")):
                    with self.assertRaises(type(error)) as raised:
                        attempt.execute(object())
                self.assertIs(raised.exception, error)
                self.assertEqual(attempt.report()["cleanup_failure"], "cleanup_refused")
                self.assertFalse(attempt.capture_facts["available"])

    def test_new_observation_cancel_wins_over_ordinary_primary(self):
        self.error_after_register = ValueError("PRIVATE ordinary")
        cancel = genuine_owner.OwnedProcessInterrupted("PRIVATE new")
        attempt = self.attempt()
        with mock.patch.object(subject.os, "read", side_effect=cancel):
            with self.assertRaises(genuine_owner.OwnedProcessInterrupted) as raised:
                attempt.execute(object())
        self.assertIs(raised.exception, cancel)

    def test_no_primary_capture_io_is_failed_not_missing_tuple_success(self):
        attempt = self.attempt()
        with mock.patch.object(subject.os, "read", side_effect=OSError("PRIVATE io")):
            with self.assertRaises(OSError):
                attempt.execute(object())
        self.assertFalse(attempt.report()["captures"]["available"])
        self.group = GroupPort()
        changed = self.attempt()
        samples = 0

        def changed_fstat(descriptor):
            nonlocal samples
            samples += 1
            values = list(self.modeled_fstat(descriptor))
            if samples == 2:
                values[1] += 1
            return os.stat_result(values)

        with mock.patch.object(subject.os, "fstat", side_effect=changed_fstat):
            with self.assertRaises(subject.ObservationRefused) as raised:
                changed.execute(object())
        self.assertEqual(raised.exception.cause, "capture_changed")
        self.assertFalse(changed.report()["captures"]["available"])

    def test_wrong_kind_mode_uid_and_symlink_private_roots_refuse(self):
        root = self.parent / "external"
        root.mkdir()
        for mode, uid in (
            (stat.S_IFREG | 0o700, 7),
            (stat.S_IFDIR | 0o777, 7),
            (stat.S_IFDIR | 0o700, 8),
            (stat.S_IFLNK | 0o700, 7),
        ):
            with self.subTest(mode=mode, uid=uid):
                info = SimpleNamespace(st_mode=mode, st_uid=uid)
                with mock.patch.object(Path, "lstat", return_value=info):
                    with self.assertRaises(subject.ObservationRefused) as raised:
                        subject.private_directory(root)
                self.assertEqual(raised.exception.cause, "private_root_refused")

    def run_actual_main(
        self, publisher=None, sleeper=None, clock=None, printer=None, modeled_version=(3, 13)
    ):
        """Exercise the real entry with explicit source/native/POSIX recording ports."""
        source_root = Path(subject.__file__).resolve().parents[2]
        output = self.parent / "ergopti-shortcuts-cold-public"
        private = self.parent / "ergopti-shortcuts-cold-private"
        packets = []
        self.ownership.NativeProcessGroups = lambda: object()
        self.ownership.exclusive_receipt = publisher or (
            lambda path, packet: packets.append(json.loads(json.dumps(packet)))
        )
        original_attempt = subject.ColdCliAttempt

        def registered_attempt(*args):
            attempt = original_attempt(*args)
            self.attempts.append(attempt)
            return attempt

        def main_lstat(path):
            if path == Path("/usr/bin/shortcuts"):
                return SimpleNamespace(st_mode=stat.S_IFREG | 0o555, st_uid=0)
            info = self.modeled_lstat(path)
            if path.parent == private and path.name.startswith("ergopti-shortcuts-cold-"):
                values = list(info)
                values[0] = stat.S_IFDIR | 0o700
                values[4] = 7
                return os.stat_result(values)
            return info

        def pinned_source(arguments, **options):
            self.assertEqual(arguments[:2], ["git", "show"])
            relative = arguments[2].split(":", 1)[1]
            return (source_root / relative).read_bytes()

        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda module: None))
        with ExitStack() as ports:
            ports.enter_context(mock.patch.object(subject.sys, "platform", "darwin"))
            # This port models native eligibility; the host interpreter is not Darwin evidence.
            ports.enter_context(mock.patch.object(subject.sys, "version_info", modeled_version))
            ports.enter_context(
                mock.patch.object(
                    subject.sys,
                    "argv",
                    [
                        "cold-cli",
                        "--source-root",
                        str(source_root),
                        "--source-sha",
                        "a" * 40,
                        "--output",
                        str(output),
                        "--private-parent",
                        str(private),
                    ],
                )
            )
            ports.enter_context(mock.patch.object(Path, "lstat", main_lstat))
            ports.enter_context(
                mock.patch.object(subject.subprocess, "check_output", side_effect=pinned_source)
            )
            ports.enter_context(
                mock.patch.object(
                    subject.importlib.util, "spec_from_file_location", return_value=spec
                )
            )
            ports.enter_context(
                mock.patch.object(
                    subject.importlib.util, "module_from_spec", return_value=self.ownership
                )
            )
            ports.enter_context(mock.patch.object(subject.signal, "signal", return_value=None))
            ports.enter_context(
                mock.patch.object(subject, "ColdCliAttempt", side_effect=registered_attempt)
            )
            if sleeper is not None:
                ports.enter_context(mock.patch.object(subject.time, "sleep", side_effect=sleeper))
            if clock is not None:
                ports.enter_context(mock.patch.object(subject.time, "monotonic", side_effect=clock))
            if printer is not None:
                ports.enter_context(mock.patch("builtins.print", side_effect=printer))
            return subject.main(), packets

    def future_retirement_ack(self):
        """The recording owner supplies a later actual-contract terminal acknowledgement."""
        self.group.ack = False
        settle = self.group.settle

        def future_ack():
            if self.group.settle_calls + 1 >= 3:
                self.group.ack = True
            return settle()

        self.group.settle = future_ack

    def test_actual_main_below_native_python_floor_refuses_before_acquisition(self):
        with self.assertRaises(subject.ObservationRefused) as raised:
            self.run_actual_main(modeled_version=(3, 12))
        self.assertEqual(raised.exception.cause, "native_prerequisite_refused")
        self.assertEqual(self.acquire_calls, [])
        self.assertEqual(self.attempts, [])
        self.assertFalse((self.parent / "ergopti-shortcuts-cold-public").exists())
        self.assertFalse((self.parent / "ergopti-shortcuts-cold-private").exists())

    def test_actual_main_secondary_publication_and_print_failure_cannot_bypass_debt(self):
        self.future_retirement_ack()

        def refused_publication(*args):
            raise OSError("PRIVATE publication")

        def refused_print(*args, **kwargs):
            raise BrokenPipeError("PRIVATE diagnostic pipe")

        status, packets = self.run_actual_main(publisher=refused_publication, printer=refused_print)
        self.assertEqual(status, 1)
        self.assertEqual(packets, [])
        self.assertEqual(self.group.settle_calls, 3)
        self.assertTrue(self.attempts[-1].retirement_ack)
        self.assertTrue(all(stream.closed for stream in self.attempts[-1].streams))
        self.assertEqual(len(self.acquire_calls), 1)

    def test_actual_main_second_cancellation_during_sleep_cannot_bypass_debt(self):
        self.future_retirement_ack()
        sleeps = []

        def cancel_sleep(interval):
            sleeps.append(interval)
            raise genuine_owner.OwnedProcessInterrupted("PRIVATE second cancellation")

        status, packets = self.run_actual_main(sleeper=cancel_sleep)
        self.assertEqual(status, 1)
        self.assertEqual(sleeps, [0.02])
        self.assertEqual(self.group.settle_calls, 3)
        self.assertTrue(self.attempts[-1].retirement_ack)
        self.assertTrue(all(stream.closed for stream in self.attempts[-1].streams))
        self.assertFalse(packets[0]["retirement_ack"])
        self.assertFalse(packets[0]["feature_qualified"])
        self.assertEqual(len(self.acquire_calls), 1)

    def test_late_native_terminal_is_retained_but_cannot_admit_after_twenty(self):
        attempt = self.attempt()
        times = iter([0, 0, 20.02, 20.02])
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(object(), clock=lambda: next(times))
        self.assertEqual(raised.exception.cause, "deadline")
        self.assertEqual(
            attempt.report()["terminal_before_retirement"], {"pid": 200, "code": 1, "status": 0}
        )
        self.assertEqual(attempt.report()["retired_exit"], 0)
        self.assertTrue(attempt.retirement_ack)

    def test_actual_main_setup_consumed_budget_cannot_start_a_new_twenty(self):
        samples = []

        def clock():
            samples.append(None)
            return 0 if len(samples) == 1 else 21

        status, packets = self.run_actual_main(clock=clock)
        self.assertEqual(status, 1)
        self.assertEqual(self.acquire_calls, [])
        self.assertEqual(packets[0]["failure"], "deadline")
        self.assertIsNone(packets[0]["terminal_before_retirement"])
        self.assertTrue(packets[0]["retirement_ack"])

    def test_capture_completion_late_retains_native_zero_but_refuses_admission(self):
        attempt = self.attempt()
        times = iter([0, 0, 19.99, 20.02])
        with self.assertRaises(subject.ObservationRefused) as raised:
            attempt.execute(object(), clock=lambda: next(times))
        self.assertEqual(raised.exception.cause, "deadline")
        self.assertEqual(
            attempt.report()["terminal_before_retirement"], {"pid": 200, "code": 1, "status": 0}
        )
        self.assertEqual(attempt.report()["retired_exit"], 0)
        self.assertEqual(attempt.report()["elapsed_us"], 20020000)
        self.assertTrue(attempt.capture_facts["available"])
        self.assertTrue(attempt.retirement_ack)


if __name__ == "__main__":
    unittest.main()
