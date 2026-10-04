// Tests/ErgoptiPlusTests/KeyboardSourceProbeTests.swift

// ==============================================================================
// MODULE: Exact Native Keyboard Source Qualification
// DESCRIPTION:
// Exercises the production Carbon translator on real selected US/French input
// sources, including a base-level dead key. No key event is constructed or posted.
// Source changes are restricted to CI and restored even after assertion failures.
// ==============================================================================

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

final class KeyboardSourceProbeTests: XCTestCase {
	private func withSelectedSource(_ identifier: String, _ body: (KeyboardSourceTestDiagnostics) throws -> Void) throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["CI"] == "true",
			"Input-source switching is restricted to disposable CI hosts")
		let diagnostics = KeyboardSourceTestDiagnostics(name + ":" + identifier)
		defer { diagnostics.emit() }
		diagnostics.witness("original.capture.call.entered")
		let captured = TISCopyCurrentKeyboardInputSource()
		diagnostics.witness("original.capture.call.returned")
		let original = captured!.takeRetainedValue()
		diagnostics.record("original.capture", original: original)
		defer {
			let status = diagnostics.nativeCall("restore.outer", original: original) { TISSelectInputSource(original) }
			XCTAssertEqual(status, noErr)
		}
		let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
		diagnostics.witness("target.list.call.entered")
		let inventory = TISCreateInputSourceList(filter, true)
		diagnostics.witness("target.list.call.returned")
		let sources = inventory!.takeRetainedValue() as! [TISInputSource]
		let source = try XCTUnwrap(sources.first, "Missing native fixture: \(identifier)")
		diagnostics.witness("target.enabledProperty.call.entered")
		let enabledProperty = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled)
		diagnostics.witness("target.enabledProperty.call.returned")
		let pointer = try XCTUnwrap(enabledProperty)
		let wasEnabled = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
		diagnostics.record("target.inventory", original: original, target: source)
		if !wasEnabled {
			let status = diagnostics.nativeCall("enable", original: original, target: source) { TISEnableInputSource(source) }
			XCTAssertEqual(status, noErr)
		}
		defer {
			let status = diagnostics.nativeCall("restore.inner", original: original, target: source) { TISSelectInputSource(original) }
			XCTAssertEqual(status, noErr)
			if !wasEnabled {
				let disabled = diagnostics.nativeCall("disable", original: original, target: source) { TISDisableInputSource(source) }
				XCTAssertEqual(disabled, noErr)
			}
		}
		let status = diagnostics.nativeCall("select", original: original, target: source) { TISSelectInputSource(source) }
		XCTAssertEqual(status, noErr)
		diagnostics.record("body.before", original: original, target: source)
		defer { diagnostics.record("body.after", original: original, target: source) }
		try body(diagnostics)
	}

	func testActualSelectedSourcesProveDirectPunctuationAndRejectDeadAccent() throws {
		for (identifier, code, expected) in [
			("com.apple.keylayout.US", UInt16(41), ";"),
			("com.apple.keylayout.French", UInt16(39), "ù"),
		] {
			try withSelectedSource(identifier) { diagnostics in
				let receipt = try diagnostics.probe(
					KeyboardSourceProbeInvocation(sourceID: identifier, codes: [code]))
				XCTAssertEqual(receipt.sourceID, identifier)
				XCTAssertEqual(receipt.levels, [
					KeyboardSourceProbeLevel(code: code, text: expected, dead: false, direct: true)
				])
			}
		}
		try withSelectedSource("com.apple.keylayout.French") { diagnostics in
			let receipt = try diagnostics.probe(
				KeyboardSourceProbeInvocation(sourceID: "com.apple.keylayout.French", codes: [33, 0]))
			XCTAssertTrue(receipt.levels[0].dead, "French circumflex enters a native composition state")
			XCTAssertFalse(receipt.levels[0].direct, "A dead accent cannot recommend Ctrl+the physical key")
			XCTAssertEqual(receipt.levels[1],
				KeyboardSourceProbeLevel(code: 0, text: "q", dead: false, direct: true),
				"Each key must start with independent neutral composition state")
			let again = try diagnostics.probe(
				KeyboardSourceProbeInvocation(sourceID: "com.apple.keylayout.French", codes: [0, 33]))
			XCTAssertEqual(again.levels[0].text, "q", "A previous probe must never affect a successor")
			XCTAssertTrue(again.levels[1].dead)
		}
	}

	func testShiftAndOptionOnlyGlyphsAreAbsentFromDirectReceipt() throws {
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let snapshot = try captureSelectedKeyboardSource()
			diagnostics.record("translation.snapshot", snapshot: snapshot)
			let data = try XCTUnwrap(snapshot.data)
			let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
			try withExtendedLifetime(data) {
				let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
				let shifted = try directKeyboardLevel(layout: layout, code: 28,
					keyboardType: snapshot.keyboardType, modifiers: UInt32(shiftKey >> 8))
				XCTAssertEqual(shifted.text, "*")
				let option = try directKeyboardLevel(layout: layout, code: 19,
					keyboardType: snapshot.keyboardType, modifiers: UInt32(optionKey >> 8))
				XCTAssertEqual(option.text, "™")
				let receipt = try diagnostics.probe(
					KeyboardSourceProbeInvocation(sourceID: "com.apple.keylayout.US", codes: [28, 19]))
				XCTAssertEqual(receipt.levels.map(\.text), ["8", "2"])
				XCTAssertFalse(receipt.levels.contains { $0.text == "*" || $0.text == "™" })
			}
		}
	}

	func testMissingUnicodeDataDoesNotUseUnderlyingLayout() {
		let invocation = KeyboardSourceProbeInvocation(sourceID: "selected.input.method", codes: [41])
		XCTAssertThrowsError(try probeSelectedKeyboardSource(invocation, readSnapshot: {
			KeyboardSourceSnapshot(sourceID: invocation.sourceID, data: nil, keyboardType: 0)
		}, readCurrentID: { XCTFail("Missing data must reject before an underlying-layout read"); return invocation.sourceID }))
	}

	func testSourceChangesAreRejectedBeforeAndAfterTranslation() throws {
		let invocation = KeyboardSourceProbeInvocation(sourceID: "expected.source", codes: [41])
		XCTAssertThrowsError(try probeSelectedKeyboardSource(invocation, readSnapshot: {
			KeyboardSourceSnapshot(sourceID: "other.source", data: nil, keyboardType: 0)
		}))
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let request = KeyboardSourceProbeInvocation(sourceID: "com.apple.keylayout.US", codes: [41])
			XCTAssertThrowsError(try diagnostics.probe(request, readCurrentID: { "changed.source" }))
		}
	}

	func testHeadlessRoleRejectsNonCanonicalAndDuplicateCodes() {
		let prefix = ["ErgoptiPlus", kKeyboardSourceProbeFlag, "source.id"]
		for tail in [[], ["-1"], ["128"], ["01"], ["1.0"], ["41", "41"]] {
			XCTAssertNil(KeyboardSourceProbeInvocation.parse(arguments: prefix + tail))
		}
		XCTAssertNotNil(KeyboardSourceProbeInvocation.parse(arguments: prefix + ["0", "127"]))
		XCTAssertFalse(KeyboardSourceProbeWorker.handles(arguments: ["ErgoptiPlus", "--unrelated"]))
	}

	func testWorkerEmitsExactReceiptAndRefusesChangedOrFailedProof() throws {
		let arguments = ["ErgoptiPlus", kKeyboardSourceProbeFlag, "source.id", "41"]
		let receipt = KeyboardSourceProbeReceipt(version: 1, sourceID: "source.id", keyboardType: 40,
			levels: [KeyboardSourceProbeLevel(code: 41, text: ";", dead: false, direct: true)])
		var output: Data?
		XCTAssertEqual(KeyboardSourceProbeWorker.run(arguments: arguments,
			probe: { _ in receipt }, writeOutput: { output = $0; return true }), 0)
		XCTAssertEqual(try JSONDecoder().decode(KeyboardSourceProbeReceipt.self, from: XCTUnwrap(output)), receipt)
		XCTAssertEqual(KeyboardSourceProbeWorker.run(arguments: arguments,
			probe: { _ in throw KeyboardSourceProbeError.translationFailed },
			writeOutput: { _ in XCTFail("A failed native proof must not publish JSON"); return true }), 70)
		XCTAssertEqual(KeyboardSourceProbeWorker.run(arguments: arguments, probe: { _ in
			KeyboardSourceProbeReceipt(version: 1, sourceID: "changed", keyboardType: 40, levels: receipt.levels)
		}, writeOutput: { _ in XCTFail("A foreign source must not publish JSON"); return true }), 70)
		XCTAssertEqual(KeyboardSourceProbeWorker.run(arguments: arguments,
			probe: { _ in receipt }, writeOutput: { _ in false }), 74)
	}
}
