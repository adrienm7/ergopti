// tools/diagnostics/macos_tis_register_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Register Probe
 * DESCRIPTION:
 * A one-file probe for the macOS questions of docs/design/layout-option-emulation.md:
 * can a keyboard layout written while the system runs be registered, enabled and
 * SELECTED without a logout, and by which route.
 *
 * What the first two runs showed (macOS 26, arm64):
 *   - TISRegisterInputSource lists a loose .keylayout at once (id org.unknown.keylayout.<Name>);
 *   - TISEnableInputSource answers 0 but the source stays enabled=false, so
 *     TISSelectInputSource answers -50 (paramErr), at once, after a run-loop turn and after
 *     re-reading the list;
 *   - an in-place rewrite stays cached, and a disabled source whose file was removed stays
 *     listed until logout;
 *   - a bundle built with a made-up identifier was not listed at all.
 * The driver's own install path (macos/modules/keymap/input_sources.lua) does not call
 * TISEnableInputSource for a layout: it adds {InputSourceKind "Keyboard Layout",
 * "KeyboardLayout ID" (the integer id of the .keylayout), "KeyboardLayout Name"} to
 * AppleEnabledInputSources of com.apple.HIToolbox and restarts SystemUIServer. This
 * version tests that route (P5), a bundle shaped exactly like the shipped Ergopti bundle
 * (P4), and replacing a layout inside the already enabled Ergopti bundle (P7).
 *
 * Run (Terminal, macOS 13 or later, no Xcode project needed):
 *   swiftc -O -o /tmp/ep_tis_probe tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe
 * Flags (each writes more; none is on by default):
 *   --write-prefs       P5: enable the throw-away layouts through com.apple.HIToolbox
 *                       (exported first, imported back at the end) and restart SystemUIServer
 *   --replace-ergopti   P7: add a layout under a new name and id inside the bundle that holds
 *                       the current input source (copied to a backup first, put back at the end)
 * After a logout and login: /tmp/ep_tis_probe after-logout
 *
 * FEATURES & RATIONALE:
 * 1. Throw-away layouts only, named EPProbe<pid>..., with numeric ids outside every layout
 *    file found in the layout folders. The user is put back on the input source they started
 *    on and every file the probe wrote is removed at the end, also when a step fails.
 * 2. One verdict line per question:  P<n> PASS|FAIL|INFO <what was observed>
 *    Send all printed lines back.
 * 3. No event is posted: what a source types is read from its own layout data with
 *    UCKeyTranslate (key code 12, the Q key, no modifier).
 * 4. The only waits are run-loop turns of 0.3 s to 1.5 s, to tell « needs time » from
 *    « refused for good ».
 *
 * Questions:
 *   P0  how many numeric ids are taken, and where this run's ids start
 *   P1  capabilities of a freshly registered loose .keylayout, before selecting
 *   P2  select at once (TISEnableInputSource then TISSelectInputSource)
 *   P3  the same after a run-loop turn and after re-reading the list
 *   P4  the same layout as a bundle shaped like the Ergopti bundle: listed? capabilities, select
 *   P5  --write-prefs: enabled through AppleEnabledInputSources, SystemUIServer restarted, then
 *       enabled? select? (for the loose file and for the bundle)
 *   P7  --replace-ergopti: the new layout inside the enabled Ergopti bundle: listed? enabled by
 *       inheritance? select? and the bundle put back
 *   P6  sources named EPProbe still listed after the cleanup (a ghost until logout is expected);
 *       with the argument after-logout, whether any survived the logout
 * ==============================================================================
 */

import Carbon
import Foundation

let layoutsDirectory = NSString(string: "~/Library/Keyboard Layouts").expandingTildeInPath
let keyCodeQ: UInt16 = 12
let pidTag = "EPProbe\(getpid())"
let writePrefs = CommandLine.arguments.contains("--write-prefs")
let replaceErgopti = CommandLine.arguments.contains("--replace-ergopti")
var createdPaths: [String] = []
var createdNames: [String] = []
var layoutIdentifiers: [String: Int] = [:]

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
	let id = freshIdentifier()
	layoutIdentifiers[name] = id
	try keylayoutText(name: name, id: id, output: output).write(toFile: path, atomically: true, encoding: .utf8)
	createdPaths.append(path)
	createdNames.append(name)
	return URL(fileURLWithPath: path)
}

/// A bundle shaped like the shipped Ergopti bundle: a com.apple.keyboardlayout.* identifier,
/// KLInfo_<layout name> with the same keys, version.plist, and the display name in a
/// localized InfoPlist.strings (UTF-16, as the shipped one).
func writeBundle(name: String, output: String) throws -> URL {
	let root = "\(layoutsDirectory)/\(name).bundle"
	let resources = root + "/Contents/Resources"
	try FileManager.default.createDirectory(atPath: resources + "/en.lproj", withIntermediateDirectories: true)
	let id = freshIdentifier()
	layoutIdentifiers[name] = id
	try keylayoutText(name: name, id: id, output: output)
		.write(toFile: "\(resources)/\(name).keylayout", atomically: true, encoding: .utf8)
	let sourceID = "com.apple.keyboardlayout.\(name.lowercased())"
	let info: [String: Any] = [
		"CFBundleIdentifier": sourceID,
		"CFBundleName": name,
		"CFBundleShortVersionString": "1.0.0",
		"CFBundleVersion": "1.0.0",
		"KLInfo_\(name)": [
			"TICapsLockLanguageSwitchCapable": true,
			"TISIconIsTemplate": false,
			"TISInputSourceID": sourceID,
			"TISIntendedLanguage": "fr",
		],
	]
	try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
		.write(to: URL(fileURLWithPath: root + "/Contents/Info.plist"))
	let version: [String: Any] = ["BuildVersion": "1.0.0", "ProjectName": name, "SourceVersion": "1.0.0"]
	try PropertyListSerialization.data(fromPropertyList: version, format: .xml, options: 0)
		.write(to: URL(fileURLWithPath: root + "/Contents/version.plist"))
	try "\"\(name)\" = \"\(name)\";\n".data(using: .utf16)!
		.write(to: URL(fileURLWithPath: resources + "/en.lproj/InfoPlist.strings"))
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

// MARK: - Processes and user preferences

@discardableResult
func run(_ path: String, _ arguments: [String], input: Data? = nil) -> (Int32, Data) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: path)
	process.arguments = arguments
	let output = Pipe()
	process.standardOutput = output
	process.standardError = Pipe()
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
	let (status, data) = run("/usr/bin/defaults", ["export", "com.apple.HIToolbox", "-"])
	return status == 0 ? data : nil
}

/// Restarts the agent that reads the enabled list, the way the driver's own install does.
func restartInputSourceAgent() -> Int32 {
	return run("/bin/launchctl", ["kickstart", "-k", "user/\(getuid())/com.apple.SystemUIServer"]).0
}

/// Adds {Keyboard Layout, id, name} to AppleEnabledInputSources, the entry the driver writes.
func enableThroughPreferences(name: String) -> String {
	guard let id = layoutIdentifiers[name] else { return "no numeric id known for \(name)" }
	let (status, data) = run("/usr/bin/defaults", ["export", "com.apple.HIToolbox", "-"])
	guard status == 0,
		var domain = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
	else { return "cannot read com.apple.HIToolbox" }
	var sources = domain["AppleEnabledInputSources"] as? [[String: Any]] ?? []
	sources.removeAll { ($0["KeyboardLayout Name"] as? String) == name }
	sources.append(["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": id, "KeyboardLayout Name": name])
	domain["AppleEnabledInputSources"] = sources
	guard let edited = try? PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
	else { return "cannot encode the edited domain" }
	let (imported, _) = run("/usr/bin/defaults", ["import", "com.apple.HIToolbox", "-"], input: edited)
	let restarted = restartInputSourceAgent()
	return "import status \(imported), SystemUIServer restart status \(restarted)"
}

/// The route the driver uses, then the checks: enabled? select?
func tryThroughPreferences(_ step: String, _ label: String, _ name: String) {
	let did = enableThroughPreferences(name)
	turn(1.5)
	guard let source = find(name: name) else {
		verdict(step, false, "\(label): \(did); not listed afterwards")
		return
	}
	verdict(step, nil, "\(label): \(did); then \(capabilities(source))")
	let select = TISSelectInputSource(source)
	let now = currentIdentifier()
	verdict(step, select == noErr && now == identifier(source),
		"\(label): select \(select), current \(now), Q types '\(typed(source))'")
}

// MARK: - The installed bundle that holds the current source (P7 only)

/// The bundle folder in the layout folders whose Info.plist declares `sourceID`.
func installedBundle(holding sourceID: String) -> String? {
	for folder in [layoutsDirectory, "/Library/Keyboard Layouts"] {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
		for entry in names where entry.hasSuffix(".bundle") {
			let plist = "\(folder)/\(entry)/Contents/Info.plist"
			guard let data = FileManager.default.contents(atPath: plist),
				let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
			else { continue }
			for (key, value) in info where key.hasPrefix("KLInfo_") {
				if (value as? [String: Any])?["TISInputSourceID"] as? String == sourceID { return "\(folder)/\(entry)" }
			}
		}
	}
	return nil
}

var bundleBackup: (original: String, backup: String)?

/// Adds one layout (new name, new numeric id, Q types Z) to the bundle that holds the current source.
func replaceInsideErgoptiBundle() {
	let current = currentIdentifier()
	guard let bundle = installedBundle(holding: current) else {
		verdict("P7", false, "no installed bundle declares the current source \(current)")
		return
	}
	guard FileManager.default.isWritableFile(atPath: bundle + "/Contents/Info.plist") else {
		verdict("P7", false, "\(bundle) is not writable by this user (a system bundle needs the administrator route)")
		return
	}
	let backup = NSTemporaryDirectory() + "\(pidTag)-bundle-backup"
	try? FileManager.default.removeItem(atPath: backup)
	do { try FileManager.default.copyItem(atPath: bundle, toPath: backup) } catch {
		verdict("P7", false, "cannot back up \(bundle): \(error)")
		return
	}
	bundleBackup = (bundle, backup)
	let name = pidTag + "d"
	do {
		let plistPath = bundle + "/Contents/Info.plist"
		let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
		guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
		else { verdict("P7", false, "unreadable Info.plist"); return }
		let sourceID = current + ".epv\(getpid())"
		info["KLInfo_\(name)"] = [
			"TICapsLockLanguageSwitchCapable": true,
			"TISIconIsTemplate": false,
			"TISInputSourceID": sourceID,
			"TISIntendedLanguage": "fr",
		]
		let id = freshIdentifier()
		layoutIdentifiers[name] = id
		try keylayoutText(name: name, id: id, output: "Z")
			.write(toFile: bundle + "/Contents/Resources/\(name).keylayout", atomically: true, encoding: .utf8)
		try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
			.write(to: URL(fileURLWithPath: plistPath))
		createdNames.append(name)
		let status = TISRegisterInputSource(URL(fileURLWithPath: bundle) as CFURL)
		turn(0.5)
		guard let source = find(name: name) else {
			verdict("P7", false, "register status \(status): \(name) is not listed after adding it to \(bundle)")
			return
		}
		verdict("P7", nil, "register status \(status), inside \(bundle): \(capabilities(source))")
		trySelect("P7", "new layout inside the enabled bundle, select", name)
		if writePrefs { tryThroughPreferences("P7", "new layout inside the enabled bundle", name) }
	} catch {
		verdict("P7", false, "error: \(error)")
	}
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

let originalDomain = (writePrefs || replaceErgopti) ? exportDomain() : nil
if (writePrefs || replaceErgopti) && originalDomain == nil {
	print("P5 FAIL cannot export com.apple.HIToolbox, so nothing will be written to the preferences")
}
let mayWritePreferences = writePrefs && originalDomain != nil

func cleanUp() {
	if let original = originalSource { _ = TISSelectInputSource(original) }
	for name in createdNames {
		if let source = find(name: name) { _ = TISDisableInputSource(source) }
	}
	for path in createdPaths { try? FileManager.default.removeItem(atPath: path) }
	if let saved = bundleBackup {
		try? FileManager.default.removeItem(atPath: saved.original)
		do {
			try FileManager.default.copyItem(atPath: saved.backup, toPath: saved.original)
			try? FileManager.default.removeItem(atPath: saved.backup)
			_ = TISRegisterInputSource(URL(fileURLWithPath: saved.original) as CFURL)
			verdict("P7", nil, "bundle \(saved.original) put back from its backup")
		} catch {
			verdict("P7", false, "THE BUNDLE COULD NOT BE PUT BACK: restore \(saved.original) from \(saved.backup) by hand (\(error))")
		}
	}
	if mayWritePreferences, let saved = originalDomain {
		let (status, _) = run("/usr/bin/defaults", ["import", "com.apple.HIToolbox", "-"], input: saved)
		let restarted = restartInputSourceAgent()
		verdict("P5", nil, "preferences put back from the export (import status \(status), SystemUIServer restart \(restarted))")
	}
	if let original = originalSource { _ = TISSelectInputSource(original) }
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
	trySelect("P3", "loose file, after re-reading the list", loose)

	// P4: the same layout as a bundle shaped like the Ergopti one.
	let bundle = pidTag + "b"
	let bundleURL = try writeBundle(name: bundle, output: "B")
	let bundleStatus = TISRegisterInputSource(bundleURL as CFURL)
	turn(0.5)
	if let source = find(name: bundle) {
		verdict("P4", nil, "bundle, register status \(bundleStatus), before selecting: \(capabilities(source))")
		trySelect("P4", "bundle, select at once", bundle)
	} else {
		verdict("P4", false, "bundle, register status \(bundleStatus): not listed (compare its Info.plist with the Ergopti bundle's)")
	}

	// P5: the driver's own route, with --write-prefs.
	if mayWritePreferences {
		tryThroughPreferences("P5", "loose file enabled through the preferences", loose)
		tryThroughPreferences("P5", "bundle enabled through the preferences", bundle)
	} else if !writePrefs {
		verdict("P5", nil, "skipped: the next step is to run with --write-prefs (edits and restores com.apple.HIToolbox)")
	}

	// P7: a layout added inside the enabled Ergopti bundle, with --replace-ergopti.
	if replaceErgopti {
		replaceInsideErgoptiBundle()
	} else {
		verdict("P7", nil, "skipped: pass --replace-ergopti to add a layout inside the installed bundle that holds the current source (backed up and restored)")
	}
} catch {
	print("probe error: \(error)")
}

cleanUp()
turn(0.5)
let ghosts = inventory().compactMap { property($0, kTISPropertyLocalizedName) }.filter { $0.hasPrefix(pidTag) }
verdict("P6", ghosts.isEmpty, "after the cleanup, probe sources still listed: \(ghosts.isEmpty ? "none" : ghosts.joined(separator: ", ")) (a ghost until logout is expected)")
verdict("END", nil, "restored to \(currentIdentifier()); started on \(identifier(originalSource)); run again with 'after-logout' after a logout for P6")
