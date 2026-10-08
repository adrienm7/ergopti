// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeFixtureChildEnvironmentTests.swift
//
// Owns the environment of native XCTest children, without changing the parent.

import Foundation
import XCTest

enum NativeFixtureChildEnvironment {
	/// Protected native executables reject forced Swift crash backtracing.
	/// Preserve other settings and parent diagnostics; ordinary children receive no compiler credential.
	static func make(inheriting parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
		var environment = parent
		environment["SWIFT_BACKTRACE"] = "enable=no"
		environment.removeValue(forKey: "ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN")
		return environment
	}

	/// Select only the dedicated metadata credential without changing the parent dictionary.
	static func compilationMetadataToken(inheriting parent: [String: String] = ProcessInfo.processInfo.environment) -> String? {
		parent["ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN"]
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
		expected.removeValue(forKey: "ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN")
		XCTAssertEqual(NativeFixtureChildEnvironment.make(), expected)
		XCTAssertEqual(ProcessInfo.processInfo.environment, inherited)
	}
}

// Independently handwritten future shared-environment cases. Native Swift0 here.
// Append only after shared-owner grant; original two assertion bodies stay whole.

extension NativeFixtureChildEnvironmentTests {
	func testPurposeCompilerCredentialIsAbsentFromOrdinaryFixtureChildren() {
		let parent = ["SWIFT_BACKTRACE": "enable=yes", "PATH": "/owned/bin:/usr/bin",
			"OWNED_NEIGHBOR": "keep", "ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN": "synthetic-test-only"]
		XCTAssertEqual(NativeFixtureChildEnvironment.make(inheriting: parent),
			["SWIFT_BACKTRACE": "enable=no", "PATH": "/owned/bin:/usr/bin", "OWNED_NEIGHBOR": "keep"])
		XCTAssertEqual(parent["ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN"], "synthetic-test-only")
		XCTAssertEqual(parent["SWIFT_BACKTRACE"], "enable=yes")
	}

	func testCompilerCredentialSelectionDoesNotBorrowAmbientOrMutateParent() {
		let ambient = ["GH_TOKEN": "synthetic-other", "GITHUB_TOKEN": "synthetic-other",
			"ERGOPTI_NATIVE_HS_METADATA_TOKEN": "synthetic-other"]
		XCTAssertNil(NativeFixtureChildEnvironment.compilationMetadataToken(inheriting: ambient))
		let dedicated = ["ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN": "synthetic-test-only", "OWNED_NEIGHBOR": "keep"]
		XCTAssertEqual(NativeFixtureChildEnvironment.compilationMetadataToken(inheriting: dedicated), "synthetic-test-only")
		XCTAssertEqual(dedicated, ["ERGOPTI_NATIVE_XCODEGEN_METADATA_TOKEN": "synthetic-test-only", "OWNED_NEIGHBOR": "keep"])
	}
}
