// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedConfigurationObservationTests.swift
// Portable refusal diagnostics preserve original native admission and grant no authority.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableOwnedConfigurationFailureObservationsRetainAllOriginalControls() throws {
		try fixture { root in
			let controls = source("hs_owned_configuration_fixture_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", controls.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertTrue(receipt.stdout.isEmpty)
			let complete = #"\A[.]{24}\n[-]{70}\nRan 24 tests in [0-9]+\.[0-9]{3}s\n\nOK\n\z"#
			XCTAssertLessThanOrEqual(receipt.stderr.utf8.count, 4096)
			XCTAssertNotNil(receipt.stderr.range(of: complete, options: .regularExpression),
				"Only all sixteen original controls and eight refusal observations qualify; native UI remains unexecuted.")
		}
	}
}
