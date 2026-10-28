// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeAppClonerWorkerCompletionTests.swift
//
// Qualifies the actual worker and completion predicate through Darwin osascript.
// This source is a scratch regression candidate, pending root integration.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeAppClonerWorkerCompletionTests: XCTestCase {
	private static var repositoryURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root
	}

	func testActualCompletionPredicateSettlesAfterStatusPersistenceRefusal() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerWorker-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		var ownershipClosed = false
		defer {
			if ownershipClosed {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native worker fixture directory did not retire") }
			}
		}
		let outputURL = root.appendingPathComponent("observer.stdout")
		let errorURL = root.appendingPathComponent("observer.stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil, attributes: [.posixPermissions: 0o600]))
		let output = try FileHandle(forWritingTo: outputURL)
		defer {
			do { try output.close() }
			catch { ownershipClosed = false; XCTFail("The native worker stdout handle did not retire") }
		}
		let errors = try FileHandle(forWritingTo: errorURL)
		defer {
			do { try errors.close() }
			catch { ownershipClosed = false; XCTFail("The native worker stderr handle did not retire") }
		}
		let probe = Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-worker-completion-probe.py")
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["python3", probe.path, Self.repositoryURL.path, root.path]
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 45) == .success else {
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 5) != .success {
				XCTFail("The exact native worker observer did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		guard process.terminationReason == .exit else { throw CocoaError(.executableRuntimeMismatch) }
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		let data = try Data(contentsOf: outputURL)
		let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		ownershipClosed = report["ownership_closed"] as? Bool == true
		XCTAssertTrue(ownershipClosed, "An interrupted native boundary must retain its ownership debt")
		XCTAssertEqual(process.terminationStatus, 0, "Native worker regression must pass every case: \(String(decoding: data, as: UTF8.self)); \(stderr)")
		XCTAssertEqual(report["state"] as? String, "NATIVE_COMPLETION_REGRESSION_PASSED")
		let cases = try XCTUnwrap(report["cases"] as? [[String: Any]])
		XCTAssertEqual(cases.count, 3)
		XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), ["healthy", "refused-default", "refused-inherited-ignore"])
		for item in cases {
			let native = try XCTUnwrap(item["native"] as? [String: Any])
			XCTAssertEqual(native["predicate_accepted"] as? Bool, true, "Completion may not be absent after worker retirement")
			XCTAssertEqual(native["absent_control_accepted"] as? Bool, false, "An absent completion cannot pass the predicate oracle")
			XCTAssertEqual(native["worker_retired_by_actual_wait"] as? Bool, true)
		}
	}
}
