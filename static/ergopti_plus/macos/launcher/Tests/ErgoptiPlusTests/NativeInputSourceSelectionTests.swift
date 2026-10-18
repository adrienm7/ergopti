// Tests/ErgoptiPlusTests/NativeInputSourceSelectionTests.swift
//
// Runs the actual native launcher roles using the Lua command flags and argv
// order. Real selection and missing-target preflight preserve every source;
// portable Lua tests independently exercise command construction and ownership.

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

final class NativeInputSourceSelectionTests: XCTestCase {
	private struct SourceState: Equatable {
		let currentID: String
		let currentName: String
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

	/// Joins native argv to the actual Lua command flags without copying a script.
	private func commandArguments(upgrade: Bool = false, byName: Bool = false,
		identifiers: [String]) throws -> [String] {
		let source = try String(contentsOf: Self.repositoryURL.appendingPathComponent(
			"static/ergopti_plus/macos/adapters/input_source_selector.lua"), encoding: .utf8)
		let flagName = upgrade ? "UPGRADE_FLAG" : (byName ? "SELECT_BY_NAME_FLAG" : "SELECT_FLAG")
		let declaration = "local " + flagName + " = \""
		guard source.components(separatedBy: declaration).count == 2 else {
			XCTFail("The production command must have exactly one flag owner")
			throw CocoaError(.fileReadCorruptFile)
		}
		let start = try XCTUnwrap(source.range(of: declaration))
		let tail = source[start.upperBound...]
		let end = try XCTUnwrap(tail.firstIndex(of: "\""))
		let flag = String(tail[..<end])
		let expectedFlag = upgrade ? kInputSourceUpgradeFlag
			: (byName ? kInputSourceSelectionByNameFlag : kInputSourceSelectionFlag)
		XCTAssertEqual(flag, expectedFlag)
		if upgrade {
			let owner = try XCTUnwrap(source.range(of: "function M.upgrade(replacements)"))
			let body = source[owner.upperBound...]
			let oldSlot = try XCTUnwrap(body.range(of: "arguments[#arguments + 1] = replacement.old_id"))
			let newSlot = try XCTUnwrap(body.range(of: "arguments[#arguments + 1] = replacement.new_id"))
			XCTAssertLessThan(oldSlot.lowerBound, newSlot.lowerBound)
			XCTAssertTrue(body.contains("return resolve(arguments)"))
		} else if byName {
			XCTAssertTrue(source.contains("return resolve({ SELECT_BY_NAME_FLAG, localised_name, identifier })"))
		} else {
			XCTAssertTrue(source.contains("return resolve({ SELECT_FLAG, identifier })"))
		}
		guard !(upgrade && byName), identifiers.count == ((upgrade || byName) ? 2 : 1) else {
			throw CocoaError(.fileReadCorruptFile)
		}
		return [flag] + identifiers
	}

	/// Finds only the executable built beside this checkout's active SwiftPM tests.
	private func nativeExecutable() throws -> URL {
		let directory = Bundle(for: NativeInputSourceSelectionTests.self).bundleURL.deletingLastPathComponent()
		for candidate in [directory.appendingPathComponent("ErgoptiPlus"),
			directory.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")] {
			if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
		}
		XCTFail("The exact SwiftPM-built native launcher is unavailable")
		throw CocoaError(.executableNotLoadable)
	}

	/// Observes the native inventory independently of the launcher result.
	private func sourceState() throws -> SourceState {
		guard Thread.isMainThread else {
			XCTFail("Native source observation must run on the main thread")
			throw CocoaError(.executableRuntimeMismatch)
		}
		let current = try XCTUnwrap(TISCopyCurrentKeyboardInputSource()).takeRetainedValue()
		let currentState = KeyboardSourceTestState.read(current)
		guard currentState.enabled.value == true, currentState.selected.value == true else {
			XCTFail("The captured current source must be enabled and selected")
			throw CocoaError(.executableRuntimeMismatch)
		}
		let currentID = try XCTUnwrap(currentState.id.value)
		let namePointer = try XCTUnwrap(TISGetInputSourceProperty(current, kTISPropertyLocalizedName))
		let nameObject = Unmanaged<CFTypeRef>.fromOpaque(namePointer).takeUnretainedValue()
		guard CFGetTypeID(nameObject) == CFStringGetTypeID() else {
			throw CocoaError(.fileReadCorruptFile)
		}
		let currentName = Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
		XCTAssertFalse(currentName.isEmpty)
		let sources = try XCTUnwrap(TISCreateInputSourceList(nil, true)).takeRetainedValue()
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
		return SourceState(currentID: currentID, currentName: currentName, installedIDs: installed.sorted(),
			enabledIDs: enabled.sorted(), selectedIDs: selected.sorted())
	}

	/// Captures bounded native child execution without blocking on full stdout pipes.
	private func runNative(_ arguments: [String], root: URL) throws -> String {
		let outputURL = root.appendingPathComponent("stdout")
		let errorURL = root.appendingPathComponent("stderr")
		XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
		XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
		let output = try FileHandle(forWritingTo: outputURL)
		let errors = try FileHandle(forWritingTo: errorURL)
		defer { try? output.close(); try? errors.close() }
		let process = Process()
		process.executableURL = try nativeExecutable()
		process.arguments = arguments
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
				XCTFail("The exact native input-source child did not retire")
			}
			throw CocoaError(.executableRuntimeMismatch)
		}
		XCTAssertEqual(process.terminationReason, .exit)
		let stderr = try String(contentsOf: errorURL, encoding: .utf8)
		XCTAssertEqual(process.terminationStatus, 0,
			"The actual native Carbon command must execute: \(String(stderr.prefix(2048)))")
		XCTAssertTrue(stderr.isEmpty, "The actual native Carbon command must emit no errors")
		return try String(contentsOf: outputURL, encoding: .utf8)
	}

	private func withNativeFixture(_ body: (URL) throws -> Void) throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent(
			"ErgoptiNativeInputSource-" + UUID().uuidString)
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
		defer {
			if fixtureCanRetire {
				do { try FileManager.default.removeItem(at: root) }
				catch { XCTFail("The exact native input-source fixture did not retire") }
			}
		}
		try body(root)
	}

	func testActualNativeSelectionReturnsZeroForAlreadySelectedSource() throws {
		let before = try sourceState()
		try withNativeFixture { root in
			defer {
				do { XCTAssertEqual(try sourceState(), before, "Selecting the current source preserves native state") }
				catch { XCTFail("The post-selection native inventory could not be observed: \(error)") }
			}
			XCTAssertEqual(try runNative(commandArguments(identifiers: [before.currentID]), root: root), "0\n")
		}
	}

	func testActualNativeSelectionReturnsMissForAbsentSourceWithoutStateChanges() throws {
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
			XCTAssertEqual(try runNative(commandArguments(identifiers: [identifier]), root: root), "MISS\n")
		}
	}

	func testActualNativeNameSelectionUsesTheCurrentLocalizedNameAndPreservesSources() throws {
		let before = try sourceState()
		let candidate = "org.ergopti.native-test.absent-name-candidate." + UUID().uuidString
		guard !before.installedIDs.contains(candidate) else {
			XCTFail("The exact candidate must be absent to exercise the native name lookup")
			throw CocoaError(.executableRuntimeMismatch)
		}
		try withNativeFixture { root in
			defer {
				do { XCTAssertEqual(try sourceState(), before, "Selecting the current name preserves native state") }
				catch { XCTFail("The post-name-selection native inventory could not be observed: \(error)") }
			}
			XCTAssertEqual(try runNative(commandArguments(byName: true,
				identifiers: [before.currentName, candidate]), root: root), "0\n")
		}
	}

	func testActualNativeUpgradePreflightRefusesMissingTargetWithoutChangingSources() throws {
		let before = try sourceState()
		let identifier = "org.ergopti.native-test.absent-upgrade." + UUID().uuidString
		guard !before.installedIDs.contains(identifier) else {
			XCTFail("The refused upgrade target must be genuinely absent")
			throw CocoaError(.executableRuntimeMismatch)
		}
		try withNativeFixture { root in
			defer {
				do { XCTAssertEqual(try sourceState(), before, "Missing-target preflight must preserve every source") }
				catch { XCTFail("The post-preflight native inventory could not be observed: \(error)") }
			}
			XCTAssertEqual(try runNative(commandArguments(upgrade: true,
				identifiers: [before.currentID, identifier]), root: root), "MISS\n")
		}
	}
}
