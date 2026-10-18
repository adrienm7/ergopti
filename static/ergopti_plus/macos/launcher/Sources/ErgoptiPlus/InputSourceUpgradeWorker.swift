// Sources/ErgoptiPlus/InputSourceUpgradeWorker.swift
//
// Retains every replacement before mutating the enabled input-source list.
// The same native lookup replaces the proven-fatal AppleScriptObjC bridge.

import Carbon
import Foundation

let kInputSourceUpgradeFlag = "--upgrade-input-sources"

struct InputSourceReplacement: Equatable {
	let oldID: String
	let newID: String
}

enum InputSourceUpgradeError: Error { case invalidReplacements }

enum InputSourceUpgradeResult: Equatable {
	case missing
	case counts(disabled: Int, enabled: Int)
	case refused(operation: String, status: OSStatus)

	var output: String {
		switch self {
		case .missing: return "MISS\n"
		case let .counts(disabled, enabled): return "\(disabled)/\(enabled)\n"
		case let .refused(operation, status): return "\(operation):\(status)\n"
		}
	}
}

/// Effect boundaries stay injectable without modelling native handles as fake pointers.
struct InputSourceUpgradeBackend<Source> {
	let find: (String) throws -> Source?
	let disable: (Source) -> OSStatus
	let enable: (Source) -> OSStatus
	let select: (Source) -> OSStatus
}

/// Preflights every target and retains both sides before the first native effect.
/// An operational refusal stops the sequence; it never fabricates rollback.
func upgradeNativeInputSources<Source>(
	_ replacements: [InputSourceReplacement], backend: InputSourceUpgradeBackend<Source>
) throws -> InputSourceUpgradeResult {
	guard !replacements.isEmpty, replacements.allSatisfy({
		isValidKeyboardSourceIdentifier($0.oldID) && isValidKeyboardSourceIdentifier($0.newID)
	}) else { throw InputSourceUpgradeError.invalidReplacements }
	var targets: [Source] = []
	for replacement in replacements {
		guard let target = try backend.find(replacement.newID) else { return .missing }
		targets.append(target)
	}
	let oldSources = try replacements.map { try backend.find($0.oldID) }
	var disabled = 0
	var enabled = 0
	for (index, target) in targets.enumerated() {
		if let old = oldSources[index] {
			let status = backend.disable(old)
			guard status == noErr else { return .refused(operation: "TISDisableInputSource", status: status) }
			disabled += 1
		}
		let status = backend.enable(target)
		guard status == noErr else { return .refused(operation: "TISEnableInputSource", status: status) }
		enabled += 1
	}
	guard let last = targets.last else { throw InputSourceUpgradeError.invalidReplacements }
	let status = backend.select(last)
	guard status == noErr else { return .refused(operation: "TISSelectInputSource", status: status) }
	return .counts(disabled: disabled, enabled: enabled)
}

/// Headless role; its caller owns the exact process and hard deadline.
enum InputSourceUpgradeWorker {
	static func handles(arguments: [String]) -> Bool {
		arguments.count > 1 && arguments[1] == kInputSourceUpgradeFlag
	}

	static func parse(arguments: [String]) -> [InputSourceReplacement]? {
		guard handles(arguments: arguments), arguments.count >= 4,
			(arguments.count - 2) % 2 == 0 else { return nil }
		var replacements: [InputSourceReplacement] = []
		for index in stride(from: 2, to: arguments.count, by: 2) {
			let old = arguments[index]
			let new = arguments[index + 1]
			guard isValidKeyboardSourceIdentifier(old), isValidKeyboardSourceIdentifier(new) else { return nil }
			replacements.append(InputSourceReplacement(oldID: old, newID: new))
		}
		return replacements
	}

	static func run(
		arguments: [String],
		upgrade: ([InputSourceReplacement]) throws -> InputSourceUpgradeResult = { replacements in
			try upgradeNativeInputSources(replacements, backend: InputSourceUpgradeBackend<TISInputSource>(
				find: findNativeKeyboardInputSource,
				disable: { TISDisableInputSource($0) }, enable: { TISEnableInputSource($0) },
				select: { TISSelectInputSource($0) }))
		},
		writeOutput: (Data) -> Bool = { data in
			do { try FileHandle.standardOutput.write(contentsOf: data); return true }
			catch { return false }
		}
	) -> Int32 {
		guard let replacements = parse(arguments: arguments) else { return 64 }
		do {
			let result = try upgrade(replacements)
			return writeOutput(Data(result.output.utf8)) ? 0 : 74
		} catch {
			return 70
		}
	}
}
