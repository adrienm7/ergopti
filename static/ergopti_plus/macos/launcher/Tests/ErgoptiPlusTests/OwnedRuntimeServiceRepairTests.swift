// Tests/ErgoptiPlusTests/OwnedRuntimeServiceRepairTests.swift
// MRT-004: the service repair of an already published Runtime adopts only the exact owned plist and keeps the first
// install's refusals. Disposable filesystem fixtures never grant administrator or service authority.
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedRuntimeServiceRepairTests: XCTestCase {
	func testRepairFlagIsExactAndDistinctFromTheFirstInstall() {
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.mode(arguments: ["Main", "--request-owned-runtime-repair"]), .repair)
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.mode(arguments: ["Main", "--request-owned-runtime-install"]), .install)
		for arguments in [["Main"], ["Main", "--request-owned-runtime-repair", "extra"], ["Main", "--owned-repair-service"],
			["Main", "--owned-install-first"], ["Main", "--request-owned-runtime-repair "]] {
			XCTAssertNil(OwnedRuntimeInstallMainOperation.mode(arguments: arguments), arguments.joined(separator: " "))
			XCTAssertFalse(OwnedRuntimeInstallMainOperation.handles(arguments: arguments))
		}
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.Mode.repair.helperArgument, OwnedRuntimeServiceRepairEntry.argument)
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.Mode.install.helperArgument, "--owned-install-first")
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.Mode.repair.requestKind, "OWNED_RUNTIME_REPAIR_REQUEST")
	}

	func testEachRoleRelaysOnlyItsOwnHelperResults() {
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.relayedLine("OWNED_RUNTIME_REPAIR|1|service-repaired-observed", mode: .repair),
			"OWNED_RUNTIME_REPAIR|1|service-repaired-observed")
		XCTAssertNotNil(OwnedRuntimeInstallMainOperation.relayedLine("OWNED_RUNTIME_REPAIR|1|service-repair-pending", mode: .repair))
		XCTAssertNotNil(OwnedRuntimeInstallMainOperation.relayedLine(
			"OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired", mode: .install))
		let refused: [(String, OwnedRuntimeInstallMainOperation.Mode)] = [
			("OWNED_RUNTIME_INSTALL|1|files-published-services-observed-staging-retired", .repair),
			("OWNED_RUNTIME_REPAIR|1|service-repaired-observed", .install),
			("OWNED_RUNTIME_REPAIR|1|refused", .repair),
			("OWNED_RUNTIME_REPAIR|1|service-repaired-observed extra", .repair),
			("", .repair),
		]
		for (line, mode) in refused {
			XCTAssertNil(OwnedRuntimeInstallMainOperation.relayedLine(line, mode: mode), line)
		}
	}

	func testHelperResultValuesMatchTheRepairEntry() {
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.Mode.repair.helperResults,
			[OwnedRuntimeServiceRepairEntry.Result.servicesObserved.rawValue, OwnedRuntimeServiceRepairEntry.Result.servicePending.rawValue])
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private let plistName = "com.ergoptiplus.runtime.core.plist"
	private let ledgerName = ".runtime-service-journal"

	private func writePlist(_ bytes: Data, in parent: URL, mode: Int = 0o644) throws -> URL {
		let file = parent.appendingPathComponent(plistName)
		try bytes.write(to: file)
		try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
		return file
	}

	func testRepairAdoptsTheExactPlistAndItsRollbackKeepsIt() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let file = try writePlist(bytes, in: parent)
		XCTAssertTrue(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: false))
		XCTAssertEqual(try Data(contentsOf: file), bytes, "an adopted plist is given back exactly")
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(ledgerName).path))
	}

	func testARestartReadsTheAdoptionBackFromTheLedger() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let file = try writePlist(bytes, in: parent)
		XCTAssertTrue(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: true))
		XCTAssertEqual(try Data(contentsOf: file), bytes, "a restarted custody still keeps the adopted plist")
	}

	func testRepairCreatesAnAbsentPlistAndItsRollbackRemovesIt() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		XCTAssertTrue(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: false))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(plistName).path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(ledgerName).path))
	}

	func testRepairRefusesForeignBytesWithoutDebt() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let foreign = bytes + Data(" ".utf8)
		let file = try writePlist(foreign, in: parent)
		XCTAssertFalse(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: false))
		XCTAssertEqual(try Data(contentsOf: file), foreign)
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(ledgerName).path))
	}

	func testRepairRefusesTheExactBytesUnderAnotherMode() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let file = try writePlist(bytes, in: parent, mode: 0o666)
		XCTAssertFalse(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: false))
		XCTAssertEqual(try Data(contentsOf: file), bytes)
		XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent(ledgerName).path))
	}

	func testRepairRefusesASymlinkToTheExactBytes() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let target = parent.appendingPathComponent("personal.plist"); try bytes.write(to: target)
		try FileManager.default.createSymbolicLink(atPath: parent.appendingPathComponent(plistName).path, withDestinationPath: target.path)
		XCTAssertFalse(try OwnedRuntimeCorePlistCustody.fixtureAdoptRollback(parent: parent, bytes: bytes, restart: false))
		XCTAssertEqual(try Data(contentsOf: target), bytes)
	}

	func testTheFirstInstallStillRefusesAPresentExactPlist() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let bytes = try OwnedRuntimeCoreProvisionOwner.fixturePlist()
		let file = try writePlist(bytes, in: parent)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureRollback(parent: parent))
		XCTAssertEqual(try Data(contentsOf: file), bytes)
	}

	func testTheFirstStartFenceStillRefusesAPresentSystemConfiguration() throws {
		let parent = try OwnedRuntimeFixtureDirectory.create(); defer { try? FileManager.default.removeItem(at: parent) }
		let configuration = parent.appendingPathComponent("core.json"); try Data("{}".utf8).write(to: configuration)
		XCTAssertFalse(try OwnedRuntimeCoreProvisionOwner.fixtureConfigurationAbsent(parent: parent))
		XCTAssertEqual(try Data(contentsOf: configuration), Data("{}".utf8), "the repair never moves or removes it")
	}
	#endif
}
