# tools/diagnostics/installed_vhd_acl_ci_test.py
"""Portable caller policy; native process and compiler endpoints are modeled."""

import copy
import errno
import json
from pathlib import Path
import shutil
import tempfile
import types
import unittest
from unittest import mock

import installed_vhd_acl_ci as subject


def native_sample():
    """Independent handwritten sample, not native ACL or retirement evidence."""
    acl = {
        "acquisition_attempted": True,
        "acquired": True,
        "acquire_errno": 0,
        "valid_result": 0,
        "valid_errno": 0,
        "first_result": -1,
        "first_errno": errno.EINVAL,
        "entry_present": False,
        "free_result": 0,
        "free_errno": 0,
    }
    nodes = []
    for role, inode in (("root", 2), ("library", 3)):
        nodes.append(
            {
                "role": role,
                "opened": True,
                "identity": {"device": 1, "inode": inode, "mode": 0o40755, "uid": 0, "gid": 0},
                "current": True,
                "pin_error": None,
                "error_code": None,
                "acl": copy.deepcopy(acl),
                "close_result": 0,
                "close_errno": 0,
            }
        )
    return {"schema": 1, "pid": 400, "nodes": nodes}


class CallerControls(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.inputs = self.root / "inputs"
        self.inputs.mkdir(mode=0o700)
        for path in subject.source_paths().values():
            copied = self.inputs / path.name
            shutil.copyfile(path, copied)
            copied.chmod(0o600)
        # Modeled subprocesses never execute this task-owned runtime-image fixture.
        self.runtime = self.root / "modeled-python-image"
        shutil.copyfile(Path(subject.sys.executable).resolve(strict=True), self.runtime)
        self.runtime.chmod(0o700)
        self.clock = [100.0]
        self.calls = []
        self.groups = []
        self.effect = lambda _phase, _group: None
        self.status = 0
        self.closed = True
        self.skip = False
        self.count = 22
        self.sample = native_sample()
        self.terminal_change = lambda _terminal: None
        self.actual_load = subject.load_captured
        self.source_hashes = None

    def acquired(self, arguments, _native, register, **options):
        phase = "guardian" if "run" in arguments else "optimized" if "-O" in arguments else "normal"
        self.calls.append((phase, arguments))
        number = 300 + len(self.groups)
        process = types.SimpleNamespace(pid=number, returncode=None)
        group = types.SimpleNamespace(process=process, reaped=False, reservation_lost=False)

        def wait(timeout):
            self.assertLessEqual(timeout, 35)
            self.assertLessEqual(timeout, 25)
            self.effect("wait_" + phase, group)
            if phase == "guardian":
                at = arguments.index("run")
                self.assertEqual(arguments[at + 2], "30")
                result_root = Path(arguments[-1])
                source_dir = Path(arguments[-2]).parent
                worker = self.actual_load(
                    "worker-model",
                    (source_dir / "installed_vhd_ci_fixture.py").read_bytes(),
                    source_dir / "installed_vhd_ci_fixture.py",
                    125.0,
                )
                terminal = {
                    "schema": 1,
                    "guardian_pid": number,
                    "worker_pid": 100,
                    "group_id": 100,
                    "closed": True,
                    "exit_status": 0,
                }
                self.terminal_change(terminal)
                Path(arguments[at + 1]).write_text(json.dumps(terminal))
                record = {
                    "schema": 1,
                    "kind": "read_only_acl_ancestry",
                    "pid": 100,
                    "native": self.sample,
                    "source_hashes": worker.source_hashes(),
                    "elapsed_seconds": 0.5,
                }
                (result_root / "acl-ancestry.json").write_text(json.dumps(record))
            else:
                message = f"Ran {self.count} tests in 0.010s\n\nOK"
                if self.skip:
                    message += " (skipped=1)"
                options["stderr"].write((message + "\n").encode())
                options["stderr"].flush()

        def settle(timeout=1):
            self.assertEqual(timeout, 3)
            self.effect("settle_" + phase, group)
            if self.closed:
                group.reaped = True
                process.returncode = self.status
            return self.closed

        group.wait_for_exit = wait
        group.settle = settle
        self.groups.append(group)
        register(group)
        self.effect("registered_" + phase, group)
        return group

    def loaded(self, name, data, path, deadline):
        actual = self.actual_load(name, data, path, deadline)
        if path.name == "macos_owned_process.py":
            actual.NativeProcessGroups = lambda: object()
            actual.acquire_owned = self.acquired
        return actual

    def execute(self):
        with (
            mock.patch.object(subject, "ROOT", self.inputs),
            mock.patch.object(subject.sys, "platform", "darwin"),
            mock.patch.object(subject.sys, "executable", str(self.runtime)),
            mock.patch.object(subject.time, "monotonic", side_effect=lambda: self.clock[0]),
            mock.patch.object(subject, "load_captured", side_effect=self.loaded),
        ):
            return subject.run(self.root)

    def test_actual_group_writable_runtime_refuses_before_native_ownership(self):
        self.runtime.chmod(0o720)
        with self.assertRaisesRegex(
            ValueError,
            r"Caller ordinary input owner refused: regular=True size=\d+ maximum=67108864 "
            r"mode=0o100720 uid=\d+ euid=\d+ links=1 source=False",
        ):
            self.execute()
        self.assertEqual(self.calls, [])
        self.assertEqual(self.groups, [])

    def test_healthy_retained_three_stages_have_no_authority(self):
        root, record = self.execute()
        self.assertEqual([row[0] for row in self.calls], ["normal", "optimized", "guardian"])
        self.assertEqual(record["classification"], "qualified")
        self.assertIs(record["authority"], False)
        self.assertEqual(record["status"], "observed")
        self.assertEqual(record["guardian_pid"], self.groups[-1].process.pid)
        self.assertEqual(record["worker_pid"], 100)
        self.assertTrue(all(group.reaped for group in self.groups))
        self.assertEqual(root.stat().st_mode & 0o777, 0o700)
        self.assertEqual(json.loads((root / "ci-classification.json").read_text()), record)

    def test_null_acl_diagnostic_stays_unknown(self):
        for node in self.sample["nodes"]:
            node["acl"].update(
                acquired=False,
                acquire_errno=0,
                valid_result=None,
                valid_errno=None,
                first_result=None,
                first_errno=None,
                entry_present=None,
                free_result=None,
                free_errno=None,
            )
        _, record = self.execute()
        self.assertEqual(record["classification"], "unknown")
        self.assertIs(record["authority"], False)

    def test_release_failure_diagnostic_stays_denied(self):
        self.sample["nodes"][0]["close_result"] = -1
        _, record = self.execute()
        self.assertEqual(record["classification"], "denied")
        self.assertIs(record["authority"], False)

    def test_portable_count_refuses_before_guardian(self):
        for count in (0, 21, 23):
            with self.subTest(count=count):
                self.count = count
                with self.assertRaises(ValueError):
                    self.execute()
                self.assertNotIn("guardian", [row[0] for row in self.calls])

    def test_portable_skip_refuses_before_guardian(self):
        self.skip = True
        with self.assertRaises(ValueError):
            self.execute()
        self.assertNotIn("guardian", [row[0] for row in self.calls])

    def test_actual_nonzero_status_refuses(self):
        self.status = 7
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.groups[0].process.returncode, 7)

    def test_native_retirement_debt_refuses_no_publication(self):
        self.closed = False
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(any(self.root.rglob("ci-classification.json")))
        self.assertFalse(self.groups[0].reaped)

    def test_wrong_terminal_identity_refuses(self):
        self.terminal_change = lambda terminal: terminal.update(guardian_pid=999)
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(any(self.root.rglob("ci-classification.json")))

    def test_ack_without_true_settlement_refuses(self):
        def effect(phase, group):
            if phase == "settle_guardian":
                group.reservation_lost = True

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertFalse(any(self.root.rglob("ci-classification.json")))

    def test_deadline_during_wait_is_permanent_refusal(self):
        self.effect = lambda phase, _group: (
            self.clock.__setitem__(0, 126.0) if phase == "wait_normal" else None
        )
        with self.assertRaises(ValueError):
            self.execute()
        self.assertTrue(self.groups[0].reaped)
        self.assertNotIn("guardian", [row[0] for row in self.calls])

    def test_actual_input_drift_before_next_phase_refuses(self):
        def effect(phase, _group):
            if phase == "wait_normal":
                with (self.inputs / "installed-vhd-acl-ancestry.c").open("ab") as stream:
                    stream.write(b"\n/* Changed real input. */\n")

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertNotIn("guardian", [row[0] for row in self.calls])

    def test_actual_source_hardlink_refuses_before_any_acquisition(self):
        path = self.inputs / "installed-vhd-acl-ancestry.c"
        import os

        os.link(path, self.root / "hardlink")
        with self.assertRaises(ValueError):
            self.execute()
        self.assertEqual(self.calls, [])

    def test_after_registration_exception_keeps_owner_for_cleanup(self):
        expected = RuntimeError("controlled foreign exception")

        def effect(phase, _group):
            if phase == "registered_normal":
                raise expected

        self.effect = effect
        with self.assertRaises(RuntimeError) as caught:
            self.execute()
        self.assertIs(caught.exception, expected)
        self.assertTrue(self.groups[0].reaped)

    def test_staged_inventory_change_refuses_before_next_phase(self):
        def effect(phase, _group):
            if phase == "wait_normal":
                for path in self.root.rglob("source"):
                    (path / "foreign.py").write_text("raise RuntimeError('foreign')\n")

        self.effect = effect
        with self.assertRaises(ValueError):
            self.execute()
        self.assertNotIn("guardian", [row[0] for row in self.calls])

    def test_guardian_sample_is_read_after_settlement(self):
        facts = []

        def effect(phase, group):
            if phase == "settle_guardian":
                facts.append(group.process.returncode)

        self.effect = effect
        self.execute()
        self.assertEqual(facts, [None])
        self.assertTrue(self.groups[-1].reaped)

    def test_late_terminal_persistence_cannot_return_success(self):
        original = subject.persist

        def persist(path, packet):
            original(path, packet)
            if path.name == "ci-classification.json":
                self.clock[0] = 126.0

        with mock.patch.object(subject, "persist", side_effect=persist):
            with self.assertRaises(ValueError):
                self.execute()
        self.assertTrue(any(self.root.rglob("ci-classification.json")))

    def test_input_change_during_terminal_persistence_refuses(self):
        original = subject.persist

        def persist(path, packet):
            original(path, packet)
            if path.name == "ci-classification.json":
                with (self.inputs / "installed-vhd-acl-ancestry.c").open("ab") as stream:
                    stream.write(b"\n/* Changed at persistence. */\n")

        with mock.patch.object(subject, "persist", side_effect=persist):
            with self.assertRaises(ValueError):
                self.execute()
        self.assertTrue(any(self.root.rglob("ci-classification.json")))

    def test_unsupported_host_acquires_nothing(self):
        with mock.patch.object(subject.sys, "platform", "linux"):
            with self.assertRaises(ValueError):
                subject.run(self.root / "uncreated")
        self.assertFalse((self.root / "uncreated").exists())


class ClosedCLIControls(unittest.TestCase):
    def test_actual_cli_retains_only_bounded_ordinary_image_refusal(self):
        import subprocess
        import sys

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve(strict=True)
            runtime = root / "modeled-runtime-image"
            runtime.write_bytes(b"Actual refused file; never executed.\n")
            runtime.chmod(0o720)
            # Only the host declaration is modeled; the CLI and file guard execute.
            script = (
                "import runpy, sys; "
                "caller, parent, runtime = sys.argv[1:]; "
                "sys.argv = [caller, parent]; sys.executable = runtime; "
                "sys.platform = 'darwin'; runpy.run_path(caller, run_name='__main__')"
            )
            result = subprocess.run(
                [sys.executable, "-B", "-c", script, subject.__file__, str(root), str(runtime)],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Caller ordinary input owner refused: regular=True", result.stderr)
            self.assertIn("mode=0o100720", result.stderr)
            self.assertIn("source=False", result.stderr)
            self.assertNotIn(str(runtime), result.stderr)
            self.assertNotIn("Traceback", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(list(root.iterdir()), [runtime])

    def test_unrecognized_value_error_keeps_private_payload_out_of_cli(self):
        import ast
        import contextlib
        import io

        tree = ast.parse(Path(subject.__file__).read_bytes())
        main = tree.body[-1]
        captured = io.StringIO()
        namespace = dict(subject.__dict__)
        namespace.update(
            __name__="__main__", run=mock.Mock(side_effect=ValueError("PRIVATE_EXCEPTION_PAYLOAD"))
        )
        with mock.patch.object(subject.sys, "argv", [subject.__file__, "/owned"]):
            with contextlib.redirect_stderr(captured):
                with self.assertRaises(SystemExit) as caught:
                    exec(
                        compile(ast.Module(body=[main], type_ignores=[]), subject.__file__, "exec"),
                        namespace,
                    )
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(captured.getvalue(), "Read-only ACL caller refused; evidence retained\n")
        self.assertNotIn("PRIVATE_EXCEPTION_PAYLOAD", captured.getvalue())

    def test_native_wait_timeout_has_closed_cli_refusal(self):
        import ast
        import contextlib
        import io
        import subprocess

        tree = ast.parse(Path(subject.__file__).read_bytes())
        main = tree.body[-1]
        self.assertIsInstance(main, ast.If)
        original = subprocess.TimeoutExpired("PRIVATE_EXCEPTION_PAYLOAD", 25)
        captured = io.StringIO()
        namespace = dict(subject.__dict__)
        namespace.update(__name__="__main__", run=mock.Mock(side_effect=original))
        with mock.patch.object(subject.sys, "argv", [subject.__file__, "/owned"]):
            with contextlib.redirect_stderr(captured):
                with self.assertRaises(SystemExit) as caught:
                    exec(
                        compile(ast.Module(body=[main], type_ignores=[]), subject.__file__, "exec"),
                        namespace,
                    )
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(captured.getvalue(), "Read-only ACL caller refused; evidence retained\n")
        self.assertNotIn("PRIVATE_EXCEPTION_PAYLOAD", captured.getvalue())

    def test_cli_prints_the_same_frozen_value_error_text_it_validated(self):
        import ast
        import contextlib
        import io

        expected = (
            "Caller ordinary input owner refused: regular=True size=1 maximum=2 "
            "mode=0o100720 uid=1 euid=1 links=1 source=False"
        )

        class ChangingMessage:
            calls = 0

            def __str__(self):
                self.calls += 1
                return expected if self.calls == 1 else "PRIVATE_EXCEPTION_PAYLOAD"

        payload = ChangingMessage()
        tree = ast.parse(Path(subject.__file__).read_bytes())
        captured = io.StringIO()
        namespace = dict(subject.__dict__)
        namespace.update(__name__="__main__", run=mock.Mock(side_effect=ValueError(payload)))
        with mock.patch.object(subject.sys, "argv", [subject.__file__, "/owned"]):
            with contextlib.redirect_stderr(captured):
                with self.assertRaises(SystemExit) as caught:
                    exec(
                        compile(
                            ast.Module(body=[tree.body[-1]], type_ignores=[]),
                            subject.__file__,
                            "exec",
                        ),
                        namespace,
                    )
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(payload.calls, 1)
        self.assertEqual(
            captured.getvalue(),
            "Read-only ACL caller refused; evidence retained\n" + expected + "\n",
        )
        self.assertNotIn("PRIVATE_EXCEPTION_PAYLOAD", captured.getvalue())


if __name__ == "__main__":
    unittest.main()
