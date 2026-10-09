// Sources/ErgoptiPlus/KeyboardGeometry.swift

// ==============================================================================
// MODULE: Native Per-Event Keyboard Geometry
// DESCRIPTION:
// Captures Carbon's geometry classification for every nonnegative SInt16 keyboard
// model before launching the Lua child. Contiguous equal classifications share
// one range; an unknown model never inherits another keyboard's form.
// ==============================================================================

import Carbon
import Foundation

let kKeyboardGeometryEnvironment = "ERGOPTI_KEYBOARD_GEOMETRY_V1"

enum KeyboardGeometryForm: String, Codable, Equatable {
	case ansi, iso, jis, unknown

	/// Interprets the native layout type, not the event's keyboard model identifier.
	static func classify(_ layoutType: UInt32) -> Self {
		switch layoutType {
		case UInt32(kKeyboardANSI): return .ansi
		case UInt32(kKeyboardISO): return .iso
		case UInt32(kKeyboardJIS): return .jis
		default: return .unknown
		}
	}
}

struct KeyboardGeometryRange: Codable, Equatable {
	let first: Int
	let last: Int
	let form: KeyboardGeometryForm
}

enum KeyboardGeometryError: Error {
	case invalidPartition, invalidEncoding
}

struct KeyboardGeometryMap {
	static let version = 1
	static let maximum = Int(Int16.max)
	let ranges: [KeyboardGeometryRange]
	let environmentValue: String

	private struct Envelope: Encodable {
		let version: Int
		let maximum: Int
		let ranges: [KeyboardGeometryRange]
	}

	/// Admits only a complete, ordered, minimally compressed domain partition.
	init(ranges: [KeyboardGeometryRange]) throws {
		var next = 0
		var previous: KeyboardGeometryForm?
		for range in ranges {
			guard range.first == next, range.last >= range.first,
				range.last <= Self.maximum, range.form != previous else {
				throw KeyboardGeometryError.invalidPartition
			}
			next = range.last + 1
			previous = range.form
		}
		guard next == Self.maximum + 1 else { throw KeyboardGeometryError.invalidPartition }
		let encoder = JSONEncoder()
		encoder.outputFormatting = [.sortedKeys]
		let data = try encoder.encode(Envelope(version: Self.version,
			maximum: Self.maximum, ranges: ranges))
		guard let value = String(data: data, encoding: .utf8) else {
			throw KeyboardGeometryError.invalidEncoding
		}
		self.ranges = ranges
		self.environmentValue = value
	}

	/// Reads each supported event-model identifier exactly once through Carbon.
	/// No global keyboard selection or empirical model-number table participates.
	static func capture(
		layoutTypeForKeyboard: (Int16) -> UInt32 = { KBGetLayoutType($0) }
	) throws -> Self {
		var ranges: [KeyboardGeometryRange] = []
		var first = 0
		var current = KeyboardGeometryForm.classify(layoutTypeForKeyboard(0))
		for identifier in 1...maximum {
			let form = KeyboardGeometryForm.classify(layoutTypeForKeyboard(Int16(identifier)))
			if form != current {
				ranges.append(KeyboardGeometryRange(first: first, last: identifier - 1, form: current))
				first = identifier
				current = form
			}
		}
		ranges.append(KeyboardGeometryRange(first: first, last: maximum, form: current))
		return try Self(ranges: ranges)
	}
}
