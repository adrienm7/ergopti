# tools/diagnostics/permission_ui_progress_test.py
"""Independent portable guards for first-seen UI facts; native UI is unexecuted."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SWIFT = (
    REPO
    / "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274PermissionDialogQualificationTests.swift"
)
PREFIX = "ERGOPTI_PERMISSION_UI_PROGRESS "
PUBLIC_PREFIX = "ERGOPTI_PERMISSION_UI_PROGRESS_DIAGNOSTIC "
NONCE = "1" * 32
VERSION = "1.1.1"


def controller():
    text = SWIFT.read_text(encoding="utf-8")
    body = text.split('private static let permissionDialogController = #"""\n', 1)[1].split(
        '\n\t"""#', 1
    )[0]
    code = "\n".join(line[1:] if line.startswith("\t") else line for line in body.splitlines())
    namespace = {"__name__": "independent_progress_control"}
    exec(compile(code, str(SWIFT), "exec"), namespace)
    return namespace


def owner_report():
    return {
        "status": "error",
        "operation_error": "Actual permission UI observation deadline",
        "cleanup_errors": [],
        "application_cleanup": "confirmed inherited PGID retired",
        "native_owner": {
            "worker_pid": 41,
            "group_id": 41,
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "escaped_sessions_managed": False,
        },
    }


def row(stage=1, busy=False, count=0, sequence=1):
    return {
        "schema": 1,
        "kind": "permission_ui_first_seen_progress",
        "authority": False,
        "native_verdict": "unchanged",
        "pid": 41,
        "nonce": NONCE,
        "version": VERSION,
        "sequence": sequence,
        "stage": stage,
        "busy": busy,
        "recorded_case_count": count,
    }


def line(value):
    return (PREFIX + json.dumps(value, separators=(",", ":"), allow_nan=False) + "\n").encode()


class PermissionProgressControls(unittest.TestCase):
    def setUp(self):
        self.code = controller()
        self.before = {"actual-held.lua": "a" * 64}
        self.report = owner_report()
        self.data = line(row()) + line(row(2, True, 2, 2))

    def observe(self, data=None, report=None, after=None):
        fn = self.code.get("progress_failure_observation")
        self.assertTrue(callable(fn), "original missing first-seen diagnostic cannot pass")
        return fn(
            self.data if data is None else data,
            self.report if report is None else report,
            41,
            NONCE,
            VERSION,
            self.before,
            self.before if after is None else after,
        )

    def unsupported(self, data=None, report=None, after=None):
        result = self.observe(data, report, after)
        self.assertEqual(result["status"], "unsupported")
        self.assertEqual(result["observations"], [])
        self.assertIsNone(result["last_entered_stage"])
        self.assertIs(result["authority"], False)
        self.assertEqual(result["native_verdict"], "unchanged")
        return result

    def test_exact_entered_stage_and_actual_prefix(self):
        value = self.observe()
        self.assertEqual(
            value,
            {
                "schema": 1,
                "kind": "permission_ui_first_seen_progress_observation",
                "authority": False,
                "native_verdict": "unchanged",
                "status": "observed",
                "coverage": "first_seen_only",
                "last_entered_stage": 2,
                "observations": [
                    {"stage": 1, "busy": False, "recorded_case_count": 0},
                    {"stage": 2, "busy": True, "recorded_case_count": 2},
                ],
            },
        )

    def test_output_omits_identity_and_raw_source(self):
        result = self.observe(b"PRIVATE_SOURCE_TEXT\n" + self.data)
        formatter = self.code.get("progress_diagnostic_line")
        self.assertTrue(callable(formatter))
        output = formatter(result)
        self.assertTrue(output.startswith(PUBLIC_PREFIX))
        for private in (
            NONCE,
            "PRIVATE_SOURCE_TEXT",
            "nonce",
            "version",
            "pid",
            "current",
            "terminal",
        ):
            self.assertNotIn(private, output)
        self.assertLessEqual(len(output.encode()), 8192)

    def test_absent_stream_is_unsupported(self):
        self.unsupported(b"")

    def test_missing_bytes_is_unsupported(self):
        fn = self.code.get("progress_failure_observation")
        self.assertTrue(callable(fn))
        result = fn(None, self.report, 41, NONCE, VERSION, self.before, self.before)
        self.assertEqual(result["status"], "unsupported")

    def test_invalid_utf8_is_unsupported(self):
        self.unsupported(b"\xff" + self.data)

    def test_unknown_stage_is_unsupported(self):
        self.unsupported(line(row(6.5, False, 4)))

    def test_boolean_stage_is_unsupported(self):
        self.unsupported(line(row(True)))

    def test_float_integer_stage_is_unsupported(self):
        self.unsupported(line(row(1.0)))

    def test_nonboolean_busy_is_unsupported(self):
        self.unsupported(line(row(busy=1)))

    def test_noninteger_count_is_unsupported(self):
        self.unsupported(line(row(count=False)))

    def test_prefix_inconsistent_with_stage_is_unsupported(self):
        self.unsupported(line(row(1, False, 2)))

    def test_foreign_pid_is_unsupported(self):
        value = row()
        value["pid"] = 42
        self.unsupported(line(value))

    def test_foreign_nonce_is_unsupported(self):
        value = row()
        value["nonce"] = "2" * 32
        self.unsupported(line(value))

    def test_foreign_version_is_unsupported(self):
        value = row()
        value["version"] = "PRIVATE_SECRET"
        self.unsupported(line(value))

    def test_unknown_field_is_unsupported_without_leak(self):
        value = row()
        value["PRIVATE_SECRET"] = "private source"
        self.unsupported(line(value))

    def test_duplicate_field_is_unsupported(self):
        self.unsupported(line(row()).replace(b'"schema":1', b'"schema":1,"schema":1'))

    def test_unknown_kind_is_unsupported(self):
        value = row()
        value["kind"] = "PRIVATE_SECRET"
        self.unsupported(line(value))

    def test_authority_cannot_be_granted(self):
        value = row()
        value["authority"] = True
        self.unsupported(line(value))

    def test_missing_newline_is_unsupported(self):
        self.unsupported(self.data[:-1])

    def test_sequence_gap_is_unsupported(self):
        self.unsupported(line(row(sequence=2)))

    def test_repeated_tuple_is_unsupported(self):
        self.unsupported(line(row()) + line(row(sequence=2)))

    def test_regressed_stage_is_unsupported(self):
        self.unsupported(line(row(2, True, 2)) + line(row(1, False, 0, 2)))

    def test_unretired_owner_is_unsupported(self):
        self.report["native_owner"]["closed"] = False
        self.unsupported()

    def test_foreign_owner_is_unsupported(self):
        self.report["native_owner"]["worker_pid"] = 42
        self.unsupported()

    def test_cleanup_debt_is_unsupported(self):
        self.report["cleanup_errors"] = ["PRIVATE_SECRET"]
        self.unsupported()

    def test_changed_sources_is_unsupported(self):
        self.unsupported(after={"actual-held.lua": "b" * 64})

    def test_other_controller_reason_is_unsupported(self):
        self.report["operation_error"] = "Exact native child exited before receipt"
        self.unsupported()

    def test_native_packet_does_not_become_missing_packet_observation(self):
        self.report["native_result"] = {}
        self.unsupported()

    def test_oversized_stream_is_unsupported(self):
        self.unsupported(b"x" * 65537 + self.data)

    def test_embedded_prefix_is_unsupported(self):
        self.unsupported(b"foreign " + self.data)

    def test_nan_is_unsupported(self):
        self.unsupported(line(row()).replace(b'"stage":1', b'"stage":NaN'))

    def test_line_bound_is_enforced(self):
        self.unsupported(line(row())[:-1] + b" " * 513 + b"\n")

    def test_row_count_bound_is_enforced(self):
        self.unsupported(line(row()) * 31)

    def read(self, path):
        fn = self.code.get("read_progress_failure_observation")
        self.assertTrue(callable(fn), "original missing after-retirement reader cannot pass")
        return fn(path, self.report, 41, NONCE, VERSION, self.before, self.before)

    def test_actual_owned_regular_capture_is_read_after_retirement(self):
        with tempfile.TemporaryDirectory(prefix="permission-progress-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(self.data)
            p.chmod(0o600)
            self.assertEqual(self.read(p), self.observe())

    def test_actual_redirected_capture_is_unsupported(self):
        with tempfile.TemporaryDirectory(prefix="permission-progress-") as d:
            p = Path(d) / "private"
            p.write_bytes(self.data)
            link = Path(d) / "launch.stderr"
            link.symlink_to(p)
            self.assertEqual(self.read(link)["status"], "unsupported")

    def test_actual_hardlinked_capture_is_unsupported(self):
        import os

        with tempfile.TemporaryDirectory(prefix="permission-progress-") as d:
            p = Path(d) / "private"
            p.write_bytes(self.data)
            p.chmod(0o600)
            link = Path(d) / "launch.stderr"
            os.link(p, link)
            self.assertEqual(self.read(link)["status"], "unsupported")

    def test_actual_oversized_capture_is_unsupported(self):
        with tempfile.TemporaryDirectory(prefix="permission-progress-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(b"x" * 65537)
            p.chmod(0o600)
            self.assertEqual(self.read(p)["status"], "unsupported")

    def test_retirement_guard_precedes_any_file_read(self):
        self.report["native_owner"]["closed"] = False
        with tempfile.TemporaryDirectory(prefix="permission-progress-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(self.data)
            p.chmod(0o600)
            with patch(
                "os.open", side_effect=AssertionError("foreign file must not be read")
            ) as opened:
                self.assertEqual(self.read(p)["status"], "unsupported")
                opened.assert_not_called()


class ProgressReaderAndReceiptBoundaryControls(unittest.TestCase):
    def setUp(self):
        self.case = PermissionProgressControls("test_exact_entered_stage_and_actual_prefix")
        self.case.setUp()

    def test_actual_fifo_refuses_without_blocking(self):
        import os
        import subprocess
        import sys

        with tempfile.TemporaryDirectory(prefix="permission-progress-fifo-") as d:
            p = Path(d) / "launch.stderr"
            os.mkfifo(p, 0o600)
            script = (
                "import importlib.util;from pathlib import Path;"
                f"s=importlib.util.spec_from_file_location('held_controls',{str(Path(__file__))!r});"
                "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
                "c=m.PermissionProgressControls('test_exact_entered_stage_and_actual_prefix');c.setUp();"
                f"print(c.read(Path({str(p)!r}))['status'],flush=True)"
            )
            try:
                receipt = subprocess.run(
                    [sys.executable, "-B", "-c", script],
                    capture_output=True,
                    timeout=0.75,
                )
            except subprocess.TimeoutExpired:
                self.fail(
                    "Ordinary FIFO admission blocked before type refusal; child killed and reaped"
                )
            self.assertEqual(receipt.returncode, 0)
            self.assertEqual(receipt.stdout, b"unsupported\n")
            self.assertEqual(receipt.stderr, b"")

    def test_actual_atime_only_read_is_healthy(self):
        import os

        with tempfile.TemporaryDirectory(prefix="permission-progress-atime-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(self.case.data)
            p.chmod(0o600)
            os.utime(p, ns=(1000000000, p.stat().st_mtime_ns))
            before = p.stat()
            result = self.case.read(p)
            after = p.stat()
            self.assertNotEqual(before.st_atime_ns, after.st_atime_ns)
            self.assertEqual(before.st_mtime_ns, after.st_mtime_ns)
            self.assertEqual(before.st_ctime_ns, after.st_ctime_ns)
            self.assertEqual(p.read_bytes(), self.case.data)
            self.assertEqual(result, self.case.observe())

    def changed_while_held_read(self, mutation):
        import os

        with tempfile.TemporaryDirectory(prefix="permission-progress-held-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(self.case.data)
            p.chmod(0o600)
            original = os.fdopen

            class HeldStream:
                def __init__(self, stream):
                    self.stream = stream

                def __enter__(self):
                    self.stream.__enter__()
                    return self

                def __exit__(self, *args):
                    return self.stream.__exit__(*args)

                def fileno(self):
                    return self.stream.fileno()

                def read(self, count):
                    data = self.stream.read(count)
                    mutation(p)
                    return data

            with patch("os.fdopen", side_effect=lambda *args: HeldStream(original(*args))):
                result = self.case.read(p)
            self.assertEqual(result["status"], "unsupported")
            self.assertEqual(result["observations"], [])

    def test_actual_content_change_during_held_read_refuses(self):
        self.changed_while_held_read(lambda p: p.write_bytes(b"x" * len(self.case.data)))

    def test_actual_mode_change_during_held_read_refuses(self):
        self.changed_while_held_read(lambda p: p.chmod(0o640))

    def test_changed_held_identity_custody_fields_refuse(self):
        import os
        from types import SimpleNamespace

        fields = (
            "st_dev",
            "st_ino",
            "st_uid",
            "st_gid",
            "st_nlink",
            "st_mode",
            "st_size",
            "st_mtime_ns",
            "st_ctime_ns",
        )
        with tempfile.TemporaryDirectory(prefix="permission-progress-custody-") as d:
            p = Path(d) / "launch.stderr"
            p.write_bytes(self.case.data)
            p.chmod(0o600)
            original = os.fstat
            for field in fields:
                with self.subTest(field=field):
                    calls = 0

                    def held_stat(fd):
                        nonlocal calls
                        actual = original(fd)
                        calls += 1
                        if calls == 1:
                            return actual
                        values = {name: getattr(actual, name) for name in fields}
                        values["st_atime_ns"] = actual.st_atime_ns
                        values[field] += 1
                        return SimpleNamespace(**values)

                    with patch("os.fstat", side_effect=held_stat):
                        result = self.case.read(p)
                    self.assertEqual(result["status"], "unsupported")
                    self.assertEqual(result["observations"], [])

    def test_swift_wrapper_requires_complete_receipt(self):
        import re

        text = SWIFT.read_text(encoding="utf-8")
        method = text.split("func testPortablePermissionUiFirstSeenProgress", 1)[1].split(
            "\n\tprivate static", 1
        )[0]

        def admitted(stderr, status=0, stdout=""):
            if 'contains("\\nRan 38 tests in ")' in method:
                return (
                    status == 0
                    and stdout == ""
                    and "\nRan 38 tests in " in stderr
                    and stderr.endswith("\nOK\n")
                    and "skipped" not in stderr
                )
            pattern = re.search(r'let complete = #"([\s\S]*?)"#', method)
            self.assertIsNotNone(pattern, "Actual Swift complete-receipt predicate missing")
            return (
                status == 0
                and stdout == ""
                and re.fullmatch(pattern[1].replace(r"\z", r"\Z"), stderr) is not None
            )

        old = "." * 38 + "\n" + "-" * 70 + "\nRan 38 tests in 0.001s\n\nOK\n"
        for bad in ["PRIVATE_PREFIX\n" + old, old[:-3] + "PRIVATE_SUFFIX\nOK\n"]:
            self.assertFalse(admitted(bad))
        healthy = "." * 44 + "\n" + "-" * 70 + "\nRan 44 tests in 0.001s\n\nOK\n"
        self.assertTrue(admitted(healthy))
        for bad in [
            "",
            "PRIVATE_PREFIX\n" + healthy,
            healthy + "PRIVATE_SUFFIX\n",
            healthy[:-3] + "PRIVATE_SUFFIX\nOK\n",
            healthy.replace("Ran 44", "Ran 0"),
            healthy.replace("Ran 44", "Ran 43"),
            healthy.replace("OK\n", "OK (skipped=1)\n"),
            healthy.replace("0.001s", "-1.001s"),
            healthy.replace("0.001s", "NaNs"),
            healthy.replace("0.001s", "0.001s PRIVATE"),
            healthy.replace(".", "s", 1),
        ]:
            with self.subTest(receipt=bad):
                self.assertFalse(admitted(bad))
        self.assertFalse(admitted(healthy, status=1))
        self.assertFalse(admitted(healthy, stdout="PRIVATE_STDOUT"))


if __name__ == "__main__":
    unittest.main()
