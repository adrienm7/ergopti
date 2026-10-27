// tools/diagnostics/macos_tis_register_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Register Probe
 * DESCRIPTION:
 * A one-file probe for the macOS questions of docs/design/layout-option-emulation.md:
 * can a keyboard layout written while the system runs be registered, enabled and
 * SELECTED without a logout, and what makes TISSelectInputSource refuse it.
 * The first run (probe v1) showed that registering works at once, that an in-place
 * rewrite stays cached, that a removed file leaves a ghost entry until logout, and
 * that selecting a freshly registered loose .keylayout answers -50 (paramErr).
 * This version tries the ways around that refusal, one line each.
 *
 * Run (Terminal, macOS 13 or later, no Xcode project needed):
 *   swiftc -O -o /tmp/ep_tis_probe tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe
 * Optional: add --write-prefs to also try the last resort (P5), which edits the
 * user's AppleEnabledInputSources in com.apple.HIToolbox and puts it back.
 * After a logout and login: /tmp/ep_tis_probe after-logout
 *
 * FEATURES & RATIONALE:
 * 1. Throw-away layouts only, named EPProbe<pid>..., with numeric ids drawn from a range
 *    no installed layout uses (the ids found in the layout folders are listed first and
 *    avoided). The user is put back on the input source they started on and every file
 *    is removed at the end, also when a step fails.
 * 2. One verdict line per question:
 *      P<n> PASS|FAIL|INFO <what was observed>
 *    Send all printed lines back. Nothing else is read or written; P5 writes the user's
 *    preferences only with --write-prefs, and restores them.
 * 3. No event is posted: what a source types is read from its own layout data with
 *    UCKeyTranslate (key code 12, the Q key, no modifier).
 * 4. The only waits are run-loop turns of 0.3 s (P3, P4, P5), to tell « needs time » from
 *    « refused for good ».
 *
 * Questions:
 *   P0  how many numeric ids are already taken, and where this run's ids start
 *   P1  the capabilities of a freshly registered loose .keylayout before selecting
 *   P2  select at once (the v1 result: -50)
 *   P3  select after a run-loop turn, then after re-reading the source list
 *   P4  the same layout installed as a .bundle (Info.plist + Resources/<name>.keylayout)
 *   P5  select once the source is enabled through the user's preferences (--write-prefs)
 *   P6  sources named EPProbe still listed after the cleanup (a ghost until logout is
 *       expected); with the argument after-logout, whether any survived the logout
 * ==============================================================================
 */

import Carbon
import Foundation

let layoutsDirectory = NSString(string: "~/Library/Keyboard Layouts").expandingTildeInPath
let keyCodeQ: UInt16 = 12
let pidTag = "EPProbe\(getpid())"
let writePrefs = CommandLine.arguments.contains("--write-prefs")
var createdPaths: [String] = []
var createdNames: [String] = []

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

/// The numeric ids already declared by the layout files of the user and the system folders.
func takenIdentifiers() -> Set<Int> {
	var taken = Set<Int>()
	let folders = [layoutsDirectory, "/Library/Keyboard Layouts", "/System/Library/Keyboard Layouts"]
	for folder in folders {
		guard let enumerator = FileManager.default.enumerator(atPath: folder) else { continue }
		for case let relative as String in enumerator where relative.hasSuffix(".keylayout") {
			guard let data = FileManager.default.contents(atPath: folder + "/" + relative),
				let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
				let range = text.range(of: "<keyboard ") else { continue }
			let head = text[range.upperBound...].prefix(400)
			if let idRange = head.range(of: " id=\"") {
				let digits = head[idRange.upperBound...].prefix { $0 == "-" || $0.isNumber }
				if let value = Int(digits) { taken.insert(value) }
			}
		}
	}
	return taken
}

var identifierTaken = takenIdentifiers()
var nextIdentifier = -(700_000 + Int(getpid()) % 200_000)

func freshIdentifier() -> Int {
	while identifierTaken.contains(nextIdentifier) { nextIdentifier -= 1 }
	let value = nextIdentifier
	identifierTaken.insert(value)
	nextIdentifier -= 1
	return value
}

func writeLoose(name: String, output: String) throws -> URL {
	try FileManager.default.createDirectory(atPath: layoutsDirectory, withIntermediateDirectories: true)
	let path = "\(layoutsDirectory)/\(name).keylayout"
	try keylayoutText(name: name, id: freshIdentifier(), output: output).write(toFile: path, atomically: true, encoding: .utf8)
	createdPaths.append(path)
	createdNames.append(name)
	return URL(fileURLWithPath: path)
}

func writeBundle(name: String, output: String) throws -> URL {
	let root = "\(layoutsDirectory)/\(name).bundle"
	let resources = root + "/Contents/Resources"
	try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
	try keylayoutText(name: name, id: freshIdentifier(), output: output)
		.write(toFile: "\(resources)/\(name).keylayout", atomically: true, encoding: .utf8)
	let identifier = "org.epprobe.keylayout.\(name)"
	let info: [String: Any] = [
		"CFBundleIdentifier": identifier,
		"CFBundleName": name,
		"CFBundleVersion": "1",
		"CFBundleShortVersionString": "1",
		"CFBundlePackageType": "BNDL",
		"KLInfo_\(name)": ["TISInputSourceID": identifier, "TISIntendedLanguage": "en-US"],
	]
	let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
	try data.write(to: URL(fileURLWithPath: root + "/Contents/Info.plist"))
	createdPaths.append(root)
	createdNames.append(name)
	return URL(fileURLWithPath: root)
}

// MARK: - Input-source reads

func property(_ source: TISInputSource, _ key: CFString) -> String? {
	guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
	return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
}

func flag(_ source: TISInputSource, _ key: CFString) -> String {
	guard let pointer = TISGetInputSourceProperty(source, key) else { return "nil" }
	return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(pointer).takeUnretainedValue()) ? "true" : "false"
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

func capabilities(_ source: TISInputSource) -> String {
	return "selectCapable=\(flag(source, kTISPropertyInputSourceIsSelectCapable)) "
		+ "enableCapable=\(flag(source, kTISPropertyInputSourceIsEnableCapable)) "
		+ "enabled=\(flag(source, kTISPropertyInputSourceIsEnabled)) "
		+ "selected=\(flag(source, kTISPropertyInputSourceIsSelected)) "
		+ "category=\(property(source, kTISPropertyInputSourceCategory) ?? "nil") "
		+ "type=\(property(source, kTISPropertyInputSourceType) ?? "nil") "
		+ "id=\(identifier(source))"
}

func verdict(_ step: String, _ pass: Bool?, _ text: String) {
	let word = pass == nil ? "INFO" : (pass! ? "PASS" : "FAIL")
	print("\(step) \(word) \(text)")
}

func turn(_ seconds: Double) {
	RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

/// Enables, selects and reads back; the line says every status and what the Q key types.
func trySelect(_ step: String, _ label: String, _ name: String) {
	guard let source = find(name: name) else {
		verdict(step, false, "\(label): \(name) is not listed")
		return
	}
	let enable = TISEnableInputSource(source)
	let select = TISSelectInputSource(source)
	let now = currentIdentifier()
	verdict(step, select == noErr && now == identifier(source),
		"\(label): enable \(enable), select \(select), current \(now), Q types '\(typed(source))'")
}

// MARK: - User preferences (P5 only, with --write-prefs)

func defaultsTool(_ arguments: [String], input: Data? = nil) -> (Int32, Data) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
	process.arguments = arguments
	let output = Pipe()
	process.standardOutput = output
	if let input = input {
		let pipe = Pipe()
		process.standardInput = pipe
		pipe.fileHandleForWriting.write(input)
		pipe.fileHandleForWriting.closeFile()
	}
	do { try process.run() } catch { return (-1, Data()) }
	let data = output.fileHandleForReading.readDataToEndOfFile()
	process.waitUntilExit()
	return (process.terminationStatus, data)
}

/// The domain as exported, so that it can be put back as it was.
func exportDomain() -> Data? {
	let (status, data) = defaultsTool(["export", "com.apple.HIToolbox", "-"])
	return status == 0 ? data : nil
}

func enabledListContains(_ fragment: String) -> Bool {
	let (_, data) = defaultsTool(["read", "com.apple.HIToolbox", "AppleEnabledInputSources"])
	return String(data: data, encoding: .utf8)?.contains(fragment) ?? false
}

// MARK: - After-logout mode

if CommandLine.arguments.dropFirst().first == "after-logout" {
	let leftover = inventory().compactMap { property($0, kTISPropertyLocalizedName) }.filter { $0.hasPrefix("EPProbe") }
	verdict("P6", leftover.isEmpty, "after a logout, EPProbe sources still listed: \(leftover.isEmpty ? "none" : leftover.joined(separator: ", "))")
	exit(0)
}

// MARK: - The run

let originalSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
print("start current source: \(currentIdentifier())")
verdict("P0", nil, "\(identifierTaken.count) numeric layout ids already taken; this run draws from \(nextIdentifier) downward")

let originalDomain = writePrefs ? exportDomain() : nil
if writePrefs && originalDomain == nil {
	print("P5 FAIL cannot export com.apple.HIToolbox, so --write-prefs is refused and nothing will be written")
}

func cleanUp() {
	if let original = originalSource { _ = TISSelectInputSource(original) }
	for name in createdNames {
		if let source = find(name: name) { _ = TISDisableInputSource(source) }
	}
	for path in createdPaths { try? FileManager.default.removeItem(atPath: path) }
	if let saved = originalDomain {
		let (status, _) = defaultsTool(["import", "com.apple.HIToolbox", "-"], input: saved)
		verdict("P5", nil, "preferences put back from the export (defaults import status \(status))")
	}
}

do {
	// P1 and P2: a loose file with a unique id; its capabilities, then an immediate select.
	let loose = pidTag + "a"
	let looseURL = try writeLoose(name: loose, output: "A")
	let registered = TISRegisterInputSource(looseURL as CFURL)
	if let source = find(name: loose) {
		verdict("P1", nil, "loose file, register status \(registered), before selecting: \(capabilities(source))")
		trySelect("P2", "loose file, select at once", loose)
	} else {
		verdict("P1", false, "loose file, register status \(registered): not listed")
	}

	// P3: the same source after a run-loop turn, then after the list is read again.
	turn(0.3)
	trySelect("P3", "loose file, after a 0.3 s run-loop turn", loose)
	turn(0.3)
	_ = inventory()
	if let source = find(name: loose) {
		verdict("P3", nil, "loose file, after re-reading the list: \(capabilities(source))")
	}
	trySelect("P3", "loose file, after re-reading the list", loose)

	// P4: the same layout as a bundle.
	let bundle = pidTag + "b"
	let bundleURL = try writeBundle(name: bundle, output: "B")
	let bundleStatus = TISRegisterInputSource(bundleURL as CFURL)
	if let source = find(name: bundle) {
		verdict("P4", nil, "bundle, register status \(bundleStatus), before selecting: \(capabilities(source))")
		trySelect("P4", "bundle, select at once", bundle)
		turn(0.3)
		trySelect("P4", "bundle, after a 0.3 s run-loop turn", bundle)
	} else {
		verdict("P4", false, "bundle, register status \(bundleStatus): not listed")
	}

	// P5: the last resort, only with --write-prefs and a verified export to put back.
	if writePrefs && originalDomain != nil {
		let name = pidTag + "c"
		let url = try writeLoose(name: name, output: "C")
		_ = TISRegisterInputSource(url as CFURL)
		let entry = "<dict><key>InputSourceKind</key><string>Keyboard Layout</string><key>KeyboardLayout Name</key><string>\(name)</string></dict>"
		let (status, _) = defaultsTool(["write", "com.apple.HIToolbox", "AppleEnabledInputSources", "-array-add", entry])
		verdict("P5", nil, "added \(name) to AppleEnabledInputSources (defaults status \(status), listed there: \(enabledListContains(name)))")
		turn(0.3)
		trySelect("P5", "enabled through the preferences, select", name)
	} else if !writePrefs {
		verdict("P5", nil, "skipped: pass --write-prefs to try enabling through com.apple.HIToolbox")
	}
} catch {
	print("probe error: \(error)")
}

cleanUp()
let ghosts = inventory().compactMap { property($0, kTISPropertyLocalizedName) }.filter { $0.hasPrefix(pidTag) }
verdict("P6", ghosts.isEmpty, "after the cleanup, probe sources still listed: \(ghosts.isEmpty ? "none" : ghosts.joined(separator: ", ")) (a ghost until logout is expected)")
verdict("END", nil, "restored to \(currentIdentifier()); started on \(identifier(originalSource)); run again with 'after-logout' after a logout for P6")
