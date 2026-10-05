// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeBindingQualificationTests.swift
//
// Real SDK compilation and missing-object refusal use the existing exact guardian.
// This proves neither physical correlation nor the complete Core-Service build.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testNativeBindingCompilesWithActualSDKAndRefusesMissingObjects() throws {
		try fixture { root in
			for standard in ["c++17", "c++23"] {
				let executable = try compile(source("hs274-native-binding-test.cpp"),
					standard: standard, root: root, frameworks: true)
				let result = try run(executable, [], root: root)
				XCTAssertEqual(result.status, 0)
				XCTAssertEqual(result.stdout,
					"PASS native binding missing-object controls assertions=9; native device correlation unexecuted\n")
				XCTAssertTrue(result.stderr.isEmpty)
			}
		}
	}
}
