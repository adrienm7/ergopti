// Tests/ErgoptiPlusTests/InputSourceAppleScriptTests.swift
//
// Runs the actual Lua selection template against Carbon without enabling or
// disabling sources. Direct Swift Carbon success cannot qualify this bridge.

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

final class InputSourceAppleScriptTests: XCTestCase {
	private struct SourceState: Equatable {
		let currentID: String
		let installedIDs: [String]
		let enabledIDs: [String]
		let selectedIDs: [String]
	}

	private var fixtureCanRetire = true

	private static var repositoryURL: URL {
		var url = URL(fileURLWithPath: #filePath)
		for _ in 0..<7 { url.deleteLastPathComponent() }
		return url
	}

	/// Reads the production template; only its original string slot is interpolated.
	private func selectionScript(identifier: String) throws -> String {
		let source = try String(contentsOf: Self.repositoryURL.appendingPathComponent(
			"static/ergopti_plus/macos/modules/keymap/input_sources.lua"), encoding: .utf8)
		let owner = "local function set_input_source_async(localised_name, kl_name, on_done)"
		guard source.components(separatedBy: owner).count == 2 else {
			XCTFail("The production selection function must have exactly one owner")
			throw CocoaError(.fileReadCorruptFile)
		}
		let start = try XCTUnwrap(source.range(of: owner))
		let ownerAndTail = source[start.upperBound...]
		let finish = try XCTUnwrap(ownerAndTail.range(of: "\nfunction build_kl_name_to_tis_id()"))
		let body = ownerAndTail[..<finish.lowerBound]
		let opening = "text_utils.applescript_format([["
		guard body.components(separatedBy: opening).count == 2 else {
			XCTFail("The production selection function must own exactly one AppleScript template")
			throw CocoaError(.fileReadCorruptFile)
		}
		let templateStart = try XCTUnwrap(body.range(of: opening))
		let templateAndTail = body[templateStart.upperBound...]
		let templateEnd = try XCTUnwrap(templateAndTail.range(of: "]], tis_id)"))
		let slots = templateAndTail[..<templateEnd.lowerBound].components(separatedBy: "%s")
		XCTAssertEqual(slots.count, 2, "The exact selection template has one escaped source identifier")
		guard slots.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
		let escaped = identifier.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
		return slots[0] + escaped + slots[1]
	}

	/// Observes the native inventory independently of the AppleScript result.
	private func sourceState() throws -> SourceState {
		guard Thread.isMainThread else {
			XCTFail("Native source observation must run on the main thread")
			throw CocoaError(.executableRuntimeMismatch)
		}
		let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
		let currentState = KeyboardSourceTestState.read(current)
		guard currentState.enabled.value == true, currentState.selected.value == true else {
			XCTFail("The captured current source must be enabled and selected")
			throw CocoaError(.executableRuntimeMismatch)
		}
		let currentID = try XCTUnwrap(currentState.id.value)
		let sources = TISCreateInputSourceList(nil, true).takeRetainedValue()
		let inventory = try XCTUnwrap(sources as? [TISInputSource])
		var installed: [String] = []
		var enabled: [String] = []
		var selected: [String] = []
		for source in inventory {
			let state = KeyboardSourceTestState.read(source)
			let identifier = try XCTUnwrap(state.id.value)
			installed.append(identifier)
			if state.enabled.value == true { enabled.append(identifier) }
			if state.selected.value == true { selected.append(identifier) }
		}
		return SourceState(currentID: currentID, installedIDs: installed.sorted(),
			enabledIDs: enabled.sorted(), selectedIDs: selected.sorted())
	}

	/// Captures bounded native child execution without blocking on full stdout pipes.
	private func runNative(_ script: String, root: URL) throws -> String {
		let scriptURL = root.appendingPathComponent("selection.applescript")
		let outputURL = root.appendingPathComponent("stdout")
		let errorURL = root.appendingPathComponent("stderr")
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
				XCTFail("The exact input-source AppleScript child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		XCTAssertEqual(process.terminationStatus, 0,
			"The actual Carbon AppleScript must execute: \(String(stderr.prefix(2048)))")
		XCTAssertTrue(stderr.isEmpty, "The actual Carbon AppleScript must emit no errors")
		return try String(contentsOf: outputURL, encoding: .utf8)
	}

	private func withNativeFixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ErgoptiInputSourceAppleScript-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact input-source AppleScript fixture did not retire") }
			}
		}
		try body(root)
	}

	func testActualSelectionTemplateReturnsNativeZeroForAlreadySelectedSource() throws {
		let before = try sourceState()
		try withNativeFixture { root in
			defer {
				do { XCTAssertEqual(try sourceState(), before, "Selecting the current source preserves native state") }
				catch { XCTFail("The post-selection native inventory could not be observed: \(error)") }
			}
			XCTAssertEqual(try runNative(selectionScript(identifier: before.currentID), root: root), "0\n")
		}
	}

	func testActualSelectionTemplateReturnsMissForAbsentSourceWithoutStateChanges() throws {
		let before = try sourceState()
		let identifier = "org.ergopti.native-test.absent." + UUID().uuidString
		// A filtered no-match result can be NULL; prove absence from the full native inventory.
		guard !before.installedIDs.contains(identifier) else {
			XCTFail("The refused source must be genuinely absent")
			throw CocoaError(.executableRuntimeMismatch)
		}
		try withNativeFixture { root in
			defer {
				do { XCTAssertEqual(try sourceState(), before, "An absent source preserves native state") }
				catch { XCTFail("The post-refusal native inventory could not be observed: \(error)") }
			}
			XCTAssertEqual(try runNative(selectionScript(identifier: identifier), root: root), "MISS\n")
		}
	}
}
