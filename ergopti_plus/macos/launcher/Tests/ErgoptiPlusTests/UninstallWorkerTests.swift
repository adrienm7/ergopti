// Tests/ErgoptiPlusTests/UninstallWorkerTests.swift

// ==============================================================================
// MODULE: Uninstall Authorization Tests
// DESCRIPTION:
// Proves filesystem removal cannot precede authorization, clean exit and renewed
// ownership validation. All capabilities are inert closures, including Trash.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

private final class UninstallLaunchctlStub: GuardianLaunchctlRunning {
	var calls: [[String]] = []
	var bootoutAllowed = true
	func run(arguments: [String]) -> Bool {
		calls.append(arguments)
		return arguments.first != "bootout" || bootoutAllowed
	}
}

final class UninstallWorkerTests: XCTestCase {
	func testBundleValidationRejectsAliasesSourceTreesAndChangedExecutable() throws {
		let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: temporary) }
		let root = temporary.resolvingSymlinksInPath()
		let bundle = root.appendingPathComponent("ErgoptiPlus.app")
		let executable = bundle.appendingPathComponent("Contents/MacOS/ErgoptiPlus")
		try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(),
			withIntermediateDirectories: true)
		try Data("owned executable".utf8).write(to: executable)
		let identity = try XCTUnwrap(launcherExecutableFileIdentity(at: executable.path))
		let environment = [
			"ERGOPTI_LAUNCHER_EXECUTABLE": executable.path,
			"ERGOPTI_LAUNCHER_DEVICE": identity.device,
			"ERGOPTI_LAUNCHER_INODE": identity.inode,
		]
		func validate(_ candidate: URL) throws {
			try validateUninstallBundle(bundle: candidate, bundleIdentifier: kErgoptiBundleId,
				environment: environment, expectedIdentity: identity)
		}
		XCTAssertNoThrow(try validate(bundle))
		let alias = root.appendingPathComponent("Alias.app")
		try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: bundle)
		XCTAssertThrowsError(try validate(alias))
		let marker = root.appendingPathComponent(".git")
		try Data("gitdir: elsewhere".utf8).write(to: marker)
		XCTAssertThrowsError(try validate(bundle))
		try FileManager.default.removeItem(at: marker)
		// Keep the old inode alive so filesystem reuse cannot obscure replacement.
		try FileManager.default.moveItem(at: executable, to: root.appendingPathComponent("old"))
		try Data("replacement executable".utf8).write(to: executable)
		XCTAssertThrowsError(try validate(bundle))
	}

	func testLegacyRemovalChecksExactBytesAndBootoutBeforeUnlink() throws {
		let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
		let agents = home.appendingPathComponent("Library/LaunchAgents")
		try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: home) }
		let plist = agents.appendingPathComponent(kRemapGuardianPlistName)
		let executable = "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
		let runner = UninstallLaunchctlStub()
		try Data("foreign agent".utf8).write(to: plist)
		XCTAssertFalse(removeLegacyRemapGuardian(
			executablePath: executable, runner: runner, homeDirectory: home.path
		))
		XCTAssertTrue(runner.calls.isEmpty)
		try Data(legacyGuardianPlist(executablePath: executable).utf8).write(to: plist)
		runner.bootoutAllowed = false
		XCTAssertFalse(removeLegacyRemapGuardian(
			executablePath: executable, runner: runner, homeDirectory: home.path
		))
		XCTAssertTrue(FileManager.default.fileExists(atPath: plist.path))
		runner.bootoutAllowed = true
		XCTAssertTrue(removeLegacyRemapGuardian(
			executablePath: executable, runner: runner, homeDirectory: home.path
		))
		XCTAssertFalse(FileManager.default.fileExists(atPath: plist.path))
	}

	func testLeaseRetirementAllowsTransientRecordsButRefusesPersistentOnes() throws {
		var clock: TimeInterval = 0
		XCTAssertTrue(try waitForUninstallLeaseRetirement(
			isEmpty: { clock >= 2 }, now: { clock }, pause: { clock += 1 }, timeout: 5
		))
		XCTAssertEqual(clock, 2)
		XCTAssertFalse(try waitForUninstallLeaseRetirement(
			isEmpty: { false }, now: { clock }, pause: { clock += 1 }, timeout: 5
		))
		XCTAssertEqual(clock, 7)
	}

	func testSuccessfulRemovalOrdersEveryOwnershipBoundary() throws {
		var calls: [String] = []
		try performConfirmedUninstall(
			validate: { calls.append("validate") },
			authorize: { calls.append("authorize"); return true },
			waitForCleanExit: { calls.append("exit"); return true },
			unregister: { calls.append("unregister") },
			trash: { calls.append("trash") }
		)
		XCTAssertEqual(calls, ["validate", "authorize", "exit", "validate", "unregister", "validate", "trash"])
	}

	func testRefusedAuthorizationOrUncleanExitNeverUnregistersOrRemoves() {
		for authorized in [false, true] {
			var destructiveCalls = 0
			XCTAssertThrowsError(try performConfirmedUninstall(
				validate: {}, authorize: { authorized }, waitForCleanExit: { false },
				unregister: { destructiveCalls += 1 }, trash: { destructiveCalls += 1 }
			))
			XCTAssertEqual(destructiveCalls, 0)
		}
	}

	func testChangedApplicationAtEitherRevalidationNeverReachesTrash() {
		for failedValidation in 1...3 {
			var validations = 0
			var removals = 0
			XCTAssertThrowsError(try performConfirmedUninstall(
				validate: {
					validations += 1
					if validations == failedValidation { throw UninstallFailure.invalidBundle }
				}, authorize: { true }, waitForCleanExit: { true }, unregister: {},
				trash: { removals += 1 }
			))
			XCTAssertEqual(removals, 0)
		}
	}
}
