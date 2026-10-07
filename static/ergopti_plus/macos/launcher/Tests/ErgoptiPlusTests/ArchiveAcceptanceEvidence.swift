// Typed archive diagnostic facts only; private fixtures and command streams never enter this export.

import CoreFoundation
import Darwin
import Foundation
import XCTest

final class ArchiveAcceptanceEvidence {
	enum Owner: String { case brew, sparkle }

	/// A diagnostic describes an already acquired child; it cannot admit readiness or closure.
	struct ServerDiagnostic {
		let stage: String
		let pid: Int32
		let state: String
		let nativeStatus: Int32?
		let nativeReason: String?
		let captures: String
		var stdoutBytes: Int? = nil
		var stderrBytes: Int? = nil
		var stdoutSHA256: String? = nil
		var stderrSHA256: String? = nil
		var helperPhase: String? = nil
		var helperException: String? = nil
		var lastPhase: String? = nil

		var packet: [String: Any]? {
			guard ["readiness-refused", "before-cleanup", "after-server-exit"].contains(stage),
				["pending", "terminal", "unavailable"].contains(state),
				["pending", "available", "unavailable"].contains(captures),
				pid > 0 || (pid == 0 && state == "unavailable"),
				state == "terminal" ? (nativeStatus != nil && ["exit", "signal"].contains(nativeReason ?? "")) : (nativeStatus == nil && nativeReason == nil),
				state == "pending" ? captures == "pending" : captures != "pending" else { return nil }
			var result: [String: Any] = ["stage": stage, "pid": pid, "state": state, "captures": captures]
			if state == "terminal" {
				guard let nativeStatus, let nativeReason else { return nil }
				result["native_status"] = nativeStatus; result["native_reason"] = nativeReason
			}
			if captures == "available" {
				guard state == "terminal", let stdoutBytes, let stderrBytes,
					(0..<4_000_000).contains(stdoutBytes), (0..<4_000_000).contains(stderrBytes),
					let stdoutSHA256, let stderrSHA256, Self.digest(stdoutSHA256), Self.digest(stderrSHA256) else { return nil }
				result["stdout_bytes"] = stdoutBytes; result["stderr_bytes"] = stderrBytes
				result["stdout_sha256"] = stdoutSHA256; result["stderr_sha256"] = stderrSHA256
			} else if stdoutBytes != nil || stderrBytes != nil || stdoutSHA256 != nil || stderrSHA256 != nil { return nil }
			if helperPhase != nil || helperException != nil {
				guard captures == "available", let helperPhase, let helperException,
					Self.helperPhases.contains(helperPhase), Self.helperExceptions.contains(helperException) else { return nil }
				result["helper_phase"] = helperPhase; result["helper_exception"] = helperException
			}
			if let lastPhase {
				guard captures == "available", Self.helperPhases.contains(lastPhase) else { return nil }
				result["last_phase"] = lastPhase
			}
			return result
		}

		private static func digest(_ value: String) -> Bool {
			value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
		}
		static let helperPhases = Set(["entry", "directory-admission", "nonce-admission", "socket-bind", "signal-registration", "readiness-publication", "request-loop", "server-retirement"])
		static let helperExceptions = Set(["RuntimeError", "OSError", "PermissionError", "FileNotFoundError", "ValueError", "TypeError", "NameError", "ImportError", "ModuleNotFoundError", "OverflowError", "unclassified"])

		/// At most eight fixed phase checkpoints; every row must belong to this child.
		static func progressMarker(_ stderr: String, pid: Int32) -> String? {
			let prefix = "Sparkle server progress: "
			let lines = stderr.split(separator: "\n").filter { $0.hasPrefix(prefix) }
			guard !lines.isEmpty, lines.count <= helperPhases.count else { return nil }
			var last: String?
			for line in lines {
				let data = Data(line.dropFirst(prefix.count).utf8)
				guard data.count <= 512, let object = try? JSONSerialization.jsonObject(with: data),
					let packet = object as? [String: Any], Set(packet.keys) == Set(["schema", "pid", "phase"]),
					let schema = packet["schema"] as? NSNumber, let nativePID = packet["pid"] as? NSNumber,
					CFGetTypeID(schema) != CFBooleanGetTypeID(), CFGetTypeID(nativePID) != CFBooleanGetTypeID(),
					!["f", "d"].contains(String(cString: schema.objCType)), !["f", "d"].contains(String(cString: nativePID.objCType)),
					schema.int64Value == 1, nativePID.int64Value == Int64(pid),
					let phase = packet["phase"] as? String, helperPhases.contains(phase) else { return nil }
				last = phase
			}
			return last
		}

		/// The marker is optional, bounded, and tied to this acquired child, never a path or exception message.
		static func helperMarker(_ stderr: String, pid: Int32) -> (String, String)? {
			let prefix = "Sparkle server diagnostic: "
			let lines = stderr.split(separator: "\n").filter { $0.hasPrefix(prefix) }
			guard lines.count == 1 else { return nil }
			let data = Data(lines[0].dropFirst(prefix.count).utf8)
			guard data.count <= 512, let object = try? JSONSerialization.jsonObject(with: data),
				let packet = object as? [String: Any], Set(packet.keys) == Set(["schema", "pid", "phase", "exception_type"]),
				let schema = packet["schema"] as? NSNumber, let nativePID = packet["pid"] as? NSNumber,
				CFGetTypeID(schema) != CFBooleanGetTypeID(), CFGetTypeID(nativePID) != CFBooleanGetTypeID(),
				!["f", "d"].contains(String(cString: schema.objCType)), !["f", "d"].contains(String(cString: nativePID.objCType)),
				schema.int64Value == 1, nativePID.int64Value == Int64(pid),
				let phase = packet["phase"] as? String, helperPhases.contains(phase),
				let category = packet["exception_type"] as? String, helperExceptions.contains(category) else { return nil }
			return (phase, category)
		}
	}

	/// Secondary export failure is visible, but can never replace the operation's primary error.
	static func preservingPrimaryFailure<T>(operation: () throws -> T, collect: () throws -> Void,
		collectionRefused: () -> Void) throws -> T {
		do { return try operation() }
		catch {
			let primary = error
			do { try collect() } catch { collectionRefused() }
			throw primary
		}
	}
	let directory: URL
	private let descriptor: Int32
	private let started = ProcessInfo.processInfo.systemUptime
	private var sequence = 0
	private var lastSemantic: Data?
	private(set) var failed = false
	private static let cases = Set(["zip_install", "xz_upgrade", "checksum_refusal_preserved", "checksum_retry", "artifact_refusal_preserved", "artifact_retry"])
	private let owner: Owner

	init(owner: Owner, parent: URL? = nil) throws {
		self.owner = owner
		let environment = ProcessInfo.processInfo.environment
		let base = parent ?? environment["ERGOPTI_ARCHIVE_EVIDENCE_DIR"].map { URL(fileURLWithPath: $0) }
			?? URL(fileURLWithPath: environment["RUNNER_TEMP"] ?? NSTemporaryDirectory())
				.resolvingSymlinksInPath().appendingPathComponent("swift-launcher-evidence")
		if parent == nil, environment["ERGOPTI_ARCHIVE_EVIDENCE_DIR"] != nil {
			guard let runnerTemp = environment["RUNNER_TEMP"] else { throw CocoaError(.fileReadNoPermission) }
			let expectedParent = URL(fileURLWithPath: runnerTemp).resolvingSymlinksInPath().appendingPathComponent("swift-launcher-evidence")
			guard base.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path == expectedParent.standardizedFileURL.path,
				base.lastPathComponent.hasPrefix("archive-session.") else { throw CocoaError(.fileReadNoPermission) }
		}
		if parent == nil, environment["ERGOPTI_ARCHIVE_EVIDENCE_DIR"] == nil, !FileManager.default.fileExists(atPath: base.path) {
			try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		}
		let parentFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		guard parentFD >= 0 else { throw CocoaError(.fileReadNoPermission) }
		defer { close(parentFD) }
		var parentInfo = stat()
		guard fstat(parentFD, &parentInfo) == 0, parentInfo.st_uid == getuid(), parentInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
			parent != nil || environment["ERGOPTI_ARCHIVE_EVIDENCE_DIR"] == nil || parentInfo.st_mode & 0o777 == 0o700 else {
			throw CocoaError(.fileReadNoPermission)
		}
		let name = "archive-" + owner.rawValue + "-" + UUID().uuidString
		guard mkdirat(parentFD, name, 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
		directory = base.appendingPathComponent(name)
		descriptor = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
		guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
	}

	deinit { close(descriptor) }

	func childDirectory() throws -> URL {
		guard mkdirat(descriptor, "helper", 0o700) == 0 else { throw CocoaError(.fileWriteFileExists) }
		return directory.appendingPathComponent("helper")
	}

	/// Closure is supplied only after the native owner's independent retirement ACK.
	/// A failed export never changes that ACK or interrupts physical cleanup.
	@discardableResult
	func record(_ phase: String, status: String = "pending", closed: Bool = false,
		ownedPIDs: [Int32] = [], facts: [String: Bool] = [:], server: ServerDiagnostic? = nil) -> Bool {
		let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789._-".utf8)
		guard !phase.isEmpty, phase.utf8.count <= 64, phase.utf8.allSatisfy({ allowed.contains($0) }),
			["pending", "accepted", "refused", "cleanup-debt"].contains(status),
			ownedPIDs.count <= 16, ownedPIDs.allSatisfy({ $0 > 0 }), Set(facts.keys).isSubset(of: Self.cases) else {
			failed = true; return false
		}
		var packet: [String: Any] = ["schema": 1, "owner": owner.rawValue,
			"owner_pid": ProcessInfo.processInfo.processIdentifier, "phase": phase,
			"scope": owner == .brew ? "helper-and-native-groups" : "application-installer-server-and-commands",
			"status": status, "ownership_closed": closed, "owned_pids": ownedPIDs, "cases": facts]
		if let server {
			guard owner == .sparkle, let diagnostic = server.packet else { failed = true; return false }
			packet["server_diagnostic"] = diagnostic
		}
		guard let semantic = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]) else {
			failed = true; return false
		}
		if semantic == lastSemantic { return !failed }
		packet["elapsed_seconds"] = ProcessInfo.processInfo.systemUptime - started
		packet["history_omitted"] = max(0, sequence + 1 - 256)
		guard let bytes = try? JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys]), bytes.count <= 4096 else {
			failed = true; return false
		}
		let temporary = ".phase-" + UUID().uuidString
		let fd = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
		guard fd >= 0 else { failed = true; return false }
		let stream = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
		defer { unlinkat(descriptor, temporary, 0) }
		do {
			try stream.write(contentsOf: bytes)
			try stream.synchronize()
			try stream.close()
			if sequence < 256 {
				let name = String(format: "phase-%03d.json", sequence)
				guard linkat(descriptor, temporary, descriptor, name, 0) == 0 else { throw CocoaError(.fileWriteUnknown) }
			}
			guard renameat(descriptor, temporary, descriptor, "checkpoint.json") == 0 else { throw CocoaError(.fileWriteUnknown) }
			lastSemantic = semantic
			sequence += 1
			return !failed
		} catch { try? stream.close(); failed = true; return false }
	}
}

final class ArchiveAcceptanceEvidenceTests: XCTestCase {
	private func privateRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ArchiveEvidenceControl-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
		return root
	}

	func testInitialEvidenceCannotClaimNativeClosure() throws {
		let root = try privateRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let evidence = try ArchiveAcceptanceEvidence(owner: .brew, parent: root)
		XCTAssertTrue(evidence.record("candidate.begin"))
		let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: evidence.directory.appendingPathComponent("checkpoint.json"))) as? [String: Any])
		XCTAssertEqual(packet["ownership_closed"] as? Bool, false)
		XCTAssertEqual(packet["owner"] as? String, "brew")
		XCTAssertEqual(packet["status"] as? String, "pending")
		XCTAssertEqual((packet["owner_pid"] as? NSNumber)?.int32Value, getpid())
		XCTAssertEqual(Set(packet.keys), Set(["schema", "owner", "owner_pid", "scope", "phase", "status", "ownership_closed", "owned_pids", "cases", "elapsed_seconds", "history_omitted"]))
	}

	func testEvidenceParentSymlinkIsRefusedBeforeAnyForeignWrite() throws {
		let root = try privateRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let foreign = root.appendingPathComponent("foreign")
		try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
		let link = root.appendingPathComponent("link")
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
		XCTAssertThrowsError(try ArchiveAcceptanceEvidence(owner: .brew, parent: link))
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), [])
	}

	func testRefusedPublicationNeverReplacesAnUnclosedCheckpoint() throws {
		let root = try privateRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let evidence = try ArchiveAcceptanceEvidence(owner: .sparkle, parent: root)
		XCTAssertTrue(evidence.record("candidate.begin"))
		let checkpoint = evidence.directory.appendingPathComponent("checkpoint.json")
		let original = try Data(contentsOf: checkpoint)
		let collision = evidence.directory.appendingPathComponent("phase-001.json")
		let expected = Data("Independent preexisting evidence bytes".utf8)
		try expected.write(to: collision, options: .withoutOverwriting)
		XCTAssertFalse(evidence.record("cleanup.closed", status: "accepted", closed: true))
		XCTAssertTrue(evidence.failed)
		XCTAssertEqual(try Data(contentsOf: checkpoint), original)
		XCTAssertEqual(try Data(contentsOf: collision), expected)
		XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: evidence.directory.path).contains { $0.hasPrefix(".phase-") })
	}
	func testServerDiagnosticRequiresPhysicalTerminalBeforePublishingStatus() throws {
		let root = try privateRoot()
		defer { try? FileManager.default.removeItem(at: root) }
		let evidence = try ArchiveAcceptanceEvidence(owner: .sparkle, parent: root)
		let live = ArchiveAcceptanceEvidence.ServerDiagnostic(stage: "readiness-refused", pid: 123, state: "pending", nativeStatus: nil, nativeReason: nil, captures: "pending")
		XCTAssertTrue(evidence.record("server.observation", status: "refused", server: live))
		let bytes = try Data(contentsOf: evidence.directory.appendingPathComponent("checkpoint.json"))
		let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
		let diagnostic = try XCTUnwrap(packet["server_diagnostic"] as? [String: Any])
		XCTAssertEqual(Set(diagnostic.keys), Set(["stage", "pid", "state", "captures"]))
		XCTAssertEqual(packet["ownership_closed"] as? Bool, false)
		let forged = ArchiveAcceptanceEvidence.ServerDiagnostic(stage: "readiness-refused", pid: 123, state: "pending", nativeStatus: 0, nativeReason: "exit", captures: "pending")
		XCTAssertFalse(evidence.record("server.observation-forged", server: forged))
		XCTAssertEqual(try Data(contentsOf: evidence.directory.appendingPathComponent("checkpoint.json")), bytes)
	}

	func testServerDiagnosticBoundsHashesAndHelperIdentityWithoutRawStreams() throws {
		var terminal = ArchiveAcceptanceEvidence.ServerDiagnostic(stage: "after-server-exit", pid: 123, state: "terminal", nativeStatus: 1, nativeReason: "exit", captures: "available")
		terminal.stdoutBytes = 0; terminal.stderrBytes = 31
		terminal.stdoutSHA256 = String(repeating: "a", count: 64); terminal.stderrSHA256 = String(repeating: "b", count: 64)
		terminal.helperPhase = "socket-bind"; terminal.helperException = "OSError"
		let packet = try XCTUnwrap(terminal.packet)
		XCTAssertEqual(packet["native_status"] as? Int32, 1)
		XCTAssertEqual(Set(packet.keys), Set(["stage", "pid", "state", "captures", "native_status", "native_reason", "stdout_bytes", "stderr_bytes", "stdout_sha256", "stderr_sha256", "helper_phase", "helper_exception"]))
		terminal.stderrBytes = 4_000_000; XCTAssertNil(terminal.packet)
		terminal.stderrBytes = 31; terminal.stderrSHA256 = "PRIVATE"; XCTAssertNil(terminal.packet)
		let marker = #"Sparkle server diagnostic: {"schema":1,"pid":123,"phase":"socket-bind","exception_type":"OSError"}"#
		XCTAssertEqual(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker, pid: 123)?.0, "socket-bind")
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker, pid: 124))
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker.replacingOccurrences(of: #""pid":123"#, with: #""pid":4294967419"#), pid: 123))
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker.replacingOccurrences(of: #""schema":1"#, with: #""schema":true"#), pid: 123))
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker + "\n" + marker, pid: 123))
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker.replacingOccurrences(of: "socket-bind", with: "/PRIVATE"), pid: 123))
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.helperMarker(marker.replacingOccurrences(of: #""schema":1"#, with: #""raw":"PRIVATE","schema":1"#), pid: 123))
	}

	func testProgressMarkersRequireExactChildClosedTypesAndFiniteRows() throws {
		let first = #"Sparkle server progress: {"schema":1,"pid":123,"phase":"directory-admission"}"#
		let last = #"Sparkle server progress: {"schema":1,"pid":123,"phase":"socket-bind"}"#
		XCTAssertEqual(ArchiveAcceptanceEvidence.ServerDiagnostic.progressMarker(first + "\n" + last, pid: 123), "socket-bind")
		for refused in [last.replacingOccurrences(of: #""pid":123"#, with: #""pid":true"#), last.replacingOccurrences(of: #""schema":1"#, with: #""schema":1.0"#), last.replacingOccurrences(of: "socket-bind", with: "/PRIVATE"), last.replacingOccurrences(of: #""schema":1"#, with: #""private":"SECRET","schema":1"#), String(repeating: last + "\n", count: 9)] {
			XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.progressMarker(refused, pid: 123))
		}
		XCTAssertNil(ArchiveAcceptanceEvidence.ServerDiagnostic.progressMarker(last, pid: 124))
	}

	func testSignaledDiagnosticExportsOnlyClosedFactsAndProgress() throws {
		var terminal = ArchiveAcceptanceEvidence.ServerDiagnostic(stage: "after-server-exit", pid: 123, state: "terminal", nativeStatus: 15, nativeReason: "signal", captures: "available")
		terminal.stdoutBytes = 0; terminal.stderrBytes = 100
		terminal.stdoutSHA256 = String(repeating: "a", count: 64); terminal.stderrSHA256 = String(repeating: "b", count: 64)
		terminal.lastPhase = "socket-bind"
		let packet = try XCTUnwrap(terminal.packet)
		XCTAssertEqual(packet["last_phase"] as? String, "socket-bind")
		XCTAssertEqual(packet["native_reason"] as? String, "signal")
		XCTAssertNil(packet["stdout"]); XCTAssertNil(packet["stderr"])
		terminal.lastPhase = "/PRIVATE"; XCTAssertNil(terminal.packet)
		terminal.lastPhase = "socket-bind"; terminal.stderrBytes = 4_000_000; XCTAssertNil(terminal.packet)
	}

	func testDiagnosticCloseOrPublicationFailureCannotReplacePrimaryException() throws {
		let primary = NSError(domain: "IndependentPrimary", code: 17)
		let secondary = NSError(domain: "IndependentSecondary", code: 23)
		var collections = 0
		var refusals = 0
		do {
			let _: Int = try ArchiveAcceptanceEvidence.preservingPrimaryFailure(operation: { throw primary },
				collect: { collections += 1; throw secondary }, collectionRefused: { refusals += 1 })
			XCTFail("The original operation must remain failed")
		} catch { XCTAssertTrue((error as NSError) === primary) }
		XCTAssertEqual(collections, 1); XCTAssertEqual(refusals, 1)
		let accepted = try ArchiveAcceptanceEvidence.preservingPrimaryFailure(operation: { 29 },
			collect: { collections += 1 }, collectionRefused: { refusals += 1 })
		XCTAssertEqual(accepted, 29); XCTAssertEqual(collections, 1); XCTAssertEqual(refusals, 1)
	}
}
