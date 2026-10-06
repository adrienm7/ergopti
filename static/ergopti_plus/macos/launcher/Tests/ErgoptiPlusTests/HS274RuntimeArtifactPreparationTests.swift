// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274RuntimeArtifactPreparationTests.swift
//
// Ordinary filesystem custody with modeled compiler/factory endpoints only.
// This method does not qualify genuine native products, signing or installation.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableRetainedRuntimeSnapshotUsesActualFilesystemAndModeledCompiler() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_artifact_test.py")
			// The existing SDK Guardian retains its literal 30/35/10 bounds.
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable retained runtime snapshot tests=40 failures=0 errors=0 skipped=0 native=unexecuted\n")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{40}\n-{70}\nRan 40 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}
}
