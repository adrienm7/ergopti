// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274PermissionDialogQualificationTests.swift
// Actual native UI only; guardian/settings endpoints are explicitly modeled.
import CoreFoundation
import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPermissionDialogReceiptRefusesIncompleteNativeUIControls() throws {
		try fixture { root in
			let controller = root.appendingPathComponent("permission-ui.py")
			try Data(Self.permissionDialogController.utf8).write(to: controller, options: .atomic)
			let repository = source("hs_permission_dialog_native.lua").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path, "--portable"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS permission UI portable receipt controls tests=17 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.isEmpty)
		}
	}

	func testActualPermissionDialogsSequenceBridgeDismissalAndObservedReadyClose() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let controller = root.appendingPathComponent("permission-ui.py")
			try Data(Self.permissionDialogController.utf8).write(to: controller, options: .atomic)
			let repository = source("hs_permission_dialog_native.lua").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Actual native permission UI refused within SDK30/35/10; evidence: " + root.path
				+ "; " + Self.permissionUiDiagnosticSummary(receipt.stderr))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(packet["status"] as? String, "ok")
			XCTAssertEqual(packet["qualification"] as? String, "actual native permission UI with modeled guardian")
			XCTAssertEqual(packet["controller_budget_seconds"] as? Int, 25)
			let elapsed = try XCTUnwrap(packet["observation_retirement_seconds"] as? Double)
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0 && elapsed < 25)
			let native = try XCTUnwrap(packet["native_result"] as? [String: Any])
			let cases = try XCTUnwrap(native["case_results"] as? [[String: Any]])
			XCTAssertEqual(cases.compactMap { $0["id"] as? String }, [
				"tap_holds_off_keeps_banner", "accessibility_precedes_login_items",
				"accessibility_later_native_bridge", "login_items_native_dom_and_window",
				"unknown_status_keeps_steps", "open_settings_native_bridge",
				"later_dismisses_and_spends_offer", "explicit_reopen_creates_new_view",
				"native_delete_reports_close", "observed_ready_auto_closes",
			])
			XCTAssertTrue(cases.allSatisfy { ($0["passed"] as? Bool) == true })
			XCTAssertEqual(native["action_kind"] as? String, "synthetic DOM actions through native WK usercontent")
			let authority = try XCTUnwrap(native["authority"] as? [String: Any])
			XCTAssertEqual(authority["guardian"] as? String, "modeled")
			XCTAssertEqual(authority["settings_opener"] as? String, "modeled")
			for flag in ["physical_click", "permission_granted", "system_settings_opened", "activation"] {
				XCTAssertEqual(authority[flag] as? Bool, false)
			}
			let artifact = try Self.persistLegacyCleanupReceipt(receipt.stdout, parent: parent,
				name: "legacy-cleanup-receipt-" + UUID().uuidString + ".json")
			print("ERGOPTI_PERMISSION_UI_RECEIPT " + artifact.name + " cases=10", terminator: "\n")
		}
	}


	func testPortablePermissionUiFailureObservationsRemainClosedAndNonAuthoritative() throws {
		try fixture { root in
			let controller = root.appendingPathComponent("permission-ui-diagnostics.py")
			try Data(Self.permissionDialogController.utf8).write(to: controller, options: .atomic)
			let repository = source("hs_permission_dialog_native.lua").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path,
					"--portable-diagnostics"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS permission UI diagnostic controls tests=16 failures=0 errors=0 skipped=0; native unexecuted\n")
			XCTAssertTrue(receipt.stderr.isEmpty)
		}
	}

	private static func permissionUiDiagnosticSummary(_ stderr: String) -> String {
		let unsupported = "UI observation unsupported"
		guard stderr.utf8.count <= 8192,
			let first = stderr.split(separator: "\n", omittingEmptySubsequences: false).first else {
			return unsupported
		}
		let prefix = "ERGOPTI_PERMISSION_UI_DIAGNOSTIC "
		guard first.hasPrefix(prefix), first.utf8.count <= 1024,
			let data = String(first.dropFirst(prefix.count)).data(using: .utf8),
			let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(packet.keys) == Set(["schema", "status", "kind", "authority", "native_verdict", "check",
				"completed_cases", "last_completed_case", "next_expected_case"]),
			let schema = packet["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
			Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: schema.objCType)),
			schema.doubleValue == 1,
			packet["kind"] as? String == "permission_ui_failure_observation",
			packet["native_verdict"] as? String == "unchanged",
			let authority = packet["authority"] as? NSNumber, CFGetTypeID(authority) == CFBooleanGetTypeID(),
			!authority.boolValue,
			let count = packet["completed_cases"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(),
			Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: count.objCType)),
			count.doubleValue.isFinite, count.doubleValue.rounded() == count.doubleValue,
			count.doubleValue >= 0, count.doubleValue <= 10,
			let canonical = try? JSONSerialization.data(withJSONObject: packet,
				options: [.sortedKeys, .withoutEscapingSlashes]), canonical == data else { return unsupported }
		// Position in the actual completed prefix is not an observation of native execution stage.
		let cases = [
			"tap_holds_off_keeps_banner",
			"accessibility_precedes_login_items",
			"accessibility_later_native_bridge",
			"login_items_native_dom_and_window",
			"unknown_status_keeps_steps",
			"open_settings_native_bridge",
			"later_dismisses_and_spends_offer",
			"explicit_reopen_creates_new_view",
			"native_delete_reports_close",
			"observed_ready_auto_closes",
		]
		let checks: Set<String> = [
			"accessibility_close_debt",
			"accessibility_dialog_refused",
			"accessibility_dom_refused",
			"approval_close_debt",
			"approval_reopen_refused",
			"automatic_offer_unspent",
			"disabled_guide_resources",
			"explicit_reopen_refused",
			"explicit_view_reused",
			"factory_observer_changed",
			"geometry_mismatch",
			"guide_budget_changed",
			"guide_queue_refused",
			"javascript_overlap",
			"later_close_debt",
			"login_items_dom_incomplete",
			"login_items_dom_refused",
			"native_close_debt",
			"native_view_missing",
			"native_window_id_unknown",
			"observer_timer_debt",
			"probe_deadline",
			"queued_view_duplicate",
			"queued_view_reused",
			"receipt_encoding_failed",
			"settings_dom_refused",
			"settings_ownership_changed",
			"unexpected_actions",
			"unknown_status_dismissal",
			"wk_evaluation_failed",
		]
		let completed = count.intValue
		guard packet["status"] as? String == "observed",
			let check = packet["check"] as? String, checks.contains(check) else { return unsupported }
		let last = completed == 0 ? "none" : cases[completed - 1]
		let next = completed == cases.count ? "none" : cases[completed]
		guard (completed == 0 ? packet["last_completed_case"] is NSNull
			: packet["last_completed_case"] as? String == last),
			(completed == cases.count ? packet["next_expected_case"] is NSNull
				: packet["next_expected_case"] as? String == next) else { return unsupported }
		return "UI check=\(check) completed=\(completed) last=\(last) next=\(next)"
	}

	func testPermissionUiFailureSummaryRejectsPrivateAndMalformedFields() {
		let observed = #"ERGOPTI_PERMISSION_UI_DIAGNOSTIC {"authority":false,"check":"guide_queue_refused","completed_cases":2,"kind":"permission_ui_failure_observation","last_completed_case":"accessibility_precedes_login_items","native_verdict":"unchanged","next_expected_case":"accessibility_later_native_bridge","schema":1,"status":"observed"}"# + "\n"
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed),
			"UI check=guide_queue_refused completed=2 last=accessibility_precedes_login_items next=accessibility_later_native_bridge")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed + "private traceback: SECRET/path\n"),
			Self.permissionUiDiagnosticSummary(observed))
		XCTAssertEqual(Self.permissionUiDiagnosticSummary("private traceback: SECRET/path\n"), "UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "guide_queue_refused", with: "SECRET")),
			"UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"private\":\"SECRET\"")),
			"UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "\"completed_cases\":2", with: "\"completed_cases\":true")),
			"UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "\"authority\":false", with: "\"authority\":true")),
			"UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1.0")),
			"UI observation unsupported")
		XCTAssertEqual(Self.permissionUiDiagnosticSummary(observed.replacingOccurrences(of: "\"completed_cases\":2", with: "\"completed_cases\":2.0")),
			"UI observation unsupported")
	}

	private static let permissionDialogController = #"""
	"""Actual private WebKit permission UI, with modeled guardian/settings leaf endpoints."""

	import argparse
	import copy
	import hashlib
	import json
	import math
	from pathlib import Path
	import shutil
	import sys
	import time
	import tempfile
	import uuid

	CASES = (
	    "tap_holds_off_keeps_banner",
	    "accessibility_precedes_login_items",
	    "accessibility_later_native_bridge",
	    "login_items_native_dom_and_window",
	    "unknown_status_keeps_steps",
	    "open_settings_native_bridge",
	    "later_dismisses_and_spends_offer",
	    "explicit_reopen_creates_new_view",
	    "native_delete_reports_close",
	    "observed_ready_auto_closes",
	)
	AUTHORITY = {
	    "guardian": "modeled",
	    "settings_opener": "modeled",
	    "physical_click": False,
	    "permission_granted": False,
	    "system_settings_opened": False,
	    "activation": False,
	}
	ACTION = "synthetic DOM actions through native WK usercontent"


	def require(condition, message):
	    if not condition:
	        raise ValueError(message)


	def inventory(repo):
	    paths = set()
	    for subtree in ("static/ergopti_plus/macos", "static/ergopti_plus/_shared"):
	        for path in (repo / subtree).rglob("*"):
	            if path.suffix in (".lua", ".json", ".toml") and path.is_file():
	                require(not path.is_symlink(), "Redirected production source")
	                paths.add(path.relative_to(repo).as_posix())
	    paths.update(
	        (
	            "tools/diagnostics/hs_permission_dialog_native.lua",
	            "tools/diagnostics/macos_physical_clock.py",
	            "tools/diagnostics/macos_tooltip_canvas.py",
	            "tools/diagnostics/macos_owned_process.py",
	            "static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274PermissionDialogQualificationTests.swift",
	            ".github/workflows/ci.yml",
	        )
	    )
	    return {path: hashlib.sha256((repo / path).read_bytes()).hexdigest() for path in sorted(paths)}


	def admit(packet, report, pid, nonce, version, before, after, now, deadline):
	    fields = {
	        "schema",
	        "status",
	        "runtime",
	        "pid",
	        "nonce",
	        "version",
	        "case_results",
	        "window_ids",
	        "settings_calls",
	        "guide_active",
	        "dialog_open",
	        "active_timers",
	        "factory_restored",
	        "action_kind",
	        "retired_views",
	        "authority",
	        "failure",
	    }
	    require(type(packet) is dict and set(packet) == fields, "Unexpected native receipt fields")
	    require(
	        type(packet["schema"]) is int
	        and packet["schema"] == 1
	        and packet["status"] == "ok"
	        and packet["runtime"] == "native Hammerspoon"
	        and packet["failure"] == "",
	        "Native UI operation refused",
	    )
	    require(
	        type(pid) is int
	        and pid > 0
	        and type(packet["pid"]) is int
	        and packet["pid"] == pid
	        and type(nonce) is str
	        and len(nonce) == 32
	        and packet["nonce"] == nonce
	        and type(version) is str
	        and bool(version)
	        and packet["version"] == version,
	        "Foreign native runtime identity",
	    )
	    results = packet["case_results"]
	    require(type(results) is list and len(results) == len(CASES), "Incomplete native cases")
	    for expected, result in zip(CASES, results, strict=True):
	        require(
	            type(result) is dict
	            and set(result) == {"id", "passed"}
	            and result["id"] == expected
	            and result["passed"] is True,
	            "Native case order or literal acknowledgement differs",
	        )
	    ids = packet["window_ids"]
	    require(
	        type(ids) is list and len(ids) == 4 and all(type(x) is int and x > 0 for x in ids),
	        "Missing actual native window IDs",
	    )
	    require(
	        type(packet["settings_calls"]) is int
	        and packet["settings_calls"] == 1
	        and packet["guide_active"] is False
	        and packet["dialog_open"] is False
	        and type(packet["active_timers"]) is int
	        and packet["active_timers"] == 0
	        and packet["factory_restored"] is True
	        and type(packet["retired_views"]) is int
	        and packet["retired_views"] == 4,
	        "Production UI retirement incomplete",
	    )
	    require(packet["action_kind"] == ACTION, "Synthetic action provenance missing")
	    authority = packet["authority"]
	    require(
	        type(authority) is dict
	        and set(authority) == set(AUTHORITY)
	        and all(
	            type(authority[key]) is type(value) and authority[key] == value
	            for key, value in AUTHORITY.items()
	        ),
	        "Fixture cannot grant authority",
	    )
	    require(type(before) is dict and bool(before) and before == after, "Production source changed")
	    require(
	        type(now) in (int, float)
	        and type(deadline) in (int, float)
	        and 0 <= now < deadline <= 1e12
	        and math.isfinite(now)
	        and math.isfinite(deadline),
	        "Observation deadline expired",
	    )
	    # This checks a genuine post-operation group receipt only in the native route.
	    clock.validate_owner(report, pid)
	    return {
	        "status": "ok",
	        "qualification": "actual native permission UI with modeled guardian",
	        "controller_budget_seconds": 25,
	        "native_result": packet,
	        "native_owner": report["native_owner"],
	        "source_inventory": before,
	    }


	def portable():
	    packet = {
	        "schema": 1,
	        "status": "ok",
	        "runtime": "native Hammerspoon",
	        "pid": 41,
	        "nonce": "1" * 32,
	        "version": "1.1.1",
	        "case_results": [{"id": case, "passed": True} for case in CASES],
	        "window_ids": [1, 2, 3, 4],
	        "settings_calls": 1,
	        "guide_active": False,
	        "dialog_open": False,
	        "active_timers": 0,
	        "factory_restored": True,
	        "retired_views": 4,
	        "action_kind": ACTION,
	        "authority": dict(AUTHORITY),
	        "failure": "",
	    }
	    report = {
	        "status": "ok",
	        "native_owner": {
	            "worker_pid": 41,
	            "group_id": 41,
	            "closed": True,
	            "reservation_lost": False,
	            "live_group_members": [],
	            "escaped_sessions_managed": False,
	        },
	    }
	    before = {"actual-source.lua": "a" * 64}
	    admit(packet, report, 41, "1" * 32, "1.1.1", before, before, 1.0, 2.0)
	    mutations = (
	        ("pid", 42),
	        ("nonce", "2" * 32),
	        ("version", "unknown"),
	        ("case_results", []),
	        ("case_results", list(reversed(packet["case_results"]))),
	        ("case_results", [{"id": CASES[0], "passed": 1}] + packet["case_results"][1:]),
	        ("window_ids", [0, 2, 3, 4]),
	        ("active_timers", 1),
	        ("factory_restored", False),
	        ("retired_views", 0),
	    )
	    count = 1
	    for key, value in mutations:
	        changed = copy.deepcopy(packet)
	        changed[key] = value
	        refuses(lambda: admit(changed, report, 41, "1" * 32, "1.1.1", before, before, 1.0, 2.0))
	        count += 1
	    changed_report = copy.deepcopy(report)
	    changed_report["native_owner"]["closed"] = False
	    refuses(lambda: admit(packet, changed_report, 41, "1" * 32, "1.1.1", before, before, 1.0, 2.0))
	    count += 1
	    refuses(lambda: admit(packet, report, 41, "1" * 32, "1.1.1", before, {"other": "b"}, 1.0, 2.0))
	    count += 1
	    refuses(lambda: admit(packet, report, 41, "1" * 32, "1.1.1", before, before, 2.0, 2.0))
	    count += 1
	    changed = copy.deepcopy(packet)
	    changed["authority"]["permission_granted"] = True
	    refuses(lambda: admit(changed, report, 41, "1" * 32, "1.1.1", before, before, 1.0, 2.0))
	    count += 1
	    changed = copy.deepcopy(packet)
	    changed["action_kind"] = "physical click"
	    refuses(lambda: admit(changed, report, 41, "1" * 32, "1.1.1", before, before, 1.0, 2.0))
	    count += 1
	    with tempfile.TemporaryDirectory(prefix="permission-ui-portable-") as temporary:
	        path = Path(temporary).resolve() / "duplicate.json"
	        path.write_text('{"schema":1,"\\u0073chema":1}')
	        refuses(lambda: clock.read_receipt(path))
	    count += 1
	    require(count == 17, "Portable case inventory differs")
	    print("PASS permission UI portable receipt controls tests=17 failures=0 errors=0 skipped=0")


	def refuses(operation):
	    try:
	        operation()
	    except ValueError:
	        return
	    raise ValueError("Malformed receipt was admitted")


	DIAGNOSTIC_PREFIX = "ERGOPTI_PERMISSION_UI_DIAGNOSTIC "
	DIAGNOSTIC_CHECKS = {
	    "Actual native view missing": "native_view_missing",
	    "Actual native window ID unavailable": "native_window_id_unknown",
	    "Overlapping native JavaScript operation": "javascript_overlap",
	    "Actual WK evaluation failed": "wk_evaluation_failed",
	    "Production factory observer changed": "factory_observer_changed",
	    "Actual observer timer did not retire": "observer_timer_debt",
	    "Native receipt encoding failed": "receipt_encoding_failed",
	    "Actual UI probe deadline exceeded": "probe_deadline",
	    "Production guide budgets changed": "guide_budget_changed",
	    "Disabled tap-holds created guide resources": "disabled_guide_resources",
	    "Actual accessibility dialog refused": "accessibility_dialog_refused",
	    "Login Items did not queue behind Accessibility": "guide_queue_refused",
	    "Accessibility DOM action refused": "accessibility_dom_refused",
	    "Queued Login Items duplicated views": "queued_view_duplicate",
	    "Accessibility native window survived Later": "accessibility_close_debt",
	    "Queued native view reused prior object": "queued_view_reused",
	    "Actual Login Items DOM incomplete": "login_items_dom_incomplete",
	    "Actual view did not consume shared geometry": "geometry_mismatch",
	    "Unknown status dismissed actual guide": "unknown_status_dismissal",
	    "Settings DOM action refused": "settings_dom_refused",
	    "Native settings message changed guide ownership": "settings_ownership_changed",
	    "Login Items DOM action refused": "login_items_dom_refused",
	    "Later left production window/poll debt": "later_close_debt",
	    "Automatic offer was not spent": "automatic_offer_unspent",
	    "Explicit reopen refused": "explicit_reopen_refused",
	    "Explicit reopen reused prior view": "explicit_view_reused",
	    "Native close left production poll/window debt": "native_close_debt",
	    "Approval reopen refused": "approval_reopen_refused",
	    "Approval left native window/poll debt": "approval_close_debt",
	    "Unexpected settings/view action": "unexpected_actions",
	}
	DIAGNOSTIC_RECEIPT_FIELDS = {
	    "authority",
	    "runtime",
	    "case_results",
	    "dialog_open",
	    "guide_active",
	    "pid",
	    "failure",
	    "factory_restored",
	    "version",
	    "status",
	    "nonce",
	    "retired_views",
	    "action_kind",
	    "window_ids",
	    "settings_calls",
	    "active_timers",
	    "schema",
	}


	def failure_observation(packet, report, pid, nonce, version, before, after, now, deadline):
	    """Report only closed failure facts, never grant native case or retirement authority."""
	    unsupported = {
	        "schema": 1,
	        "status": "unsupported",
	        "kind": "permission_ui_failure_observation",
	        "authority": False,
	        "native_verdict": "unchanged",
	        "check": "unclassified",
	        "completed_cases": 0,
	        "last_completed_case": None,
	        "next_expected_case": None,
	    }
	    try:
	        require(
	            type(packet) is dict and set(packet) == DIAGNOSTIC_RECEIPT_FIELDS,
	            "Unsupported failure facts",
	        )
	        require(
	            type(packet["schema"]) is int
	            and packet["schema"] == 1
	            and packet["status"] == "error"
	            and packet["runtime"] == "native Hammerspoon",
	            "Unsupported failure facts",
	        )
	        require(
	            type(pid) is int
	            and pid > 0
	            and type(packet["pid"]) is int
	            and packet["pid"] == pid
	            and type(nonce) is str
	            and len(nonce) == 32
	            and packet["nonce"] == nonce
	            and type(version) is str
	            and bool(version)
	            and packet["version"] == version,
	            "Unsupported failure identity",
	        )
	        require(
	            type(before) is dict and bool(before) and before == after, "Unsupported source facts"
	        )
	        require(
	            type(now) in (int, float)
	            and type(deadline) in (int, float)
	            and math.isfinite(now)
	            and math.isfinite(deadline)
	            and 0 <= now < deadline <= 1e12,
	            "Unsupported observation point",
	        )
	        clock.validate_owner(report, pid)
	        results = packet["case_results"]
	        require(type(results) is list and 0 <= len(results) <= len(CASES), "Unsupported prefix")
	        for expected, row in zip(CASES, results):
	            require(
	                type(row) is dict
	                and set(row) == {"id", "passed"}
	                and row["id"] == expected
	                and row["passed"] is True,
	                "Unsupported prefix",
	            )
	        failure = packet["failure"]
	        require(
	            type(failure) is str and 0 < len(failure.encode("utf-8")) <= 8192, "Unsupported failure"
	        )
	        # Only a fixed native check literal is observed; traceback or foreign text is never copied.
	        check = DIAGNOSTIC_CHECKS.get(failure.split("\n", 1)[0])
	        require(check is not None, "Unsupported check")
	        count = len(results)
	        return dict(
	            unsupported,
	            status="observed",
	            check=check,
	            completed_cases=count,
	            last_completed_case=CASES[count - 1] if count else None,
	            next_expected_case=CASES[count] if count < len(CASES) else None,
	        )
	    except Exception:
	        return unsupported


	def diagnostic_line(value):
	    return DIAGNOSTIC_PREFIX + json.dumps(
	        value, sort_keys=True, separators=(",", ":"), allow_nan=False
	    )


	def portable_diagnostics():
	    # Handwritten expectations were frozen before code; every native endpoint is modeled here.
	    packet = {
	        "schema": 1,
	        "status": "error",
	        "runtime": "native Hammerspoon",
	        "pid": 41,
	        "nonce": "1" * 32,
	        "version": "1.1.1",
	        "case_results": [{"id": CASES[0], "passed": True}, {"id": CASES[1], "passed": True}],
	        "window_ids": [1],
	        "settings_calls": 0,
	        "guide_active": True,
	        "dialog_open": True,
	        "active_timers": 1,
	        "factory_restored": True,
	        "retired_views": 0,
	        "action_kind": ACTION,
	        "authority": dict(AUTHORITY),
	        "failure": "Login Items did not queue behind Accessibility",
	    }
	    report = {
	        "status": "ok",
	        "native_owner": {
	            "worker_pid": 41,
	            "group_id": 41,
	            "closed": True,
	            "reservation_lost": False,
	            "live_group_members": [],
	            "escaped_sessions_managed": False,
	        },
	    }
	    sources = {"source.lua": "a" * 64}
	    scenarios = []
	    for name in (
	        "known_check",
	        "traceback_payload_omitted",
	        "wk_error",
	        "unknown_message",
	        "oversized_error",
	        "foreign_pid",
	        "foreign_nonce",
	        "foreign_version",
	        "unretired_owner",
	        "unordered_prefix",
	        "nonliteral_ack",
	        "ten_prior_cases_failure",
	        "successful_primary_no_failure_observation",
	        "extra_case_field",
	        "changed_sources",
	        "expired_observation",
	    ):
	        current, owner_report, after, now = (
	            copy.deepcopy(packet),
	            copy.deepcopy(report),
	            dict(sources),
	            1.0,
	        )
	        if name == "traceback_payload_omitted":
	            current["failure"] += "\nstack traceback:\n/private/SECRET https://secret.invalid"
	        elif name == "wk_error":
	            current["failure"] = "Actual WK evaluation failed"
	        elif name == "unknown_message":
	            current["failure"] = "/private/SECRET arbitrary failure"
	        elif name == "oversized_error":
	            current["failure"] += "x" * 8192
	        elif name == "foreign_pid":
	            current["pid"] = 42
	        elif name == "foreign_nonce":
	            current["nonce"] = "2" * 32
	        elif name == "foreign_version":
	            current["version"] = "foreign"
	        elif name == "unretired_owner":
	            owner_report["native_owner"]["closed"] = False
	        elif name == "unordered_prefix":
	            current["case_results"].reverse()
	        elif name == "nonliteral_ack":
	            current["case_results"][0]["passed"] = 1
	        elif name == "ten_prior_cases_failure":
	            current["case_results"] = [{"id": case, "passed": True} for case in CASES]
	            current["failure"] = "Actual observer timer did not retire"
	        elif name == "successful_primary_no_failure_observation":
	            current["status"] = "ok"
	        elif name == "extra_case_field":
	            current["case_results"][0]["private"] = "SECRET"
	        elif name == "changed_sources":
	            after = {"source.lua": "b" * 64}
	        elif name == "expired_observation":
	            now = 3.0
	        scenarios.append(
	            (
	                name,
	                failure_observation(
	                    current, owner_report, 41, "1" * 32, "1.1.1", sources, after, now, 2.0
	                ),
	            )
	        )
	    expected = {
	        "known_check": ("observed", "guide_queue_refused", 2),
	        "traceback_payload_omitted": ("observed", "guide_queue_refused", 2),
	        "wk_error": ("observed", "wk_evaluation_failed", 2),
	        "ten_prior_cases_failure": ("observed", "observer_timer_debt", 10),
	    }
	    require(len(scenarios) == 16, "Diagnostic control census differs")
	    for name, observed in scenarios:
	        wanted = expected.get(name, ("unsupported", "unclassified", 0))
	        require(
	            (observed["status"], observed["check"], observed["completed_cases"]) == wanted,
	            "Diagnostic expectation failed: " + name,
	        )
	        require(
	            observed["authority"] is False and observed["native_verdict"] == "unchanged",
	            "Diagnostic changed authority",
	        )
	        require(
	            "SECRET" not in diagnostic_line(observed) and "failure" not in observed,
	            "Diagnostic copied private payload",
	        )
	        if wanted[0] == "observed":
	            require(
	                observed["last_completed_case"] == CASES[wanted[2] - 1], "Completed case differs"
	            )
	            require(
	                observed["next_expected_case"] == (CASES[wanted[2]] if wanted[2] < 10 else None),
	                "Expected next case differs",
	            )
	        else:
	            require(
	                observed["last_completed_case"] is None and observed["next_expected_case"] is None,
	                "Unsupported progress claim",
	            )
	    print(
	        "PASS permission UI diagnostic controls tests=16 failures=0 errors=0 skipped=0; native unexecuted"
	    )


	OPERATION_DIAGNOSTIC_PREFIX = "ERGOPTI_PERMISSION_UI_OPERATION "
	OPERATION_DIAGNOSTIC_CHECKS = {
	    "Actual permission UI observation deadline": "observation_deadline",
	    "Exact native child exited before receipt": "child_exited_before_receipt",
	    "Native child exited during receipt": "child_exited_during_receipt",
	    "Native receipt exceeded probe deadline": "receipt_deadline",
	    "Live production source changed": "live_source_changed",
	    "Copied production source changed": "copied_source_changed",
	    "Native entry, configuration, or runtime changed": "retained_input_changed",
	}


	def operation_failure_observation(report, pid, before, after):
	    """Expose a fixed controller refusal only after the exact native owner retires."""
	    unsupported = {
	        "schema": 1,
	        "status": "unsupported",
	        "kind": "permission_ui_controller_failure_observation",
	        "authority": False,
	        "native_verdict": "unchanged",
	        "controller_check": "unclassified",
	    }
	    try:
	        require(type(report) is dict and report.get("status") == "error", "Unsupported report")
	        require("native_result" not in report, "Controller operation returned a native packet")
	        require(
	            report.get("cleanup_errors") == []
	            and type(report.get("cleanup_errors")) is list
	            and report.get("application_cleanup") == "confirmed inherited PGID retired",
	            "Unsupported cleanup",
	        )
	        native = report.get("native_owner")
	        require(
	            type(pid) is int and pid > 0 and type(native) is dict
	            and type(native.get("worker_pid")) is int and native["worker_pid"] == pid
	            and type(native.get("group_id")) is int and native["group_id"] == pid
	            and native.get("closed") is True and native.get("reservation_lost") is False
	            and type(native.get("live_group_members")) is list
	            and native["live_group_members"] == []
	            and native.get("escaped_sessions_managed") is False,
	            "Unsupported exact native retirement",
	        )
	        require(type(before) is dict and bool(before) and before == after, "Unsupported source facts")
	        error = report.get("operation_error")
	        require(type(error) is str, "Unsupported controller refusal")
	        check = OPERATION_DIAGNOSTIC_CHECKS.get(error)
	        require(check is not None, "Unknown controller refusal")
	        return dict(unsupported, status="observed", controller_check=check)
	    except Exception:
	        return unsupported


	def operation_diagnostic_line(value):
	    return OPERATION_DIAGNOSTIC_PREFIX + json.dumps(
	        value, sort_keys=True, separators=(",", ":"), allow_nan=False
	    )


	def native(repo, root):
	    require(
	        sys.platform == "darwin" and sys.version_info >= (3, 13),
	        "Native macOS CPython3.13 required",
	    )
	    start = time.monotonic()
	    deadline = start + 25
	    root = clock.ordinary_owner_root(root)
	    before = inventory(repo)
	    output = root / "permission-ui"
	    output.mkdir(mode=0o700)
	    copied = output / "source"
	    for relative in before:
	        destination = copied / relative
	        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
	        shutil.copyfile(repo / relative, destination)
	    executable, provision = clock.acquire_runtime(
	        repo, output, min(deadline, time.monotonic() + 10)
	    )
	    nonce = uuid.uuid4().hex
	    owner.exclusive_receipt(
	        output / "configuration.json",
	        {
	            "source": str(copied),
	            "root": str(output),
	            "nonce": nonce,
	            "version": provision["version"],
	            "bundle": str(executable.parent.parent.parent),
	        },
	    )
	    config = output / "init.lua"
	    config.write_text("""local function entry_phase(phase)
	    -- Failure-only evidence uses the exact owned child's captured stream.
	    -- A diagnostic I/O failure must not change the original configuration result.
	    pcall(function()
	        io.stderr:write('ERGOPTI_PERMISSION_UI_ENTRY {"schema":1,"kind":"permission_ui_entry_observation","authority":false,"native_verdict":"unchanged","phase":"' .. phase .. '"}\\n')
	        io.stderr:flush()
	    end)
	end
	entry_phase("init_entered")
	local completed, original_error = xpcall(function()
	    local location = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	    local config = assert(hs.json.read(location .. "/configuration.json"))
	    entry_phase("config_decoded")
	    package.path = config.source .. "/static/ergopti_plus/macos/?.lua;" .. config.source .. "/static/ergopti_plus/macos/?/init.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	    entry_phase("paths_bound")
	    local producer = assert(dofile(config.source .. "/tools/diagnostics/hs_permission_dialog_native.lua"))
	    entry_phase("native_entry_loaded")
	    producer(config)
	    entry_phase("call_returned")
	end, function(failure)
	    entry_phase("synchronous_error")
	    return failure
	end)
	if not completed then error(original_error, 0) end
	""")
	    retained = {
	        path: hashlib.sha256(path.read_bytes()).hexdigest()
	        for path in (config, output / "configuration.json", executable)
	    }

	    def unchanged():
	        require(inventory(repo) == before, "Live production source changed")
	        require(
	            all(
	                hashlib.sha256((copied / p).read_bytes()).hexdigest() == digest
	                for p, digest in before.items()
	            ),
	            "Copied production source changed",
	        )
	        require(
	            all(
	                hashlib.sha256(path.read_bytes()).hexdigest() == digest
	                for path, digest in retained.items()
	            ),
	            "Native entry, configuration, or runtime changed",
	        )

	    actual_pid = None

	    def operation(group):
	        nonlocal actual_pid
	        actual_pid = group.process.pid
	        probe = min(deadline, time.monotonic() + 10)
	        while time.monotonic() < probe:
	            require(group.observe_exit() is None, "Exact native child exited before receipt")
	            unchanged()
	            if (output / "result.json").exists():
	                packet = clock.read_receipt(output / "result.json")
	                require(group.observe_exit() is None, "Native child exited during receipt")
	                unchanged()
	                require(time.monotonic() < probe, "Native receipt exceeded probe deadline")
	                return {"native_result": packet}
	            time.sleep(0.01)
	        raise ValueError("Actual permission UI observation deadline")

	    unchanged()
	    report = facade.owned_observation(
	        executable, config, output, operation, owner.NativeProcessGroups()
	    )
	    unchanged()
	    after, now = inventory(repo), time.monotonic()
	    try:
	        packet = admit(
	            report.get("native_result"),
	            report,
	            actual_pid,
	            nonce,
	            provision["version"],
	            before,
	            after,
	            now,
	            deadline,
	        )
	    except ValueError:
	        diagnostic = failure_observation(
	            report.get("native_result"),
	            report,
	            actual_pid,
	            nonce,
	            provision["version"],
	            before,
	            after,
	            now,
	            deadline,
	        )
	        print(diagnostic_line(diagnostic), file=sys.stderr)
	        print(
	            operation_diagnostic_line(
	                operation_failure_observation(report, actual_pid, before, after)
	            ),
	            file=sys.stderr,
	        )
	        raise
	    packet["observation_retirement_seconds"] = time.monotonic() - start
	    packet["runtime_provisioning"] = provision
	    print(json.dumps(packet, separators=(",", ":"), allow_nan=False))


	def main():
	    parser = argparse.ArgumentParser()
	    parser.add_argument("--repo", type=Path, required=True)
	    parser.add_argument("--root", type=Path, required=True)
	    parser.add_argument("--portable", action="store_true")
	    parser.add_argument("--portable-diagnostics", action="store_true")
	    args = parser.parse_args()
	    repo = args.repo.resolve(strict=True)
	    sys.path.insert(0, str(repo / "tools/diagnostics"))
	    global clock, facade, owner
	    import macos_physical_clock as clock
	    import macos_tooltip_canvas as facade
	    import macos_owned_process as owner

	    clock.validate_imports(repo)
	    if args.portable_diagnostics:
	        portable_diagnostics()
	    elif args.portable:
	        portable()
	    else:
	        native(repo, args.root)


	if __name__ == "__main__":
	    main()
	"""#
}
