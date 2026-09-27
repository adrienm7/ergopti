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
		let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
		defer { XCTAssertEqual(TISSelectInputSource(original), noErr) }
		let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
		for (identifier, plain, shifted) in [
			("com.apple.keylayout.US", "a", "A"),
			("com.apple.keylayout.French", "q", "Q"),
		] {
			let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
			let inputs = TISCreateInputSourceList(filter, true).takeRetainedValue() as! [TISInputSource]
			let input = try XCTUnwrap(inputs.first, "Missing fixture layout: \(identifier)")
			let enabledPointer = try XCTUnwrap(TISGetInputSourceProperty(input, kTISPropertyInputSourceIsEnabled))
			let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enabledPointer).takeUnretainedValue())
			if !wasEnabled { XCTAssertEqual(TISEnableInputSource(input), noErr) }
			defer {
				XCTAssertEqual(TISSelectInputSource(original), noErr)
				if !wasEnabled { XCTAssertEqual(TISDisableInputSource(input), noErr) }
			}
			XCTAssertEqual(TISSelectInputSource(input), noErr)
			for (flags, expected) in [(CGEventFlags(), plain), (.maskShift, shifted)] {
				let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
				event.flags = flags
				let native = try XCTUnwrap(NSEvent(cgEvent: event))
				XCTAssertEqual(native.characters, expected, "\(identifier), flags=\(flags.rawValue)")
			}
		}
	}
}
