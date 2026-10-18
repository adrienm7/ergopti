// Sources/ErgoptiPlus/InputSourceSelectionWorker.swift
//
// Isolates Carbon input-source selection from the Hammerspoon event loop.
// AppleScriptObjC's dictionary bridge aborts before returning a native status.

import Carbon
import Darwin
import Foundation

let kInputSourceSelectionFlag = "--select-input-source"

/// Shared argv boundary for native input-source mutation roles.
func isValidKeyboardSourceIdentifier(_ identifier: String) -> Bool {
	!identifier.isEmpty && identifier.utf8.count <= kMaximumKeyboardSourceIDBytes
		&& !identifier.utf8.contains(0)
}

enum InputSourceSelectionError: Error {
	case unavailableInventory, ambiguousIdentifier, wrongThread
}

enum InputSourceSelectionResult: Equatable {
	case missing
	case status(OSStatus)

	var output: String {
		switch self {
		case .missing: return "MISS\n"
		case .status(let status): return "\(status)\n"
		}
	}
}

/// Retains the exact native source without bridging a filtered dictionary.
/// Selection and enabled-list mutations share this side-effect-free lookup.
func findNativeKeyboardInputSource(_ identifier: String) throws -> TISInputSource? {
	guard Thread.isMainThread else { throw InputSourceSelectionError.wrongThread }
	guard let copied = TISCreateInputSourceList(nil, true),
		let inventory = copied.takeRetainedValue() as? [TISInputSource] else {
		throw InputSourceSelectionError.unavailableInventory
	}
	var match: TISInputSource?
	for source in inventory {
		guard try selectedKeyboardSourceID(source) == identifier else { continue }
		if match != nil { throw InputSourceSelectionError.ambiguousIdentifier }
		match = source
	}
	return match
}

/// Returns Carbon's actual acceptance status; a missing source never mutates state.
func selectNativeKeyboardInputSource(_ identifier: String) throws -> InputSourceSelectionResult {
	guard let source = try findNativeKeyboardInputSource(identifier) else { return .missing }
	return .status(TISSelectInputSource(source))
}

/// Headless role of the same signed executable; the Lua owner bounds its lifetime.
enum InputSourceSelectionWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == kInputSourceSelectionFlag
	}

	static func run(
		arguments: [String],
		select: (String) throws -> InputSourceSelectionResult = selectNativeKeyboardInputSource,
		writeOutput: (Data) -> Bool = { data in
			do { try FileHandle.standardOutput.write(contentsOf: data); return true }
			catch { return false }
		}
	) -> Int32 {
		guard arguments.count == 3, handles(arguments: arguments) else { return 64 }
		let identifier = arguments[2]
		guard isValidKeyboardSourceIdentifier(identifier) else { return 64 }
		do {
			let result = try select(identifier)
			return writeOutput(Data(result.output.utf8)) ? 0 : 74
		} catch {
			return 70
		}
	}
}
