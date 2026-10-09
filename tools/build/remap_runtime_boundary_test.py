"""Independent literal boundary evidence policy. Native compilation is unexecuted."""

import errno
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "tools/build/remap_runtime_build.py"
spec = importlib.util.spec_from_file_location("actual_boundary_subject", BUILDER)
B = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = B
exec(compile(BUILDER.read_bytes(), str(BUILDER), "exec"), B.__dict__)


class IndependentBoundaryControls(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name).resolve()
        self.owner = self.base / "owner"
        self.owner.mkdir(mode=0o700)
        self.path = self.owner / "owned-compilation-boundaries.jsonl"

    def rows(self):
        data = self.path.read_bytes()
        self.assertLessEqual(len(data), 131072)
        rows = [json.loads(line) for line in data.splitlines()]
        self.assertLessEqual(len(rows), 512)
        fields = {
            "schema",
            "seq",
            "event",
            "span",
            "parent",
            "stage",
            "phase",
            "mono_ns",
            "elapsed_ns",
            "sync_ns",
            "code",
        }
        for index, row in enumerate(rows, 1):
            self.assertEqual(set(row), fields)
            self.assertEqual(row["seq"], index)
            self.assertEqual(row["schema"], 1)
            for key in ("span", "parent", "mono_ns", "elapsed_ns", "sync_ns"):
                self.assertIs(type(row[key]), int)
                self.assertGreaterEqual(row[key], 0)
                self.assertLess(row[key], 10**20)
        self.assertNotIn(b"SECRET", data)
        self.assertNotIn(str(self.base).encode(), data)
        self.assertNotIn(b"qualified", data)
        return rows

    def test_ordered_entry_completion_and_exact_private_mode(self):
        with B._observe_compilation(self.owner):
            with B._observe_span("inputs"):
                pass
        rows = self.rows()
        self.assertEqual(
            [r["event"] for r in rows], ["writer_start", "enter", "complete", "writer_end"]
        )
        self.assertEqual(
            [r["stage"] for r in rows], ["compilation", "inputs", "inputs", "compilation"]
        )
        self.assertEqual([r["span"] for r in rows], [0, 1, 1, 0])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)

    def test_nested_parent_and_completion_order(self):
        with B._observe_compilation(self.owner):
            with B._observe_span("inputs"):
                with B._observe_span("products"):
                    pass
        rows = self.rows()[1:-1]
        self.assertEqual(
            [(r["event"], r["span"], r["parent"]) for r in rows],
            [("enter", 1, 0), ("enter", 2, 1), ("complete", 2, 1), ("complete", 1, 0)],
        )

    def test_unentered_native_and_source_stages_not_claimed(self):
        with B._observe_compilation(self.owner):
            with B._observe_span("inputs"):
                pass
        self.assertNotIn("native_dispatch", [r["stage"] for r in self.rows()])
        self.assertNotIn("source_prepare", [r["stage"] for r in self.rows()])

    def test_actual_interruption_retains_entry_without_completion(self):
        program = "import importlib.util,sys,os\nfrom pathlib import Path\np=Path(sys.argv[1]);s=importlib.util.spec_from_file_location('interrupted_actual',p);B=importlib.util.module_from_spec(s);sys.modules[s.name]=B;exec(compile(p.read_bytes(),str(p),'exec'),B.__dict__)\nwith B._observe_compilation(Path(sys.argv[2])):\n with B._observe_span('inputs'):\n  os._exit(17)\n"
        result = subprocess.run(
            [sys.executable, "-c", program, str(BUILDER), str(self.owner)],
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 17, result.stderr.decode())
        self.assertEqual([r["event"] for r in self.rows()], ["writer_start", "enter"])

    def test_native_error_object_rethrown_and_closed_code(self):
        error = B.BASE.NativeBuildError("phase_failed", "SECRET native arguments and stderr")
        with self.assertRaises(B.BASE.NativeBuildError) as caught:
            with B._observe_compilation(self.owner):
                with B._observe_span("native_dispatch", "core_build"):
                    raise error
        self.assertIs(caught.exception, error)
        refused = [r for r in self.rows() if r["event"] == "refused"]
        self.assertEqual(
            [(r["stage"], r["phase"], r["code"]) for r in refused],
            [("native_dispatch", "core_build", "phase_failed")],
        )
        self.assertNotIn("complete", [r["event"] for r in self.rows()])

    def test_unknown_exception_payload_never_exported(self):
        error = RuntimeError("SECRET /private native exception")
        with self.assertRaises(RuntimeError) as caught:
            with B._observe_compilation(self.owner):
                with B._observe_span("inputs"):
                    raise error
        self.assertIs(caught.exception, error)
        self.assertEqual(
            [r["code"] for r in self.rows() if r["event"] == "refused"], ["unexpected"]
        )

    def test_unknown_native_code_payload_never_exported(self):
        with self.assertRaises(B.BASE.NativeBuildError):
            with B._observe_compilation(self.owner):
                with B._observe_span("inputs"):
                    raise B.BASE.NativeBuildError("SECRET raw native code", "SECRET stderr")
        self.assertEqual(
            [r["code"] for r in self.rows() if r["event"] == "refused"], ["other_refusal"]
        )

    def test_overflow_one_marker_and_original_operations_continue(self):
        entered = 0
        with B._observe_compilation(self.owner):
            for _ in range(600):
                with B._observe_span("inputs"):
                    entered += 1
        rows = self.rows()
        self.assertEqual(entered, 600)
        self.assertEqual(sum(r["event"] == "overflow" for r in rows), 1)
        self.assertEqual(rows[-1]["event"], "overflow")
        self.assertEqual(rows[-1]["code"], "limit")
        self.assertNotIn("writer_end", [r["event"] for r in rows])

    def test_existing_file_collision_preserves_foreign_bytes(self):
        self.path.write_bytes(b"FOREIGN marker")
        before = self.path.stat()
        entered = False
        with B._observe_compilation(self.owner):
            entered = True
        self.assertTrue(entered)
        self.assertEqual(self.path.read_bytes(), b"FOREIGN marker")
        self.assertEqual(self.path.stat().st_ino, before.st_ino)

    def test_unknown_stage_refused_before_operation(self):
        entered = False
        with self.assertRaises(ValueError):
            with B._observe_compilation(self.owner):
                with B._observe_span("SECRET raw stage"):
                    entered = True
        self.assertFalse(entered)
        self.rows()

    def test_unknown_native_phase_collapsed_without_changing_dispatch(self):
        marker = object()
        deadline = object()
        args = ["SECRET executable", "SECRET argument"]
        calls = []

        def native(name, actual_args, cwd, owner, actual_deadline):
            calls.append((name, actual_args, cwd, owner, actual_deadline))
            return marker

        with patch.object(B, "_RUN_PHASE", native), B._observe_compilation(self.owner):
            actual = B._observed_run_phase(
                "SECRET raw phase", args, self.owner, self.owner, deadline
            )
        self.assertIs(actual, marker)
        self.assertEqual(len(calls), 1)
        self.assertIs(calls[0][1], args)
        self.assertIs(calls[0][4], deadline)
        self.assertEqual(
            [r["phase"] for r in self.rows() if r["stage"] == "native_dispatch"],
            ["unclassified", "unclassified"],
        )

    def test_replaced_journal_no_foreign_write_and_original_operation_runs(self):
        ran = False
        with B._observe_compilation(self.owner):
            self.path.unlink()
            self.path.write_bytes(b"FOREIGN replacement")
            with B._observe_span("inputs"):
                ran = True
        self.assertTrue(ran)
        self.assertEqual(self.path.read_bytes(), b"FOREIGN replacement")

    def test_replaced_owner_no_foreign_write_and_original_operation_runs(self):
        ran = False
        with B._observe_compilation(self.owner):
            saved = self.base / "saved"
            self.owner.rename(saved)
            self.owner.mkdir(mode=0o700)
            with B._observe_span("inputs"):
                ran = True
        self.assertTrue(ran)
        self.assertFalse(self.path.exists())
        self.assertEqual(
            [json.loads(x)["event"] for x in (saved / self.path.name).read_bytes().splitlines()],
            ["writer_start"],
        )

    def test_retired_scope_no_later_observation(self):
        with B._observe_compilation(self.owner):
            pass
        before = self.path.read_bytes()
        with B._observe_span("inputs"):
            pass
        self.assertEqual(self.path.read_bytes(), before)

    def test_diagnostic_clock_never_reads_or_renews_original_deadline_clock(self):
        with patch.object(
            B.time, "monotonic", side_effect=AssertionError("Original deadline clock read")
        ):
            with B._observe_compilation(self.owner):
                with B._observe_span("inputs"):
                    pass
        self.rows()

    def test_nonfinite_diagnostic_clock_does_not_claim_completion_or_change_operation(self):
        entered = False
        with patch.object(B.time, "perf_counter_ns", return_value=float("nan")):
            with B._observe_compilation(self.owner):
                with B._observe_span("inputs"):
                    entered = True
        self.assertTrue(entered)
        if self.path.exists():
            self.assertEqual(self.path.read_bytes(), b"")

    def test_real_current_input_refusal_keeps_original_check_and_named_stage(self):
        source = self.base / "source"
        source.mkdir(mode=0o700)
        leaf = source / "leaf"
        leaf.write_bytes(b"ORIGINAL")
        held = B._ordinary(leaf, source, 4096)
        snapshot = B.InputSnapshot(source, B._directory_identity(source.stat()), (held,))
        leaf.write_bytes(b"CHANGED")
        with self.assertRaises(B.BASE.NativeBuildError) as caught:
            with B._observe_compilation(self.owner):
                B.current_inputs(snapshot, time.monotonic() + 30)
        self.assertEqual(caught.exception.code, "source_identity")
        self.assertEqual(
            [(r["stage"], r["code"]) for r in self.rows() if r["event"] == "refused"],
            [("inputs", "source_identity")],
        )

    def test_close_failure_debt_never_masks_original_error(self):
        error = RuntimeError("SECRET original operation")
        journal = None
        with patch.object(B.os, "close", side_effect=OSError("SECRET close failure")):
            with self.assertRaises(RuntimeError) as caught:
                with B._observe_compilation(self.owner) as journal:
                    with B._observe_span("inputs"):
                        raise error
        self.assertIs(caught.exception, error)
        self.assertTrue(journal.close_debt)
        # Release only the exact retained private descriptor after restoring close.
        os.close(journal.descriptor)
        self.rows()


class IndependentStartupCloseControl(unittest.TestCase):
    def test_new_descriptor_closed_after_each_prepublication_attribute_failure(self):
        for cut in ("set_inheritable", "fchmod"):
            with self.subTest(cut=cut), tempfile.TemporaryDirectory() as directory:
                owner = Path(directory).resolve()
                opened = []
                entered = []

                def fail(fd, *args):
                    opened.append(fd)
                    raise OSError("SECRET injected startup attribute failure")

                with patch.object(B.os, cut, fail):
                    with B._observe_compilation(owner):
                        entered.append(True)
                self.assertEqual(entered, [True])
                self.assertEqual(len(opened), 1)
                with self.assertRaises(OSError):
                    os.fstat(opened[0])
                self.assertEqual((owner / "owned-compilation-boundaries.jsonl").read_bytes(), b"")


class IndependentUnknownStartupDebtControl(unittest.TestCase):
    def test_unavailable_initial_descriptor_observation_keeps_private_debt_and_original_error(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = Path(directory).resolve()
            real_fstat = os.fstat
            calls = []

            def missing_first(fd):
                calls.append(fd)
                if len(calls) == 1:
                    raise OSError("SECRET unavailable first descriptor observation")
                return real_fstat(fd)

            original = RuntimeError("SECRET original operation")
            journal = None
            with patch.object(B.os, "fstat", missing_first):
                with self.assertRaises(RuntimeError) as caught:
                    with B._observe_compilation(owner) as journal:
                        raise original
            self.assertIs(caught.exception, original)
            self.assertTrue(journal.close_debt)
            self.assertTrue(journal.disabled)
            self.assertEqual((owner / "owned-compilation-boundaries.jsonl").read_bytes(), b"")
            # Test knows the real exclusive-open descriptor; release it outside the fault port.
            os.close(journal.descriptor)


class IndependentSyncFenceControl(unittest.TestCase):
    def test_real_sync_fences_precede_operation_and_measured_prefix_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            owner = Path(directory).resolve()
            calls = []
            real_sync = os.fsync

            def sync(fd):
                calls.append(fd)
                return real_sync(fd)

            with patch.object(B.os, "fsync", sync):
                with B._observe_compilation(owner):
                    with B._observe_span("inputs"):
                        self.assertGreaterEqual(len(calls), 2)
                self.assertGreaterEqual(len(calls), 4)
                self.assertLessEqual(len(calls), 512)
            rows = [
                json.loads(x)
                for x in (owner / "owned-compilation-boundaries.jsonl").read_bytes().splitlines()
            ]
            self.assertGreater(rows[-1]["sync_ns"], 0)
            self.assertEqual([r["sync_ns"] for r in rows], sorted(r["sync_ns"] for r in rows))


class SameInodeCloseControl(unittest.TestCase):
    def test_late_close_error_cannot_close_a_reused_same_inode_descriptor(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = B._BoundaryJournal(Path(directory).resolve())
            original_fd = journal.descriptor
            original_stat = os.fstat(original_fd)
            real_close = os.close
            foreign = []
            calls = []

            def late_error(fd):
                calls.append(fd)
                if len(calls) == 1:
                    real_close(fd)
                    borrowed = os.open(journal.path, os.O_RDWR | os.O_NOFOLLOW)
                    foreign.append(borrowed)
                    self.assertEqual(
                        borrowed, original_fd, "Actual lowest-free descriptor must be reused"
                    )
                    actual = os.fstat(borrowed)
                    self.assertEqual(
                        (actual.st_dev, actual.st_ino, actual.st_uid),
                        (original_stat.st_dev, original_stat.st_ino, original_stat.st_uid),
                    )
                    raise OSError(
                        errno.EIO, "MODELED late close error after real descriptor release"
                    )
                real_close(fd)

            try:
                with patch.object(B.os, "close", late_error):
                    journal.close()
                try:
                    os.fstat(foreign[0])
                    foreign_alive = True
                except OSError:
                    foreign_alive = False
                observed = {
                    "close_attempts": len(calls),
                    "foreign_same_inode_fd_alive": foreign_alive,
                    "private_close_debt": journal.close_debt,
                    "native_error_delivery": "MODELED",
                    "underlying_close_open_fstat": "REAL_LINUX",
                }
                print(json.dumps(observed, sort_keys=True), flush=True)
                self.assertEqual((len(calls), foreign_alive, journal.close_debt), (1, True, True))
            finally:
                for fd in foreign:
                    try:
                        real_close(fd)
                    except OSError:
                        pass


def concurrent_boundary_control_suite():
    """Independent coordinator tokens; native process endpoints unexecuted."""

    class ConcurrentBoundaryControls(unittest.TestCase):
        def setUp(self):
            self.case = IndependentBoundaryControls(methodName="runTest")
            self.case.setUp()
            self.addCleanup(self.case.doCleanups)

        def test_overlapping_tokens_are_siblings_not_stack_parents(self):
            with B._observe_compilation(self.case.owner) as journal:
                core = B._begin_dispatch_span("core_build")
                console = B._begin_dispatch_span("console_build")
                self.assertEqual(journal.stack, [])
                with B._observe_span("inputs"):
                    pass
                B._finish_dispatch_span(console)
                B._finish_dispatch_span(core)
            rows = self.case.rows()
            entered = [r for r in rows if r["event"] == "enter"]
            self.assertEqual([r["parent"] for r in entered], [0, 0, 0])
            complete = [r for r in rows if r["event"] == "complete"]
            self.assertEqual([r["span"] for r in complete], [3, 2, 1])

        def test_duplicate_finish_is_refused_without_second_completion(self):
            with B._observe_compilation(self.case.owner):
                token = B._begin_dispatch_span("core_build")
                B._finish_dispatch_span(token)
                with self.assertRaises(ValueError):
                    B._finish_dispatch_span(token)
            self.assertEqual(sum(r["event"] == "complete" for r in self.case.rows()), 1)

        def test_refusal_closes_only_its_token_without_payload(self):
            with B._observe_compilation(self.case.owner):
                token = B._begin_dispatch_span("core_build")
                error = B.BASE.NativeBuildError("phase_failed", "SECRET foreign native details")
                B._finish_dispatch_span(token, error)
            refused = [r for r in self.case.rows() if r["event"] == "refused"]
            self.assertEqual(
                [(r["phase"], r["code"]) for r in refused], [("core_build", "phase_failed")]
            )

    return unittest.defaultTestLoader.loadTestsFromTestCase(ConcurrentBoundaryControls)


if __name__ == "__main__":
    concurrent_result = unittest.TextTestRunner(verbosity=2).run(
        concurrent_boundary_control_suite()
    )
    print(
        "PARALLEL CONTROLS tests="
        + str(concurrent_result.testsRun)
        + " failures="
        + str(len(concurrent_result.failures))
        + " errors="
        + str(len(concurrent_result.errors))
        + " skipped="
        + str(len(concurrent_result.skipped))
        + " native=unexecuted",
        file=sys.stderr,
    )
    if not (
        concurrent_result.wasSuccessful()
        and concurrent_result.testsRun == 3
        and not concurrent_result.skipped
    ):
        raise SystemExit(1)

if __name__ == "__main__":
    unittest.main()
