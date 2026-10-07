// TEST-ONLY actual native API prerequisite, not installed-reference qualification.
import Foundation
import SystemExtensions
import XCTest
@testable import ErgoptiPlus

private enum ActiveVHDQueryQualificationError: Error { case prerequisite }

extension HS274NativePolicyQualificationTests {
	func testActiveExtensionObservationPortableControls() throws {
		try fixture { root in
			let controls = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("installed_vhd_active_extension_fixture_test.py").path, "-v"], root: root)
			XCTAssertEqual(controls.status, 0)
			XCTAssertTrue(controls.stderr.contains("Ran 13 tests"))
			XCTAssertTrue(controls.stderr.hasSuffix("OK\n"))
			print("PASS13 observational wire/actual filesystem controls; actual native API calls=0")
		}
	}

	func testActualSignedReadOnlyVirtualHIDPropertiesQuery() throws {
		try fixture { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let privateRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
				.appendingPathComponent("ErgoptiTestOnlyVHDQuery-" + UUID().uuidString)
			let publicRoot = root.appendingPathComponent("credential-public")
			let queryRoot = root.appendingPathComponent("query")
			for directory in [publicRoot, queryRoot] {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
					attributes: [.posixPermissions: 0o700])
			}
			var primaryError: Error?
			do {
				let setup = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", diagnostics.appendingPathComponent("hs274_native_signing_fixture.py").path,
						"setup", privateRoot.path, publicRoot.path], root: root)
				XCTAssertEqual(setup.status, 0, "Native TEST-ONLY signing prerequisite refused")
				guard setup.status == 0 else { throw ActiveVHDQueryQualificationError.prerequisite }
				let query = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", diagnostics.appendingPathComponent("installed_vhd_active_extension_fixture.py").path,
						queryRoot.path, privateRoot.path, publicRoot.path], root: root)
				XCTAssertEqual(query.status, 0, "Actual signed native properties-query fixture refused")
				guard query.status == 0 else { throw ActiveVHDQueryQualificationError.prerequisite }
				let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(query.stdout.utf8)) as? [String: Any])
				XCTAssertEqual(record["schema"] as? Int, 1)
				XCTAssertEqual(record["query_identifier"] as? String, "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice")
				XCTAssertEqual(record["signing_identifier"] as? String, "com.ergoptiplus.test.vhd-properties")
				XCTAssertEqual(record["test_only"] as? Bool, true)
				XCTAssertEqual(record["reference_qualified"] as? Bool, false)
				XCTAssertEqual(record["approval_qualified"] as? Bool, false)
				XCTAssertEqual(record["installed_positive_qualified"] as? Bool, false)
				let setupRecord = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setup.stdout.utf8)) as? [String: Any])
				XCTAssertEqual(record["public_leaf_sha256"] as? String, setupRecord["public_leaf_sha256"] as? String)
				let status = try XCTUnwrap(record["status"] as? String)
				print("Actual TEST-ONLY signed native properties-query observation: " + status
					+ "; reference/approval/installed-positive qualifications remain false")
				guard status == "observed_empty" || status == "observed_properties" else {
					XCTFail("Native properties-query prerequisite failed: " + status + "; production query remains UNQUALIFIED")
					throw ActiveVHDQueryQualificationError.prerequisite
				}
				XCTAssertEqual(record["callback_count"] as? Int, 1)
				if status == "observed_empty" {
					XCTAssertEqual((record["properties"] as? [[String: Any]])?.count, 0)
					print("PASS actual native empty properties request delivery; installed-positive UNEXECUTED")
				} else {
					XCTAssertEqual((record["properties"] as? [[String: Any]])?.count, 1)
					print("PASS actual native properties observation only; installed authority UNQUALIFIED")
				}
			} catch { primaryError = error }
			// No credential cleanup until every actual retained Guardian retires.
			try retireOwnedChildren()
			if FileManager.default.fileExists(atPath: privateRoot.path) {
				let cleanup = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", diagnostics.appendingPathComponent("hs274_native_signing_fixture.py").path,
						"cleanup", privateRoot.path], root: root)
				XCTAssertEqual(cleanup.status, 0, "Exact native TEST-ONLY signing cleanup refused")
				try retireOwnedChildren()
				guard cleanup.status == 0 else { throw ActiveVHDQueryQualificationError.prerequisite }
				XCTAssertFalse(FileManager.default.fileExists(atPath: privateRoot.path))
			}
			if let error = primaryError { throw error }
		}
	}
}

// Negative bookkeeping controls use genuine distinct OS request objects. No
// native properties objects are fabricated and no API delivery is claimed.
final class InstalledVHDActiveExtensionRequestCustodyTests: XCTestCase {
	func testForeignActualRequestObjectRefusesTheObservation() throws {
		guard #available(macOS 12.0, *) else { throw XCTSkip("Properties request API unavailable") }
		let probe = InstalledVirtualHIDActiveExtensionProbe.lifecycleForTest()
		let foreign = OSSystemExtensionRequest.propertiesRequest(
			forExtensionWithIdentifier: "org.pqrs.Karabiner-DriverKit-VirtualHIDDevice", queue: .main)
		probe.request(foreign, didFailWithError: NSError(domain: "unit-bookkeeping", code: 1))
		let receipt = probe.finishForTest()
		XCTAssertEqual(receipt.status, "query_refused")
		XCTAssertEqual(receipt.reason, "foreign_request_callback")
		XCTAssertFalse(receipt.referenceQualified)
	}

	func testDuplicateFailureCallbacksCannotPublishADeniedSuccessor() throws {
		guard #available(macOS 12.0, *) else { throw XCTSkip("Properties request API unavailable") }
		let probe = InstalledVirtualHIDActiveExtensionProbe.lifecycleForTest()
		let request = try XCTUnwrap(probe.requestForTest)
		probe.request(request, didFailWithError: NSError(domain: "unit-bookkeeping", code: 1))
		probe.request(request, didFailWithError: NSError(domain: "unit-bookkeeping", code: 1))
		let receipt = probe.finishForTest()
		XCTAssertEqual(receipt.status, "query_refused")
		XCTAssertEqual(receipt.reason, "duplicate_native_callback")
		XCTAssertFalse(receipt.installedPositiveQualified)
	}

	func testStopRevokesBeforeLateFailureDelivery() throws {
		guard #available(macOS 12.0, *) else { throw XCTSkip("Properties request API unavailable") }
		let probe = InstalledVirtualHIDActiveExtensionProbe.lifecycleForTest()
		let request = try XCTUnwrap(probe.requestForTest)
		probe.stop()
		probe.request(request, didFailWithError: NSError(domain: "unit-bookkeeping", code: 1))
		let receipt = probe.finishForTest()
		XCTAssertEqual(receipt.status, "query_refused")
		XCTAssertEqual(receipt.reason, "observation_stopped")
		XCTAssertEqual(receipt.callbackCount, 0)
	}

	func testAbsentNativeTerminalNeverBecomesEmptySuccess() throws {
		guard #available(macOS 12.0, *) else { throw XCTSkip("Properties request API unavailable") }
		let probe = InstalledVirtualHIDActiveExtensionProbe.lifecycleForTest()
		let receipt = probe.finishForTest()
		XCTAssertEqual(receipt.status, "query_timeout")
		XCTAssertEqual(receipt.callbackCount, 0)
		XCTAssertFalse(receipt.approvalQualified)
	}
}
