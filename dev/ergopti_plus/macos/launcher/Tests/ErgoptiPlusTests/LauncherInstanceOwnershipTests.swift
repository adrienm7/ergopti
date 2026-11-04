// Tests/ErgoptiPlusTests/LauncherInstanceOwnershipTests.swift

// ==============================================================================
// MODULE: Launcher Instance Ownership Tests
// DESCRIPTION:
// On 2026-10-21 and 2026-10-22 a second embedded runtime ran beside the
// launcher's own (hs-second-instance-2026-10-22). These tests pin the two
// launcher-side halves of the fix: one launcher per user, and a replacement
// scan that can select only the embedded runtime's own bundle identity, so a
// Hammerspoon the user installed is never terminated.
//
// NOTE: This target requires the macOS Swift toolchain; it runs on macOS CI.
// ==============================================================================

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class LauncherInstanceOwnershipTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ergopti-instance-lock-\(UUID().uuidString)", isDirectory: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	private var lockPath: String {
		directory.appendingPathComponent("launcher.lock").path
	}

	func testTheLockLivesBesideTheLauncherPathsFile() {
		XCTAssertEqual(
			launcherInstanceLockPath(homeDirectory: "/Users/u"),
			"/Users/u/Library/Application Support/ErgoptiPlus/launcher.lock"
		)
		XCTAssertEqual(
			(launcherInstanceLockPath(homeDirectory: "/Users/u") as NSString).deletingLastPathComponent,
			(managedPathsFile(homeDirectory: "/Users/u") as NSString).deletingLastPathComponent
		)
	}

	func testASecondLauncherIsRefusedWhileTheFirstHoldsTheLock() {
		let first = LauncherInstanceLock(path: lockPath)
		let second = LauncherInstanceLock(path: lockPath)
		XCTAssertEqual(first.acquire(), .acquired, "the lock folder is created when absent")
		XCTAssertEqual(second.acquire(), .heldByAnotherLauncher)
		XCTAssertFalse(second.isHeld)
		first.release()
		XCTAssertEqual(second.acquire(), .acquired, "a released lock is free for the next launcher")
		second.release()
	}

	func testADuplicateAcquireOnTheSameOwnerIsRefused() {
		let lock = LauncherInstanceLock(path: lockPath)
		XCTAssertEqual(lock.acquire(), .acquired)
		XCTAssertEqual(lock.acquire(), .failed(errorCode: EALREADY))
		lock.release()
	}

	func testTheLockDescriptorIsNotInheritedByHelpers() throws {
		let lock = LauncherInstanceLock(path: lockPath)
		XCTAssertEqual(lock.acquire(), .acquired)
		let descriptor = try XCTUnwrap(lock.heldDescriptor)
		XCTAssertNotEqual(fcntl(descriptor, F_GETFD) & FD_CLOEXEC, 0,
			"a helper that inherited the lock would keep it after the launcher exits")
		lock.release()
	}

	func testOnlyTheEmbeddedRuntimeIdentityIsEverReplaced() {
		let running = [
			RunningRuntimeCandidate(processIdentifier: 10, bundleIdentifier: kEmbeddedHammerspoonBundleId),
			RunningRuntimeCandidate(processIdentifier: 11, bundleIdentifier: "org.hammerspoon.Hammerspoon"),
			RunningRuntimeCandidate(processIdentifier: 12, bundleIdentifier: nil),
			RunningRuntimeCandidate(processIdentifier: 13, bundleIdentifier: kEmbeddedHammerspoonBundleId),
			RunningRuntimeCandidate(processIdentifier: 0, bundleIdentifier: kEmbeddedHammerspoonBundleId),
		]
		XCTAssertEqual(staleEmbeddedRuntimes(running, trackedChild: 13), [10],
			"the user's Hammerspoon, an unknown identity and this launcher's own child stay untouched")
		XCTAssertEqual(staleEmbeddedRuntimes(running, trackedChild: nil), [10, 13])
	}

	func testStartupProceedsAtOnceWhenNoLeftoverRuntimeRuns() {
		var childStartCount = 0
		var fatalMessages: [String] = []
		var scannedBundles: [String] = []
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			applicationLauncher: { _, _, _ in childStartCount += 1 },
			fatalReporter: { fatalMessages.append($0) },
			loggerWorkerFactory: { nil },
			instanceLock: LauncherInstanceLock(path: lockPath),
			runningApplicationsReader: { bundle in
				scannedBundles.append(bundle)
				return []
			}
		)
		delegate.startManagedHammerspoon(at: "/nonexistent/Hammerspoon.app/Contents/MacOS/Hammerspoon")
		XCTAssertEqual(scannedBundles, [kEmbeddedHammerspoonBundleId],
			"the replacement scan asks for the embedded identity only")
		XCTAssertEqual(childStartCount, 0, "a missing logger worker still fails before any child start")
		XCTAssertEqual(fatalMessages.count, 1, "the launch itself was attempted right after the scan")
	}
}
