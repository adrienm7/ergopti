// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274ProductObservationOwnershipTests.swift
// Actual phase/filesystem ownership with modeled architecture replies, never native product qualification.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableProductObservationKeepsActualChildrenWithinTheirOwner() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_product_observation_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable product observation ownership tests=4 failures=0 errors=0 skipped=0 native=unexecuted\n")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{4}\n-{70}\nRan 4 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}
}
