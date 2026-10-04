// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HomebrewArchiveAcceptanceTests.swift
//
// Real Brew ZIP installation and XZ upgrade in a private native write sandbox.
// Missing native prerequisites fail acceptance; portable controls are separate.

import Darwin
import Foundation
import XCTest

final class HomebrewArchiveAcceptanceTests: XCTestCase {
	private enum FixtureError: Error {
		case timedOut
		case refused(Int32, String)
	}

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	func testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState() throws {
		let manager = FileManager.default
		let root = manager.temporaryDirectory.appendingPathComponent("ErgoptiBrewInvoker-" + UUID().uuidString)
		try manager.createDirectory(at: root, withIntermediateDirectories: false,
			attributes: [.posixPermissions: 0o700])
		guard (try manager.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
			throw FixtureError.refused(-1, "Brew invoker directory is not private")
		}
		var canRetire = false
		defer {
			if canRetire {
				do { try manager.removeItem(at: root) }
				catch { XCTFail("Owned Brew invoker fixture could not retire: \(error)") }
			}
		}
		let receiptURL = root.appendingPathComponent("receipt.json")
		let outputURL = root.appendingPathComponent("stdout")
		let errorURL = root.appendingPathComponent("stderr")
		XCTAssertTrue(manager.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(manager.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
		process.arguments = ["python3", Self.repositoryURL.appendingPathComponent(
			"tools/diagnostics/macos_brew_archive_acceptance.py").path,
			Self.repositoryURL.path, receiptURL.path, "--fixture-parent", root.path]
		process.environment = NativeFixtureChildEnvironment.make()
		process.currentDirectoryURL = root
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		var observedExit = false
		var launched = false
		func observeExit(_ seconds: Double) -> Bool {
			if observedExit { return !process.isRunning }
			guard completed.wait(timeout: .now() + seconds) == .success else { return false }
			observedExit = true
			return !process.isRunning
		}
		func readReceipt() throws -> Data {
			let descriptor = open(receiptURL.path, O_RDONLY | O_NOFOLLOW)
			guard descriptor >= 0 else { throw FixtureError.refused(-1, "Missing ordinary receipt") }
			let stream = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
			defer { try? stream.close() }
			var info = stat()
			guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
				throw FixtureError.refused(-1, "Receipt is not an ordinary file")
			}
			return try stream.readToEnd() ?? Data()
		}
		func ownershipClosed() -> Bool {
			guard observedExit, !process.isRunning,
				let data = try? readReceipt(),
				let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
				let ownership = packet["ownership"] as? [String: Any],
				Set(ownership.keys) == Set(["schema", "helper_pid", "closed"]),
				ownership["schema"] as? Int == 1,
				(ownership["helper_pid"] as? NSNumber)?.int32Value == process.processIdentifier,
				ownership["closed"] as? Bool == true else { return false }
			return true
		}
		func retireInvoker() -> Bool {
			guard launched else { return true }
			if !observeExit(0) {
				if process.isRunning { process.terminate() }
				guard observeExit(15) else { return false }
			}
			return ownershipClosed()
		}
		// A later retry never consumes the completion semaphore twice or kills
		// the helper that still owns reserved child PIDs and inherited PGIDs.
		defer {
			if !retireInvoker() {
				canRetire = false
				XCTFail("Brew ownership acknowledgement remains incomplete; retained fixture: \(root.path)")
			}
		}
		process.terminationHandler = { _ in completed.signal() }
		do { try process.run(); launched = true }
		catch { launched = process.processIdentifier > 0; throw error }
		guard observeExit(900) else {
			_ = retireInvoker()
			XCTFail("Real Brew acceptance exceeded its deadline; retained fixture: \(root.path)")
			throw FixtureError.timedOut
		}
		guard ownershipClosed() else {
			XCTFail("Real Brew helper exited without its exact ownership acknowledgement; retained fixture: \(root.path)")
			throw FixtureError.refused(process.terminationStatus, "Missing native ownership acknowledgement")
		}
		XCTAssertFalse(process.isRunning)
		XCTAssertEqual(process.terminationReason, .exit)
		let stdout = try Data(contentsOf: outputURL)
		let stderr = try Data(contentsOf: errorURL)
		guard process.terminationStatus == 0 else {
			let diagnostic = String(decoding: stderr.prefix(4096), as: UTF8.self)
			XCTFail("Real Brew acceptance refused; retained fixture: \(root.path); \(String(reflecting: diagnostic))")
			throw FixtureError.refused(process.terminationStatus, diagnostic)
		}
		XCTAssertTrue(stdout.isEmpty, "Receipt files own evidence; stdout never carries TLS or credential payloads")
		XCTAssertTrue(stderr.isEmpty, String(decoding: stderr.prefix(4096), as: UTF8.self))
		let receipt = try XCTUnwrap(try JSONSerialization.jsonObject(with: readReceipt()) as? [String: Any])
		XCTAssertEqual(receipt["kind"] as? String, "native-homebrew-archive-acceptance")
		XCTAssertEqual(receipt["complete"] as? Bool, true)
		XCTAssertEqual(receipt["host_unchanged"] as? Bool, true)
		XCTAssertEqual(receipt["fixture_retained"] as? Bool, false)
		XCTAssertEqual(receipt["cleanup_errors"] as? [String], [])
		XCTAssertEqual(receipt["signature_identity_boundary"] as? String, "upstream-publication")
		let cases = try XCTUnwrap(receipt["cases"] as? [String: Bool])
		XCTAssertEqual(cases, ["zip_install": true, "xz_upgrade": true,
			"checksum_refusal_preserved": true, "checksum_retry": true,
			"artifact_refusal_preserved": true, "artifact_retry": true])
		let requests = try XCTUnwrap(receipt["requests"] as? [String])
		XCTAssertGreaterThanOrEqual(requests.count, 6, "Two refusals and their recovery acquire actual HTTPS origin assets")
		let brew = try XCTUnwrap(receipt["brew"] as? [String: Any])
		XCTAssertFalse(try XCTUnwrap(brew["version"] as? String).isEmpty)
		XCTAssertEqual(try XCTUnwrap(brew["entrypoint_sha256"] as? String).count, 64)
		// Cleanup is eligible only after the entire strict receipt was admitted.
		canRetire = ownershipClosed()
			&& receipt["complete"] as? Bool == true
			&& receipt["fixture_retained"] as? Bool == false
			&& receipt["host_unchanged"] as? Bool == true
			&& receipt["cleanup_errors"] as? [String] == []
	}
}
