// Typed archive diagnostic facts only; private fixtures and command streams never enter this export.

import Darwin
import Foundation
import XCTest

final class ArchiveAcceptanceEvidence {
	enum Owner: String { case brew, sparkle }
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
		ownedPIDs: [Int32] = [], facts: [String: Bool] = [:]) -> Bool {
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
}
