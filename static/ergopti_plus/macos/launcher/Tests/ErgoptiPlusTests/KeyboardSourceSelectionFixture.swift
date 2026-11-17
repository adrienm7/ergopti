// Tests/ErgoptiPlusTests/KeyboardSourceSelectionFixture.swift

// ==============================================================================
// MODULE: Observed Native Keyboard Source Selection Fixture
// DESCRIPTION:
// Selects a real input source on a disposable CI host and restores the original
// one, acknowledging each change only once this process observes it.
// A selection's noErr can precede this process's view of it; a fixture that
// disabled its temporary source right after that return left a disabled,
// unselected source "current", so every later fixture captured it as the
// original, failed to select, and could not restore it (paramErr).
// Each selection is made by the launcher's headless selection role, a plain
// process, as production selects (InputSourceSelectionWorker), never by the
// XCTest process: an application process that selects and pumps its own events
// can leave the system's current layout on the previous source while the
// selected list moves (com.apple.HIToolbox AppleCurrentKeyboardLayoutInputSourceID,
// read by every process), under a storm of selection notifications. The TIS
// cache probe (probe-macos-tis-cache.yml) saw that 3 times in about 5,900
// application-mode steps and never in about 5,700 steps where a plain child
// selected for that same application, nor in about 7,700 plain-process steps.
// ==============================================================================

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

enum KeyboardSourceSelectionFixture {
	enum Failure: Error, Equatable { case unavailable, deadline }

	static let selectionTimeoutSeconds: TimeInterval = 5

	/// A native selection return does not acknowledge this process's notification cache.
	static func receiveSelection(timeout: TimeInterval, selected: () -> Bool,
		now: () -> TimeInterval, pump: () -> Void) throws {
		let started = now()
		guard timeout.isFinite, timeout > 0, started.isFinite else { throw Failure.unavailable }
		while true {
			let elapsed = now() - started
			guard elapsed.isFinite, elapsed >= 0, elapsed < timeout else { throw Failure.deadline }
			if selected() {
				let acknowledged = now() - started
				guard acknowledged.isFinite, acknowledged >= 0, acknowledged < timeout else {
					throw Failure.deadline
				}
				return
			}
			pump()
		}
	}

	/// True only when the current source is exactly `expected`, selected and enabled.
	static func sourceIsSelected(_ expected: TISInputSource) -> Bool {
		guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			CFEqual(current, expected) else { return false }
		let retainedState = KeyboardSourceTestState.read(expected)
		let currentState = KeyboardSourceTestState.read(current)
		return retainedState.selected.value == true && retainedState.enabled.value == true
			&& currentState.selected.value == true && currentState.enabled.value == true
	}

	/// The SwiftPM-built launcher beside this test bundle, whose headless role selects.
	static func launcherExecutable() -> URL? {
		let directory = Bundle(for: KeyboardSourceSelectionFixtureTests.self).bundleURL.deletingLastPathComponent()
		return [directory.appendingPathComponent("ErgoptiPlus"),
			directory.deletingLastPathComponent().appendingPathComponent("ErgoptiPlus")]
			.first { FileManager.default.isExecutableFile(atPath: $0.path) }
	}

	/// Reads the role's whole answer: one native status line, or nil for anything else.
	static func selectionStatus(_ output: String) -> OSStatus? {
		guard output.hasSuffix("\n"), output.filter({ $0 == "\n" }).count == 1 else { return nil }
		return OSStatus(output.dropLast())
	}

	/// Selects in one bounded plain child; any failure to get its status is ioErr and a test failure.
	static func selectInPlainProcess(_ source: TISInputSource) -> OSStatus {
		guard let identifier = KeyboardSourceTestState.read(source).id.value else {
			XCTFail("The source to select has no identifier")
			return OSStatus(ioErr)
		}
		guard let executable = launcherExecutable() else {
			XCTFail("The SwiftPM-built launcher, whose headless role selects, is unavailable")
			return OSStatus(ioErr)
		}
		let child = Process()
		child.executableURL = executable
		child.arguments = [kInputSourceSelectionFlag, identifier]
		child.environment = NativeFixtureChildEnvironment.make()
		let output = Pipe()
		child.standardOutput = output
		child.standardError = FileHandle.nullDevice
		let exited = DispatchSemaphore(value: 0)
		child.terminationHandler = { _ in exited.signal() }
		do { try child.run() } catch {
			XCTFail("The selecting child did not start: \(error)")
			return OSStatus(ioErr)
		}
		guard exited.wait(timeout: .now() + selectionTimeoutSeconds) == .success else {
			child.terminate()
			if exited.wait(timeout: .now() + selectionTimeoutSeconds) != .success {
				XCTFail("The selecting child did not retire")
			}
			XCTFail("The selecting child did not answer before the fixture deadline")
			return OSStatus(ioErr)
		}
		let answer = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
		guard child.terminationReason == .exit, child.terminationStatus == 0,
			let status = selectionStatus(answer) else {
			XCTFail("The selecting child answered \(child.terminationStatus): \(answer.prefix(64))")
			return OSStatus(ioErr)
		}
		return status
	}

	/// Select exactly once, retain its raw status, then receive genuine selected state.
	static func selectAndObserve(_ source: TISInputSource) -> (status: OSStatus, observed: Bool) {
		let status = selectInPlainProcess(source)
		var observed = false
		if status == noErr {
			do {
				try receiveSelection(timeout: selectionTimeoutSeconds,
					selected: { sourceIsSelected(source) },
					now: { ProcessInfo.processInfo.systemUptime },
					pump: { _ = CFRunLoopRunInMode(.defaultMode, 0.01, true) })
				observed = true
			} catch { XCTFail("Native selection was not observed before the fixture deadline: \(error)") }
		}
		return (status, observed)
	}

	/// A failed restoration must retain the temporary source instead of disabling an unresolved selection.
	static func retireTemporarySource(restorationObserved: Bool, originalSelected: () -> Bool,
		targetUnselected: () -> Bool, disable: () -> Void) throws {
		guard restorationObserved, originalSelected(), targetUnselected() else { throw Failure.unavailable }
		disable()
	}

	/// Runs `body` with `identifier` selected, then restores the original source and
	/// disables the target only if this fixture enabled it and restoration was observed.
	static func withSelectedSource(_ identifier: String, diagnostics: KeyboardSourceTestDiagnostics,
		_ body: (TISInputSource) throws -> Void) throws {
		let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
		diagnostics.record("original.capture", original: original)
		// Refuse stale or unselected initial state before changing this disposable host.
		guard Thread.isMainThread, sourceIsSelected(original) else { throw Failure.unavailable }
		defer {
			let status = diagnostics.nativeCall("restore.outer", original: original) { selectAndObserve(original).status }
			XCTAssertEqual(status, noErr)
		}
		let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
		let sources = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
		let source = try XCTUnwrap(sources.first, "Missing native fixture: \(identifier)")
		let pointer = try XCTUnwrap(TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled))
		let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
		diagnostics.record("target.inventory", original: original, target: source)
		if !wasEnabled {
			let status = diagnostics.nativeCall("enable", original: original, target: source) { TISEnableInputSource(source) }
			XCTAssertEqual(status, noErr)
		}
		defer {
			var restorationObserved = false
			let status = diagnostics.nativeCall("restore.inner", original: original, target: source) {
				let receipt = selectAndObserve(original)
				restorationObserved = receipt.observed
				return receipt.status
			}
			XCTAssertEqual(status, noErr)
			if !wasEnabled {
				do {
					try retireTemporarySource(restorationObserved: restorationObserved,
						originalSelected: { sourceIsSelected(original) },
						targetUnselected: { KeyboardSourceTestState.read(source).selected.value == false }, disable: {
							let disabled = diagnostics.nativeCall("disable", original: original, target: source) { TISDisableInputSource(source) }
							XCTAssertEqual(disabled, noErr)
						})
				} catch { XCTFail("Temporary source cleanup remains unresolved: \(error)") }
			}
		}
		var selectionObserved = false
		let status = diagnostics.nativeCall("select", original: original, target: source) {
			let receipt = selectAndObserve(source)
			selectionObserved = receipt.observed
			return receipt.status
		}
		XCTAssertEqual(status, noErr)
		guard status == noErr, selectionObserved, sourceIsSelected(source) else { throw Failure.unavailable }
		try body(source)
	}
}

final class KeyboardSourceSelectionFixtureTests: XCTestCase {
	func testTemporarySourceIsDisabledOnlyAfterObservedRestoration() {
		var disabled = 0
		XCTAssertThrowsError(try KeyboardSourceSelectionFixture.retireTemporarySource(restorationObserved: false,
			originalSelected: { XCTFail("Failed restoration cannot grant a later observation"); return true },
			targetUnselected: { XCTFail("Failed restoration cannot inspect a successor"); return true },
			disable: { disabled += 1 }))
		XCTAssertThrowsError(try KeyboardSourceSelectionFixture.retireTemporarySource(restorationObserved: true,
			originalSelected: { false }, targetUnselected: { true }, disable: { disabled += 1 }))
		XCTAssertThrowsError(try KeyboardSourceSelectionFixture.retireTemporarySource(restorationObserved: true,
			originalSelected: { true }, targetUnselected: { false }, disable: { disabled += 1 }))
		XCTAssertEqual(disabled, 0, "A still-current temporary source must never be disabled")
		XCTAssertNoThrow(try KeyboardSourceSelectionFixture.retireTemporarySource(restorationObserved: true,
			originalSelected: { true }, targetUnselected: { true }, disable: { disabled += 1 }))
		XCTAssertEqual(disabled, 1)
	}

	func testNativeReturnIsNotAcknowledgedUntilTheSelectionIsObserved() {
		var time: TimeInterval = 0
		var reads = 0
		XCTAssertNoThrow(try KeyboardSourceSelectionFixture.receiveSelection(timeout: 1, selected: {
			reads += 1
			return reads == 3
		}, now: { time }, pump: { time += 0.25 }))
		XCTAssertEqual(reads, 3, "A native return cannot admit a still-stale selected source")
		time = 0
		XCTAssertThrowsError(try KeyboardSourceSelectionFixture.receiveSelection(timeout: 1, selected: { false },
			now: { time }, pump: { time += 0.5 })) { error in
			XCTAssertEqual(error as? KeyboardSourceSelectionFixture.Failure, .deadline)
		}
	}

	func testOnlyOneNativeStatusLineIsASelectionAnswer() {
		XCTAssertEqual(KeyboardSourceSelectionFixture.selectionStatus("0\n"), noErr)
		XCTAssertEqual(KeyboardSourceSelectionFixture.selectionStatus("-50\n"), OSStatus(paramErr))
		for refused in ["", "0", "MISS\n", "0\n0\n", " 0\n", "0 \n", "zero\n"] {
			XCTAssertNil(KeyboardSourceSelectionFixture.selectionStatus(refused), refused)
		}
	}

	func testSuitesThatSwitchSourcesUseTheObservedFixture() throws {
		let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		let fixture = try String(contentsOf: directory.appendingPathComponent("KeyboardSourceSelectionFixture.swift"),
			encoding: .utf8)
		let selectCall = "TISSelect" + "InputSource("
		XCTAssertFalse(fixture.contains(selectCall),
			"The fixture selects through the launcher's plain headless role, never in the XCTest process")
		XCTAssertTrue(fixture.contains("child.arguments = [kInputSourceSelectionFlag, identifier]"))
		for file in ["KeyboardSourceProbeTests.swift", "KeyboardCharacterMappingTests.swift"] {
			let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
			XCTAssertFalse(source.contains(selectCall),
				"\(file) must select through KeyboardSourceSelectionFixture, which waits for the change")
			XCTAssertFalse(source.contains("TISDisableInputSource("),
				"\(file) must not disable a source before its restoration is observed")
			XCTAssertTrue(source.contains("KeyboardSourceSelectionFixture.withSelectedSource("), file)
		}
	}
}
