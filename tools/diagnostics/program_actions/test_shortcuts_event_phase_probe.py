#!/usr/bin/env python3
# tools/diagnostics/program_actions/test_shortcuts_event_phase_probe.py
"""Independent phase oracles and actual local-process controls; no macOS API fiction."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "event_phase", Path(__file__).with_name("run_shortcuts_event_phase_probe.py")
)
P = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(P)
RAW_PREFIX = b"EP1 START 1\nEP1 ENDPOINT 1\nEP1 RUNNING_BEFORE 1\nEP1 PREFLIGHT_ENTER 0\nEP1 PREFLIGHT_RETURN 0\n"
RAW_GOOD = (
    RAW_PREFIX
    + b"EP1 RAW_SEND_ENTER 0\nEP1 RAW_SEND_RETURN 0\nEP1 REPLY_CORRELATED 1\nEP1 REPLY_ERROR_SHAPE 1\nEP1 REPLY_ERROR 0\nEP1 SERVICE_REPLY 1\nEP1 RUNNING_AFTER 1\nEP1 END 0\n"
)
SB_PREFIX = b"EP1 START 2\nEP1 ENDPOINT 1\nEP1 RUNNING_BEFORE 1\nEP1 PREFLIGHT_ENTER 0\nEP1 PREFLIGHT_RETURN 0\nEP1 SB_CONSTRUCT_ENTER 0\nEP1 SB_CONSTRUCT_RETURN 1\nEP1 SB_COLLECTION_ENTER 0\nEP1 SB_COLLECTION_RETURN 1\n"
SB_GOOD = (
    SB_PREFIX
    + b"EP1 SB_COUNT_ENTER 0\nEP1 SB_COUNT_RETURN 1\nEP1 SB_FAILED 0\nEP1 SB_ERROR 0\nEP1 RUNNING_AFTER 1\nEP1 END 0\n"
)


class ProtocolControls(unittest.TestCase):
    def test_native_correlated_apple_audit_reply_is_only_this_comparator(self):
        parsed = P.parse_frames(RAW_GOOD, "raw-version")
        facts = P.facts(parsed, "raw-version", True)
        self.assertTrue(parsed["complete"])
        self.assertTrue(facts["service_reply_proved"])
        self.assertEqual(P.operation_reason(parsed, "raw-version"), "none")
        self.assertEqual(facts["baseline_cause"], "not_determined")
        for name in (
            "sender_equal_to_baseline",
            "catalogue_observed",
            "invocation_qualified",
            "remote_cancellation_qualified",
            "opaque_native_allocation_bounded",
        ):
            self.assertIs(facts[name], False)

    def test_entered_send_without_return_is_an_exact_stopped_prefix(self):
        parsed = P.parse_frames(RAW_PREFIX + b"EP1 RAW_SEND_ENTER 0\n", "raw-version")
        facts = P.facts(parsed, "raw-version", True)
        self.assertFalse(parsed["complete"])
        self.assertEqual(parsed["last"], "RAW_SEND_ENTER")
        self.assertTrue(facts["send_entered"])
        self.assertFalse(facts["send_returned"])
        self.assertIsNone(facts["send_status"])
        self.assertFalse(facts["service_reply_proved"])

    def test_preflight_target_requirement_never_becomes_historical_tcc_cause(self):
        raw = RAW_GOOD.replace(b"RUNNING_BEFORE 1", b"RUNNING_BEFORE 0").replace(
            b"PREFLIGHT_RETURN 0", b"PREFLIGHT_RETURN -600"
        )
        parsed = P.parse_frames(raw, "raw-version")
        facts = P.facts(parsed, "raw-version", True)
        self.assertEqual(facts["permission_status"], -600)
        self.assertFalse(facts["running_before_observed"])
        self.assertTrue(facts["service_reply_proved"])
        self.assertEqual(facts["baseline_cause"], "not_determined")

    def test_typed_send_failures_keep_exact_current_sender_outcomes(self):
        for code, reason in [
            (-1744, "this_sender_would_require_consent"),
            (-1743, "this_sender_permission_refused"),
            (-600, "this_sender_target_not_found"),
            (-1712, "this_sender_event_timeout"),
        ]:
            raw = (
                RAW_PREFIX
                + f"EP1 RAW_SEND_ENTER 0\nEP1 RAW_SEND_RETURN {code}\nEP1 RUNNING_AFTER 1\nEP1 END 0\n".encode()
            )
            parsed = P.parse_frames(raw, "raw-version")
            self.assertEqual(P.operation_reason(parsed, "raw-version"), reason)
            self.assertEqual(P.facts(parsed, "raw-version", True)["send_status"], code)
            self.assertFalse(P.facts(parsed, "raw-version", True)["service_reply_proved"])

    def test_unproved_audit_source_never_is_a_service_reply(self):
        parsed = P.parse_frames(
            RAW_GOOD.replace(b"SERVICE_REPLY 1", b"SERVICE_REPLY 0"), "raw-version"
        )
        self.assertEqual(P.operation_reason(parsed, "raw-version"), "reply_source_not_proved")
        self.assertFalse(P.facts(parsed, "raw-version", True)["service_reply_proved"])

    def test_forged_reply_correlation_or_shape_is_closed(self):
        for old in (b"REPLY_CORRELATED 1", b"REPLY_ERROR_SHAPE 1"):
            with self.assertRaises(P.Refused):
                P.parse_frames(RAW_GOOD.replace(old, old[:-1] + b"0"), "raw-version")
        self.assertFalse(
            P.facts(P.parse_frames(RAW_GOOD, "raw-version"), "raw-version", False)[
                "service_reply_proved"
            ]
        )

    def test_remote_service_can_reply_with_a_read_failure(self):
        parsed = P.parse_frames(
            RAW_GOOD.replace(b"REPLY_ERROR 0", b"REPLY_ERROR -1728"), "raw-version"
        )
        self.assertTrue(P.facts(parsed, "raw-version", True)["service_reply_proved"])
        self.assertEqual(P.operation_reason(parsed, "raw-version"), "remote_read_refused")

    def test_sb_count_entry_does_not_claim_a_transport_entry(self):
        parsed = P.parse_frames(SB_PREFIX + b"EP1 SB_COUNT_ENTER 0\n", "sb-count")
        facts = P.facts(parsed, "sb-count", True)
        self.assertFalse(parsed["complete"])
        self.assertEqual(parsed["last"], "SB_COUNT_ENTER")
        self.assertFalse(facts["send_entered"])
        self.assertFalse(facts["service_reply_proved"])

    def test_sb_count_return_is_never_catalogue_or_invocation(self):
        parsed = P.parse_frames(SB_GOOD, "sb-count")
        self.assertEqual(P.operation_reason(parsed, "sb-count"), "none")
        facts = P.facts(parsed, "sb-count", True)
        self.assertTrue(facts["sb_count_returned"])
        self.assertFalse(facts["catalogue_observed"])
        self.assertFalse(facts["invocation_qualified"])

    def test_sb_error_is_typed_current_sender_permission_only(self):
        raw = (
            SB_PREFIX
            + b"EP1 SB_COUNT_ENTER 0\nEP1 SB_COUNT_RETURN 0\nEP1 SB_FAILED 1\nEP1 SB_ERROR -1743\nEP1 RUNNING_AFTER 1\nEP1 END 0\n"
        )
        parsed = P.parse_frames(raw, "sb-count")
        self.assertEqual(P.operation_reason(parsed, "sb-count"), "this_sender_permission_refused")
        self.assertEqual(P.facts(parsed, "sb-count", True)["baseline_cause"], "not_determined")

    def test_endpoint_or_native_fixture_never_proves_service_availability(self):
        endpoint = P.parse_frames(b"EP1 START 1\nEP1 ENDPOINT 0\nEP1 END 0\n", "raw-version")
        self.assertEqual(P.operation_reason(endpoint, "raw-version"), "endpoint_not_verified")
        fixture = P.parse_frames(
            b"EP1 FIXTURE 1\nEP1 FIXTURE_STATUS 0\nEP1 FIXTURE_HANDLER 1\n",
            "native-fixture",
        )
        facts = P.facts(fixture, "native-fixture", True)
        self.assertTrue(facts["fixture_only"])
        self.assertFalse(facts["service_reply_proved"])
        with self.assertRaises(P.Refused):
            P.parse_frames(b"EP1 FIXTURE 1\n", "raw-version")

    def test_private_malformed_duplicate_and_oversize_frames_refuse(self):
        for raw in [
            b"private name\n",
            b"EP1 START 1\nEP1 START 1\n",
            b"EP1 START 01\n",
            b"EP1 START 2147483648\n",
            b"EP1 START 1",
            RAW_GOOD + b"EP1 END 0\n",
            b"x" * 4097,
        ]:
            with self.assertRaises(P.Refused):
                P.parse_frames(raw, "raw-version")

    def test_native_source_has_fixed_readonly_no_prompt_and_audit_contract(self):
        source = Path(__file__).with_name("ShortcutsEventPhaseProbe.m").read_text()
        self.assertIn(
            "AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, false)",
            source,
        )
        self.assertIn(
            "kAENeverInteract | kAEDontRecord | kAEDoNotPromptForUserConsent, 15 * 60",
            source,
        )
        self.assertIn("app.timeout = 15 * 60", source)
        self.assertIn("keySenderAuditTokenAttr", source)
        self.assertIn("kSecGuestAttributeAudit", source)
        self.assertIn("correlated && errorShape && appleReplyAudit(&reply, requirement)", source)
        self.assertIn("desc.descriptorType == typeSInt32", source)
        self.assertIn("AEGetParamDesc(reply, keyErrorNumber, typeWildCard", source)
        self.assertIn("AEGetAttributeDesc(event, key, typeWildCard", source)
        self.assertIn('CFSTR("anchor apple")', source)
        self.assertIn("pVersion", source)
        self.assertNotIn("runWithInput", source)
        self.assertNotIn("DYLD_INSERT_LIBRARIES", source)
        self.assertNotIn("ObjC.import", source)
        observer = Path(__file__).with_name("run_shortcuts_event_phase_probe.py").read_text()
        self.assertIn("capture([str(worker), args.role], native, owner, 20)", observer)
        self.assertIn('"baseline_cause": "not_determined"', observer)


class CustodyControls(unittest.TestCase):
    def setUp(self):
        self.addCleanup(P.RETAINED.clear)
        patcher = mock.patch.object(P.signal, "signal", return_value=P.signal.SIG_DFL)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_deferred_acquisition_interruption_retains_registered_owner_until_closed(
        self,
    ):
        group = types.SimpleNamespace(
            reservation_lost=False,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(returncode=-15),
        )

        def settle():
            self.assertIs(P.RETAINED[id(group)], group)
            group.reaped = True
            return True

        group.settle = settle
        group.receipt = lambda: {"closed": True}

        def acquire(arguments, native, register, **options):
            register(group)
            raise P.Refused("interrupted")

        metadata, raw = P.capture(
            ["controlled"], None, types.SimpleNamespace(acquire_owned=acquire), 20
        )
        self.assertEqual(metadata["failure"], "interrupted")
        self.assertTrue(metadata["retired"])
        self.assertEqual(raw, b"")
        self.assertNotIn(id(group), P.RETAINED)

    def test_acquisition_time_is_inside_the_single_parent_deadline(self):
        group = types.SimpleNamespace(
            reservation_lost=False,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(returncode=-15),
            observations=0,
        )

        def settle():
            group.reaped = True
            return True

        def observe():
            group.observations += 1
            return object()

        group.settle = settle
        group.observe_exit = observe
        group.receipt = lambda: {"closed": True}
        owner = types.SimpleNamespace(
            acquire_owned=lambda arguments, native, register, **options: register(group)
        )
        with mock.patch.object(P.time, "monotonic", side_effect=[0, 21, 21, 21]):
            metadata, raw = P.capture(["controlled"], None, owner, 20)
        self.assertEqual(metadata["failure"], "deadline")
        self.assertEqual(group.observations, 0)
        self.assertTrue(metadata["receipt"]["closed"])
        self.assertEqual(raw, b"")

    def test_lost_reservation_parks_without_another_signal_or_reap(self):
        class ParkCheckpoint(BaseException):
            pass

        group = types.SimpleNamespace(
            reservation_lost=True,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(returncode=None),
            calls=0,
        )

        def settle():
            group.calls += 1
            return False

        group.settle = settle

        def observe():
            raise RuntimeError("controlled unavailable native observation")

        group.observe_exit = observe
        owner = types.SimpleNamespace(
            acquire_owned=lambda arguments, native, register, **options: register(group)
        )

        def park(duration):
            self.assertIs(P.RETAINED[id(group)], group)
            raise ParkCheckpoint()

        with mock.patch.object(P.time, "sleep", side_effect=park):
            with self.assertRaises(ParkCheckpoint):
                P.capture(["controlled"], None, owner, 20)
        self.assertEqual(group.calls, 0)
        self.assertIs(P.RETAINED[id(group)], group)


class LinuxProcCensus:
    """Actual Linux kernel controls; this is explicitly not a Darwin ABI claim."""

    def observe_exit(self, process):
        return os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)

    def live_members(self, pgid, leader):
        live = []
        reserved = False
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                raw = (entry / "stat").read_text()
                fields = raw.rpartition(") ")[2].split()
            except FileNotFoundError:
                continue
            if int(fields[2]) != pgid:
                continue
            pid = int(entry.name)
            if pid == leader:
                P.require(
                    fields[0] == "Z" and int(fields[1]) == os.getpid(),
                    "unreserved_linux_fixture",
                )
                reserved = True
            if fields[0] != "Z":
                live.append(pid)
        P.require(reserved, "unreserved_linux_fixture")
        return live


class ActualProcessControls(unittest.TestCase):
    """Run only on Linux or actual Darwin/Python3.13, never silently skip."""

    def setUp(self):
        dependency = ROOT / "tools/diagnostics/macos_owned_process.py"
        if not dependency.is_file():
            dependency = ROOT.parent / "dependencies/tools/diagnostics/macos_owned_process.py"
        spec = importlib.util.spec_from_file_location("phase_process_fixture", dependency)
        self.owner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.owner)
        if sys.platform == "linux":
            self.native = LinuxProcCensus()
        else:
            self.native = self.owner.NativeProcessGroups()

    def test_real_local_process_prefix_arrives_only_after_retirement(self):
        script = "import sys; sys.stdout.buffer.write(" + repr(RAW_GOOD) + ")"
        metadata, raw = P.capture([sys.executable, "-c", script], self.native, self.owner, 2)
        self.assertEqual(metadata["failure"], "none")
        self.assertEqual(metadata["status"], 0)
        self.assertTrue(metadata["retired"])
        self.assertTrue(metadata["receipt"]["closed"])
        self.assertEqual(raw, RAW_GOOD)
        self.assertEqual(P.parse_frames(raw, "raw-version")["last"], "END")

    def test_actual_deadline_keeps_send_entry_and_exact_local_sigterm_retirement(self):
        prefix = RAW_PREFIX + b"EP1 RAW_SEND_ENTER 0\n"
        script = (
            "import sys,time; sys.stdout.buffer.write("
            + repr(prefix)
            + "); sys.stdout.flush(); time.sleep(30)"
        )
        metadata, raw = P.capture([sys.executable, "-c", script], self.native, self.owner, 0.2)
        self.assertEqual(metadata["failure"], "deadline")
        self.assertEqual(metadata["status"], -signal.SIGTERM)
        self.assertTrue(metadata["receipt"]["closed"])
        self.assertIn(signal.SIGTERM, metadata["receipt"]["signals"])
        parsed = P.parse_frames(raw, "raw-version")
        self.assertEqual(parsed["last"], "RAW_SEND_ENTER")
        self.assertFalse(P.facts(parsed, "raw-version", True)["service_reply_proved"])

    def test_actual_output_limit_is_refusal_and_physical_receipt_survives(self):
        script = "import sys,time;sys.stdout.write('x'*5000);sys.stdout.flush();time.sleep(30)"
        metadata, raw = P.capture([sys.executable, "-c", script], self.native, self.owner, 2)
        self.assertEqual(metadata["failure"], "output_limit")
        self.assertGreater(metadata["stdout_bytes"], 4096)
        self.assertTrue(metadata["receipt"]["closed"])
        self.assertEqual(raw, b"")


class CompilerDiagnosticControls(unittest.TestCase):
    """Handwritten public-error oracles over controlled stderr, never native SDK proof."""

    def test_exact_public_header_diagnostic_exports_only_its_fixed_class(self):
        raw = (
            b"/private/user/ShortcutsEventPhaseProbe.m:3:9: fatal error: 'AppKit/AppKit.h' file not found\n"
            b"private catalogue, opaque error, and signed redirect data stay private\n"
        )
        self.assertEqual(P.classify_compiler_stderr(raw), ["missing_appkit_header"])
        raw = b"ShortcutsEventPhaseProbe.m:4:9: fatal error: 'Foundation/Foundation.h' file not found\r\n"
        self.assertEqual(P.classify_compiler_stderr(raw), ["missing_foundation_header"])

    def test_exact_native_symbol_and_unknown_stderr_have_independent_closed_classes(self):
        raw = b"ShortcutsEventPhaseProbe.m:123:6: error: use of undeclared identifier 'keySenderAuditTokenAttr'\n"
        self.assertEqual(P.classify_compiler_stderr(raw), ["undeclared_sender_audit_attribute"])
        for raw in (
            b"opaque private compiler error\n",
            b"mention 'AppKit/AppKit.h' file not found\n",
            b"private.m:3:9: fatal error: 'AppKit/AppKit.h' file not found\n",
            b"OtherShortcutsEventPhaseProbe.m:3:9: fatal error: 'AppKit/AppKit.h' file not found\n",
            b"ShortcutsEventPhaseProbe.m:3:9: fatal error: 'private/catalogue.h' file not found\n",
        ):
            self.assertEqual(P.classify_compiler_stderr(raw), ["unclassified"])
        self.assertEqual(P.classify_compiler_stderr(b""), ["empty_stderr"])
        for raw in ("native text", b"x" * 65537):
            with self.assertRaises(P.Refused):
                P.classify_compiler_stderr(raw)

    def test_compiler_classification_waits_for_retirement_and_preserves_refusal(self):
        self.addCleanup(P.RETAINED.clear)
        raw = b"ShortcutsEventPhaseProbe.m:3:9: fatal error: 'AppKit/AppKit.h' file not found\n"
        group = types.SimpleNamespace(
            reservation_lost=False,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(pid=456, returncode=1),
        )
        group.observe_exit = lambda: types.SimpleNamespace(si_pid=456, si_code=1, si_status=1)
        group.receipt = lambda: {"closed": group.reaped}
        classifier = P.classify_compiler_stderr

        def classify(value):
            self.assertTrue(group.reaped)
            return classifier(value)

        def settle():
            self.assertIs(P.RETAINED[id(group)], group)
            group.reaped = True
            return True

        group.settle = settle

        def acquire(arguments, native, register, **options):
            self.assertEqual(arguments, ["controlled-compiler"])
            register(group)
            options["stderr"].write(raw)

        owner = types.SimpleNamespace(acquire_owned=acquire)
        with mock.patch.object(P.signal, "signal", return_value=P.signal.SIG_DFL):
            with mock.patch.object(P, "classify_compiler_stderr", side_effect=classify):
                metadata, stdout = P.capture(
                    ["controlled-compiler"], None, owner, 120, 65536, compiler_diagnostics=True
                )
        self.assertEqual(metadata["compiler_error_classes"], ["missing_appkit_header"])
        self.assertEqual(metadata["status"], 1)
        self.assertEqual(metadata["failure"], "none")
        self.assertTrue(metadata["retired"])
        self.assertTrue(metadata["receipt"]["closed"])
        self.assertEqual(stdout, b"")
        self.assertNotIn(id(group), P.RETAINED)

    def test_nonboolean_diagnostic_mode_refuses_before_acquisition(self):
        acquire = mock.Mock()
        with self.assertRaises(P.Refused):
            P.capture(
                ["controlled"],
                None,
                types.SimpleNamespace(acquire_owned=acquire),
                20,
                compiler_diagnostics=1,
            )
        acquire.assert_not_called()

    def test_actual_main_publishes_closed_compile_diagnostic_and_stops_before_sign(self):
        self.addCleanup(P.RETAINED.clear)
        raw = b"ShortcutsEventPhaseProbe.m:3:9: fatal error: 'AppKit/AppKit.h' file not found\n"
        group = types.SimpleNamespace(
            reservation_lost=False,
            reap_started=False,
            reaped=False,
            process=types.SimpleNamespace(pid=456, returncode=1),
        )
        group.observe_exit = lambda: types.SimpleNamespace(si_pid=456, si_code=1, si_status=1)
        group.receipt = lambda: {"closed": group.reaped}

        def settle():
            group.reaped = True
            return True

        group.settle = settle

        def acquire(arguments, native, register, **options):
            self.assertIn("-fobjc-arc", arguments)
            self.assertIn("-mmacosx-version-min=13.0", arguments)
            self.assertNotIn("/usr/bin/codesign", arguments)
            register(group)
            options["stderr"].write(raw)

        owner = types.SimpleNamespace(acquire_owned=acquire, NativeProcessGroups=lambda: None)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "observation"
            compiler = Path(directory) / "controlled-clang"
            compiler.write_bytes(b"controlled compiler identity")
            argv = [
                "probe",
                "--source-root",
                str(ROOT),
                "--source-sha",
                "a" * 40,
                "--role",
                "raw-version",
                "--output",
                str(output),
            ]
            with (
                mock.patch.object(P.sys, "argv", argv),
                mock.patch.object(P.sys, "platform", "darwin"),
                mock.patch.object(P.sys, "version_info", (3, 13)),
                mock.patch.object(P, "source_snapshot", return_value={"controlled": "source"}),
                mock.patch.object(P, "load_owner", return_value=owner),
                mock.patch.object(
                    P.subprocess,
                    "check_output",
                    side_effect=[b"prior source", str(compiler).encode()],
                ) as commands,
                mock.patch.object(P.signal, "signal", return_value=P.signal.SIG_DFL),
            ):
                self.assertEqual(P.main(), 1)
            observed = json.loads((output / "observation.json").read_bytes())
            self.assertEqual(observed["result"], "REFUSED")
            self.assertEqual(observed["reason"], "compile_refused")
            self.assertEqual(observed["baseline_cause"], "not_determined")
            self.assertEqual(len(observed["captures"]), 1)
            compiled = observed["captures"][0]
            self.assertEqual(compiled["operation"], "compile")
            self.assertEqual(compiled["compiler_error_classes"], ["missing_appkit_header"])
            self.assertEqual(compiled["status"], 1)
            self.assertTrue(compiled["retired"])
            self.assertTrue(compiled["receipt"]["closed"])
            self.assertEqual(commands.call_count, 2)
            self.assertNotIn("ShortcutsEventPhaseProbe.m:", json.dumps(observed))
            self.assertNotIn(id(group), P.RETAINED)


if __name__ == "__main__":
    unittest.main()
