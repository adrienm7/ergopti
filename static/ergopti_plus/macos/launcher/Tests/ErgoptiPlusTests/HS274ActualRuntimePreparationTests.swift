// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274ActualRuntimePreparationTests.swift
//
// Genuine opt-in preparation and separate read-only retired-output observation.
// Neither result qualifies signing, shipping, installation or runtime activation.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortablePreparedOutputObservationUsesActualFilesAndModeledMetadata() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_preparation_observation_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable prepared runtime observation tests=46 failures=0 errors=0 skipped=0 native=unexecuted\n")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{46}\n-{70}\nRan 46 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}

	func testActualOwnedCompilationPreparesCompleteUnsignedSnapshotBeforeRetirement() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let repository = diagnostics.deletingLastPathComponent().deletingLastPathComponent()
			let observer = repository.appendingPathComponent("tools/build/remap_runtime_preparation_observation.py")
			let owner = root.appendingPathComponent("owned-preparation")
			try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			// One genuine invocation keeps the original retained objects through
			// opt-in copying. The existing native Guardian stays at 300/305/10.
			let prepared = try runOwnedRuntimeCompilation(
				[repository.path, owner.path, "--prepare-owned", "--budget", "300"], root: root)
			let compilation = "PASS unsigned actual owned four-target compilation; signing and activation unqualified\n"
			let completed = compilation
				+ "PASS retained unsigned runtime snapshot; native shipping and installation unqualified\n"
			XCTAssertEqual(prepared.status, 0, "The genuine opt-in invocation did not complete preparation"
				+ "; retired owned refusal code: "
				+ HS274RetiredBuildRefusal.code(prepared.stderr, producer: .owned))
			if prepared.status == 2, prepared.stdout == compilation {
				// The original compile receipt survives this later refusal. A fixed
				// SDK observation confirms metadata only; the status assertion above
				// remains a failure of native snapshot preparation qualification.
				let refusal = try NSRegularExpression(pattern:
					#"^Unsigned runtime preparation refused: [a-z_]+\n$"#)
				let range = NSRange(prepared.stderr.startIndex..<prepared.stderr.endIndex, in: prepared.stderr)
				XCTAssertEqual(refusal.firstMatch(in: prepared.stderr, range: range)?.range, range)
				let metadata = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3", observer.path, repository.path, owner.path, "--compilation-only"], root: root)
				XCTAssertEqual(metadata.status, 0)
				XCTAssertEqual(metadata.stdout,
					"PASS observed completed compilation metadata; unsigned snapshot unqualified\n")
				XCTAssertTrue(metadata.stderr.isEmpty)
				print("Completed unsigned compilation; separate snapshot preparation refused; signing and installation unqualified")
				return
			}
			XCTAssertEqual(prepared.stdout, completed)
			XCTAssertTrue(prepared.stderr.isEmpty)
			guard prepared.status == 0, prepared.stdout == completed, prepared.stderr.isEmpty else { return }
			// This second child only reads current inventories/bytes/modes and
			// original closed metadata after real retirement. SDK stays 30/35/10.
			// It cannot reconstruct the consumed original handoff or sign/install.
			let observed = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", observer.path, repository.path, owner.path], root: root)
			XCTAssertEqual(observed.status, 0)
			XCTAssertEqual(observed.stdout,
				"PASS observed unsigned prepared runtime products=3; custody, signing and installation unqualified\n")
			XCTAssertTrue(observed.stderr.isEmpty)
		}
	}
}
