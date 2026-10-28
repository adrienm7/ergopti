// Tests/ErgoptiPlusTests/LuaSourceSelectionTests.swift

// ==============================================================================
// MODULE: Lua Source Selection Tests
// DESCRIPTION:
// Proves where the launcher points the embedded Hammerspoon: the signed
// payload of a packaged app, or the clone recorded by a developer build
// (ERGOPTI_DEV_SOURCE=1), and that a broken developer key refuses the launch
// instead of falling back to the payload.
//
// FEATURES & RATIONALE:
// 1. Packaged default: no key selects Contents/Resources/static/ergopti_plus/macos.
// 2. Developer clone: an absolute root with init.lua selects that clone.
// 3. Fail fast: a non-string, relative, trailing-slash or missing-init.lua key
//    is refused with a reason naming the problem.
// 4. Child authority: the runtime receives the clone root only from a developer
//    build; an inherited value never reaches a packaged runtime.
//
// NOTE: This target requires the macOS Swift toolchain. Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher --filter LuaSourceSelectionTests`.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

final class LuaSourceSelectionTests: XCTestCase {
	private let bundle = "/Applications/\(Identifiers.App.bundle)"
	private let clone = "/Users/maintainer/ergopti"
	private var key: String { Identifiers.DevSource.plistKey }

	func testPackagedBundleReadsItsPayload() {
		let selection = LuaSourceSelection.resolve(
			infoDictionary: ["CFBundleName": "ErgoptiPlus"],
			bundlePath: bundle,
			fileExists: { _ in XCTFail("a packaged app must not probe a clone"); return false }
		)
		XCTAssertEqual(selection, .packaged(configDir: "\(bundle)/Contents/Resources/static/ergopti_plus/macos"))
		XCTAssertNil(selection.developerRoot)
	}

	func testDeveloperBuildReadsTheRecordedClone() {
		var probed: [String] = []
		let selection = LuaSourceSelection.resolve(
			infoDictionary: [key: clone],
			bundlePath: bundle,
			fileExists: { probed.append($0); return true }
		)
		XCTAssertEqual(selection, .developer(root: clone, configDir: "\(clone)/static/ergopti_plus/macos"))
		XCTAssertEqual(probed, ["\(clone)/static/ergopti_plus/macos/init.lua"])
		XCTAssertEqual(selection.developerRoot, clone)
		XCTAssertEqual(selection.configDir, "\(clone)/static/ergopti_plus/macos")
	}

	func testDeveloperCloneWithoutInitLuaIsRefused() {
		let selection = LuaSourceSelection.resolve(
			infoDictionary: [key: clone], bundlePath: bundle, fileExists: { _ in false }
		)
		guard case let .refused(reason) = selection else {
			return XCTFail("a missing clone init.lua must refuse the launch, not run the payload")
		}
		XCTAssertTrue(reason.contains("\(clone)/static/ergopti_plus/macos/init.lua is missing"), reason)
		XCTAssertNil(selection.configDir)
	}

	func testMalformedDeveloperKeysAreRefused() {
		let values: [Any] = [42, "", "/", "relative/ergopti", "\(clone)/", "\(clone)\n", "\(clone)\0"]
		for value in values {
			let selection = LuaSourceSelection.resolve(
				infoDictionary: [key: value], bundlePath: bundle, fileExists: { _ in true }
			)
			guard case let .refused(reason) = selection else {
				XCTFail("developer key \(value) must be refused")
				continue
			}
			XCTAssertTrue(reason.contains(key), reason)
		}
	}

	func testChildReceivesTheCloneRootOnlyFromADeveloperBuild() {
		let inherited = [Identifiers.DevSource.environment: "/tmp/foreign-clone"]
		let packaged = launcherChildEnvironment(base: inherited, launcherPid: 7, launcherBundleId: nil)
		XCTAssertNil(packaged[Identifiers.DevSource.environment])
		let developer = launcherChildEnvironment(
			base: inherited, launcherPid: 7, launcherBundleId: nil, developerSourceRoot: clone
		)
		XCTAssertEqual(developer[Identifiers.DevSource.environment], clone)
	}
}
