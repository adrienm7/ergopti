// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/PkgutilCapabilityFixtureTests.swift
// TEST ONLY: no installation, protected reference, driver activation or runtime qualification.

import CryptoKit
import Darwin
import Foundation
import XCTest

private enum PkgutilCapabilityError: Error { case prerequisite, observation }

extension HS274NativePolicyQualificationTests {

	private static func closedPkgutilPortableReceipt(_ stderr: String) -> Bool {
		guard stderr.utf8.count <= 160,
			let expression = try? NSRegularExpression(
				pattern: #"\A\.{11}\n-{70}\nRan 11 tests in [0-9]+\.[0-9]{3}s\n\nOK\n\z"#) else { return false }
		let range = NSRange(stderr.startIndex..<stderr.endIndex, in: stderr)
		return expression.firstMatch(in: stderr, range: range)?.range == range
	}

	/// Ordinary unfiltered discovery uses the unchanged SDK Guardian and Python25 budget.
	func testActualPkgutilCapabilityFixtureExpandsOnlyItsInertMarkerAndRefusesCorruption() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let fullReceipt = "...........\n" + String(repeating: "-", count: 70)
				+ "\nRan 11 tests in 0.001s\n\nOK\n"
			XCTAssertTrue(Self.closedPkgutilPortableReceipt(fullReceipt))
			for malformed in ["EXTRA\n" + fullReceipt, fullReceipt + "EXTRA\n",
				fullReceipt.replacingOccurrences(of: "Ran 11", with: "Ran 9"),
				fullReceipt.replacingOccurrences(of: "OK\n", with: "OK (skipped=1)\n"),
				fullReceipt.replacingOccurrences(of: "0.001", with: "nan")] {
				XCTAssertFalse(Self.closedPkgutilPortableReceipt(malformed))
			}
			let helper = source("pkgutil_capability_fixture.py")
			let controls = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", "-m", "unittest", "discover", "-s", helper.deletingLastPathComponent().path,
				 "-p", "pkgutil_capability_fixture_test.py"], root: root)
			XCTAssertEqual(controls.status, 0)
			XCTAssertTrue(controls.stdout.isEmpty)
			XCTAssertTrue(Self.closedPkgutilPortableReceipt(controls.stderr))
			guard controls.status == 0, controls.stdout.isEmpty,
				Self.closedPkgutilPortableReceipt(controls.stderr) else {
				throw PkgutilCapabilityError.prerequisite
			}
			let stage = root.appendingPathComponent("pkgutil-capability-probe")
			try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-B", helper.path, stage.path], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Test-only pkgutil capability prerequisite refused; " + String(receipt.stdout.prefix(4096)))
			XCTAssertTrue(receipt.stderr.isEmpty)
			guard receipt.status == 0, receipt.stderr.isEmpty, receipt.stdout.utf8.count <= 65537 else {
				throw PkgutilCapabilityError.prerequisite
			}
			let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(Set(packet.keys), Set(["schema", "kind", "status", "full_expansion_observed",
				"corrupt_header_refused", "negative_status", "package_generation_count", "deadline_seconds",
				"probe_directory_retired", "installation_qualified", "reference_qualified", "runtime_qualified", "tool_sha256",
				"source_sha256", "expected_marker_base64", "observed_expanded_inventory", "packages"]))
			XCTAssertEqual(packet["schema"] as? Int, 1)
			XCTAssertEqual(packet["kind"] as? String, "test_only_pkgutil_capability_fixture")
			XCTAssertEqual(packet["status"] as? String, "prepared_and_observed")
			XCTAssertEqual(packet["full_expansion_observed"] as? Bool, true)
			XCTAssertEqual(packet["corrupt_header_refused"] as? Bool, true)
			XCTAssertEqual(packet["negative_status"] as? String, "verified_nonzero")
			XCTAssertEqual(packet["package_generation_count"] as? Int, 1)
			XCTAssertEqual(packet["deadline_seconds"] as? Int, 25)
			XCTAssertEqual(packet["probe_directory_retired"] as? Bool, true)
			for key in ["installation_qualified", "reference_qualified", "runtime_qualified"] {
				XCTAssertEqual(packet[key] as? Bool, false)
			}
			let marker = Data("Ergopti pkgutil capability fixture\n".utf8)
			XCTAssertEqual(packet["expected_marker_base64"] as? String, marker.base64EncodedString())
			let inventory = try XCTUnwrap(packet["observed_expanded_inventory"] as? [String: Any])
			XCTAssertEqual(Set(inventory.keys), Set(["Bom", "PackageInfo", "Payload", "Payload/ergopti-capability.txt"]))
			let markerObservation = try XCTUnwrap(inventory["Payload/ergopti-capability.txt"] as? [String: Any])
			let markerDigest = SHA256.hash(data: marker).map { String(format: "%02x", $0) }.joined()
			XCTAssertEqual(markerObservation["sha256"] as? String, markerDigest)
			XCTAssertEqual(markerObservation["bytes"] as? Int, marker.count)
			let packages = try XCTUnwrap(packet["packages"] as? [String: [String: Any]])
			XCTAssertEqual(Set(packages.keys), Set(["positive.pkg", "corrupt-header.pkg"]))
			var packageBytes: [String: Data] = [:]
			for name in ["positive.pkg", "corrupt-header.pkg"] {
				let entry = try XCTUnwrap(packages[name])
				XCTAssertEqual(Set(entry.keys), Set(["bytes", "sha256", "base64"]))
				let encoded = try XCTUnwrap(entry["base64"] as? String)
				guard encoded.utf8.count <= 21848, let bytes = Data(base64Encoded: encoded),
					bytes.count > 28, bytes.count <= 16384 else { throw PkgutilCapabilityError.observation }
				XCTAssertEqual(entry["bytes"] as? Int, bytes.count)
				XCTAssertEqual(entry["sha256"] as? String,
					SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
				packageBytes[name] = bytes
			}
			let positive = try XCTUnwrap(packageBytes["positive.pkg"])
			let negative = try XCTUnwrap(packageBytes["corrupt-header.pkg"])
			XCTAssertEqual(positive.prefix(4), Data("xar!".utf8))
			XCTAssertEqual(negative, Data("BAD!".utf8) + positive.dropFirst(4))
			let sources = try XCTUnwrap(packet["source_sha256"] as? [String: String])
			XCTAssertEqual(Set(sources.keys), Set(["generator_probe", "original_reference"]))
			XCTAssertEqual(sources["original_reference"], "642baf8c465d5d6e3d87fdc04050060ac393c0b4d4e47e29cbcd0c6d1b9a213d")
			XCTAssertEqual(sources["generator_probe"],
				SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined())
			let tools = try XCTUnwrap(packet["tool_sha256"] as? [String: String])
			XCTAssertEqual(Set(tools.keys), Set(["pkgbuild", "pkgutil"]))
			for digest in tools.values {
				XCTAssertEqual(digest.count, 64)
				XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
			}
			// run() has already acknowledged Guardian retirement. The worker's
			// checked cleanup must leave no probe path before ordinary outer cleanup.
			let absent = stage.withUnsafeFileSystemRepresentation { path -> Bool in
				guard let path else { return false }
				var info = stat()
				errno = 0
				return lstat(path, &info) == -1 && errno == ENOENT
			}
			XCTAssertTrue(absent)
			guard absent else { throw PkgutilCapabilityError.observation }
			// Preserve only the capped inert package byte envelopes/provenance.
			print(receipt.stdout, terminator: "")
		}
	}
}
