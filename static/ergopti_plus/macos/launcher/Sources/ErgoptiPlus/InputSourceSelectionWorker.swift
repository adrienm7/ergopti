// Sources/ErgoptiPlus/InputSourceSelectionWorker.swift
//
// Isolates Carbon input-source selection from the Hammerspoon event loop.
// AppleScriptObjC's dictionary bridge aborts before returning a native status.

import Carbon
import Darwin
import Foundation

let kInputSourceSelectionFlag = "--select-input-source"
let kInputSourceSelectionByNameFlag = "--select-input-source-by-name"

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

/// Copies one complete native snapshot without bridging a filtered dictionary.
func copyNativeKeyboardInputSources() throws -> [TISInputSource] {
	guard Thread.isMainThread else { throw InputSourceSelectionError.wrongThread }
	guard let copied = TISCreateInputSourceList(nil, true),
		let inventory = copied.takeRetainedValue() as? [TISInputSource] else {
		throw InputSourceSelectionError.unavailableInventory
	}
	return inventory
}

/// Resolves identity before name, rejecting ambiguity before any native mutation.
/// Both properties belong to the same retained source, never separate snapshots.
func findUniqueKeyboardInputSource<Source>(
	_ identifier: String, localisedName: String?, inventory: [Source],
	sourceID: (Source) throws -> String, sourceName: (Source) -> String?
) throws -> Source? {
	var match: Source?
	for source in inventory {
		guard try sourceID(source) == identifier else { continue }
		if match != nil { throw InputSourceSelectionError.ambiguousIdentifier }
		match = source
	}
	if match != nil || localisedName == nil { return match }
	for source in inventory {
		guard sourceName(source) == localisedName else { continue }
		if match != nil { throw InputSourceSelectionError.ambiguousIdentifier }
		match = source
	}
	return match
}

/// Retains the exact source; enabled-list mutations also use this pure lookup.
func findNativeKeyboardInputSource(_ identifier: String) throws -> TISInputSource? {
	try findUniqueKeyboardInputSource(identifier, localisedName: nil,
		inventory: copyNativeKeyboardInputSources(), sourceID: selectedKeyboardSourceID,
		sourceName: { _ in nil })
}

/// Selects only after the complete inventory proves a unique identity or name.
func selectKeyboardInputSource<Source>(
	_ identifier: String, localisedName: String, inventory: [Source],
	sourceID: (Source) throws -> String, sourceName: (Source) -> String?,
	select: (Source) -> OSStatus
) throws -> InputSourceSelectionResult {
	guard let source = try findUniqueKeyboardInputSource(identifier, localisedName: localisedName,
		inventory: inventory, sourceID: sourceID, sourceName: sourceName) else { return .missing }
	return .status(select(source))
}

/// Uses the native localized property on the same retained inventory as its ID.
func selectNativeKeyboardInputSourceByName(_ name: String, identifier: String) throws -> InputSourceSelectionResult {
	try selectKeyboardInputSource(identifier, localisedName: name,
		inventory: copyNativeKeyboardInputSources(), sourceID: selectedKeyboardSourceID,
		sourceName: { source in
			guard let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return nil }
			return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
		}, select: { TISSelectInputSource($0) })
}

/// Returns Carbon's actual acceptance status; a missing source never mutates state.
func selectNativeKeyboardInputSource(_ identifier: String) throws -> InputSourceSelectionResult {
	guard let source = try findNativeKeyboardInputSource(identifier) else { return .missing }
	return .status(TISSelectInputSource(source))
}

/// Headless role of the same signed executable; the Lua owner bounds its lifetime.
enum InputSourceSelectionWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && [kInputSourceSelectionFlag, kInputSourceSelectionByNameFlag].contains(arguments[1])
	}

	static func run(
		arguments: [String],
		select: (String) throws -> InputSourceSelectionResult = selectNativeKeyboardInputSource,
		selectByName: (String, String) throws -> InputSourceSelectionResult = selectNativeKeyboardInputSourceByName,
		writeOutput: (Data) -> Bool = { data in
			do { try FileHandle.standardOutput.write(contentsOf: data); return true }
			catch { return false }
		}
	) -> Int32 {
		guard handles(arguments: arguments) else { return 64 }
		let byName = arguments[1] == kInputSourceSelectionByNameFlag
		guard arguments.count == (byName ? 4 : 3),
			arguments.dropFirst(2).allSatisfy(isValidKeyboardSourceIdentifier) else { return 64 }
		do {
			let result = try (byName ? selectByName(arguments[2], arguments[3]) : select(arguments[2]))
			return writeOutput(Data(result.output.utf8)) ? 0 : 74
		} catch {
			return 70
		}
	}
}
