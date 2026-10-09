// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274NativeCredentialOwnerTests.swift
// Physical Python IPC/FS controls do not qualify native Security or signing.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testNativeCredentialOwnerPhysicalBoundaryControlRegistration() throws {
		try fixture { root in
			let controls = source("hs274_native_credential_owner_test.py")
			for optimization in [false, true] {
				let arguments = ["python3", "-B"] + (optimization ? ["-O"] : []) + [controls.path]
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), arguments, root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				let complete = #"\A[.]{40}\n[-]{70}\nRan 40 tests in [0-9]+\.[0-9]{3}s\n\nOK\n\z"#
				XCTAssertLessThanOrEqual(receipt.stderr.utf8.count, 4096)
				XCTAssertNotNil(receipt.stderr.range(of: complete, options: .regularExpression),
					"All forty physical IPC/FS controls must execute with zero skips; actual native credentials remain separately qualified.")
			}
		}
	}
}
