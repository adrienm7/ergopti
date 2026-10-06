// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274PermissionDialogQualificationTests.swift
// Actual native UI only; guardian/settings endpoints are explicitly modeled.
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
				+ "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
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
	    config.write_text("""local location = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
	local config = assert(hs.json.read(location .. "/configuration.json"))
	package.path = config.source .. "/static/ergopti_plus/macos/?.lua;" .. config.source .. "/static/ergopti_plus/macos/?/init.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. config.source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
	assert(dofile(config.source .. "/tools/diagnostics/hs_permission_dialog_native.lua"))(config)
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
	    packet = admit(
	        report.get("native_result"),
	        report,
	        actual_pid,
	        nonce,
	        provision["version"],
	        before,
	        inventory(repo),
	        time.monotonic(),
	        deadline,
	    )
	    packet["observation_retirement_seconds"] = time.monotonic() - start
	    packet["runtime_provisioning"] = provision
	    print(json.dumps(packet, separators=(",", ":"), allow_nan=False))


	def main():
	    parser = argparse.ArgumentParser()
	    parser.add_argument("--repo", type=Path, required=True)
	    parser.add_argument("--root", type=Path, required=True)
	    parser.add_argument("--portable", action="store_true")
	    args = parser.parse_args()
	    repo = args.repo.resolve(strict=True)
	    sys.path.insert(0, str(repo / "tools/diagnostics"))
	    global clock, facade, owner
	    import macos_physical_clock as clock
	    import macos_tooltip_canvas as facade
	    import macos_owned_process as owner

	    clock.validate_imports(repo)
	    if args.portable:
	        portable()
	    else:
	        native(repo, args.root)


	if __name__ == "__main__":
	    main()
	"""#
}
