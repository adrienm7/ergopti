// tools/test/macos-layout-bundle-native.swift

/**
 * ==============================================================================
 * MODULE: macOS Layout Bundle Native Probe
 * DESCRIPTION:
 * Registers an installed keyboard layout bundle with the Text Input Sources
 * API, requires each of its input sources to be listed with an icon, and
 * types the plan's vectors through UCKeyTranslate on the layout data macOS
 * read from the installed files. Prints one JSON receipt; exits 1 on any
 * missing source or wrong character. Driven by macos-layout-bundle-native.cjs.
 * ==============================================================================
 */

import Carbon
import Foundation

struct Press: Decodable {
	let code: UInt16
	let modifiers: UInt32
}

struct Vector: Decodable {
	let variant: String
	let input_source: String
	let name: String
	let keys: [Press]
	let expected: String
}

struct Plan: Decodable {
	let bundle: String
	let sources: [String]
	let vectors: [Vector]
}

/// The property of a source as a Swift object, or nil when macOS gives none.
func property(_ source: TISInputSource, _ key: CFString) -> AnyObject? {
	guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
	return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
}

/// The installed source with this identifier, enabled or not.
func installedSource(_ identifier: String) -> TISInputSource? {
	let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
	guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
	else { return nil }
	return list.first
}

/// Types one sequence of presses, carrying the dead-key state between them.
func type(_ data: CFData, _ presses: [Press]) -> String {
	guard let bytes = CFDataGetBytePtr(data) else { return "<no layout bytes>" }
	return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
		var deadKeyState: UInt32 = 0
		var typed = ""
		for press in presses {
			var length = 0
			var units = [UniChar](repeating: 0, count: 16)
			let status = UCKeyTranslate(
				layout, press.code, UInt16(kUCKeyActionDown), press.modifiers,
				UInt32(LMGetKbdType()), 0, &deadKeyState, units.count, &length, &units)
			if status != noErr { return "<UCKeyTranslate \(status)>" }
			typed += String(utf16CodeUnits: units, count: length)
		}
		return typed
	}
}

let arguments = CommandLine.arguments
guard arguments.count == 2,
	let planData = FileManager.default.contents(atPath: arguments[1]),
	let plan = try? JSONDecoder().decode(Plan.self, from: planData)
else {
	FileHandle.standardError.write("usage: layout-bundle-probe <plan.json>\n".data(using: .utf8)!)
	exit(2)
}

var receipt: [String: Any] = [:]
var failures: [String] = []
let registered = TISRegisterInputSource(URL(fileURLWithPath: plan.bundle) as CFURL)
receipt["register_status"] = Int(registered)
if registered != noErr { failures.append("TISRegisterInputSource answered \(registered)") }

var layouts: [String: CFData] = [:]
var sources: [[String: Any]] = []
for identifier in plan.sources {
	guard let source = installedSource(identifier) else {
		failures.append("\(identifier) is not listed")
		continue
	}
	let icon = property(source, kTISPropertyIconImageURL) as? URL
	let data = property(source, kTISPropertyUnicodeKeyLayoutData)
	sources.append([
		"id": identifier,
		"name": (property(source, kTISPropertyLocalizedName) as? String) ?? "",
		"icon": icon?.lastPathComponent ?? "",
		"layout_bytes": data.map { CFDataGetLength(($0 as! CFData)) } ?? 0,
	])
	if icon == nil { failures.append("\(identifier) has no icon") }
	if let data = data { layouts[identifier] = (data as! CFData) } else {
		failures.append("\(identifier) has no Unicode layout data")
	}
}
receipt["sources"] = sources

var typedCount = 0
for vector in plan.vectors {
	guard let data = layouts[vector.input_source] else { continue }
	let typed = type(data, vector.keys)
	typedCount += 1
	if typed != vector.expected {
		failures.append("\(vector.variant) \(vector.name): typed \(typed.debugDescription), expected \(vector.expected.debugDescription)")
	}
}
receipt["vectors"] = plan.vectors.count
receipt["typed"] = typedCount
receipt["keyboard_type"] = Int(LMGetKbdType())
receipt["failures"] = failures

let json = try! JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
print(String(data: json, encoding: .utf8)!)
exit(failures.isEmpty && typedCount == plan.vectors.count ? 0 : 1)
