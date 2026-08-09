// Tests/ErgoptiPlusTests/LauncherEnvironmentTests.swift

// ==============================================================================
// MODULE: Launcher Child-Environment Tests
// DESCRIPTION:
// Proves that the Swift launcher exports its exact live process identity to the
// embedded Hammerspoon child instead of trusting an inherited or fixed marker.
//
// FEATURES & RATIONALE:
// 1. Exact PID replacement: an inherited stale launcher PID is overwritten by
//    the current process identifier before Process.environment is assigned.
// 2. Observable bundle identity: the current bundle identifier is exported when
//    known, while a stale inherited identifier is removed when it is unknown.
// 3. Environment preservation: unrelated child configuration survives unchanged.
// 4. Fail-fast identity: a missing device/inode proof reaches the fatal path
//    before the embedded Hammerspoon child runner can execute.
//
// NOTE: This target requires the macOS Swift toolchain. Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import Dispatch
import XCTest
@testable import ErgoptiPlus

/// Verifies the pure child-environment boundary used before launching embedded
/// Hammerspoon.
final class LauncherEnvironmentTests: XCTestCase {





	// ============================================
	// ============================================
	// ======= 1/ Exact Child Identity ============
	// ============================================
	// ============================================

	/// Verifies current launcher identity replaces stale inherited markers.
	func testExactLauncherIdentityReplacesInheritedMarkers() {
		let environment = launcherChildEnvironment(
			base: [
				"ERGOPTI_LAUNCHER_PID": "7",
				"ERGOPTI_LAUNCHER_BUNDLE_ID": "example.stale",
				"UNRELATED": "preserved",
			],
			launcherPid: 4242,
			launcherBundleId: "com.ergoptiplus.app"
		)

		XCTAssertEqual(environment["ERGOPTI_LAUNCHER_PID"], "4242")
		XCTAssertEqual(
			environment["ERGOPTI_LAUNCHER_BUNDLE_ID"],
			"com.ergoptiplus.app"
		)
		XCTAssertEqual(environment["UNRELATED"], "preserved")
	}

	/// Verifies an unavailable bundle identifier removes inherited stale state.
	func testUnknownBundleIdentityCannotLeakAnInheritedMarker() {
		for bundleId in [nil, ""] as [String?] {
			let environment = launcherChildEnvironment(
				base: ["ERGOPTI_LAUNCHER_BUNDLE_ID": "example.stale"],
				launcherPid: 4242,
				launcherBundleId: bundleId
			)

			XCTAssertNil(environment["ERGOPTI_LAUNCHER_BUNDLE_ID"])
		}
	}

	/// Proves an unavailable launcher file identity cannot start a partial app.
	func testMissingLauncherFileIdentityFailsBeforeChildStart() {
		var childStartCount = 0
		var fatalMessages: [String] = []
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in nil },
			processRunner: { _ in childStartCount += 1 },
			fatalReporter: { fatalMessages.append($0) }
		)

		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		XCTAssertEqual(childStartCount, 0)
		XCTAssertEqual(
			fatalMessages,
			["Running launcher executable identity is unavailable."]
		)
	}

	/// The Lua child receives the exact fail-closed reason for localized recovery UI.
	func testGuardianRegistrationStatusIsExportedToHammerspoon() {
		var childEnvironment: [String: String] = [:]
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { process in childEnvironment = process.environment ?? [:] }
		)

		delegate.launchHammerspoon(
			at: "/tmp/embedded-hammerspoon",
			remapGuardianStatus: .requiresApproval
		)

		XCTAssertEqual(
			childEnvironment["ERGOPTI_REMAP_GUARDIAN_STATUS"],
			"requires_approval"
		)
	}

	/// The composed startup cannot create the child before registration resolves.
	func testManagedHammerspoonWaitsForGuardianRegistrationResultBeforeChildStart() {
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let childStarted = expectation(description: "managed Hammerspoon child started")
		let stateLock = NSLock()
		var childStartCount = 0
		var childEnvironment: [String: String] = [:]
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { process in
				stateLock.lock()
				childStartCount += 1
				childEnvironment = process.environment ?? [:]
				stateLock.unlock()
				childStarted.fulfill()
			},
			guardianRegistrar: { _ in
				entered.signal()
				guard release.wait(timeout: .now() + 2) == .success
				else { return .unavailable }
				return .requiresApproval
			}
		)

		withExtendedLifetime(delegate) {
			delegate.startManagedHammerspoon(
				at: "/tmp/embedded-hammerspoon",
				launcherPath: "/tmp/ErgoptiPlus"
			)
			XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
			stateLock.lock()
			let startsBeforeRegistration = childStartCount
			stateLock.unlock()
			XCTAssertEqual(startsBeforeRegistration, 0)
			release.signal()
			wait(for: [childStarted], timeout: 2)
			stateLock.lock()
			let finalStartCount = childStartCount
			let exportedStatus = childEnvironment["ERGOPTI_REMAP_GUARDIAN_STATUS"]
			stateLock.unlock()
			XCTAssertEqual(finalStartCount, 1)
			XCTAssertEqual(exportedStatus, "requires_approval")
		}
	}

	/// A blocked legacy launchctl path cannot park AppKit's startup callback.
	func testGuardianRegistrationRunsOffTheMainThread() {
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let resultLock = NSLock()
		var registrarObservedRelease = false
		let completed = expectation(description: "registration delivered on main")
		let delegate = AppDelegate(guardianRegistrar: { _ in
			entered.signal()
			let result = release.wait(timeout: .now() + 1)
			resultLock.lock()
			registrarObservedRelease = result == .success
			resultLock.unlock()
			return .ready
		})

		delegate.beginRemapGuardianRegistration(executablePath: "/tmp/ErgoptiPlus") {
			status in
			XCTAssertTrue(Thread.isMainThread)
			XCTAssertEqual(status, .ready)
			resultLock.lock()
			let ranAsynchronously = registrarObservedRelease
			resultLock.unlock()
			XCTAssertTrue(ranAsynchronously,
				"a synchronous registrar would time out before this test can release it")
			completed.fulfill()
		}

		XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
		release.signal()
		wait(for: [completed], timeout: 2)
	}
}
