// Tests/ErgoptiPlusTests/OwnedRuntimeCLIGuestOwnerTests.swift
// Native observations refuse foreign guests; no fixture can mint an installed image lease.
import CPOSIXCompatibility
import Darwin
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeCLIGuestOwnerTests: XCTestCase {
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	func testInvalidNativeProcessCannotAuthenticateInstalledCLI() {
		XCTAssertFalse(OwnedRuntimeInstalledPeerOwner.fixtureCLIExecutableGuest(ergopti_owned_program_observe(0)))
	}
	func testCurrentXCTestImageCannotAuthenticateInstalledCLI() {
		XCTAssertFalse(OwnedRuntimeInstalledPeerOwner.fixtureCLIExecutableGuest(ergopti_owned_program_observe(getpid())))
	}
	func testForgedNativeBirthCannotAuthenticateInstalledCLI() {
		var sampled = ergopti_owned_program_observe(getpid())
		XCTAssertEqual(sampled.error_code, 0)
		sampled.start_seconds &+= 1
		XCTAssertFalse(OwnedRuntimeInstalledPeerOwner.fixtureCLIExecutableGuest(sampled))
	}
	func testCurrentProcessIsNotItsOwnNativeChild() {
		XCTAssertFalse(OwnedRuntimeInstalledPeerOwner.fixtureCurrentNativeParent(getpid()))
	}
#endif
}
