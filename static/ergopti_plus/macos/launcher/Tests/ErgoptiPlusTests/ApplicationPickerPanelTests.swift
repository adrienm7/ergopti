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
		return try String(contentsOf: outputURL, encoding: .utf8)
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
}
