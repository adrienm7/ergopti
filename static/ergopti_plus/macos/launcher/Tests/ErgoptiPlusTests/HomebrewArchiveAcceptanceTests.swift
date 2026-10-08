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

	/// Keep normal OS permission requests explicit for each native fixture invocation.
	private static func consentArguments(_ environment: [String: String]) throws -> [String] {
		func enabled(_ name: String) throws -> Bool {
			guard let value = environment[name] else { return false }
			guard value == "0" || value == "1" else {
				throw FixtureError.refused(-1, "Malformed owned Automation consent opt-in")
			}
			return value == "1"
		}
		let request = try enabled("ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT")
		let approve = try enabled("ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI")
		guard !approve || request else {
			throw FixtureError.refused(-1, "Owned consent UI requires an explicit permission request")
		}
		return (request ? ["--allow-automation-consent"] : [])
			+ (approve ? ["--allow-owned-consent-ui"] : [])
	}

	func testAutomationConsentArgumentsRequireBothExplicitOptIns() throws {
		XCTAssertEqual(try Self.consentArguments([:]), [])
		XCTAssertEqual(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "0"]), [])
		XCTAssertEqual(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1"]),
			["--allow-automation-consent"])
		XCTAssertEqual(try Self.consentArguments([
			"ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1", "ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": "1"
		]), ["--allow-automation-consent", "--allow-owned-consent-ui"])
		XCTAssertThrowsError(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": "1"]))
		for invalid in ["true", "1\n", "", "2"] {
			XCTAssertThrowsError(try Self.consentArguments(["ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": invalid]))
			XCTAssertThrowsError(try Self.consentArguments([
				"ERGOPTI_BREW_ALLOW_AUTOMATION_CONSENT": "1", "ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI": invalid
			]))
		}
	}

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	func testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState() throws {
		let failuresBefore = try XCTUnwrap(testRun?.failureCount)
		let evidence = try ArchiveAcceptanceEvidence(owner: .brew)
		let evidenceDirectory = try evidence.childDirectory()
		var evidenceRefused = false
		func checkpoint(_ phase: String, status: String = "pending", closed: Bool = false, pids: [Int32] = [], facts: [String: Bool] = [:]) {
			if !evidence.record(phase, status: status, closed: closed, ownedPIDs: pids, facts: facts), !evidenceRefused {
				evidenceRefused = true
				XCTFail("Safe Brew phase evidence publication refused")
			}
		}
		checkpoint("candidate.begin")
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
			Self.repositoryURL.path, receiptURL.path, "--fixture-parent", root.path, "--evidence-directory", evidenceDirectory.path]
		let ordinaryArguments = try XCTUnwrap(process.arguments)
		process.arguments = ordinaryArguments + (try Self.consentArguments(ProcessInfo.processInfo.environment))
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
			checkpoint("cleanup.begin", pids: process.processIdentifier > 0 ? [process.processIdentifier] : [])
			if !retireInvoker() {
				checkpoint("cleanup.debt", status: "cleanup-debt", pids: process.processIdentifier > 0 ? [process.processIdentifier] : [])
				canRetire = false
				XCTFail("Brew ownership acknowledgement remains incomplete; retained fixture: \(root.path)")
			} else { checkpoint("cleanup.closed", status: "accepted", closed: true, pids: process.processIdentifier > 0 ? [process.processIdentifier] : []) }
			if evidenceRefused { canRetire = false }
		}
		process.terminationHandler = { _ in completed.signal() }
		do { try process.run(); launched = true }
		catch { launched = process.processIdentifier > 0; throw error }
		checkpoint("helper.started", pids: [process.processIdentifier])
		guard observeExit(900) else {
			checkpoint("deadline", status: "refused", pids: [process.processIdentifier])
			_ = retireInvoker()
			XCTFail("Real Brew acceptance exceeded its deadline; retained fixture: \(root.path)")
			throw FixtureError.timedOut
		}
		guard ownershipClosed() else {
			checkpoint("ownership.refused", status: "refused")
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
		checkpoint("receipt.checked", status: testRun?.failureCount == failuresBefore ? "accepted" : "refused", closed: true, pids: [process.processIdentifier], facts: cases)
		// Cleanup is eligible only after the entire strict receipt was admitted.
		canRetire = !evidenceRefused && ownershipClosed()
			&& receipt["complete"] as? Bool == true
			&& receipt["fixture_retained"] as? Bool == false
			&& receipt["host_unchanged"] as? Bool == true
			&& receipt["cleanup_errors"] as? [String] == []
	}
}
