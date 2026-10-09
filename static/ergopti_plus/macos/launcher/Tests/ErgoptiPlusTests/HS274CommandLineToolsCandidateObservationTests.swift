// TEST ONLY: fixed CLT metadata observation, with no toolchain or root authority.

import CoreFoundation
import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	/// Uses the original SDK Guardian 30/35/10, including when CLT is absent.
	func testActualCommandLineToolsCandidateMetadataObservation() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", source("root_clt_candidate_observation.py").path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertTrue(receipt.stderr.isEmpty)
			let data = try XCTUnwrap(receipt.stdout.data(using: .utf8))
			XCTAssertLessThanOrEqual(data.count, 8192)
			let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
			XCTAssertEqual(Set(report.keys), Set(["schema", "kind", "platform", "authority", "root_admission",
				"toolchain_selected", "native_verdict", "rows"]))
			XCTAssertEqual(report["schema"] as? Int, 1)
			XCTAssertEqual(report["kind"] as? String, "clt_candidate_metadata_observation")
			XCTAssertEqual(report["platform"] as? String, "darwin")
			XCTAssertEqual(report["native_verdict"] as? String, "unchanged")
			for flag in ["authority", "root_admission", "toolchain_selected"] {
				let number = try XCTUnwrap(report[flag] as? NSNumber)
				XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID())
				XCTAssertFalse(number.boolValue)
			}
			let rows = try XCTUnwrap(report["rows"] as? [[String: Any]])
			XCTAssertGreaterThanOrEqual(rows.count, 8)
			XCTAssertLessThanOrEqual(rows.count, 32)
			let roles = Set(["xcrun", "xcode_select", "clt", "clt_usr", "clt_bin", "compiler",
				"sdk_directory", "sdk", "compiler_target", "sdk_target"])
			XCTAssertTrue(Set(["xcrun", "xcode_select", "clt", "clt_usr", "clt_bin", "compiler",
				"sdk_directory", "sdk"]).isSubset(of: Set(rows.compactMap { $0["role"] as? String })))
			for row in rows {
				XCTAssertEqual(Set(row.keys), Set(["role", "version", "hop", "state", "kind", "uid", "mode",
					"executable", "alias", "current"]))
				XCTAssertTrue(roles.contains(try XCTUnwrap(row["role"] as? String)))
				let version = try XCTUnwrap(row["version"] as? String)
				XCTAssertNotNil(version.range(of: "^(default|[0-9]{1,3}(\\.[0-9]{1,3}){0,3})$", options: .regularExpression))
				let state = try XCTUnwrap(row["state"] as? String)
				XCTAssertTrue(["present", "missing", "blocked"].contains(state))
				let kind = try XCTUnwrap(row["kind"] as? String)
				XCTAssertTrue(["regular", "directory", "symlink", "missing", "blocked"].contains(kind))
				XCTAssertTrue(["none", "within_clt"].contains(try XCTUnwrap(row["alias"] as? String)))
				let hop = try XCTUnwrap(row["hop"] as? NSNumber)
				XCTAssertNotEqual(CFGetTypeID(hop), CFBooleanGetTypeID())
				XCTAssertEqual(hop.doubleValue, Double(hop.intValue))
				XCTAssertGreaterThanOrEqual(hop.intValue, 0)
				XCTAssertLessThanOrEqual(hop.intValue, 8)
				for field in ["current", "executable"] {
					let number = try XCTUnwrap(row[field] as? NSNumber)
					XCTAssertEqual(CFGetTypeID(number), CFBooleanGetTypeID())
					if field == "current" { XCTAssertTrue(number.boolValue) }
				}
				if state == "present" {
					XCTAssertTrue(["regular", "directory", "symlink"].contains(kind))
					for (field, maximum) in [("uid", 4_294_967_295.0), ("mode", 4095.0)] {
						let number = try XCTUnwrap(row[field] as? NSNumber)
						XCTAssertNotEqual(CFGetTypeID(number), CFBooleanGetTypeID())
						XCTAssertEqual(number.doubleValue, Double(number.int64Value))
						XCTAssertGreaterThanOrEqual(number.doubleValue, 0)
						XCTAssertLessThanOrEqual(number.doubleValue, maximum)
					}
				} else {
					XCTAssertEqual(kind, state)
					XCTAssertTrue(row["uid"] is NSNull)
					XCTAssertTrue(row["mode"] is NSNull)
					XCTAssertEqual(row["executable"] as? Bool, false)
				}
			}
			// Successful fixtures retire private captures; keep the bounded closed observation in the CI log.
			FileHandle.standardError.write(Data(("ERGOPTI_CLT_CANDIDATE_METADATA "
				+ receipt.stdout.trimmingCharacters(in: .newlines) + "\n").utf8))
		}
	}

	func testPortableCommandLineToolsCandidateMetadataControls() throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			for flags in [[], ["-O"]] {
				let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
					["python3"] + flags + [source("root_clt_candidate_observation_test.py").path], root: root)
				XCTAssertEqual(receipt.status, 0)
				let data = try XCTUnwrap(receipt.stdout.data(using: .utf8))
				let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
				XCTAssertEqual(Set(result.keys), Set(["schema", "tests", "executed", "skipped", "failures", "errors", "native"]))
				XCTAssertEqual(result["schema"] as? Int, 1)
				XCTAssertEqual(result["tests"] as? Int, 20)
				XCTAssertEqual(result["executed"] as? Int, 20)
				XCTAssertEqual(result["skipped"] as? Int, 0)
				XCTAssertEqual(result["failures"] as? Int, 0)
				XCTAssertEqual(result["errors"] as? Int, 0)
				XCTAssertEqual(result["native"] as? String, "unexecuted")
			}
		}
	}
}
