// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274RetiredBuildRefusalTests.swift
// Closed diagnostic codes from genuinely retired children; no raw payload is forwarded.

import Foundation
import XCTest

enum HS274RetiredBuildRefusal {
	enum Producer { case native, owned }

	// Fixed literals from the current native producer and owned/factory refusals.
	// New or malformed diagnostics stay unclassified until explicitly reviewed.
	private static let nativeCodes: Set<String> = [
		"candidate_path",
		"duplicate_candidate_path",
		"duplicate_key",
		"invalid_budget",
		"invalid_digest",
		"invalid_seal",
		"owner_identity",
		"owner_mode",
		"owner_path",
		"patch_hash",
		"patch_rejected",
		"patch_scope",
		"phase_deadline",
		"phase_failed",
		"phase_log_limit",
		"postimage_hash",
		"preimage_hash",
		"source_identity",
		"tool_unavailable",
		"unsafe_path",
		"xcodegen_archive",
		"xcodegen_binary",
		"xcodegen_digest",
		"xcodegen_limit",
		"xcodegen_member",
		"xcodegen_metadata",
		"xcodegen_size",
		"xcodegen_transport",
	]
	private static let ownedCodes: Set<String> = [
		"baseline_refused",
		"candidate_path",
		"deadline",
		"dependency_changed",
		"dependency_unreleased",
		"duplicate_candidate_path",
		"duplicate_key",
		"invalid_budget",
		"invalid_digest",
		"invalid_seal",
		"inventory",
		"owned_receipt_refused",
		"owner_identity",
		"owner_mode",
		"owner_path",
		"patch_hash",
		"patch_rejected",
		"patch_scope",
		"phase_deadline",
		"phase_failed",
		"phase_log_limit",
		"pin",
		"postimage_hash",
		"preimage",
		"preimage_hash",
		"product_architecture",
		"product_identity",
		"source_changed",
		"source_controls_refused",
		"source_identity",
		"tool_unavailable",
		"unsafe_path",
		"xcodegen_archive",
		"xcodegen_binary",
		"xcodegen_digest",
		"xcodegen_limit",
		"xcodegen_member",
		"xcodegen_metadata",
		"xcodegen_size",
		"xcodegen_transport",
	]

	static func code(_ stderr: String, producer: Producer) -> String {
		guard !stderr.isEmpty, stderr.utf8.count <= 2048 else { return "unclassified" }
		let bytes = Array(stderr.utf8)
		guard bytes.last == 10,
			bytes.dropLast().allSatisfy({ $0 >= 32 && $0 <= 126 }) else { return "unclassified" }
		let line = String(stderr.dropLast())
		switch producer {
		case .native:
			let prefix = "Native compilation qualification refused: "
			guard line.hasPrefix(prefix) else { return "unclassified" }
			let body = String(line.dropFirst(prefix.count))
			guard let separator = body.range(of: "; "), separator.upperBound < body.endIndex else {
				return "unclassified"
			}
			let candidate = String(body[..<separator.lowerBound])
			return nativeCodes.contains(candidate) ? candidate : "unclassified"
		case .owned:
			let prefix = "Owned runtime compilation refused: "
			guard line.hasPrefix(prefix) else { return "unclassified" }
			let candidate = String(line.dropFirst(prefix.count))
			return ownedCodes.contains(candidate) ? candidate : "unclassified"
		}
	}
}

extension HS274NativePolicyQualificationTests {

	func testRetiredBuildRefusalDiagnosticCodesRemainClosedAndPayloadFree() {
		// Handwritten expectations frozen before the parser; these are software controls.
		let cases: [(String, HS274RetiredBuildRefusal.Producer, String, String)] = [
			("native_phase", .native, "Native compilation qualification refused: phase_failed; native child failed\n", "phase_failed"),
			("native_transport", .native, "Native compilation qualification refused: xcodegen_transport; HTTPS acquisition failed\n", "xcodegen_transport"),
			("native_private_payload_discarded", .native, "Native compilation qualification refused: owner_path; /private/SECRET https://secret.invalid\n", "owner_path"),
			("owned_policy", .owned, "Owned runtime compilation refused: source_controls_refused\n", "source_controls_refused"),
			("owned_phase", .owned, "Owned runtime compilation refused: phase_failed\n", "phase_failed"),
			("owned_factory", .owned, "Owned runtime compilation refused: dependency_changed\n", "dependency_changed"),
			("native_foreign_family", .native, "Owned runtime compilation refused: phase_failed\n", "unclassified"),
			("owned_foreign_family", .owned, "Native compilation qualification refused: phase_failed; failure\n", "unclassified"),
			("unknown_native", .native, "Native compilation qualification refused: secret_code; failure\n", "unclassified"),
			("unknown_owned", .owned, "Owned runtime compilation refused: secret_code\n", "unclassified"),
			("multiple_records", .owned, "Owned runtime compilation refused: phase_failed\nOwned runtime compilation refused: source_controls_refused\n", "unclassified"),
			("traceback", .native, "Traceback: /private/SECRET\nNative compilation qualification refused: phase_failed; failure\n", "unclassified"),
			("blank", .owned, "", "unclassified"),
			("no_final_lf", .owned, "Owned runtime compilation refused: phase_failed", "unclassified"),
			("owned_reason_forbidden", .owned, "Owned runtime compilation refused: phase_failed; /private/SECRET\n", "unclassified"),
			("native_missing_reason", .native, "Native compilation qualification refused: phase_failed; \n", "unclassified"),
			("carriage_return", .native, "Native compilation qualification refused: phase_failed; failure\r\n", "unclassified"),
			("nul", .native, "Native compilation qualification refused: phase_failed; failure\u{0000}\n", "unclassified"),
			("tab", .native, "Native compilation qualification refused: phase_failed; fail\ture\n", "unclassified"),
			("oversized", .native, "Native compilation qualification refused: phase_failed; "
				+ String(repeating: "x", count: 2048) + "\n", "unclassified"),
			("unicode_payload", .native, "Native compilation qualification refused: phase_failed; secreté\n", "unclassified"),
			("case_mismatch", .owned, "Owned runtime compilation refused: PHASE_FAILED\n", "unclassified"),
			("leading_whitespace", .owned, " Owned runtime compilation refused: phase_failed\n", "unclassified"),
			("extra_final_lf", .owned, "Owned runtime compilation refused: phase_failed\n\n", "unclassified"),
		]
		XCTAssertEqual(cases.count, 24)
		for (id, producer, stderr, expected) in cases {
			XCTAssertEqual(HS274RetiredBuildRefusal.code(stderr, producer: producer), expected, id)
		}
	}
}
