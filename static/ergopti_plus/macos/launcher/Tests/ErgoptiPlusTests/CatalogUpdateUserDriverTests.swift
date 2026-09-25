// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/CatalogUpdateUserDriverTests.swift
//
// The in-app updater used Sparkle's standard interface: English windows, and
// the "has been downloaded, install it?" prompt the user reported. These tests
// pin the catalog-localized driver that replaced it: every locale carries every
// update text, a found update is only offered (Sparkle downloads after Install
// alone), and Sparkle's own English error text never reaches the user.

import AppKit
import Foundation
import Sparkle
import XCTest
@testable import ErgoptiPlus

@MainActor
final class CatalogUpdateUserDriverTests: XCTestCase {
	private final class RecordingPresenter: UpdatePromptPresenting {
		var prompts: [(prompt: UpdatePrompt, activate: Bool)] = []
		var choiceHandlers: [(Int?) -> Void] = []
		var progress: [UpdateProgressText] = []
		var closeAllCount = 0
		var bringToFrontCount = 0

		func present(_ prompt: UpdatePrompt, activate: Bool, onChoice: @escaping (Int?) -> Void) {
			prompts.append((prompt, activate))
			choiceHandlers.append(onChoice)
		}

		func showProgress(_ text: UpdateProgressText, fraction: Double?, onCancel: (() -> Void)?) {
			progress.append(text)
		}

		func bringToFront() {
			bringToFrontCount += 1
		}

		func closeAll() {
			closeAllCount += 1
		}
	}

	/// static/ergopti_plus/_shared/data/locales, found from this file.
	private static let localesDirectory: String = {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<5 {
			url.deleteLastPathComponent()
		}
		return url.appendingPathComponent("_shared/data/locales").path
	}()

	private static func localization(_ code: String) throws -> LauncherLocalization {
		let loaded = try XCTUnwrap(LauncherLocalization.load(
			localesDirectory: localesDirectory,
			storedLocale: code,
			preferredLanguages: []))
		XCTAssertEqual(loaded.localeCode, code, "the \(code) catalog must load itself, not a fallback")
		return loaded
	}

	private static func localeCodes() throws -> [String] {
		let orderPath = URL(fileURLWithPath: localesDirectory)
			.deletingLastPathComponent()
			.appendingPathComponent("locale_order.json")
		let data = try Data(contentsOf: orderPath)
		let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
		return try XCTUnwrap(object["order"] as? [String])
	}

	private static func placeholders(_ text: String) -> Set<String> {
		let pattern = try! NSRegularExpression(pattern: "\\{[0-9]+\\}")
		let range = NSRange(text.startIndex..., in: text)
		return Set(pattern.matches(in: text, range: range).compactMap {
			Range($0.range, in: text).map { String(text[$0]) }
		})
	}

	private func makeDriver(
		_ code: String,
		presenter: RecordingPresenter
	) throws -> (CatalogUpdateUserDriver, LauncherLocalization) {
		let catalog = try Self.localization(code)
		let driver = CatalogUpdateUserDriver(
			textsProvider: { UpdatePromptTexts(localization: catalog) },
			presenter: presenter,
			currentVersion: { "0.0.0-dev.7" },
			log: { _ in })
		return (driver, catalog)
	}

	func testEveryLocaleCarriesEveryUpdateText() throws {
		let codes = try Self.localeCodes()
		XCTAssertEqual(codes.count, 21, "the update flow must speak every supported language")
		let english = try Self.localization("en")
		for code in codes {
			let catalog = try Self.localization(code)
			XCTAssertNotNil(UpdatePromptTexts(localization: catalog),
				"\(code) must define every update text, or the prompt could not be shown")
			for key in UpdatePromptTexts.requiredKeys {
				let text = try XCTUnwrap(catalog.text(key), "\(code) lacks \(key)")
				let reference = try XCTUnwrap(english.text(key))
				XCTAssertEqual(Self.placeholders(text), Self.placeholders(reference),
					"\(code) \(key) must keep the English placeholders")
			}
		}
	}

	func testFoundUpdateIsOfferedInTheUserLanguageAndDownloadsOnlyOnInstall() throws {
		let presenter = RecordingPresenter()
		let (driver, french) = try makeDriver("fr", presenter: presenter)
		var replies: [SPUUserUpdateChoice] = []

		driver.presentUpdateFound(
			version: "0.0.0-dev.140", stage: .notDownloaded,
			userInitiated: false, informationOnly: false) { replies.append($0) }

		let shown = try XCTUnwrap(presenter.prompts.first)
		XCTAssertEqual(shown.prompt.title, french.text("updater.title_update_available"))
		XCTAssertEqual(shown.prompt.message, french.text("updater.update_found_body", ["0.0.0-dev.140"]))
		XCTAssertEqual(shown.prompt.buttons, [
			try XCTUnwrap(french.text("updater.update_dialog_install")),
			try XCTUnwrap(french.text("updater.update_dialog_later")),
			try XCTUnwrap(french.text("updater.skip_version")),
		])
		XCTAssertFalse(shown.activate, "a scheduled check must not steal focus")
		XCTAssertTrue(replies.isEmpty, "nothing is downloaded before the user answers")

		presenter.choiceHandlers[0](0)
		presenter.choiceHandlers[0](0)
		XCTAssertEqual(replies, [.install], "Install answers once, and only Install downloads")
	}

	func testClosingOrLaterNeverDownloads() throws {
		let presenter = RecordingPresenter()
		let (driver, _) = try makeDriver("de", presenter: presenter)
		var replies: [SPUUserUpdateChoice] = []
		// Sparkle keeps one offer outstanding at a time: each is answered first.
		driver.presentUpdateFound(version: "2", stage: .notDownloaded, userInitiated: true, informationOnly: false) {
			replies.append($0)
		}
		presenter.choiceHandlers[0](nil)
		driver.presentUpdateFound(version: "2", stage: .notDownloaded, userInitiated: true, informationOnly: false) {
			replies.append($0)
		}
		presenter.choiceHandlers[1](1)
		XCTAssertEqual(replies, [.dismiss, .dismiss], "closing the window and Later both leave the update unfetched")
		XCTAssertTrue(presenter.prompts[0].activate, "a check the user asked for comes to the front")
	}

	func testStagedUpdateOffersRestartOrInstallOnQuit() throws {
		let presenter = RecordingPresenter()
		let (driver, catalog) = try makeDriver("ja", presenter: presenter)
		var replies: [SPUUserUpdateChoice] = []
		driver.presentUpdateFound(version: "3", stage: .installing, userInitiated: true, informationOnly: false) {
			replies.append($0)
		}
		XCTAssertEqual(presenter.prompts[0].prompt.buttons, [
			try XCTUnwrap(catalog.text("updater.install_and_restart")),
			try XCTUnwrap(catalog.text("updater.install_on_quit")),
		])
		presenter.choiceHandlers[0](1)
		XCTAssertEqual(replies, [.dismiss], "install-on-quit keeps the staged update without relaunching")
	}

	func testDismissDropsPendingRepliesWithoutAnswering() throws {
		let presenter = RecordingPresenter()
		let (driver, _) = try makeDriver("en", presenter: presenter)
		var replies: [SPUUserUpdateChoice] = []
		driver.presentUpdateFound(version: "4", stage: .notDownloaded, userInitiated: true, informationOnly: false) {
			replies.append($0)
		}
		driver.dismissUpdateInstallation()
		presenter.choiceHandlers[0](0)
		XCTAssertEqual(presenter.closeAllCount, 1)
		XCTAssertTrue(replies.isEmpty, "a dismissed session must never be answered")
	}

	func testNoticesAreAcknowledgedOnlyWhenClosed() throws {
		let presenter = RecordingPresenter()
		let (driver, catalog) = try makeDriver("es", presenter: presenter)
		var acknowledgements = 0
		driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))) {
			acknowledgements += 1
		}
		XCTAssertEqual(presenter.prompts[0].prompt.message, catalog.text("updater.up_to_date", ["0.0.0-dev.7"]))
		XCTAssertEqual(acknowledgements, 0,
			"acknowledging ends Sparkle's session, which would close the notice at once")
		presenter.choiceHandlers[0](nil)
		XCTAssertEqual(acknowledgements, 1)
	}

	func testErrorsNeverShowSparkleText() throws {
		let presenter = RecordingPresenter()
		let (driver, catalog) = try makeDriver("fr", presenter: presenter)
		let cases: [(Int, String)] = [
			(Int(SUError.downloadError.rawValue), "updater.no_connection"),
			(Int(SUError.runningTranslocated.rawValue), "updater.move_to_applications"),
			(Int(SUError.signatureError.rawValue), "updater.install_error"),
		]
		for (index, entry) in cases.enumerated() {
			let error = NSError(domain: SUSparkleErrorDomain, code: entry.0,
				userInfo: [NSLocalizedDescriptionKey: "Sparkle English description"])
			driver.showUpdaterError(error) {}
			let shown = presenter.prompts[index].prompt
			XCTAssertEqual(shown.message, catalog.text(entry.1))
			XCTAssertFalse(shown.message.contains("Sparkle English"))
		}
	}

	func testExtractionReplacesTheCancellableDownloadWindow() throws {
		let presenter = RecordingPresenter()
		let (driver, _) = try makeDriver("en", presenter: presenter)
		driver.showDownloadInitiated {}
		XCTAssertNotNil(presenter.progress.last?.cancelTitle, "a download can be cancelled")
		let closesBefore = presenter.closeAllCount
		driver.showDownloadDidStartExtractingUpdate()
		XCTAssertEqual(presenter.closeAllCount, closesBefore + 1,
			"the download window and its Cancel button must go once cancelling is over")
		XCTAssertNil(presenter.progress.last?.cancelTitle, "installing cannot be cancelled")
	}

	func testUnreadableCatalogDismissesInsteadOfShowingEnglish() {
		let presenter = RecordingPresenter()
		let driver = CatalogUpdateUserDriver(
			textsProvider: { nil }, presenter: presenter,
			currentVersion: { "1" }, log: { _ in })
		var replies: [SPUUserUpdateChoice] = []
		driver.presentUpdateFound(version: "5", stage: .notDownloaded, userInitiated: true, informationOnly: false) {
			replies.append($0)
		}
		XCTAssertEqual(replies, [.dismiss])
		XCTAssertTrue(presenter.prompts.isEmpty)
	}

	/// Holds a value written by a @Sendable reply, which cannot mutate a local.
	private final class ResponseBox: @unchecked Sendable {
		var response: SUUpdatePermissionResponse?
	}

	func testPermissionAnswerNeverEnablesAutomaticDownloads() throws {
		let presenter = RecordingPresenter()
		let (driver, _) = try makeDriver("en", presenter: presenter)
		let box = ResponseBox()
		driver.show(SPUUpdatePermissionRequest(systemProfile: [])) { box.response = $0 }
		let response = try XCTUnwrap(box.response)
		XCTAssertTrue(response.automaticUpdateChecks)
		XCTAssertNotEqual(response.automaticUpdateDownloading?.boolValue, true)
	}

	func testPanelOpensAndClosesWithoutReportingAChoice() {
		_ = NSApplication.shared
		let panel = UpdatePromptPanel()
		var choices: [Int?] = []
		panel.present(UpdatePrompt(title: "t", message: "m", buttons: ["a", "b"]), activate: false) {
			choices.append($0)
		}
		panel.showProgress(UpdateProgressText(title: "t", message: "p", cancelTitle: "c"), fraction: 0.5) {}
		panel.showProgress(UpdateProgressText(title: "t", message: "q", cancelTitle: "c"), fraction: nil) {}
		panel.bringToFront()
		panel.closeAll()
		panel.closeAll()
		XCTAssertTrue(choices.isEmpty, "replacing or closing a window programmatically reports no choice")
	}
}
