// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274FullSourceCompilationTests.swift
//
// Qualifies actual unsigned pinned Core-Service and CLI compilation. It never
// installs a driver, activates a runtime, or proves physical capture authority.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testActualPythonControllerPreservesIndependentFilesystemAndDeadlinePolicies() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS independent native build controller tests=29 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 29 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualPinnedCoreServiceAndCLICompileWithinOwnedCalibration() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			var arguments = [source("hs274_raw_patch.py").deletingLastPathComponent().path,
				root.path, "--budget", "300"]
			// This prerequisite requires the reviewed complete inactive union.
			// Compiling current Source-1 inputs cannot qualify the Source-2 candidate.
			let seal = source("fixtures/hs274-native-build-candidate/manifest.json")
			let sealPresent = FileManager.default.fileExists(atPath: seal.path)
				|| (try? FileManager.default.destinationOfSymbolicLink(atPath: seal.path)) != nil
			XCTAssertTrue(sealPresent, "Full candidate compilation requires its reviewed inactive seal")
			guard sealPresent else { return }
			arguments += ["--candidate-seal", seal.path]
			let receipt = try runSourceCompilation(arguments, root: root)
			XCTAssertEqual(receipt.status, 0,
				"Full native compilation refused; retained phase evidence at " + root.path
				+ "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let lines = receipt.stdout.split(separator: "\n", omittingEmptySubsequences: false)
			XCTAssertEqual(lines.count, 21)
			XCTAssertEqual(lines.first,
				"PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted")
			let expected = ["xcode_version", "xcodegen_version", "sdk_path", "acquisition", "checkout",
				"submodules", "identity_upstream", "identity_cpm", "identity_vhd", "source_clean", "version",
				"instrumentation", "duktape_generate", "duktape_build", "core_generate", "core_build",
				"cli_generate", "cli_build"]
			guard lines.count == 21 else { return }
			for (index, phase) in expected.enumerated() {
				let prefix = "PHASE " + phase + " seconds="
				XCTAssertTrue(lines[index + 1].hasPrefix(prefix))
				let duration = try XCTUnwrap(Double(lines[index + 1].dropFirst(prefix.count)))
				XCTAssertTrue(duration.isFinite && duration >= 0 && duration <= 300)
			}
			do {
				struct CandidateMarker: Decodable {
					let patch_sha256: String
				}
				// This informational comparison follows the worker's successful
				// strict seal admission; it grants no ownership or capture authority.
				let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: seal.path)[.size] as? NSNumber)
				XCTAssertLessThanOrEqual(size.int64Value, 65_536)
				guard size.int64Value <= 65_536 else { return }
				let expectedCandidate = try JSONDecoder().decode(CandidateMarker.self,
					from: Data(contentsOf: seal)).patch_sha256
				let marker = String(lines[19])
				XCTAssertEqual(marker, "CANDIDATE " + expectedCandidate)
				let digest = marker.dropFirst("CANDIDATE ".count)
				XCTAssertEqual(digest.count, 64)
				XCTAssertTrue(digest.allSatisfy { "0123456789abcdef".contains($0) })
			}
			XCTAssertEqual(lines[20], "")
			for relative in ["upstream/vendor/duktape-src/build/Release/libduktape.a",
				"upstream/src/apps/CoreService/build/Release/Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service",
				"upstream/src/bin/cli/build/Release/karabiner_cli", "native-build-result.json"] {
				let file = root.appendingPathComponent(relative)
				let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
				XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
				let size = try XCTUnwrap(attributes[.size] as? NSNumber)
				XCTAssertGreaterThan(size.int64Value, 0)
			}
			// Preserve measured phase durations and the exact candidate identity in
			// the CI transcript even when successful private fixtures are retired.
			print(receipt.stdout, terminator: "")
		}
	}
}
