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
}
