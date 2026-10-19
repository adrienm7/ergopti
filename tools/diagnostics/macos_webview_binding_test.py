# tools/diagnostics/macos_webview_binding_test.py
"""Pure receipt/ownership refusal controls, never evidence of native WebKit execution."""

from copy import deepcopy
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import macos_webview_binding as probe


def healthy():
    """Model a receipt only to exercise strict supervisor refusals on mutated facts."""
    return {
        "status": "ok",
        "schema_version": 3,
        "contract": "native.webview-binding",
        "nonce": "owned-nonce",
        "pid": 711,
        "version": "1.1.1",
        "source_revision": "a" * 40,
        "runtime": "native Hammerspoon",
        "scope": "production ui.ui_builder.show_webview; native WebView/UCC bindings",
        "window_identity": {"explicit": 101, "user": 202, "host_pid": 711},
        "ucc_userdata_gc": "unmeasured; controllers deliberately retained",
        "features": {
            "explicit_product_close": {
                "visible_before": True,
                "native_auto_delete_disabled": True,
                "exact_close_count": 1,
                "userdata_consumed": True,
                "runloop_continued": True,
                "sibling_survived": True,
            },
            "user_product_close": {
                "visible_before": True,
                "native_auto_delete_disabled": True,
                "native_close_button_requested": True,
                "exact_close_count": 1,
                "userdata_consumed": True,
            },
            "callback_release": {
                "held_before_detach": True,
                "collected_after_detach": True,
                "detach_acknowledged": True,
            },
            "message_identity": {
                "rebound_b_callback": True,
                "b_after_a_gc_source_exact": True,
                "b_after_a_gc_accepted": True,
                "b_after_a_gc_evaluated": True,
                "initial_a_exact": True,
                "current_b_exact": True,
                "stale_a_rejected": True,
                "current_b_accepted": True,
                "a_close_preserved_b": True,
                "a_closes": 1,
                "b_closes": 1,
            },
        },
        "cleanup": {
            "windows_consumed": True,
            "callbacks_detached": True,
            "timers_stopped": True,
            "console_checked": True,
        },
    }


class BindingSupervisorControls(unittest.TestCase):
    """An actual native process remains mandatory outside these modeled Python controls."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        for name in ("launch.stdout", "launch.stderr"):
            (self.root / name).write_text("")
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None

    def publish(self, result=None):
        (self.root / "result.json").write_text(json.dumps(healthy() if result is None else result))

    def observe(self, unchanged=None):
        return probe.supervise(
            self.group, self.root, "1.1.1", "owned-nonce", "a" * 40, unchanged or Mock(), timeout=1
        )

    def test_complete_modeled_receipt_reaches_both_live_process_checks(self):
        self.publish()
        with patch.object(probe.time, "sleep") as sleep:
            result = self.observe()
        self.assertEqual(result["native_execution"], "executed")
        self.assertEqual(self.group.observe_exit.call_count, 2)
        sleep.assert_called_once_with(0.5)

    def test_wrong_identity_and_boolean_pid_cannot_borrow_native_owner(self):
        for field, value in (
            ("pid", 712),
            ("pid", True),
            ("nonce", "foreign"),
            ("source_revision", "b" * 40),
            ("version", "1.0.0"),
        ):
            with self.subTest(field=field, value=value):
                result = healthy()
                result[field] = value
                self.publish(result)
                with self.assertRaisesRegex(ValueError, "identities"):
                    self.observe()

    def test_native_window_identities_are_distinct_owned_integers(self):
        for field, value in (("explicit", True), ("user", 101), ("user", 0), ("host_pid", 712)):
            result = healthy()
            result["window_identity"][field] = value
            self.publish(result)
            with (
                self.subTest(field=field, value=value),
                self.assertRaisesRegex(ValueError, "identities"),
            ):
                self.observe()

    def test_missing_or_false_feature_never_qualifies(self):
        original = healthy()
        for name, fields in original["features"].items():
            for field in fields:
                for value in (None, False, "true"):
                    with self.subTest(name=name, field=field, value=value):
                        result = deepcopy(original)
                        if value is None:
                            del result["features"][name][field]
                        else:
                            result["features"][name][field] = value
                        self.publish(result)
                        with self.assertRaisesRegex(ValueError, "measurements"):
                            self.observe()

    def test_integer_one_cannot_replace_a_measured_boolean(self):
        for section, field in (
            ("cleanup", "console_checked"),
            ("message_identity", "b_after_a_gc_source_exact"),
            ("message_identity", "b_after_a_gc_accepted"),
            ("message_identity", "b_after_a_gc_evaluated"),
        ):
            result = healthy()
            fields = result["cleanup"] if section == "cleanup" else result["features"][section]
            fields[field] = 1
            self.publish(result)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "schema"):
                self.observe()

    def test_unknown_fake_or_skip_flags_and_gc_claim_are_rejected(self):
        for field, value in (("fake", True), ("skip", True), ("ucc_userdata_gc", "qualified")):
            result = healthy()
            result[field] = value
            self.publish(result)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "schema"):
                self.observe()

    def test_declared_error_remains_failure(self):
        self.publish({"status": "error", "error": "native assertion"})
        with self.assertRaisesRegex(ValueError, "native assertion"):
            self.observe()

    def test_native_exit_is_rejected_before_receipt(self):
        self.publish()
        self.group.observe_exit.return_value = object()
        with self.assertRaisesRegex(ValueError, "exited before"):
            self.observe()

    def test_native_exit_after_receipt_is_rejected(self):
        self.publish()
        self.group.observe_exit.side_effect = [None, object()]
        with patch.object(probe.time, "sleep"), self.assertRaisesRegex(ValueError, "exited after"):
            self.observe()

    def test_real_gc_overflow_in_stderr_refuses_an_otherwise_healthy_receipt(self):
        self.publish()
        recorded = (
            "2026-10-18 22:15:47.777 Hammerspoon[2276:10763] BREADCRUMB: "
            "hs.webview:error invoking _gc for deleteOnClose:C stack overflow\n"
        )
        for text in (recorded, "*** Assertion failure in -[LuaSkin pushLuaRef:ref:]\n"):
            with self.subTest(text=text):
                (self.root / "launch.stderr").write_text(text)
                with (
                    patch.object(probe.time, "sleep"),
                    self.assertRaisesRegex(ValueError, "Native runtime error"),
                ):
                    self.observe()

    def test_native_error_after_result_remains_refusing(self):
        self.publish()

        def later(_delay):
            (self.root / "launch.stderr").write_text(
                "LuaSkin: error, state ERRRUN: C stack overflow\n"
            )

        with patch.object(probe.time, "sleep", side_effect=later):
            with self.assertRaisesRegex(ValueError, "C stack overflow"):
                self.observe()

    def test_missing_native_output_reaches_deadline_instead_of_skip(self):
        with patch.object(probe.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(ValueError, "deadline"):
                self.observe()

    def test_source_change_refuses_after_native_receipt(self):
        self.publish()
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.observe(Mock(side_effect=ValueError("source changed")))

    def test_redirected_output_and_mutation_after_receipt_are_rejected(self):
        self.publish()
        captured = self.root / "result.json"
        target = self.root / "foreign.json"
        captured.rename(target)
        captured.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "Redirected"):
            self.observe()
        captured.unlink()
        target.rename(captured)
        with patch.object(probe.time, "sleep", side_effect=lambda _: captured.write_text("{}")):
            with self.assertRaisesRegex(ValueError, "changed after"):
                self.observe()

    def test_oversized_and_malformed_output_are_rejected(self):
        for text, error in ((" " * 32769, ValueError), ("{", json.JSONDecodeError)):
            (self.root / "result.json").write_text(text)
            with self.subTest(error=error), self.assertRaises(error):
                self.observe()

    def test_same_actual_owner_callback_handles_failure_and_successor_debt(self):
        import macos_tooltip_canvas as canvas

        self.group.receipt.return_value = {"closed": False}
        self.group.settle.return_value = False
        self.group.reaped = False

        def acquire(_arguments, _native, register, **_options):
            register(self.group)

        owned_output = self.root / "owned-observation"
        owned_output.mkdir()
        with patch.object(canvas.owner, "acquire_owned", side_effect=acquire):
            result = canvas.owned_observation(
                Path("/owned/Hammerspoon"),
                self.root / "init.lua",
                owned_output,
                lambda _: (_ for _ in ()).throw(ValueError("native assertion")),
                Mock(),
            )
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["operation_error"], "native assertion")
        self.assertRegex(result["cleanup_errors"][0], "retirement debt")
        self.group.settle.assert_called_once()

    def qualify_with_boundary(self, mutate=None):
        """Exercise the new coordinator with a modeled owner, never a native qualification."""
        scratch, output = self.root / "scratch", self.root / "output"
        scratch.mkdir()
        output.mkdir()

        def observed(executable, config, destination, _operation, native):
            self.assertEqual(executable, Path("/owned/Hammerspoon"))
            self.assertIs(native, self.group)
            self.assertEqual(destination, output / "webview-binding")
            for name in ("launch.stdout", "launch.stderr"):
                (destination / name).write_text("")
            settings = json.loads((config.parent / "webview-config.json").read_text())
            value = healthy()
            value["nonce"] = settings["nonce"]
            value.update(source_revision=settings["source_revision"])
            receipt = {
                "status": "ok",
                "native_execution": "executed",
                "native_process_observed": True,
                "result": value,
                "cleanup_errors": [],
                "operation_error": None,
                "native_owner": {
                    "worker_pid": 711,
                    "group_id": 711,
                    "closed": True,
                    "reservation_lost": False,
                    "live_group_members": [],
                },
            }
            if mutate:
                mutate(receipt, config)
            return receipt

        with patch.object(probe, "revision", return_value="a" * 40):
            return probe.qualify_product(
                self.root,
                Path("/owned/Hammerspoon"),
                scratch,
                output,
                "1.1.1",
                Mock(),
                observed,
                self.group,
            )

    def test_coordinator_preserves_exact_runtime_and_separate_retirement_receipt(self):
        receipt = self.qualify_with_boundary()
        self.assertEqual(receipt["source_revision"], "a" * 40)
        self.assertTrue((self.root / "output/webview-binding/supervisor.json").is_file())
        self.assertFalse((self.root / "output/result.json").exists())

    def test_coordinator_refuses_payload_changes_and_retains_owner_receipt(self):
        def mutate(_receipt, config):
            config.write_text("altered Lua payload")

        with self.assertRaisesRegex(ValueError, "payload changed"):
            self.qualify_with_boundary(mutate)
        receipt = json.loads((self.root / "output/webview-binding/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")
        self.assertRegex(receipt["qualification_error"], "payload changed")

    def test_incomplete_retirement_cannot_be_qualified_by_green_measurement(self):
        def mutate(receipt, _config):
            receipt["native_owner"]["closed"] = False

        with self.assertRaisesRegex(ValueError, "retirement is incomplete"):
            self.qualify_with_boundary(mutate)
        receipt = json.loads((self.root / "output/webview-binding/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")
        self.assertRegex(receipt["qualification_error"], "retirement is incomplete")

    def test_unknown_or_incomplete_owner_observation_is_not_adopted(self):
        def mutate(receipt, _config):
            receipt["native_execution"] = "modeled"

        with self.assertRaisesRegex(ValueError, "observation is incomplete"):
            self.qualify_with_boundary(mutate)

    def test_error_retained_after_owner_retirement_cannot_leave_a_green_receipt(self):
        def mutate(_receipt, config):
            output = json.loads((config.parent / "webview-config.json").read_text())["output_dir"]
            (Path(output) / "launch.stderr").write_text(
                "Hammerspoon BREADCRUMB: hs.webview:error invoking _gc for deleteOnClose:C stack overflow\n"
            )

        with self.assertRaisesRegex(ValueError, "C stack overflow"):
            self.qualify_with_boundary(mutate)
        receipt = json.loads((self.root / "output/webview-binding/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")

    def test_final_log_collection_cannot_publish_errors_with_a_green_status(self):
        failure = {
            "source": "launch.stderr",
            "line": 1,
            "text": "Native error during final collection",
        }
        with patch.object(probe, "native_errors", side_effect=[[], [failure]]):
            with self.assertRaisesRegex(ValueError, "final log admission"):
                self.qualify_with_boundary()
        receipt = json.loads((self.root / "output/webview-binding/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")
        self.assertEqual(receipt["native_log_errors"], [failure])

    def test_each_actual_post_expression_returns_a_supported_primitive_once(self):
        source = Path(probe.__file__).with_suffix(".lua").read_text()
        expressions = re.findall(
            r'view:evaluateJavaScript\("([^"\n]*)" \.\.\s*'
            r"assert\(json.encode\(\{ nonce = config.nonce, kind = kind \}\)\)\s*"
            r'\.\. "([^"\n]*)", function\(',
            source,
        )
        self.assertEqual(len(expressions), 1, "actual native post expression must be unique")
        prefix, suffix = expressions[0]
        node = shutil.which("node")
        self.assertIsNotNone(node, "canonical Node interpreter is mandatory")
        for kind in ("initial-a", "stale-a", "current-b", "current-b-after-a-gc"):
            payload = {"nonce": 'owned-"nonce\\value-✨', "kind": kind}
            script = prefix + json.dumps(payload) + suffix
            with self.subTest(kind=kind):
                result = subprocess.run(
                    [
                        node,
                        "-e",
                        """const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const posts = [];
const scope = { window: { webkit: { messageHandlers: { ergopti_binding: {
  postMessage(body) { posts.push(body); return Promise.resolve('unsupported return control'); }
} } } } };
const value = vm.runInNewContext(input.script, scope, { timeout: 1000 });
assert.equal(value, true, 'native evaluateJavaScript must receive primitive true');
assert.deepEqual(JSON.parse(JSON.stringify(posts)), [input.payload]);
""",
                    ],
                    input=json.dumps({"script": script, "payload": payload}),
                    text=True,
                    capture_output=True,
                    timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_has_no_fake_native_or_skip_admission_flags(self):
        runner = Path(probe.__file__).with_name("macos_tooltip_canvas.py")
        for flag in ("--fake-native", "--skip-webview-binding"):
            result = subprocess.run(
                [
                    sys.executable,
                    str(runner),
                    "--repo",
                    str(self.root),
                    "--app",
                    str(self.root / "unused.app"),
                    "--output",
                    str(self.root / "not-created"),
                    flag,
                ],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("unrecognized arguments: " + flag, result.stderr)
            self.assertFalse((self.root / "not-created").exists())


def raw_observed():
    """Model a completed raw observation only; its stderr must still prove the defect."""
    return {
        "schema_version": 1,
        "contract": "native.webview-raw-delete",
        "status": "observed",
        "nonce": "raw-nonce",
        "source_revision": "a" * 40,
        "pid": 711,
        "version": "1.1.1",
        "runtime": "native Hammerspoon",
        "features": {
            "visible_before": True,
            "native_opt_in": True,
            "close_callback_count": 1,
            "userdata_consumed": True,
            "runloop_continued": True,
        },
        "cleanup": {"windows_consumed": True, "timers_stopped": True},
        "ucc_userdata_gc": "unmeasured; no controller constructed",
    }


def recorded_raw_errors(pid=711):
    """Use the two actual CI39171054196 error bodies with a test-owned PID."""
    return [
        {
            "source": "launch.stderr",
            "line": number,
            "text": f"2026-10-18 22:15:47.777 Hammerspoon[{pid}:10763] BREADCRUMB: " + body,
        }
        for number, body in enumerate(
            (
                "hs.webview:error invoking _gc for deleteOnClose:C stack overflow",
                "logForLuaSkin: error, state ERRRUN: C stack overflow",
            ),
            1,
        )
    ]


class RawControlAdmission(unittest.TestCase):
    """Pure negative-control admission; no modeled failure qualifies product behavior."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None
        self.publish()

    def publish(self, value=None):
        (self.root / "result.json").write_text(
            json.dumps(raw_observed() if value is None else value)
        )
        (self.root / "launch.stdout").write_text("")
        (self.root / "launch.stderr").write_text(
            "\n".join(e["text"] for e in recorded_raw_errors()) + "\n"
        )

    def observe(self):
        return probe.supervise_raw(
            self.group, self.root, "1.1.1", "raw-nonce", "a" * 40, Mock(), timeout=1
        )

    def test_only_the_exact_recorded_stderr_pair_is_expected(self):
        probe.known_raw_failure(recorded_raw_errors(), 711)
        for errors in (
            [],
            recorded_raw_errors()[:1],
            recorded_raw_errors() * 2,
            recorded_raw_errors(712),
            [dict(recorded_raw_errors()[0], source="launch.stdout")],
        ):
            with self.subTest(errors=errors), self.assertRaises(ValueError):
                probe.known_raw_failure(errors, 711)

    def test_unknown_native_failure_is_never_folded_into_the_known_defect(self):
        errors = recorded_raw_errors() + [
            {"source": "launch.stderr", "line": 3, "text": "Hammerspoon: unknown native error"}
        ]
        with self.assertRaisesRegex(ValueError, "unknown failure"):
            probe.known_raw_failure(errors, 711)

    def test_expected_failure_still_requires_completed_visible_native_observation(self):
        for field, value in (
            ("native_opt_in", False),
            ("close_callback_count", 2),
            ("userdata_consumed", False),
        ):
            result = raw_observed()
            result["features"][field] = value
            self.publish(result)
            with (
                self.subTest(field=field),
                self.assertRaisesRegex(ValueError, "observation or schema"),
            ):
                self.observe()

    def test_valid_raw_transcript_keeps_its_receipt_and_two_liveness_checks(self):
        with patch.object(probe.time, "sleep"):
            result = self.observe()
        self.assertEqual(result["result"]["status"], "observed")
        self.assertEqual(self.group.observe_exit.call_count, 2)

    def test_premature_raw_exit_is_not_an_expected_negative_success(self):
        self.group.observe_exit.side_effect = [None, object()]
        with patch.object(probe.time, "sleep"), self.assertRaisesRegex(ValueError, "exited after"):
            self.observe()

    def qualify(self, mutate=None):
        scratch, output = self.root / "scratch", self.root / "output"
        scratch.mkdir()
        output.mkdir()

        def observed(executable, config, destination, _operation, native):
            self.assertEqual(executable, Path("/owned/Hammerspoon"))
            self.assertIs(native, self.group)
            self.assertEqual(destination, output / "webview-raw-delete")
            settings = json.loads((config.parent / "webview-config.json").read_text())
            (destination / "launch.stdout").write_text("")
            (destination / "launch.stderr").write_text(
                "\n".join(e["text"] for e in recorded_raw_errors()) + "\n"
            )
            value = raw_observed()
            value.update(nonce=settings["nonce"], source_revision=settings["source_revision"])
            receipt = {
                "status": "ok",
                "operation_error": None,
                "cleanup_errors": [],
                "native_execution": "executed",
                "native_process_observed": True,
                "result": value,
                "native_owner": {
                    "closed": True,
                    "reservation_lost": False,
                    "live_group_members": [],
                    "worker_pid": 711,
                    "group_id": 711,
                },
            }
            if mutate:
                mutate(receipt)
            return receipt

        with patch.object(probe, "revision", return_value="a" * 40):
            return probe.qualify_raw(
                self.root,
                Path("/owned/Hammerspoon"),
                scratch,
                output,
                "1.1.1",
                Mock(),
                observed,
                self.group,
            )

    def test_raw_qualification_is_explicitly_negative_and_keeps_its_own_artifact(self):
        result = self.qualify()
        self.assertEqual(result["status"], "expected_native_failure")
        self.assertEqual(len(result["native_log_errors"]), 2)
        self.assertTrue((self.root / "output/webview-raw-delete/supervisor.json").is_file())
        self.assertFalse((self.root / "output/webview-binding").exists())

    def test_raw_retirement_debt_is_never_an_expected_negative_success(self):
        def mutate(receipt):
            receipt["native_owner"]["closed"] = False

        with self.assertRaisesRegex(ValueError, "retirement is incomplete"):
            self.qualify(mutate)
        result = json.loads((self.root / "output/webview-raw-delete/supervisor.json").read_text())
        self.assertEqual(result["status"], "error")

    def test_final_raw_collection_rejects_a_new_error_outside_the_pinned_pair(self):
        extra = {"source": "launch.stderr", "line": 3, "text": "Unrelated native error"}
        with patch.object(
            probe,
            "native_errors",
            side_effect=[recorded_raw_errors(), recorded_raw_errors() + [extra]],
        ):
            with self.assertRaisesRegex(ValueError, "final classification"):
                self.qualify()
        result = json.loads((self.root / "output/webview-raw-delete/supervisor.json").read_text())
        self.assertEqual(result["status"], "error")
        self.assertEqual(len(result["native_log_errors"]), 3)

    def test_orchestrator_runs_two_roles_and_preserves_distinct_owners(self):
        order = []
        raw = {"status": "expected_native_failure", "native_owner": {"worker_pid": 711}}
        product = {"status": "ok", "native_owner": {"worker_pid": 712}}
        with (
            patch.object(probe, "qualify_raw", side_effect=lambda *_: order.append("raw") or raw),
            patch.object(
                probe, "qualify_product", side_effect=lambda *_: order.append("product") or product
            ),
        ):
            result = probe.qualify(*([None] * 8))
        self.assertEqual(order, ["raw", "product"])
        self.assertEqual(result["status"], "ok")
        self.assertEqual(result["raw_negative_control"]["status"], "expected_native_failure")
        self.assertNotEqual(
            result["native_owner"]["worker_pid"],
            result["raw_negative_control"]["native_owner"]["worker_pid"],
        )

    def test_unrecognized_raw_failure_cannot_start_product_observation(self):
        with (
            patch.object(probe, "qualify_raw", side_effect=ValueError("unknown native failure")),
            patch.object(probe, "qualify_product") as product,
        ):
            with self.assertRaisesRegex(ValueError, "unknown native failure"):
                probe.qualify(*([None] * 8))
        product.assert_not_called()


if __name__ == "__main__":
    unittest.main()
