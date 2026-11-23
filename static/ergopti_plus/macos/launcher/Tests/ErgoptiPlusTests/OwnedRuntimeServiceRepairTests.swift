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

	/// Field report 2026-11-23: a Runtime folder an earlier install left (its CLI missing) made the driver offer the
	/// install, and the helper refused every retry at `refused-destination`. The install's administrator shell now
	/// retires it first; the repair keeps the published Runtime it repairs.
	func testTheInstallRetiresAStaleRuntimeBeforeTheHelper() throws {
		let program = OwnedRuntimeUninstall.staleRuntimeProgram()
		let label = Identifiers.ServiceLabels.macosCore
		XCTAssertTrue(program.hasPrefix("task_step=stale_runtime; "), program)
		XCTAssertTrue(program.contains("/bin/launchctl bootout system/" + label + ";"), program)
		XCTAssertTrue(program.contains("/bin/rm -f '/Library/LaunchDaemons/" + label + ".plist';"), program)
		XCTAssertTrue(program.contains("/bin/rm -rf '" + OwnedRuntimeUninstall.runtimeDirectory + "';"), program)
		XCTAssertFalse(program.contains(Identifiers.ServiceLabels.macosVirtualHid), program)
		// The same text, pointed at a disposable folder and an unknown job, removes a half-published Runtime.
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-runtime-" + UUID().uuidString)
		defer { try? FileManager.default.removeItem(at: root) }
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Runtime/bin", isDirectory: true),
			withIntermediateDirectories: true)
		let plist = root.appendingPathComponent("core.plist")
		try Data("x".utf8).write(to: plist)
		let sandboxed = program
			.replacingOccurrences(of: OwnedRuntimeUninstall.runtimeDirectory, with: root.appendingPathComponent("Runtime").path)
			.replacingOccurrences(of: "/Library/LaunchDaemons/" + label + ".plist", with: plist.path)
			.replacingOccurrences(of: label, with: "com.ergoptiplus.tests.absent-" + UUID().uuidString)
		let shell = Process()
		shell.executableURL = URL(fileURLWithPath: "/bin/sh")
		shell.arguments = ["-c", "set -eu; " + sandboxed + "exit 0"]
		try shell.run(); shell.waitUntilExit()
		XCTAssertEqual(shell.terminationStatus, 0)
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
	}

	/// Field report 2026-11-23: a plain `refused-destination`, met before the journal wrote anything, came back as
	/// « cleanup pending » because the rollback it never needed refused.
	func testARefusalBeforeTheJournalIsARefusalNotCleanupPending() {
		var rolledBack = 0
		XCTAssertEqual(OwnedRuntimeIdleServiceEntry.unpublishedResult(.refused, rollback: { rolledBack += 1; return false }), .refused)
		XCTAssertEqual(rolledBack, 0, "nothing was written, so nothing is rolled back")
		XCTAssertEqual(OwnedRuntimeIdleServiceEntry.unpublishedResult(.cleanupPending, rollback: { true }), .refused)
		XCTAssertEqual(OwnedRuntimeIdleServiceEntry.unpublishedResult(.cleanupPending, rollback: { false }), .cleanupPending)
	}

	func testHelperResultValuesMatchTheRepairEntry() {
		XCTAssertEqual(OwnedRuntimeInstallMainOperation.Mode.repair.helperResults,
			[OwnedRuntimeServiceRepairEntry.Result.servicesObserved.rawValue, OwnedRuntimeServiceRepairEntry.Result.servicePending.rawValue])
	}

	#if ERGOPTI_GUARDIAN_TEST_SUPPORT
	private let plistName = Identifiers.ServiceLabels.macosCore + ".plist"
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
