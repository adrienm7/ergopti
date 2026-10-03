// Sources/ErgoptiPlus/KeyboardSourceProbe.swift

// ==============================================================================
// MODULE: Native Direct Keyboard Source Proof
// DESCRIPTION:
// Reads the selected input source without activating an application or posting
// input. Carbon translation uses a fresh local composition state for every key,
// so a displayed dead-key accent cannot masquerade as a direct printable tap.
// ==============================================================================

import Carbon
import Darwin
import Foundation

let kKeyboardSourceProbeFlag = "--keyboard-source-probe"
private let kKeyboardSourceProbeVersion = 1
private let kMaximumKeyboardSourceIDBytes = 1_024
private let kMaximumKeyboardSourceCodes = 128
private let kMaximumKeyboardVirtualCode: UInt16 = 127
private let kMaximumKeyboardTranslationUnits = 256

enum KeyboardSourceProbeError: Error {
	case invalidArguments, sourceChanged, unavailableLayout, translationFailed, invalidUnicode
}

struct KeyboardSourceProbeInvocation: Equatable {
	let sourceID: String
	let codes: [UInt16]

	static func parse(arguments: [String]) -> KeyboardSourceProbeInvocation? {
		guard arguments.count >= 4, arguments[1] == kKeyboardSourceProbeFlag,
			arguments.count - 3 <= kMaximumKeyboardSourceCodes else { return nil }
		let sourceID = arguments[2]
		guard !sourceID.isEmpty, sourceID.utf8.count <= kMaximumKeyboardSourceIDBytes,
			!sourceID.utf8.contains(0) else { return nil }
		var codes: [UInt16] = []
		for argument in arguments.dropFirst(3) {
			guard let code = UInt16(argument), code <= kMaximumKeyboardVirtualCode,
				String(code) == argument, !codes.contains(code) else { return nil }
			codes.append(code)
		}
		return KeyboardSourceProbeInvocation(sourceID: sourceID, codes: codes)
	}
}

struct KeyboardSourceProbeLevel: Codable, Equatable {
	let code: UInt16
	let text: String
	let dead: Bool
	let direct: Bool
}

struct KeyboardSourceProbeReceipt: Codable, Equatable {
	let version: Int
	let sourceID: String
	let keyboardType: UInt32
	let levels: [KeyboardSourceProbeLevel]

	enum CodingKeys: String, CodingKey {
		case version, levels
		case sourceID = "source_id"
		case keyboardType = "keyboard_type"
	}
}

struct KeyboardSourceSnapshot {
	let sourceID: String
	let data: CFData?
	let keyboardType: UInt32
}

/// Returns the actual selected source identity, including input methods.
func selectedKeyboardSourceID(_ source: TISInputSource) throws -> String {
	guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
		throw KeyboardSourceProbeError.unavailableLayout
	}
	return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

/// Retains the exact selected source's Unicode data; no underlying-layout fallback.
func captureSelectedKeyboardSource() throws -> KeyboardSourceSnapshot {
	let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
	let sourceID = try selectedKeyboardSourceID(source)
	let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
	let data = pointer.map { Unmanaged<CFData>.fromOpaque($0).takeUnretainedValue() }
	return KeyboardSourceSnapshot(sourceID: sourceID, data: data, keyboardType: UInt32(LMGetKbdType()))
}

/// Translates one key without sharing or suppressing dead-key state.
/// Modifier bits are Carbon's shifted modifier mask, rather than CGEvent flags.
func directKeyboardLevel(
	layout: UnsafePointer<UCKeyboardLayout>, code: UInt16, keyboardType: UInt32,
	modifiers: UInt32 = 0
) throws -> KeyboardSourceProbeLevel {
	var deadState: UInt32 = 0
	var length: Int = 0
	var output = [UniChar](repeating: 0, count: kMaximumKeyboardTranslationUnits)
	let status = UCKeyTranslate(
		layout, code, UInt16(kUCKeyActionDown), modifiers, keyboardType,
		0, &deadState, output.count, &length, &output
	)
	guard status == noErr, length <= output.count else {
		throw KeyboardSourceProbeError.translationFailed
	}
	let units = output.prefix(Int(length))
	let text = String(decoding: units, as: UTF16.self)
	guard text.utf16.elementsEqual(units) else { throw KeyboardSourceProbeError.invalidUnicode }
	return KeyboardSourceProbeLevel(
		code: code, text: text, dead: deadState != 0,
		direct: deadState == 0 && !text.isEmpty
	)
}

/// Proves direct base-level output from one retained exact native source.
/// An input method without Unicode layout data is unavailable; its underlying
/// ASCII layout cannot establish what the selected input method will type.
func probeSelectedKeyboardSource(
	_ invocation: KeyboardSourceProbeInvocation,
	readSnapshot: () throws -> KeyboardSourceSnapshot = captureSelectedKeyboardSource,
	readCurrentID: () throws -> String = {
		try selectedKeyboardSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
	}
) throws -> KeyboardSourceProbeReceipt {
	let snapshot = try readSnapshot()
	guard snapshot.sourceID == invocation.sourceID else {
		throw KeyboardSourceProbeError.sourceChanged
	}
	guard let data = snapshot.data else {
		throw KeyboardSourceProbeError.unavailableLayout
	}
	guard CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size,
		let bytes = CFDataGetBytePtr(data) else { throw KeyboardSourceProbeError.unavailableLayout }
	let levels = try withExtendedLifetime(data) {
		let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
		return try invocation.codes.map {
			try directKeyboardLevel(layout: layout, code: $0, keyboardType: snapshot.keyboardType)
		}
	}
	guard try readCurrentID() == invocation.sourceID else {
		throw KeyboardSourceProbeError.sourceChanged
	}
	return KeyboardSourceProbeReceipt(
		version: kKeyboardSourceProbeVersion, sourceID: invocation.sourceID,
		keyboardType: snapshot.keyboardType, levels: levels
	)
}

/// Headless read-only role in the existing signed executable.
enum KeyboardSourceProbeWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == kKeyboardSourceProbeFlag
	}

	static func run(
		arguments: [String],
		probe: (KeyboardSourceProbeInvocation) throws -> KeyboardSourceProbeReceipt = { try probeSelectedKeyboardSource($0) },
		writeOutput: (Data) -> Bool = { data in
			do { try FileHandle.standardOutput.write(contentsOf: data); return true }
			catch { return false }
		}
	) -> Int32 {
		guard let invocation = KeyboardSourceProbeInvocation.parse(arguments: arguments) else { return 64 }
		do {
			let receipt = try probe(invocation)
			guard receipt.sourceID == invocation.sourceID,
				receipt.levels.map(\.code) == invocation.codes else { return 70 }
			let output = try JSONEncoder().encode(receipt)
			return writeOutput(output) ? 0 : 74
		} catch {
			return 70
		}
	}
}
