// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274RootProcessPrerequisiteTests.swift
// TEST ONLY: one bounded fixed root child, with no credential or runtime authority.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	/// The original SDK Guardian retains 30/35/10. The entire root probe uses one25-second deadline.
	func testActualRootProcessPrerequisiteUsesProtectedImageAndRootChildRetirement() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let output = root.appendingPathComponent("root-process-probe")
			try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let helper = source("root_process_prerequisite.py")
			let repository = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", helper.path, repository.path, output.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertTrue(receipt.stderr.isEmpty)
			let data = try XCTUnwrap(receipt.stdout.data(using: .utf8))
			let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
			XCTAssertEqual(Set(result.keys), Set(["schema", "root_process_prerequisite", "root_child_signal_denied",
				"physical_root_worker_exit_observed", "native_reservations_reaped",
				"abi_preflight_reservations_reaped", "native_abi_preflight_validated", "signing_authority",
				"installation_qualified", "runtime_qualified"]))
			XCTAssertEqual(result["schema"] as? Int, 1)
			XCTAssertEqual(result["root_process_prerequisite"] as? Bool, true)
			XCTAssertEqual(result["root_child_signal_denied"] as? Bool, true)
			XCTAssertEqual(result["physical_root_worker_exit_observed"] as? Bool, true)
			XCTAssertEqual(result["native_reservations_reaped"] as? Int, 9)
			XCTAssertEqual(result["abi_preflight_reservations_reaped"] as? Int, 6)
			XCTAssertEqual(result["native_abi_preflight_validated"] as? Bool, true)
			XCTAssertEqual(result["signing_authority"] as? Bool, false)
			XCTAssertEqual(result["installation_qualified"] as? Bool, false)
			XCTAssertEqual(result["runtime_qualified"] as? Bool, false)
		}
	}

	/// Runs ordinary entrypoint refusals without SDK, root, or credential acquisition.
	func testPortableRootProcessPrerequisiteFailureDiagnostics() throws {
		try fixture { root in
			let diagnostics = source("root_process_prerequisite_test.py").deletingLastPathComponent()
			let check = """
			import json, sys, unittest
			suite = unittest.defaultTestLoader.discover(sys.argv[1], pattern="root_process_prerequisite_test.py")
			result = unittest.TextTestRunner(verbosity=2).run(suite)
			print(json.dumps({"schema": 1, "tests": result.testsRun,
			    "executed": result.testsRun - len(result.skipped), "skipped": len(result.skipped),
			    "skipped_tests": [test.id() for test, _ in result.skipped],
			    "failures": len(result.failures), "errors": len(result.errors), "native": "unexecuted"},
			    sort_keys=True))
			raise SystemExit(0 if result.wasSuccessful() else 1)
			"""
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", check, diagnostics.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			let data = try XCTUnwrap(receipt.stdout.data(using: .utf8))
			let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
			XCTAssertEqual(Set(result.keys), Set(["schema", "tests", "executed", "skipped", "skipped_tests", "failures", "errors", "native"]))
			XCTAssertEqual(result["schema"] as? Int, 1)
			let tests = try XCTUnwrap(result["tests"] as? Int)
			let skipped = try XCTUnwrap(result["skipped"] as? Int)
			let executed = try XCTUnwrap(result["executed"] as? Int)
			let skippedTests = try XCTUnwrap(result["skipped_tests"] as? [String])
			XCTAssertGreaterThanOrEqual(tests, 19)
			XCTAssertGreaterThanOrEqual(executed, 17)
			XCTAssertGreaterThanOrEqual(skipped, 0)
			XCTAssertLessThanOrEqual(skipped, 2)
			XCTAssertEqual(executed, tests - skipped)
			XCTAssertEqual(skipped, skippedTests.count)
			XCTAssertTrue(Set(skippedTests).isSubset(of: Set([
				"root_process_prerequisite_test.ClosedControls.test_c_parser_refuses_malformed_roles_without_native_fallback",
				"root_process_prerequisite_test.FailureDiagnosticControls.test_actual_non_darwin_cli_retains_unavailable_primary_verdict"])))
			XCTAssertEqual(result["failures"] as? Int, 0)
			XCTAssertEqual(result["errors"] as? Int, 0)
			XCTAssertEqual(result["native"] as? String, "unexecuted")
		}
	}
}
