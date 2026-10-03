# tools/diagnostics/hs_native_bootstrap_probe_test.py
"""Reject foreign startup owners, incomplete native measurements and cleanup debt."""

import copy
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

import hs_native_bootstrap_probe as probe
import hs_delayed_timer_probe_test as timer_cases
import hs_karabiner_config_probe_test as karabiner_cases
import macos_launch_gate as gate

DOMAIN = timer_cases.DOMAIN
NONCE = timer_cases.NONCE


class NativeFixture:
    """Model external native boundaries while invoking the actual ownership code."""

    def __init__(self, root):
        self.app = root / "ErgoptiPlus.app"
        self.output = root / "evidence"
        self.output.mkdir()
        self.executable = probe.NativeDelayedTimerProbe.executable_path(self.app)
        self.launcher = self.app / "Contents/MacOS/ErgoptiPlus"
        self.embedded = self.app / "Contents/Frameworks/Hammerspoon.app"
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text("native boundary fixture; not a Darwin proof")
        with (self.embedded / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(
                {"CFBundleIdentifier": DOMAIN, "CFBundleShortVersionString": "1.1.1"}, handle
            )
        macos = self.app / "Contents/Resources/static/ergopti_plus/macos"
        macos.mkdir(parents=True)
        (macos / "init.lua").write_text("-- Must never execute the full driver.")
        (macos.parent / "_shared/lua").mkdir(parents=True)
        self.preferences = {probe.CONFIG_KEY: ["physical", "legacy"], "unrelated": 91}
        self.initial = copy.deepcopy(self.preferences)
        self.owners = []
        self.calls = []
        self.ready_mutation = None
        self.settled_mutation = None
        self.feature_mutation = None
        self.fail_open = False
        self.owner = probe.SupplementaryNativeBootstrap(
            self.app, self.output, DOMAIN, self.processes, self.run
        )
        self.owner.nonce = NONCE
        self.owner.identity["nonce"] = NONCE

    def processes(self, executable):
        return list(self.owners) if executable == self.executable else []

    def run(self, arguments, **options):
        self.calls.append((arguments, options))
        if arguments[0] == "/usr/bin/defaults":
            command = arguments[1]
            if command == "export":
                return subprocess.CompletedProcess(
                    arguments, 0, plistlib.dumps(self.preferences), b""
                )
            if command == "write":
                self.preferences[arguments[3]] = arguments[5]
            elif command == "import":
                # Native defaults import can merge omitted keys.
                self.preferences.update(plistlib.loads(options["input"]))
            elif command == "delete":
                self.preferences.pop(arguments[3], None)
            return subprocess.CompletedProcess(arguments, 0, b"", b"")
        if arguments[0] == "/usr/bin/open":
            if self.fail_open:
                return subprocess.CompletedProcess(arguments, 1, b"", b"refused")
            self.owners = [42]
            context = probe.read_receipt(
                self.output / "supplementary-native-bootstrap/context.json"
            )
            ready = dict(
                self.owner.identity,
                schema_version=1,
                contract=probe.CONTRACT,
                phase="ready",
                pid=42,
            )
            if self.ready_mutation:
                self.ready_mutation(ready)
            probe.publish(Path(context["paths"]["ready"]), ready)
            self.preferences["late-unrelated"] = "keep"
        return subprocess.CompletedProcess(arguments, 0, b"", b"")

    def settle(self, path, timeout):
        if path.name == "ready.json":
            self.test.assertEqual(timeout, 10)
            return probe.read_receipt(path)
        self.test.assertEqual(
            timeout,
            15
            if probe.read_receipt(path.with_name("context.json"))["feature"] == "delayed_timer"
            else 10,
        )
        admitted = probe.read_receipt(path.with_name("admit.json"))
        self.test.assertEqual(self.owner.pid, 42)
        self.test.assertEqual(admitted["phase"], "admit")
        self.test.assertEqual(admitted["nonce"], NONCE)
        context = probe.read_receipt(path.with_name("context.json"))
        receipt = (
            timer_cases.receipt()
            if context["feature"] == "delayed_timer"
            else karabiner_cases.receipt()
        )
        receipt["executable"] = str(self.executable)
        if self.feature_mutation:
            self.feature_mutation(receipt)
        probe.publish(path.with_name("feature.json"), receipt)
        settled = dict(
            self.owner.identity,
            schema_version=1,
            contract=probe.CONTRACT,
            phase="settled",
            pid=42,
            complete=True,
            cleanup_acknowledged=True,
            errors=[],
        )
        if self.settled_mutation:
            self.settled_mutation(settled)
        probe.publish(path, settled)
        return settled

    def kill(self, pid, _signal):
        self.test.assertEqual(pid, 42)
        self.owners = []

    def observe(self, test, feature="delayed_timer"):
        self.test = test
        with (
            mock.patch.object(self.owner, "wait_receipt", side_effect=self.settle),
            mock.patch.object(probe.os, "kill", side_effect=self.kill),
        ):
            return self.owner.observe(feature)


class StartupOwnershipTests(unittest.TestCase):
    """Keep physical preferences and real native ownership separate from admission."""

    def test_original_probe_measurements_are_qualified_only_after_exact_retirement(self):
        for feature in ("delayed_timer", "karabiner_config"):
            with self.subTest(feature=feature), tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                summary = fixture.observe(self, feature)
                self.assertEqual(summary["feature"], feature)
                self.assertEqual(summary["qualification"], probe.QUALIFICATION)
                self.assertTrue(summary["cleanup_acknowledged"])
                self.assertTrue(summary["process_retired"])
                self.assertTrue(summary["preference_restored"])
                self.assertEqual(
                    fixture.preferences[probe.CONFIG_KEY], fixture.initial[probe.CONFIG_KEY]
                )
                self.assertEqual(fixture.preferences["late-unrelated"], "keep")
                self.assertEqual(fixture.owners, [])
                commands = [call[0] for call in fixture.calls]
                self.assertEqual(
                    [cmd for cmd in commands if cmd[0] == "/usr/bin/open"],
                    [["/usr/bin/open", "-n", str(fixture.embedded)]],
                )
                self.assertTrue(
                    any(
                        cmd[:5]
                        == [
                            "/usr/bin/codesign",
                            "--verify",
                            "--deep",
                            "--strict",
                            str(fixture.embedded),
                        ]
                        for cmd in commands
                    )
                )
                self.assertFalse(any("osascript" in cmd[0] for cmd in commands))
                self.assertFalse(any("HSAppleScriptEnabledKey" in cmd for cmd in commands))
                context = probe.read_receipt(
                    fixture.output / "supplementary-native-bootstrap/context.json"
                )
                self.assertEqual(
                    Path(context["probe_source"]).name,
                    "hs_delayed_timer_native.lua"
                    if feature == "delayed_timer"
                    else "hs_karabiner_config_native.lua",
                )
                self.assertEqual(context["admission_timeout"], 10)
                self.assertEqual(
                    context["feature_timeout"], 15 if feature == "delayed_timer" else 10
                )

    def test_absent_startup_key_is_physically_removed_without_losing_late_values(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            fixture.preferences.pop(probe.CONFIG_KEY)
            fixture.observe(self)
            self.assertNotIn(probe.CONFIG_KEY, fixture.preferences)
            self.assertEqual(fixture.preferences["late-unrelated"], "keep")

    def test_failed_publication_still_restores_exact_physical_value(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            original_run = fixture.run

            def refused(arguments, **options):
                result = original_run(arguments, **options)
                if arguments[:2] == ["/usr/bin/defaults", "write"]:
                    result.returncode = 1
                return result

            fixture.owner.preference.runner = refused
            with self.assertRaisesRegex(RuntimeError, "publication"):
                fixture.observe(self)
            self.assertEqual(fixture.preferences, fixture.initial)

    def test_failed_launch_still_restores_without_claiming_a_native_measurement(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            fixture.fail_open = True
            with self.assertRaisesRegex(RuntimeError, "LaunchServices"):
                fixture.observe(self)
            self.assertEqual(fixture.preferences, fixture.initial)

    def test_foreign_or_duplicate_preexisting_runtime_refuses_before_preferences(self):
        for owners in ([42], [42, 43]):
            with tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                fixture.owners = owners
                with self.assertRaisesRegex(RuntimeError, "original runtimes"):
                    fixture.observe(self)
                self.assertEqual(fixture.calls, [])
                self.assertEqual(fixture.preferences, fixture.initial)

    def test_every_exact_ready_field_and_unknown_field_refuses_dispatch(self):
        for key, value in {
            "nonce": "b" * 32,
            "pid": 43,
            "executable": "/foreign/Hammerspoon",
            "bundle_id": "org.hammerspoon.Hammerspoon",
            "version": "0.0.0",
            "schema_version": True,
            "phase": "admit",
            "contract": "foreign",
            "extra": True,
        }.items():
            with self.subTest(key=key), tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                fixture.ready_mutation = lambda receipt, k=key, v=value: receipt.update({k: v})
                with self.assertRaises(ValueError):
                    fixture.observe(self)
                self.assertFalse(
                    (fixture.output / "supplementary-native-bootstrap/admit.json").exists()
                )
                self.assertEqual(
                    fixture.preferences[probe.CONFIG_KEY], fixture.initial[probe.CONFIG_KEY]
                )

    def test_incomplete_or_foreign_terminal_owner_cannot_publish_success(self):
        for key, value in {
            "cleanup_acknowledged": False,
            "complete": False,
            "errors": ["stop refused"],
            "pid": 43,
            "nonce": "b" * 32,
            "version": "0.0.0",
            "extra": True,
        }.items():
            with self.subTest(key=key), tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                fixture.settled_mutation = lambda receipt, k=key, v=value: receipt.update({k: v})
                with self.assertRaises(ValueError):
                    fixture.observe(self)
                self.assertEqual(fixture.owners, [])
                self.assertEqual(
                    fixture.preferences[probe.CONFIG_KEY], fixture.initial[probe.CONFIG_KEY]
                )

    def test_original_timer_inventory_and_karabiner_graph_assertions_remain_required(self):
        for feature, mutate in (
            ("delayed_timer", lambda result: result["deliveries"].update(rearm=1)),
            ("delayed_timer", lambda result: result["observations"].pop("idle_running")),
            ("karabiner_config", lambda result: result.update(lease_initialized=True)),
            ("karabiner_config", lambda result: result["variants"].pop()),
        ):
            with self.subTest(feature=feature), tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                fixture.feature_mutation = mutate
                with self.assertRaises(ValueError):
                    fixture.observe(self, feature)
                self.assertEqual(fixture.owners, [])

    def test_changed_native_process_retains_preference_debt_instead_of_restoring(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            fixture.test = self
            original_settle = fixture.settle

            def changed(path, timeout):
                result = original_settle(path, timeout)
                if path.name == "settled.json":
                    fixture.owners = [43]
                return result

            with (
                mock.patch.object(fixture.owner, "wait_receipt", side_effect=changed),
                mock.patch.object(probe.os, "kill") as killed,
            ):
                with self.assertRaisesRegex(RuntimeError, "Foreign native process debt"):
                    fixture.owner.observe("delayed_timer")
            killed.assert_not_called()
            self.assertNotEqual(
                fixture.preferences[probe.CONFIG_KEY], fixture.initial[probe.CONFIG_KEY]
            )

    def test_real_owned_child_is_reaped_before_exact_preference_restoration(self):
        child = subprocess.Popen(["/usr/bin/env", "python3", "-c", "import time; time.sleep(60)"])
        try:
            with tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                owner = fixture.owner
                owner.pid = child.pid
                owner.launch_attempted = True

                def current(_executable):
                    return [child.pid] if child.poll() is None else []

                owner.processes = current
                owner.retire()
                self.assertIsNotNone(child.returncode)
                self.assertEqual(current(owner.executable), [])
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=2)

    def test_receipts_reject_duplicate_truncated_and_symlinked_answers(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "answer.json"
            for raw in ('{"nonce":"a","nonce":"b"}', '{"nonce":', '"' + "a" * 50 + '"'):
                path.write_text(raw)
                with self.assertRaises(ValueError):
                    probe.read_receipt(path, 32)
            path.unlink()
            foreign = Path(root) / "foreign.json"
            foreign.write_text("{}")
            path.symlink_to(foreign)
            with self.assertRaisesRegex(ValueError, "regular file"):
                probe.read_receipt(path)

    def test_foreign_startup_preference_edit_is_preserved_and_refuses_restoration(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            fixture.owner.preference.configure(Path(root) / "owned.lua")
            fixture.preferences[probe.CONFIG_KEY] = "foreign-choice.lua"
            with self.assertRaisesRegex(RuntimeError, "foreign startup preference"):
                fixture.owner.preference.restore()
            self.assertEqual(fixture.preferences[probe.CONFIG_KEY], "foreign-choice.lua")

    def test_bootstrap_refusal_reuses_bounded_privacy_and_omits_child_argv(self):
        private_path = str(Path.home() / "private-bootstrap-source.lua")
        raw = RuntimeError(private_path + " " + "details " * 3000)
        bounded = probe.bounded_refusal(raw)
        self.assertNotIn(private_path, bounded)
        self.assertIn("[path redacted]", bounded)
        self.assertIn("[native diagnostic truncated]", bounded)
        self.assertLessEqual(len(bounded), 8192)
        deadline = subprocess.TimeoutExpired(["/usr/bin/open", "private-child-argv"], 10)
        self.assertNotIn("private-child-argv", probe.bounded_refusal(deadline))

    def test_unicode_owned_startup_paths_are_valid_utf8_lua_literals(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root) / "ù — ★"
            directory.mkdir()
            fixture = NativeFixture(directory)
            fixture.observe(self)
            source = (fixture.output / "supplementary-native-bootstrap/init.lua").read_text()
            self.assertIn("ù — ★", source)
            self.assertNotIn("\\u", source)

    def test_receipt_already_present_after_deadline_is_not_a_late_success(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = NativeFixture(Path(root))
            fixture.owners = [42]
            path = Path(root) / "late.json"
            path.write_text("{}")
            for clock in ([100, 111], [100, 100, 111]):
                with (
                    self.subTest(clock=clock),
                    mock.patch.object(probe.time, "monotonic", side_effect=clock),
                ):
                    with self.assertRaisesRegex(RuntimeError, "timed out"):
                        fixture.owner.wait_receipt(path, 10)


class PackagedExecutionTests(unittest.TestCase):
    """Require the supplementary call after original retirement, without substitution."""

    def test_packaged_scenarios_execute_supplementary_probe_after_original_cleanup(self):
        for scenario, feature in (
            ("clean", "delayed_timer"),
            ("karabiner_config", "karabiner_config"),
        ):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as root:
                fixture = NativeFixture(Path(root))
                fixture.launcher.parent.mkdir(parents=True)
                fixture.launcher.write_text("fixture launcher")
                with (fixture.app / "Contents/Info.plist").open("wb") as handle:
                    plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
                owner = mock.Mock()
                owner.scripting_commands = []
                owner.diagnostic_receipts = []
                owner.control.side_effect = RuntimeError("original control refused")
                owner.observe.side_effect = RuntimeError("original feature refused")
                supplement = mock.Mock()
                supplement.observe.return_value = {"qualification": probe.QUALIFICATION}
                live = {"value": False}
                events = []

                def processes(executable):
                    return [42 if executable == fixture.executable else 41] if live["value"] else []

                def run_native(arguments, **options):
                    if arguments[0] == "open":
                        live["value"] = True
                    return subprocess.CompletedProcess(arguments, 0, "arm64", "")

                def quit_native(*_):
                    live["value"] = False
                    events.append("retired")
                    return 0.5

                def restored():
                    self.assertFalse(live["value"])
                    events.append("restored")

                def supplemental(*arguments):
                    self.assertEqual(events, ["retired", "restored"])
                    self.assertFalse(live["value"])
                    self.assertEqual(arguments[:3], (fixture.app, fixture.output, DOMAIN))
                    self.assertEqual(arguments[3](fixture.executable), [])
                    return supplement

                owner.restore.side_effect = restored
                owner_name = (
                    "NativeDelayedTimerProbe"
                    if scenario == "clean"
                    else "NativeKarabinerConfigProbe"
                )
                with (
                    mock.patch.object(gate.Path, "home", return_value=Path(root) / "home"),
                    mock.patch.object(gate, "seed", return_value={"logs_dir": Path(root) / "logs"}),
                    mock.patch.object(gate, owner_name, return_value=owner),
                    mock.patch.object(
                        gate, "SupplementaryNativeBootstrap", create=True, side_effect=supplemental
                    ) as invoked,
                    mock.patch.object(gate, "processes", side_effect=processes),
                    mock.patch.object(gate.subprocess, "run", side_effect=run_native),
                    mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                    mock.patch.object(
                        gate,
                        "read_text",
                        return_value="embedded Hammerspoon bootstrap logger configured\n",
                    ),
                    mock.patch.object(
                        gate, "driver_logs", return_value="Onboarding wizard opened.\n"
                    ),
                    mock.patch.object(gate, "check_state", return_value=[]),
                    mock.patch.object(gate, "quit_application", side_effect=quit_native),
                    mock.patch.object(gate, "collect", return_value={"errors": [], "windows": {}}),
                ):
                    # The gate's actual resolver is the mocked callable, not
                    # the stand-in function supplying its external observations.
                    report = gate.run(fixture.app, fixture.output, scenario, "")
                invoked.assert_called_once()
                supplement.observe.assert_called_once_with(feature)
                self.assertEqual(
                    report["supplementary_native_bootstrap"], supplement.observe.return_value
                )
                self.assertTrue(
                    any("original control refused" in item for item in report["failures"])
                )
                self.assertTrue(
                    any("original feature refused" in item for item in report["failures"])
                )
                self.assertIsNone(report.get("native_delayed_timer"))
                self.assertIsNone(report.get("native_karabiner_config"))

    def test_supplementary_success_cannot_change_any_original_verdict(self):
        from macos_launch_gate_test import HEALTHY

        missing = dict(
            HEALTHY,
            native_transport_control_error="required path refused",
            native_delayed_timer=None,
        )
        expected = gate.evaluate("clean", missing)
        supplemented = dict(
            missing,
            supplementary_native_bootstrap={"complete": True, "measurement": timer_cases.receipt()},
        )
        self.assertEqual(gate.evaluate("clean", supplemented), expected)
        self.assertTrue(any("required path refused" in failure for failure in expected))
        self.assertTrue(any("native delayed-timer" in failure for failure in expected))


if __name__ == "__main__":
    unittest.main()
