// Confirmed-source guard qualification; owner scheduling remains modeled.
import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testLegacyConsentPortableReceiptAndSourceControls() throws {
		try fixture { root in
			let controller = source("macos_legacy_consent.py")
			let repository = controller.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path, "--portable"], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout,
				"PASS cleanup portable receipt controls tests=11 failures=0 errors=0 skipped=0\n"
				+ "PASS consent portable receipt/source controls tests=24 failures=0 errors=0 skipped=0 native=unexecuted\n")
			XCTAssertTrue(receipt.stderr.isEmpty)
		}
	}

	func testActualLegacyConsentSourceCohortFourCases() throws {
		try qualifyLegacyConsentCohort("source", expected: [
			"confirmed_remove", "confirmed_noop", "confirmed_raw_changed_before_read", "owner_stale_before_read",
		])
	}

	func testActualLegacyConsentOwnerCohortFourCases() throws {
		try qualifyLegacyConsentCohort("owner", expected: [
			"owner_stale_after_read", "owner_stale_before_backup", "owner_stale_after_backup", "owner_callback_raises",
		])
	}

	func testActualLegacyConsentRefusalCohortFourCases() throws {
		try qualifyLegacyConsentCohort("refusal", expected: [
			"owner_callback_nontrue", "confirmed_invalid_json", "confirmed_absent_destination", "confirmed_destination_changed_after_backup",
		])
	}

	/// Every fixed cohort owns a separate SDK30/35/10 child. Aggregate qualification
	/// requires all three discovered native methods, never a passing subset.
	private func qualifyLegacyConsentCohort(_ cohort: String, expected: [String]) throws {
		let parent = try compilationEvidenceParent()
		try fixture(parent: parent) { root in
			let controller = source("macos_legacy_consent.py")
			let repository = controller.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"),
				["python3", controller.path, "--repo", repository.path, "--root", root.path, "--cohort", cohort], root: root)
			XCTAssertEqual(receipt.status, 0,
				"Actual confirmed-source cleanup refused within unchanged SDK30/35/10; cohort=" + cohort
				+ "; evidence=" + root.path + "; " + String(reflecting: String(receipt.stderr.prefix(4096))))
			guard receipt.status == 0 else { return }
			XCTAssertTrue(receipt.stderr.isEmpty)
			let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(receipt.stdout.utf8)) as? [String: Any])
			XCTAssertEqual(packet["status"] as? String, "ok")
			XCTAssertEqual(packet["qualification"] as? String, "actual production legacy consent guard private files")
			XCTAssertEqual(packet["cohort"] as? String, cohort)
			XCTAssertEqual(packet["controller_budget_seconds"] as? Int, 25)
			let elapsed = try XCTUnwrap(packet["observation_retirement_seconds"] as? Double)
			XCTAssertTrue(elapsed.isFinite && elapsed >= 0 && elapsed < 25)
			let inventory = [
				"confirmed_remove", "confirmed_noop", "confirmed_raw_changed_before_read", "owner_stale_before_read",
				"owner_stale_after_read", "owner_stale_before_backup", "owner_stale_after_backup", "owner_callback_raises",
				"owner_callback_nontrue", "confirmed_invalid_json", "confirmed_absent_destination", "confirmed_destination_changed_after_backup",
			]
			XCTAssertEqual(packet["full_inventory"] as? [String], inventory)
			let native = try XCTUnwrap(packet["native_result"] as? [String: Any])
			XCTAssertEqual(native["runtime"] as? String, "native Hammerspoon")
			XCTAssertEqual(native["cohort"] as? String, cohort)
			XCTAssertEqual(native["full_inventory"] as? [String], inventory)
			XCTAssertEqual(native["boundary_model"] as? String,
				"owner predicate and interleaving only; actual production JSON/files/backup/CAS")
			let cases = try XCTUnwrap(native["case_results"] as? [[String: Any]])
			XCTAssertEqual(cases.compactMap { $0["id"] as? String }, expected)
			XCTAssertEqual(cases.count, 4)
			XCTAssertTrue(cases.allSatisfy { ($0["passed"] as? Bool) == true })
			let observations = try XCTUnwrap(native["observations"] as? [[String: Any]])
			XCTAssertEqual(observations.compactMap { $0["id"] as? String }, expected)
			XCTAssertTrue(observations.allSatisfy {
				($0["boundary_reached"] as? Bool) == true && ($0["methods_restored"] as? Bool) == true
				&& ($0["owner_modeled"] as? Bool) == true
			})
			let authority = try XCTUnwrap(native["authority"] as? [String: Any])
			XCTAssertEqual(authority["user_backup"] as? String, "unavailable")
			XCTAssertEqual(authority["physical_input"] as? String, "unexecuted")
			XCTAssertEqual(authority["ui_confirmation"] as? String, "unexecuted")
			XCTAssertEqual(authority["lease_initialized"] as? Bool, false)
			XCTAssertEqual(authority["installation"] as? Bool, false)
			let artifact = try Self.persistLegacyCleanupReceipt(receipt.stdout, parent: parent,
				name: "legacy-cleanup-receipt-" + UUID().uuidString + ".json")
			print(Self.legacyCleanupReceiptLog(artifact.name, bytes: artifact.bytes, cases: cases.count), terminator: "")
		}
	}
}
