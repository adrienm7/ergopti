# tools/diagnostics/macos_metrics_apps_page_test.py
"""Pure refusals and supervisor boundaries. No modeled packet is native WK evidence."""

import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import macos_metrics_apps_page as probe
import macos_tooltip_canvas as supervisor


def snapshot(
    editor=60000, browser=120000, edited=False, filtered=False, *, empty=False, selection=None
):
    """Independent ordinary example input for the parser, never a native receipt."""
    label = "Mon équipe" if edited else "constructor"
    times = (
        {}
        if empty
        else ({"Editor": editor} if filtered else {"Editor": editor, "Browser": browser})
    )
    if filtered and selection is None:
        selection = [label]
    return {
        "row_count": len(times),
        "rows": {
            name: {
                "category": label if name == "Editor" else "toString",
                "duration": {60000: "1m", 120000: "2m", 240000: "4m"}[ms],
            }
            for name, ms in times.items()
        },
        "times": times,
        "categories": {
            "Editor": {"type": label, "score": int(edited)},
            "Browser": {"type": "toString", "score": 0},
        },
        "by_category": {}
        if empty
        else {label: editor, **({} if filtered else {"toString": browser})},
        "pie_labels": [] if empty else ([label] if filtered else ["toString", label]),
        "pie_hours": []
        if empty
        else (
            [{60000: 0.02, 120000: 0.03}[editor]]
            if filtered
            else ([0.03, 0.02] if editor == 60000 else [0.07, 0.03])
        ),
        "filter_buttons": {
            label: selection is None or label in selection,
            "toString": selection is None or "toString" in selection,
        },
        "filter_selection": selection,
        "render_error": False,
        "script_errors": 0,
        "same_publishers": True,
        "chart_version": "4.4.9",
    }


def schema_example():
    """Explicit expected structure; native_execution is only added by a real supervisor."""
    return {
        "schema_version": 1,
        "contract": "native.metrics-apps-page",
        "scope": "actual UiBuilder and MetricsApps page; Host.show, SQLite and native choosers unmeasured",
        "native_input": "not attempted; JavaScript DOM click only",
        "ucc_userdata_gc": "unmeasured",
        "nonce": "owned-nonce",
        "source_revision": "a" * 40,
        "source_manifest_digest": "b" * 64,
        "pid": 711,
        "version": "1.1.1",
        "arch": "arm64",
        "status": "ok",
        "errors": [],
        "phase": "complete",
        "navigation_completed": True,
        "native_apis_unmodified": True,
        "filter_scope": "category rename and DOM filter with non-null selection; Host.show and persistence unmeasured",
        "readiness": {
            "data": "function",
            "categories": "function",
            "ready_state": "complete",
            "dependencies": ["function"] * 4,
            "private_owner_exposed": False,
            "chart_version": "4.4.9",
        },
        "steps": {
            "initial": {"applied": True, "snapshot": snapshot()},
            "filter": {"applied": True, "snapshot": snapshot(filtered=True)},
            "filter_reset": {"applied": True, "snapshot": snapshot()},
            "category_edit": {"applied": True, "snapshot": snapshot(edited=True)},
            "newer_manifest": {"applied": True, "snapshot": snapshot(120000, 240000, edited=True)},
            "stale": {"applied": False, "snapshot": snapshot(120000, 240000, edited=True)},
            "newer_categories": {"applied": True, "snapshot": snapshot(120000, 240000)},
            "select_before_rename": {
                "applied": True,
                "snapshot": snapshot(120000, 240000, filtered=True),
            },
            "rename_selected": {
                "applied": True,
                "snapshot": snapshot(
                    120000, 240000, edited=True, empty=True, selection=["constructor"]
                ),
            },
            "include_renamed": {
                "applied": True,
                "snapshot": snapshot(
                    120000,
                    240000,
                    edited=True,
                    filtered=True,
                    selection=["Mon équipe", "constructor"],
                ),
            },
            "include_remaining": {
                "applied": True,
                "snapshot": snapshot(120000, 240000, edited=True),
            },
            "restore_categories": {"applied": True, "snapshot": snapshot(120000, 240000)},
        },
        "native_message": {
            "name": "metrics_apps_bridge",
            "webview_type": "userdata",
            "webview_exact": True,
            "main_frame": True,
            "body": {"action": "edit", "app": "Editor", "cat": "constructor", "score": 0},
        },
        "cleanup": {
            "callback_detached": True,
            "window_consumed": True,
            "product_timer_baseline": 0,
            "product_timer_final": 0,
            "probe_timers_final": 0,
            "evaluation_pending": False,
        },
    }


def owner_example(result=None):
    """Model only terminal ownership metadata; the pure input cannot qualify Cocoa."""
    return {
        "status": "ok",
        "native_execution": "executed",
        "native_process_observed": True,
        "operation_error": None,
        "cleanup_errors": [],
        "result": result,
        "native_owner": {
            "closed": True,
            "reservation_lost": False,
            "live_group_members": [],
            "worker_pid": 711,
            "group_id": 711,
        },
    }


def wire_example(value):
    """Encode parser examples as the exact native JSON-string boundary, not native evidence."""
    value = json.loads(json.dumps(value))
    if isinstance(value.get("steps"), dict):
        value["steps"] = {
            name: json.dumps(step) if type(step) is dict else step
            for name, step in value["steps"].items()
        }
    return value


def admit(value):
    probe.validate(
        wire_example(value), 711, "1.1.1", "owned-nonce", "a" * 40, "arm64", "b" * 64, "4.4.9"
    )


class MetricsAppsPageControls(unittest.TestCase):
    """Exercise exact evidence rejection without constructing a synthetic native success."""

    def setUp(self):
        self.temporary = TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "output"
        self.output.mkdir()
        for name in ("launch.stdout", "launch.stderr", "console.txt"):
            (self.output / name).write_text("")
        self.group = Mock()
        self.group.process.pid = 711
        self.group.observe_exit.return_value = None

    def publish(self, value=None):
        (self.output / "result.json").write_text(
            json.dumps(wire_example(value or schema_example()))
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
            "4.4.9",
            unchanged or Mock(),
            timeout=1,
        )

    def source_fixture(self):
        repo = self.root / "repo"
        page = repo / probe.PAGE
        page.parent.mkdir(parents=True)
        scripts = [
            "../vendor/chart.umd.js",
            "../host_bridge.js",
            "../dom_utils.js",
            "../i18n.js",
            "../metrics_rebuild_banner.js",
            "helpers.js",
            "state.js",
            "main.js",
            "charts.js",
            "modal.js",
        ]
        page.write_text(
            "".join(f'<script src="{name}"></script>' for name in scripts)
            + '<link rel="stylesheet" href="style.css">'
        )
        for name in (*probe.DEPENDENCIES,):
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("-- pure source fixture\n")
        for name in (*scripts, "style.css"):
            target = page.parent / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("// pure source fixture\n")
        (repo / probe.CALLER).write_text(
            'return submit_javascript(generation, webview, "typeof window.publishMetricsAppsData", callback)'
        )
        (page.parent / "../vendor/chart.umd.js").write_text("/* Chart.js v4.4.9 */")
        return repo

    def test_ordinary_schema_admits_both_architectures_without_broadening_scope(self):
        admit(schema_example())
        result = schema_example()
        result["arch"] = "x86_64"
        probe.validate(
            wire_example(result), 711, "1.1.1", "owned-nonce", "a" * 40, "x86_64", "b" * 64, "4.4.9"
        )

    def test_native_identity_never_accepts_foreign_or_boolean_pid(self):
        for key, value in (
            ("pid", True),
            ("pid", 712),
            ("version", "other"),
            ("arch", "x86_64"),
            ("nonce", "other"),
            ("source_revision", "c" * 40),
            ("source_manifest_digest", "c" * 64),
        ):
            with self.subTest(key=key), self.assertRaises(ValueError):
                result = schema_example()
                result[key] = value
                admit(result)

    def test_missing_unknown_and_synthetic_scope_fields_refuse(self):
        for change in (
            lambda r: r.pop("readiness"),
            lambda r: r.update(skipped=True),
            lambda r: r.update(scope="Host.show and real database"),
            lambda r: r.update(native_input="physical input executed"),
            lambda r: r.update(ucc_userdata_gc="collected"),
        ):
            result = schema_example()
            change(result)
            with self.subTest(change=change), self.assertRaises(ValueError):
                admit(result)

    def test_readiness_requires_actual_functions_dependencies_and_completed_document(self):
        for key, value in (
            ("data", "undefined"),
            ("categories", "undefined"),
            ("ready_state", "loading"),
            ("dependencies", ["function"] * 3 + ["undefined"]),
            ("chart_version", "0"),
        ):
            result = schema_example()
            result["readiness"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_private_lexical_owner_and_unchanged_native_apis_are_required(self):
        for change in (
            lambda r: r["readiness"].update(private_owner_exposed=True),
            lambda r: r.update(native_apis_unmodified=False),
        ):
            result = schema_example()
            change(result)
            with self.subTest(change=change), self.assertRaises(ValueError):
                admit(result)

    def test_complete_closed_step_census_is_required(self):
        for change in (
            lambda r: r["steps"].pop("filter"),
            lambda r: r["steps"].update(skipped={}),
            lambda r: r["steps"].update(rename_selected=False),
            lambda r: r["steps"].update(rename_selected="{"),
        ):
            result = schema_example()
            change(result)
            with self.subTest(change=change), self.assertRaises(ValueError):
                admit(result)

    def test_applied_status_and_stale_rejection_are_not_truthy_casts(self):
        for key, value in (("initial", False), ("initial", 1), ("stale", True)):
            result = schema_example()
            result["steps"][key]["applied"] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_component_revisions_cannot_roll_back_other_owner(self):
        result = schema_example()
        result["steps"]["newer_manifest"]["snapshot"]["categories"]["Editor"] = {
            "type": "constructor",
            "score": 0,
        }
        with self.assertRaises(ValueError):
            admit(result)
        for step, field, value in (
            ("rename_selected", "filter_buttons", {"constructor": True, "toString": False}),
            ("include_renamed", "filter_selection", None),
            ("include_renamed", "row_count", 2),
            ("include_remaining", "filter_selection", ["Mon équipe", "constructor", "toString"]),
        ):
            result = schema_example()
            result["steps"][step]["snapshot"][field] = value
            with self.subTest(step=step, field=field), self.assertRaises(ValueError):
                admit(result)

    def test_dom_rows_labels_and_own_rollups_are_actual_facts(self):
        for change in (
            lambda s: s["rows"]["Editor"].update(category="Utilitaires"),
            lambda s: s["times"].update(Editor=True),
            lambda s: s["by_category"].pop("constructor"),
            lambda s: s.update(row_count=3),
        ):
            result = schema_example()
            change(result["steps"]["initial"]["snapshot"])
            with self.subTest(change=change), self.assertRaises(ValueError):
                admit(result)

    def test_actual_chart_inputs_and_script_health_are_mandatory(self):
        for key, value in (
            ("pie_labels", []),
            ("pie_hours", [0, 0]),
            ("render_error", True),
            ("script_errors", 1),
            ("same_publishers", False),
        ):
            result = schema_example()
            result["steps"]["initial"]["snapshot"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_native_channel_exact_view_body_and_main_frame_are_required(self):
        for change in (
            lambda m: m.update(name="foreign"),
            lambda m: m.update(webview_type="table"),
            lambda m: m.update(webview_exact=False),
            lambda m: m.update(main_frame=False),
            lambda m: m["body"].update(action="pick"),
            lambda m: m["body"].update(score=False),
        ):
            result = schema_example()
            change(result["native_message"])
            with self.subTest(change=change), self.assertRaises(ValueError):
                admit(result)

    def test_cleanup_false_nil_live_window_timer_and_pending_evaluation_refuse(self):
        for key, value in (
            ("callback_detached", False),
            ("callback_detached", None),
            ("window_consumed", False),
            ("product_timer_final", 1),
            ("product_timer_baseline", True),
            ("probe_timers_final", 1),
            ("evaluation_pending", True),
        ):
            result = schema_example()
            result["cleanup"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                admit(result)

    def test_process_retirement_requires_reserved_exact_empty_group(self):
        for change in (
            lambda r: r["native_owner"].update(closed=False),
            lambda r: r["native_owner"].update(reservation_lost=True),
            lambda r: r["native_owner"].update(live_group_members=[712]),
            lambda r: r["native_owner"].update(group_id=712),
            lambda r: r.update(cleanup_errors=["stop refused"]),
        ):
            result = owner_example()
            change(result)
            with self.subTest(change=change), self.assertRaises(ValueError):
                probe.validate_retirement(result)

    def test_source_manifest_uses_actual_declared_scripts_and_caller_query(self):
        repo = self.source_fixture()
        sources, digest = probe.source_identity(repo)
        self.assertEqual(len(digest), 64)
        self.assertTrue(any(name.endswith("modal.js") for name in sources))
        self.assertFalse(any(name.endswith("/script.js") for name in sources))
        self.assertEqual(
            probe.page_contract(repo), ("typeof window.publishMetricsAppsData", "4.4.9")
        )

    def test_missing_or_remote_asset_cannot_be_accepted(self):
        repo = self.source_fixture()
        page = repo / probe.PAGE
        (page.parent / "state.js").unlink()
        with self.assertRaises(ValueError):
            probe.source_identity(repo)
        page.write_text(
            page.read_text().replace('src="state.js"', 'src="https://invalid/state.js"')
        )
        with self.assertRaises(ValueError):
            probe.source_identity(repo)

    def test_asset_symlink_and_legacy_load_refuse(self):
        repo = self.source_fixture()
        page = repo / probe.PAGE
        state = page.parent / "state.js"
        state.unlink()
        state.symlink_to(page.parent / "main.js")
        with self.assertRaises(ValueError):
            probe.source_identity(repo)
        page.write_text(page.read_text().replace('src="state.js"', 'src="script.js"'))
        with self.assertRaises(ValueError):
            probe.source_identity(repo)

    def test_caller_query_or_vendor_version_cannot_be_guessed(self):
        repo = self.source_fixture()
        caller = repo / probe.CALLER
        captured = caller.read_text()
        (repo / probe.CALLER).write_text("-- missing query")
        with self.assertRaises(ValueError):
            probe.page_contract(repo)
        caller.write_text(captured)
        (repo / "static/ergopti_plus/_shared/ui/vendor/chart.umd.js").write_text(
            "// missing vendor"
        )
        with self.assertRaises(ValueError):
            probe.page_contract(repo)

    def test_supervisor_observes_real_boundary_contract_with_exact_live_owner(self):
        self.publish()
        with patch.object(probe.time, "sleep"):
            result = self.observe()
        self.assertEqual(result["native_execution"], "executed")
        self.assertEqual(self.group.observe_exit.call_count, 2)

    def test_owner_exit_and_replaced_result_refuse(self):
        self.publish()
        self.group.observe_exit.return_value = 0
        with self.assertRaises(ValueError):
            self.observe()
        self.group.observe_exit.return_value = None

        def replace(_delay):
            (self.output / "result.json").write_text("{}")

        with patch.object(probe.time, "sleep", side_effect=replace), self.assertRaises(ValueError):
            self.observe()

    def test_source_drift_missing_receipt_and_native_logs_refuse(self):
        self.publish()
        with self.assertRaisesRegex(ValueError, "drift"):
            self.observe(Mock(side_effect=ValueError("source drift")))
        (self.output / "result.json").unlink()
        with (
            patch.object(probe.time, "monotonic", side_effect=[0, 2]),
            self.assertRaises(ValueError),
        ):
            self.observe()
        (self.output / "launch.stderr").write_text("NSInternalInconsistencyException\n")
        with self.assertRaises(ValueError):
            probe.check_logs(self.output)

    def qualify(self, changed=None):
        repo = self.source_fixture()
        scratch = self.root / "scratch"
        scratch.mkdir()
        destination = self.output / "metrics-apps-page"
        calls = []

        def unchanged():
            calls.append(True)
            if changed:
                changed(len(calls), destination, scratch)

        def observe(_exe, _startup, output, operation, _native):
            for name in ("launch.stdout", "launch.stderr", "console.txt"):
                (output / name).write_text("")
            packet = schema_example()
            packet["source_manifest_digest"] = probe.source_identity(repo)[1]
            (output / "result.json").write_text(json.dumps(wire_example(packet)))
            return owner_example(operation(self.group)["result"])

        with (
            patch.object(probe, "revision", return_value="a" * 40),
            patch.object(probe.platform, "machine", return_value="arm64"),
            patch.object(probe.secrets, "token_hex", return_value="owned-nonce"),
            patch.object(probe.time, "sleep"),
        ):
            return probe.qualify(
                repo,
                Path("/pure-not-executed"),
                scratch,
                self.output,
                "1.1.1",
                unchanged,
                observe,
                object(),
            )

    def test_final_log_boundary_degrades_receipt_and_preserves_raw_error(self):
        def changed(count, output, _scratch):
            if count == 4:
                (output / "launch.stderr").write_text("late native exception retained\n")

        with self.assertRaises(ValueError):
            self.qualify(changed)
        result = json.loads((self.output / "metrics-apps-page/supervisor.json").read_text())
        self.assertEqual(result["status"], "error")
        self.assertIn("final_log_error", result)
        self.assertEqual(
            set(result["diagnostic_payload"]),
            {"macos_metrics_apps_page.lua", "metrics-page-config.json", "metrics-page-start.lua"},
        )
        self.assertIn(
            "late native exception", (self.output / "metrics-apps-page/launch.stderr").read_text()
        )

    def test_diagnostic_payload_drift_before_spawn_is_a_failure(self):
        def changed(count, _output, scratch):
            if count == 1:
                (scratch / "metrics-apps-page/metrics-page-start.lua").write_text("foreign")

        with self.assertRaisesRegex(ValueError, "diagnostic payload changed"):
            self.qualify(changed)

    def test_native_qualification_is_mandatory_after_earlier_supervisor_roles(self):
        """Run real orchestration with refused native boundary; do not merely grep its call."""
        app, scratch = self.root / "application", self.root / "outer-scratch"
        app.mkdir()
        scratch.mkdir()
        repo = Path(__file__).resolve().parents[2]
        with (
            patch.dict(sys.modules, {"PIL": SimpleNamespace(__version__="11.3.0")}),
            patch.object(supervisor.sys, "platform", "darwin"),
            patch.object(supervisor.sys, "version_info", (3, 13)),
            patch.object(supervisor.tempfile, "mkdtemp", return_value=str(scratch)),
            patch.object(supervisor, "identities", return_value={}),
            patch.object(supervisor, "digest", return_value="native-boundary-fixture"),
            patch.object(supervisor, "selected_version", return_value="1.1.1"),
            patch.object(
                supervisor,
                "admit_runtime",
                return_value={"executable_sha256": "native-boundary-fixture"},
            ),
            patch.object(supervisor.shutil, "copytree"),
            patch.object(supervisor.subprocess, "run"),
            patch.object(supervisor.owner, "NativeProcessGroups"),
            patch.object(supervisor, "owned_observation", return_value={"status": "ok"}),
            patch.object(supervisor, "qualify_script_scope", return_value={}),
            patch.object(supervisor, "qualify_webview_binding", return_value={}),
            patch.object(supervisor, "qualify_physical_shortcuts_close", return_value={}),
            patch.object(supervisor, "qualify_action_picker_pool", return_value={}),
            patch.object(supervisor, "qualify_layout_manager_pool", return_value={}),
            patch.object(supervisor, "qualify_permission_dialog_pool", return_value={}),
            patch.object(
                supervisor,
                "qualify_metrics_apps_page",
                side_effect=ValueError("native page refused"),
            ) as page,
        ):
            result = supervisor.run(repo, app, self.root / "outer-result")
        page.assert_called_once()
        self.assertEqual(result["status"], "error")
        self.assertEqual(result["error"], "native page refused")
        self.assertEqual(result["installed_package"], "unmeasured")


if __name__ == "__main__":
    unittest.main()
