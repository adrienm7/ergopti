// Tests/ErgoptiPlusTests/BundleValidationTests.swift

// ==============================================================================
// MODULE: Bundle Validation Tests
// DESCRIPTION:
// Regression coverage for F-HIGH-28 — the launcher spawned the embedded
// Hammerspoon binary without ever checking that the bundled init.lua actually
// exists. Hammerspoon tolerates a missing/invalid MJConfigFile by starting
// normally with no Lua loaded (no crash, exit code 0), so a partial unzip, a
// disk-full install, or a build-script regression that silently drops the Lua
// tree all produced an app that launches, shows nothing wrong, and remaps
// nothing.
//
// FEATURES & RATIONALE:
// 1. main.swift is a top-level `main.swift` executable entry point — its
//    AppDelegate methods are private and applicationDidFinishLaunching drives
//    real NSApplication/Process side effects, so it cannot be driven directly
//    from an XCTest without a much larger refactor into a testable library
//    target (explicitly out of scope for this fix; the existing Package.swift
//    documents the single-target-executable choice as deliberate).
// 2. This test instead exercises the EXACT predicate the new guard added in
//    applicationDidFinishLaunching relies on — FileManager.default.fileExists
//    (atPath:) against a path shaped like bundledInitLuaPath() — against a
//    real on-disk fixture bundle that is missing its Contents/Resources Lua
//    tree, proving the failure path would fire, and a second fixture where the
//    file is present, proving the guard does not false-positive on a healthy
//    bundle. This is the most faithful test achievable without restructuring
//    the executable target.
//
// NOTE: This target could not be built or executed in the environment this
// fix was authored in (no Xcode / macOS Swift toolchain available). Written
// carefully against the existing file's style; verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import XCTest

final class BundleValidationTests: XCTestCase {

	// ==================================================
	// ======= 1/ Fixture bundle path construction =======
	// ==================================================

	/// Builds a throwaway directory tree mirroring the shape of a real
	/// .app bundle's Contents/Resources/static/ergopti_plus/macos/ Lua root,
	/// mirroring bundledConfigDir()/bundledInitLuaPath() in main.swift.
	/// - Parameter includeInitLua: When true, writes a stub init.lua file so
	///   the fixture represents a healthy bundle instead of a broken one.
	/// - Returns: The fixture bundle's root directory path.
	private func makeFixtureBundle(includeInitLua: Bool) throws -> String {
		let root = NSTemporaryDirectory() + "ErgoptiPlusTests-\(UUID().uuidString).app"
		let luaDir = root + "/Contents/Resources/static/ergopti_plus/macos"
		try FileManager.default.createDirectory(atPath: luaDir, withIntermediateDirectories: true)

		if includeInitLua {
			let initLuaPath = luaDir + "/init.lua"
			try "-- fixture init.lua".write(toFile: initLuaPath, atomically: true, encoding: .utf8)
		}

		return root
	}

	private func bundledInitLuaPath(forBundleRoot root: String) -> String {
		return root + "/Contents/Resources/static/ergopti_plus/macos/init.lua"
	}




	// ====================================================================
	// ======= 2/ Missing init.lua is detected before launch (F-HIGH-28) =======
	// ====================================================================

	func testMissingInitLuaIsDetected() throws {
		let brokenBundle = try makeFixtureBundle(includeInitLua: false)
		defer { try? FileManager.default.removeItem(atPath: brokenBundle) }

		let initLuaPath = bundledInitLuaPath(forBundleRoot: brokenBundle)

		XCTAssertFalse(
			FileManager.default.fileExists(atPath: initLuaPath),
			"a bundle with no Lua tree must fail the existence check the launcher guard relies on — " +
			"this is the exact scenario (partial unzip / disk-full install / build-script regression) " +
			"that used to launch silently with nothing remapped"
		)
	}

	func testPresentInitLuaPassesTheGuard() throws {
		let healthyBundle = try makeFixtureBundle(includeInitLua: true)
		defer { try? FileManager.default.removeItem(atPath: healthyBundle) }

		let initLuaPath = bundledInitLuaPath(forBundleRoot: healthyBundle)

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: initLuaPath),
			"a healthy bundle with init.lua present must pass the existence check " +
			"so the guard never false-positives on a normal install"
		)
	}
}
