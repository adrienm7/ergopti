// Tests/ErgoptiPlusTests/OwnedRuntimeServiceReferenceOwnerTests.swift
// Precode handwritten native refusal controls; they are not Linux execution proof.
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeServiceReferenceOwnerTests: XCTestCase {
	func testXCTestHostCannotSupplyTheProductionLauncherPrincipal() {
		XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.ergoptiplus.app")
		let owner = OwnedRuntimeServiceReferenceOwner.acquire()
		XCTAssertNil(owner.identity())
		XCTAssertEqual(owner.refusal(), .launcherPrincipalUnavailable)
		XCTAssertTrue(owner.retire())
		XCTAssertTrue(owner.retired())
	}

	func testRepeatedAcquisitionCannotPromoteHistoricalUnavailability() {
		XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.ergoptiplus.app")
		let first = OwnedRuntimeServiceReferenceOwner.acquire()
		let second = OwnedRuntimeServiceReferenceOwner.acquire()
		XCTAssertNil(first.identity())
		XCTAssertNil(second.identity())
		XCTAssertTrue(first.retire())
		XCTAssertNil(second.identity())
		XCTAssertTrue(second.retire())
	}

	func testRefusedAcquisitionRetiresWithoutAProcessReceipt() {
		XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.ergoptiplus.app")
		let owner = OwnedRuntimeServiceReferenceOwner.acquire()
		XCTAssertNil(owner.identity())
		XCTAssertTrue(owner.retire())
		XCTAssertTrue(owner.retire())
		XCTAssertTrue(owner.retired())
		XCTAssertNil(owner.identity())
	}
}

// Ordinary generator checks exercise repository bytes, independently of native code custody.
extension HS274NativePolicyQualificationTests {
	func testOwnedRuntimeServiceReferenceActualGeneratorCheckIsReadOnly() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/generate_owned_runtime_service_reference.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path, "--check"], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.isEmpty)
			}
		}
	}

	func testOwnedRuntimeServiceReferenceWrapperUsesActualPrivateCLIControls() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/owned_runtime_service_reference_wrapper_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 5 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
}
