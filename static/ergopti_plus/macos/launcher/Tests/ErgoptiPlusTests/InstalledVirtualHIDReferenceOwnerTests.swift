// Tests/ErgoptiPlusTests/InstalledVirtualHIDReferenceOwnerTests.swift
// Actual protected static references; package trust and driver readiness stay separate.
import Darwin
import CoreFoundation
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

	private static func protectedReferenceFailureSummary(_ stdout: String) -> String {
		let unsupported = "reference preparation observation unsupported"
		guard stdout.utf8.count <= 1024, let data = stdout.data(using: .utf8),
			let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(packet.keys) == Set(["schema", "status", "reason", "fixture_root",
				"installation_qualified", "reference_qualified"]),
			let schema = packet["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
			Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: schema.objCType)),
			schema.doubleValue == 1, packet["status"] as? String == "refused",
			packet["fixture_root"] is NSNull,
			let installation = packet["installation_qualified"] as? NSNumber,
			CFGetTypeID(installation) == CFBooleanGetTypeID(), !installation.boolValue,
			let reference = packet["reference_qualified"] as? NSNumber,
			CFGetTypeID(reference) == CFBooleanGetTypeID(), !reference.boolValue,
			let reason = packet["reason"] as? String else { return unsupported }
		let reasons: Set<String> = [
			"native_prerequisite", "owner", "owner_inventory", "native_image", "native_image_changed",
			"native_output", "native_status", "expand_prerequisite", "source_name", "source_type",
			"source_changed", "package_version", "package_pin", "download_output", "expand_output",
			"codesign_output", "package_changed", "payload_inventory", "payload_mode", "payload_bytes",
			"compiler_output", "ancestry_source", "ancestry_source_changed", "deadline",
			"FileNotFoundError", "PermissionError", "OSError", "ValueError", "TimeoutExpired", "CalledProcessError",
		]
		guard reasons.contains(reason) else { return unsupported }
		return "reference preparation reason=" + reason
	}

	func testProtectedReferenceFailureSummaryKeepsPrivateAndMalformedFactsUnsupported() {
		let refused = #"{"schema":1,"status":"refused","reason":"owner","fixture_root":null,"installation_qualified":false,"reference_qualified":false}"#
		XCTAssertEqual(Self.protectedReferenceFailureSummary(refused), "reference preparation reason=owner")
		for malformed in [
			refused.replacingOccurrences(of: "owner", with: "SECRET private cause"),
			refused.replacingOccurrences(of: "null", with: #""/private/SECRET""#),
			refused.replacingOccurrences(of: #""schema":1"#, with: #""schema":true"#),
			refused.replacingOccurrences(of: #""schema":1"#, with: #""schema":1.0"#),
			refused.replacingOccurrences(of: #""reference_qualified":false"#, with: #""reference_qualified":0"#),
			refused.replacingOccurrences(of: #""reference_qualified":false"#, with: #""reference_qualified":true"#),
			refused.replacingOccurrences(of: #""schema":1"#, with: #""schema":1,"extra":"SECRET""#),
			refused + "SECRET", String(repeating: "x", count: 1025), "invalid SECRET",
		] {
			XCTAssertEqual(Self.protectedReferenceFailureSummary(malformed),
				"reference preparation observation unsupported")
		}
	}

	/// Project only the existing, retired Guardian receipt into fixed public scalars.
	/// This observation neither authorizes the reference nor recovers missing captures.
	private static func protectedReferenceInventoryConsoleObservation(_ stderr: String) -> String {
		let unsupported = "reference inventory observation unsupported"
		let prefix = "ERGOPTI_VHD_PAYLOAD_INVENTORY_DIAGNOSTIC "
		guard stderr.utf8.count <= 8192 else { return unsupported }
		let bytes = Array(stderr.utf8)
		guard bytes.starts(with: prefix.utf8), bytes.last == 10,
			bytes.count > prefix.utf8.count + 1 else { return unsupported }
		let body = Data(bytes.dropFirst(prefix.utf8.count).dropLast())
		guard body.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
			let packet = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
			Set(packet.keys) == Set(["schema", "kind", "authority", "version", "reason",
				"expected_count", "rows", "missing_expected_indices", "extra_count",
				"installation_qualified", "reference_qualified"]),
			protectedReferenceDiagnosticInteger(packet["schema"], minimum: 1, maximum: 1) == 1,
			packet["kind"] as? String == "installed_vhd_payload_inventory_refusal_observation",
			packet["reason"] as? String == "payload_inventory",
			protectedReferenceDiagnosticBoolean(packet["authority"]) == false,
			protectedReferenceDiagnosticBoolean(packet["installation_qualified"]) == false,
			protectedReferenceDiagnosticBoolean(packet["reference_qualified"]) == false,
			let version = packet["version"] as? String,
			Set(["8.4.0", "8.5.0", "8.6.0"]).contains(version),
			protectedReferenceDiagnosticInteger(packet["expected_count"], minimum: 42, maximum: 42) == 42,
			let extra = protectedReferenceDiagnosticInteger(packet["extra_count"], minimum: 0, maximum: 1024),
			let rows = packet["rows"] as? [[String: Any]], rows.count == 42,
			let missing = packet["missing_expected_indices"] as? [Any] else { return unsupported }
		var expectedMissing: [Int] = []
		var projectedRows: [String] = []
		for (index, row) in rows.enumerated() {
			guard Set(row.keys) == Set(["index", "present", "type_matches", "mode_matches",
				"bytes_matches", "sha256_matches"]),
				protectedReferenceDiagnosticInteger(row["index"], minimum: index, maximum: index) == index,
				let present = protectedReferenceDiagnosticBoolean(row["present"]) else { return unsupported }
			var symbols = ""
			for key in ["type_matches", "mode_matches", "bytes_matches", "sha256_matches"] {
				if row[key] is NSNull { symbols += "N" }
				else {
					guard let flag = protectedReferenceDiagnosticBoolean(row[key]) else { return unsupported }
					symbols += flag ? "T" : "F"
				}
			}
			if !present {
				guard symbols == "NNNN" else { return unsupported }
				expectedMissing.append(index)
			}
			projectedRows.append(String(index) + "=" + (present ? "1" : "0") + symbols)
		}
		guard missing.count == expectedMissing.count, !expectedMissing.isEmpty || extra > 0 else {
			return unsupported
		}
		for (position, value) in missing.enumerated() {
			let expected = expectedMissing[position]
			guard protectedReferenceDiagnosticInteger(value, minimum: expected, maximum: expected) == expected else {
				return unsupported
			}
		}
		// Exact canonical equality rejects duplicate keys, whitespace and extra packets.
		// The frozen original-emitter fixture must qualify Foundation/Python compatibility.
		guard let canonical = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]),
			canonical == body else { return unsupported }
		let absent = expectedMissing.isEmpty ? "-" : expectedMissing.map(String.init).joined(separator: ",")
		let observation = "reference inventory observation version=" + version
			+ " authority=false extra=" + String(extra) + " missing=" + absent
			+ " rows=" + projectedRows.joined(separator: ",")
			+ " legend=present,type,mode,bytes,sha256(T/F/N)"
		guard observation.utf8.count <= 2048 else { return unsupported }
		return observation
	}

	private static func protectedReferenceDiagnosticBoolean(_ value: Any?) -> Bool? {
		guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
		return number.boolValue
	}

	private static func protectedReferenceDiagnosticInteger(_ value: Any?, minimum: Int, maximum: Int) -> Int? {
		guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
			Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: number.objCType)),
			number.int64Value >= Int64(minimum), number.int64Value <= Int64(maximum) else { return nil }
		return Int(number.int64Value)
	}

	func testProtectedReferenceInventoryConsoleKeepsFixedFortyTwoOrdinals() {
		XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(Self.protectedInventoryFixedReceipt),
			Self.protectedInventoryFixedExpected)
	}

	func testProtectedReferenceInventoryConsoleRetainsSupportedVersionsAndExtraCount() {
		for version in ["8.4.0", "8.5.0", "8.6.0"] {
			let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: "8.4.0", with: version)
			let expected = Self.protectedInventoryFixedExpected.replacingOccurrences(of: "8.4.0", with: version)
			XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt), expected)
		}
		let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: #""extra_count":0"#, with: #""extra_count":1024"#)
		let expected = Self.protectedInventoryFixedExpected.replacingOccurrences(of: "extra=0 ", with: "extra=1024 ")
		XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt), expected)
	}

	func testProtectedReferenceInventoryConsoleRejectsBooleanAndFloatingIntegers() {
		for (original, replacement) in [
			(#""schema":1"#, #""schema":true"#), (#""schema":1"#, #""schema":1.0"#),
			(#""expected_count":42"#, #""expected_count":42.0"#),
			(#""extra_count":0"#, #""extra_count":false"#), (#""extra_count":0"#, #""extra_count":0.0"#),
			(#""extra_count":0"#, #""extra_count":-1"#), (#""extra_count":0"#, #""extra_count":1025"#),
			(#""index":0,"#, #""index":false,"#), (#""index":0,"#, #""index":0.0,"#),
			(#""missing_expected_indices":[3,8]"#, #""missing_expected_indices":[3.0,8]"#),
			(#""authority":false"#, #""authority":0"#), (#""authority":false"#, #""authority":true"#),
			(#""installation_qualified":false"#, #""installation_qualified":true"#),
			(#""reference_qualified":false"#, #""reference_qualified":true"#),
		] {
			let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: original, with: replacement)
			XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt),
				"reference inventory observation unsupported")
		}
	}

	func testProtectedReferenceInventoryConsoleRejectsUnknownFieldsAndIncoherentOrdinals() {
		for (original, replacement) in [
			(#""reason":"payload_inventory""#, #""reason":"payload_inventory","unknown":null"#),
			(#""index":0,"#, #""index":0,"unknown":null,"#),
			(#""index":0,"#, #""index":42,"#),
			(#""missing_expected_indices":[3,8]"#, #""missing_expected_indices":[8,3]"#),
			(#""missing_expected_indices":[3,8]"#, #""missing_expected_indices":[3,3]"#),
			(#""missing_expected_indices":[3,8]"#, #""missing_expected_indices":[3]"#),
			(#""missing_expected_indices":[3,8]"#, #""missing_expected_indices":[3,8,9]"#),
			("," + Self.protectedInventoryFixedLastRow, ""),
			(Self.protectedInventoryFixedFirstRow, Self.protectedInventoryFixedFirstRow + "," + Self.protectedInventoryFixedFirstRow),
		] {
			let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: original, with: replacement)
			XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt),
				"reference inventory observation unsupported")
		}
	}

	func testProtectedReferenceInventoryConsoleRejectsDuplicateAndNoncanonicalReceipts() {
		for receipt in [
			Self.protectedInventoryFixedReceipt.replacingOccurrences(of: #""schema":1"#, with: #""schema":1,"schema":1"#),
			Self.protectedInventoryFixedReceipt.replacingOccurrences(of: #""index":0,"#, with: #""index":0,"index":0,"#),
			Self.protectedInventoryFixedReceipt.replacingOccurrences(of: #""schema":1"#, with: #""schema": 1"#),
			Self.protectedInventoryFixedReceipt + "\n", Self.protectedInventoryFixedReceipt + Self.protectedInventoryFixedReceipt,
			String(Self.protectedInventoryFixedReceipt.dropLast()), "ERGOPTI_VHD_PAYLOAD_INVENTORY_DIAGNOSTIC {\n",
			String(repeating: "x", count: 8193), "invalid SECRET receipt", "",
		] {
			XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt),
				"reference inventory observation unsupported")
		}
	}

	func testProtectedReferenceInventoryConsoleRejectsMalformedFlags() {
		for (original, replacement) in [
			(#""present":true"#, #""present":1"#), (#""present":true"#, #""present":null"#),
			(#""mode_matches":true"#, #""mode_matches":1"#),
			(#""type_matches":null"#, #""type_matches":true"#),
			(#""bytes_matches":null"#, #""bytes_matches":"SECRET""#),
		] {
			let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: original, with: replacement)
			XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt),
				"reference inventory observation unsupported")
		}
		let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: #""mode_matches":true"#, with: #""mode_matches":false"#)
		XCTAssertEqual(Self.protectedReferenceInventoryConsoleObservation(receipt),
			Self.protectedInventoryFixedExpected.replacingOccurrences(of: "=1TT", with: "=1TF"))
	}

	func testProtectedReferenceInventoryConsoleNeverEchoesPrivateInput() {
		for (original, replacement) in [
			(#""version":"8.4.0""#, #""version":"/private/SECRET""#),
			(#""reason":"payload_inventory""#, #""reason":"SECRET arbitrary error""#),
			(#""kind":"installed_vhd_payload_inventory_refusal_observation""#, #""kind":"SECRET private kind""#),
			(#""extra_count":0"#, #""extra_count":"SECRET UID or path""#),
			(#""sha256_matches":true"#, #""sha256_matches":"SECRET digest""#),
			(#""schema":1"#, #""schema":1,"private_path":"/private/SECRET""#),
		] {
			let receipt = Self.protectedInventoryFixedReceipt.replacingOccurrences(of: original, with: replacement)
			let observation = Self.protectedReferenceInventoryConsoleObservation(receipt)
			XCTAssertEqual(observation, "reference inventory observation unsupported")
			XCTAssertFalse(observation.contains("SECRET")); XCTAssertFalse(observation.contains("/private/"))
		}
	}

	func testProtectedReferenceInventoryConsoleKeepsFiniteMaximumWithinBound() {
		let observation = Self.protectedReferenceInventoryConsoleObservation(Self.protectedInventoryMaximumReceipt)
		XCTAssertEqual(observation, Self.protectedInventoryMaximumExpected)
		XCTAssertLessThanOrEqual(observation.utf8.count, 2048)
		XCTAssertTrue(observation.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e })
		XCTAssertFalse(observation.contains("authority=true")); XCTAssertFalse(observation.contains("/private/"))
	}

	// Immutable original-package scalar ports; these hypothetical receipts qualify no native payload.
	private static var protectedInventoryFixedReceipt: String {
		let rows = [
			#"{"bytes_matches":null,"index":0,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":1,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":2,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":3,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":true,"index":4,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":5,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":6,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":7,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":8,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":true,"index":9,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":10,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":11,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":12,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":13,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":14,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":15,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":16,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":17,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":18,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":19,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":20,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":21,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":22,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":23,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":24,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":25,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":26,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":27,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":28,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":29,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":30,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":31,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":32,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":33,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":34,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":35,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":36,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":37,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":38,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":null,"index":39,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":40,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
			#"{"bytes_matches":true,"index":41,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#,
		]
		let body = #"{"authority":false,"expected_count":42,"extra_count":0,"installation_qualified":false,"kind":"installed_vhd_payload_inventory_refusal_observation","missing_expected_indices":[3,8],"reason":"payload_inventory","reference_qualified":false,"rows":["#
			+ rows.joined(separator: ",") + #"],"schema":1,"version":"8.4.0"}"#
		return "ERGOPTI_VHD_PAYLOAD_INVENTORY_DIAGNOSTIC " + body + "\n"
	}

	private static let protectedInventoryFixedExpected = "reference inventory observation version=8.4.0 authority=false extra=0 missing=3,8 rows=0=1TTNN,1"
		+ "=1TTNN,2=1TTNN,3=0NNNN,4=1TTTT,5=1TTNN,6=1TTNN,7=1TTNN,8=0NNNN,9=1TTTT,10=1TTNN,11=1TTTT,12=1TTT"
		+ "T,13=1TTTT,14=1TTNN,15=1TTTT,16=1TTTT,17=1TTNN,18=1TTTT,19=1TTNN,20=1TTTT,21=1TTTT,22=1TTNN,23=1"
		+ "TTNN,24=1TTNN,25=1TTNN,26=1TTNN,27=1TTNN,28=1TTNN,29=1TTTT,30=1TTNN,31=1TTTT,32=1TTTT,33=1TTNN,3"
		+ "4=1TTTT,35=1TTNN,36=1TTTT,37=1TTTT,38=1TTNN,39=1TTNN,40=1TTTT,41=1TTTT legend=present,type,mode,"
		+ "bytes,sha256(T/F/N)"

	private static var protectedInventoryMaximumReceipt: String {
		let rows = [
			#"{"bytes_matches":null,"index":0,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":1,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":2,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":3,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":4,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":5,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":6,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":7,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":8,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":9,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":10,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":11,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":12,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":13,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":14,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":15,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":16,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":17,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":18,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":19,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":20,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":21,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":22,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":23,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":24,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":25,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":26,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":27,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":28,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":29,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":30,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":31,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":32,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":33,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":34,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":35,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":36,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":37,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":38,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":39,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":40,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
			#"{"bytes_matches":null,"index":41,"mode_matches":null,"present":false,"sha256_matches":null,"type_matches":null}"#,
		]
		let body = #"{"authority":false,"expected_count":42,"extra_count":1024,"installation_qualified":false,"kind":"installed_vhd_payload_inventory_refusal_observation","missing_expected_indices":[0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41],"reason":"payload_inventory","reference_qualified":false,"rows":["#
			+ rows.joined(separator: ",") + #"],"schema":1,"version":"8.4.0"}"#
		return "ERGOPTI_VHD_PAYLOAD_INVENTORY_DIAGNOSTIC " + body + "\n"
	}

	private static let protectedInventoryMaximumExpected = "reference inventory observation version=8.4.0 authority=false extra=1024 missing=0,1,2,3,4,5,6,7"
		+ ",8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,4"
		+ "0,41 rows=0=0NNNN,1=0NNNN,2=0NNNN,3=0NNNN,4=0NNNN,5=0NNNN,6=0NNNN,7=0NNNN,8=0NNNN,9=0NNNN,10=0NN"
		+ "NN,11=0NNNN,12=0NNNN,13=0NNNN,14=0NNNN,15=0NNNN,16=0NNNN,17=0NNNN,18=0NNNN,19=0NNNN,20=0NNNN,21="
		+ "0NNNN,22=0NNNN,23=0NNNN,24=0NNNN,25=0NNNN,26=0NNNN,27=0NNNN,28=0NNNN,29=0NNNN,30=0NNNN,31=0NNNN,"
		+ "32=0NNNN,33=0NNNN,34=0NNNN,35=0NNNN,36=0NNNN,37=0NNNN,38=0NNNN,39=0NNNN,40=0NNNN,41=0NNNN legend"
		+ "=present,type,mode,bytes,sha256(T/F/N)"

	private static let protectedInventoryFixedFirstRow = #"{"bytes_matches":null,"index":0,"mode_matches":true,"present":true,"sha256_matches":null,"type_matches":true}"#
	private static let protectedInventoryFixedLastRow = #"{"bytes_matches":true,"index":41,"mode_matches":true,"present":true,"sha256_matches":true,"type_matches":true}"#

	/// Runs all eleven protected-reference controls inside one explicit SDK-owned fixture.
	func testActualOwnedProtectedVirtualHIDReferenceCases() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let script = diagnostics.appendingPathComponent("installed_vhd_reference_fixture.py")
			let stage = root.appendingPathComponent("reference-payload")
			try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let prepared = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", script.path, "prepare", stage.path], root: root)
			XCTAssertEqual(prepared.status, 0, "Actual pinned package acquisition/verification prerequisite refused; "
				+ Self.protectedReferenceFailureSummary(prepared.stdout))
			XCTAssertTrue(prepared.stderr.isEmpty,
				Self.protectedReferenceInventoryConsoleObservation(prepared.stderr))
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
