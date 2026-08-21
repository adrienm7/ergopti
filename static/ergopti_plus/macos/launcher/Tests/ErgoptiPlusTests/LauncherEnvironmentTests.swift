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
// 5. Writable bootstrap: the packaged Lua child receives a stable paths.toml
//    location outside the signed application resources.
// 6. Logger authority: stale inherited credentials are removed, and the child
//    receives only the endpoint that was successfully bound before its launch.
// 7. Private inheritance: the launcher installs umask 0077 before child spawn.
// 8. Launch Services isolation: parent GUI identity cannot leak into Hammerspoon.
//
// NOTE: This target requires the macOS Swift toolchain. Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import Dispatch
import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

private final class TestLoggerDatagramServer: LoggerDatagramServing {
	let endpoint: LoggerDatagramEndpoint
	private(set) var stopCount = 0

	init(port: UInt16 = 31_337, token: String = "test-logger-token") {
		endpoint = LoggerDatagramEndpoint(port: port, token: token)
	}

	func stop() { stopCount += 1 }
}

/// Verifies the pure child-environment boundary used before launching embedded
/// Hammerspoon.
final class LauncherEnvironmentTests: XCTestCase {





	// ============================================
	// ============================================
	// ======= 1/ Exact Child Identity ============
	// ============================================
	// ============================================

	/// The child and native helpers must inherit a private file-creation mask.
	func testLauncherInstallsPrivateInheritedUmask() {
		var installedMask: mode_t?
		let priorMask = installPrivateProcessUmask { requestedMask in
			installedMask = requestedMask
			return 0o022
		}

		XCTAssertEqual(installedMask, 0o077)
		XCTAssertEqual(priorMask, 0o022)
	}

	/// Verifies current launcher identity replaces stale inherited markers.
	func testExactLauncherIdentityReplacesInheritedMarkers() {
		let environment = launcherChildEnvironment(
			base: [
				"ERGOPTI_LAUNCHER_PID": "7",
				"ERGOPTI_LAUNCHER_BUNDLE_ID": "example.stale",
				"ERGOPTI_LOG_PORT": "9",
				"ERGOPTI_LOG_TOKEN": "stale-token",
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
		XCTAssertNil(environment["ERGOPTI_LOG_PORT"])
		XCTAssertNil(environment["ERGOPTI_LOG_TOKEN"])
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

	/// A GUI child must discover its own bundle and preferences domain instead
	/// of impersonating the Launch Services parent that spawned it.
	func testOuterLaunchServicesIdentityCannotLeakIntoEmbeddedGUIChild() {
		let environment = launcherChildEnvironment(
			base: [
				"__CFBundleIdentifier": "com.ergoptiplus.app",
				"XPC_SERVICE_NAME": "application.com.ergoptiplus.app.123",
				"UNRELATED": "preserved",
			],
			launcherPid: 4242,
			launcherBundleId: "com.ergoptiplus.app"
		)

		XCTAssertNil(environment["__CFBundleIdentifier"])
		XCTAssertNil(environment["XPC_SERVICE_NAME"])
		XCTAssertEqual(environment["UNRELATED"], "preserved")
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
		let loggerWorker = TestLoggerDatagramServer()
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { process in childEnvironment = process.environment ?? [:] },
			loggerWorkerFactory: { loggerWorker }
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

	/// paths.toml must survive app replacement and remain writable in /Applications.
	func testManagedBootstrapPathIsOutsideTheBundleAndExported() {
		XCTAssertEqual(
			managedPathsFile(homeDirectory: "/Users/test"),
			"/Users/test/Library/Application Support/ErgoptiPlus/paths.toml"
		)

		var childEnvironment: [String: String] = [:]
		let loggerWorker = TestLoggerDatagramServer()
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { process in childEnvironment = process.environment ?? [:] },
			loggerWorkerFactory: { loggerWorker }
		)
		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		let exported = childEnvironment["ERGOPTI_PATHS_FILE"]
		XCTAssertEqual(exported, managedPathsFile())
		XCTAssertFalse(exported?.contains(".app/Contents/") ?? true,
			"the managed bootstrap must never resolve inside signed app resources")
	}

	/// The composed startup cannot create the child before registration resolves.
	func testManagedHammerspoonWaitsForGuardianRegistrationResultBeforeChildStart() {
		let entered = DispatchSemaphore(value: 0)
		let release = DispatchSemaphore(value: 0)
		let childStarted = expectation(description: "managed Hammerspoon child started")
		let stateLock = NSLock()
		var childStartCount = 0
		var childEnvironment: [String: String] = [:]
		let loggerWorker = TestLoggerDatagramServer()
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
			},
			loggerWorkerFactory: { loggerWorker }
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

	/// A bound endpoint replaces inherited credentials before the child runner fires.
	func testNativeLoggerEndpointIsBoundAndExportedBeforeChildStart() {
		let loggerWorker = TestLoggerDatagramServer(port: 42_424, token: "fresh-token")
		var factoryCallCount = 0
		var childEnvironment: [String: String] = [:]
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { process in
				XCTAssertEqual(factoryCallCount, 1)
				childEnvironment = process.environment ?? [:]
			},
			loggerWorkerFactory: {
				factoryCallCount += 1
				return loggerWorker
			}
		)

		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		XCTAssertEqual(childEnvironment["ERGOPTI_LOG_PORT"], "42424")
		XCTAssertEqual(childEnvironment["ERGOPTI_LOG_TOKEN"], "fresh-token")
	}

	/// No input runtime may start when the native sink could not bind its socket.
	func testMissingNativeLoggerFailsBeforeChildStart() {
		var childStartCount = 0
		var fatalMessages: [String] = []
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { _ in childStartCount += 1 },
			fatalReporter: { fatalMessages.append($0) },
			loggerWorkerFactory: { nil }
		)

		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		XCTAssertEqual(childStartCount, 0)
		XCTAssertEqual(
			fatalMessages,
			["Native Hammerspoon logger transport could not be started."]
		)
	}

	/// AppKit teardown explicitly cancels the exact pre-bound logger authority.
	func testApplicationTerminationStopsTheOwnedNativeLogger() {
		let loggerWorker = TestLoggerDatagramServer()
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { _ in },
			loggerWorkerFactory: { loggerWorker }
		)
		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		delegate.applicationWillTerminate(Notification(name: Notification.Name(
			"test-termination"
		)))

		XCTAssertEqual(loggerWorker.stopCount, 1)
	}

	/// A refused child start rolls back the already-bound logger authority exactly.
	func testChildLaunchFailureStopsThePreboundNativeLogger() {
		let loggerWorker = TestLoggerDatagramServer()
		var fatalMessages: [String] = []
		let delegate = AppDelegate(
			launcherIdentityReader: { _ in (device: "11", inode: "22") },
			processRunner: { _ in
				throw NSError(domain: "test-launch", code: 17)
			},
			fatalReporter: { fatalMessages.append($0) },
			loggerWorkerFactory: { loggerWorker }
		)

		delegate.launchHammerspoon(at: "/tmp/embedded-hammerspoon")

		XCTAssertEqual(loggerWorker.stopCount, 1)
		XCTAssertEqual(fatalMessages.count, 1)
		XCTAssertTrue(fatalMessages[0].hasPrefix("Failed to launch embedded Hammerspoon:"))
	}

	/// A runtime emergency remains visible after Hammerspoon can no longer alert.
	func testNonzeroEmbeddedHammerspoonExitUsesFatalLauncherUI() {
		var fatalMessages: [String] = []
		var cleanTerminationCount = 0
		let delegate = AppDelegate(
			fatalReporter: { fatalMessages.append($0) },
			applicationTerminator: { _ in cleanTerminationCount += 1 }
		)

		delegate.handleEmbeddedHammerspoonExit(status: 17)

		XCTAssertEqual(cleanTerminationCount, 0)
		XCTAssertEqual(fatalMessages, [
			"Embedded Hammerspoon stopped unexpectedly (status 17). "
				+ "ErgoptiPlus remap revocation is being enforced by the independent guardian.",
		])
	}

	/// A deliberate zero-status Hammerspoon quit keeps the fused app lifecycle.
	func testZeroEmbeddedHammerspoonExitTerminatesLauncherNormally() {
		var fatalMessages: [String] = []
		var cleanTerminationCount = 0
		let delegate = AppDelegate(
			fatalReporter: { fatalMessages.append($0) },
			applicationTerminator: { _ in cleanTerminationCount += 1 }
		)

		delegate.handleEmbeddedHammerspoonExit(status: 0)

		XCTAssertEqual(cleanTerminationCount, 1)
		XCTAssertEqual(fatalMessages, [])
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
