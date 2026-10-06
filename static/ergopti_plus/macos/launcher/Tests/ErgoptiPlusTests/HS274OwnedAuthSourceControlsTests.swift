// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedAuthSourceControlsTests.swift
//
// A separate finite source calibration retains a fresh pristine input and real
// C++ controls. Identity, UID, watch and MAIN leaves remain explicitly modeled.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableOwnedAuthSourceControlRefusalsHaveNoNativeAuthority() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_source_controls_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable owned AUTH source-controls tests=22 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 22 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualFreshPristineRetiresSourceControlsWithModeledNativeLeaves() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let repository = diagnostics.deletingLastPathComponent().deletingLastPathComponent()
			let script = repository.appendingPathComponent("tools/build/remap_runtime_build.py")
			let owner = root.appendingPathComponent("source-controls")
			try FileManager.default.createDirectory(at: owner, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			// The fixed helper owns its original sourceCalibration300/305/10.
			// Its genuine finish/retirement precedes any inspection of metadata.
			let controls = try runOwnedRuntimeCompilation(
				[repository.path, owner.path, "--source-controls", "--budget", "300"], root: root)
			XCTAssertEqual(controls.status, 0)
			XCTAssertEqual(controls.stdout,
				"PASS owned AUTH source controls=21 policy=26 hs274=22; native authentication unqualified\n")
			XCTAssertTrue(controls.stderr.isEmpty)
			guard controls.status == 0, controls.stderr.isEmpty else { return }
			let check = #"""
			import importlib.util
			from pathlib import Path
			import sys
			path=Path(sys.argv[1])
			spec=importlib.util.spec_from_file_location("owned_auth_source_evidence",path)
			module=importlib.util.module_from_spec(spec)
			sys.modules[spec.name]=module
			spec.loader.exec_module(module)
			module.source_controls_output(0,sys.argv[3],"")
			owner=Path(sys.argv[2])
			row=module._ordinary(owner/"owned-source-controls-result.json",owner,module.BASE.MAX_INPUT_BYTES)
			module.validate_source_controls_record(module.parse_json(row.data))
			print("PASS closed source controls21/26/22; native identity remains modeled")
			"""#
			let evidence = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", check, script.path, owner.path, controls.stdout], root: root)
			XCTAssertEqual(evidence.status, 0)
			XCTAssertEqual(evidence.stdout,
				"PASS closed source controls21/26/22; native identity remains modeled\n")
			XCTAssertTrue(evidence.stderr.isEmpty)
		}
	}
}
