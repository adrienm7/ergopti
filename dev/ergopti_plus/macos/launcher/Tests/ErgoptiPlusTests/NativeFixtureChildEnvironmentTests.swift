// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeFixtureChildEnvironmentTests.swift
//
// Owns the environment of native XCTest children, without changing the parent.

import Foundation
import XCTest

enum NativeFixtureChildEnvironment {
	/// Protected native executables reject forced Swift crash backtracing.
	/// Preserve every other inherited setting and the parent XCTest diagnostics.
	static func make(inheriting parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
		var environment = parent
		environment["SWIFT_BACKTRACE"] = "enable=no"
		return environment
	}
}

final class NativeFixtureChildEnvironmentTests: XCTestCase {
	func testOnlyOwnedChildBacktraceSettingChanges() {
		let parent = ["SWIFT_BACKTRACE": "enable=yes", "PATH": "/owned/bin:/usr/bin", "OWNED_NEIGHBOR": "keep"]
		XCTAssertEqual(NativeFixtureChildEnvironment.make(inheriting: parent),
			["SWIFT_BACKTRACE": "enable=no", "PATH": "/owned/bin:/usr/bin", "OWNED_NEIGHBOR": "keep"])
		XCTAssertEqual(parent["SWIFT_BACKTRACE"], "enable=yes", "The caller's inherited dictionary remains unchanged")
	}

	func testMissingBacktraceSettingDoesNotInventOtherEnvironmentValues() {
		XCTAssertEqual(NativeFixtureChildEnvironment.make(inheriting: [:]), ["SWIFT_BACKTRACE": "enable=no"])
		let inherited = ProcessInfo.processInfo.environment
		var expected = inherited
		expected["SWIFT_BACKTRACE"] = "enable=no"
		XCTAssertEqual(NativeFixtureChildEnvironment.make(), expected)
		XCTAssertEqual(ProcessInfo.processInfo.environment, inherited)
	}
}
