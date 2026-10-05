// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274BuildFlagsTests.swift
//
// Exercises actual unsigned calibration command assembly; controlled products
// establish build policy only, never native compilation or capture authority.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testActualUnsignedCalibrationCommandsPreserveAllTargetsWithoutDebugMetadata() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_flags_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			let phases = ["xcode_version", "xcodegen_acquisition", "xcodegen_version", "sdk_path", "acquisition",
				"checkout", "submodules", "identity_upstream", "identity_cpm", "identity_vhd", "source_clean",
				"version", "instrumentation", "duktape_generate", "duktape_build", "core_generate", "core_build",
				"cli_generate", "cli_build"]
			let controlledReceipt = "PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted\n"
				+ phases.map { "PHASE " + $0 + " seconds=0.000\n" }.joined()
				+ "CANDIDATE none; actual diagnostic inputs compiled\n"
			XCTAssertEqual(receipt.stdout, String(repeating: controlledReceipt, count: 3))
			XCTAssertTrue(receipt.stderr.contains("Ran 3 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}
}
