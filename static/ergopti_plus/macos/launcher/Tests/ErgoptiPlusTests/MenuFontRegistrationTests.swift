// Tests/ErgoptiPlusTests/MenuFontRegistrationTests.swift

// ==============================================================================
// MODULE: Menu Font Registration Tests
// DESCRIPTION:
// Proves which files the launcher registers so the embedded runtime can draw
// its tray menu in the reading font: the sfnt faces menu_faces.json lists,
// beside the driver tree, for the login session; a relaunch's "already
// registered" is a success, a refusal is reported and never unregistered, and
// a broken manifest names itself.
//
// FEATURES & RATIONALE:
// 1. The real manifest: the repository's menu_faces.json is read from the
//    driver tree, as the packaged app reads its copy, and every face it names
//    exists as a .ttf or .otf file (Core Text cannot register a WOFF2).
// 2. Session scope only through the injected registrar: no test registers a
//    real font.
//
// NOTE: This target requires the macOS Swift toolchain. Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher --filter MenuFontRegistrationTests`.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

final class MenuFontRegistrationTests: XCTestCase {
	/// static/ergopti_plus/macos of this checkout, as LuaSourceSelection names it.
	private var driverDirectory: String {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<4 { url.deleteLastPathComponent() }
		return url.path
	}

	func testFontsDirectorySitsBesideTheDriverTree() {
		let directory = MenuFontRegistration.fontsDirectory(
			configDir: "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos"
		)
		XCTAssertEqual(
			directory.path,
			"/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/_shared/ui/fonts"
		)
	}

	func testRepositoryManifestNamesExistingSfntFaces() throws {
		let directory = MenuFontRegistration.fontsDirectory(configDir: driverDirectory)
		let urls = try MenuFontRegistration.faceURLs(fontsDirectory: directory)
		XCTAssertEqual(urls.count, 2, "one face per non-default reading font")
		for url in urls {
			XCTAssertTrue(["ttf", "otf"].contains(url.pathExtension), "\(url.lastPathComponent) is an sfnt file")
			XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(url.path) ships")
			XCTAssertTrue(url.path.hasPrefix(directory.path + "/"), "\(url.path) stays in the fonts folder")
		}
	}

	func testRelaunchCountsAsRegisteredAndARefusalIsNotHeld() {
		let first = URL(fileURLWithPath: "/fonts/a.ttf")
		let second = URL(fileURLWithPath: "/fonts/b.otf")
		let third = URL(fileURLWithPath: "/fonts/c.ttf")
		var asked: [URL] = []
		let outcomes = MenuFontRegistration.register([first, second, third]) { url in
			asked.append(url)
			if url == first { return (true, nil) }
			if url == second { return (false, MenuFontRegistration.alreadyRegisteredCode) }
			return (false, 104)
		}
		XCTAssertEqual(asked, [first, second, third])
		XCTAssertEqual(outcomes, [.registered(first), .alreadyRegistered(second), .refused(third, code: 104)])
		XCTAssertEqual(MenuFontRegistration.held(outcomes), [first, second], "a refused face is never unregistered")
	}

	func testUnreadableManifestNamesItsPath() {
		let directory = URL(fileURLWithPath: "/missing/fonts", isDirectory: true)
		XCTAssertThrowsError(try MenuFontRegistration.faceURLs(fontsDirectory: directory) { _ in
			throw CocoaError(.fileNoSuchFile)
		}) { error in
			XCTAssertEqual(error as? MenuFontManifestError, .unreadable("/missing/fonts/menu_faces.json"))
		}
	}

	func testMalformedOrEscapingManifestIsRefused() {
		let directory = URL(fileURLWithPath: "/fonts", isDirectory: true)
		for body in [
			"[]",
			#"{"faces": {}}"#,
			#"{"faces": {"dyslexic": {"family": "OpenDyslexic"}}}"#,
			#"{"faces": {"dyslexic": {"file": "/etc/passwd"}}}"#,
			#"{"faces": {"dyslexic": {"file": "../../secret.ttf"}}}"#,
		] {
			XCTAssertThrowsError(try MenuFontRegistration.faceURLs(fontsDirectory: directory) { _ in
				Data(body.utf8)
			}, body) { error in
				XCTAssertEqual(error as? MenuFontManifestError, .malformed("/fonts/menu_faces.json"), body)
			}
		}
	}
}
