// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274VerifiedBuilderLoadTests.swift
//
// Real Python CLI/cache controls are portable source evidence, not native build authority.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableVerifiedBuilderBytesIgnoreForeignPythonCaches() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_verified_load_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable retained builder source tests=7 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 7 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}
