// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274ActualRuntimeSigningTests.swift
// Native disposable TEST-ONLY signing qualification; no production identity.
// Retained direct Guardians retire before private credential cleanup.

import Foundation
import XCTest

private enum NativeDisposableSigningError: Error { case ownership }

extension HS274NativePolicyQualificationTests {

	/// One ordinary XCTest retains the existing worker and SDK caller budgets.
	/// A disposable TEST-ONLY certificate is not a production identity fallback.
	func testActualRuntimeSigningWithDisposableCredential() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let repository = diagnostics.deletingLastPathComponent().deletingLastPathComponent()
			let fixtureScript = diagnostics.appendingPathComponent("hs274_native_signing_fixture.py")
			let observerScript = diagnostics.appendingPathComponent("hs274_signed_runtime_observation.py")
			// Kept outside swift-launcher-evidence, including every refusal path.
			let privateRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
				.appendingPathComponent("ErgoptiTestOnlySigning-" + UUID().uuidString)
			guard !privateRoot.path.hasPrefix(parent.path + "/"), privateRoot != parent else {
				throw NativeDisposableSigningError.ownership
			}
			let publicOwner = root.appendingPathComponent("credential-public")
			let owner = root.appendingPathComponent("signed-compilation")
			let captures = root.appendingPathComponent("signed-observation")
			for directory in [publicOwner, owner, captures] {
				try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
					attributes: [.posixPermissions: 0o700])
			}
			var primaryError: Error?
			do {
				let setup = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", fixtureScript.path, "setup", privateRoot.path, publicOwner.path], root: root)
				XCTAssertEqual(setup.status, 0, "Native TEST-ONLY credential setup refused")
				XCTAssertTrue(setup.stderr.isEmpty)
				guard setup.status == 0, setup.stderr.isEmpty else { throw NativeDisposableSigningError.ownership }
				let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(setup.stdout.utf8)) as? [String: Any])
				guard Set(record.keys) == Set(["schema", "status", "identity", "public_leaf_sha256", "test_only",
					"shipping_qualified", "installation_qualified", "authentication_qualified"]),
					record["schema"] as? Int == 1, record["status"] as? String == "ready",
					record["test_only"] as? Bool == true,
					record["shipping_qualified"] as? Bool == false,
					record["installation_qualified"] as? Bool == false,
					record["authentication_qualified"] as? Bool == false else { throw NativeDisposableSigningError.ownership }
				let identity = try XCTUnwrap(record["identity"] as? String)
				guard identity.count == 40, identity.allSatisfy({ "0123456789ABCDEF".contains($0) }) else {
					throw NativeDisposableSigningError.ownership
				}
				// The credential exists before the ONE live compile/copy/sign handoff.
				let signed = try runOwnedRuntimeCompilation([repository.path, owner.path, "--sign-owned",
					"--budget", "300", "--signing-identity", identity, "--signing-keychain",
					privateRoot.appendingPathComponent("fixture.keychain-db").path, "--signing-public-leaf",
					privateRoot.appendingPathComponent("public-leaf.der").path], root: root)
				let expected = "PASS unsigned actual owned four-target compilation; signing and activation unqualified\n"
					+ "PASS retained unsigned runtime snapshot; native shipping and installation unqualified\n"
					+ "PASS fixed signed runtime snapshot; shipping, installation and live authentication unqualified\n"
				XCTAssertEqual(signed.status, 0, "Genuine disposable signing mechanics refused")
				XCTAssertEqual(signed.stdout, expected)
				XCTAssertTrue(signed.stderr.isEmpty)
				guard signed.status == 0, signed.stdout == expected, signed.stderr.isEmpty else {
					throw NativeDisposableSigningError.ownership
				}
				let observed = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", observerScript.path,
					repository.path, owner.path, publicOwner.appendingPathComponent("public-leaf.der").path,
					captures.path], root: root)
				XCTAssertEqual(observed.status, 0, "Native readonly signing observation refused")
				XCTAssertTrue(observed.stderr.isEmpty)
				guard observed.status == 0, observed.stderr.isEmpty else { throw NativeDisposableSigningError.ownership }
				let observation = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observed.stdout.utf8)) as? [String: Any])
				guard Set(observation.keys) == Set(["schema", "status", "identity", "targets", "architectures",
					"test_only", "shipping_qualified", "installation_qualified", "authentication_qualified"]),
					observation["schema"] as? Int == 1, observation["status"] as? String == "observed",
					observation["identity"] as? String == identity, observation["targets"] as? Int == 5,
					observation["architectures"] as? [String] == ["x86_64", "arm64"],
					observation["test_only"] as? Bool == true,
					observation["shipping_qualified"] as? Bool == false,
					observation["installation_qualified"] as? Bool == false,
					observation["authentication_qualified"] as? Bool == false else { throw NativeDisposableSigningError.ownership }
			} catch { primaryError = error }
			// A thrown finish() can retain a native child. Never erase credentials
			// until the actual Guardian acknowledges retirement of every child.
			try retireOwnedChildren()
			if FileManager.default.fileExists(atPath: privateRoot.path) {
				let cleaned = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", fixtureScript.path, "cleanup", privateRoot.path], root: root)
				XCTAssertEqual(cleaned.status, 0, "Exact TEST-ONLY keychain cleanup refused")
				XCTAssertEqual(cleaned.stdout, "{\"schema\": 1, \"status\": \"removed\", \"test_only\": true}\n")
				XCTAssertTrue(cleaned.stderr.isEmpty)
				guard cleaned.status == 0, cleaned.stderr.isEmpty,
					!FileManager.default.fileExists(atPath: privateRoot.path) else { throw NativeDisposableSigningError.ownership }
			}
			if let primaryError { throw primaryError }
		}
	}
}
