// static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ApplicationPickerPanelTests.swift
//
// Runs the actual Lua panel-construction template against native AppKit.
// This does not open a modal or claim a completed Hammerspoon user selection.

import Foundation
import XCTest
@testable import ErgoptiPlus

final class ApplicationPickerPanelTests: XCTestCase {
	private var fixtureCanRetire = true

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	/// Interpolates only original template slots, so inserted percent signs stay data.
	private func constructionScript(title: String, message: String) throws -> String {
		let source = try String(contentsOf: Self.repositoryURL.appendingPathComponent(
			"static/ergopti_plus/macos/infra/dialog_util.lua"), encoding: .utf8)
		let owner = try XCTUnwrap(source.range(of: "function M.application_picker_script(message, title)"))
		let body = source[owner.upperBound...]
		let start = try XCTUnwrap(body.range(of: "text_utils.applescript_format([["))
		let templateAndTail = body[start.upperBound...]
		let end = try XCTUnwrap(templateAndTail.range(of: "]], WindowTitles.compose(title), message, APPLICATIONS_DIR)"))
		let template = String(templateAndTail[..<end.lowerBound])
		let slots = template.components(separatedBy: "%s")
		XCTAssertEqual(slots.count, 4, "The actual owner has exactly three escaped inputs")
		guard slots.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
		let values = [WindowTitles.compose(title), message, "/Applications"].map(escape)
		var script = slots[0]
		for index in 0..<3 { script += values[index] + slots[index + 1] }
		let modal = try XCTUnwrap(script.range(of: "set response to panel's runModal()"))
		// The real construction prefix is executed; independent assertions inspect its panel.
		return String(script[..<modal.lowerBound]) + """
		if (panel's title() as text) is not "\(escape(WindowTitles.compose(title)))" then error "Caption differs"
		if (panel's message() as text) is not "\(escape(message))" then error "Message differs"
		if (panel's directoryURL()'s |path|() as text) is not "/Applications" then error "Directory differs"
		if (panel's canChooseFiles() as boolean) is not true then error "Files refused"
		if (panel's canChooseDirectories() as boolean) is not false then error "Directories admitted"
		if (panel's allowsMultipleSelection() as boolean) is not false then error "Multiple selection admitted"
		if (panel's allowedFileTypes() as list) is not {"app"} then error "Application filter differs"
		if (panel's resolvesAliases() as boolean) is not true then error "Aliases refused"
		return "OK"
		"""
	}

	/// Mirrors the shared AppleScript string boundary without interpreting inserted data.
	private func escape(_ text: String) -> String {
		text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
	}

	private func runNative(_ script: String, root: URL) throws -> String {
		let scriptURL = root.appendingPathComponent(UUID().uuidString + ".applescript")
		let outputURL = root.appendingPathComponent(UUID().uuidString + ".stdout")
		let errorURL = root.appendingPathComponent(UUID().uuidString + ".stderr")
		try script.write(to: scriptURL, atomically: true, encoding: .utf8)
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
		process.arguments = [scriptURL.path]
		process.environment = NativeFixtureChildEnvironment.make()
		process.standardOutput = output
		process.standardError = errors
		let completed = DispatchSemaphore(value: 0)
		process.terminationHandler = { _ in completed.signal() }
		try process.run()
		guard completed.wait(timeout: .now() + 10) == .success else {
			if process.isRunning { process.terminate() }
			if completed.wait(timeout: .now() + 5) != .success {
				fixtureCanRetire = false
				XCTFail("The exact native panel fixture child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		XCTAssertEqual(process.terminationStatus, 0, "The actual AppKit construction must execute")
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		XCTAssertTrue(stderr.isEmpty, "The actual native panel must emit no errors")
		if !stderr.isEmpty {
			var paths = [(errorURL.path, "<owned-stderr>"), (root.path, "<owned-fixture>"),
				(Self.repositoryURL.path, "<checkout>"), (NSHomeDirectory(), "<home>")]
			if let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] {
				paths.append((temporary, "<runner-temp>"))
			}
			print(nativeStandardErrorText(stderr, script: script, paths: paths))
			let retained = try retainNativeStandardError(errorURL, bytes: Data(stderr.utf8),
				evidence: nativeEvidenceDirectory())
			let reason = process.terminationReason == .exit ? "exit" : "signal"
			print("APPKIT_PANEL_STDERR bytes=\(stderr.utf8.count) lines=\(stderr.split(separator: "\n").count) termination=\(reason) status=\(process.terminationStatus) artifact=\(retained ? "retained" : "unavailable")")
		}
		return try String(contentsOf: outputURL, encoding: .utf8)
	}

	func testActualApplicationChildEnvironmentPreservesParentAndExecutableSearchPath() throws {
		let inherited = ProcessInfo.processInfo.environment
		let inheritedPath = try XCTUnwrap(inherited["PATH"])
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiApplicationEnvironment-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native application environment fixture did not retire") }
			}
		}
		XCTAssertEqual(try runNative("return (system attribute \"SWIFT_BACKTRACE\")", root: root),
			"enable=no\n", "The actual osascript child disables unsupported crash backtracing")
		XCTAssertEqual(try runNative("return (system attribute \"PATH\")", root: root),
			inheritedPath + "\n", "The actual osascript child preserves executable lookup")
		XCTAssertEqual(ProcessInfo.processInfo.environment, inherited,
			"The parent XCTest environment remains unchanged")
	}

	func testActualApplicationPanelTemplateKeepsCaptionAndSelectionPolicy() throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiApplicationPanel-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native panel fixture did not retire") }
			}
		}
		for title in ["Configure application", "Application \"quoted\" %s C:\\Applications", "配置应用程序 😀"] {
			XCTAssertEqual(try runNative(constructionScript(title: title, message: "Application to open: %s"), root: root), "OK\n")
		}
	}

	/// Exposes only bounded escaped retired-child text, with owned inputs removed.
	private func nativeStandardErrorText(_ stderr: String, script: String,
		paths: [(String, String)]) -> String {
		var privateValues: [String] = []
		var assignmentKinds: Set<String> = []
		for line in script.components(separatedBy: "\n") {
			for prefix in ["panel's setTitle:\"", "panel's setMessage:\""] {
				if line.hasPrefix(prefix), line.hasSuffix("\"") {
					assignmentKinds.insert(prefix)
					let literal = String(line.dropFirst(prefix.count).dropLast())
					privateValues.append(literal)
					privateValues.append(literal.replacingOccurrences(of: "\\\"", with: "\"")
						.replacingOccurrences(of: "\\\\", with: "\\"))
				}
			}
		}
		// Unknown or repeated input assignments cannot authorize raw diagnostic text.
		guard assignmentKinds.count == 2, privateValues.count == 4, !privateValues.contains("") else {
			return "APPKIT_PANEL_STDERR_TEXT bytes=\(stderr.utf8.count) text=<input-redaction-refused>"
		}
		var safe = stderr
		// URLs are removed before any input or path substitution can split a private signed query.
		guard let urls = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s\"'<>]+"#) else {
			return "APPKIT_PANEL_STDERR_TEXT bytes=\(stderr.utf8.count) text=<url-redaction-refused>"
		}
		safe = urls.stringByReplacingMatches(in: safe, range: NSRange(safe.startIndex..., in: safe),
			withTemplate: "<url>")
		for value in privateValues.sorted(by: { $0.count > $1.count }) {
			safe = safe.replacingOccurrences(of: value, with: "<panel-text>")
		}
		for (value, marker) in paths.filter({ !$0.0.isEmpty }).sorted(by: { $0.0.count > $1.0.count }) {
			safe = safe.replacingOccurrences(of: value, with: marker)
		}
		let bytes = Data(safe.utf8)
		var text = String(reflecting: String(decoding: bytes.prefix(2048), as: UTF8.self))
		for (separator, escaped) in [("\u{85}", "\\u{85}"), ("\u{2028}", "\\u{2028}"),
			("\u{2029}", "\\u{2029}")] {
			text = text.replacingOccurrences(of: separator, with: escaped)
		}
		return "APPKIT_PANEL_STDERR_TEXT bytes=\(stderr.utf8.count) truncated=\(bytes.count > 2048) text=\(text)"
	}

	func testNativeStandardErrorTextRemovesExactOwnedPathsPanelInputsAndURLs() {
		let script = "panel's setTitle:\"Private \\\"title\\\"\"\npanel's setMessage:\"Private message %s\""
		let paths = [("/owned/fixture/error.stderr", "<owned-stderr>"), ("/owned/fixture", "<owned-fixture>"),
			("/owned/runner", "<runner-temp>"), ("/owned/checkout", "<checkout>"), ("/owned/home", "<home>")]
		let stderr = "/owned/fixture/error.stderr:17: execution error: Expected identifier\n"
			+ "Private \"title\" Private message %s /owned/runner /owned/checkout /owned/home\n"
			+ "https://example.invalid/owned/fixture?secret=PRIVATE_QUERY\n"
		let packet = nativeStandardErrorText(stderr, script: script, paths: paths)
		XCTAssertTrue(packet.contains("execution error: Expected identifier"))
		for marker in ["<owned-stderr>", "<runner-temp>", "<checkout>", "<home>", "<panel-text>", "<url>"] {
			XCTAssertTrue(packet.contains(marker))
		}
		for hidden in ["/owned/", "Private", "example.invalid", "PRIVATE_QUERY", "secret="] {
			XCTAssertFalse(packet.contains(hidden))
		}
		XCTAssertFalse(packet.contains("<owned-fixture>/error.stderr"), "The deepest owner is removed first")
		let overlappingScript = "panel's setTitle:\"Secret\"\npanel's setMessage:\"Message\""
		let overlap = nativeStandardErrorText("https://private.invalid/Secret?token=PRIVATE_QUERY",
			script: overlappingScript, paths: [])
		XCTAssertTrue(overlap.contains("<url>"))
		for hidden in ["private.invalid", "Secret", "token=", "PRIVATE_QUERY"] {
			XCTAssertFalse(overlap.contains(hidden), "Panel-input URL overlap must not expose the query")
		}
	}

	func testNativeStandardErrorTextBoundsAndEscapesPhysicalLines() {
		let script = "panel's setTitle:\"Fixture title\"\npanel's setMessage:\"Fixture message\""
		let stderr = "quoted \"text\"\n\r\t\0\u{1b}\u{85}\u{2028}\u{2029}😀 "
			+ String(repeating: "A", count: 2048) + "PRIVATE_TAIL"
		let packet = nativeStandardErrorText(stderr, script: script, paths: [])
		XCTAssertTrue(packet.contains("truncated=true"))
		XCTAssertTrue(packet.contains("bytes=\(stderr.utf8.count) "))
		XCTAssertTrue(packet.contains("\\\"text\\\""))
		for separator in ["\n", "\r", "\t", "\0", "\u{1b}", "\u{85}", "\u{2028}", "\u{2029}"] {
			XCTAssertFalse(packet.contains(separator), "Diagnostics remain one escaped physical line")
		}
		XCTAssertFalse(packet.contains("PRIVATE_TAIL"))
		XCTAssertLessThan(packet.utf8.count, 16384)
		let exact = nativeStandardErrorText(String(repeating: "A", count: 2048), script: script, paths: [])
		XCTAssertTrue(exact.contains("truncated=false"))
	}

	func testNativeStandardErrorTextRefusesMissingOrAmbiguousPanelInputs() {
		for script in ["", "panel's setTitle:\"private\"",
			"panel's setTitle:\"private\"\npanel's setTitle:\"other\"",
			"panel's setTitle:\"private\"\npanel's setMessage:\"private\"\npanel's setTitle:\"other\""] {
			let packet = nativeStandardErrorText("PRIVATE_DIAGNOSTIC", script: script, paths: [])
			XCTAssertTrue(packet.contains("text=<input-redaction-refused>"))
			XCTAssertFalse(packet.contains("PRIVATE_DIAGNOSTIC"))
		}
	}

	private enum NativeEvidenceFailure: Error { case refused }

	/// Reuses the existing CI failure artifact owner; a local run may have no owner.
	private func nativeEvidenceDirectory() throws -> URL? {
		guard let temporary = ProcessInfo.processInfo.environment["RUNNER_TEMP"] else { return nil }
		guard temporary.hasPrefix("/") else { throw NativeEvidenceFailure.refused }
		return URL(fileURLWithPath: temporary, isDirectory: true)
			.appendingPathComponent("swift-launcher-evidence", isDirectory: true)
	}

	/// Captures only a retired fixture child's exact regular-file image, never an ambient log.
	private func retainNativeStandardError(_ source: URL, bytes: Data, evidence: URL?) throws -> Bool {
		guard let evidence else { return false }
		guard !bytes.isEmpty, bytes.count <= 65536 else { throw NativeEvidenceFailure.refused }
		do {
			let manager = FileManager.default
			let sourceBefore = try manager.attributesOfItem(atPath: source.path)
			let ownerBefore = try manager.attributesOfItem(atPath: evidence.path)
			guard sourceBefore[.type] as? FileAttributeType == .typeRegular,
				ownerBefore[.type] as? FileAttributeType == .typeDirectory,
				let sourceDevice = sourceBefore[.systemNumber] as? NSNumber,
				let sourceInode = sourceBefore[.systemFileNumber] as? NSNumber,
				let ownerDevice = ownerBefore[.systemNumber] as? NSNumber,
				let ownerInode = ownerBefore[.systemFileNumber] as? NSNumber,
				let sourceSize = sourceBefore[.size] as? NSNumber,
				sourceSize.uint64Value == UInt64(bytes.count),
				try Data(contentsOf: source) == bytes else { throw NativeEvidenceFailure.refused }
			let destination = evidence.appendingPathComponent("application-panel-" + UUID().uuidString + ".stderr")
			// copyItem refuses an existing destination. Its complete result and exact
			// source/owner identities are checked before the evidence is acknowledged.
			try manager.copyItem(at: source, to: destination)
			let sourceAfter = try manager.attributesOfItem(atPath: source.path)
			let ownerAfter = try manager.attributesOfItem(atPath: evidence.path)
			let captured = try manager.attributesOfItem(atPath: destination.path)
			guard sourceAfter[.type] as? FileAttributeType == .typeRegular,
				ownerAfter[.type] as? FileAttributeType == .typeDirectory,
				captured[.type] as? FileAttributeType == .typeRegular,
				let capturedSize = captured[.size] as? NSNumber,
				capturedSize.uint64Value == UInt64(bytes.count),
				sourceAfter[.systemNumber] as? NSNumber == sourceDevice,
				sourceAfter[.systemFileNumber] as? NSNumber == sourceInode,
				ownerAfter[.systemNumber] as? NSNumber == ownerDevice,
				ownerAfter[.systemFileNumber] as? NSNumber == ownerInode,
				try Data(contentsOf: source) == bytes,
				try Data(contentsOf: destination) == bytes else { throw NativeEvidenceFailure.refused }
			return true
		} catch {
			// Native file errors may contain private paths. Only the fixed refusal
			// crosses XCTest; failed or partial artifacts cannot report a valid copy.
			throw NativeEvidenceFailure.refused
		}
	}

	private func withEvidenceFixture(_ body: (URL, URL, URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ErgoptiPanelEvidence-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			do { try FileManager.default.removeItem(at: root) }
			catch { XCTFail("The exact panel evidence fixture did not retire") }
		}
		let source = root.appendingPathComponent("owned.stderr")
		let evidence = root.appendingPathComponent("evidence", isDirectory: true)
		try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: false)
		try body(root, source, evidence)
	}

	func testNativeStandardErrorEvidenceRetainsOnlyExactOwnedBytes() throws {
		try withEvidenceFixture { _, source, evidence in
			let bytes = Data("fixed fixture diagnostic\n".utf8)
			try bytes.write(to: source)
			XCTAssertTrue(try retainNativeStandardError(source, bytes: bytes, evidence: evidence))
			let artifacts = try FileManager.default.contentsOfDirectory(at: evidence,
				includingPropertiesForKeys: nil)
			XCTAssertEqual(artifacts.count, 1)
			XCTAssertTrue(try XCTUnwrap(artifacts.first).lastPathComponent.hasPrefix("application-panel-"))
			XCTAssertEqual(try Data(contentsOf: XCTUnwrap(artifacts.first)), bytes)
			XCTAssertEqual(try Data(contentsOf: source), bytes)
		}
	}

	func testNativeStandardErrorEvidenceRefusesUnknownImagesAndBounds() throws {
		try withEvidenceFixture { _, source, evidence in
			let original = Data("fixed fixture diagnostic\n".utf8)
			try original.write(to: source)
			for bytes in [Data(), Data("foreign image".utf8), Data(repeating: 65, count: 65537)] {
				XCTAssertThrowsError(try retainNativeStandardError(source, bytes: bytes, evidence: evidence))
				XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: evidence.path).isEmpty)
				XCTAssertEqual(try Data(contentsOf: source), original)
			}
			XCTAssertFalse(try retainNativeStandardError(source, bytes: original, evidence: nil))
			XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: evidence.path).isEmpty)
		}
	}

	func testNativeStandardErrorEvidenceRefusesSourceAndOwnerSymlinks() throws {
		try withEvidenceFixture { root, source, evidence in
			let bytes = Data("fixed fixture diagnostic\n".utf8)
			try bytes.write(to: source)
			let linkedSource = root.appendingPathComponent("linked.stderr")
			let linkedOwner = root.appendingPathComponent("linked-owner")
			try FileManager.default.createSymbolicLink(at: linkedSource, withDestinationURL: source)
			try FileManager.default.createSymbolicLink(at: linkedOwner, withDestinationURL: evidence)
			XCTAssertThrowsError(try retainNativeStandardError(linkedSource, bytes: bytes, evidence: evidence))
			XCTAssertThrowsError(try retainNativeStandardError(source, bytes: bytes, evidence: linkedOwner))
			XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: evidence.path).isEmpty)
			XCTAssertEqual(try Data(contentsOf: source), bytes)
		}
	}

}
