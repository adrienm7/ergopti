// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedRuntimeCompilationTests.swift
//
// Fixed four-target preparation is portable policy evidence. Actual unsigned
// compilation consumes only the actual reviewed complete parent/auth factory.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableFourTargetPreparationUsesActualFilesystemAndClosedControls() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_build_test.py")
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable four-target preparation tests=41 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 41 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualFreshBaselineRetiresBeforeSeparateOwnedFourTargetCompilation() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_native_build.py").deletingLastPathComponent()
			let repository = diagnostics.deletingLastPathComponent().deletingLastPathComponent()
			let ownedScript = repository.appendingPathComponent("tools/build/remap_runtime_build.py")
			let baseline = root.appendingPathComponent("baseline")
			let owned = root.appendingPathComponent("owned")
			try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			// Readiness checks fixed code dependencies only. It supplies no source
			// or compilation authority and cannot substitute for either build.
			let ready = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", ownedScript.path, repository.path, owned.path, "--ready", "--budget", "300"], root: root)
			XCTAssertEqual(ready.status, 0, "Reviewed owned parent/auth source composition is not released")
			guard ready.status == 0 else { return }
			let witness = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_promoted_source_witness.py").path, repository.path], root: root)
			XCTAssertEqual(witness.status, 0)
			XCTAssertEqual(witness.stdout,
				"PASS generated promoted source witness files=25; compilation and installation unexecuted\n")
			XCTAssertTrue(witness.stderr.isEmpty)
			guard witness.status == 0, witness.stderr.isEmpty else { return }
			// The original invoker returns only after actual guardian, worker,
			// captures and native phase debt have genuinely completed and retired.
			let baselineReceipt = try runSourceCompilation([diagnostics.path, baseline.path, "--budget", "300"], root: root)
			XCTAssertEqual(baselineReceipt.status, 0)
			XCTAssertTrue(baselineReceipt.stderr.isEmpty)
			guard baselineReceipt.status == 0, baselineReceipt.stderr.isEmpty else { return }
			let check = #"""
			import importlib.util
			from pathlib import Path
			import sys

			path = Path(sys.argv[1])
			spec = importlib.util.spec_from_file_location("four_target_baseline_evidence", path)
			module = importlib.util.module_from_spec(spec)
			sys.modules[spec.name] = module
			spec.loader.exec_module(module)
			module.baseline_output(0, sys.argv[2], "")
			print("PASS actual baseline output phases=19 candidate=none")
			"""#
			let baselineEvidence = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", check, ownedScript.path, baselineReceipt.stdout], root: root)
			XCTAssertEqual(baselineEvidence.status, 0)
			XCTAssertEqual(baselineEvidence.stdout, "PASS actual baseline output phases=19 candidate=none\n")
			XCTAssertTrue(baselineEvidence.stderr.isEmpty)
			guard baselineEvidence.status == 0, baselineEvidence.stderr.isEmpty else { return }
			// A second fresh acquisition retains the pristine input separately from
			// its full owned stage. Metadata never replaces a native invocation.
			let compiled = try runOwnedRuntimeCompilation([repository.path, owned.path, "--compile-owned", "--budget", "300"], root: root)
			XCTAssertEqual(compiled.status, 0)
			XCTAssertTrue(compiled.stderr.isEmpty)
			guard compiled.status == 0, compiled.stderr.isEmpty else { return }
			let ownedCheck = #"""
			import importlib.util
			from pathlib import Path
			import sys
			path=Path(sys.argv[1])
			spec=importlib.util.spec_from_file_location("actual_owned_result",path)
			module=importlib.util.module_from_spec(spec)
			sys.modules[spec.name]=module
			spec.loader.exec_module(module)
			module.owned_output(0,sys.argv[3],"")
			owner=Path(sys.argv[2])
			row=module._ordinary(owner/"owned-native-build-result.json",owner,module.BASE.MAX_INPUT_BYTES)
			module.validate_owned_record(module.parse_json(row.data))
			print("PASS closed actual owned result; signing and activation unqualified")
			"""#
			let ownedEvidence = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", ownedCheck, ownedScript.path, owned.path, compiled.stdout], root: root)
			XCTAssertEqual(ownedEvidence.status, 0)
			XCTAssertEqual(ownedEvidence.stdout, "PASS closed actual owned result; signing and activation unqualified\n")
			XCTAssertTrue(ownedEvidence.stderr.isEmpty)
			guard ownedEvidence.status == 0, ownedEvidence.stderr.isEmpty else { return }
			let observed = root.appendingPathComponent("product-observation")
			try FileManager.default.createDirectory(at: observed, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let products = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", ownedScript.path, repository.path, observed.path,
					"--observe-products", owned.appendingPathComponent("upstream").path], root: root)
			XCTAssertEqual(products.status, 0)
			XCTAssertEqual(products.stdout,
				"PASS observed native products=4 architectures=2; signing and activation unqualified\n")
			XCTAssertTrue(products.stderr.isEmpty)
		}
	}
}
