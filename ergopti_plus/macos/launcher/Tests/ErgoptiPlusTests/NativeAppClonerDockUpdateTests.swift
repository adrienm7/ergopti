// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeAppClonerDockUpdateTests.swift
//
// Run the actual Dock writer with Darwin file locking and owned preference files.
// Native bookmark/registration/restart boundaries are controlled, without Dock UI.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeAppClonerDockUpdateTests: XCTestCase {
	private static var repositoryURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root
	}

	func testConcurrentDockWritersKeepBothCloneEntries() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiDockLock-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		var ownershipClosed = false
		defer {
			if ownershipClosed {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The owned Dock campaign directory did not retire") }
			}
		}
		let outputURL = root.appendingPathComponent("campaign.stdout")
		let errorURL = root.appendingPathComponent("campaign.stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		let output = try FileHandle(forWritingTo: outputURL)
		defer {
			do { try output.close() }
			catch { ownershipClosed = false; XCTFail("The owned Dock stdout handle did not retire") }
		}
		let errors = try FileHandle(forWritingTo: errorURL)
		defer {
			do { try errors.close() }
			catch { ownershipClosed = false; XCTFail("The owned Dock stderr handle did not retire") }
		}
		let driver = Self.repositoryURL.appendingPathComponent("static/ergopti_plus/macos")
		let campaign = driver.appendingPathComponent("tests/support/apps/dock_update_campaign.py")
		let source = driver.appendingPathComponent("apps/App Cloner.app/Contents/Resources/clone_app.sh")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["python3", "-B", campaign.path, source.path, root.path]
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 65) == .success else {
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 10) != .success {
				XCTFail("The exact Dock campaign process did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		guard process.terminationReason == .exit else {
			XCTFail("The Dock campaign did not end with a normal retirement receipt")
			throw CocoaError(.executableRuntimeMismatch)
		}
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		let data = try Data(contentsOf: outputURL)
		let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		// A report is emitted only after Python's finally has retired its exact
		// workers and removed its owned fixture. Interrupted work retains root.
		ownershipClosed = true
		XCTAssertEqual(process.terminationStatus, 0, "\(String(decoding: data, as: UTF8.self)); \(stderr)")
		XCTAssertEqual(report["state"] as? String, "PASS")
		let checks = try XCTUnwrap(report["checks"] as? [String: Bool])
		XCTAssertFalse(checks.isEmpty)
		XCTAssertTrue(checks.values.allSatisfy { $0 }, "Every physical Dock control must pass")
		XCTAssertEqual(report["concurrent_labels"] as? [String], ["A", "B"])
	}
}
