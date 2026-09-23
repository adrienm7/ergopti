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
// 4. Runtime stops: kind=runtime selects its own title, names the component
//    and lists every log the runtime reported beside launcher.log.
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

	/// A user whose app ran for days was told it "could not start" at "Step:
	/// native_logger". A runtime report now names the component and every log.
	func testRuntimeReportRoundTripsItsKindAndLogs() {
		let report = EmbeddedFatalReport.parse(
			"kind=runtime\nstage=native_logger\nmessage=Stopped.\ndetail=no ACK\n"
				+ "log=/L/ErgoptiPlus_2026-09-22.log\nlog=/L/ErgoptiPlus_errors_2026-09-22.log\n")
		XCTAssertEqual(report, EmbeddedFatalReport(
			kind: .runtime,
			stage: "native_logger",
			message: "Stopped.",
			detail: "no ACK",
			logPaths: ["/L/ErgoptiPlus_2026-09-22.log", "/L/ErgoptiPlus_errors_2026-09-22.log"]
		))
		XCTAssertEqual(report?.diagnostic,
			"Embedded Hammerspoon stopped at runtime in component 'native_logger': no ACK")
	}

	func testRuntimeAlertNamesComponentAndEveryLogWithoutACatalog() {
		let report = EmbeddedFatalReport(
			kind: .runtime,
			stage: "native_logger",
			message: "Stopped.",
			detail: "no ACK",
			logPaths: ["/L/today.log", "/L/errors.log"]
		)
		let text = embeddedFatalAlertText(report, logPath: "/L/launcher.log", localization: nil)
		XCTAssertEqual(text,
			"Stopped.\n\nComponent: native_logger\nCause: no ACK\nDetails are saved in:\n"
				+ "/L/today.log\n/L/errors.log\n/L/launcher.log")
		XCTAssertFalse(text.contains("Step:"))
		XCTAssertEqual(embeddedFatalAlertTitle(report, localization: nil), kFatalRuntimeTitleFallback)
		XCTAssertEqual(
			embeddedFatalAlertTitle(EmbeddedFatalReport(stage: "boot", message: "", detail: ""),
				localization: nil),
			kFatalBootTitleFallback
		)
	}

	func testRuntimeAlertUsesTheBundledCatalogInEveryLanguageShipped() throws {
		let report = EmbeddedFatalReport(
			kind: .runtime, stage: "native_logger", message: "", detail: "no ACK",
			logPaths: ["/L/today.log"])
		let boot = EmbeddedFatalReport(stage: "native_logger", message: "", detail: "no ACK")
		for locale in ["en", "fr"] {
			let localization = try XCTUnwrap(LauncherLocalization.load(
				localesDirectory: Self.localesDirectory,
				storedLocale: locale,
				preferredLanguages: []
			))
			let title = embeddedFatalAlertTitle(report, localization: localization)
			XCTAssertEqual(title, localization.text("launcher.fatal.title_runtime"))
			XCTAssertNotEqual(title, embeddedFatalAlertTitle(boot, localization: localization),
				"\(locale): a runtime stop must not reuse the could-not-start title")
			let text = embeddedFatalAlertText(report, logPath: "/L/launcher.log", localization: localization)
			XCTAssertTrue(text.contains("/L/today.log\n/L/launcher.log"), text)
			XCTAssertFalse(text.contains("{1}") || text.contains("{3}"), text)
		}
	}

	func testUnrecognisedKindIsStillShownAndNamedInTheDiagnostic() {
		let report = EmbeddedFatalReport.parse("kind=later\nstage=x\ndetail=y\n")
		XCTAssertEqual(report?.kind, .boot)
		XCTAssertEqual(report?.diagnostic,
			"Embedded Hammerspoon stopped at boot stage 'x': y (unrecognised report kind 'later')")
	}

	private static let localesDirectory = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../../../_shared/data/locales")
		.standardizedFileURL.path

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
