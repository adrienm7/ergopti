// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274HostedClockQualificationTests.swift
//
// Executes the real pinned Hammerspoon getter through the unchanged SDK guardian.
// Source-binding tokens remain separate from observed native Mach sample evidence.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testActualHostedClockControllerRefusesForgedSourceFilesystemAndDeadlineControls() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("macos_physical_clock_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS independent hosted clock controls tests=46 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 46 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualPinnedHammerspoonGetterMatchesIndependentParentMachInterval() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let repository = source("macos_physical_clock.py").deletingLastPathComponent()
				.deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("macos_physical_clock.py").path, "--repo", repository.path,
				 "--root", root.path, "--budget", "25"], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Real hosted clock prerequisite refused within unchanged SDK30/35/10; private evidence: "
				+ root.path + "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(packet["status"] as? String, "ok")
			XCTAssertEqual(packet["qualification"] as? String,
				"actual hosted samples match independently checked parent Mach nanoseconds")
			XCTAssertEqual(packet["binding_token_scope"] as? String, "borrowed API subscription identity only")
			XCTAssertEqual(packet["controller_budget_seconds"] as? Int, 25)
			let elapsed = try XCTUnwrap(packet["total_seconds"] as? Double)
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0 && elapsed <= 25)
			let acquisition = try XCTUnwrap(packet["acquisition_seconds"] as? Double)
			XCTAssertTrue(acquisition.isFinite && acquisition >= 0 && acquisition <= 10)
			XCTAssertEqual(packet["physical_input"] as? String, "unexecuted")
			XCTAssertEqual(packet["permission_history"] as? String, "unadmitted")
			// Preserve the exact source hashes, raw bracket and observed timing in CI
			// after successful private fixture files are removed by their owner.
			print(receipt.stdout, terminator: "")
		}
	}
}
