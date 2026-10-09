// Tests/ErgoptiPlusTests/LoginStartupWorkerTests.swift

// ==============================================================================
// MODULE: Login Startup Consent Tests
// DESCRIPTION:
// Uses inert service boundaries so no test registers a real login item.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

final class LoginStartupWorkerTests: XCTestCase {
	func testBothExplicitDirectionsAndReadback() throws {
		var state = LoginStartupState.disabled
		var operations: [String] = []
		func toggle() throws -> LoginStartupState {
			try toggleLoginStartup(read: { state }, enable: {
				operations.append("enable"); state = .enabled
			}, disable: {
				operations.append("disable"); state = .disabled
			}, requestApproval: { operations.append("approval") })
		}
		XCTAssertEqual(try toggle(), .enabled)
		XCTAssertEqual(try toggle(), .disabled)
		XCTAssertEqual(operations, ["enable", "disable"])
	}

	func testApprovalAfterRegistrationThrowsStillOpensSettings() throws {
		var state = LoginStartupState.disabled
		var approvals = 0
		let result = try toggleLoginStartup(read: { state }, enable: {
			state = .approval
			throw NSError(domain: "fixture", code: 1)
		}, disable: { XCTFail("must not disable") }, requestApproval: { approvals += 1 })
		XCTAssertEqual(result, .approval)
		XCTAssertEqual(approvals, 1)
	}

	func testUnavailableAndRefusedServiceNeverBecomeEnabled() throws {
		XCTAssertEqual(try toggleLoginStartup(read: { .unavailable },
			enable: { XCTFail("unsupported registration") },
			disable: { XCTFail("unsupported removal") }, requestApproval: {}), .unavailable)
		XCTAssertThrowsError(try toggleLoginStartup(read: { .disabled },
			enable: { throw NSError(domain: "fixture", code: 2) },
			disable: {}, requestApproval: {}))
		XCTAssertThrowsError(try toggleLoginStartup(read: { .disabled },
			enable: {}, disable: {}, requestApproval: {}))
	}
}
