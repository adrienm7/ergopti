// tools/diagnostics/macos_tis_register_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Register Probe
 * DESCRIPTION:
 * A one-file probe that answers the macOS questions M1 to M6 of
 * docs/design/layout-option-emulation.md on a real Mac: whether a keyboard
 * layout file written while the system runs can be registered, enabled,
 * selected, replaced by a newer build and retired without a logout.
 *
 * Run (Terminal, macOS 13 or later, no Xcode project needed):
 *   swiftc -O -o /tmp/ep_tis_probe tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe
 *
 * FEATURES & RATIONALE:
 * 1. It changes only two throw-away layouts named "EPProbe<pid>v1" and
 *    "EPProbe<pid>v2" in ~/Library/Keyboard Layouts, and puts the user back on
 *    the input source they started with. Both files are removed at the end,
 *    also when a step fails.
 * 2. One verdict line per question, then a closing line:
 *      M<n> PASS|FAIL|INFO <what was observed>
 *    Send all printed lines back. Nothing else is read or written.
 * 3. No event is posted: what a source types is read from its own layout data
 *    with UCKeyTranslate (key code 12, the Q key, no modifier).
 * 4. The only wait is a single two-second pause in M1, to tell « listed at
 *    once » from « listed later ».
 *
 * After the run, log out and in once and run the probe again with the argument
 * "after-logout": it only reports whether any EPProbe source is still listed
 * (the second half of M5).
 * ==============================================================================
 */

import Carbon
import Foundation

let layoutsDirectory = NSString(string: "~/Library/Keyboard Layouts").expandingTildeInPath
let keyCodeQ: UInt16 = 12
let pidTag = "EPProbe\(getpid())"
let nameV1 = pidTag + "v1"
let nameV2 = pidTag + "v2"

// MARK: - Layout files

func keylayoutText(name: String, id: Int, output: String) -> String {
	return """
	<?xml version="1.1" encoding="UTF-8"?>
	<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">
	<keyboard group="126" id="\(id)" name="\(name)" maxout="1">
	 <layouts><layout first="0" last="0" modifiers="m" mapSet="s"/></layouts>
	 <modifierMap id="m" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>
	 <keyMapSet id="s"><keyMap index="0"><key code="12" output="\(output)"/></keyMap></keyMapSet>
	</keyboard>
	"""
}

func filePath(_ name: String) -> String { return "\(layoutsDirectory)/\(name).keylayout" }

func writeLayout(name: String, id: Int, output: String) throws {
	try FileManager.default.createDirectory(atPath: layoutsDirectory, withIntermediateDirectories: true)
	try keylayoutText(name: name, id: id, output: output)
		.write(toFile: filePath(name), atomically: true, encoding: .utf8)
}

// MARK: - Input-source reads

func property(_ source: TISInputSource, _ key: CFString) -> String? {
	guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
	return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func inventory() -> [TISInputSource] {
	guard let copied = TISCreateInputSourceList(nil, true) else { return [] }
	return (copied.takeRetainedValue() as? [TISInputSource]) ?? []
}

func find(name: String) -> TISInputSource? {
	return inventory().first { property($0, kTISPropertyLocalizedName) == name }
}

func identifier(_ source: TISInputSource?) -> String {
	guard let source = source else { return "<not listed>" }
	return property(source, kTISPropertyInputSourceID) ?? "<no id>"
}

func currentIdentifier() -> String {
	guard let current = TISCopyCurrentKeyboardLayoutInputSource() else { return "<none>" }
	return identifier(current.takeRetainedValue())
}

func isEnabled(_ source: TISInputSource) -> Bool {
	guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
	return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue())
}

/// What the Q key types on this source, from its own layout data.
func typed(_ source: TISInputSource) -> String {
	guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "<no layout data>" }
	let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
	guard let bytes = CFDataGetBytePtr(data) else { return "<empty layout data>" }
	let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
	var dead: UInt32 = 0
	var length = 0
	var characters = [UniChar](repeating: 0, count: 4)
	let status = UCKeyTranslate(layout, keyCodeQ, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
		OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, characters.count, &length, &characters)
	return status == noErr ? String(utf16CodeUnits: characters, count: length) : "<UCKeyTranslate \(status)>"
}

func verdict(_ step: String, _ pass: Bool?, _ text: String) {
	let word = pass == nil ? "INFO" : (pass! ? "PASS" : "FAIL")
	print("\(step) \(word) \(text)")
}

// MARK: - After-logout mode

if CommandLine.arguments.dropFirst().first == "after-logout" {
	let leftover = inventory().compactMap { property($0, kTISPropertyLocalizedName) }.filter { $0.hasPrefix("EPProbe") }
	verdict("M5b", leftover.isEmpty, "after a logout, EPProbe sources still listed: \(leftover.isEmpty ? "none" : leftover.joined(separator: ", "))")
	exit(0)
}

// MARK: - The run

let originalSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
print("start current source: \(currentIdentifier())")

func cleanUp() {
	if let original = originalSource { _ = TISSelectInputSource(original) }
	for name in [nameV1, nameV2] {
		if let source = find(name: name) { _ = TISDisableInputSource(source) }
		try? FileManager.default.removeItem(atPath: filePath(name))
	}
}

do {
	// M1 and M2: register a file written just now; is it listed without a logout, and under which id?
	try writeLayout(name: nameV1, id: -24101, output: "A")
	let url1 = URL(fileURLWithPath: filePath(nameV1)) as CFURL
	let registerStatus1 = TISRegisterInputSource(url1)
	let listedAtOnce = find(name: nameV1)
	verdict("M1", registerStatus1 == noErr && listedAtOnce != nil,
		"TISRegisterInputSource status \(registerStatus1), listed immediately: \(listedAtOnce != nil)")
	if listedAtOnce == nil {
		sleep(2)
		verdict("M1", nil, "listed two seconds later: \(find(name: nameV1) != nil)")
	}
	verdict("M2", nil, "source id of a bare user .keylayout: \(identifier(find(name: nameV1)))")

	// M4: a new name (new id) types the new cells after enable and select, no logout.
	if let first = find(name: nameV1) {
		let enable1 = TISEnableInputSource(first)
		let select1 = TISSelectInputSource(first)
		verdict("M4a", enable1 == noErr && select1 == noErr && currentIdentifier() == identifier(first) && typed(first) == "A",
			"build v1: enable \(enable1), select \(select1), current \(currentIdentifier()), Q types '\(typed(first))' (expected 'A')")
	} else {
		verdict("M4a", false, "build v1 is not listed, so it cannot be enabled")
	}

	try writeLayout(name: nameV2, id: -24102, output: "B")
	let registerStatus2 = TISRegisterInputSource(URL(fileURLWithPath: filePath(nameV2)) as CFURL)
	if let second = find(name: nameV2) {
		let enable2 = TISEnableInputSource(second)
		let select2 = TISSelectInputSource(second)
		verdict("M4b", registerStatus2 == noErr && enable2 == noErr && select2 == noErr && currentIdentifier() == identifier(second) && typed(second) == "B",
			"build v2 (new name): register \(registerStatus2), enable \(enable2), select \(select2), current \(currentIdentifier()), Q types '\(typed(second))' (expected 'B')")
	} else {
		verdict("M4b", false, "build v2 is not listed after register status \(registerStatus2)")
	}

	// M3: rewrite build v1 in place, same name and id, without toggling anything.
	try writeLayout(name: nameV1, id: -24101, output: "Z")
	_ = TISRegisterInputSource(url1)
	if let again = find(name: nameV1) {
		let seen = typed(again)
		verdict("M3", nil, "same name rewritten in place: Q types '\(seen)' (A means the old cells are cached, Z means the new ones are read)")
	} else {
		verdict("M3", nil, "build v1 disappeared after the in-place rewrite")
	}

	// M6 and M5: retire build v1 while build v2 is selected; the selection must survive.
	let selectedBefore = currentIdentifier()
	if let old = find(name: nameV1) {
		let disable1 = TISDisableInputSource(old)
		verdict("M6", currentIdentifier() == selectedBefore,
			"disabled v1 (status \(disable1)); current source before \(selectedBefore), after \(currentIdentifier())")
		try? FileManager.default.removeItem(atPath: filePath(nameV1))
		let afterRemoval = find(name: nameV1)
		let enabledLeft = afterRemoval.map(isEnabled) ?? false
		verdict("M5a", afterRemoval == nil,
			"v1 after disable and file removal: listed \(afterRemoval != nil), enabled \(enabledLeft) (still listed means a ghost entry)")
	} else {
		verdict("M6", false, "build v1 was not listed when retirement was due")
	}
} catch {
	print("probe error: \(error)")
}

cleanUp()
verdict("END", nil, "restored to \(currentIdentifier()); started on \(identifier(originalSource)); run again with 'after-logout' after a logout for M5b")
