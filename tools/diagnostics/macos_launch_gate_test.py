# tools/diagnostics/macos_launch_gate_test.py
"""Prove the packaged launch verdict rejects every failure it exists to catch."""

import importlib.util
import contextlib
import copy
import gzip
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import hs_delayed_timer_probe as timer_probe
import hs_karabiner_config_probe as karabiner_probe
import hs_native_bootstrap_probe as bootstrap

spec = importlib.util.spec_from_file_location(
    "launch_gate", Path(__file__).with_name("macos_launch_gate.py")
)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

EXECUTABLE = timer_probe.INSTALLED_EXECUTABLE
PRODUCT = {
    "executable": EXECUTABLE,
    "bundle_id": gate.HS_DOMAIN,
    "version": timer_probe.CONTRACT["runtime_version"],
    "codesign_verified": True,
    "module_tree_sha256": "c" * 64,
}


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
        "executable": EXECUTABLE,
        "preference_restored": True,
    }


def karabiner_summary():
    """Return the measured graph proof of the real Karabiner receipt judge."""
    from hs_karabiner_config_probe_test import receipt, NONCE, DOMAIN

    measured = dict(receipt(), executable=EXECUTABLE)
    summary = karabiner_probe.validate_receipt(measured, NONCE, 42, EXECUTABLE, DOMAIN)
    summary["preference_restored"] = True
    return summary


def startup_summary(feature, measurement, nonce="d" * 32, pid=44):
    """Return one startup-file bootstrap summary bound to the verified product."""
    return {
        "schema_version": 1,
        "contract": bootstrap.CONTRACT,
        "feature": feature,
        "qualification": bootstrap.QUALIFICATION,
        "admission": "owned startup file",
        "identity": {
            "schema_version": 1,
            "contract": bootstrap.CONTRACT,
            "phase": "ready",
            "nonce": nonce,
            "pid": pid,
            "executable": EXECUTABLE,
            "bundle_id": gate.HS_DOMAIN,
            "version": timer_probe.CONTRACT["runtime_version"],
        },
        "measurement": measurement,
        "installed_product": dict(PRODUCT),
        "cleanup_acknowledged": True,
        "process_retired": True,
        "preference_restored": True,
    }


def script_summary():
    """Return a complete Script SDK/participant summary from a fresh exact owner."""
    return startup_summary(
        "script_scope",
        {
            "contract": "script.scope-native",
            "runtime": "native Hammerspoon",
            "publication_scope": "private-file-and-nonce-settings-only",
            "alias_count": 3,
            "sdk_void_set": True,
            "sdk_clear": True,
            "participant_inverse": True,
            "nonce": "e" * 32,
            "pid": 45,
            "executable": EXECUTABLE,
        },
        nonce="e" * 32,
        pid=45,
    )


def consent_boundary(**changes):
    """Return the owned sender's exact consent-step answer for the launched runtime."""
    receipt = {
        "schema_version": 1,
        "contract": gate.CONSENT_CONTRACT,
        "mode": gate.CONSENT_SENDER_MODE,
        "pid": 42,
        "executable": EXECUTABLE,
        "exit_status": 0,
        "stdout": "native_appleevent_status=-1744\n",
        "stderr": "",
    }
    receipt.update(changes)
    return receipt


def scripting_line(pid=42, getter="boolean", allowed="true", bridge="callable"):
    """Return the boot-journal line adapters/boot_journal.lua writes at startup."""
    return (
        "2026-10-18 00:00:00 [INFO] [init] Native scripting server: "
        f"pid={pid}; getter={getter}; allowed={allowed}; bridge={bridge}; "
        "handler_registration=unobserved; handler_entry=unobserved.\n"
    )


HEALTHY = {
    "launcher_log": "[t] embedded Hammerspoon bootstrap logger configured\n",
    "driver_log": "[SUCCESS] [onboarding] Onboarding wizard opened.\n",
    "alive_after_window": True,
    "quit_seconds": 1.5,
    "state_problems": [],
    "boot_log": "2026-10-18 00:00:00 [INFO] [init] boot started\n" + scripting_line(),
    "installed_product": dict(PRODUCT),
    "native_child_pid": 42,
    "appleevent_consent_boundary": consent_boundary(),
    "native_startup_bootstrap": startup_summary("delayed_timer", timer_summary()),
    "native_delayed_timer": timer_summary(),
}


# The fallback boot log line every fatal Lua abort now writes before exiting.
REFUSED_BOOT_LOG = "t [ERROR] [init] FATAL at boot stage 'native_logger_transport': refused\n"


def observe(**changes):
    """Return a healthy observation with only the named criteria changed."""
    observation = copy.deepcopy(HEALTHY)
    observation.update(changes)
    return observation


def karabiner_observation(**changes):
    """Return a healthy karabiner_config observation with the named criteria changed."""
    summary = karabiner_summary()
    observation = observe(
        native_startup_bootstrap=startup_summary("karabiner_config", summary),
        native_karabiner_config=summary,
        native_script_scope=script_summary(),
    )
    observation.pop("native_delayed_timer")
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

    def test_karabiner_scenario_requires_graph_script_scope_and_existing_error_assertions(self):
        self.assertEqual(gate.evaluate("karabiner_config", karabiner_observation()), [])
        summary = karabiner_summary()
        for changed in (
            None,
            dict(summary, private_source_restored=False),
            dict(summary, lease_initialized=True),
        ):
            self.assertTrue(
                gate.evaluate(
                    "karabiner_config", karabiner_observation(native_karabiner_config=changed)
                )
            )
        for script in (
            None,
            dict(script_summary(), preference_restored=False),
            dict(script_summary(), installed_product=dict(PRODUCT, module_tree_sha256="f" * 64)),
        ):
            with self.subTest(script=script):
                failures = gate.evaluate(
                    "karabiner_config", karabiner_observation(native_script_scope=script)
                )
                self.assertTrue(any("Script SDK/participant" in value for value in failures))
        failures = gate.evaluate(
            "karabiner_config",
            karabiner_observation(native_script_scope_error="RuntimeError: script owner refused"),
        )
        self.assertTrue(any("script owner refused" in value for value in failures))
        failures = gate.evaluate(
            "karabiner_config",
            karabiner_observation(
                driver_log=HEALTHY["driver_log"] + "[ERROR] actual production refusal\n"
            ),
        )
        self.assertTrue(any("actual production refusal" in failure for failure in failures))

    def test_clean_launch_retains_startup_bootstrap_refusal(self):
        failures = gate.evaluate(
            "clean", observe(native_startup_bootstrap_error="RuntimeError: startup refused")
        )
        self.assertTrue(any("startup refused" in failure for failure in failures))

    def test_startup_bootstrap_must_observe_the_verified_installed_product(self):
        foreign = startup_summary("delayed_timer", timer_summary())
        foreign["installed_product"]["module_tree_sha256"] = "f" * 64
        for changes in (
            {"native_startup_bootstrap": foreign},
            {"native_startup_bootstrap": None},
            {"installed_product": None},
            {"installed_product_error": "RuntimeError: signature refused"},
        ):
            with self.subTest(changes=changes):
                self.assertTrue(gate.evaluate("clean", observe(**changes)))

    def test_consent_boundary_admits_only_the_exact_consent_step(self):
        self.assertEqual(gate.evaluate("clean", observe()), [])
        for receipt in (
            None,
            consent_boundary(stdout="native_appleevent_status=0\n"),
            consent_boundary(exit_status=66, stdout="native_appleevent_status=-1743\n"),
            consent_boundary(exit_status=66, stdout="native_appleevent_status=-1712\n"),
            consent_boundary(stderr="Owned AppleEvent outcome admission failed: -1744\n"),
            consent_boundary(pid=43),
            consent_boundary(mode="denied"),
            consent_boundary(executable="/private/foreign/Hammerspoon"),
            dict(consent_boundary(), prompt=True),
        ):
            with self.subTest(receipt=receipt):
                failures = gate.evaluate("clean", observe(appleevent_consent_boundary=receipt))
                self.assertTrue(any("AppleEvent boundary" in value for value in failures))
        failures = gate.evaluate(
            "clean", observe(appleevent_consent_boundary_error="RuntimeError: sender refused")
        )
        self.assertTrue(any("sender refused" in value for value in failures))

    def test_deferral_defers_only_the_consent_boundary(self):
        refused = observe(
            appleevent_consent_boundary=consent_boundary(
                exit_status=66, stdout="native_appleevent_status=-1712\n"
            )
        )
        self.assertTrue(gate.evaluate("clean", refused))
        self.assertEqual(gate.evaluate("clean", refused, defer_native=True), [])
        for changes in (
            {"native_delayed_timer": None},
            {"native_startup_bootstrap_error": "RuntimeError: startup refused"},
            {"boot_log": scripting_line(allowed="false")},
            {"quit_seconds": None},
        ):
            with self.subTest(changes=changes):
                self.assertTrue(gate.evaluate("clean", observe(**changes), defer_native=True))
        self.assertTrue(
            gate.evaluate(
                "karabiner_config",
                karabiner_observation(native_script_scope=None),
                defer_native=True,
            )
        )

    def test_journaled_scripting_state_must_reflect_the_enabled_preference(self):
        for boot_log in (
            "",
            scripting_line(allowed="false"),
            scripting_line(getter="error", allowed="unknown"),
            scripting_line(bridge="missing"),
            scripting_line(pid=43),
            scripting_line() + scripting_line(),
        ):
            with self.subTest(boot_log=boot_log):
                failures = gate.evaluate("clean", observe(boot_log=boot_log))
                self.assertTrue(any("scripting state" in value for value in failures))
        failures = gate.evaluate("clean", observe(native_child_pid=None))
        self.assertTrue(any("scripting state" in value for value in failures))

    def test_feature_proofs_cannot_hide_a_consent_boundary_refusal(self):
        for scenario, observation in (
            ("clean", observe),
            ("karabiner_config", karabiner_observation),
        ):
            with self.subTest(scenario=scenario):
                failures = gate.evaluate(
                    scenario,
                    observation(appleevent_consent_boundary_error="RuntimeError: refused send"),
                )
                self.assertEqual(len(failures), 1)
                self.assertIn("refused send", failures[0])

    def test_consent_boundary_cannot_substitute_for_missing_feature_proofs(self):
        for scenario, observation, field in (
            ("clean", observe, "native_delayed_timer"),
            ("karabiner_config", karabiner_observation, "native_karabiner_config"),
            ("karabiner_config", karabiner_observation, "native_script_scope"),
        ):
            with self.subTest(scenario=scenario, field=field):
                failures = gate.evaluate(scenario, observation(**{field: None}))
                self.assertTrue(failures)
                self.assertFalse(any("AppleEvent" in value for value in failures))

    def test_scripting_preference_owner_failure_is_retained(self):
        failures = gate.evaluate(
            "clean",
            observe(native_scripting_preference_error="preference restoration failed: x"),
        )
        self.assertTrue(any("preference restoration failed" in value for value in failures))

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

    def test_consent_sender_output_is_printed_without_workflow_commands(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            gate.print_native_diagnostics(
                {
                    "appleevent_consent_boundary": consent_boundary(
                        exit_status=66,
                        stdout="native_appleevent_status=-1712\n::error::foreign\n",
                        stderr="Owned AppleEvent outcome admission failed: -1712\r\n%0A::notice::x",
                    )
                }
            )
        lines = stdout.getvalue().splitlines()
        self.assertEqual(
            lines,
            [
                "native AppleEvent consent boundary: exit=66; expected status -1744",
                "native AppleEvent consent boundary stdout: native_appleevent_status=-1712",
                "native AppleEvent consent boundary stdout: ::error::foreign",
                "native AppleEvent consent boundary stderr: "
                "Owned AppleEvent outcome admission failed: -1712",
                "native AppleEvent consent boundary stderr: %0A::notice::x",
            ],
        )
        self.assertTrue(all(not line.startswith("::") for line in lines))

    def test_deferred_cli_names_only_the_deferred_boundary(self):
        report = {"failures": [], "qualification": {"status": "deferred"}}
        with tempfile.TemporaryDirectory() as root:
            stdout = io.StringIO()
            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate, "run", return_value=report),
                contextlib.redirect_stdout(stdout),
            ):
                status = gate.main(
                    ["/Applications/ErgoptiPlus.app", str(Path(root) / "evidence"), "clean"]
                )
        self.assertEqual(status, 0)
        self.assertIn("AppleEvent consent boundary qualified=false", stdout.getvalue())
        self.assertIn("every startup-file native feature passed", stdout.getvalue())

    def test_healthy_launch_passes(self):
        self.assertEqual(gate.evaluate("clean", observe()), [])

    def test_security_log_workflow_is_failure_owned_and_retained(self):
        # The E2E stage file of the macOS lane runs the e2e-hs job and its steps.
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/ci-macos-e2e.yml"
        text = workflow.read_text(encoding="utf-8")
        jobs = re.findall(r"^  e2e-hs:\n(.*?)(?=^  [\w-]+:\n|\Z)", text, re.M | re.S)
        self.assertEqual(len(jobs), 1)
        job = jobs[0]

        def step(name):
            blocks = re.findall(
                r"^      - name: " + re.escape(name) + r"\n(.*?)(?=^      - |\Z)", job, re.M | re.S
            )
            self.assertEqual(len(blocks), 1, name)
            return blocks[0]

        receiver = step("Receive actual native model create, pull, inference and retirement")
        self.assertIn("        id: managed-ollama-model-receiving\n", receiver)
        for name, identifier in (
            ("Qualify actual native PAC and WPAD XCTest controls", "managed-ollama-pac-receiving"),
            (
                "Receive actual independent managed HTTP native clients",
                "native_http_clock",
            ),
        ):
            with self.subTest(receiver=name):
                self.assertIn(f"        id: {identifier}\n", step(name))
        capture = step("Retain passive security service logs after native receiving failure")
        conditions = re.findall(r"^        if: (.*)$", capture, re.M)
        self.assertEqual(
            conditions,
            [
                "${{ steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native' && (!cancelled() && failure() && (steps.managed-ollama-pac-receiving.outcome == 'failure' || steps.native_http_clock.outcome == 'failure' || steps.managed-ollama-model-receiving.outcome == 'failure')) }}"
            ],
        )
        self.assertIn("from macos_launch_gate import collect_security_logs", capture)
        self.assertIn("collect_security_logs(sys.argv[1])", capture)
        self.assertIn('"$ERGOPTI_OLLAMA_BUILD_ROOT/security-observation"', capture)
        self.assertIn("        timeout-minutes: 3\n", capture)
        retained = step("Retain actual native producer, catalogue and receiving evidence")
        self.assertIn(
            "        if: ${{ steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native' && (always()) }}\n",
            retained,
        )
        self.assertIn(
            "            ${{ env.ERGOPTI_OLLAMA_BUILD_ROOT }}/security-observation\n", retained
        )
        self.assertLess(
            job.index("Receive actual native model create"),
            job.index("Retain passive security service logs"),
        )
        self.assertLess(
            job.index("Retain passive security service logs"),
            job.index("Upload qualified native inputs"),
        )

    def test_security_log_workflow_covers_each_failed_native_receiver(self):
        # The E2E stage file of the macOS lane runs the e2e-hs job and its steps.
        workflow = Path(__file__).resolve().parents[2] / ".github/workflows/ci-macos-e2e.yml"
        text = workflow.read_text(encoding="utf-8")
        blocks = re.findall(
            r"^      - name: Retain passive security service logs after native receiving failure\n"
            r"(.*?)(?=^      - |\Z)",
            text,
            re.M | re.S,
        )
        self.assertEqual(len(blocks), 1)
        conditions = re.findall(r"^        if: (.*)$", blocks[0], re.M)
        self.assertEqual(len(conditions), 1)
        condition = conditions[0]
        clauses = re.findall(r"steps\.([\w-]+)\.outcome == '([^']+)'", condition)
        identifiers = (
            "managed-ollama-pac-receiving",
            "native_http_clock",
            "managed-ollama-model-receiving",
        )
        self.assertEqual(
            clauses,
            [("stage-admission", "success")]
            + [(identifier, "failure") for identifier in identifiers],
        )
        self.assertEqual(
            condition,
            "${{ steps.stage-admission.outcome == 'success' && env.MACOS_STAGE_ROLE == 'managed-ollama-native' && (!cancelled() && failure() && ("
            + " || ".join(f"steps.{identifier}.outcome == 'failure'" for identifier in identifiers)
            + ")) }}",
        )

        # Closed GitHub outcome model reads the actual source clauses. This is
        # workflow admission evidence, never native Security service proof.
        def observes(cancelled, failed, outcomes, admitted=True, role="managed-ollama-native"):
            return (
                admitted
                and role == "managed-ollama-native"
                and not cancelled
                and failed
                and any(
                    outcomes.get(identifier) == expected for identifier, expected in clauses[1:]
                )
            )

        for first in ("success", "skipped", "failure"):
            for second in ("success", "skipped", "failure"):
                for third in ("success", "skipped", "failure"):
                    values = (first, second, third)
                    outcomes = dict(zip(identifiers, values))
                    with self.subTest(outcomes=values):
                        self.assertEqual(observes(False, True, outcomes), "failure" in values)
                        self.assertFalse(observes(True, True, outcomes))
                        self.assertFalse(observes(False, False, outcomes))
                        self.assertFalse(observes(False, True, outcomes, admitted=False))
                        self.assertFalse(observes(False, True, outcomes, role="tooltip-canvas"))
        self.assertFalse(observes(False, True, {}))

    def test_security_failure_logs_reuse_only_bounded_default_redacted_capture(self):
        for outcome in ("success", "refused", "timeout"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "security"
                calls = []

                def recording_run(arguments, **options):
                    calls.append((arguments, options))
                    self.assertEqual(arguments[0:2], ["log", "show"])
                    if outcome == "timeout":
                        raise subprocess.TimeoutExpired(arguments, options["timeout"])
                    return subprocess.CompletedProcess(
                        arguments,
                        0 if outcome == "success" else 64,
                        "initial authorization evidence\n" + "x" * 400000,
                        "observation refused" if outcome == "refused" else "",
                    )

                with (
                    mock.patch.object(gate.sys, "platform", "darwin"),
                    mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                    mock.patch.object(gate.subprocess, "run", side_effect=recording_run),
                ):
                    receipts = gate.collect_security_logs(output)
                self.assertEqual(len(calls), 1)
                arguments, options = calls[0]
                self.assertEqual(arguments[arguments.index("--last") + 1], "4m")
                self.assertEqual(options["timeout"], 120)
                self.assertNotIn("--privacy", arguments)
                predicate = arguments[arguments.index("--predicate") + 1]
                for process in (
                    "security",
                    "securityd",
                    "trustd",
                    "authd",
                    "SecurityAgent",
                    "authorizationhost",
                ):
                    self.assertIn(f'process == "{process}"', predicate)
                self.assertEqual(len(receipts), 1)
                receipt = receipts[0]
                self.assertEqual(
                    receipt["status"], "captured" if outcome == "success" else "unavailable"
                )
                self.assertEqual(
                    json.loads((output / "unified-log-collection.json").read_text()), receipts
                )
                if outcome != "timeout":
                    with gzip.open(
                        output / receipt["archive_file"], "rt", encoding="utf-8"
                    ) as handle:
                        self.assertTrue(handle.read().startswith("initial authorization evidence"))
                    self.assertEqual(len((output / "security-system.log").read_text()), 400000)
                else:
                    self.assertIn("TimeoutExpired", receipt["cause"])

    def test_security_log_capture_refuses_non_ci_hosts_and_existing_output(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "security"
            for platform, ci in (("win32", "true"), ("darwin", "false")):
                with (
                    mock.patch.object(gate.sys, "platform", platform),
                    mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": ci}),
                    mock.patch.object(gate.subprocess, "run") as run,
                ):
                    with self.assertRaises(RuntimeError):
                        gate.collect_security_logs(output)
                    run.assert_not_called()
                    self.assertFalse(output.exists())
            output.mkdir()
            sentinel = output / "original"
            sentinel.write_text("preserved", encoding="utf-8")
            with (
                mock.patch.object(gate.sys, "platform", "darwin"),
                mock.patch.dict(gate.os.environ, {"GITHUB_ACTIONS": "true"}),
                mock.patch.object(gate.subprocess, "run") as run,
            ):
                with self.assertRaises(FileExistsError):
                    gate.collect_security_logs(output)
                run.assert_not_called()
                self.assertEqual(sentinel.read_text(), "preserved")

    def test_appleevent_diagnostics_retain_system_logs_and_collection_failures(self):
        for outcome in ("success", "refused", "timeout"):
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "output"
                output.mkdir()
                home = Path(folder) / "home"
                home.mkdir()
                log_calls = []

                def native_run(arguments, **options):
                    if arguments[0] == "log":
                        log_calls.append(arguments)
                        if outcome == "timeout":
                            raise subprocess.TimeoutExpired(arguments, options["timeout"])
                        return subprocess.CompletedProcess(
                            arguments,
                            64 if outcome == "refused" else 0,
                            "native log evidence",
                            "log collection refused" if outcome == "refused" else "",
                        )
                    return subprocess.CompletedProcess(arguments, 0, "", "")

                with (
                    mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                    mock.patch.object(gate, "processes", return_value=[]),
                ):
                    collected = gate.collect(
                        output,
                        {"logs_dir": home / "missing"},
                        home,
                        (Path("/private/owned/Hammerspoon"),),
                    )
                self.assertEqual(len(log_calls), 2)
                system_call = log_calls[1]
                predicate = system_call[system_call.index("--predicate") + 1]
                self.assertIn('process == "tccd"', predicate)
                self.assertIn('subsystem == "com.apple.appleevents"', predicate)
                self.assertIn("--info", system_call)
                self.assertIn("--debug", system_call)
                self.assertEqual(system_call[system_call.index("--last") + 1], "4m")
                diagnostics = collected["unified_logs"]
                self.assertEqual(len(diagnostics), 2)
                for receipt in diagnostics:
                    self.assertEqual(
                        receipt["status"], "captured" if outcome == "success" else "unavailable"
                    )
                    if outcome == "refused":
                        self.assertEqual(receipt["exit_status"], 64)
                        self.assertIn("log collection refused", receipt["stderr"])
                    if outcome == "timeout":
                        self.assertIn("TimeoutExpired", receipt["cause"])
                self.assertEqual(
                    json.loads((output / "unified-log-collection.json").read_text()), diagnostics
                )
                self.assertTrue((output / "appleevents-system.log").exists())

    def test_unified_log_capture_requires_completed_archive_and_preview_writes(self):
        for failure in ("open", "close", "preview"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as folder:
                output = Path(folder) / "output"
                output.mkdir()
                home = Path(folder) / "home"
                home.mkdir()
                original_write = Path.write_text

                @contextlib.contextmanager
                def refused_close(*arguments, **options):
                    yield io.StringIO()
                    raise OSError("Archive close refused")

                def refused_preview(path, text, **options):
                    if path.name in ("unified.log", "appleevents-system.log"):
                        raise OSError("Preview write refused")
                    return original_write(path, text, **options)

                with contextlib.ExitStack() as stack:
                    stack.enter_context(mock.patch.object(gate, "processes", return_value=[]))
                    stack.enter_context(
                        mock.patch.object(
                            gate.subprocess,
                            "run",
                            return_value=subprocess.CompletedProcess([], 0, "evidence", ""),
                        )
                    )
                    if failure == "open":
                        stack.enter_context(
                            mock.patch.object(
                                gate.gzip, "open", side_effect=OSError("Archive open refused")
                            )
                        )
                    elif failure == "close":
                        stack.enter_context(mock.patch.object(gate.gzip, "open", refused_close))
                    else:
                        stack.enter_context(mock.patch.object(Path, "write_text", refused_preview))
                    collected = gate.collect(
                        output,
                        {"logs_dir": home / "missing"},
                        home,
                        (Path("/private/owned/Hammerspoon"),),
                    )
                for receipt in collected["unified_logs"]:
                    self.assertEqual(receipt["status"], "unavailable")
                    self.assertIn("refused", receipt["cause"])
                    if failure != "preview":
                        self.assertNotIn("archive_file", receipt)
                    else:
                        self.assertIn("Preview write refused", receipt["preview_error"])
                        self.assertEqual(receipt["archive_file"], receipt["file"] + ".gz")
                        with gzip.open(
                            output / receipt["archive_file"], "rt", encoding="utf-8"
                        ) as handle:
                            self.assertEqual(handle.read(), "evidence")

    def test_unified_log_archive_preserves_initial_authorization_after_preview_limit(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / "output"
            output.mkdir()
            home = Path(folder) / "home"
            home.mkdir()
            trace = "initial consent request\n" + "x" * 400000 + "\nfinal observation\n"

            def native_run(arguments, **options):
                return subprocess.CompletedProcess(
                    arguments, 0, trace if arguments[0] == "log" else "", ""
                )

            with (
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "processes", return_value=[]),
            ):
                collected = gate.collect(
                    output,
                    {"logs_dir": home / "missing"},
                    home,
                    (Path("/private/owned/Hammerspoon"),),
                )
            for receipt in collected["unified_logs"]:
                with gzip.open(
                    output / (receipt["file"] + ".gz"), "rt", encoding="utf-8"
                ) as handle:
                    self.assertEqual(handle.read(), trace)
                self.assertEqual(receipt["archive_file"], receipt["file"] + ".gz")
                self.assertEqual(receipt["characters"], len(trace))
                self.assertTrue(receipt["preview_truncated"])
                preview = (output / receipt["file"]).read_text(encoding="utf-8")
                self.assertEqual(len(preview), 400000)
                self.assertTrue(preview.endswith("final observation\n"))

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
                timer_probe.executable_path(Path("/Applications/ErgoptiPlus.app")),
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
                timer_probe.executable_path(app),
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


class NativeQualificationRunTests(unittest.TestCase):
    """The actual run sends one consent-free event, then qualifies features by startup file."""

    def exercise(
        self,
        scenario,
        deferred=False,
        boundary=None,
        refuse=(),
        leave_child=False,
    ):
        events = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home, app, output = root / "home", root / "ErgoptiPlus.app", root / "evidence"
            output.mkdir()
            launcher = app / "Contents/MacOS/ErgoptiPlus"
            child = app / "Contents/Frameworks/Hammerspoon.app/Contents/MacOS/Hammerspoon"
            for executable in (launcher, child):
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_text("inert exact executable")
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.ergoptiplus.app"}, handle)
            live = {"launcher": False, "child": False}

            def processes(executable):
                if executable == child:
                    return [42] if live["child"] else []
                return [41] if live["launcher"] else []

            def native_run(arguments, **options):
                self.assertNotIn("osascript", " ".join(map(str, arguments)))
                if arguments[0] == "open":
                    live.update(launcher=True, child=True)
                return subprocess.CompletedProcess(arguments, 0, "arm64", "")

            def read_text(path):
                if Path(path).name == gate.FALLBACK_BOOT_LOG_NAME:
                    return scripting_line()
                return HEALTHY["launcher_log"]

            preference = mock.Mock()
            preference.enable.side_effect = lambda: events.append("enable")
            preference.restore.side_effect = lambda: events.append("restore")

            def send(sender, pid, executable):
                self.assertEqual((pid, executable), (42, child))
                events.append("boundary")
                if isinstance(boundary, Exception):
                    raise boundary
                return boundary or consent_boundary()

            def quit_owned(*arguments):
                events.append("quit")
                live["launcher"] = False
                if not leave_child:
                    live["child"] = False
                return 0.5

            def startup_owner(owner_app, owner_output, domain, resolver):
                self.assertEqual((owner_app, owner_output, domain), (app, output, gate.HS_DOMAIN))
                owner = mock.Mock()

                def observe_feature(feature):
                    # Each feature starts only after the managed runtime and its
                    # scripting key retired, never as a substitute for them.
                    self.assertFalse(live["launcher"] or live["child"])
                    self.assertIn("restore", events)
                    events.append(feature)
                    if feature in refuse:
                        raise RuntimeError(f"{feature} refused")
                    if feature == "delayed_timer":
                        return startup_summary(
                            feature, dict(timer_summary(), preference_restored=False)
                        )
                    if feature == "karabiner_config":
                        return startup_summary(
                            feature, dict(karabiner_summary(), preference_restored=False)
                        )
                    return script_summary()

                owner.observe.side_effect = observe_feature
                return owner

            qualification = {"status": "deferred", "scope": "macos-launch-appleevents"}
            with (
                mock.patch.object(gate.Path, "home", return_value=home),
                mock.patch.object(gate, "seed", return_value={"logs_dir": gate.logs_folder(home)}),
                mock.patch.object(gate, "installed_product", return_value=dict(PRODUCT)),
                mock.patch.object(gate, "build_consent_sender", return_value=root / "sender"),
                mock.patch.object(gate, "observe_consent_boundary", side_effect=send),
                mock.patch.object(gate, "AppleScriptPreference", return_value=preference),
                mock.patch.object(gate, "NativeStartupBootstrap", side_effect=startup_owner),
                mock.patch.object(gate, "read_launch_qualification", return_value=qualification),
                mock.patch.object(gate, "processes", side_effect=processes),
                mock.patch.object(gate.subprocess, "run", side_effect=native_run),
                mock.patch.object(gate, "STARTUP_TIMEOUT_SECONDS", 0),
                mock.patch.object(gate, "read_text", side_effect=read_text),
                mock.patch.object(gate, "driver_logs", return_value=HEALTHY["driver_log"]),
                mock.patch.object(gate, "check_state", return_value=[]),
                mock.patch.object(gate, "quit_application", side_effect=quit_owned),
                mock.patch.object(gate, "collect", return_value={"errors": [], "windows": {}}),
                mock.patch.object(
                    gate.os,
                    "kill",
                    side_effect=lambda pid, _: None if leave_child else live.update(child=False),
                ),
                mock.patch.object(gate.signal, "SIGKILL", 9, create=True),
            ):
                report = gate.run(
                    app, output, scenario, "", "explicit-record" if deferred else None
                )
        return events, report

    def test_clean_sends_one_consent_free_event_before_quit_then_qualifies_the_timer(self):
        events, report = self.exercise("clean")
        self.assertEqual(events, ["enable", "boundary", "quit", "restore", "delayed_timer"])
        self.assertEqual(report["failures"], [])
        self.assertEqual(report["appleevent_consent_boundary"], consent_boundary())
        timer_probe.validate_summary(report["native_delayed_timer"])
        self.assertEqual(report["installed_product"], PRODUCT)

    def test_karabiner_runs_script_scope_whatever_failed_before_it(self):
        events, report = self.exercise(
            "karabiner_config",
            boundary=consent_boundary(exit_status=66, stdout="native_appleevent_status=-1712\n"),
            refuse=("karabiner_config",),
        )
        self.assertEqual(
            events,
            ["enable", "boundary", "quit", "restore", "karabiner_config", "script_scope"],
        )
        self.assertEqual(report["native_script_scope"], script_summary())
        self.assertNotIn("not_executed", json.dumps(report))
        self.assertTrue(any("AppleEvent boundary" in value for value in report["failures"]))
        self.assertTrue(any("karabiner_config refused" in value for value in report["failures"]))
        self.assertFalse(any("Script SDK" in value for value in report["failures"]))

    def test_healthy_karabiner_run_passes_with_every_native_feature(self):
        events, report = self.exercise("karabiner_config")
        self.assertEqual(report["failures"], [])
        karabiner_probe.validate_summary(report["native_karabiner_config"])

    def test_deferral_still_requires_every_startup_file_feature(self):
        events, report = self.exercise(
            "karabiner_config",
            deferred=True,
            boundary=RuntimeError("consent boundary unavailable"),
        )
        self.assertEqual(events[-2:], ["karabiner_config", "script_scope"])
        self.assertEqual(report["failures"], [])
        self.assertIs(report["native_qualified"], False)
        events, report = self.exercise("clean", deferred=True, refuse=("delayed_timer",))
        self.assertIn("delayed_timer", events)
        self.assertTrue(any("delayed_timer refused" in value for value in report["failures"]))

    def test_live_managed_runtime_refuses_features_as_recorded_failures(self):
        with mock.patch.object(gate, "QUIT_TIMEOUT_SECONDS", 0):
            events, report = self.exercise("karabiner_config", leave_child=True)
        self.assertNotIn("karabiner_config", events)
        self.assertNotIn("script_scope", events)
        self.assertIn("native_startup_bootstrap_error", report)
        self.assertIn("native_script_scope_error", report)
        self.assertTrue(any("Script SDK" in value for value in report["failures"]))


if __name__ == "__main__":
    unittest.main()
