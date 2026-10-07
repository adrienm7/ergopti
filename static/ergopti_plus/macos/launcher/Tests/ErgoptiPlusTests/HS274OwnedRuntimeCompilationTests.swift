// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedRuntimeCompilationTests.swift
//
// Fixed four-target preparation is portable policy evidence. Actual unsigned
// compilation consumes only the actual reviewed complete parent/auth factory.

import CoreFoundation
import CryptoKit
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

	func testPortableCurrentOwnedProfileUsesPrivateActualSourceControls() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_following_profile_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertEqual(receipt.stdout,
					"PASS portable current owned source profile tests=17 failures=0 errors=0 skipped=0 native=unexecuted\n")
				XCTAssertTrue(receipt.stderr.contains("Ran 17 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}

	func testPortableProductCurrentnessCutsPreserveOriginalRefusals() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_product_cut_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 6 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}

	func testPortableFixedBuilderImageSizeKeepsOrdinarySourceBounds() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.appendingPathComponent("hs274_builder_image_size_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 5 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}

	func testPortableLexicalContainmentPreservesPublicPathSemantics() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_lexical_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 48 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}

	func testPortableLexicalSourceClosureRefusesHistoricalInputs() throws {
		let modes: [[String]] = [[], ["-O"]]
		try fixture { root in
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_lexical_closure_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 8 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
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
			XCTAssertEqual(baselineReceipt.status, 0, "Retired native baseline refusal code: "
				+ HS274RetiredBuildRefusal.code(baselineReceipt.stderr, producer: .native))
			XCTAssertTrue(baselineReceipt.stderr.isEmpty)
			if baselineReceipt.status != 0 {
				// The original invoker has already admitted its actual retired ACK.
				// This fixed SDK child observes only the retained phase metadata.
				let unsupported = #"{"authority":false,"kind":"baseline_phase_observations","last_recorded_phase":null,"native_verdict":"unchanged","rows":[],"schema":1,"status":"unsupported"}"# + "\n"
				do {
					let observation = try run(URL(fileURLWithPath: "/usr/bin/env"),
						["python3", source("hs274_native_build_observation.py").path,
							baseline.path, String(baselineReceipt.status)], root: root)
					if observation.status == 0, observation.stderr.isEmpty,
						let admitted = admittedBaselineSummary(observation.stdout) {
						print(admitted, terminator: "")
					} else { print(unsupported, terminator: "") }
				} catch { print(unsupported, terminator: "") }
			}
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
			XCTAssertEqual(compiled.status, 0, "Retired owned compilation refusal code: "
				+ HS274RetiredBuildRefusal.code(compiled.stderr, producer: .owned))
			XCTAssertTrue(compiled.stderr.isEmpty)
			// This separate partial calibration uses the untouched source retained
			// by the already retired four-target worker, including its failure path.
			// It cannot qualify the original four-target result or transfer ownership.
			let coreConstructor = root.appendingPathComponent("core-constructor")
			try FileManager.default.createDirectory(at: coreConstructor, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let coreReceipt = try runCoreConstructorCompilation([
				"--owner", coreConstructor.path, "--pristine", owned.appendingPathComponent("pristine").path,
				"--budget", "300"], root: root)
			XCTAssertEqual(coreReceipt.status, 0, "Separate Core constructor calibration refused: " + coreReceipt.stderr)
			XCTAssertTrue(coreReceipt.stderr.isEmpty)
			if coreReceipt.status == 0 {
				let partial = try JSONSerialization.jsonObject(with: Data(coreReceipt.stdout.utf8)) as? [String: Any]
				XCTAssertNotNil(partial)
				XCTAssertEqual(partial?["qualification"] as? String,
					"unsigned_actual_core_constructor_compilation_only")
				XCTAssertEqual(partial?["producer_sha256"] as? String,
					"c0c3f2d741711c199e4bea202e878ccdd5323b654b9de8fe99bb6437940a36e7")
				XCTAssertEqual(partial?["source_factory_sha256"] as? String,
					"854dc3ef556e2540d4a64e0d935610a2a2fe8c947e3f7fe315c1641ceaaedd7d")
				XCTAssertEqual(partial?["architectures"] as? [String], ["arm64", "x86_64"])
				XCTAssertEqual(partial?["core_relative_path"] as? String,
					"upstream/src/apps/CoreService/build/Release/ErgoptiPlus-Remap-Core.app")
				XCTAssertEqual(partial?["descriptor_retirement_ack"] as? Bool, true)
				for excluded in ["full_four_target_qualified", "signing_executed", "main_principal_qualified",
					"root_placement_qualified", "child_group_retirement_qualified", "installation_executed", "capture_executed"] {
					XCTAssertEqual(partial?[excluded] as? Bool, false)
				}
			}
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
			module.validate_current_owned_record(module.parse_json(row.data))
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
			guard products.status == 0, products.stdout ==
				"PASS observed native products=4 architectures=2; signing and activation unqualified\n",
				products.stderr.isEmpty else { return }
			let metadata = root.appendingPathComponent("team-metadata")
			try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let team = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", repository.appendingPathComponent("tools/build/remap_runtime_team_metadata.py").path,
					repository.path, owned.path, metadata.path], root: root)
			XCTAssertEqual(team.status, 0)
			XCTAssertEqual(team.stdout, "PASS native CF Team metadata cases=12; signing and authentication unqualified\n")
			XCTAssertTrue(team.stderr.isEmpty)
		}
	}

	private func admittedBaselineSummary(_ text: String) -> String? {
		let data = Data(text.utf8)
		guard data.count <= 2048, data.last == 10,
			let packet = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			Set(packet.keys) == Set(["schema", "kind", "status", "last_recorded_phase",
				"native_verdict", "authority", "rows"]),
			packet["kind"] as? String == "baseline_phase_observations",
			packet["native_verdict"] as? String == "unchanged",
			let authority = packet["authority"] as? NSNumber,
			CFGetTypeID(authority) == CFBooleanGetTypeID(), !authority.boolValue,
			let rows = packet["rows"] as? [[Any]],
			let status = packet["status"] as? String else { return nil }
		func integer(_ value: Any?, maximum: Int64) -> Int64? {
			guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
				Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]).contains(String(cString: number.objCType)),
				number.doubleValue >= 0, number.doubleValue <= Double(maximum),
				number.doubleValue == Double(number.int64Value) else { return nil }
			return number.int64Value
		}
		guard integer(packet["schema"], maximum: 1) == 1 else { return nil }
		if status == "unsupported" {
			guard rows.isEmpty, packet["last_recorded_phase"] is NSNull else { return nil }
		} else {
			guard status == "observed", rows.count == 19 else { return nil }
			var phases: [String] = []
			var last: String? = nil
			for row in rows {
				guard row.count == 4, let phase = row[0] as? String,
					let state = row[1] as? String,
					Set(["absent", "begun", "passed", "failed", "refused", "launch_refused"]).contains(state)
					else { return nil }
				phases.append(phase)
				if state != "absent" { last = phase }
				for value in row[2...3] {
					if let absence = value as? String {
						guard absence == "missing" || absence == "not-produced" else { return nil }
					} else if integer(value, maximum: 33_554_432) == nil { return nil }
				}
			}
			// The fixed source declaration owns the roster; its digest binds this
			// output boundary without another nineteen-name production list.
			let digest = SHA256.hash(data: Data(phases.joined(separator: "\n").utf8))
				.map { String(format: "%02x", $0) }.joined()
			guard digest == "1296884884f048d6f3f2d6a389b6e2904f8074a9340cb6a2204a64dd66ed43e7" else { return nil }
			if let last {
				guard packet["last_recorded_phase"] as? String == last else { return nil }
			} else if !(packet["last_recorded_phase"] is NSNull) { return nil }
		}
		guard let canonical = try? JSONSerialization.data(withJSONObject: packet,
			options: [.sortedKeys, .withoutEscapingSlashes]), canonical + Data([10]) == data else { return nil }
		return String(data: canonical + Data([10]), encoding: .utf8)
	}

	func testPortableRetiredBaselineObservationUsesClosedFilesystemControls() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_observation_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS portable baseline observation tests=25 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 25 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			let baseline = root.appendingPathComponent("observed-baseline")
			try FileManager.default.createDirectory(at: baseline, withIntermediateDirectories: false,
				attributes: [.posixPermissions: 0o700])
			let observation = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_observation.py").path, baseline.path, "124"], root: root)
			XCTAssertEqual(observation.status, 0)
			XCTAssertTrue(observation.stderr.isEmpty)
			XCTAssertEqual(admittedBaselineSummary(observation.stdout), observation.stdout)
			let unsupported = #"{"authority":false,"kind":"baseline_phase_observations","last_recorded_phase":null,"native_verdict":"unchanged","rows":[],"schema":1,"status":"unsupported"}"# + "\n"
			XCTAssertEqual(admittedBaselineSummary(unsupported), unsupported)
			XCTAssertNil(admittedBaselineSummary("{not JSON}\n"))
			XCTAssertNil(admittedBaselineSummary(unsupported.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1.0")))
			XCTAssertNil(admittedBaselineSummary(unsupported.replacingOccurrences(of: "unchanged", with: "SECRET/private/path")))
			XCTAssertNil(admittedBaselineSummary(unsupported.replacingOccurrences(of: "\"rows\":[]", with: "\"rows\":[],\"rows\":[]")))
			XCTAssertNil(admittedBaselineSummary(String(repeating: "x", count: 2049)))
		}
	}
}

extension HS274NativePolicyQualificationTests {
	func testPortablePinnedVHDSourceUsesTenOriginalControls() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path, "--group", "source", "--owner", root.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertEqual(receipt.stdout, "PASS portable VHD group=source tests=10; native=unexecuted\n")
				XCTAssertTrue(receipt.stderr.contains("Ran 10 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
	func testPortablePinnedVHDTimerRetainsGenuineCancellationControl() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path, "--group", "timer", "--owner", root.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertEqual(receipt.stdout, "PASS portable VHD group=timer tests=1; native=unexecuted\n")
				XCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
	func testPortablePinnedVHDCallbackRetainsGenuineDestructionControl() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path, "--group", "callback", "--owner", root.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertEqual(receipt.stdout, "PASS portable VHD group=callback tests=1; native=unexecuted\n")
				XCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
	func testPortablePinnedVHDLowerPeerUsesGenuineComposedHeaders() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path, "--group", "lower", "--owner", root.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertEqual(receipt.stdout, "PASS portable VHD group=lower tests=1; native=unexecuted\n")
				XCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
	func testPortablePinnedVHDFixtureRefusesPhysicalInputTampering() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_vhd_fixture_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 21 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
}

extension HS274NativePolicyQualificationTests {
	func testPortableProductDifferenceAxesPreserveOriginalRefusals() throws {
		try fixture { root in
			let modes: [[String]] = [[], ["-O"]]
			for mode in modes {
				let script = source("hs274_native_build.py").deletingLastPathComponent()
					.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_product_axes_test.py")
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + mode + [script.path], root: root)
				XCTAssertEqual(receipt.status, 0)
				XCTAssertTrue(receipt.stdout.isEmpty)
				XCTAssertTrue(receipt.stderr.contains("Ran 10 tests in "))
				XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
			}
		}
	}
}

extension HS274NativePolicyQualificationTests {
	func testPortableInitializerDeliveryRetainsAllTwentyTwoFrozenControls() throws {
		try fixture { root in
			let cases: [String] = ["healthy", "unbound", "bytes_mismatch", "empty", "noncanonical", "error", "unknown_response", "duplicate", "retired", "changed_peer", "timer", "queue_refusal", "callback", "foreign_debt", "timer_observation", "empty_refusal", "reserved_kind", "outbound_wire", "pending_cancel", "completion_reentry", "peer_reentry", "completion_exception"]
			let modes: [[String]] = [[], ["-O"]]
			for selected in cases {
				for mode in modes {
					let script = source("hs274_native_build.py").deletingLastPathComponent()
						.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_initializer_test.py")
					let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
						["python3"] + mode + [script.path, "--case", selected, "--owner", root.path], root: root)
					XCTAssertEqual(receipt.status, 0)
					XCTAssertTrue(receipt.stdout.isEmpty)
					XCTAssertTrue(receipt.stderr.contains("Ran 1 test in "))
					XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
				}
			}
		}
	}
}
