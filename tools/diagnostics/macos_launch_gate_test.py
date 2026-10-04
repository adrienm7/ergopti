# tools/diagnostics/macos_launch_gate_test.py
"""Prove the packaged launch verdict rejects every failure it exists to catch."""

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import hs_delayed_timer_probe as timer_probe
import hs_delayed_timer_probe_test as timer_probe_test
import hs_karabiner_config_probe as karabiner_probe

spec = importlib.util.spec_from_file_location(
    "launch_gate", Path(__file__).with_name("macos_launch_gate.py")
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def timer_summary():
    """Return the complete admission receipt produced by the native judge."""
    return {
        "schema_version": 1,
        "contract": timer_probe.CONTRACT["contract"],
        "runtime": "native Hammerspoon",
        "version": timer_probe.CONTRACT["runtime_version"],
        "complete": True,
        "checks": timer_probe.CHECK_COUNT,
        "nonce": "a" * 32,
        "pid": 42,
        "executable": "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon",
        "preference_restored": True,
    }


def control_summary():
    """Return an independent native transport acknowledgement, not feature proof."""
    return {
        "schema_version": 1,
        "contract": "hs.applescript.control",
        "phase": "control",
        "acknowledged": True,
        "nonce": "a" * 32,
        "pid": 42,
        "executable": "/Applications/ErgoptiPlus.app/Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon",
    }


HEALTHY = {
    "launcher_log": "[t] embedded Hammerspoon bootstrap logger configured\n",
    "driver_log": "[SUCCESS] [onboarding] Onboarding wizard opened.\n",
    "alive_after_window": True,
    "quit_seconds": 1.5,
    "state_problems": [],
    "native_delayed_timer": timer_summary(),
    "native_transport_control": control_summary(),
}


# The fallback boot log line every fatal Lua abort now writes before exiting.
REFUSED_BOOT_LOG = "t [ERROR] [init] FATAL at boot stage 'native_logger_transport': refused\n"


def observe(**changes):
    """Return a healthy observation with only the named criteria changed."""
    observation = dict(HEALTHY)
    observation.update(changes)
    return observation


class VerdictTests(unittest.TestCase):
    """Each criterion must fail on its own, and a healthy launch must pass."""

    def test_clean_launch_requires_native_timer_evidence(self):
        for value in (
            None,
            {},
            dict(timer_summary(), complete=False),
            dict(timer_summary(), preference_restored=False),
        ):
            with self.subTest(value=value):
                failures = gate.evaluate("clean", observe(native_delayed_timer=value))
                self.assertTrue(any("native delayed-timer" in failure for failure in failures))

    def test_karabiner_scenario_requires_actual_graph_and_existing_error_assertions(self):
        from hs_karabiner_config_probe_test import receipt, EXECUTABLE, NONCE, DOMAIN

        summary = karabiner_probe.validate_receipt(receipt(), NONCE, 42, EXECUTABLE, DOMAIN)
        summary["preference_restored"] = True
        self.assertEqual(
            gate.evaluate("karabiner_config", observe(native_karabiner_config=summary)), []
        )
        for changed in (
            None,
            dict(summary, private_source_restored=False),
            dict(summary, lease_initialized=True),
        ):
            self.assertTrue(
                gate.evaluate("karabiner_config", observe(native_karabiner_config=changed))
            )
        failures = gate.evaluate(
            "karabiner_config",
            observe(
                native_karabiner_config=summary,
                driver_log=HEALTHY["driver_log"] + "[ERROR] actual production refusal\n",
            ),
        )
        self.assertTrue(any("actual production refusal" in failure for failure in failures))

    def test_clean_launch_retains_native_probe_refusal(self):
        failures = gate.evaluate("clean", observe(native_delayed_timer_error="scripting refused"))
        self.assertTrue(any("scripting refused" in failure for failure in failures))

    def test_cli_annotates_the_failure_cause_without_weakening_its_exit(self):
        cause = "native scripting refused: 50%\r\n::notice::foreign text"
        report = {"failures": [cause]}
        with tempfile.TemporaryDirectory(prefix="ergopti-native-annotation-") as root:
            output = Path(root) / "evidence"
            stdout = io.StringIO()
            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate, "run", return_value=report),
                mock.patch.object(gate, "print_tails"),
                contextlib.redirect_stdout(stdout),
            ):
                status = gate.main(["/Applications/ErgoptiPlus.app", str(output), "clean"])
            self.assertEqual(status, 1, "annotating a cause must retain the negative verdict")
            self.assertEqual(
                stdout.getvalue().splitlines(),
                [
                    "::error::macOS launch gate [clean] failed",
                    "::error::native scripting refused: 50%25%0D%0A::notice::foreign text",
                ],
            )
            self.assertEqual(json.loads((output / "result.json").read_text())["failures"], [cause])

    def test_cli_retains_owned_native_context_beyond_the_annotation_limit(self):
        # GitHub renders at most4096 characters of one error annotation. The
        # sampled background ancestry is later than the complete primary cause.
        context = (
            "observed native Hammerspoon server thread: Thread_42\n" + "native ancestry\n" * 310
        )
        context += "TCCAccessRequest (native final frame)"
        cause = "native scripting TimeoutExpired: " + "p" * 4096 + context
        report = {
            "failures": [cause],
            "native_probe_diagnostics": [
                {"command": 2, "phase": "observation", "observations": context}
            ],
        }
        with tempfile.TemporaryDirectory(prefix="ergopti-native-plain-") as root:
            output = Path(root) / "evidence"
            stdout = io.StringIO()
            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate, "run", return_value=report),
                mock.patch.object(gate, "print_tails"),
                contextlib.redirect_stdout(stdout),
            ):
                status = gate.main(["/Applications/ErgoptiPlus.app", str(output), "clean"])
            self.assertEqual(status, 1)
            lines = stdout.getvalue().splitlines()
            plain = [
                line for line in lines if line.startswith("native probe command2 (observation): ")
            ]
            self.assertTrue(plain, "owned context must have a plain-log channel")
            self.assertIn(
                "native probe command2 (observation): TCCAccessRequest (native final frame)", plain
            )
            self.assertTrue(all(not line.startswith("::") for line in plain))
            self.assertEqual(json.loads((output / "result.json").read_text()), report)

    def test_plain_native_diagnostic_lines_cannot_inject_workflow_commands(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            gate.print_native_probe_diagnostics(
                {
                    "native_probe_diagnostics": [
                        {
                            "command": 1,
                            "phase": "observation",
                            "observations": "native frame\r\n::notice::foreign annotation\n%0A::error::text",
                        }
                    ],
                }
            )
        lines = stdout.getvalue().splitlines()
        self.assertEqual(
            lines,
            [
                "native probe command1 (observation): native frame",
                "native probe command1 (observation): ::notice::foreign annotation",
                "native probe command1 (observation): %0A::error::text",
            ],
        )

    def test_launch_report_retains_its_own_probe_diagnostics_after_refusal(self):
        for scenario in ("clean", "karabiner_config"):
            with tempfile.TemporaryDirectory(prefix="ergopti-owned-native-log-") as root:
                app, output = Path(root) / "ErgoptiPlus.app", Path(root) / "evidence"
                output.mkdir()
                child = timer_probe.NativeDelayedTimerProbe.executable_path(app)
                launcher = app / "Contents/MacOS/ErgoptiPlus"
                for executable in (launcher, child):
                    executable.parent.mkdir(parents=True, exist_ok=True)
                    executable.write_text("owned fixture executable")
                with (app / "Contents/Info.plist").open("wb") as handle:
                    plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
                owner_type = (
                    timer_probe.NativeDelayedTimerProbe
                    if scenario == "clean"
                    else karabiner_probe.NativeKarabinerConfigProbe
                )
                owner = owner_type(app, output, gate.HS_DOMAIN)
                live = {"started": False}

                def processes(executable):
                    return [42 if executable == child else 41] if live["started"] else []

                def native_run(arguments, **options):
                    if arguments[0] == "open":
                        live["started"] = True
                    return subprocess.CompletedProcess(arguments, 0, "arm64", "")

                def observe_native(pid, resolve):
                    self.assertEqual(pid, 42)
                    self.assertEqual(resolve(child), [42])
                    owner.scripting_command_number = 1
                    owner.retain_diagnostics(
                        ["observed native Hammerspoon server thread: Thread_42"]
                    )
                    raise RuntimeError("primary refusal with unrelated secret")

                def quit_native(*_):
                    live["started"] = False
                    return 0.5

                with (
                    mock.patch.object(gate.Path, "home", return_value=Path(root) / "home"),
                    mock.patch.object(gate, "seed", return_value={"logs_dir": Path(root) / "logs"}),
                    mock.patch.object(gate, owner_type.__name__, return_value=owner),
                    mock.patch.object(owner, "enable"),
                    mock.patch.object(
                        owner, "control", side_effect=RuntimeError("control refused")
                    ) as control,
                    mock.patch.object(
                        owner, "constructor_control", return_value={"constructed": "only"}
                    ) as constructor,
                    mock.patch.object(
                        owner, "control_pid", return_value={"diagnostic": "only"}
                    ) as pid_control,
                    mock.patch.object(
                        owner, "control_pid_no_prompt", create=True, return_value={"status": -1744}
                    ) as no_prompt,
                    mock.patch.object(owner, "observe", side_effect=observe_native),
                    mock.patch.object(owner, "restore"),
                    mock.patch.object(gate, "processes", side_effect=processes) as resolver,
                    mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                    mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                    mock.patch.object(gate, "read_text", return_value=HEALTHY["launcher_log"]),
                    mock.patch.object(gate, "driver_logs", return_value=HEALTHY["driver_log"]),
                    mock.patch.object(gate, "check_state", return_value=[]),
                    mock.patch.object(gate, "quit_application", side_effect=quit_native),
                    mock.patch.object(gate, "collect", return_value={"errors": [], "windows": {}}),
                ):
                    report = gate.run(app, output, scenario, "")
                self.assertEqual(report["native_probe_diagnostics"], owner.diagnostic_receipts)
                control.assert_called_once_with(42, resolver)
                constructor.assert_called_once_with(42, resolver)
                self.assertEqual(report["native_descriptor_constructor"], {"constructed": "only"})
                pid_control.assert_called_once_with(42, resolver)
                self.assertEqual(report["native_pid_transport_control"], {"diagnostic": "only"})
                no_prompt.assert_called_once_with(42, resolver)
                self.assertEqual(report["native_pid_no_prompt_control"], {"status": -1744})
                self.assertEqual(len(report["failures"]), 2)
                self.assertIn("control refused", report["failures"][0])
                self.assertIn("primary refusal", report["failures"][1])
                self.assertNotIn("unrelated secret", str(report["native_probe_diagnostics"]))
                self.assertEqual(report["quit_seconds"], 0.5)

    def test_primary_control_error_is_printed_even_when_native_samples_exist(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            gate.print_native_probe_diagnostics(
                {
                    "native_probe_diagnostics": [
                        {
                            "command": 3,
                            "phase": "pid_no_prompt",
                            "observations": "native frame",
                            "primary_error": "Native status -1743\n::error::foreign annotation",
                        }
                    ]
                }
            )
        self.assertEqual(
            stdout.getvalue().splitlines(),
            [
                "native probe command3 (pid_no_prompt): primary error: Native status -1743",
                "native probe command3 (pid_no_prompt): primary error: ::error::foreign annotation",
                "native probe command3 (pid_no_prompt): native frame",
            ],
        )

    def test_successful_feature_proofs_cannot_hide_native_control_refusal(self):
        from hs_karabiner_config_probe_test import receipt, EXECUTABLE, NONCE, DOMAIN

        summary = karabiner_probe.validate_receipt(receipt(), NONCE, 42, EXECUTABLE, DOMAIN)
        summary["preference_restored"] = True
        for scenario in ("clean", "karabiner_config"):
            with self.subTest(scenario=scenario):
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_karabiner_config=summary,
                        native_transport_control_error="actual control owner refused",
                    ),
                )
                self.assertTrue(any("actual control owner refused" in value for value in failures))
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_karabiner_config=summary,
                        native_transport_control=None,
                    ),
                )
                self.assertTrue(any("control" in value for value in failures))

    def test_constructor_cannot_replace_original_path_pid_or_feature_proofs(self):
        constructed = timer_probe.validate_constructor_receipt(
            json.dumps(timer_probe_test.constructor_receipt()) + "\n",
            timer_probe_test.NONCE,
            42,
            timer_probe_test.constructor_receipt()["direct_text"],
        )
        for scenario, feature in (
            ("clean", "native_delayed_timer"),
            ("karabiner_config", "native_karabiner_config"),
        ):
            with self.subTest(scenario=scenario):
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_descriptor_constructor=constructed,
                        native_transport_control_error="original control refusal",
                        **{feature + "_error": "original feature refusal"},
                    ),
                )
                self.assertTrue(any("original control refusal" in value for value in failures))
                self.assertTrue(any("original feature refusal" in value for value in failures))
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_descriptor_constructor=constructed,
                        native_transport_control=constructed,
                        **{feature: None},
                    ),
                )
                self.assertTrue(any("control" in value for value in failures))
                self.assertTrue(any("proof is incomplete" in value for value in failures))
        with self.assertRaises(ValueError):
            timer_probe.validate_pid_control_summary(constructed)

    def test_pid_diagnostic_cannot_replace_path_control_or_original_feature(self):
        alternative = dict(
            control_summary(), contract="hs.applescript.pid-control", phase="pid_control"
        )
        for scenario, feature in (
            ("clean", "native_delayed_timer"),
            ("karabiner_config", "native_karabiner_config"),
        ):
            with self.subTest(scenario=scenario):
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_pid_transport_control=alternative,
                        native_transport_control_error="original path refusal",
                        **{feature + "_error": "original feature refusal"},
                    ),
                )
                self.assertTrue(any("original path refusal" in value for value in failures))
                self.assertTrue(any("original feature refusal" in value for value in failures))
                failures = gate.evaluate(
                    scenario,
                    observe(
                        native_transport_control=alternative,
                        native_pid_transport_control=alternative,
                        **{feature: None},
                    ),
                )
                self.assertTrue(any("control" in value for value in failures))
                self.assertTrue(any("proof is incomplete" in value for value in failures))

    def test_control_receipt_cannot_substitute_for_missing_native_feature_proofs(self):
        for scenario, field in (
            ("clean", "native_delayed_timer"),
            ("karabiner_config", "native_karabiner_config"),
        ):
            with self.subTest(scenario=scenario):
                failures = gate.evaluate(scenario, observe(**{field: None}))
                self.assertTrue(failures)
                self.assertFalse(
                    any("control" in value for value in failures),
                    "the valid control remains separate from the absent feature proof",
                )

    def test_healthy_launch_passes(self):
        self.assertEqual(gate.evaluate("clean", observe()), [])

    def test_window_timeout_does_not_discard_other_native_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "home"
            home.mkdir()
            output = Path(folder) / "output"
            output.mkdir()
            calls = []

            def native_run(arguments, **options):
                calls.append(arguments[0])
                if arguments[0] == "osascript":
                    raise subprocess.TimeoutExpired(arguments, options["timeout"])
                return subprocess.CompletedProcess(arguments, 0, "retained native evidence", "")

            with (
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "processes", return_value=[42]),
            ):
                collected = gate.collect(
                    output,
                    {"logs_dir": home / "missing-logs"},
                    home,
                    (Path("/private/owned/Hammerspoon"),),
                )
            self.assertEqual(collected["errors"], [])
            self.assertEqual(collected["windows"]["status"], "unavailable")
            self.assertFalse(collected["windows"]["ui_qualified"])
            self.assertIn("TimeoutExpired", collected["windows"]["observations"][0]["cause"])
            self.assertIn("TimeoutExpired", (output / "windows.txt").read_text())
            self.assertIn(
                "log", calls, "the window timeout must not prevent unified-log collection"
            )
            self.assertEqual((output / "unified.log").read_text(), "retained native evidence")

    def test_successful_quit_attests_exact_owned_process_absence_without_global_ax_query(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            owners = (
                Path("/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"),
                timer_probe.NativeDelayedTimerProbe.executable_path(
                    Path("/Applications/ErgoptiPlus.app")
                ),
            )
            with (
                mock.patch.object(gate, "processes", return_value=[]) as resolve,
                mock.patch.object(gate.subprocess, "run") as native,
            ):
                receipt = gate.collect_owned_windows(output, owners)
            self.assertEqual(resolve.call_args_list, [mock.call(path) for path in owners])
            native.assert_not_called()
            self.assertEqual(receipt["status"], "not_running")
            self.assertFalse(
                receipt["ui_qualified"], "process absence is not qualified window inspection"
            )
            self.assertEqual(
                receipt["owners"], [{"executable": str(path), "pids": []} for path in owners]
            )
            self.assertEqual(receipt["observations"], [])
            self.assertEqual(json.loads((output / "windows.json").read_text()), receipt)
            self.assertEqual(gate.evaluate("symlink_logs", observe()), [])

    def test_window_properties_are_extracted_after_binding_exact_live_pid(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            scripts = []

            def native_run(arguments, **options):
                script = arguments[2]
                scripts.append((script, options["timeout"]))
                if "whose background only" in script:
                    return subprocess.CompletedProcess(
                        arguments,
                        1,
                        "",
                        "Can't get materialized lists whose background only=false. (-1728)",
                    )
                return subprocess.CompletedProcess(arguments, 0, "Hammerspoon, Owned window", "")

            with (
                mock.patch.object(gate, "processes", return_value=[42]),
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
            ):
                receipt = gate.collect_owned_windows(output, (Path("/private/owned/Hammerspoon"),))
            self.assertEqual(receipt["status"], "observed")
            self.assertTrue(receipt["ui_qualified"])
            self.assertEqual(len(scripts), 1)
            self.assertIn(
                "set ownedProcess to first process whose unix id is 42\ntell ownedProcess",
                scripts[0][0],
            )
            self.assertNotIn("every process", scripts[0][0])
            self.assertNotIn("background only", scripts[0][0])
            self.assertGreater(scripts[0][1], 0)
            self.assertLessEqual(scripts[0][1], 30)
            self.assertEqual(receipt["observations"][0]["stdout"], "Hammerspoon, Owned window")

    def test_accessibility_refusal_retains_cause_without_fabricating_missing_app_windows(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder)
            refusal = "System Events: osascript is not allowed assistive access. (-25211)"
            with (
                mock.patch.object(gate, "processes", return_value=[42]),
                mock.patch.object(
                    gate.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 1, "", refusal),
                ),
            ):
                receipt = gate.collect_owned_windows(output, (Path("/private/owned/Hammerspoon"),))
            self.assertEqual(receipt["status"], "unavailable")
            self.assertFalse(receipt["ui_qualified"])
            self.assertEqual(receipt["observations"][0]["stderr"], refusal)
            self.assertEqual(receipt["observations"][0]["exit_status"], 1)
            self.assertEqual(gate.evaluate("symlink_logs", observe(owned_windows=receipt)), [])
            self.assertTrue(
                gate.evaluate("symlink_logs", observe(owned_windows=receipt, quit_seconds=None))
            )
            self.assertTrue(
                gate.evaluate(
                    "symlink_logs",
                    observe(owned_windows=receipt, driver_log="[ERROR] actual application failure"),
                )
            )
            self.assertTrue(
                gate.evaluate("clean", observe(owned_windows=receipt, native_delayed_timer=None))
            )

    def test_owned_pid_exit_during_query_never_qualifies_stale_window_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            with (
                mock.patch.object(gate, "processes", side_effect=[[42], [42], []]),
                mock.patch.object(
                    gate.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0, "stale window", ""),
                ),
            ):
                receipt = gate.collect_owned_windows(
                    Path(folder), (Path("/private/owned/Hammerspoon"),)
                )
            self.assertEqual(receipt["status"], "unavailable")
            self.assertFalse(receipt["ui_qualified"])
            self.assertIn("changed", receipt["observations"][0]["cause"])

    def test_two_owned_window_queries_share_the_original_total_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            with (
                mock.patch.object(gate.time, "monotonic", side_effect=[0, 1, 31]),
                mock.patch.object(gate, "processes", return_value=[42]),
                mock.patch.object(
                    gate.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([], 0, "owned window", ""),
                ) as native,
            ):
                receipt = gate.collect_owned_windows(
                    Path(folder),
                    (Path("/private/owned/Launcher"), Path("/private/owned/Hammerspoon")),
                )
            self.assertEqual(native.call_count, 1)
            self.assertEqual(native.call_args.kwargs["timeout"], 29)
            self.assertEqual(receipt["status"], "unavailable")
            self.assertIn("30 s budget", receipt["observations"][1]["cause"])

    def test_quit_and_collection_failures_still_write_primary_report(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder) / "home"
            app = Path(folder) / "ErgoptiPlus.app"
            for executable in (
                app / "Contents/MacOS/ErgoptiPlus",
                timer_probe.NativeDelayedTimerProbe.executable_path(app),
            ):
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("owned fixture executable")
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
            live = {"started": False}
            killed = []

            def processes(executable):
                return [42 if executable.name == "Hammerspoon" else 41] if live["started"] else []

            def native_run(arguments, **options):
                if arguments[0] == "open":
                    live["started"] = True
                return subprocess.CompletedProcess(arguments, 0, "arm64", "")

            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate.Path, "home", return_value=home),
                mock.patch.object(
                    gate, "seed", return_value={"logs_dir": home / "logs", "symlinks": []}
                ),
                mock.patch.object(gate, "processes", side_effect=processes),
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                mock.patch.object(gate, "read_text", return_value=HEALTHY["launcher_log"]),
                mock.patch.object(gate, "driver_logs", return_value=HEALTHY["driver_log"]),
                mock.patch.object(gate, "check_state", return_value=[]),
                mock.patch.object(
                    gate, "quit_application", side_effect=RuntimeError("original quit failure")
                ),
                mock.patch.object(
                    gate, "collect", side_effect=RuntimeError("independent collection failure")
                ),
                mock.patch.object(gate.os, "kill", side_effect=lambda pid, _: killed.append(pid)),
                mock.patch.object(gate, "print_tails"),
                contextlib.redirect_stdout(io.StringIO()),
            ):
                status = gate.main([str(app), str(Path(folder) / "evidence"), "symlink_logs_dir"])
            report = json.loads((Path(folder) / "evidence/result.json").read_text())
            self.assertEqual(status, 1)
            self.assertIn("RuntimeError: original quit failure", report["failures"])
            self.assertTrue(
                any("independent collection failure" in error for error in report["failures"])
            )
            self.assertEqual(
                sorted(killed),
                [41, 42],
                "failed evidence collection must still stop both exact processes",
            )

    def test_published_symlink_failure_is_rejected(self):
        # The exact launcher.log of the reported dev.127 failure.
        failures = gate.evaluate(
            "symlink_logs",
            observe(
                launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertTrue(any("acknowledged" in failure for failure in failures))
        self.assertTrue(any("FATAL" in failure for failure in failures))
        self.assertTrue(any("no driver log" in failure for failure in failures))

    def test_environment_key_named_fatal_is_not_a_fatal_line(self):
        # The boot log lists the launcher environment, which has ERGOPTI_FATAL_REPORT_FILE.
        healthy = observe()
        failures = gate.evaluate(
            "clean",
            observe(
                launcher_log=healthy["launcher_log"]
                + "[t] embedded Hammerspoon boot INFO: Launcher environment keys present: "
                "ERGOPTI_CONFIG_DIR, ERGOPTI_FATAL_REPORT_FILE.\n"
            ),
        )
        self.assertEqual(failures, [])

    def test_early_log_without_marker_is_not_startup(self):
        failures = gate.evaluate("clean", observe(driver_log="Path: log file open\n"))
        self.assertEqual(failures, ["the driver log has no completed startup marker"])

    def test_driver_error_invalidates_marker(self):
        failures = gate.evaluate(
            "clean", observe(driver_log="Onboarding wizard opened.\n[ERROR] [x] later failure\n")
        )
        self.assertEqual(len(failures), 1)
        self.assertIn("ERROR", failures[0])

    def test_process_death_after_marker_is_rejected(self):
        failures = gate.evaluate("clean", observe(alive_after_window=False, quit_seconds=None))
        self.assertEqual(len(failures), 2)

    def test_hanging_quit_is_rejected(self):
        failures = gate.evaluate("clean", observe(quit_seconds=None))
        self.assertEqual(
            failures, [f"Quit did not end both processes within {gate.QUIT_TIMEOUT_SECONDS} s"]
        )

    def test_refused_state_needs_a_named_reason(self):
        generic = observe(
            launcher_log="[t] FATAL: Embedded Hammerspoon stopped unexpectedly with exit code 0.\n",
            boot_log=REFUSED_BOOT_LOG,
            alive_after_window=False,
        )
        self.assertEqual(len(gate.evaluate("dangling_logs", generic)), 1)
        named = observe(
            launcher_log="[t] FATAL: log folder /u/gitcfg/ergopti_plus is a "
            "symbolic link whose target does not exist\n",
            boot_log=REFUSED_BOOT_LOG,
            alive_after_window=False,
        )
        self.assertEqual(gate.evaluate("dangling_logs", named), [])

    def test_refused_state_must_not_keep_running(self):
        observation = observe(
            launcher_log="FATAL: gitcfg/ergopti_plus is a symbolic link to nothing\n",
            boot_log=REFUSED_BOOT_LOG,
        )
        self.assertEqual(len(gate.evaluate("dangling_logs", observation)), 1)

    def test_published_silent_configured_exit_is_rejected(self):
        # The exact dev.128 shape: logger configured, child gone, no FATAL, no dialog.
        failures = gate.evaluate(
            "configured_symlink",
            observe(
                launcher_log="[t] embedded Hammerspoon bootstrap logger configured\n"
                "[t] embedded Hammerspoon terminated\n"
                "[t] applicationWillTerminate; stopping embedded Hammerspoon\n",
                boot_log="[SUCCESS] [config_paths] Config paths initialized\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertIn("no driver log appeared under the configured logs folder", failures)
        self.assertIn(
            "the launcher and embedded Hammerspoon did not both survive the observation window",
            failures,
        )

    def test_configured_boot_waits_for_accessibility(self):
        waiting = observe(
            driver_log="[INFO] [accessibility_wait] Waiting for the Accessibility "
            "permission (up to 600 s)…\n"
        )
        self.assertEqual(gate.evaluate("configured_symlink", waiting), [])
        self.assertEqual(gate.ready_marker("clean"), gate.READY_MARKER)

    def test_configured_accessibility_exit_is_rejected(self):
        # The dev.141 shape: a named FATAL exit that sent the user to relaunch.
        failures = gate.evaluate(
            "configured_symlink",
            observe(
                launcher_log="[t] embedded Hammerspoon bootstrap logger configured\n"
                "[t] FATAL: Embedded Hammerspoon stopped at boot stage 'accessibility': untrusted\n",
                boot_log="t [ERROR] [init] FATAL at boot stage 'accessibility': untrusted\n",
                driver_log="",
                alive_after_window=False,
                quit_seconds=None,
            ),
        )
        self.assertTrue(any("FATAL" in failure for failure in failures))
        self.assertTrue(any("survive" in failure for failure in failures))

    def test_plain_open_launches_like_a_double_click(self):
        app = Path("/Applications/ErgoptiPlus.app")
        self.assertEqual(gate.launch_command("plain_open", app), ["open", str(app)])
        self.assertEqual(gate.launch_command("clean", app), ["open", "-n", str(app)])
        self.assertIn("plain_open", gate.SCENARIOS)
        self.assertIn("configured_symlink", gate.SCENARIOS)


class StateTests(unittest.TestCase):
    """The application must never rewrite the user's own folder layout."""

    def test_configured_state_has_a_completed_config_behind_a_symlink(self):
        self.assertTrue(gate.CONFIG_TEMPLATE.is_file(), gate.CONFIG_TEMPLATE)
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            try:
                state = gate.seed("configured_symlink", home, "", "2026-09-22")
            except OSError as error:
                self.skipTest(f"symbolic links unavailable here: {error}")
            default = home / ".config/ergopti_plus"
            self.assertTrue(default.is_symlink())
            self.assertTrue((default / "hammerspoon/config.toml").is_file())
            self.assertEqual(state["symlinks"], [str(default)])

    def test_logs_scenarios_seed_logs_dir_path(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            synced_home = home / "synced"
            dangling_home = home / "dangling"
            try:
                synced = gate.seed("symlink_logs_dir", synced_home, "", "2026-09-24")
                dangling = gate.seed("dangling_logs", dangling_home, "", "2026-09-24")
            except OSError as error:
                self.skipTest(f"symbolic links unavailable here: {error}")
            self.assertNotEqual(synced["paths_toml"], dangling["paths_toml"])
            self.assertEqual(synced["logs_dir"], synced_home / "SyncedLogs/ergopti_plus")
            self.assertIn(
                f'LogsDirPath = "{synced_home}/SyncedLogs"',
                synced["paths_toml"].read_text(encoding="utf-8"),
            )
            self.assertIn(
                f'LogsDirPath = "{dangling_home}/gitcfg/ergopti_plus"',
                dangling["paths_toml"].read_text(encoding="utf-8"),
            )
            self.assertTrue((synced_home / "SyncedLogs").is_symlink())
            self.assertTrue((dangling_home / "gitcfg/ergopti_plus").is_symlink())
            self.assertFalse((dangling_home / "gitcfg/ergopti_plus").exists())
            self.assertIn("symlink_logs_dir", gate.SCENARIOS)
            self.assertEqual(gate.logs_folder(home), home / "Library/Logs/ergopti_plus")

    def test_picked_logs_folder_losing_its_permissions_is_reported(self):
        if os.name != "posix":
            self.skipTest("POSIX permission bits are unavailable here")
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            picked = home / "picked"
            picked.mkdir()
            picked.chmod(0o755)
            state = {"symlinks": [], "foreign_folder": (picked, 0o755)}
            self.assertEqual(gate.check_state("symlink_logs_dir", state, home), [])
            state["foreign_folder"] = (picked, 0o700)
            self.assertEqual(len(gate.check_state("symlink_logs_dir", state, home)), 1)

    def test_replaced_symlink_and_unpersisted_tilde_are_reported(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            real = home / "real"
            real.mkdir()
            paths = gate.write_paths_toml(home, "~/gitcfg/ergopti_plus/")
            state = {"symlinks": [str(real)], "paths_toml": paths}
            problems = gate.check_state("tilde_paths", state, home)
            self.assertEqual(len(problems), 2)
            paths.write_text(f'ConfigDirPath = "{home}/gitcfg/ergopti_plus/"\n', encoding="utf-8")
            link = home / "link"
            try:
                link.symlink_to(real, target_is_directory=True)
            except OSError as error:
                # Only Windows refuses an unprivileged symbolic link. On the macOS
                # job that runs this self-test, a failure here is a real error.
                if sys.platform != "win32":
                    raise
                self.skipTest(f"symbolic links unavailable here: {error}")
            state["symlinks"] = [str(link)]
            self.assertEqual(gate.check_state("tilde_paths", state, home), [])


# Keep independent oracles for every approved scenario, including the picked
# logs-directory link added when launcher and driver log ownership converged.
CI_PROFILE = [
    "clean",
    "karabiner_config",
    "upgraded",
    "symlink_config",
    "symlink_hammerspoon",
    "symlink_logs",
    "symlink_logs_dir",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
]
RELEASE_PROFILE = [
    "clean",
    "karabiner_config",
    "upgraded",
    "source_logs",
    "symlink_config",
    "symlink_config_documents",
    "symlink_hammerspoon",
    "symlink_logs",
    "symlink_logs_dir",
    "tilde_paths",
    "dangling_logs",
    "configured_symlink",
    "plain_open",
]
SCRIPT = Path(__file__).with_name("macos_launch_gate.py")


def print_matrix(*arguments):
    """Run the matrix mode the way the workflow does, outside GitHub Actions."""
    env = {key: value for key, value in os.environ.items() if key != "GITHUB_ACTIONS"}
    return subprocess.run(
        [sys.executable, str(SCRIPT), *arguments],
        capture_output=True,
        text=True,
        env=env,
        timeout=60,
    )


class ProfileTests(unittest.TestCase):
    """The workflow's launch matrix comes from these profiles alone, so they must not drift."""

    def test_ci_profile_keeps_the_approved_gated_scenarios(self):
        self.assertEqual(
            list(gate.PROFILES["ci"]),
            CI_PROFILE,
            "the CI launch profile changed; update CI_PROFILE only for a deliberate change",
        )

    def test_release_profile_launches_every_scenario(self):
        self.assertEqual(gate.PROFILES["release"], gate.SCENARIOS)
        self.assertEqual(
            list(gate.SCENARIOS),
            RELEASE_PROFILE,
            "the release scenarios changed; update this oracle only for a deliberate change",
        )

    def test_ci_profile_is_a_strict_subset_of_release(self):
        self.assertLess(set(gate.PROFILES["ci"]), set(gate.PROFILES["release"]))
        self.assertLessEqual(set(gate.RELEASE_ONLY_SCENARIOS), set(gate.SCENARIOS))

    def test_print_matrix_emits_one_output_line_off_macos(self):
        # GITHUB_ACTIONS is removed, so the launch guard would refuse this run
        # on every host if the matrix mode reached it.
        for profile in ("ci", "release"):
            result = print_matrix("--print-matrix", profile)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(len(lines), 1, result.stdout)
            key, _, value = lines[0].partition("=")
            self.assertEqual(key, "scenarios")
            self.assertEqual(json.loads(value), list(gate.PROFILES[profile]))

    def test_print_matrix_rejects_unknown_profiles_and_launch_arguments(self):
        for arguments in (
            ("--print-matrix", "nightly"),
            ("--print-matrix", "ci", "/Applications/ErgoptiPlus.app"),
            ("--print-matrix", "release", "--seed-tag", "v0.0.0-dev.24"),
        ):
            result = print_matrix(*arguments)
            self.assertEqual(result.returncode, 2, arguments)
            self.assertEqual(result.stdout, "", arguments)

    def test_launch_mode_still_needs_all_its_arguments(self):
        result = print_matrix("/Applications/ErgoptiPlus.app", "evidence")
        self.assertEqual(result.returncode, 2)
        self.assertIn("app, output and scenario", result.stderr)


def load_tests(loader, tests, pattern):
    """Keep native receipt and preference checks in the existing package self-test."""
    import hs_delayed_timer_probe_test
    import hs_karabiner_config_probe_test
    import hs_native_bootstrap_probe_test

    tests.addTests(loader.loadTestsFromModule(hs_delayed_timer_probe_test))
    tests.addTests(loader.loadTestsFromModule(hs_karabiner_config_probe_test))
    tests.addTests(loader.loadTestsFromModule(hs_native_bootstrap_probe_test))
    return tests


class EarlyLuaJournalObservationTests(unittest.TestCase):
    """Early location evidence cannot change any mandatory launch verdict."""

    def test_actual_run_reads_only_its_owned_journal_after_original_refusals(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app, output, home = root / "app", root / "evidence", root / "home"
            child = timer_probe.NativeDelayedTimerProbe.executable_path(app)
            for executable in (app / "Contents/MacOS/ErgoptiPlus", child):
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("inert native fixture executable")
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
            output.mkdir()
            logs = gate.logs_folder(home)
            logs.mkdir(parents=True)
            owner = timer_probe.NativeDelayedTimerProbe(app, output, gate.HS_DOMAIN)
            owner.nonce = "a" * 32
            live = {"started": False}

            def processes(executable):
                return [42 if executable == child else 41] if live["started"] else []

            def native_run(arguments, **options):
                if arguments[0] == "open":
                    live["started"] = True
                    (logs / gate.LAUNCHER_LOG_NAME).write_text(HEALTHY["launcher_log"])
                    (logs / gate.FALLBACK_BOOT_LOG_NAME).write_text(
                        "2026-10-04 00:00:00 [INFO] [init] Native scripting Lua body stage: "
                        "phase=received_lua_body; pid=42; nonce=" + owner.nonce + ".\n"
                    )
                return subprocess.CompletedProcess(arguments, 0, "arm64", "")

            def refuse_feature(pid, resolve):
                owner.bind_runtime(pid, resolve)
                raise RuntimeError("original feature refused")

            def quit_owned(*arguments):
                live["started"] = False
                return 0.5

            with (
                mock.patch.object(gate.Path, "home", return_value=home),
                mock.patch.object(gate, "seed", return_value={"logs_dir": logs}),
                mock.patch.object(gate, "NativeDelayedTimerProbe", return_value=owner),
                mock.patch.object(owner, "enable"),
                mock.patch.object(
                    owner, "control", side_effect=RuntimeError("original control refused")
                ),
                mock.patch.object(
                    owner, "constructor_control", return_value={"constructed": "only"}
                ),
                mock.patch.object(
                    owner, "control_pid", side_effect=RuntimeError("original PID refused")
                ),
                mock.patch.object(owner, "control_pid_no_prompt", return_value={"status": -1712}),
                mock.patch.object(owner, "observe", side_effect=refuse_feature),
                mock.patch.object(owner, "restore"),
                mock.patch.object(gate, "processes", side_effect=processes),
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                mock.patch.object(gate, "driver_logs", return_value=HEALTHY["driver_log"]),
                mock.patch.object(gate, "check_state", return_value=[]),
                mock.patch.object(gate, "quit_application", side_effect=quit_owned),
                mock.patch.object(gate, "collect", return_value={"errors": [], "windows": {}}),
                mock.patch.object(
                    gate.SupplementaryNativeBootstrap,
                    "observe",
                    side_effect=RuntimeError("supplement refused"),
                ),
            ):
                report = gate.run(app, output, "clean", "")
            stage = report["supplementary_received_lua_stage"]
            self.assertEqual(stage["body_stage"], "observed")
            self.assertFalse(stage["qualified"])
            self.assertEqual(stage["publication_ack"], "unobserved")
            self.assertEqual(stage["timing"], "unknown")
            self.assertTrue(
                any("original control refused" in error for error in report["failures"])
            )
            self.assertTrue(
                any("original feature refused" in error for error in report["failures"])
            )
            self.assertEqual(report["quit_seconds"], 0.5)

    def test_closed_plain_output_carries_no_journal_payload_and_never_qualifies(self):
        with io.StringIO() as output, contextlib.redirect_stdout(output):
            gate.print_native_probe_diagnostics(
                {
                    "supplementary_received_lua_stage": {
                        "body_stage": "observed",
                        "publication_ack": "unobserved",
                        "timing": "unknown",
                        "qualified": False,
                        "private": "PRIVATE_SHOULD_NOT_PRINT",
                    }
                }
            )
            printed = output.getvalue()
        self.assertIn(
            "stage=observed; publication_ack=unobserved; timing=unknown; qualified=false",
            printed,
        )
        self.assertNotIn("PRIVATE_SHOULD_NOT_PRINT", printed)

    def test_observed_stage_cannot_satisfy_transport_feature_or_cleanup(self):
        for scenario in ("clean", "karabiner_config"):
            before = observe(
                native_delayed_timer=None,
                native_karabiner_config=None,
                native_transport_control_error="controlled native transport refusal",
            )
            expected = gate.evaluate(scenario, before)
            self.assertTrue(expected)
            after = dict(
                before,
                supplementary_received_lua_stage={
                    "body_stage": "observed",
                    "publication_ack": "unobserved",
                    "timing": "unknown",
                    "qualified": False,
                },
            )
            self.assertEqual(gate.evaluate(scenario, after), expected)
            after["quit_seconds"] = None
            self.assertTrue(gate.evaluate(scenario, after))


if __name__ == "__main__":
    unittest.main()
