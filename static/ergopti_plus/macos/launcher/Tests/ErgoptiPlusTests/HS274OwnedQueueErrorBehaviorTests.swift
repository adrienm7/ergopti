// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedQueueErrorBehaviorTests.swift
//
// Active queue-error software controls with modeled IOKit and scheduler ports.
// Native delivery, retirement and complete coverage remain unqualified.

import Foundation
import XCTest


extension HS274NativePolicyQualificationTests {
	func testActualVendorActiveQueueErrorsRevokeOnlyOwnedPhysicalReadiness() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_queue_error_fixture.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", script.path, "--owner", root.path, "--compiler", "/usr/bin/clang++"], root: root)
			XCTAssertEqual(receipt.status, 0, receipt.stderr)
			XCTAssertEqual(receipt.stdout,
				"PASS owned runtime queue errors=6 unknown=1; modeled platform ports only\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 2 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}

// The full fixed leaf namespace uses modeled contents and admission provenance;
// the actual owner/count/path/content/mode/FD guards still execute physically.
extension HS274NativePolicyQualificationTests {
	func testPhysicalFullStagedCountKeepsAllOriginalSourceGuards() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_lexical_closure_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", script.path, "--staged-count-only"], root: root)
			XCTAssertEqual(receipt.status, 0, receipt.stderr)
			XCTAssertTrue(receipt.stdout.isEmpty)
			XCTAssertTrue(receipt.stderr.contains("Ran 4 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}
