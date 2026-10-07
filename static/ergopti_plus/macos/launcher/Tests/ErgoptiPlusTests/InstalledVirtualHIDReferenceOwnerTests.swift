// Tests/ErgoptiPlusTests/InstalledVirtualHIDReferenceOwnerTests.swift
// Actual protected static references; package trust and driver readiness stay separate.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

private struct RetainedStaticReferenceControls {
	let providedLocations: (String) throws -> InstalledVHDProbeLocations
	let registerOwner: (InstalledVirtualHIDReferenceOwner) -> InstalledVirtualHIDReferenceOwner
	private func fixture(_ name: String = "official") throws -> InstalledVHDProbeLocations {
		try providedLocations(name)
	}
	private func acquire(locations: InstalledVHDProbeLocations,
		boundary: ((InstalledVirtualHIDReferenceOwner, InstalledVHDProbeBoundary) throws -> Void)? = nil) -> InstalledVirtualHIDReferenceOwner {
		registerOwner(InstalledVirtualHIDReferenceOwner.acquireTestFixture(locations: locations, boundary: boundary))
	}

	func testOfficialFixedStaticReferenceRemainsHeldUntilRetirement() throws {
		let locations = try fixture()
		let owner = acquire(locations: locations)
		defer { XCTAssertTrue(owner.retire()) }
		let token = try XCTUnwrap(owner.identity())
		XCTAssertTrue(owner.current(token)); XCTAssertFalse(owner.retired())
		XCTAssertFalse(InstalledVirtualHIDProbe.observeTestFixture(locations: locations).referenceQualified)
		XCTAssertTrue(owner.current(token), "A separate diagnostic collector cannot close this owner's descriptors")
	}

	func testAnotherActualOwnerTokenCannotAuthorizeOrRetireThisOwner() throws {
		let locations = try fixture()
		let first = acquire(locations: locations)
		let second = acquire(locations: locations)
		defer { XCTAssertTrue(first.retire()); XCTAssertTrue(second.retire()) }
		let firstToken = try XCTUnwrap(first.identity()), secondToken = try XCTUnwrap(second.identity())
		XCTAssertFalse(first.current(secondToken)); XCTAssertTrue(first.current(firstToken))
		XCTAssertTrue(second.retire()); XCTAssertTrue(second.retired())
		XCTAssertFalse(second.current(secondToken)); XCTAssertTrue(first.current(firstToken))
	}

	func testRetirementRevokesTheTokenAndAcknowledgesActualCloseOnce() throws {
		let owner = acquire(locations: try fixture())
		let token = try XCTUnwrap(owner.identity())
		XCTAssertTrue(owner.retire()); XCTAssertTrue(owner.retired())
		XCTAssertNil(owner.identity()); XCTAssertFalse(owner.current(token))
		XCTAssertTrue(owner.retire()); XCTAssertTrue(owner.retired())
	}

	func testStopDuringAcquisitionCannotPublishAndSettlesAfterTheFrame() throws {
		var entered = false
		let owner = acquire(locations: try fixture(), boundary: { owner, boundary in
			guard !entered, boundary.stage == "beforePublication" else { return }
			entered = true
			XCTAssertNil(owner.identity()); XCTAssertFalse(owner.retire()); XCTAssertFalse(owner.retired())
		})
		XCTAssertTrue(entered); XCTAssertNil(owner.identity())
		XCTAssertTrue(owner.retired()); XCTAssertTrue(owner.retire())
	}

	func testReentrantStopDuringCurrentValidationCannotAcknowledgeItsOwnFrame() throws {
		var stopOnCurrent = false, entered = false
		let owner = acquire(locations: try fixture(), boundary: { owner, boundary in
			guard stopOnCurrent, !entered, boundary.stage == "beforeCurrentValidation" else { return }
			entered = true
			XCTAssertFalse(owner.retire()); XCTAssertFalse(owner.retired())
		})
		let token = try XCTUnwrap(owner.identity())
		stopOnCurrent = true
		XCTAssertFalse(owner.current(token)); XCTAssertTrue(entered)
		XCTAssertNil(owner.identity()); XCTAssertTrue(owner.retired())
	}

	func testCloseBoundaryReentryRetainsPhysicalRetirementDebt() throws {
		var entered = false
		let owner = acquire(locations: try fixture(), boundary: { owner, boundary in
			guard !entered, boundary.stage == "beforeDescriptorClose" else { return }
			entered = true
			XCTAssertFalse(owner.retire()); XCTAssertFalse(owner.retired()); XCTAssertNil(owner.identity())
		})
		XCTAssertNotNil(owner.identity()); XCTAssertTrue(owner.retire())
		XCTAssertTrue(entered); XCTAssertTrue(owner.retired())
	}

	func testAcquisitionBoundaryFailureReleasesTheActualHeldInventory() throws {
		enum Refusal: Error { case boundary }
		var entered = false
		let owner = acquire(locations: try fixture(), boundary: { _, boundary in
			guard boundary.stage == "afterSecurityValidated" else { return }
			entered = true; throw Refusal.boundary
		})
		XCTAssertTrue(entered); XCTAssertNil(owner.identity())
		XCTAssertTrue(owner.retired()); XCTAssertTrue(owner.retire())
	}

	func testUnprotectedModifiedAndUnsupportedNativeReferencesNeverMintToken() throws {
		for name in ["newer-reference", "same-signer-other-build", "unsigned", "adhoc", "bad-other-slice",
			"changed-plist", "changed-resource", "symlink-ancestor", "symlink-plist", "symlink-executable",
			"user-owned", "writable-file", "nonempty-acl", "writable-ancestor", "missing-daemon", "missing-dext", "missing-executable"] {
			let owner = acquire(locations: try fixture(name))
			XCTAssertNil(owner.identity(), name); XCTAssertTrue(owner.retired(), name); XCTAssertTrue(owner.retire(), name)
		}
	}
}

extension RetainedStaticReferenceControls {
	func testActualDescriptorWitnessesCloseAfterRetirement() throws {
		let owner = acquire(locations: try fixture())
		defer { _ = owner.retire() }
		XCTAssertNotNil(owner.identity())
		let descriptors = owner.descriptorWitnessesForTest()
		XCTAssertFalse(descriptors.isEmpty); XCTAssertLessThanOrEqual(descriptors.count, 512)
		for fd in descriptors { XCTAssertGreaterThanOrEqual(fcntl(fd, F_GETFD), 0) }
		let acknowledged = owner.retire()
		let outcomes = descriptors.map { fd -> (Int32, Int32) in
			errno = 0; let result = fcntl(fd, F_GETFD); return (result, errno)
		}
		XCTAssertTrue(acknowledged)
		for outcome in outcomes { XCTAssertEqual(outcome.0, -1); XCTAssertEqual(outcome.1, EBADF) }
	}

	func testReentrantCurrentStopDoesNotCloseItsBorrowedDescriptorsEarly() throws {
		var stopping = false, retainedDuringFrame = false
		let owner = acquire(locations: try fixture(), boundary: { owner, boundary in
			guard stopping, boundary.stage == "beforeCurrentValidation" else { return }
			let descriptors = owner.descriptorWitnessesForTest()
			XCTAssertFalse(owner.retire()); XCTAssertFalse(owner.retired())
			retainedDuringFrame = !descriptors.isEmpty && descriptors.allSatisfy { fcntl($0, F_GETFD) >= 0 }
		})
		let token = try XCTUnwrap(owner.identity()), descriptors = owner.descriptorWitnessesForTest()
		stopping = true
		let admitted = owner.current(token)
		let outcomes = descriptors.map { fd -> (Int32, Int32) in
			errno = 0; let result = fcntl(fd, F_GETFD); return (result, errno)
		}
		XCTAssertFalse(admitted); XCTAssertTrue(retainedDuringFrame); XCTAssertTrue(owner.retired())
		for outcome in outcomes { XCTAssertEqual(outcome.0, -1); XCTAssertEqual(outcome.1, EBADF) }
	}

	func testForeignCloseBoundaryThrowCannotSuppressActualDescriptorClose() throws {
		enum Refusal: Error { case boundary }
		var entered = false
		let owner = acquire(locations: try fixture(), boundary: { _, boundary in
			guard boundary.stage == "beforeDescriptorClose" else { return }
			entered = true; throw Refusal.boundary
		})
		let token = try XCTUnwrap(owner.identity()), descriptors = owner.descriptorWitnessesForTest()
		let acknowledged = owner.retire()
		let outcomes = descriptors.map { fd -> (Int32, Int32) in
			errno = 0; let result = fcntl(fd, F_GETFD); return (result, errno)
		}
		XCTAssertFalse(descriptors.isEmpty); XCTAssertTrue(entered); XCTAssertTrue(acknowledged)
		XCTAssertFalse(owner.current(token)); XCTAssertTrue(owner.retired())
		for outcome in outcomes { XCTAssertEqual(outcome.0, -1); XCTAssertEqual(outcome.1, EBADF) }
	}
}

extension RetainedStaticReferenceControls {
	func testActualUnownedTemporaryBundlesCannotMintStaticReference() throws {
		try XCTSkipUnless(geteuid() != 0, "This native ownership refusal requires an unprivileged process")
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiVHDUnowned-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer { try? FileManager.default.removeItem(at: root) }
		let daemon = root.appendingPathComponent("daemon.app"), dext = root.appendingPathComponent("driver.dext")
		try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: false)
		try FileManager.default.createDirectory(at: dext, withIntermediateDirectories: false)
		let owner = acquire(locations: InstalledVHDProbeLocations(daemon: daemon, dext: dext))
		XCTAssertNil(owner.identity()); XCTAssertTrue(owner.retired()); XCTAssertTrue(owner.retire())
	}

	func testActualMissingUniqueReferencesCannotMintStaticReference() throws {
		let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiVHDMissing-" + UUID().uuidString)
		XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
		let owner = acquire(locations: InstalledVHDProbeLocations(
			daemon: missing.appendingPathComponent("daemon.app"), dext: missing.appendingPathComponent("driver.dext")))
		XCTAssertNil(owner.identity()); XCTAssertTrue(owner.retired()); XCTAssertTrue(owner.retire())
		XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Observation must never create an installed reference")
	}
}

private enum ProtectedReferenceFixtureError: Error { case prerequisite, ownership, cases, retirement, cleanup }

extension HS274NativePolicyQualificationTests {
	/// Runs all eleven protected-reference controls inside one explicit SDK-owned fixture.
	func testActualOwnedProtectedVirtualHIDReferenceCases() throws {
		try fixture { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let script = diagnostics.appendingPathComponent("installed_vhd_reference_fixture.py")
			let stage = root.appendingPathComponent("reference-payload")
			try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let prepared = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path, "prepare", stage.path], root: root)
			XCTAssertEqual(prepared.status, 0, "Actual pinned package acquisition/verification prerequisite refused")
			XCTAssertTrue(prepared.stderr.isEmpty)
			guard prepared.status == 0, prepared.stderr.isEmpty else { throw ProtectedReferenceFixtureError.prerequisite }
			let preparation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prepared.stdout.utf8)) as? [String: Any])
			guard preparation["schema"] as? Int == 1, preparation["status"] as? String == "prepared",
				preparation["package_versions"] as? [String] == ["8.4.0", "8.5.0", "8.6.0"],
				preparation["installation_qualified"] as? Bool == false,
				preparation["reference_qualified"] as? Bool == false else { throw ProtectedReferenceFixtureError.prerequisite }
			let created = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path, "create", stage.path], root: root)
			XCTAssertEqual(created.status, 0, "Actual sudo/protected-ancestry/fixture prerequisite refused")
			XCTAssertTrue(created.stderr.isEmpty)
			guard created.status == 0, created.stderr.isEmpty else { throw ProtectedReferenceFixtureError.prerequisite }
			let creation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created.stdout.utf8)) as? [String: Any])
			let path = try XCTUnwrap(creation["fixture_root"] as? String)
			let prefix = "/Library/ErgoptiPlusNativeFixture-"
			guard path.hasPrefix(prefix), path.count == prefix.count + 32,
				path.dropFirst(prefix.count).allSatisfy({ "0123456789abcdef".contains($0) }),
				creation["schema"] as? Int == 1, creation["status"] as? String == "created",
				creation["installation_qualified"] as? Bool == false,
				creation["reference_qualified"] as? Bool == false else { throw ProtectedReferenceFixtureError.ownership }
			let expectedCases = ["official", "newer-reference", "same-signer-other-build", "unsigned", "adhoc",
				"bad-other-slice", "changed-plist", "changed-resource", "symlink-ancestor", "symlink-plist",
				"symlink-executable", "user-owned", "writable-file", "nonempty-acl", "writable-ancestor",
				"missing-daemon", "missing-dext", "missing-executable"]
			guard creation["cases"] as? [String] == expectedCases else { throw ProtectedReferenceFixtureError.cases }
			let protectedRoot = URL(fileURLWithPath: path)
			let identity = try XCTUnwrap(creation["identity"] as? [String: Any])
			let identityData = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
			let identityText = String(decoding: identityData, as: UTF8.self)
			var owners: [InstalledVirtualHIDReferenceOwner] = []
			let controls = RetainedStaticReferenceControls(providedLocations: { name in
				guard expectedCases.contains(name) else { throw ProtectedReferenceFixtureError.cases }
				let caseRoot = protectedRoot.appendingPathComponent(name)
				return InstalledVHDProbeLocations(daemon: caseRoot.appendingPathComponent("daemon.app"),
					dext: caseRoot.appendingPathComponent("driver.dext"))
			}, registerOwner: { owner in owners.append(owner); return owner })
			var primaryError: Error?
			do {
				let cases: [(String, () throws -> Void)] = [
					("testOfficialFixedStaticReferenceRemainsHeldUntilRetirement", controls.testOfficialFixedStaticReferenceRemainsHeldUntilRetirement),
					("testAnotherActualOwnerTokenCannotAuthorizeOrRetireThisOwner", controls.testAnotherActualOwnerTokenCannotAuthorizeOrRetireThisOwner),
					("testRetirementRevokesTheTokenAndAcknowledgesActualCloseOnce", controls.testRetirementRevokesTheTokenAndAcknowledgesActualCloseOnce),
					("testStopDuringAcquisitionCannotPublishAndSettlesAfterTheFrame", controls.testStopDuringAcquisitionCannotPublishAndSettlesAfterTheFrame),
					("testReentrantStopDuringCurrentValidationCannotAcknowledgeItsOwnFrame", controls.testReentrantStopDuringCurrentValidationCannotAcknowledgeItsOwnFrame),
					("testCloseBoundaryReentryRetainsPhysicalRetirementDebt", controls.testCloseBoundaryReentryRetainsPhysicalRetirementDebt),
					("testAcquisitionBoundaryFailureReleasesTheActualHeldInventory", controls.testAcquisitionBoundaryFailureReleasesTheActualHeldInventory),
					("testUnprotectedModifiedAndUnsupportedNativeReferencesNeverMintToken", controls.testUnprotectedModifiedAndUnsupportedNativeReferencesNeverMintToken),
					("testActualDescriptorWitnessesCloseAfterRetirement", controls.testActualDescriptorWitnessesCloseAfterRetirement),
					("testReentrantCurrentStopDoesNotCloseItsBorrowedDescriptorsEarly", controls.testReentrantCurrentStopDoesNotCloseItsBorrowedDescriptorsEarly),
					("testForeignCloseBoundaryThrowCannotSuppressActualDescriptorClose", controls.testForeignCloseBoundaryThrowCannotSuppressActualDescriptorClose)
				]
				for (name, operation) in cases {
					let before = testRun?.failureCount
					try operation()
					guard let before, testRun?.failureCount == before else { throw ProtectedReferenceFixtureError.cases }
					print("PASS actual retained static reference control " + name)
				}
			} catch { primaryError = error }
			var closed = true
			for owner in owners { if !owner.retire() || !owner.retired() { closed = false } }
			try retireOwnedChildren()
			guard closed else { throw ProtectedReferenceFixtureError.retirement }
			let cleaned = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path, "cleanup", stage.path,
				String(path.dropFirst(prefix.count)), identityText], root: root)
			XCTAssertEqual(cleaned.status, 0, "Exact protected fixture cleanup refused; retain its source and inventory")
			XCTAssertTrue(cleaned.stderr.isEmpty)
			guard cleaned.status == 0, cleaned.stderr.isEmpty else { throw ProtectedReferenceFixtureError.cleanup }
			let cleanup = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cleaned.stdout.utf8)) as? [String: Any])
			guard cleanup["schema"] as? Int == 1, cleanup["status"] as? String == "removed",
				cleanup["fixture_root"] as? String == path,
				cleanup["installation_qualified"] as? Bool == false,
				cleanup["reference_qualified"] as? Bool == false,
				!FileManager.default.fileExists(atPath: path) else { throw ProtectedReferenceFixtureError.cleanup }
			if let primaryError { throw primaryError }
		}
	}
}

final class InstalledVirtualHIDReferenceOwnerOrdinaryDenialTests: XCTestCase {
	private func controls() -> RetainedStaticReferenceControls {
		RetainedStaticReferenceControls(providedLocations: { _ in throw ProtectedReferenceFixtureError.prerequisite },
			registerOwner: { $0 })
	}
	func testActualUnownedTemporaryBundlesCannotMintStaticReference() throws {
		try controls().testActualUnownedTemporaryBundlesCannotMintStaticReference()
	}
	func testActualMissingUniqueReferencesCannotMintStaticReference() throws {
		try controls().testActualMissingUniqueReferencesCannotMintStaticReference()
	}
}
