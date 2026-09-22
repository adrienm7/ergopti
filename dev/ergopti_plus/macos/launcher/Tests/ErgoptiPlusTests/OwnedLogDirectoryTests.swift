// Tests/ErgoptiPlusTests/OwnedLogDirectoryTests.swift

// ==============================================================================
// MODULE: Owned Log Directory Tests
// DESCRIPTION:
// Reproduces the user layouts that version the configuration folder through
// symbolic links, and the refusals that must name their folder and cause.
//
// FEATURES & RATIONALE:
// 1. Layouts A/B/C: a symlinked config root, hammerspoon folder, or logs
//    folder is a user-owned directory and must be accepted end to end.
// 2. A dangling link is refused as such, and its target is never created.
// 3. The refusal reaches the Lua NACK detail and the launcher observer.
// 4. The alert text comes from the bundled shared locale catalog.
// ==============================================================================

import Darwin
import Foundation
import XCTest
@testable import ErgoptiPlus

final class OwnedLogDirectoryTests: XCTestCase {





	// ============================================
	// ============================================
	// ======= 1/ Symlinked User Layouts ==========
	// ============================================
	// ============================================

	/// Layout C: <config>/hammerspoon/logs is a link into a versioned folder.
	/// The published launcher refused it with ELOOP (symlinked-config-dir).
	func testSymlinkedLogsFolderIsAcceptedAndWrittenThrough() throws {
		let root = try makeRoot()
		let target = root.appendingPathComponent("gitcfg/logs", isDirectory: true)
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		let logs = root.appendingPathComponent("config/hammerspoon/logs", isDirectory: true)
		try FileManager.default.createDirectory(
			at: logs.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: target)

		let sink = LoggerRecordSink(now: { Self.fixedDate })
		XCTAssertTrue(sink.configure(directoryPath: logs.path, retentionDays: 14),
			String(describing: sink.lastDirectoryFailure))
		XCTAssertNil(sink.lastDirectoryFailure)
		XCTAssertTrue(sink.append(
			line: "through-link",
			variant: "info",
			topics: [],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))
		XCTAssertEqual(
			try String(contentsOf: target.appendingPathComponent("ErgoptiPlus_2026-08-14.log")),
			"through-link\n"
		)
		XCTAssertTrue(try isSymbolicLink(logs), "the user's link must stay a link")
	}

	/// Layout A: ~/.config/ergopti_plus is a link and logs/ is gitignored, so absent.
	func testSymlinkedConfigRootCreatesTheMissingLogsFolderInsideTheTarget() throws {
		let root = try makeRoot()
		let target = root.appendingPathComponent("gitcfg/ergopti_plus", isDirectory: true)
		try FileManager.default.createDirectory(
			at: target.appendingPathComponent("hammerspoon", isDirectory: true),
			withIntermediateDirectories: true
		)
		let config = root.appendingPathComponent("config", isDirectory: true)
		try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)

		let sink = LoggerRecordSink(now: { Self.fixedDate })
		XCTAssertTrue(sink.configure(
			directoryPath: config.appendingPathComponent("hammerspoon/logs").path,
			retentionDays: 14
		), String(describing: sink.lastDirectoryFailure))
		let created = target.appendingPathComponent("hammerspoon/logs").path
		var attributes = stat()
		XCTAssertEqual(Darwin.lstat(created, &attributes), 0)
		XCTAssertEqual(attributes.st_mode & S_IFMT, S_IFDIR)
		XCTAssertEqual(attributes.st_mode & 0o777, 0o700)
	}

	/// Layout B: only the hammerspoon/ subfolder is a link.
	func testSymlinkedDriverFolderIsAccepted() throws {
		let root = try makeRoot()
		let target = root.appendingPathComponent("gitcfg/hammerspoon", isDirectory: true)
		try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
		let config = root.appendingPathComponent("config", isDirectory: true)
		try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(
			at: config.appendingPathComponent("hammerspoon"),
			withDestinationURL: target
		)

		let sink = LoggerRecordSink(now: { Self.fixedDate })
		XCTAssertTrue(sink.configure(
			directoryPath: config.appendingPathComponent("hammerspoon/logs").path,
			retentionDays: 14
		), String(describing: sink.lastDirectoryFailure))
		XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("logs").path))
	}

	/// A source-run driver leaves 0644 logs without locks; they stay appendable.
	func testPreexistingSourceRunLogsAreReused() throws {
		let logs = try makeRoot().appendingPathComponent("logs", isDirectory: true)
		try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
		let unified = logs.appendingPathComponent("ErgoptiPlus_2026-08-14.log")
		try Data("source-run\n".utf8).write(to: unified)
		XCTAssertEqual(Darwin.chmod(unified.path, 0o644), 0)

		let sink = LoggerRecordSink(now: { Self.fixedDate })
		XCTAssertTrue(sink.configure(directoryPath: logs.path, retentionDays: 14))
		XCTAssertTrue(sink.append(
			line: "launcher-run",
			variant: "info",
			topics: [],
			calendarDate: "2026-08-14",
			operationId: "session-a:1"
		))
		XCTAssertEqual(try String(contentsOf: unified), "source-run\nlauncher-run\n")
	}





	// ============================================
	// ============================================
	// ======= 2/ Named Refusals ==================
	// ============================================
	// ============================================

	func testDanglingLogsLinkIsRefusedAndItsTargetIsNeverCreated() throws {
		let root = try makeRoot()
		let missing = root.appendingPathComponent("gitcfg/missing-logs", isDirectory: true)
		let logs = root.appendingPathComponent("config/hammerspoon/logs", isDirectory: true)
		try FileManager.default.createDirectory(
			at: logs.deletingLastPathComponent(),
			withIntermediateDirectories: true
		)
		try FileManager.default.createSymbolicLink(at: logs, withDestinationURL: missing)

		let sink = LoggerRecordSink(now: { Self.fixedDate })
		XCTAssertFalse(sink.configure(directoryPath: logs.path, retentionDays: 14))
		XCTAssertEqual(sink.lastDirectoryFailure, LogDirectoryFailure(
			path: logs.path,
			refusal: .danglingSymlink(link: logs.path)
		))
		XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
		XCTAssertTrue(sink.lastDirectoryFailure?.diagnostic.contains("symbolic link") == true)
	}

	func testDanglingAncestorLinkNamesTheAncestor() throws {
		let root = try makeRoot()
		let config = root.appendingPathComponent("config", isDirectory: true)
		try FileManager.default.createSymbolicLink(
			at: config,
			withDestinationURL: root.appendingPathComponent("gone", isDirectory: true)
		)
		let failure = try XCTUnwrap(failureOf(config.appendingPathComponent("hammerspoon/logs").path))
		XCTAssertEqual(failure.refusal, .danglingSymlink(link: config.path))
	}

	func testRegularFileInPlaceOfTheFolderIsNotADirectory() throws {
		let root = try makeRoot()
		let file = root.appendingPathComponent("logs")
		try Data().write(to: file)
		XCTAssertEqual(try XCTUnwrap(failureOf(file.path)).refusal, .notDirectory)
	}

	func testRelativePathIsInvalid() {
		XCTAssertEqual(failureOf("relative/logs")?.refusal, .invalidPath)
	}

	/// The late-swap defence rests on O_NOFOLLOW_ANY refusing any symlink
	/// component; prove the imported flag has that kernel meaning.
	func testNoFollowAnyRefusesAnIntermediateLink() throws {
		let root = try makeRoot()
		let real = root.appendingPathComponent("real/inner", isDirectory: true)
		try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
		let link = root.appendingPathComponent("link")
		try FileManager.default.createSymbolicLink(
			at: link,
			withDestinationURL: real.deletingLastPathComponent()
		)
		let descriptor = Darwin.open(
			link.appendingPathComponent("inner").path,
			O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY
		)
		let openError = errno
		if descriptor >= 0 { Darwin.close(descriptor) }
		XCTAssertLessThan(descriptor, 0)
		XCTAssertEqual(openError, ELOOP)
	}

	func testProcessorNamesTheRefusalInTheNackAndReportsIt() throws {
		let root = try makeRoot()
		let logs = root.appendingPathComponent("logs")
		try FileManager.default.createSymbolicLink(
			at: logs,
			withDestinationURL: root.appendingPathComponent("absent")
		)
		var reported: [LogDirectoryFailure] = []
		let processor = LoggerDatagramProcessor(token: "secret", sink: LoggerRecordSink(now: { Self.fixedDate }))
		processor.configureRefusalHandler = { reported.append($0) }
		let payload = try JSONSerialization.data(withJSONObject: [
			"v": 1,
			"token": "secret",
			"kind": "configure",
			"session": "session-a",
			"sequence": 0,
			"log_dir": logs.path,
			"retention_days": 14,
		])
		let data = try XCTUnwrap(processor.handle(payload, sourceIsLoopback: true))
		let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		XCTAssertEqual(response["kind"] as? String, "nack")
		XCTAssertEqual(response["reason"] as? String, "configure_failed")
		let detail = try XCTUnwrap(response["detail"] as? String)
		XCTAssertTrue(detail.contains(logs.path) && detail.contains("symbolic link"), detail)
		XCTAssertEqual(reported.map(\.refusal), [.danglingSymlink(link: logs.path)])
	}





	// ============================================
	// ============================================
	// ======= 3/ Localized Alert =================
	// ============================================
	// ============================================

	func testEveryRefusalHasALocalizedAlertInTheSharedCatalog() throws {
		let refusals: [LogDirectoryRefusal] = [
			.invalidPath, .danglingSymlink(link: "/l"), .accessDenied(errorCode: EPERM),
			.notDirectory, .notOwned(resolvedPath: "/r"), .cannotCreate(errorCode: EROFS),
			.cannotSetPermissions(errorCode: EPERM), .unavailable(errorCode: EIO),
		]
		for locale in ["en", "fr"] {
			let localization = try XCTUnwrap(LauncherLocalization.load(
				localesDirectory: Self.localesDirectory,
				storedLocale: locale,
				preferredLanguages: []
			))
			XCTAssertEqual(localization.localeCode, locale)
			XCTAssertNotNil(localization.text("launcher.fatal.title"))
			XCTAssertNotNil(localization.text("launcher.fatal.quit"))
			for refusal in refusals {
				let failure = LogDirectoryFailure(path: "/Users/u/logs", refusal: refusal)
				let text = try XCTUnwrap(logFolderRefusalAlertText(failure, localization: localization),
					"\(locale) lacks \(refusal.localizationKey)")
				XCTAssertTrue(text.contains("/Users/u/logs"), text)
				XCTAssertFalse(text.contains("{1}") || text.contains("{2}"), text)
			}
		}
	}

	func testLocaleChoiceFollowsTheDriverThenTheSystemThenEnglish() throws {
		let directory = Self.localesDirectory
		XCTAssertEqual(LauncherLocalization.load(localesDirectory: directory,
			storedLocale: "de", preferredLanguages: ["fr-FR"])?.localeCode, "de")
		XCTAssertEqual(LauncherLocalization.load(localesDirectory: directory,
			storedLocale: nil, preferredLanguages: ["fr-FR"])?.localeCode, "fr")
		XCTAssertEqual(LauncherLocalization.load(localesDirectory: directory,
			storedLocale: "xx", preferredLanguages: ["qq-QQ"])?.localeCode, "en")
		XCTAssertNil(LauncherLocalization.load(localesDirectory: "/nonexistent",
			storedLocale: nil, preferredLanguages: []))
	}





	// ============================================
	// ============================================
	// ======= 4/ Fixtures ========================
	// ============================================
	// ============================================

	private static let fixedDate: Date = {
		var calendar = Calendar(identifier: .gregorian)
		calendar.timeZone = .current
		return calendar.date(from: DateComponents(year: 2026, month: 8, day: 14, hour: 12))!
	}()

	private static let localesDirectory = URL(fileURLWithPath: #filePath)
		.deletingLastPathComponent()
		.appendingPathComponent("../../../../_shared/data/locales")
		.standardizedFileURL.path

	private func makeRoot() throws -> URL {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ergopti-owned-log-\(UUID().uuidString)",
			isDirectory: true
		)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		addTeardownBlock { try? FileManager.default.removeItem(at: root) }
		return root
	}

	private func failureOf(_ path: String) -> LogDirectoryFailure? {
		switch OwnedLogDirectoryResolver.open(path) {
		case let .success(directory):
			Darwin.close(directory.descriptor)
			return nil
		case let .failure(failure):
			return failure
		}
	}

	private func isSymbolicLink(_ url: URL) throws -> Bool {
		let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
		return values.isSymbolicLink == true
	}
}
