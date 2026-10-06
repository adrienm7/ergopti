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
				"PASS independent native build controller tests=53 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 53 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualPythonTransportDiagnosticsPreserveTypedRefusalsAndPrivacy() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_native_build_transport_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS independent native transport diagnostics tests=29 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 29 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualPythonPromotedWitnessPreservesIndependentSourceContract() throws {
		try fixture { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("hs274_promoted_source_witness_test.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS independent promoted witness controls tests=13 failures=0 errors=0 skipped=0\n")
			XCTAssertTrue(receipt.stderr.contains("Ran 13 tests in "))
			XCTAssertTrue(receipt.stderr.hasSuffix("\nOK\n"))
		}
	}

	func testActualPinnedCoreServiceAndCLICompileWithinOwnedCalibration() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let diagnostics = source("hs274_raw_patch.py").deletingLastPathComponent()
			let arguments = [diagnostics.path, root.path, "--budget", "300"]
			// The reviewed producer is now the actual source. Retain the original seal
			// as its exact postimage witness; applying its old overlay again must refuse.
			let seal = source("fixtures/hs274-promoted-source-witness/manifest.json")
			let sealPresent = FileManager.default.fileExists(atPath: seal.path)
				|| (try? FileManager.default.destinationOfSymbolicLink(atPath: seal.path)) != nil
			XCTAssertTrue(sealPresent, "Full candidate compilation requires its reviewed inactive seal")
			guard sealPresent else { return }
			let checkPromotedSources = #"""
			"""Verify reviewed promoted sources and actual staged inputs without applying an overlay."""

			import importlib.util
			import json
			from pathlib import Path
			import sys


			def load(name, path):
			    spec = importlib.util.spec_from_file_location(name, path)
			    module = importlib.util.module_from_spec(spec)
			    spec.loader.exec_module(module)
			    return module


			def main(arguments):
			    diagnostics, seal_path = map(Path, arguments[:2])
			    subject = load("promoted_native_controller", diagnostics / "hs274_native_build.py")
			    try:
			        seal = subject.load_candidate_seal(seal_path)
			        subject.require(
			            len(seal["files"]) == 25, "source_identity", "Reviewed producer inventory changed"
			        )
			        for row in seal["files"]:
			            subject.require(
			                subject.digest(subject.read_regular(diagnostics / row["path"]))
			                == row["candidate_sha256"],
			                "source_identity",
			                "Actual promoted source differs from its reviewed postimage",
			            )
			        contract = load("promoted_baseline_contract", diagnostics / "hs274_baseline_contract.py")
			        subject.require(
			            contract.versions(diagnostics.parents[1])
			            == {"consumer": 2, "producer": 2, "cli": 2, "reader": (2, 2)},
			            "source_identity",
			            "Promoted baseline boundaries disagree",
			        )
			        stage = "source"
			        if len(arguments) == 3:
			            owner = subject.validate_owner_root(Path(arguments[2]))

			            def unique(pairs):
			                value = {}
			                for key, item in pairs:
			                    subject.require(
			                        key not in value, "duplicate_key", "Staged source receipt repeats a key"
			                    )
			                    value[key] = item
			                return value

			            receipt = json.loads(
			                subject.read_regular(owner / "inputs.json", 65_536), object_pairs_hook=unique
			            )
			            subject.require(
			                isinstance(receipt, dict)
			                and set(receipt) == {"schema", "inputs", "candidate", "architecture", "tools"}
			                and type(receipt["schema"]) is int
			                and receipt["schema"] == 1
			                and receipt["candidate"] is None,
			                "source_identity",
			                "Promoted compilation may not reapply an inactive candidate overlay",
			            )
			            inputs = receipt["inputs"]
			            subject.require(
			                isinstance(inputs, dict) and set(inputs) == {"files"},
			                "source_identity",
			                "Staged source inventory is malformed",
			            )
			            rows = inputs["files"]
			            subject.require(
			                isinstance(rows, list) and 25 <= len(rows) <= 128,
			                "source_identity",
			                "Staged source inventory is incomplete or unbounded",
			            )
			            observed = {}
			            for row in rows:
			                subject.require(
			                    isinstance(row, dict)
			                    and set(row) == {"path", "sha256"}
			                    and subject.candidate_path(row["path"])
			                    and subject.valid_digest(row["sha256"]),
			                    "source_identity",
			                    "Staged source row is malformed",
			                )
			                subject.require(
			                    row["path"] not in observed, "duplicate_key", "Staged source repeats a path"
			                )
			                observed[row["path"]] = row["sha256"]
			            subject.require(
			                all(observed.get(row["path"]) == row["candidate_sha256"] for row in seal["files"]),
			                "source_identity",
			                "Actual staged inputs differ from reviewed promoted sources",
			            )
			            staged = subject.validate_owner_root(owner / "diagnostics")
			            for row in seal["files"]:
			                subject.require(
			                    subject.digest(subject.read_regular(staged / row["path"]))
			                    == row["candidate_sha256"],
			                    "source_identity",
			                    "Actual staged source differs from its reviewed postimage",
			                )
			            stage = "staged"
			        print("PASS promoted native producer inputs files=25 baseline=2 stage=" + stage)
			        return 0
			    except subject.NativeBuildError as failure:
			        print("Promoted source qualification refused: " + failure.code, file=sys.stderr)
			        return 1
			    except (OSError, ValueError, RuntimeError, KeyError, TypeError):
			        print("Promoted source qualification refused: source_identity", file=sys.stderr)
			        return 1


			if __name__ == "__main__":
			    raise SystemExit(main(sys.argv[1:]))
			"""#
			let witnessArguments = ["python3", source("hs274_promoted_source_witness.py").path,
				diagnostics.deletingLastPathComponent().deletingLastPathComponent().path]
			let witnessExpected = "PASS generated promoted source witness files=25; compilation and installation unexecuted\n"
			let sourceWitness = try run(URL(fileURLWithPath: "/usr/bin/env"), witnessArguments, root: root)
			XCTAssertEqual(sourceWitness.status, 0)
			XCTAssertEqual(sourceWitness.stdout, witnessExpected)
			XCTAssertTrue(sourceWitness.stderr.isEmpty)
			guard sourceWitness.status == 0 else { return }
			let actualInputs = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", checkPromotedSources, diagnostics.path, seal.path], root: root)
			XCTAssertEqual(actualInputs.status, 0)
			XCTAssertEqual(actualInputs.stdout,
				"PASS promoted native producer inputs files=25 baseline=2 stage=source\n")
			XCTAssertTrue(actualInputs.stderr.isEmpty)
			guard actualInputs.status == 0 else { return }
			let receipt = try runSourceCompilation(arguments, root: root)
			XCTAssertEqual(receipt.status, 0,
				"Full native compilation refused; retained phase evidence at " + root.path
				+ "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let lines = receipt.stdout.split(separator: "\n", omittingEmptySubsequences: false)
			XCTAssertEqual(lines.count, 22)
			XCTAssertEqual(lines.first,
				"PASS unsigned pinned Core-Service and CLI compilation; native capture and installation unexecuted")
			let expected = ["xcode_version", "xcodegen_acquisition", "xcodegen_version", "sdk_path", "acquisition", "checkout",
				"submodules", "identity_upstream", "identity_cpm", "identity_vhd", "source_clean", "version",
				"instrumentation", "duktape_generate", "duktape_build", "core_generate", "core_build",
				"cli_generate", "cli_build"]
			guard lines.count == 22 else { return }
			for (index, phase) in expected.enumerated() {
				let prefix = "PHASE " + phase + " seconds="
				XCTAssertTrue(lines[index + 1].hasPrefix(prefix))
				let duration = try XCTUnwrap(Double(lines[index + 1].dropFirst(prefix.count)))
				XCTAssertTrue(duration.isFinite && duration >= 0 && duration <= 300)
			}
			XCTAssertEqual(lines[20], "CANDIDATE none; actual diagnostic inputs compiled")
			let stagedWitness = try run(URL(fileURLWithPath: "/usr/bin/env"), witnessArguments, root: root)
			XCTAssertEqual(stagedWitness.status, 0)
			XCTAssertEqual(stagedWitness.stdout, witnessExpected)
			XCTAssertTrue(stagedWitness.stderr.isEmpty)
			guard stagedWitness.status == 0 else { return }
			let stagedInputs = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", "-c", checkPromotedSources, diagnostics.path, seal.path, root.path], root: root)
			XCTAssertEqual(stagedInputs.status, 0)
			XCTAssertEqual(stagedInputs.stdout,
				"PASS promoted native producer inputs files=25 baseline=2 stage=staged\n")
			XCTAssertTrue(stagedInputs.stderr.isEmpty)
			guard stagedInputs.status == 0 else { return }
			XCTAssertEqual(lines[21], "")
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
