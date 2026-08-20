// Tests/ErgoptiPlusTests/POSIXCompatibilityTests.swift

// ==============================================================================
// MODULE: POSIX Compatibility Tests
// DESCRIPTION:
// Regression coverage for Swift SDK changes that made the prior direct flock
// and process-environment imports fail during release compilation.
//
// FEATURES & RATIONALE:
// 1. Calls the real BSD lock symbol through the compatibility wrapper.
// 2. Checks exact owned envp contents and its required nil terminator.
// ==============================================================================

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

@_silgen_name("fork")
private func c_testFork() -> pid_t

/// Preserves the test harness's pre-exec descriptor inheritance on Swift 6.3.
func ergoptiForkForTesting() -> pid_t {
	c_testFork()
}

final class POSIXCompatibilityTests: XCTestCase {
	/// Proves the symbol-level wrapper still reaches BSD flock on the active SDK.
	func testFlockCompatibilityWrapperLocksAndUnlocks() throws {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("ergopti-flock-\(UUID().uuidString)").path
		XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
		defer { try? FileManager.default.removeItem(atPath: path) }
		let descriptor = Darwin.open(path, O_RDWR)
		guard descriptor >= 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		defer { _ = Darwin.close(descriptor) }

		XCTAssertEqual(ergoptiFlock(descriptor, LOCK_EX | LOCK_NB), 0)
		XCTAssertEqual(ergoptiFlock(descriptor, LOCK_UN), 0)
	}

	/// Proves spawn environments are owned, deterministic, and nil-terminated.
	func testEnvironmentDuplicationBuildsCStringVector() throws {
		guard let duplicated = duplicateProcessEnvironment([
			"SECOND": "two",
			"FIRST": "one",
		]) else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
		}
		defer { for case let pointer? in duplicated { free(pointer) } }

		XCTAssertEqual(duplicated.count, 3)
		XCTAssertEqual(duplicated.dropLast().compactMap { pointer in
			pointer.map { String(cString: $0) }
		}, ["FIRST=one", "SECOND=two"])
		XCTAssertNil(duplicated.last!)
	}
}
