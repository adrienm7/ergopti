# tools/diagnostics/macos_owned_process_test.py
"""Independent ownership models; these do not qualify actual macOS syscalls."""

import ctypes
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import macos_owned_process as owner


class OwnedProcessControls(unittest.TestCase):
    def setUp(self):
        self.kill_signal = patch.object(owner.signal, "SIGKILL", 9, create=True)
        self.kill_signal.start()
        self.addCleanup(self.kill_signal.stop)
        for name, value in (("SIG_BLOCK", 0), ("SIG_SETMASK", 2)):
            option = patch.object(owner.signal, name, value, create=True)
            option.start()
            self.addCleanup(option.stop)
        masking = patch.object(owner.signal, "pthread_sigmask", return_value=set(), create=True)
        masking.start()
        self.addCleanup(masking.stop)

    def process(self, events):
        class Child:
            pid = 73136
            returncode = None

            def wait(self, **_options):
                events.append("reap")
                self.returncode = 0
                return 0

        return Child()

    def test_explicit_owned_stdin_is_preserved_for_private_fixture_input(self):
        native = Mock()
        native.observe_exit.return_value = object()
        native.live_members.return_value = []
        registered = []
        group = owner.acquire_owned(
            [sys.executable, "-c", "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())"],
            native,
            registered.append,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            self.assertEqual(registered, [group])
            group.process.stdin.write(b"actual bounded private pipe bytes")
            group.process.stdin.close()
            # This fixture proves real Popen input dispatch, not Darwin WNOWAIT.
            group.process.wait(timeout=10)
            self.assertEqual(group.process.stdout.read(), b"actual bounded private pipe bytes")
        finally:
            if group.process.poll() is None:
                group.process.kill()
                group.process.wait()
            for stream in (group.process.stdin, group.process.stdout, group.process.stderr):
                stream.close()

    def test_default_devnull_and_explicit_devnull_are_both_admitted(self):
        for supplied in ({}, {"stdin": subprocess.DEVNULL}):
            with self.subTest(supplied=supplied):
                native = Mock()
                native.observe_exit.return_value = object()
                native.live_members.return_value = []
                registered = []
                group = owner.acquire_owned(
                    [sys.executable, "-c", "import sys; print(len(sys.stdin.buffer.read()))"],
                    native,
                    registered.append,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    **supplied,
                )
                try:
                    self.assertEqual(registered, [group])
                    # Real child dispatch/EOF; native group syscall qualification
                    # remains under the separate original ownership controls.
                    self.assertEqual(group.process.wait(timeout=10), 0)
                    self.assertEqual(group.process.stdout.read().strip(), b"0")
                    self.assertIsNone(group.process.stdin)
                finally:
                    if group.process.poll() is None:
                        group.process.kill()
                        group.process.wait()
                    group.process.stdout.close()
                    group.process.stderr.close()

    def test_cancellation_inside_native_observation_preserves_reserved_group_cleanup(self):
        process = Mock(pid=73136, returncode=None)
        native = Mock()
        native.observe_exit.side_effect = [owner.OwnedProcessInterrupted("cancel"), object()]
        native.live_members.return_value = []
        group = owner.OwnedProcessGroup(process, native)
        with self.assertRaisesRegex(owner.OwnedProcessInterrupted, "cancel"):
            group.observe_exit()
        self.assertFalse(group.reservation_lost)
        with patch.object(owner.os, "killpg", create=True) as signalling:
            self.assertTrue(group.settle())
        signalling.assert_not_called()
        process.wait.assert_called_once_with(timeout=1)
        self.assertTrue(group.reaped)

    def test_uncatchable_worker_signal_relays_without_an_invalid_handler_change(self):
        with (
            patch.object(owner.signal, "SIGSTOP", 17, create=True),
            patch.object(owner.signal, "signal") as handlers,
            patch.object(owner.os, "getpid", return_value=501),
            patch.object(owner.os, "kill") as killed,
        ):
            owner.relay_worker_signal(-owner.signal.SIGKILL)
            owner.relay_worker_signal(-owner.signal.SIGSTOP)
        handlers.assert_not_called()
        self.assertEqual([call.args for call in killed.call_args_list], [(501, 9), (501, 17)])

    def test_catchable_worker_signal_restores_default_before_signaling_only_the_guardian(self):
        events = []
        with (
            patch.object(owner.signal, "SIGSTOP", 17, create=True),
            patch.object(
                owner.signal, "signal", side_effect=lambda *args: events.append(("handler", *args))
            ),
            patch.object(owner.os, "getpid", return_value=501),
            patch.object(
                owner.os, "kill", side_effect=lambda *args: events.append(("signal", *args))
            ),
        ):
            owner.relay_worker_signal(-owner.signal.SIGTERM)
        self.assertEqual(
            events,
            [
                ("handler", owner.signal.SIGTERM, owner.signal.SIG_DFL),
                ("signal", 501, owner.signal.SIGTERM),
            ],
        )

    def test_normal_worker_exit_cannot_request_any_signal_relay(self):
        with patch.object(owner.os, "kill") as killed:
            for status in (0, 1, 255):
                with self.subTest(status=status), self.assertRaises(owner.OwnedProcessError):
                    owner.relay_worker_signal(status)
        killed.assert_not_called()

    def test_pending_acquisition_interrupt_is_delivered_only_after_worker_is_registered(self):
        events = []
        child = self.process(events)
        native = Mock()
        native.observe_exit.return_value = object()
        native.live_members.return_value = []
        registered = []
        handlers = {}

        def interrupted(_signal, _frame):
            self.assertEqual(len(registered), 1)
            raise owner.OwnedProcessError("pending interruption delivered")

        def install(signum, handler):
            handlers[signum] = handler

        def spawn(*_arguments, **options):
            self.assertTrue(options["start_new_session"])
            handlers[owner.signal.SIGTERM](owner.signal.SIGTERM, None)
            return child

        with (
            patch.object(owner.subprocess, "Popen", side_effect=spawn),
            patch.object(owner.signal, "getsignal", return_value=interrupted),
            patch.object(owner.signal, "signal", side_effect=install),
            patch.object(owner.signal, "pthread_sigmask", create=True) as mask,
        ):
            with self.assertRaisesRegex(owner.OwnedProcessError, "pending interruption"):
                owner.acquire_owned(["owned"], native, registered.append)
        mask.assert_not_called()
        self.assertIs(registered[0].process, child)
        self.assertTrue(registered[0].settle())
        self.assertEqual(events, ["reap"])
        self.assertIs(handlers[owner.signal.SIGTERM], interrupted)
        self.assertIs(handlers[owner.signal.SIGINT], interrupted)

    def test_original_early_reap_cannot_signal_a_recycled_foreign_group(self):
        events = []
        child = self.process(events)
        child.returncode = 0  # The original Popen.wait path already released this PID.
        native = owner.NativeProcessGroups.__new__(owner.NativeProcessGroups)
        group = owner.OwnedProcessGroup(child, native)
        with patch.object(owner.os, "killpg", create=True) as signals:
            with self.assertRaisesRegex(owner.OwnedProcessError, "reaped before"):
                group.settle()
        signals.assert_not_called()
        self.assertTrue(group.reservation_lost)
        self.assertEqual(events, [])

    def test_exit_census_then_exactly_one_reap_never_signals_after_reap(self):
        events = []
        child = self.process(events)
        native = Mock()
        native.observe_exit.side_effect = lambda _child: events.append("reserved-exit") or object()
        native.live_members.side_effect = lambda *_arguments: events.append("census-empty") or []
        group = owner.OwnedProcessGroup(child, native)
        with patch.object(owner.os, "killpg", create=True) as signals:
            group.wait_for_exit(1)
            self.assertTrue(group.settle())
            self.assertTrue(group.settle())
        self.assertEqual(events, ["reserved-exit", "reserved-exit", "census-empty", "reap"])
        signals.assert_not_called()
        self.assertTrue(group.reaped)

    def test_reserved_zombie_keeps_pid_owned_through_descendant_signal_and_census(self):
        events = []
        child = self.process(events)
        native = Mock()
        native.observe_exit.side_effect = lambda _child: events.append("reserved-exit") or object()
        native.live_members.side_effect = [[87236], []]
        group = owner.OwnedProcessGroup(child, native)
        with (
            patch.object(
                owner.os,
                "killpg",
                side_effect=lambda pid, sig: events.append((pid, sig)),
                create=True,
            ),
            patch.object(owner.time, "monotonic", side_effect=[0, 1, 2]),
        ):
            self.assertTrue(group.settle())
        self.assertEqual(group.signals, [owner.signal.SIGTERM])
        self.assertEqual(events[-2:], ["reserved-exit", "reap"])
        self.assertLess(events.index((73136, owner.signal.SIGTERM)), events.index("reap"))
        self.assertFalse(group.receipt()["escaped_sessions_managed"])

    def test_lost_waitable_reservation_refuses_every_future_group_signal(self):
        events = []
        child = self.process(events)
        native = Mock()
        native.observe_exit.side_effect = owner.OwnedProcessError("child reservation lost")
        group = owner.OwnedProcessGroup(child, native)
        with patch.object(owner.os, "killpg", create=True) as signals:
            with self.assertRaises(owner.OwnedProcessError):
                group.settle()
            self.assertFalse(group.settle())
        signals.assert_not_called()
        self.assertEqual(events, [])

    def test_reap_failure_never_reopens_signal_authority_or_reaps_twice(self):
        child = self.process([])
        child.wait = Mock(side_effect=RuntimeError("unknown reap result"))
        native = Mock()
        native.observe_exit.return_value = object()
        native.live_members.return_value = []
        group = owner.OwnedProcessGroup(child, native)
        with patch.object(owner.os, "killpg", create=True) as signals:
            with self.assertRaisesRegex(RuntimeError, "unknown reap"):
                group.settle()
            self.assertFalse(group.settle())
        child.wait.assert_called_once_with(timeout=1)
        signals.assert_not_called()
        self.assertTrue(group.reap_started)
        self.assertFalse(group.reaped)

    def test_native_wait_observes_same_terminal_twice_with_wnowait_before_any_reap(self):
        child = self.process([])
        native = owner.NativeProcessGroups.__new__(owner.NativeProcessGroups)
        observation = SimpleNamespace(si_pid=73136, si_code=11, si_status=7)
        with (
            patch.object(owner.os, "P_PID", 1, create=True),
            patch.object(owner.os, "WEXITED", 4, create=True),
            patch.object(owner.os, "WNOHANG", 1, create=True),
            patch.object(owner.os, "WNOWAIT", 32, create=True),
            patch.object(owner.os, "CLD_EXITED", 11, create=True),
            patch.object(owner.os, "CLD_KILLED", 12, create=True),
            patch.object(owner.os, "CLD_DUMPED", 13, create=True),
            patch.object(owner.os, "waitid", return_value=observation, create=True) as waiting,
        ):
            self.assertIs(native.observe_exit(child), observation)
        self.assertEqual(
            [call.args for call in waiting.call_args_list], [(1, 73136, 37), (1, 73136, 37)]
        )
        self.assertIsNone(child.returncode)

    def test_native_census_requires_reserved_zombie_and_reports_live_inherited_members(self):
        self.assertEqual(ctypes.sizeof(owner.ProcBSDInfo), 136)
        self.assertEqual(owner.ProcBSDInfo.pgid.offset, 100)
        native = owner.NativeProcessGroups.__new__(owner.NativeProcessGroups)

        def listed(kind, group, storage, size):
            self.assertEqual((kind, group), (2, 73136))
            if storage is None:
                return 8
            storage[0], storage[1] = 73136, 87236
            return 8

        def info(pid, kind, include_zombies, destination, size):
            self.assertEqual((kind, include_zombies, size), (3, 1, 136))
            record = ctypes.cast(destination, ctypes.POINTER(owner.ProcBSDInfo)).contents
            record.pid, record.pgid = pid, 73136
            record.status = 5 if pid == 73136 else 2
            record.ppid = owner.os.getpid()
            return 136

        native.library = SimpleNamespace(proc_listpids=listed, proc_pidinfo=info)
        self.assertEqual(native.live_members(73136, 73136), [87236])

    def test_native_census_unknown_or_truncated_buffer_cannot_authorize_reap(self):
        native = owner.NativeProcessGroups.__new__(owner.NativeProcessGroups)
        native.library = Mock()
        native.library.proc_listpids.side_effect = [4, 260]
        with self.assertRaisesRegex(owner.OwnedProcessError, "truncated"):
            native.live_members(73136, 73136)
        native.library.proc_pidinfo.assert_not_called()

    def test_native_identity_refusal_reports_only_bounded_scalar_cause(self):
        for pid, received, native_errno, reported_pid, reported_group, status in (
            (73136, 0, 5, 0, 0, 0),
            (87236, 136, 0, 0, 73136, 2),
            (87236, 12, 22, 87236, 0, 5),
        ):
            with self.subTest(reserved=pid == 73136, received=received):
                native = owner.NativeProcessGroups.__new__(owner.NativeProcessGroups)

                def listed(_kind, _group, storage, _size):
                    if storage is None:
                        return 4
                    storage[0] = pid
                    return 4

                def info(_pid, _kind, _zombies, destination, _size):
                    record = ctypes.cast(destination, ctypes.POINTER(owner.ProcBSDInfo)).contents
                    record.pid, record.pgid, record.status = reported_pid, reported_group, status
                    ctypes.set_errno(native_errno)
                    return received

                native.library = SimpleNamespace(proc_listpids=listed, proc_pidinfo=info)
                with self.assertRaises(owner.OwnedProcessError) as refused:
                    native.live_members(73136, 73136)
                self.assertEqual(
                    str(refused.exception),
                    "Native process-group member identity was unavailable "
                    f"(received_bytes={received}, errno={native_errno}, "
                    f"reserved={int(pid == 73136)}, bsd_pid_match={int(reported_pid == pid)}, "
                    f"bsd_pgid_match={int(reported_group == 73136)}, status={status})",
                )
                self.assertNotIn(str(pid), str(refused.exception))
                self.assertNotIn("/", str(refused.exception))

    def test_exclusive_terminal_publication_preserves_existing_user_bytes(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / "terminal.json"
            owner.exclusive_receipt(path, {"schema": 1, "closed": True})
            original = path.read_bytes()
            with self.assertRaises(FileExistsError):
                owner.exclusive_receipt(path, {"closed": False})
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(json.loads(original), {"schema": 1, "closed": True})
            self.assertEqual(list(path.parent.glob(".owned-process-*")), [])

    def test_guardian_cleanup_failure_restores_handlers_and_preserves_primary_deadline(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            root.chmod(0o700)
            original_stat = Path.stat

            def private_root_stat(path, *arguments, **options):
                if path == root:
                    return SimpleNamespace(st_mode=0o40700)
                return original_stat(path, *arguments, **options)

            group = Mock()
            group.wait_for_exit.side_effect = subprocess.TimeoutExpired("owned", 1)
            group.settle.side_effect = owner.OwnedProcessError("census refused")
            with (
                patch.object(owner.Path, "stat", private_root_stat),
                patch.object(owner, "NativeProcessGroups"),
                patch.object(owner.subprocess, "Popen"),
                patch.object(owner, "OwnedProcessGroup", return_value=group),
                patch.object(owner.signal, "signal", return_value=owner.signal.SIG_DFL) as handlers,
            ):
                with self.assertRaisesRegex(owner.OwnedProcessError, "deadline") as failure:
                    owner.run_guardian(root / "receipt.json", 1, ["owned"])
            self.assertIsInstance(failure.exception.__cause__, subprocess.TimeoutExpired)
            self.assertEqual(
                [call.args[1] for call in handlers.call_args_list[-2:]],
                [owner.signal.SIG_DFL, owner.signal.SIG_DFL],
            )
            self.assertFalse((root / "receipt.json").exists())


if __name__ == "__main__":
    unittest.main()
