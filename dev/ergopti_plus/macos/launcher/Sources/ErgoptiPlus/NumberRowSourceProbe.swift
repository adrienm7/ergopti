// Sources/ErgoptiPlus/NumberRowSourceProbe.swift

// ==============================================================================
// MODULE: Read-Only Native Number-Row Levels
// DESCRIPTION:
// Enumerates ten requested positions in four explicit Caps/Shift domains from
// one retained selected TIS layout. Full Carbon dead states remain typed facts;
// this role neither selects a forced mode nor constructs or posts input events.
// ==============================================================================

import Carbon
import Darwin
import Foundation

let kNumberRowSourceProbeFlag = "--number-row-source-probe"
private let kNumberRowSourceProbeVersion = 1
private let kNumberRowSourcePositions = 10
private let kNumberRowSourceUnits = 256
private let kNumberRowSourceTextBytes = 1_024

enum NumberRowSourceProbeError: Error {
	case invalidArguments, sourceChanged, unavailableLayout, translationFailed, invalidUnicode
}

struct NumberRowSourceProbeInvocation: Equatable {
	let sourceID: String
	let codes: [UInt16]

	var valid: Bool {
		!sourceID.isEmpty && sourceID.utf8.count <= 1_024 && !sourceID.utf8.contains(0)
			&& codes.count == kNumberRowSourcePositions && Set(codes).count == codes.count
			&& codes.allSatisfy { $0 <= 127 }
	}

	static func parse(arguments: [String]) -> NumberRowSourceProbeInvocation? {
		guard arguments.count == kNumberRowSourcePositions + 3,
			arguments[1] == kNumberRowSourceProbeFlag else { return nil }
		var codes: [UInt16] = []
		for argument in arguments.dropFirst(3) {
			guard let code = UInt16(argument), String(code) == argument else { return nil }
			codes.append(code)
		}
		let invocation = NumberRowSourceProbeInvocation(sourceID: arguments[2], codes: codes)
		return invocation.valid ? invocation : nil
	}
}

struct NumberRowSourceProbeLevel: Codable, Equatable {
	let code: UInt16
	let caps: Bool
	let shift: Bool
	let text: String
	let deadState: UInt32

	enum CodingKeys: String, CodingKey {
		case code, caps, shift, text
		case deadState = "dead_state"
	}
}

struct NumberRowSourceProbeReceipt: Codable, Equatable {
	let version: Int
	let sourceID: String
	let keyboardType: UInt32
	let levels: [NumberRowSourceProbeLevel]

	enum CodingKeys: String, CodingKey {
		case version, levels
		case sourceID = "source_id"
		case keyboardType = "keyboard_type"
	}

	func matches(_ invocation: NumberRowSourceProbeInvocation) -> Bool {
		guard invocation.valid, version == kNumberRowSourceProbeVersion,
			sourceID == invocation.sourceID, levels.count == 4 * kNumberRowSourcePositions else { return false }
		for (index, level) in levels.enumerated() {
			guard level.code == invocation.codes[index % kNumberRowSourcePositions],
				level.caps == (index >= 2 * kNumberRowSourcePositions),
				level.shift == ((index / kNumberRowSourcePositions) % 2 == 1),
				level.text.utf8.count <= kNumberRowSourceTextBytes,
				!level.text.utf8.contains(0) else { return false }
		}
		return true
	}
}

/// Translates one explicit modifier domain with a fresh full-width dead state.
/// No option suppresses dead keys, and no ambient Caps or composition state is read.
func nativeNumberRowLevel(
	layout: UnsafePointer<UCKeyboardLayout>, code: UInt16, keyboardType: UInt32,
	caps: Bool, shift: Bool
) throws -> NumberRowSourceProbeLevel {
	let modifiers = UInt32((caps ? alphaLock : 0) | (shift ? shiftKey : 0)) >> 8
	var deadState: UInt32 = 0
	var length: Int = 0
	var output = [UniChar](repeating: 0, count: kNumberRowSourceUnits)
	let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
		keyboardType, 0, &deadState, output.count, &length, &output)
	guard status == noErr, length >= 0, length <= output.count else {
		throw NumberRowSourceProbeError.translationFailed
	}
	let units = output.prefix(length)
	let text = String(decoding: units, as: UTF16.self)
	guard text.utf16.elementsEqual(units), !text.utf8.contains(0),
		text.utf8.count <= kNumberRowSourceTextBytes else { throw NumberRowSourceProbeError.invalidUnicode }
	return NumberRowSourceProbeLevel(code: code, caps: caps, shift: shift, text: text, deadState: deadState)
}

/// Copies one native layout into aligned owned storage before invoking its reader.
/// Both the frozen comparison bytes and the Carbon pointer outlive the body;
/// the pointer must never escape it. Original TIS object ownership stays separate.
func withFrozenNumberRowLayout<Result>(
	_ data: CFData,
	_ body: (UnsafePointer<UCKeyboardLayout>, Data) throws -> Result
) throws -> Result {
	guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
		let bytes = CFDataGetBytePtr(data) else { throw NumberRowSourceProbeError.unavailableLayout }
	let frozenBytes = Data(bytes: bytes, count: CFDataGetLength(data))
	let storage = UnsafeMutableRawPointer.allocate(byteCount: frozenBytes.count,
		alignment: MemoryLayout<UCKeyboardLayout>.alignment)
	defer { storage.deallocate() }
	try frozenBytes.withUnsafeBytes { frozen in
		guard let base = frozen.baseAddress else { throw NumberRowSourceProbeError.unavailableLayout }
		storage.copyMemory(from: base, byteCount: frozenBytes.count)
	}
	let layout = storage.bindMemory(to: UCKeyboardLayout.self, capacity: 1)
	return try body(UnsafePointer(layout), frozenBytes)
}

/// Enumerates read-only facts from the actual selected source, never its fallback.
/// Every row uses the same aligned frozen bytes, while the final read rejoins the
/// original selected object/data/type. That sample fence is not an input epoch.
func probeSelectedNumberRowSource(
	_ invocation: NumberRowSourceProbeInvocation,
	readSnapshot: () throws -> KeyboardSourceSnapshot = captureSelectedKeyboardSource
) throws -> NumberRowSourceProbeReceipt {
	guard invocation.valid else { throw NumberRowSourceProbeError.invalidArguments }
	let snapshot = try readSnapshot()
	guard snapshot.sourceID == invocation.sourceID else { throw NumberRowSourceProbeError.sourceChanged }
	guard let data = snapshot.data else { throw NumberRowSourceProbeError.unavailableLayout }
	return try withFrozenNumberRowLayout(data) { layout, originalBytes in
		var levels: [NumberRowSourceProbeLevel] = []
		for caps in [false, true] {
			for shift in [false, true] {
				for code in invocation.codes {
					levels.append(try nativeNumberRowLevel(layout: layout, code: code,
						keyboardType: snapshot.keyboardType, caps: caps, shift: shift))
				}
			}
		}
		let current = try readSnapshot()
		guard current.sourceID == snapshot.sourceID, current.keyboardType == snapshot.keyboardType,
			let currentData = current.data,
			Unmanaged.passUnretained(currentData).toOpaque() == Unmanaged.passUnretained(data).toOpaque(),
			CFDataGetLength(currentData) == originalBytes.count,
			let currentBytes = CFDataGetBytePtr(currentData),
			Data(bytes: currentBytes, count: CFDataGetLength(currentData)) == originalBytes else {
			throw NumberRowSourceProbeError.sourceChanged
		}
		return NumberRowSourceProbeReceipt(version: kNumberRowSourceProbeVersion,
			sourceID: snapshot.sourceID, keyboardType: snapshot.keyboardType, levels: levels)
	}
}

/// Separate read-only role in the signed launcher; no application startup required.
enum NumberRowSourceProbeWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == kNumberRowSourceProbeFlag
	}

	static func run(
		arguments: [String],
		probe: (NumberRowSourceProbeInvocation) throws -> NumberRowSourceProbeReceipt = {
			try probeSelectedNumberRowSource($0)
		},
		writeOutput: (Data) -> Bool = { data in
			do { try FileHandle.standardOutput.write(contentsOf: data); return true }
			catch { return false }
		}
	) -> Int32 {
		guard let invocation = NumberRowSourceProbeInvocation.parse(arguments: arguments) else { return 64 }
		do {
			let receipt = try probe(invocation)
			guard receipt.matches(invocation) else { return 70 }
			return writeOutput(try JSONEncoder().encode(receipt)) ? 0 : 74
		} catch { return 70 }
	}
}
