// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedConfigurationPublicationTests.swift
// Actual isolated native JSON/files, without installed runtime or physical remapping authority.

import CryptoKit
import Darwin
import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testActualOwnedPrivateConfigurationPublicationEightVariants() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let controller = source("hs_owned_configuration_fixture.py")
			let repository = controller.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Actual complete private configuration refused within unchanged SDK30/35/10; evidence="
				+ root.path + "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(Set(packet.keys), Set([
				"status", "qualification", "summary", "native_owner", "files", "record_sha256", "record_bytes",
				"record_relative", "source_count", "source_inventory_sha256", "controller_budget_seconds",
				"observation_retirement_seconds", "authority",
			]))
			XCTAssertEqual(packet["status"] as? String, "ok")
			XCTAssertEqual(packet["qualification"] as? String, "actual native private whole document publication")
			XCTAssertEqual(packet["controller_budget_seconds"] as? Int, 25)
			let elapsed = try XCTUnwrap(packet["observation_retirement_seconds"] as? Double)
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0 && elapsed < 25)
			XCTAssertGreaterThanOrEqual(try XCTUnwrap(packet["source_count"] as? Int), 100)
			let summary = try XCTUnwrap(packet["summary"] as? [String: Any])
			XCTAssertEqual(summary["contract"] as? String, "karabiner.owned-private-publication")
			XCTAssertEqual(summary["publication_scope"] as? String, "private-file-only")
			XCTAssertEqual(summary["variant_count"] as? Int, 8)
			XCTAssertGreaterThanOrEqual(try XCTUnwrap(summary["manipulator_count"] as? Int), 240)
			for name in ["installation", "remapping", "lease_initialized"] {
				XCTAssertEqual(summary[name] as? Bool, false)
			}
			for name in ["complete", "cleanup_settled", "stock_sentinel_preserved"] {
				XCTAssertEqual(summary[name] as? Bool, true)
			}
			let native = try XCTUnwrap(packet["native_owner"] as? [String: Any])
			let worker = try XCTUnwrap(native["worker_pid"] as? Int)
			XCTAssertGreaterThan(worker, 0)
			XCTAssertEqual(native["group_id"] as? Int, worker)
			XCTAssertEqual(native["closed"] as? Bool, true)
			XCTAssertEqual(native["reservation_lost"] as? Bool, false)
			XCTAssertEqual(native["escaped_sessions_managed"] as? Bool, false)
			XCTAssertEqual(native["live_group_members"] as? [Int], [])
			XCTAssertEqual(summary["pid"] as? Int, worker)
			let authority = try XCTUnwrap(packet["authority"] as? [String: Any])
			XCTAssertEqual(authority["installation"] as? Bool, false)
			XCTAssertEqual(authority["remapping"] as? Bool, false)
			XCTAssertEqual(authority["physical_input"] as? String, "unexecuted")
			XCTAssertEqual(authority["native_metadata"] as? String, "actual")
			XCTAssertEqual(authority["native_json_files"] as? String, "actual")
			XCTAssertEqual(authority["logging"] as? String, "modeled no-op")
			XCTAssertEqual(packet["record_relative"] as? String, "owned-configuration/native-result.json")
			let path = root.appendingPathComponent("owned-configuration/native-result.json")
			let raw = try Self.readOwnedConfigurationArtifact(path)
			XCTAssertEqual(raw.count, packet["record_bytes"] as? Int)
			let sha = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
			XCTAssertEqual(sha, packet["record_sha256"] as? String)
			let actual = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
			XCTAssertEqual(actual["nonce"] as? String, summary["nonce"] as? String)
			XCTAssertEqual(actual["pid"] as? Int, worker)
			XCTAssertEqual((actual["variants"] as? [[String: Any]])?.count, 8)
			let text = try XCTUnwrap(String(data: raw, encoding: .utf8))
			let artifact = try Self.persistLegacyCleanupReceipt(text, parent: parent,
				name: "legacy-cleanup-receipt-" + UUID().uuidString + ".json")
			print("HS274 owned configuration receipt file=" + artifact.name
				+ " bytes=" + String(artifact.bytes) + " variants=8 physical=unexecuted installation=false\n", terminator: "")
		}
	}

	private enum OwnedConfigurationArtifactError: Error {
		case ownership, readback
	}

	/// No-follow bounded owner reads preserve the full graph after actual Guardian ACK.
	private static func readOwnedConfigurationArtifact(_ path: URL) throws -> Data {
		guard path.resolvingSymlinksInPath() == path else { throw OwnedConfigurationArtifactError.ownership }
		let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
		guard descriptor >= 0 else { throw OwnedConfigurationArtifactError.ownership }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
		defer { try? handle.close() }
		var before = stat()
		guard fstat(descriptor, &before) == 0,
			before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_uid == geteuid(),
			before.st_mode & 0o7777 == 0o600, before.st_size > 0, before.st_size <= 16_777_216 else {
			throw OwnedConfigurationArtifactError.ownership
		}
		let raw = try handle.read(upToCount: Int(before.st_size + 1)) ?? Data()
		var after = stat(), named = stat()
		guard raw.count == Int(before.st_size), fstat(descriptor, &after) == 0, lstat(path.path, &named) == 0,
			before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
			before.st_mode == after.st_mode, before.st_uid == after.st_uid,
			after.st_dev == named.st_dev, after.st_ino == named.st_ino, after.st_size == named.st_size,
			after.st_mode == named.st_mode, after.st_uid == named.st_uid, path.resolvingSymlinksInPath() == path else {
			throw OwnedConfigurationArtifactError.readback
		}
		return raw
	}
}
