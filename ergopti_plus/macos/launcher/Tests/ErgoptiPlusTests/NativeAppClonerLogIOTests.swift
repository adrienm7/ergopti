// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeAppClonerLogIOTests.swift
//
// Exercises the shipped Python main with actual Darwin regular-file refusals.
// Only icon/UI child terminal boundaries are controlled; no modal is opened.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeAppClonerLogIOTests: XCTestCase {
	private var fixtureCanRetire = true

	private static var repositoryURL: URL {
		var root = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { root.deleteLastPathComponent() }
		return root
	}

	private func observeProbe(root: URL) throws -> [String: Any] {
		let outputURL = root.appendingPathComponent("probe.stdout")
		let errorURL = root.appendingPathComponent("probe.stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["python3", Self.repositoryURL.appendingPathComponent("tools/test/lib/app-cloner-log-io-probe.py").path,
			"physical", Self.repositoryURL.appendingPathComponent("static/ergopti_plus/macos/apps/App Cloner.app/Contents/MacOS/AppCloner").path]
		var environment = NativeFixtureChildEnvironment.make()
		environment["TMPDIR"] = root.path
		process.environment = environment
		process.standardInput = FileHandle.nullDevice
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 30) == .success else {
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 5) != .success {
				fixtureCanRetire = false
				XCTFail("The exact App Cloner diagnostic probe did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		let diagnostic = try String(contentsOf: errorURL, encoding: .utf8)
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, 0, "The physical probe must execute: \(diagnostic)")
		XCTAssertTrue(diagnostic.isEmpty)
		return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [String: Any])
	}

	func testActualFileSizeRefusalPreservesUIAndOwnedDescriptorRetirement() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiClonerLogIO-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact diagnostic probe fixture did not retire") }
			}
		}
		let receipt = try observeProbe(root: root)
		XCTAssertEqual(receipt["permission_scope"] as? String, "posix_mode_bits")
		let cases = try XCTUnwrap(receipt["cases"] as? [[String: Any]])
		XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), Set(["healthy", "healthy-ui-error", "initial-refusal", "post-ui-refusal"]))
		XCTAssertEqual(cases.count, 4)
		for entry in cases {
			let name = try XCTUnwrap(entry["name"] as? String)
			let events = try XCTUnwrap(entry["events"] as? [[String: Any]])
			let normal = events.filter { ($0["argv"] as? [String])?.prefix(2) == ["osascript", Self.repositoryURL.appendingPathComponent("static/ergopti_plus/macos/apps/App Cloner.app/Contents/Resources/ShortcutBuilder.applescript").path] }
			let dialogs = events.filter { ($0["argv"] as? [String])?.prefix(2) == ["osascript", "-e"] }
			let warning = try XCTUnwrap(entry["warnings"] as? String)
			XCTAssertTrue(entry["error"] is NSNull, "The actual main must continue for \(name): \(entry)")
			XCTAssertEqual(normal.count, 1, "The actual main must admit normal UI for \(name)")
			XCTAssertEqual(entry["all_streams_closed"] as? Bool, true)
			XCTAssertEqual(try XCTUnwrap(entry["descriptor_errors"] as? [String]), [])
			XCTAssertGreaterThan(try XCTUnwrap(entry["owned_fd_count"] as? Int), 0)
			guard normal.count == 1 else { continue }
			let logPath = try XCTUnwrap(normal[0]["log_path"] as? String)
			if name.hasPrefix("healthy") {
				XCTAssertTrue(logPath.hasSuffix("appcloner.log"))
				XCTAssertTrue(try XCTUnwrap(normal[0]["log_content"] as? String).contains("[AppCloner] locale=en"))
				XCTAssertEqual(normal[0]["log_mode"] as? Int, 0o600)
				XCTAssertEqual(normal[0]["directory_mode"] as? Int, 0o700)
				XCTAssertTrue(warning.isEmpty)
			} else {
				XCTAssertEqual(entry["physical_file_limit_bytes"] as? Int, 0)
				XCTAssertTrue(warning.contains("diagnostic log persistence failed"))
			}
			if name == "initial-refusal" { XCTAssertEqual(logPath, "") }
			if name == "healthy-ui-error" || name == "post-ui-refusal" {
				XCTAssertEqual(dialogs.count, 1)
				guard dialogs.count == 1 else { continue }
				let argv = try XCTUnwrap(dialogs[0]["argv"] as? [String])
				XCTAssertEqual(argv.count, 7)
				guard argv.count == 7 else { continue }
				let expected = name == "healthy-ui-error" ? "Original native startup failure.\n\nThe complete diagnostic is in " + logPath : "Original native startup failure."
				XCTAssertEqual(argv[4], expected, "An unusable diagnostic path must not hide or decorate the original failure")
			} else {
				XCTAssertTrue(dialogs.isEmpty)
			}
		}
	}
}
