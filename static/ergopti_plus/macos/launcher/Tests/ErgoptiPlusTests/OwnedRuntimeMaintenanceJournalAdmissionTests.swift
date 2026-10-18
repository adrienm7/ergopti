// Tests/ErgoptiPlusTests/OwnedRuntimeMaintenanceJournalAdmissionTests.swift
// Original held native namespace currentness never substitutes durable operation absence.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeMaintenanceJournalAdmissionTests: XCTestCase {
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	func testActualFixedMaintenanceLedgerBlocksOriginalImageAdmission() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create()
		defer { try? FileManager.default.removeItem(at: parent) }
		let held = try OwnedRuntimeServiceLifecycleLock.fixtureAcquire(parent: parent, exclusive: false, create: true)
		defer { XCTAssertTrue(held.retire()) }
		XCTAssertTrue(held.current()); XCTAssertTrue(held.permitsInstalledImages())
		let ledger = parent.appendingPathComponent(".runtime-maintenance-journal")
		try Data("pending".utf8).write(to: ledger, options: .withoutOverwriting)
		XCTAssertTrue(held.current()); XCTAssertFalse(held.permitsInstalledImages())
		try FileManager.default.removeItem(at: ledger)
		try FileManager.default.createDirectory(at: ledger, withIntermediateDirectories: false)
		XCTAssertTrue(held.current()); XCTAssertFalse(held.permitsInstalledImages())
		try FileManager.default.removeItem(at: ledger)
		try Data("foreign".utf8).write(to: parent.appendingPathComponent("unrelated-ledger"), options: .withoutOverwriting)
		XCTAssertTrue(held.current()); XCTAssertTrue(held.permitsInstalledImages())
	}
#endif
}
