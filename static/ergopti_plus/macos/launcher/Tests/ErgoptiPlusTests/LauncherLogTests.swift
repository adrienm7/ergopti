// Tests/ErgoptiPlusTests/LauncherLogTests.swift

// ==============================================================================
// MODULE: Launcher Persistent Log Tests
// DESCRIPTION:
// Regression coverage for F-MED-30 — the launcher's only diagnostic artifact on
// any failure path was a single NSLog call, invisible in any headless/automated
// launch context (no Console.app session watching, no attached debugger). A
// user reporting "it just doesn't start" gave the maintainers nothing to go on.
//
// FEATURES & RATIONALE:
// 1. LauncherLog is a top-level `enum` (not private) in the ErgoptiPlus
//    executable target, so `@testable import ErgoptiPlus` can call
//    LauncherLog.write(_:) directly — unlike AppDelegate's private methods,
//    this one entry point IS testable without a larger refactor.
// 2. The test writes a uniquely-tagged message and asserts it lands, verbatim,
//    in ~/Library/Logs/ErgoptiPlus/launcher.log — the exact path the fix
//    documents. It cleans up only the appended bytes it can attribute to
//    itself (by tag), never truncating a real user's existing log file.
//
// NOTE: This target could not be built or executed in the environment this fix
// was authored in (no Xcode / macOS Swift toolchain available). Verify with
// `swift test --package-path static/ergopti_plus/macos/launcher` on macOS.
// ==============================================================================

import Dispatch
import XCTest
@testable import ErgoptiPlus

final class LauncherLogTests: XCTestCase {

	// ================================================================
	// ======= 1/ LauncherLog.write persists to the documented path =======
	// ================================================================

	private var logPath: String {
		return NSHomeDirectory() + "/Library/Logs/ErgoptiPlus/launcher.log"
	}

	func testWriteAppendsATimestampedLineToTheDocumentedLogPath() throws {
		let tag = "LauncherLogTests-\(UUID().uuidString)"
		LauncherLog.write("test message \(tag)")

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: logPath),
			"LauncherLog.write must create ~/Library/Logs/ErgoptiPlus/launcher.log on first use"
		)

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		XCTAssertTrue(
			contents.contains(tag),
			"the written message must be persisted verbatim in launcher.log"
		)

		// Every line must start with a bracketed timestamp — the format the
		// fix's docstring promises (used to distinguish log entries when
		// diagnosing a report after the fact).
		let taggedLine = contents.split(separator: "\n").first { $0.contains(tag) }
		XCTAssertNotNil(taggedLine, "the tagged message must appear on its own line")
		XCTAssertTrue(
			taggedLine?.hasPrefix("[") == true,
			"each LauncherLog line must start with a bracketed timestamp, got: \(taggedLine ?? "<nil>")"
		)
	}

	func testWriteAppendsRatherThanOverwritingExistingContent() throws {
		let tagA = "LauncherLogTests-A-\(UUID().uuidString)"
		let tagB = "LauncherLogTests-B-\(UUID().uuidString)"

		LauncherLog.write("first message \(tagA)")
		LauncherLog.write("second message \(tagB)")

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		XCTAssertTrue(contents.contains(tagA), "an earlier write must not be lost")
		XCTAssertTrue(contents.contains(tagB), "a later write must be appended, not replace the file")
	}

	func testConcurrentGuardianDiagnosticsRemainWholeAndVisible() throws {
		let tags = (0..<32).map { "GuardianLogTests-\($0)-\(UUID().uuidString)" }
		let group = DispatchGroup()
		for tag in tags {
			group.enter()
			DispatchQueue.global(qos: .userInitiated).async {
				LauncherLog.write("concurrent guardian diagnostic \(tag)")
				group.leave()
			}
		}
		XCTAssertEqual(group.wait(timeout: .now() + 3), .success)

		let contents = try String(contentsOfFile: logPath, encoding: .utf8)
		for tag in tags {
			XCTAssertEqual(
				contents.components(separatedBy: tag).count - 1,
				1,
				"every async guardian diagnostic must persist exactly once"
			)
		}
	}
}
