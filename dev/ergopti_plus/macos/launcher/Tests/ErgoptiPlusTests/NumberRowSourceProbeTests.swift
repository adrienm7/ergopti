// Tests/ErgoptiPlusTests/NumberRowSourceProbeTests.swift

// ==============================================================================
// MODULE: Read-Only Number-Row Source Qualification
// DESCRIPTION:
// Exercises the genuine Carbon producer on selected native layouts, preserving
// exact source restoration and diagnostic publication. US plain/Shift glyphs use
// the unchanged independent corpus; Caps rows are not qualified by that oracle.
// No event is constructed, posted, or granted output authority.
// ==============================================================================

import Carbon
import Foundation
import XCTest
@testable import ErgoptiPlus

final class NumberRowSourceProbeTests: XCTestCase {
	private let codes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
	private let selectionTimeoutSeconds: TimeInterval = 5

	private enum SelectionFailure: Error { case unavailable, deadline }

	/// A native selection return does not acknowledge this process's notification cache.
	private func receiveSelection(timeout: TimeInterval, selected: () -> Bool,
		now: () -> TimeInterval, pump: () -> Void) throws {
		let started = now()
		guard timeout.isFinite, timeout > 0, started.isFinite else { throw SelectionFailure.unavailable }
		while true {
			let elapsed = now() - started
			guard elapsed.isFinite, elapsed >= 0, elapsed < timeout else { throw SelectionFailure.deadline }
			if selected() {
				let acknowledged = now() - started
				guard acknowledged.isFinite, acknowledged >= 0, acknowledged < timeout else {
					throw SelectionFailure.deadline
				}
				return
			}
			pump()
		}
	}

	private func sourceIsSelected(_ expected: TISInputSource) -> Bool {
		guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
			CFEqual(current, expected) else { return false }
		let retainedState = KeyboardSourceTestState.read(expected)
		let currentState = KeyboardSourceTestState.read(current)
		return retainedState.selected.value == true && retainedState.enabled.value == true
			&& currentState.selected.value == true && currentState.enabled.value == true
	}

	/// Select exactly once, retain its raw status, then receive genuine selected state.
	private func selectAndObserve(_ source: TISInputSource) -> (status: OSStatus, observed: Bool) {
		let status = TISSelectInputSource(source)
		var observed = false
		if status == noErr {
			do {
				try receiveSelection(timeout: selectionTimeoutSeconds,
					selected: { self.sourceIsSelected(source) },
					now: { ProcessInfo.processInfo.systemUptime },
					pump: { _ = CFRunLoopRunInMode(.defaultMode, 0.01, true) })
				observed = true
			} catch { XCTFail("Native selection was not observed before the fixture deadline: \(error)") }
		}
		return (status, observed)
	}

	/// A failed restoration must retain the temporary source instead of disabling an unresolved selection.
	private func retireTemporarySource(restorationObserved: Bool, originalSelected: () -> Bool,
		targetUnselected: () -> Bool, disable: () -> Void) throws {
		guard restorationObserved, originalSelected(), targetUnselected() else { throw SelectionFailure.unavailable }
		disable()
	}

	private func withSelectedSource(_ identifier: String, _ body: (KeyboardSourceTestDiagnostics) throws -> Void) throws {
		try XCTSkipUnless(ProcessInfo.processInfo.environment["CI"] == "true",
			"Input-source switching is restricted to disposable CI hosts")
		let diagnostics = KeyboardSourceTestDiagnostics(name + ":" + identifier)
		defer { diagnostics.emit() }
		let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
		diagnostics.record("original.capture", original: original)
		// Refuse stale or unselected initial state before changing this disposable host.
		guard Thread.isMainThread, sourceIsSelected(original) else { throw SelectionFailure.unavailable }
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
						originalSelected: { self.sourceIsSelected(original) },
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
		guard status == noErr, selectionObserved, sourceIsSelected(source) else { throw SelectionFailure.unavailable }
		diagnostics.record("body.before", original: original, target: source)
		defer { diagnostics.record("body.after", original: original, target: source) }
		try body(diagnostics)
	}

	private func snapshot(_ diagnostics: KeyboardSourceTestDiagnostics) throws -> KeyboardSourceSnapshot {
		let observed = try captureSelectedKeyboardSource()
		diagnostics.record("translation.snapshot", snapshot: observed)
		return observed
	}

	private func controlledReceipt(_ request: NumberRowSourceProbeInvocation) -> NumberRowSourceProbeReceipt {
		var levels: [NumberRowSourceProbeLevel] = []
		for caps in [false, true] {
			for shift in [false, true] {
				for code in request.codes {
					levels.append(.init(code: code, caps: caps, shift: shift, text: "", deadState: UInt32.max))
				}
			}
		}
		return .init(version: 1, sourceID: request.sourceID, keyboardType: 40, levels: levels)
	}

	func testActualSelectedUSPlainAndShiftUseUnchangedIndependentExpectations() throws {
		var shared = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
		for _ in 0..<4 { shared.deleteLastPathComponent() }
		let corpus = shared.appendingPathComponent("_shared/tests/corpus/layouts/number_row_levels.json")
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as? [String: Any])
		let rows = try XCTUnwrap(object["native"] as? [[String: Any]])
		let expected = try XCTUnwrap(rows.first { $0["id"] as? String == "qwerty" })
		let plain = try XCTUnwrap(expected["plain"] as? [String])
		let shifted = try XCTUnwrap(expected["shift"] as? [String])
		XCTAssertEqual(plain.count, 10)
		XCTAssertEqual(shifted.count, 10)
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let request = NumberRowSourceProbeInvocation(sourceID: "com.apple.keylayout.US", codes: codes)
			let receipt = try probeSelectedNumberRowSource(request, readSnapshot: { try snapshot(diagnostics) })
			XCTAssertTrue(receipt.matches(request))
			XCTAssertEqual(Array(receipt.levels.prefix(10)).map(\.text), plain)
			XCTAssertEqual(Array(receipt.levels.dropFirst(10).prefix(10)).map(\.text), shifted)
			XCTAssertEqual(Array(receipt.levels.prefix(20)).map(\.deadState), [UInt32](repeating: 0, count: 20))
			XCTAssertEqual(receipt.levels.map(\.code), codes + codes + codes + codes)
			XCTAssertEqual(receipt.levels.map(\.caps), [Bool](repeating: false, count: 20) + [Bool](repeating: true, count: 20))
			XCTAssertEqual(receipt.levels.map(\.shift), [Bool](repeating: false, count: 10) + [Bool](repeating: true, count: 10)
				+ [Bool](repeating: false, count: 10) + [Bool](repeating: true, count: 10))
			// The corpus explicitly defines Caps-off native glyphs. Shape and
			// actual Carbon execution above do not establish a Caps glyph oracle.
		}
	}

	func testActualFrenchDeadStateDoesNotLeakIntoNextPositionOrSuccessor() throws {
		try withSelectedSource("com.apple.keylayout.French") { diagnostics in
			let positions: [UInt16] = [33, 0, 18, 19, 20, 21, 23, 22, 26, 28]
			let request = NumberRowSourceProbeInvocation(sourceID: "com.apple.keylayout.French", codes: positions)
			let first = try probeSelectedNumberRowSource(request, readSnapshot: { try snapshot(diagnostics) })
			XCTAssertNotEqual(first.levels[0].deadState, 0, "The actual circumflex enters native composition")
			XCTAssertEqual(first.levels[1].text, "q", "Existing independent base-level expectation")
			XCTAssertEqual(first.levels[1].deadState, 0)
			let reordered = NumberRowSourceProbeInvocation(sourceID: request.sourceID, codes: [0, 33] + Array(positions.dropFirst(2)))
			let next = try probeSelectedNumberRowSource(reordered, readSnapshot: { try snapshot(diagnostics) })
			XCTAssertEqual(next.levels[0].text, "q")
			XCTAssertEqual(next.levels[0].deadState, 0)
			XCTAssertEqual(next.levels[1].deadState, first.levels[0].deadState,
				"The full native state is retained without a Boolean conversion")
		}
	}




	func testFrozenNativeLayoutIsAlignedDetachedFromControlledMutableStorage() throws {
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let observed = try snapshot(diagnostics)
			let nativeData = try XCTUnwrap(observed.data)
			let mutable = try XCTUnwrap(CFDataCreateMutableCopy(nil, 0, nativeData))
			let length = CFDataGetLength(mutable)
			let originalBytes = Data(bytes: try XCTUnwrap(CFDataGetBytePtr(mutable)), count: length)
			try withFrozenNumberRowLayout(mutable) { layout, frozenBytes in
				XCTAssertEqual(frozenBytes, originalBytes)
				let address = UInt(bitPattern: UnsafeRawPointer(layout))
				XCTAssertEqual(address % UInt(MemoryLayout<UCKeyboardLayout>.alignment), 0)
				// Only a private owned CFMutableData copy is changed. This does
				// not model or claim that genuine selected TIS data is mutable.
				let zeros = [UInt8](repeating: 0, count: length)
				zeros.withUnsafeBufferPointer { buffer in
					CFDataReplaceBytes(mutable, CFRange(location: 0, length: length), buffer.baseAddress, length)
				}
				let changed = Data(bytes: try XCTUnwrap(CFDataGetBytePtr(mutable)), count: length)
				XCTAssertEqual(changed, Data(repeating: 0, count: length))
				let translatedBytes = Data(bytes: UnsafeRawPointer(layout), count: length)
				XCTAssertEqual(translatedBytes, originalBytes)
				guard translatedBytes == originalBytes else {
					return XCTFail("Aliased mutation refuses before unsafe native translation")
				}
				let digit = try nativeNumberRowLevel(layout: layout, code: 18,
					keyboardType: observed.keyboardType, caps: false, shift: false)
				XCTAssertEqual(digit.text, "1")
				XCTAssertEqual(digit.deadState, 0)
				let letter = try nativeNumberRowLevel(layout: layout, code: 0,
					keyboardType: observed.keyboardType, caps: true, shift: false)
				XCTAssertEqual(letter.text, "A")
				XCTAssertEqual(letter.deadState, 0)
			}
		}
	}

	func testActualUSCapsMaskChangesAnIndependentLetterExpectation() throws {
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			// US virtual code 0 is the same a/A native fixture already qualified
			// by KeyboardCharacterMappingTests. CapsLock explicitly capitalizes
			// this letter; unchanged digit glyphs cannot catch a missing Caps mask.
			let positions = [UInt16(0)] + Array(codes.dropLast())
			let request = NumberRowSourceProbeInvocation(sourceID: "com.apple.keylayout.US", codes: positions)
			let receipt = try probeSelectedNumberRowSource(request, readSnapshot: { try snapshot(diagnostics) })
			XCTAssertEqual(receipt.levels[0].text, "a")
			XCTAssertEqual(receipt.levels[10].text, "A")
			XCTAssertEqual(receipt.levels[20].text, "A")
			XCTAssertEqual(receipt.levels[20].deadState, 0)
			// No undocumented Caps+Shift or full Caps number-row glyph oracle
			// is inferred from these three independent literal expectations.
		}
	}

	func testActualCarbonCapsDomainsPreserveNativeModifierAndDeadStateABI() throws {
		try withSelectedSource("com.apple.keylayout.French") { diagnostics in
			let observed = try snapshot(diagnostics)
			let positions: [UInt16] = [33, 0, 18, 19, 20, 21, 23, 22, 26, 28]
			let request = NumberRowSourceProbeInvocation(sourceID: observed.sourceID, codes: positions)
			let receipt = try probeSelectedNumberRowSource(request, readSnapshot: { try snapshot(diagnostics) })
			let data = try XCTUnwrap(observed.data)
			let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
			let masks: [UInt32] = [0, UInt32(shiftKey) >> 8, UInt32(alphaLock) >> 8,
				(UInt32(alphaLock) >> 8) | (UInt32(shiftKey) >> 8)]
			try withExtendedLifetime(data) {
				let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
				for (domain, mask) in masks.enumerated() {
					for (position, code) in positions.enumerated() {
						var nativeDead: UInt32 = 0
						var length: Int = 0
						var output = [UniChar](repeating: 0, count: 256)
						let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mask,
							observed.keyboardType, 0, &nativeDead, output.count, &length, &output)
						XCTAssertEqual(status, noErr)
						guard status == noErr, length >= 0, length <= output.count else {
							return XCTFail("Independent native ABI observation refused")
						}
						let row = receipt.levels[domain * 10 + position]
						XCTAssertEqual(row.deadState, nativeDead)
						XCTAssertEqual(row.text.utf16.map { $0 }, Array(output.prefix(length)))
					}
				}
			}
			// This directly compares native API calls and typed state, not an
			// independent Caps glyph corpus or actual physical keyboard output.
		}
	}

	func testActualLayoutRefusesChangedSourceTypeDataOrUnavailableFinalRead() throws {
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let original = try snapshot(diagnostics)
			let request = NumberRowSourceProbeInvocation(sourceID: original.sourceID, codes: codes)
			let data = try XCTUnwrap(original.data)
			let copy = try XCTUnwrap(CFDataCreate(nil, CFDataGetBytePtr(data), CFDataGetLength(data)))
			for changed in [
				KeyboardSourceSnapshot(sourceID: "changed.source", data: data, keyboardType: original.keyboardType),
				KeyboardSourceSnapshot(sourceID: original.sourceID, data: data, keyboardType: original.keyboardType ^ 1),
				KeyboardSourceSnapshot(sourceID: original.sourceID, data: copy, keyboardType: original.keyboardType),
				KeyboardSourceSnapshot(sourceID: original.sourceID, data: nil, keyboardType: original.keyboardType),
			] {
				var reads = 0
				XCTAssertThrowsError(try probeSelectedNumberRowSource(request, readSnapshot: {
					reads += 1
					return reads == 1 ? original : changed
				})) { error in
					guard case NumberRowSourceProbeError.sourceChanged = error else {
						return XCTFail("Final native owner loss must refuse its receipt")
					}
				}
				XCTAssertEqual(reads, 2)
			}
		}
	}

	func testMissingUnicodeDataAndForeignInitialIdentityNeverReadFallback() {
		let request = NumberRowSourceProbeInvocation(sourceID: "selected.input.method", codes: codes)
		for identity in [request.sourceID, "foreign.source"] {
			var reads = 0
			XCTAssertThrowsError(try probeSelectedNumberRowSource(request, readSnapshot: {
				reads += 1
				return KeyboardSourceSnapshot(sourceID: identity, data: nil, keyboardType: 40)
			}))
			XCTAssertEqual(reads, 1, "No underlying ASCII source or final fallback read is permitted")
		}
	}

	func testInvalidInvocationRefusesBeforeAnyNativeRead() {
		var disabled = 0
		XCTAssertThrowsError(try retireTemporarySource(restorationObserved: false,
			originalSelected: { XCTFail("Failed restoration cannot grant a later observation"); return true },
			targetUnselected: { XCTFail("Failed restoration cannot inspect a successor"); return true },
			disable: { disabled += 1 }))
		XCTAssertEqual(disabled, 0)
		XCTAssertThrowsError(try retireTemporarySource(restorationObserved: true,
			originalSelected: { false }, targetUnselected: { XCTFail("Unrestored original cannot inspect a successor"); return true },
			disable: { disabled += 1 }))
		XCTAssertThrowsError(try retireTemporarySource(restorationObserved: true,
			originalSelected: { true }, targetUnselected: { false }, disable: { disabled += 1 }))
		XCTAssertEqual(disabled, 0, "A selected or unknown target remains owned after refused restoration")
		XCTAssertNoThrow(try retireTemporarySource(restorationObserved: true,
			originalSelected: { true }, targetUnselected: { true }, disable: { disabled += 1 }))
		XCTAssertEqual(disabled, 1, "Only acknowledged restoration admits exact temporary-source cleanup")
		var time: TimeInterval = 0
		var reads = 0
		XCTAssertNoThrow(try receiveSelection(timeout: 1, selected: {
			reads += 1
			return reads == 3
		}, now: { time }, pump: { time += 0.25 }))
		XCTAssertEqual(reads, 3, "A native return cannot admit a still-stale selected source")
		XCTAssertEqual(time, 0.5, "The fixture pumps notifications before acknowledging selection")
		time = 0
		reads = 0
		XCTAssertThrowsError(try receiveSelection(timeout: 1, selected: {
			reads += 1
			return false
		}, now: { time }, pump: { time += 0.5 })) { error in
			guard case SelectionFailure.deadline = error else { return XCTFail("Expected a selection deadline") }
		}
		XCTAssertEqual(reads, 2, "Equality at the deadline refuses before another source read")
		time = 0
		XCTAssertThrowsError(try receiveSelection(timeout: 1, selected: {
			time = 1
			return true
		}, now: { time }, pump: { XCTFail("A late acknowledgement cannot retry selection") }))
		XCTAssertThrowsError(try receiveSelection(timeout: 0, selected: {
			XCTFail("Invalid selection admission cannot read a native source")
			return true
		}, now: { 0 }, pump: { XCTFail("Invalid selection admission cannot pump callbacks") }))
		for positions in [Array(codes.dropLast()), codes + [0], [UInt16](repeating: 18, count: 10),
			Array(codes.dropLast()) + [128]] {
			XCTAssertThrowsError(try probeSelectedNumberRowSource(.init(sourceID: "source.id", codes: positions),
				readSnapshot: { XCTFail("Invalid input cannot read a native source"); throw NumberRowSourceProbeError.unavailableLayout }))
		}
	}

	func testHeadlessRoleRequiresTenCanonicalDistinctPositionsAndBoundedIdentity() {
		let prefix = ["ErgoptiPlus", kNumberRowSourceProbeFlag, "source.id"]
		let tail = codes.map { String($0) }
		XCTAssertNotNil(NumberRowSourceProbeInvocation.parse(arguments: prefix + tail))
		for bad in ["-1", "128", "01", "1.0", "65536", " 18"] {
			XCTAssertNil(NumberRowSourceProbeInvocation.parse(arguments: prefix + [bad] + Array(tail.dropFirst())))
		}
		XCTAssertNil(NumberRowSourceProbeInvocation.parse(arguments: prefix + Array(tail.dropLast())))
		XCTAssertNil(NumberRowSourceProbeInvocation.parse(arguments: prefix + tail + ["0"]))
		XCTAssertNil(NumberRowSourceProbeInvocation.parse(arguments: prefix + [String](repeating: "18", count: 10)))
		for identity in ["", "source\0id", String(repeating: "é", count: 513)] {
			XCTAssertNil(NumberRowSourceProbeInvocation.parse(arguments: ["ErgoptiPlus", kNumberRowSourceProbeFlag, identity] + tail))
		}
		XCTAssertFalse(NumberRowSourceProbeWorker.handles(arguments: ["ErgoptiPlus", "--keyboard-source-probe"]))
	}

	func testWorkerPreservesUInt32DeadStateAndExactFortyRowOrder() throws {
		let request = NumberRowSourceProbeInvocation(sourceID: "source.id", codes: codes)
		let arguments = ["ErgoptiPlus", kNumberRowSourceProbeFlag, request.sourceID] + codes.map { String($0) }
		let receipt = controlledReceipt(request)
		var output: Data?
		XCTAssertEqual(NumberRowSourceProbeWorker.run(arguments: arguments, probe: { _ in receipt },
			writeOutput: { output = $0; return true }), 0)
		let decoded = try JSONDecoder().decode(NumberRowSourceProbeReceipt.self, from: XCTUnwrap(output))
		XCTAssertEqual(decoded, receipt)
		XCTAssertEqual(decoded.levels.map(\.deadState), [UInt32](repeating: UInt32.max, count: 40))
		XCTAssertEqual(NumberRowSourceProbeWorker.run(arguments: arguments, probe: { _ in receipt }, writeOutput: { _ in false }), 74)
	}

	func testWorkerRefusesPartialForeignOrMislabelledFactsWithoutPublication() {
		let request = NumberRowSourceProbeInvocation(sourceID: "source.id", codes: codes)
		let arguments = ["ErgoptiPlus", kNumberRowSourceProbeFlag, request.sourceID] + codes.map { String($0) }
		let original = controlledReceipt(request)
		var wrongCaps = original.levels
		wrongCaps[20] = .init(code: codes[0], caps: false, shift: false, text: "", deadState: 0)
		var wrongOrder = original.levels
		wrongOrder.swapAt(0, 1)
		var invalidText = original.levels
		invalidText[0] = .init(code: codes[0], caps: false, shift: false, text: "\0", deadState: 0)
		for refused in [
			NumberRowSourceProbeReceipt(version: 2, sourceID: request.sourceID, keyboardType: 40, levels: original.levels),
			NumberRowSourceProbeReceipt(version: 1, sourceID: "foreign.source", keyboardType: 40, levels: original.levels),
			NumberRowSourceProbeReceipt(version: 1, sourceID: request.sourceID, keyboardType: 40, levels: Array(original.levels.dropLast())),
			NumberRowSourceProbeReceipt(version: 1, sourceID: request.sourceID, keyboardType: 40, levels: wrongCaps),
			NumberRowSourceProbeReceipt(version: 1, sourceID: request.sourceID, keyboardType: 40, levels: wrongOrder),
			NumberRowSourceProbeReceipt(version: 1, sourceID: request.sourceID, keyboardType: 40, levels: invalidText),
		] {
			XCTAssertEqual(NumberRowSourceProbeWorker.run(arguments: arguments, probe: { _ in refused },
				writeOutput: { _ in XCTFail("Refused native facts cannot publish JSON"); return true }), 70)
		}
		XCTAssertEqual(NumberRowSourceProbeWorker.run(arguments: arguments,
			probe: { _ in throw NumberRowSourceProbeError.translationFailed },
			writeOutput: { _ in XCTFail("A failed translator cannot publish JSON"); return true }), 70)
	}

	func testActualFrozenProbeRefusesChangedFinalBytesOnSamePrivateDataObject() throws {
		try withSelectedSource("com.apple.keylayout.US") { diagnostics in
			let observed = try snapshot(diagnostics)
			let nativeData = try XCTUnwrap(observed.data)
			let mutable = try XCTUnwrap(CFDataCreateMutableCopy(nil, 0, nativeData))
			let length = CFDataGetLength(mutable)
			let originalBytes = Data(bytes: try XCTUnwrap(CFDataGetBytePtr(mutable)), count: length)
			guard length > 0 else { return XCTFail("The genuine layout needs native bytes") }
			let sameObject = KeyboardSourceSnapshot(sourceID: observed.sourceID,
				data: mutable, keyboardType: observed.keyboardType)
			let request = NumberRowSourceProbeInvocation(sourceID: observed.sourceID, codes: codes)
			var reads = 0
			XCTAssertThrowsError(try probeSelectedNumberRowSource(request, readSnapshot: {
				reads += 1
				if reads == 2 {
					// Translation has already consumed the frozen aligned copy.
					// Change only our private mutable clone, never native TIS data.
					var changed = originalBytes
					changed[0] ^= 1
					changed.withUnsafeBytes { buffer in
						CFDataReplaceBytes(mutable, CFRange(location: 0, length: length),
							buffer.bindMemory(to: UInt8.self).baseAddress, length)
					}
				}
				return sameObject
			})) { error in
				guard case NumberRowSourceProbeError.sourceChanged = error else {
					return XCTFail("Same-object final byte changes must refuse publication")
				}
			}
			XCTAssertEqual(reads, 2)
			XCTAssertEqual(CFDataGetLength(mutable), length)
			let finalBytes = Data(bytes: try XCTUnwrap(CFDataGetBytePtr(mutable)), count: length)
			XCTAssertNotEqual(finalBytes, originalBytes)
			XCTAssertEqual(Data(bytes: try XCTUnwrap(CFDataGetBytePtr(nativeData)),
				count: CFDataGetLength(nativeData)), originalBytes,
				"The genuine selected layout remains unchanged")
		}
	}
}
