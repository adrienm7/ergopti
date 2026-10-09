// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedInventoryBehaviorTests.swift
//
// Actual assembled producer/inventory behavior with explicitly modeled native ports.
// Native enumeration and activation remain unqualified.

import Foundation
import XCTest


extension HS274NativePolicyQualificationTests {
	func testActualOwnedProducerAndInventoryUsePinnedOfflinePristineInputs() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_inventory_fixture.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", script.path, "--owner", root.path, "--compiler", "/usr/bin/clang++"], root: root)
			XCTAssertEqual(receipt.status, 0, receipt.stderr)
			XCTAssertEqual(receipt.stdout,
				"PASS owned runtime production=7 inventory=37 unknown=1; modeled platform ports only\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 9 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}
