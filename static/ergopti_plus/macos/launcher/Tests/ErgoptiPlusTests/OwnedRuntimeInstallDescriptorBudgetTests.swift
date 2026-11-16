// Tests/ErgoptiPlusTests/OwnedRuntimeInstallDescriptorBudgetTests.swift
// Field report 2026-11-15: the install helper ran out of descriptors (errno 24) after publishing Runtime, and the
// driver log and field check named only « cleanup pending ».
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeInstallDescriptorBudgetTests: XCTestCase {
	/// RLIM_INFINITY (2^63 - 1); its C macro is a cast expression Swift does not import.
	private let unlimited = rlim_t(Int64.max)

	/// The inherited 256 is raised to OPEN_MAX when the hard limit allows it (owned-install-fd-limit).
	func testTheHelperRaisesAnInheritedSoftLimitOf256() {
		var written: rlimit?
		let after = OwnedRuntimeDescriptorBudget.raiseSoftLimit(
			read: { $0 = rlimit(rlim_cur: 256, rlim_max: unlimited); return 0 },
			write: { written = $0; return 0 })
		XCTAssertEqual(after, rlim_t(OPEN_MAX))
		XCTAssertEqual(written?.rlim_cur, rlim_t(OPEN_MAX))
		XCTAssertEqual(written?.rlim_max, unlimited, "the hard limit is left as it was")
		XCTAssertGreaterThan(OwnedRuntimeDescriptorBudget.wanted, 256)
	}

	func testALowHardLimitBoundsTheRaiseAndAHighSoftLimitIsKept() {
		var written: rlimit?
		XCTAssertEqual(OwnedRuntimeDescriptorBudget.raiseSoftLimit(
			read: { $0 = rlimit(rlim_cur: 256, rlim_max: 1024); return 0 }, write: { written = $0; return 0 }), 1024)
		XCTAssertEqual(written?.rlim_cur, 1024)
		written = nil
		XCTAssertEqual(OwnedRuntimeDescriptorBudget.raiseSoftLimit(
			read: { $0 = rlimit(rlim_cur: rlim_t(OPEN_MAX), rlim_max: unlimited); return 0 },
			write: { written = $0; return 0 }), rlim_t(OPEN_MAX))
		XCTAssertNil(written, "nothing to raise, nothing written")
	}

	func testARefusedRaiseKeepsTheInheritedLimit() {
		XCTAssertEqual(OwnedRuntimeDescriptorBudget.raiseSoftLimit(
			read: { $0 = rlimit(rlim_cur: 256, rlim_max: unlimited); return 0 }, write: { _ in -1 }), 256)
	}

	/// Descriptor exhaustion names how many are open and the limit; any other errno reads as before.
	func testExhaustionNamesTheOpenDescriptorsAndTheLimit() {
		XCTAssertEqual(OwnedRuntimeDescriptorBudget.errnoDetail(EACCES), "errno-" + String(EACCES))
		let detail = OwnedRuntimeDescriptorBudget.errnoDetail(EMFILE)
		XCTAssertTrue(detail.hasPrefix("errno-24-fds-"), detail)
		let parts = detail.split(separator: "-")
		XCTAssertEqual(parts.count, 6, detail)
		XCTAssertGreaterThanOrEqual(Int(parts[3]) ?? -1, 3, "stdin, stdout and stderr are open: " + detail)
		XCTAssertEqual(parts[4], "of")
		XCTAssertGreaterThan(Int(parts[5]) ?? 0, 0, detail)
	}
}
