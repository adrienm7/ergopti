// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274ProtectedReferenceExpansionControlsTests.swift
// Software expansion routing controls qualify no Darwin option, package trust or installation.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableProtectedReferenceExpansionRetainsAllOriginalCustodyControls() throws {
		try fixture { root in
			let controls = source("installed_vhd_reference_fixture_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", controls.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertTrue(receipt.stdout.isEmpty)
			let complete = #"\A[.]{30}\n[-]{70}\nRan 30 tests in [0-9]+\.[0-9]{3}s\n\nOK\n\z"#
			XCTAssertLessThanOrEqual(receipt.stderr.utf8.count, 4096)
			XCTAssertNotNil(receipt.stderr.range(of: complete, options: .regularExpression),
				"All twenty-one original custody controls and nine modeled routing controls must execute; native expansion remains unqualified.")
		}
	}
}
