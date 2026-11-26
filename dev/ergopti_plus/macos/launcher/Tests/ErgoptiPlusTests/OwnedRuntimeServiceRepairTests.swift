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
		XCTAssertTrue(program.hasPrefix("task_step=" + OwnedRuntimeUninstall.busyStep + "; "), program)
		XCTAssertTrue(program.contains("task_step=stale_runtime; "), program)
		XCTAssertTrue(program.contains("/bin/launchctl bootout system/" + label + ";"), program)
		XCTAssertTrue(program.contains("/bin/rm -f /Library/LaunchDaemons/" + label + ".plist;"), program)
		XCTAssertTrue(program.contains("/bin/rm -rf '" + OwnedRuntimeUninstall.runtimeDirectory + "';"), program)
		XCTAssertEqual(OwnedRuntimeUninstall.runtimeDirectory, OwnedRuntimeUninstall.ownedFolder + "/Runtime")
		XCTAssertFalse(program.contains(Identifiers.ServiceLabels.macosVirtualHid), program)
		// The same text, pointed at a disposable folder and an unknown job, removes a half-published Runtime.
		let root = try staleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		XCTAssertEqual(try runStaleProgram(in: root), 0)
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("core.plist").path))
	}

	/// Field report 2026-11-24: an install that stopped after its publication intent kept `.runtime-install-journal`,
	/// which no helper recovers, so once the stale step retired the Runtime every helper refused at its exclusive
	/// journal create (`refused-cleanupPending` at OwnedRuntimeInstallJournal.swift:94) and no retry could pass.
	/// The stale step now retires the ledgers and copy stages that install left, and keeps the shell's own staged
	/// helper (stale-install-journal).
	func testTheInstallRetiresTheJournalAndStagesAnInterruptedInstallLeft() throws {
		let program = OwnedRuntimeUninstall.staleRuntimeProgram()
		XCTAssertTrue(program.contains("task_step=stale_install; "), program)
		guard let busy = program.range(of: "/usr/sbin/lsof"), let bootout = program.range(of: "/bin/launchctl bootout") else {
			return XCTFail(program)
		}
		XCTAssertLessThan(busy.lowerBound, bootout.lowerBound, "the busy check stops the shell before anything is retired")
		guard let stages = program.range(of: OwnedRuntimeUninstall.installStagePattern),
			let journal = program.range(of: "/bin/rm -f '" + OwnedRuntimeUninstall.ownedFolder + "/.runtime-install-journal'") else {
			return XCTFail(program)
		}
		XCTAssertLessThan(stages.lowerBound, journal.lowerBound, "the journal goes last, so an interrupted retirement stays debt")
		let root = try staleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let stage = root.appendingPathComponent(".runtime-install-" + UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: stage.appendingPathComponent("bin", isDirectory: true),
			withIntermediateDirectories: true)
		try Data("x".utf8).write(to: stage.appendingPathComponent("bin/ergoptiplus_remap_cli"))
		let helper = root.appendingPathComponent(".runtime-installer-" + UUID().uuidString + "/Helper.app", isDirectory: true)
		try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
		let vhidLedger = root.appendingPathComponent(".runtime-vhid-service-journal")
		try Data("VHID_PLIST|1|pending".utf8).write(to: vhidLedger)
		for ledger in OwnedRuntimeUninstall.staleLedgers {
			try Data("header".utf8).write(to: root.appendingPathComponent(ledger))
		}
		XCTAssertEqual(try runStaleProgram(in: root), 0)
		for ledger in OwnedRuntimeUninstall.staleLedgers {
			XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(ledger).path), ledger)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: helper.path), "the shell's own staged helper stays")
		XCTAssertTrue(FileManager.default.fileExists(atPath: vhidLedger.path), "the VirtualHIDDevice job stays the helper's")
		XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime").path))
		// Nothing is left, so the same step passes again.
		XCTAssertEqual(try runStaleProgram(in: root), 0)
	}

	/// A live helper keeps its journal open for its whole transaction: the shell then stops at `install_busy`,
	/// before it stops the Core job or removes anything (stale-install-journal).
	func testTheInstallStopsBeforeAnythingWhileALiveHelperHoldsTheJournal() throws {
		let root = try staleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let journal = root.appendingPathComponent(".runtime-install-journal")
		try Data("header".utf8).write(to: journal)
		let held = try FileHandle(forReadingFrom: journal)
		defer { try? held.close() }
		XCTAssertEqual(try runStaleProgram(in: root), 77)
		XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime/bin").path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("core.plist").path))
	}

	/// A ledger that is not the plain file a helper creates is never followed or removed (stale-install-journal).
	func testTheInstallRefusesALedgerThatIsNotAPlainFile() throws {
		let root = try staleFixture()
		defer { try? FileManager.default.removeItem(at: root) }
		let target = root.appendingPathComponent("personal.txt")
		try Data("keep".utf8).write(to: target)
		let journal = root.appendingPathComponent(".runtime-install-journal")
		try FileManager.default.createSymbolicLink(atPath: journal.path, withDestinationPath: target.path)
		XCTAssertEqual(try runStaleProgram(in: root), 77)
		XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
		XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime/bin").path))
	}

	/// A disposable owned folder with a half-published Runtime and a Core plist beside it.
	/// - Returns: The folder, which the caller removes.
	private func staleFixture() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("stale-runtime-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root.appendingPathComponent("Runtime/bin", isDirectory: true),
			withIntermediateDirectories: true)
		try Data("x".utf8).write(to: root.appendingPathComponent("core.plist"))
		return root
	}

	/// Runs the install's stale step against a disposable folder instead of the owned one, with an unknown job.
	/// - Parameter root: The folder from staleFixture.
	/// - Returns: The shell's exit status.
	private func runStaleProgram(in root: URL) throws -> Int32 {
		let label = Identifiers.ServiceLabels.macosCore
		let sandboxed = OwnedRuntimeUninstall.staleRuntimeProgram()
			.replacingOccurrences(of: OwnedRuntimeUninstall.ownedFolder, with: root.path)
			.replacingOccurrences(of: "/Library/LaunchDaemons/" + label + ".plist", with: root.appendingPathComponent("core.plist").path)
			.replacingOccurrences(of: label, with: "com.ergoptiplus.tests.absent-" + UUID().uuidString)
		XCTAssertFalse(sandboxed.contains(OwnedRuntimeUninstall.ownedFolder), sandboxed)
		let shell = Process()
		shell.executableURL = URL(fileURLWithPath: "/bin/sh")
		shell.arguments = ["-c", "set -eu; " + sandboxed + "exit 0"]
		try shell.run(); shell.waitUntilExit()
		return shell.terminationStatus
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
