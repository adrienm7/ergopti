// Tests/ErgoptiPlusTests/OwnedRuntimeInstallJournalHeaderOnlyTests.swift
// A journal that recorded no vnode retires itself, so the next install is not refused at its exclusive create.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeInstallJournalHeaderOnlyTests: XCTestCase {
#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	func testHeaderOnlyJournalRetiresAndAdmitsTheNextInstall() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create()
		defer { try? FileManager.default.removeItem(at: parent) }
		let ledger = parent.appendingPathComponent(".runtime-install-journal")
		do {
			// The failure between create() and the stage's first record leaves exactly this header-only journal.
			let journal = try OwnedRuntimeInstallJournal.fixtureCreate(parent: parent)
			XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path))
			XCTAssertNoThrow(try journal.retireUnpublished())
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
		// The exclusive create that refused at line 94 after an interrupted install now admits the next one.
		XCTAssertNoThrow(try OwnedRuntimeInstallJournal.fixtureCreate(parent: parent))
	}

	func testRecoveredHeaderOnlyJournalRetiresWithoutAnyVnode() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create()
		defer { try? FileManager.default.removeItem(at: parent) }
		let ledger = parent.appendingPathComponent(".runtime-install-journal")
		do { _ = try OwnedRuntimeInstallJournal.fixtureCreate(parent: parent) }
		XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path))
		let recovered = try OwnedRuntimeInstallJournal.fixtureRecover(parent: parent)
		XCTAssertNoThrow(try recovered.retireUnpublished())
		XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
		XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
	}
#endif
}
