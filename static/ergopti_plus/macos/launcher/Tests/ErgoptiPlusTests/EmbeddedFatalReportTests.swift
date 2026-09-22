// Tests/ErgoptiPlusTests/EmbeddedFatalReportTests.swift

// ==============================================================================
// MODULE: Embedded Fatal Report Tests
// DESCRIPTION:
// Proves the launcher reads exactly what adapters/boot_fatal.lua writes and turns
// it into an alert that names the failed stage and the log to read.
//
// FEATURES & RATIONALE:
// 1. Wire format: the three `key=value` lines written by Lua round-trip, and a
//    value containing `=` is kept whole.
// 2. No stage, no report: an empty or truncated file cannot fabricate a cause.
// 3. Alert text: the localized message leads, then stage, bounded cause and
//    launcher.log path, with the documented English pre-i18n fallback.
//
// NOTE: This target requires the macOS Swift toolchain. Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import XCTest
@testable import ErgoptiPlus

final class EmbeddedFatalReportTests: XCTestCase {

	func testParsesTheLuaWireFormat() {
		let report = EmbeddedFatalReport.parse(
			"stage=native_logger_transport\nmessage=Cannot start.\ndetail=refused: a=b\n")
		XCTAssertEqual(report, EmbeddedFatalReport(
			stage: "native_logger_transport",
			message: "Cannot start.",
			detail: "refused: a=b"
		))
	}

	func testMissingStageIsNotAReport() {
		XCTAssertNil(EmbeddedFatalReport.parse(""))
		XCTAssertNil(EmbeddedFatalReport.parse("message=x\ndetail=y\n"))
		XCTAssertNil(EmbeddedFatalReport.parse("stage=\n"))
	}

	func testAlertNamesStageCauseAndLogWithoutACatalog() {
		let report = EmbeddedFatalReport(stage: "accessibility", message: "Allow it.", detail: "refused")
		XCTAssertEqual(
			embeddedFatalAlertText(report, logPath: "/L/launcher.log", localization: nil),
			"Allow it.\n\nStep: accessibility\nCause: refused\nDetails are saved in /L/launcher.log."
		)
	}

	func testAlertBoundsAVeryLongCause() {
		let long = String(repeating: "x", count: kFatalReportAlertDetailLimit + 50)
		let report = EmbeddedFatalReport(stage: "boot", message: "", detail: long)
		let text = embeddedFatalAlertText(report, logPath: "/L", localization: nil)
		XCTAssertFalse(text.contains(long))
		XCTAssertTrue(text.contains(String(repeating: "x", count: kFatalReportAlertDetailLimit) + "…"))
	}

	func testStoreReadsWhatItWasGivenAndClearsIt() throws {
		let path = FileManager.default.temporaryDirectory
			.appendingPathComponent("ergopti-fatal-\(UUID().uuidString).txt").path
		let store = EmbeddedFatalReportStore(path: path)
		XCTAssertTrue(store.clear())
		XCTAssertNil(store.read())
		try "stage=boot\ndetail=d\n".write(toFile: path, atomically: true, encoding: .utf8)
		XCTAssertEqual(store.read()?.stage, "boot")
		XCTAssertTrue(store.clear())
		XCTAssertFalse(FileManager.default.fileExists(atPath: path))
	}
}
