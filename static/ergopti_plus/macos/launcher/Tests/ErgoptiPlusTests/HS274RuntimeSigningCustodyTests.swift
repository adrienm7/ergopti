// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274RuntimeSigningCustodyTests.swift
//
// Ordinary file custody with explicitly modeled compiler and native commands.
// No certificate, native signature, shipping, installation or authentication is qualified.

import Foundation
import XCTest

extension HS274NativePolicyQualificationTests {

	func testPortableMachOCustodyWithModeledNativeEndpoints() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_macho_test.py")
			// Existing SDK Guardian retains its literal 30/35/10 bounds.
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path], root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout, "")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{24}\n-{70}\nRan 24 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}

	func testPortableSigningFirstCustodyWithModeledNativeEndpoints() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_signing_test.py")
			let selected = [
				"SigningCustodyControls.test_explicit_existing_configuration_matches_independent_public_der",
				"SigningCustodyControls.test_complete_fixed_pipeline_uses_live_unsigned_bytes",
				"SigningCustodyControls.test_signing_order_and_identifiers_are_fixed_inside_out",
				"SigningCustodyControls.test_complete_source_recuts_surround_every_native_boundary",
				"SigningCustodyControls.test_default_prepare_creates_no_signed_stage_or_native_commands",
				"SigningCustodyControls.test_private_handoff_current_and_held_members_refuse_after_lexical_exit",
				"SigningCustodyControls.test_retired_outcome_or_receipt_is_not_live_unsigned_authority",
				"SigningCustodyControls.test_absent_credentials_refuse_after_unsigned_completion",
				"SigningCustodyControls.test_partial_credentials_refuse_after_unsigned_completion",
				"SigningCustodyControls.test_adhoc_identity_refuses_without_native_fallback",
				"SigningCustodyControls.test_wrong_identity_for_public_der_refuses",
			]
			// Existing SDK Guardian retains its literal 30/35/10 bounds.
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path] + selected, root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout, "")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{11}\n-{70}\nRan 11 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}

	func testPortableSigningSecondCustodyWithModeledNativeEndpoints() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_signing_test.py")
			let selected = [
				"SigningCustodyControls.test_unowned_keychain_mode_refuses",
				"SigningCustodyControls.test_keychain_symlink_refuses",
				"SigningCustodyControls.test_same_byte_public_leaf_replacement_during_native_boundary_refuses",
				"SigningCustodyControls.test_same_byte_original_resource_replacement_during_native_boundary_refuses",
				"SigningCustodyControls.test_same_byte_unsigned_primary_replacement_during_native_boundary_refuses",
				"SigningCustodyControls.test_unsigned_inventory_injection_during_native_boundary_refuses",
				"SigningCustodyControls.test_exclusive_signed_stage_collision_refuses",
				"SigningCustodyControls.test_signed_stage_link_collision_refuses",
				"SigningCustodyControls.test_signature_work_collision_refuses",
				"SigningCustodyControls.test_wrong_actual_extracted_leaf_refuses",
			]
			// Existing SDK Guardian retains its literal 30/35/10 bounds.
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path] + selected, root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout, "")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{10}\n-{70}\nRan 10 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}

	func testPortableSigningThirdCustodyWithModeledNativeEndpoints() throws {
		try fixture { root in
			let script = source("hs274_native_build.py").deletingLastPathComponent()
				.deletingLastPathComponent().appendingPathComponent("build/remap_runtime_signing_test.py")
			let selected = [
				"SigningCustodyControls.test_wrong_actual_designated_identifier_refuses",
				"SigningCustodyControls.test_native_command_failure_preserves_original_completed_unsigned_facts",
				"SigningCustodyControls.test_valid_modeled_external_verify_cannot_admit_substituted_executable",
				"SigningCustodyControls.test_secondary_execute_object_refuses_after_native_boundary",
				"SigningCustodyControls.test_signed_source_resource_mutation_refuses",
				"SigningCustodyControls.test_signature_inventory_file_bound_refuses_before_payload_read",
				"SigningCustodyControls.test_signature_inventory_symlink_refuses",
				"SigningCustodyControls.test_native_verification_requires_two_architectures",
				"SigningCustodyControls.test_caught_nested_entry_refuses_outer_signing_without_reusing_claim",
				"SigningCustodyControls.test_expired_deadline_refuses_without_renewal",
			]
			// Existing SDK Guardian retains its literal 30/35/10 bounds.
			let receipt = try run(URL(fileURLWithPath: "/usr/bin/env"), ["python3", script.path] + selected, root: root)
			XCTAssertEqual(receipt.status, 0)
			XCTAssertEqual(receipt.stdout, "")
			let summary = try NSRegularExpression(pattern:
				#"^[.]{10}\n-{70}\nRan 10 tests in [0-9]+(?:\.[0-9]+)?s\n\nOK\n$"#)
			let range = NSRange(receipt.stderr.startIndex..<receipt.stderr.endIndex, in: receipt.stderr)
			XCTAssertEqual(summary.firstMatch(in: receipt.stderr, range: range)?.range, range)
		}
	}
}
