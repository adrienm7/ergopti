"""Passive owned-command controls, using actual isolated POSIX children.

Native wait/retirement is explicitly modeled; no Darwin/native clock credit.
No original owning test class or method is rewritten by this additive module.
"""

import importlib.util
import io
import contextlib
from pathlib import Path
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


OWNING = load("passive_owning_ports", "tools/test/macos_native_http_receiving_facts_test.py")
WIRE = OWNING.WIRE
CLIENT = load(
    "passive_actual_client",
    "static/ergopti_plus/macos/tests/support/native_http_wire_client_receiving.py",
)


class PassivePorts(OWNING.NativeCommandGuardProtocolModel):
    def acquire_owned(self, *args, **kwargs):
        owner = super().acquire_owned(*args, **kwargs)
        self.receipt_calls = getattr(self, "receipt_calls", 0)

        def receipt():
            self.receipt_calls += 1
            return {
                "worker_pid": owner.process.pid,
                "group_id": owner.process.pid,
                "closed": owner.reaped,
                "reservation_lost": False,
                "signals": [],
                "live_group_members": [],
                "escaped_sessions_managed": False,
            }

        owner.receipt = receipt
        return owner


class PassiveCommandControls(unittest.TestCase):
    def setUp(self):
        self.fixture = WIRE.WireFixture(native=False)
        self.ports = PassivePorts()
        self.fixture.native = True
        self.fixture.groups = self.ports
        self.fixture.native_groups = object()
        self.records = []
        self.output = io.StringIO()
        self.redirect = contextlib.redirect_stderr(self.output)
        self.redirect.__enter__()

    def tearDown(self):
        # Exact acquired handles only: no retry of modeled settlement, no PID lookup.
        try:
            for owner in self.ports.children:
                if owner.process.poll() is None:
                    owner.process.kill()
                owner.process.wait(timeout=5)
                for stream in (
                    owner.process.stdin,
                    owner.process.output_capture,
                    owner.process.error_capture,
                ):
                    if not stream.closed:
                        stream.close()
            self.fixture.native = False
            self.fixture.command_group_debt.clear()
            self.fixture.command_file_debt.clear()
            self.fixture.close()
        finally:
            self.redirect.__exit__(None, None, None)

    def command(self, sink=None):
        return self.fixture._command(
            ["EXPLICIT modeled compiler"],
            passive_receiving=self.records.append if sink is None else sink,
        )

    def test_closed_same_owner_observation_keeps_original_result_and_single_settlement(self):
        self.assertEqual(self.command(), (0, b""))
        self.assertEqual(len(self.records), 1)
        owner = self.ports.children[0]
        self.assertEqual(owner.settle_calls, 1)
        self.assertEqual(self.records[0]["owner"]["worker_pid"], owner.process.pid)
        self.assertEqual(self.ports.receipt_calls, 1)
        self.assertTrue(owner.process.stdin.closed)
        self.assertTrue(owner.process.output_capture.closed)
        self.assertTrue(owner.process.error_capture.closed)
        self.assertEqual(self.fixture.command_fact, {"phase": "complete", "status": 0})

    def test_absent_observer_acquires_no_receipt_or_optional_export(self):
        self.assertEqual(self.fixture._command(["EXPLICIT modeled compiler"]), (0, b""))
        self.assertEqual(getattr(self.ports, "receipt_calls", 0), 0)
        self.assertEqual(self.records, [])

    def test_false_ack_never_exports_or_retries_settlement(self):
        self.ports.ack = False
        with self.assertRaises(Exception):
            self.command()
        self.assertEqual(self.records, [])
        self.assertEqual(self.ports.children[0].settle_calls, 1)
        self.assertIs(self.fixture.command_group_debt[0], self.ports.children[0])

    def test_truthy_nonliteral_ack_never_exports(self):
        self.ports.ack = 1
        with self.assertRaises(WIRE.FixtureFailure):
            self.command()
        self.assertEqual(self.records, [])
        self.assertEqual(self.ports.children[0].settle_calls, 1)

    def test_uncertain_original_capture_closure_never_exports(self):
        self.ports.uncertain_capture = True
        with self.assertRaises(OSError):
            self.command()
        self.assertEqual(self.records, [])
        self.assertTrue(self.fixture.command_file_debt)
        self.assertEqual(self.ports.children[0].settle_calls, 1)

    def test_preexisting_group_debt_denies_new_child_and_export(self):
        debt = object()
        self.fixture.command_group_debt.append(debt)
        with self.assertRaises(WIRE.FixtureFailure):
            self.command()
        self.assertEqual(self.ports.children, [])
        self.assertEqual(self.records, [])
        self.assertIs(self.fixture.command_group_debt[0], debt)

    def test_technical_sink_refusal_preserves_success(self):
        for error in (OSError("EXPLICIT sink refusal"), WIRE.FixtureFailure("EXPLICIT technical")):
            with self.subTest(kind=type(error).__name__):
                with mock.patch.object(self, "sink", create=True, side_effect=error) as sink:
                    self.assertEqual(self.command(sink), (0, b""))
                    self.assertEqual(sink.call_count, 1)

    def test_original_primary_remains_authoritative_when_callback_is_cancelled(self):
        # Nonzero exit is real in the modeled owned child, not a synthesized fact.
        self.ports.exit_status = 3

        def cancelled(_):
            raise KeyboardInterrupt("EXPLICIT after original failure")

        with self.assertRaises(WIRE.FixtureFailure) as primary:
            self.fixture._command(
                ["EXPLICIT modeled failing command"],
                passive_receiving=cancelled,
            )
        self.assertEqual(str(primary.exception), "Native fixture command refused")
        self.assertEqual(self.fixture.command_fact, {"phase": "exit", "status": 3})

    def test_actual_fixture_signal_handlers_preserve_fresh_cancellation(self):
        handlers = OWNING.native_guard_actual_main_handlers()
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):

                def cancelled(_):
                    handlers[signum](signum, None)

                with self.assertRaisesRegex(WIRE.FixtureFailure, "^Native fixture cancelled$"):
                    self.command(cancelled)
                self.assertEqual(self.ports.children[-1].settle_calls, 1)
                self.assertEqual(self.fixture.command_group_debt, [])

    def test_keyboard_interrupt_and_system_exit_preserve_control_plane(self):
        for error in (KeyboardInterrupt(), SystemExit(4)):
            with self.subTest(kind=type(error).__name__):

                def cancelled(_):
                    raise error

                with self.assertRaises(type(error)):
                    self.command(cancelled)
                self.assertEqual(self.ports.children[-1].settle_calls, 1)


class PassiveExportControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ergopti-clock-passive-")
        self.addCleanup(self.temporary.cleanup)
        self.parent = Path(self.temporary.name).resolve()
        self.sink = CLIENT.NativeClockEvidence(self.parent / "evidence")

    def loader_context(self, cache):
        flags = SimpleNamespace(isolated=1, ignore_environment=1, no_user_site=1, safe_path=True)
        return mock.patch.multiple(
            CLIENT.sys, flags=flags, dont_write_bytecode=True, pycache_prefix=str(cache)
        )

    def test_explicit_private_cache_receives_actual_directory_identity(self):
        cache = self.parent / "private-cache"
        cache.mkdir(mode=0o700)
        with self.loader_context(cache):
            received = CLIENT.native_clock_python_loader(cache)
        identity = cache.lstat()
        self.assertEqual(received["cache_device"], identity.st_dev)
        self.assertEqual(received["cache_inode"], identity.st_ino)
        self.assertTrue(received["cache_empty"])

    def test_nonempty_private_prefix_never_claims_uncached_execution(self):
        cache = self.parent / "private-cache"
        cache.mkdir(mode=0o700)
        (cache / "retained.pyc").write_bytes(b"EXPLICIT old bytecode")
        with self.loader_context(cache):
            with self.assertRaises(CLIENT.NativeClockRefused):
                CLIENT.native_clock_python_loader(cache)
        self.assertEqual((cache / "retained.pyc").read_bytes(), b"EXPLICIT old bytecode")

    def test_default_loader_or_other_prefix_stays_unqualified(self):
        cache = self.parent / "private-cache"
        cache.mkdir(mode=0o700)
        with self.loader_context(cache):
            with mock.patch.object(CLIENT.sys.flags, "isolated", 0):
                with self.assertRaises(CLIENT.NativeClockRefused):
                    CLIENT.native_clock_python_loader(cache)
            with mock.patch.object(CLIENT.sys, "pycache_prefix", str(self.parent / "other")):
                with self.assertRaises(CLIENT.NativeClockRefused):
                    CLIENT.native_clock_python_loader(cache)

    def test_same_name_private_cache_replacement_is_refused_without_deletion(self):
        cache = self.parent / "private-cache"
        cache.mkdir(mode=0o700)
        original = self.parent / "old-cache"
        actual_iterdir = Path.iterdir

        def replace(path):
            if path == cache:
                cache.rename(original)
                cache.mkdir(mode=0o700)
                return iter(())
            return actual_iterdir(path)

        with self.loader_context(cache), mock.patch.object(Path, "iterdir", replace):
            with self.assertRaises(CLIENT.NativeClockRefused):
                CLIENT.native_clock_python_loader(cache)
        self.assertTrue(original.is_dir())
        self.assertTrue(cache.is_dir())

    def test_command_collection_performs_no_io_or_new_clock(self):
        with mock.patch.object(self.sink, "_write", side_effect=AssertionError("Unexpected write")):
            self.sink.command("clock", {"stdout": b'{"version":1}\n', "version": 1})
        self.assertEqual(list(self.sink.root.iterdir()), [])
        self.assertEqual(self.sink.records["clock"][1], b'{"version":1}\n')

    def test_duplicate_or_unbounded_frame_leaves_export_refused(self):
        self.sink.command("clock", {"stdout": b"one\n"})
        with self.assertRaises(CLIENT.NativeClockRefused):
            self.sink.command("clock", {"stdout": b"two\n"})
        self.assertTrue(self.sink.refused)
        other = CLIENT.NativeClockEvidence(self.parent / "other")
        with self.assertRaises(CLIENT.NativeClockRefused):
            other.command("clock", {"stdout": b"x" * 4097})
        self.assertTrue(other.refused)

    def test_foreign_same_name_root_is_not_written_or_removed(self):
        original = self.parent / "original"
        self.sink.root.rename(original)
        self.sink.root.mkdir(mode=0o700)
        marker = self.sink.root / "foreign"
        marker.write_bytes(b"foreign")
        with self.assertRaises(CLIENT.NativeClockRefused):
            self.sink._write("clock.json", b"{}")
        self.assertEqual(marker.read_bytes(), b"foreign")
        self.assertEqual(list(original.iterdir()), [])

    def test_exclusive_evidence_does_not_overwrite_existing_or_follow_alias(self):
        self.sink._write("clock.json", b"first")
        with self.assertRaises(FileExistsError):
            self.sink._write("clock.json", b"second")
        self.assertEqual((self.sink.root / "clock.json").read_bytes(), b"first")
        (self.sink.root / "sign.json").symlink_to("clock.json")
        with self.assertRaises(FileExistsError):
            self.sink._write("sign.json", b"changed")
        self.assertEqual((self.sink.root / "clock.json").read_bytes(), b"first")

    def test_missing_command_record_never_exports_image_or_receipt(self):
        with self.assertRaises(CLIENT.NativeClockRefused):
            self.sink.export(object(), object(), b"raw\n", {})
        self.assertEqual(list(self.sink.root.iterdir()), [])

    def test_no_environment_means_no_new_export_owner(self):
        build = object()
        with mock.patch.dict(CLIENT.os.environ, {}, clear=True):
            with mock.patch.object(
                CLIENT, "NativeClockEvidence", side_effect=AssertionError("Unexpected exporter")
            ):
                CLIENT.prepare_native_clock_evidence(build)

    def test_optional_publication_failure_does_not_suppress_actual_client_cancellation(self):
        class Build:
            passive_clock_evidence = self.sink

        for error in (
            OSError("EXPLICIT export refusal"),
            WIRE.FixtureFailure("EXPLICIT technical"),
        ):
            with mock.patch.object(self.sink, "export", side_effect=error):
                CLIENT.export_native_clock_evidence(Build(), object(), b"", {})
        for error in (
            KeyboardInterrupt(),
            SystemExit(2),
            CLIENT.wire.FixtureFailure("Native fixture cancelled"),
        ):
            with mock.patch.object(self.sink, "export", side_effect=error):
                with self.assertRaises(type(error)):
                    CLIENT.export_native_clock_evidence(Build(), object(), b"", {})


EXPECTED_CASES = {
    "PassiveCommandControls": (
        "test_absent_observer_acquires_no_receipt_or_optional_export",
        "test_actual_fixture_signal_handlers_preserve_fresh_cancellation",
        "test_closed_same_owner_observation_keeps_original_result_and_single_settlement",
        "test_false_ack_never_exports_or_retries_settlement",
        "test_keyboard_interrupt_and_system_exit_preserve_control_plane",
        "test_original_primary_remains_authoritative_when_callback_is_cancelled",
        "test_preexisting_group_debt_denies_new_child_and_export",
        "test_technical_sink_refusal_preserves_success",
        "test_truthy_nonliteral_ack_never_exports",
        "test_uncertain_original_capture_closure_never_exports",
    ),
    "PassiveExportControls": (
        "test_command_collection_performs_no_io_or_new_clock",
        "test_default_loader_or_other_prefix_stays_unqualified",
        "test_duplicate_or_unbounded_frame_leaves_export_refused",
        "test_exclusive_evidence_does_not_overwrite_existing_or_follow_alias",
        "test_explicit_private_cache_receives_actual_directory_identity",
        "test_foreign_same_name_root_is_not_written_or_removed",
        "test_missing_command_record_never_exports_image_or_receipt",
        "test_no_environment_means_no_new_export_owner",
        "test_nonempty_private_prefix_never_claims_uncached_execution",
        "test_optional_publication_failure_does_not_suppress_actual_client_cancellation",
        "test_same_name_private_cache_replacement_is_refused_without_deletion",
    ),
}
if __name__ == "__main__":
    for case in (PassiveCommandControls, PassiveExportControls):
        if (
            tuple(unittest.defaultTestLoader.getTestCaseNames(case))
            != EXPECTED_CASES[case.__name__]
        ):
            raise RuntimeError("Passive clock selector identity refused")
    if sum(map(len, EXPECTED_CASES.values())) != 21:
        raise RuntimeError("Passive clock selector census refused")
    del case
    unittest.main(verbosity=2)
