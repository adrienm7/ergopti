# tools/diagnostics/macos_permission_dialog_pool_test.py
"""Pure schema/ownership refusals only; no modeled receipt qualifies native execution."""

from copy import deepcopy
import json
from pathlib import Path
import re
import shutil
import subprocess
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import macos_permission_dialog_pool as probe


def schema_example():
    """Describe the expected schema in memory; this is never a native observation."""
    case = {
        "window_id": 101,
        "host_pid": 711,
        "visible_before": True,
        "native_policy_observed": True,
        "retained_before": True,
        "business_settings": 1,
        "javascript_completed": True,
        "ax_close_ack": True,
        "userdata_consumed": True,
        "receiver_collected": True,
        "callback_collected": True,
        "sentinel_collected": True,
        "owner_closed_once": True,
        "product_timer_retired": True,
        "native_message": {
            "name": "permission_dialog_bridge",
            "webview_type": "userdata",
            "webview_exact": True,
            "dispatcher_exact": True,
            "message_parameter_observed": True,
        },
    }
    return {
        "schema_version": 1,
        "contract": probe.CONTRACT,
        "observation": probe.OBSERVATION,
        "native_identity": probe.IDENTITY_SCOPE,
        "weak_scope": probe.WEAK_SCOPE,
        "nonce": "owned-nonce",
        "source_revision": "a" * 40,
        "source_manifest_digest": "b" * 64,
        "pid": 711,
        "version": "1.1.1",
        "arch": "arm64",
        "status": "ok",
        "errors": [],
        "native_input": probe.INPUT_SCOPE,
        "business_scope": probe.BUSINESS_SCOPE,
        "ucc_userdata_gc": probe.GC_SCOPE,
        "native_apis_unmodified": True,
        "settings_callbacks_collected": True,
        "product_timer_baseline": 0,
        "product_timer_final": 0,
        "a_retired_before_b_open": True,
        "same_ucc_exact": True,
        "distinct_views": True,
        "a_settings_count_unchanged": True,
        "a": deepcopy(case),
        "b": deepcopy(case),
    }


def admit(value):
    probe.validate(value, 711, "1.1.1", "owned-nonce", "a" * 40, "arm64", "b" * 64)


def owner_example():
    """Model only the supervisor's retirement schema in disposable unit-test state."""
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


class PermissionDialogPoolControls(unittest.TestCase):
    """Keep modeled parser inputs separate from the mandatory real native run."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            (self.output / name).write_text("")
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None

    def publish(self, value=None):
        (self.output / "result.json").write_text(
            json.dumps(schema_example() if value is None else value)
        )

    def observe(self, unchanged=None):
        return probe.supervise(
            self.group,
            self.output,
            "1.1.1",
            "owned-nonce",
            "a" * 40,
            "arm64",
            "b" * 64,
            unchanged or Mock(),
            timeout=1,
        )

    def test_schema_keeps_private_observation_and_allows_sequential_os_window_id_reuse(
        self,
    ):
        admit(schema_example())

    def test_private_observer_cannot_be_relabelled_as_public_or_generic(self):
        for value in ("public getter", "generic UCC", "", None):
            result = schema_example()
            result["observation"] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                admit(result)

    def test_wrong_epoch_host_and_boolean_pid_refuse(self):
        for field, value in (
            ("pid", True),
            ("pid", 712),
            ("version", "foreign"),
            ("nonce", "foreign"),
            ("source_revision", "c" * 40),
            ("source_manifest_digest", "c" * 64),
            ("arch", "x86_64"),
        ):
            result = schema_example()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                admit(result)

    def test_unknown_skip_gc_and_physical_input_claims_refuse(self):
        for field, value in (
            ("skip", True),
            ("fake", True),
            ("ucc_userdata_gc", "qualified"),
            ("native_input", "physical"),
            ("native_identity", "direct raw envelope observed"),
            ("weak_scope", "native dispatcher collected"),
        ):
            result = schema_example()
            result[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                admit(result)

    def test_raw_native_message_fields_must_be_measured_exactly(self):
        for phase in ("a", "b"):
            for field in schema_example()[phase]["native_message"]:
                for value in (None, False, True, "true", "foreign", 1):
                    result = schema_example()
                    if value is None:
                        del result[phase]["native_message"][field]
                    else:
                        result[phase]["native_message"][field] = value
                    if probe.exact(
                        result[phase]["native_message"],
                        schema_example()[phase]["native_message"],
                    ):
                        continue
                    with (
                        self.subTest(phase=phase, field=field, value=value),
                        self.assertRaises(ValueError),
                    ):
                        admit(result)

    def test_missing_false_and_coerced_top_level_facts_refuse(self):
        original = schema_example()
        for field, current in original.items():
            if type(current) is not bool:
                continue
            for value in (None, False, 1, "true"):
                result = deepcopy(original)
                if value is None:
                    del result[field]
                else:
                    result[field] = value
                with (
                    self.subTest(field=field, value=value),
                    self.assertRaises(ValueError),
                ):
                    admit(result)

    def test_each_case_requires_native_and_javascript_outcomes_and_callback_retirement(
        self,
    ):
        for name in ("a", "b"):
            for field, value in schema_example()[name].items():
                for replacement in (None, False, 0, "true"):
                    result = schema_example()
                    if replacement is None:
                        del result[name][field]
                    else:
                        result[name][field] = replacement
                    with self.subTest(name=name, field=field, value=replacement):
                        with self.assertRaises(ValueError):
                            admit(result)

    def test_boolean_counts_and_native_window_ids_cannot_coerce_to_integers(self):
        for name in ("a", "b"):
            for field in ("business_settings", "window_id", "host_pid"):
                result = schema_example()
                result[name][field] = True
                with (
                    self.subTest(name=name, field=field),
                    self.assertRaises(ValueError),
                ):
                    admit(result)

    def test_ax_refusal_stays_failure_even_if_userdata_was_later_consumed(self):
        result = schema_example()
        result["a"]["ax_close_ack"] = False
        with self.assertRaises(ValueError):
            admit(result)

    def test_duplicate_refresh_and_missing_a_retirement_refuse(self):
        for name in ("a", "b"):
            result = schema_example()
            result[name]["business_settings"] = 3
            with self.subTest(name=name), self.assertRaises(ValueError):
                admit(result)
        result = schema_example()
        result["a_retired_before_b_open"] = False
        with self.assertRaises(ValueError):
            admit(result)

    def test_timer_debt_and_missing_baseline_refuse(self):
        for field, value in (
            ("product_timer_baseline", True),
            ("product_timer_baseline", -1),
            ("product_timer_final", 1),
            ("product_timer_final", False),
        ):
            result = schema_example()
            result[field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                admit(result)

    def test_native_errors_and_missing_logs_refuse(self):
        startup = (
            "[SentryCrashMonitor_NSException:126] Backing up original handler.\n"
            "[SentryCrashMonitor_NSException:129] Setting new handler.\n"
        )
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            path = self.output / name
            path.write_text(startup)
            probe.check_logs(self.output)
            for failure in (
                "hs.webview:error invoking _gc: C stack overflow",
                "NSInternalInconsistencyException",
                "*** Terminating app due to uncaught exception 'NSInvalidArgumentException'",
                "NSException: native binding refused",
                "NOREF/REFNIL",
                "assertion failure",
                "ERRRUN",
            ):
                path.write_text(startup + failure + "\n")
                with (
                    self.subTest(name=name, failure=failure),
                    self.assertRaises(ValueError),
                ):
                    probe.check_logs(self.output)
            path.write_text("")
        (self.output / "console.txt").unlink()
        with self.assertRaises(ValueError):
            probe.check_logs(self.output)

    def test_model_schema_checks_the_live_owner_before_and_after_observation(self):
        self.publish()
        with patch.object(probe.time, "sleep") as sleep:
            self.observe()
        self.assertEqual(self.group.observe_exit.call_count, 2)
        sleep.assert_called_once_with(0.5)

    def test_native_exit_before_or_after_receipt_refuses(self):
        self.publish()
        for values in ([0], [None, 0]):
            self.group.observe_exit.side_effect = values
            with patch.object(probe.time, "sleep"), self.assertRaises(ValueError):
                self.observe()

    def test_changed_payload_source_and_late_native_errors_refuse(self):
        self.publish()
        with self.assertRaisesRegex(ValueError, "changed"):
            self.observe(Mock(side_effect=ValueError("source changed")))
        with patch.object(
            probe.time,
            "sleep",
            side_effect=lambda _: (self.output / "launch.stderr").write_text("native ERROR\n"),
        ):
            with self.assertRaises(ValueError):
                self.observe()

    def test_result_redirection_mutation_and_unbounded_receipt_refuse(self):
        self.publish()
        path = self.output / "result.json"
        original = path.read_text()
        target = self.output / "foreign.json"
        path.rename(target)
        path.symlink_to(target)
        with self.assertRaises(ValueError):
            self.observe()
        path.unlink()
        path.write_text(original)
        with patch.object(probe.time, "sleep", side_effect=lambda _: path.write_text("{}")):
            with self.assertRaises(ValueError):
                self.observe()
        path.write_text(" " * 32769)
        with self.assertRaises(ValueError):
            self.observe()

    def test_missing_receipt_cannot_skip_native_execution(self):
        with patch.object(probe.time, "monotonic", side_effect=[0, 2]):
            with self.assertRaisesRegex(ValueError, "deadline"):
                self.observe()

    def test_source_manifest_tracks_frontend_pool_and_observer_consumers(self):
        repo = self.output / "repo"
        for name in probe.DEPENDENCIES:
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        before = probe.source_identity(repo)
        (repo / probe.DEPENDENCIES[1]).write_text("changed pool")
        self.assertNotEqual(probe.source_identity(repo), before)
        path = repo / probe.DEPENDENCIES[0]
        path.unlink()
        path.symlink_to(repo / probe.DEPENDENCIES[1])
        with self.assertRaises(ValueError):
            probe.source_identity(repo)

    def test_owner_retirement_never_hides_cleanup_or_live_group_debt(self):
        original = owner_example()
        self.assertEqual(probe.validate_retirement(original), 711)
        for field, value in (
            ("closed", False),
            ("reservation_lost", True),
            ("live_group_members", [712]),
            ("group_id", True),
        ):
            result = deepcopy(original)
            result["native_owner"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                probe.validate_retirement(result)
        original["cleanup_errors"] = ["debt"]
        with self.assertRaises(ValueError):
            probe.validate_retirement(original)

    def test_coordinator_freezes_the_observer_inside_a_disposable_unit_boundary(self):
        for mutate in (False, True):
            with (
                self.subTest(mutate=mutate),
                TemporaryDirectory(dir=self.output) as temporary,
            ):
                root = Path(temporary)
                repo, scratch, output = root / "repo", root / "scratch", root / "output"
                scratch.mkdir()
                output.mkdir()
                for name in probe.DEPENDENCIES:
                    path = repo / name
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("unit source: " + name)

                def boundary(executable, startup, destination, _operation, native):
                    # This unit boundary never runs Hammerspoon, JS or a bridge.
                    self.assertIs(native, self.group)
                    self.assertEqual(executable, Path("/unit-only/Hammerspoon"))
                    observer = startup.parent / "macos_permission_dialog_pool_observer.lua"
                    expected = Path(probe.__file__).with_name(observer.name)
                    self.assertEqual(observer.read_bytes(), expected.read_bytes())
                    settings = json.loads(
                        (startup.parent / "permission-dialog-config.json").read_text()
                    )
                    result = schema_example()
                    result.update(
                        nonce=settings["nonce"],
                        source_revision=settings["source_revision"],
                        source_manifest_digest=settings["source_manifest_digest"],
                    )
                    for name in ("launch.stdout", "launch.stderr", "console.txt"):
                        (destination / name).write_text("")
                    receipt = owner_example()
                    receipt["result"] = result
                    if mutate:
                        observer.write_text("changed private observer")
                    return receipt

                with (
                    patch.object(probe, "revision", return_value="a" * 40),
                    patch.object(probe.platform, "machine", return_value="arm64"),
                ):
                    arguments = (
                        repo,
                        Path("/unit-only/Hammerspoon"),
                        scratch,
                        output,
                        "1.1.1",
                        Mock(),
                        boundary,
                        self.group,
                    )
                    if mutate:
                        with self.assertRaisesRegex(ValueError, "payload changed"):
                            probe.qualify(*arguments)
                    else:
                        receipt = probe.qualify(*arguments)
                        self.assertEqual(receipt["observation"], probe.OBSERVATION)
                persisted = json.loads(
                    (output / "permission-dialog-pool/supervisor.json").read_text()
                )
                self.assertEqual(persisted["status"], "error" if mutate else "ok")

    def test_final_log_collection_cannot_leave_a_green_supervisor_receipt(self):
        repo, scratch, output = (
            self.output / "repo",
            self.output / "scratch",
            self.output / "out",
        )
        scratch.mkdir()
        output.mkdir()
        for name in probe.DEPENDENCIES:
            path = repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("unit-only source: " + name)

        def boundary(_executable, startup, destination, _operation, _native):
            settings = json.loads((startup.parent / "permission-dialog-config.json").read_text())
            result = schema_example()
            result.update(
                nonce=settings["nonce"],
                source_revision=settings["source_revision"],
                source_manifest_digest=settings["source_manifest_digest"],
            )
            for name in ("launch.stdout", "launch.stderr", "console.txt"):
                (destination / name).write_text("")
            return dict(owner_example(), result=result)

        original, calls = probe.check_logs, []

        def final_native_error(destination):
            calls.append(destination)
            if len(calls) == 2:
                (destination / "launch.stderr").write_text("native ERROR after last admission\n")
            original(destination)

        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
            patch.object(probe, "check_logs", side_effect=final_native_error),
        ):
            with self.assertRaisesRegex(ValueError, "final native logs refused"):
                probe.qualify(
                    repo,
                    Path("/unit-only/Hammerspoon"),
                    scratch,
                    output,
                    "1.1.1",
                    Mock(),
                    boundary,
                    self.group,
                )
        persisted = json.loads((output / "permission-dialog-pool/supervisor.json").read_text())
        self.assertEqual(len(calls), 2)
        self.assertEqual(persisted["status"], "error")
        self.assertIn("native runtime failure", persisted["final_log_error"])

    def expressions(self):
        source = Path(probe.__file__).with_suffix(".lua").read_text()
        matches = re.findall(
            r"entry\.view:evaluateJavaScript\((.*?),\s*function\(\w+,\s*\w+\)",
            source,
            re.S,
        )
        self.assertEqual(len(matches), 2)
        return [
            "".join(json.loads(value) for value in re.findall(r'"(?:\\.|[^"\\])*"', match))
            for match in matches
        ]

    def javascript_control(self, script, expression):
        node = shutil.which("node")
        self.assertIsNotNone(node, "Node is required for the actual expression control")
        result = subprocess.run(
            [node, "-e", script, json.dumps(expression)],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        self.assertEqual(result.stdout, "EXPRESSION_ONLY_PASS\n")

    def test_real_settings_expression_clicks_once_and_returns_a_primitive(self):
        # This measures only the diagnostic expression against a controlled DOM.
        # It never qualifies WebKit, the product frontend, routing or Cocoa.
        expression = next(value for value in self.expressions() if "button.click()" in value)
        self.javascript_control(
            """
const vm=require('node:vm'); const expression=JSON.parse(process.argv[1]);
let clicks=0; const button={disabled:false,onclick(){},click(){clicks++;}};
const context={document:{getElementById(id){if(id!=='open')throw Error('wrong id');return button;}}};
if(vm.runInNewContext(expression,context)!==true || clicks!==1)throw Error('primitive/click contract');
for(const state of [null,{disabled:true,onclick(){}},{disabled:false}]){
 let threw=false;
 try{vm.runInNewContext(expression,{document:{getElementById(){return state;}}});}catch(e){threw=true;}
 if(!threw)throw Error('unready button admitted');
}
const old=expression.replace(/; true$/, '');
if(old===expression || vm.runInNewContext(old,{document:context.document})===true)throw Error('causal refusal absent');
process.stdout.write('EXPRESSION_ONLY_PASS\\n');
""",
            expression,
        )

    def test_real_readiness_expression_waits_for_the_actual_bound_button(self):
        expression = next(value for value in self.expressions() if value.startswith("Boolean("))
        self.javascript_control(
            """
const vm=require('node:vm'); const expression=JSON.parse(process.argv[1]);
for(const [button,expected] of [[null,false],[{},false],[{disabled:true,onclick(){}},false],[{disabled:false,onclick(){}},true]]){
 const context={document:{getElementById(id){if(id!=='open')throw Error('wrong id');return button;}}};
 if(vm.runInNewContext(expression,context)!==expected)throw Error('readiness contract');
}
process.stdout.write('EXPRESSION_ONLY_PASS\\n');
""",
            expression,
        )


if __name__ == "__main__":
    unittest.main()
