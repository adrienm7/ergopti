// Tests/ErgoptiPlusTests/KeyboardCharacterMappingTests.swift

// ==============================================================================
// MODULE: Native Keyboard Character Mapping Tests
// DESCRIPTION:
// Verifies the Quartz/AppKit conversion used by the one-shot Shift adapter.
// Events are inspected without posting them. Input-source selection is confined
// to disposable CI hosts and restored after the probe, including assertion errors.
// ==============================================================================

import AppKit
import Carbon
import XCTest

final class KeyboardCharacterMappingTests: XCTestCase {
	func testFreshKeyboardEventsFollowLayoutAndShiftFlags() throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["CI"] == "true",
			"The layout-switching probe is restricted to disposable CI hosts")
		let diagnostics = KeyboardSourceTestDiagnostics(name)
		defer { diagnostics.emit() }
		let selection = try KeyboardSourceTestSelection()
		defer { selection.close() }
		diagnostics.witness("original.capture.call.entered")
		let captured = TISCopyCurrentKeyboardInputSource()
		diagnostics.witness("original.capture.call.returned")
		let original = captured!.takeRetainedValue()
		diagnostics.record("original.capture", original: original)
		try selection.validateOriginal(original)
		defer {
			let status = diagnostics.nativeCall("restore.outer", original: original) { TISSelectInputSource(original) }
			XCTAssertEqual(status, noErr)
			XCTAssertTrue(selection.acknowledge(original, status: status), "Outer restoration needs actual current-source completion")
		}
		let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
		for (identifier, plain, shifted) in [
			("com.apple.keylayout.US", "a", "A"),
			("com.apple.keylayout.French", "q", "Q"),
		] {
			let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
			diagnostics.witness("target.list.call.entered")
			let inventory = TISCreateInputSourceList(filter, true)
			diagnostics.witness("target.list.call.returned")
			let inputs = inventory!.takeRetainedValue() as! [TISInputSource]
			let input = try XCTUnwrap(inputs.first, "Missing fixture layout: \(identifier)")
			diagnostics.witness("target.enabledProperty.call.entered")
			let enabledProperty = TISGetInputSourceProperty(input, kTISPropertyInputSourceIsEnabled)
			diagnostics.witness("target.enabledProperty.call.returned")
			let enabledPointer = try XCTUnwrap(enabledProperty)
			let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabledPointer).takeUnretainedValue())
			diagnostics.record("target.inventory", original: original, target: input)
			if !wasEnabled {
				try selection.retainEnabled(input)
				let status = diagnostics.nativeCall("enable", original: original, target: input) { TISEnableInputSource(input) }
				XCTAssertEqual(status, noErr)
			}
			defer {
				let status = diagnostics.nativeCall("restore.inner", original: original, target: input) { TISSelectInputSource(original) }
				XCTAssertEqual(status, noErr)
				let restored = selection.acknowledge(original, status: status)
				XCTAssertTrue(restored, "Inner restoration needs actual current-source completion")
				if !wasEnabled {
					if restored && selection.mayDisable(input, original: original) {
						let disabled = diagnostics.nativeCall("disable", original: original, target: input) { TISDisableInputSource(input) }
						XCTAssertEqual(disabled, noErr)
						selection.releaseDisabled(input, original: original, status: disabled)
					} else {
						XCTFail("Restoration is unacknowledged; enabled source retained as cleanup debt")
					}
				}
			}
			try selection.prepareSelection()
			let status = diagnostics.nativeCall("select", original: original, target: input) { TISSelectInputSource(input) }
			XCTAssertEqual(status, noErr)
			try selection.requireSelection(input, status: status)
			for (flags, expected) in [(CGEventFlags(), plain), (.maskShift, shifted)] {
				diagnostics.record("event.before", original: original, target: input)
				defer { diagnostics.record("event.after", original: original, target: input) }
				let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
				event.flags = flags
				let native = try XCTUnwrap(NSEvent(cgEvent: event))
				XCTAssertEqual(native.characters, expected, "\(identifier), flags=\(flags.rawValue)")
			}
		}
	}
}
