# tools/diagnostics/macos_physical_shortcuts_close_test.py
"""Pure evidence refusals only; these modeled receipts never qualify native WebKit."""

from copy import deepcopy
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import macos_physical_shortcuts_close as probe


def healthy():
    """Construct the expected native schema to exercise independent parser mutations."""
    case = {
        "window_id": 101,
        "host_pid": 711,
        "native_delete_requests": 1,
        "notifications": [
            {
                "action": "closing",
                "visible_read": True,
                "visible": True,
                "userdata_live_before": True,
            }
        ],
        "userdata_consumed": True,
        "visible_before": True,
        "native_auto_delete_disabled": True,
        "callback_retained_before": True,
        "exact_bridge_detach": True,
        "consumed_before_detach": True,
        "callback_collected": True,
        "product_timer_retired": True,
    }
    return {
        "schema_version": 1,
        "contract": probe.CONTRACT,
        "nonce": "owned-nonce",
        "source_revision": "a" * 40,
        "source_manifest_digest": "b" * 64,
        "pid": 711,
        "version": "1.1.1",
        "arch": "arm64",
        "status": "ok",
        "errors": [],
        "ucc_userdata_gc": probe.GC_SCOPE,
        "native_input": probe.INPUT_SCOPE,
        "product_timer_baseline": 0,
        "product_timer_final": 0,
        "ax_close_ack": True,
        "observers_restored": True,
        "public_close_initial_return": False,
        "ax_user_close": deepcopy(case),
        "public_close": deepcopy(case),
    }


def admit(result):
    probe.validate(result, 711, "1.1.1", "owned-nonce", "a" * 40, "arm64", "b" * 64)


def retired():
    return {
        "status": "ok",
        "native_execution": "executed",
        "native_process_observed": True,
        "operation_error": None,
        "cleanup_errors": [],
        "native_owner": {
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "worker_pid": 711,
            "group_id": 711,
        },
    }


class PhysicalNativeControls(unittest.TestCase):
    """Reject omissions independently of diagnostic Lua implementation text."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            (self.output / name).write_text("")
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None

    def observe(self, changed=None):
        return probe.supervise(
            self.group,
            self.output,
            "1.1.1",
            "owned-nonce",
            "a" * 40,
            "arm64",
            "b" * 64,
            changed or Mock(),
            timeout=1,
        )

    def publish(self, result=None):
        (self.output / "result.json").write_text(
            json.dumps(healthy() if result is None else result)
        )

    def test_complete_modeled_schema_admits_both_visibility_values_and_notification_counts(self):
        for count in (1, 2):
            result = healthy()
            result["ax_user_close"]["notifications"] *= count
            result["public_close"]["notifications"][0]["visible"] = False
            admit(result)

    def test_wrong_native_metadata_and_coercions_are_refused(self):
        for key, value in (
            ("pid", True),
            ("pid", 712),
            ("nonce", "foreign"),
            ("version", "1.0"),
            ("arch", "x86_64"),
            ("source_revision", "c" * 40),
            ("source_manifest_digest", "c" * 64),
        ):
            with self.subTest(key=key, value=value):
                result = healthy()
                result[key] = value
                with self.assertRaises(ValueError):
                    admit(result)

    def test_unknown_fields_skip_and_userdata_gc_claim_are_refused(self):
        for key, value in (("skip", True), ("modeled", True), ("ucc_userdata_gc", "qualified")):
            result = healthy()
            result[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_ax_refusal_cannot_use_a_delete_fallback(self):
        for value in (False, None, 1, "true"):
            result = healthy()
            result["ax_close_ack"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                admit(result)

    def test_missing_or_duplicated_cases_are_refused(self):
        for name in ("ax_user_close", "public_close"):
            result = healthy()
            del result[name]
            with self.subTest(name=name), self.assertRaises(ValueError):
                admit(result)
        result = healthy()
        result["third_close"] = deepcopy(result["public_close"])
        with self.assertRaises(ValueError):
            admit(result)

    def test_multiple_deletes_and_boolean_counter_are_refused(self):
        for name in ("ax_user_close", "public_close"):
            for count in (0, 2, True):
                result = healthy()
                result[name]["native_delete_requests"] = count
                with self.subTest(name=name, count=count), self.assertRaises(ValueError):
                    admit(result)

    def test_missing_consumption_detach_collection_and_timer_ack_are_refused(self):
        for name in ("ax_user_close", "public_close"):
            for field in (
                "userdata_consumed",
                "exact_bridge_detach",
                "consumed_before_detach",
                "callback_collected",
                "product_timer_retired",
                "callback_retained_before",
                "visible_before",
                "native_auto_delete_disabled",
            ):
                for value in (False, 1, None):
                    result = healthy()
                    if value is None:
                        del result[name][field]
                    else:
                        result[name][field] = value
                    with (
                        self.subTest(name=name, field=field, value=value),
                        self.assertRaises(ValueError),
                    ):
                        admit(result)

    def test_native_window_identity_is_a_positive_integer(self):
        for value in (0, True, "101", -1):
            result = healthy()
            result["ax_user_close"]["window_id"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                admit(result)

        for value in (True, 712, None):
            result = healthy()
            result["public_close"]["host_pid"] = value
            with self.subTest(host_pid=value), self.assertRaises(ValueError):
                admit(result)

    def test_missing_native_notification_or_visibility_is_refused(self):
        for value in ([], {}, None):
            result = healthy()
            result["ax_user_close"]["notifications"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                admit(result)
        for field, value in (
            ("visible_read", False),
            ("visible", 1),
            ("userdata_live_before", None),
            ("action", "simulated"),
            ("extra", True),
        ):
            result = healthy()
            result["public_close"]["notifications"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                admit(result)

    def test_product_timer_debt_and_missing_observed_return_are_refused(self):
        for key, value in (
            ("product_timer_final", 1),
            ("product_timer_baseline", True),
            ("product_timer_final", False),
            ("public_close_initial_return", None),
            ("observers_restored", False),
        ):
            result = healthy()
            result[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_child_is_observed_alive_before_and_after_receipt(self):
        self.publish()
        with patch.object(probe.time, "sleep") as sleep:
            result = self.observe()
        self.assertTrue(result["native_process_observed"])
        self.assertEqual(self.group.observe_exit.call_count, 2)
        sleep.assert_called_once_with(0.5)

    def test_child_exit_before_or_after_receipt_is_refused(self):
        self.publish()
        for observed in ((object(),), (None, object())):
            self.group.observe_exit.side_effect = observed
            with (
                self.subTest(observed=observed),
                patch.object(probe.time, "sleep"),
                self.assertRaises(ValueError),
            ):
                self.observe()

    def test_missing_receipt_times_out_without_a_native_success(self):
        with (
            patch.object(probe.time, "monotonic", side_effect=[0, 2]),
            self.assertRaisesRegex(ValueError, "deadline"),
        ):
            self.observe()

    def test_changed_source_and_changed_receipt_are_refused(self):
        self.publish()
        with self.assertRaisesRegex(ValueError, "changed source"):
            self.observe(Mock(side_effect=ValueError("changed source")))

        def mutate(_delay):
            self.publish({"status": "error"})

        with (
            patch.object(probe.time, "sleep", side_effect=mutate),
            self.assertRaisesRegex(ValueError, "changed"),
        ):
            self.observe()

    def test_missing_logs_and_real_native_or_product_errors_are_refused(self):
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            for message in (
                "NOREF/REFNIL",
                "C stack overflow",
                "NSInternalInconsistencyException",
                "ERROR product refused",
            ):
                path = self.output / name
                path.write_text(message)
                with self.subTest(name=name, message=message), self.assertRaises(ValueError):
                    probe.check_logs(self.output)
                path.write_text("")
            path.unlink()
            with self.assertRaises(ValueError):
                probe.check_logs(self.output)
            path.write_text("")

    def test_ci7_sentry_source_names_are_not_exceptions_but_real_failures_remain_refused(self):
        startup = (
            "[Sentry] [debug] [1792371722.8890882] [SentryCrashMonitor_NSException:126] Backing up original handler.\n"
            "[Sentry] [debug] [1792371722.8891] [SentryCrashMonitor_NSException:129] Setting new handler.\n"
        )
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            path = self.output / name
            path.write_text(startup)
            probe.check_logs(self.output)
            for failure in (
                "NSInternalInconsistencyException: udRef missing",
                "*** Terminating app due to uncaught exception 'NSInvalidArgumentException'",
                "[SentryCrashMonitor_NSException:126] ERROR genuine failure",
                "[SentryCrashMonitor_NSException:129] C stack overflow",
                "NOREF/REFNIL",
                "assertion failure",
                "ERRRUN",
                "exception in callback",
            ):
                path.write_text(startup + failure)
                with self.subTest(name=name, failure=failure), self.assertRaises(ValueError):
                    probe.check_logs(self.output)
            path.write_text("")

    def test_native_owner_still_alive_or_reservation_lost_is_refused(self):
        self.assertEqual(probe.validate_retirement(retired()), 711)
        for field, value in (
            ("closed", False),
            ("reservation_lost", True),
            ("live_group_members", [711]),
            ("worker_pid", True),
            ("group_id", 712),
        ):
            result = retired()
            result["native_owner"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_retirement(result)

    def test_owner_cleanup_errors_and_missing_execution_are_refused(self):
        for field, value in (
            ("status", "error"),
            ("native_execution", "unexecuted"),
            ("native_process_observed", False),
            ("operation_error", "native failure"),
            ("cleanup_errors", ["pending group"]),
        ):
            result = retired()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_retirement(result)

    def test_source_ownership_digest_changes_with_exact_bytes_and_refuses_symlink(self):
        repo = self.output / "repo"
        for relative in probe.DEPENDENCIES:
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        before = probe.source_identity(repo)
        path = repo / probe.DEPENDENCIES[0]
        path.write_text("changed")
        self.assertNotEqual(probe.source_identity(repo), before)
        path.unlink()
        path.symlink_to(repo / probe.DEPENDENCIES[1])
        with self.assertRaises(ValueError):
            probe.source_identity(repo)

    def prepare_repo(self):
        repo = self.output / "repo"
        for relative in probe.DEPENDENCIES:
            path = repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(relative)
        scratch = self.output / "scratch"
        scratch.mkdir()
        return repo, scratch

    def test_qualification_failure_retains_exact_owner_refusal_receipt(self):
        repo, scratch = self.prepare_repo()
        observed = Mock(return_value={"status": "error", "operation_error": "child refused"})
        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
        ):
            with self.assertRaises(ValueError):
                probe.qualify(
                    repo,
                    Path("/native/Hammerspoon"),
                    scratch,
                    self.output,
                    "1.1.1",
                    Mock(),
                    observed,
                    object(),
                )
        observed.assert_called_once()
        receipt = json.loads((self.output / "physical-shortcuts-close/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")
        self.assertEqual(receipt["operation_error"], "child refused")
        self.assertNotIn("native_execution", receipt)

    def test_qualification_source_drift_blocks_native_acquisition(self):
        repo, scratch = self.prepare_repo()
        observed = Mock()

        def change():
            (repo / probe.DEPENDENCIES[0]).write_text("drift")

        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
        ):
            with self.assertRaisesRegex(ValueError, "source changed"):
                probe.qualify(
                    repo,
                    Path("/native/Hammerspoon"),
                    scratch,
                    self.output,
                    "1.1.1",
                    change,
                    observed,
                    object(),
                )
        observed.assert_not_called()

    def test_qualification_forwards_real_profile_context_to_existing_supervisor(self):
        repo, scratch = self.prepare_repo()

        def observe(executable, startup, output, operation, native):
            self.assertEqual(executable, Path("/native/Hammerspoon"))
            self.assertTrue(startup.is_file())
            config = json.loads((startup.parent / "physical-config.json").read_text())
            self.assertEqual(config["production_root"], str(repo / "static/ergopti_plus"))
            self.assertEqual(config["output_dir"], str(output))
            result = healthy()
            result["nonce"] = config["nonce"]
            result["source_manifest_digest"] = config["source_manifest_digest"]
            for name in ("launch.stdout", "launch.stderr", "console.txt"):
                (output / name).write_text("")
            (output / "result.json").write_text(json.dumps(result))
            receipt = retired()
            receipt.update(operation(self.group))
            return receipt

        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
            patch.object(probe.time, "sleep"),
        ):
            receipt = probe.qualify(
                repo,
                Path("/native/Hammerspoon"),
                scratch,
                self.output,
                "1.1.1",
                Mock(),
                observe,
                object(),
            )
        self.assertEqual(receipt["status"], "ok")
        self.assertEqual(receipt["source_revision"], "a" * 40)
        self.assertEqual(self.group.observe_exit.call_count, 2)

    def test_qualification_last_source_fence_error_cannot_publish_success(self):
        repo, scratch = self.prepare_repo()

        def observe(executable, startup, output, operation, native):
            config = json.loads((startup.parent / "physical-config.json").read_text())
            result = healthy()
            result["nonce"] = config["nonce"]
            result["source_manifest_digest"] = config["source_manifest_digest"]
            for name in ("launch.stdout", "launch.stderr", "console.txt"):
                (output / name).write_text("")
            (output / "result.json").write_text(json.dumps(result))
            receipt = retired()
            receipt.update(operation(self.group))
            return receipt

        fences = []

        def unchanged():
            fences.append(True)
            if len(fences) == 4:
                (self.output / "physical-shortcuts-close/launch.stderr").write_text(
                    "ERROR late native boundary"
                )

        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
            patch.object(probe.time, "sleep"),
        ):
            with self.assertRaisesRegex(ValueError, "final native logs"):
                probe.qualify(
                    repo,
                    Path("/native/Hammerspoon"),
                    scratch,
                    self.output,
                    "1.1.1",
                    unchanged,
                    observe,
                    object(),
                )
        self.assertEqual(len(fences), 4)
        receipt = json.loads((self.output / "physical-shortcuts-close/supervisor.json").read_text())
        self.assertEqual(receipt["status"], "error")
        self.assertIn("runtime failure", receipt["final_log_error"])
        self.assertTrue(receipt["native_owner"]["closed"])


if __name__ == "__main__":
    unittest.main()
