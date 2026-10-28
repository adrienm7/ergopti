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
		let source = try XCTUnwrap(CGEventSource(stateID: .privateState))
		for (identifier, plain, shifted) in [
			("com.apple.keylayout.US", "a", "A"),
			("com.apple.keylayout.French", "q", "Q"),
		] {
			try KeyboardSourceSelectionFixture.withSelectedSource(identifier, diagnostics: diagnostics) { input in
				for (flags, expected) in [(CGEventFlags(), plain), (.maskShift, shifted)] {
					diagnostics.record("event.before", target: input)
					defer { diagnostics.record("event.after", target: input) }
					let event = try XCTUnwrap(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
					event.flags = flags
					let native = try XCTUnwrap(NSEvent(cgEvent: event))
					XCTAssertEqual(native.characters, expected, "\(identifier), flags=\(flags.rawValue)")
				}
			}
		}
	}
}
