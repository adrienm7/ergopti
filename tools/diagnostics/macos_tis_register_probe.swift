// tools/diagnostics/macos_tis_register_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Register Probe
 * DESCRIPTION:
 * A one-file probe for the macOS questions of docs/design/layout-option-emulation.md:
 * can a keyboard layout written while the system runs be registered, enabled and
 * SELECTED without a logout, and by which route. Every line says why its step ended.
 *
 * What the Mac runs showed so far (macOS 26, arm64):
 *   - TISRegisterInputSource lists a loose .keylayout at once (id org.unknown.keylayout.<Name>);
 *   - TISEnableInputSource answers 0 but the source stays enabled=false, so
 *     TISSelectInputSource answers -50 (paramErr), at once, after a run-loop turn and after
 *     re-reading the list;
 *   - an in-place rewrite stays cached, and a disabled source whose file was removed stays
 *     listed until logout;
 *   - the driver's own route (macos/modules/keymap/input_sources.lua) adds {InputSourceKind
 *     "Keyboard Layout", "KeyboardLayout ID" (integer), "KeyboardLayout Name"} to
 *     AppleEnabledInputSources of com.apple.HIToolbox and restarts SystemUIServer;
 *   - versions 2 and 3: the "not listed" bundle may only have been a lookup by display name,
 *     and version 3 did not compile on the Mac (a missing argument label), so the third
 *     run executed the second binary. Version 4 prints its version first for that reason,
 *     looks sources up by name or by id, and polls instead of guessing a delay.
 *
 * Run (Terminal, macOS 13 or later, no Xcode project needed). Build first and look at the
 * result; a failed build must not run an old binary:
 *   swiftc -O -o /tmp/ep_tis_probe_v4 tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe_v4
 * Flags (each writes more than the default run; none is on by default):
 *   --write-prefs       P5: enable the throw-away layouts through com.apple.HIToolbox
 *                       (exported first, imported back at the end) and restart SystemUIServer
 *   --replace-ergopti   P7: add a layout under a new name and id inside the bundle that holds
 *                       the current input source (copied to a backup first, put back at the end)
 * After a logout and login: /tmp/ep_tis_probe_v4 after-logout
 *
 * FEATURES & RATIONALE:
 * 1. Throw-away layouts only, named EPProbe<pid>..., with numeric ids outside every layout
 *    file found in the layout folders. The user is put back on the input source they started
 *    on and every file the probe wrote is removed at the end, also when a step fails.
 * 2. One verdict line per question:  P<n> PASS|FAIL|INFO <what was observed> [because ...]
 *    Send all printed lines back. A step that is skipped prints a line too.
 * 3. No event is posted: what a source types is read from its own layout data with
 *    UCKeyTranslate (key code 12, the Q key, no modifier).
 * 4. Waits are polls with a ceiling and the time they took is printed.
 *
 * Questions:
 *   P0  version, flags, how many numeric ids are taken, where this run's ids start
 *   P1  capabilities of a freshly registered loose .keylayout, before selecting
 *   P2  select at once (TISEnableInputSource then TISSelectInputSource)
 *   P3  the same after a run-loop turn and after re-reading the list
 *   P4  bundles, registered by the bundle URL: a. shaped like the Ergopti bundle, b. the same
 *       with an icon copied from the installed one, c. the inner .keylayout registered alone,
 *       d. a clone of the installed Ergopti bundle with only name and ids changed. Listed? by
 *       which name and id? select?
 *   P5  --write-prefs: enabled through AppleEnabledInputSources, SystemUIServer restarted (its
 *       pid change is polled), enabled? select? (loose file, then bundle d if it was listed)
 *   P7  --replace-ergopti: a new layout inside the enabled Ergopti bundle: listed? enabled by
 *       inheritance? select? and the bundle put back
 *   P6  sources named EPProbe still listed after the cleanup (a ghost until logout is expected);
 *       with the argument after-logout, whether any survived the logout
 * ==============================================================================
 */

import Carbon
import Foundation

let probeVersion = "v4"
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

func sourceIdentifier(for name: String) -> String { return "com.apple.keyboardlayout.\(name.lowercased())" }

/// A bundle shaped like the shipped Ergopti bundle: a com.apple.keyboardlayout.* identifier,
/// KLInfo_<layout name> with the same keys, version.plist, and the display name in a
/// localized InfoPlist.strings (UTF-16, as the shipped one). `icon` is an .icns to copy in.
func writeBundle(name: String, output: String, icon: String? = nil) throws -> URL {
	let root = "\(layoutsDirectory)/\(name).bundle"
	let resources = root + "/Contents/Resources"
	try FileManager.default.createDirectory(atPath: resources + "/en.lproj", withIntermediateDirectories: true)
	let id = freshIdentifier()
	layoutIdentifiers[name] = id
	try keylayoutText(name: name, id: id, output: output)
		.write(toFile: "\(resources)/\(name).keylayout", atomically: true, encoding: .utf8)
	let sourceID = sourceIdentifier(for: name)
	var entry: [String: Any] = [
		"TICapsLockLanguageSwitchCapable": true,
		"TISIconIsTemplate": false,
		"TISInputSourceID": sourceID,
		"TISIntendedLanguage": "fr",
	]
	if let icon = icon {
		try FileManager.default.copyItem(atPath: icon, toPath: "\(resources)/\(name).icns")
		entry["ICNS"] = "\(name).icns"
	}
	let info: [String: Any] = [
		"CFBundleIdentifier": sourceID,
		"CFBundleName": name,
		"CFBundleShortVersionString": "1.0.0",
		"CFBundleVersion": "1.0.0",
		"KLInfo_\(name)": entry,
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

func nameOf(_ source: TISInputSource) -> String { return property(source, kTISPropertyLocalizedName) ?? "<no name>" }

func identifier(_ source: TISInputSource?) -> String {
	guard let source = source else { return "<not listed>" }
	return property(source, kTISPropertyInputSourceID) ?? "<no id>"
}

/// Every listed source whose display name or id contains the tag, whatever the system called it.
func findAll(tag: String) -> [TISInputSource] {
	let needle = tag.lowercased()
	return inventory().filter {
		nameOf($0).lowercased().contains(needle) || identifier($0).lowercased().contains(needle)
	}
}

func find(tag: String) -> TISInputSource? { return findAll(tag: tag).first }

func describeMatches(_ tag: String) -> String {
	let found = findAll(tag: tag)
	if found.isEmpty { return "no listed source has '\(tag)' in its name or id (\(inventory().count) sources searched)" }
	return found.map { "name='\(nameOf($0))' id=\(identifier($0))" }.joined(separator: "; ")
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
	var parts: [String] = []
	parts.append("selectCapable=" + flag(source, kTISPropertyInputSourceIsSelectCapable))
	parts.append("enableCapable=" + flag(source, kTISPropertyInputSourceIsEnableCapable))
	parts.append("enabled=" + flag(source, kTISPropertyInputSourceIsEnabled))
	parts.append("selected=" + flag(source, kTISPropertyInputSourceIsSelected))
	parts.append("category=" + (property(source, kTISPropertyInputSourceCategory) ?? "nil"))
	parts.append("type=" + (property(source, kTISPropertyInputSourceType) ?? "nil"))
	parts.append("name='" + nameOf(source) + "'")
	parts.append("id=" + identifier(source))
	return parts.joined(separator: " ")
}

func statusText(_ status: OSStatus) -> String {
	switch status {
	case 0: return "noErr"
	case -50: return "paramErr (the call refuses this source in its present state)"
	case -128: return "userCanceledErr"
	default: return "OSStatus \(status)"
	}
}

func verdict(_ step: String, _ pass: Bool?, _ text: String) {
	let word = pass == nil ? "INFO" : (pass! ? "PASS" : "FAIL")
	print("\(step) \(word) \(text)")
}

func turn(_ seconds: Double) {
	RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
}

/// Polls until `condition` holds; returns the seconds it took, or nil at the ceiling.
func waitUntil(_ ceiling: Double, _ condition: () -> Bool) -> Double? {
	let start = Date()
	while Date().timeIntervalSince(start) < ceiling {
		if condition() { return Date().timeIntervalSince(start) }
		turn(0.25)
	}
	return condition() ? Date().timeIntervalSince(start) : nil
}

func seconds(_ value: Double) -> String { return String(format: "%.2f s", value) }

/// Enables, selects and reads back; the line says every status, what the source reports and why.
func trySelect(_ step: String, _ label: String, _ tag: String) {
	guard let source = find(tag: tag) else {
		verdict(step, false, "\(label): ended before selecting because \(describeMatches(tag))")
		return
	}
	let enable = TISEnableInputSource(source)
	let select = TISSelectInputSource(source)
	let now = currentIdentifier()
	let after = find(tag: tag).map { flag($0, kTISPropertyInputSourceIsEnabled) } ?? "unlisted"
	let ok = select == noErr && now == identifier(source)
	var line = "\(label): enable \(enable), select \(select), current \(now), enabled afterwards=\(after), "
	line += "Q types '\(typed(source))'"
	if !ok {
		line += " because select answered \(statusText(select))"
		if after == "false" { line += " and the source is still not enabled" }
	}
	verdict(step, ok, line)
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

func agentPid() -> String {
	let (_, data) = run("/usr/bin/pgrep", ["-x", "SystemUIServer"])
	return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
}

/// Restarts the agent that reads the enabled list, the way the driver's own install does,
/// and polls until a new process is running. Returns what happened.
func restartInputSourceAgent() -> String {
	let before = agentPid()
	let status = run("/bin/launchctl", ["kickstart", "-k", "user/\(getuid())/com.apple.SystemUIServer"]).0
	let took = waitUntil(10) { let now = agentPid(); return !now.isEmpty && now != before }
	return "kickstart status \(status), SystemUIServer pid \(before) -> \(agentPid())"
		+ (took.map { " after \(seconds($0))" } ?? " (no new process within 10 s)")
}

/// Adds {Keyboard Layout, id, name} to AppleEnabledInputSources, the entry the driver writes.
func enableThroughPreferences(_ name: String) -> String {
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
	return "import status \(imported) (entry id \(id) name \(name)); " + restartInputSourceAgent()
}

/// The route the driver uses, then the checks: enabled? select?
func tryThroughPreferences(_ step: String, _ label: String, _ name: String, tag: String) {
	let did = enableThroughPreferences(name)
	let took = waitUntil(10) { find(tag: tag).map { flag($0, kTISPropertyInputSourceIsEnabled) == "true" } ?? false }
	guard let source = find(tag: tag) else {
		verdict(step, false, "\(label): \(did); ended because \(describeMatches(tag))")
		return
	}
	var enabledLine = "\(label): \(did); enabled=true "
	if let took = took { enabledLine += "after \(seconds(took))" } else { enabledLine += "never within 10 s" }
	enabledLine += "; \(capabilities(source))"
	verdict(step, took != nil, enabledLine)
	let select = TISSelectInputSource(source)
	let now = currentIdentifier()
	let ok = select == noErr && now == identifier(source)
	var line = "\(label): select \(select), current \(now), Q types '\(typed(source))'"
	if !ok { line += " because select answered \(statusText(select))" }
	verdict(step, ok, line)
}

// MARK: - The installed bundle that holds the current source

/// The bundle folder in the layout folders whose Info.plist declares `sourceID`, and the
/// KLInfo key (so the layout file name) that declares it.
func installedBundle(holding sourceID: String) -> (path: String, key: String)? {
	for folder in [layoutsDirectory, "/Library/Keyboard Layouts"] {
		guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
		for entry in names where entry.hasSuffix(".bundle") {
			let plist = "\(folder)/\(entry)/Contents/Info.plist"
			guard let data = FileManager.default.contents(atPath: plist),
				let info = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
			else { continue }
			for (key, value) in info where key.hasPrefix("KLInfo_") {
				if (value as? [String: Any])?["TISInputSourceID"] as? String == sourceID { return ("\(folder)/\(entry)", key) }
			}
		}
	}
	return nil
}

/// Replaces the first match of `pattern` in `text` with `template`.
func replacingFirst(_ pattern: String, in text: String, with template: String) -> String {
	guard let expression = try? NSRegularExpression(pattern: pattern),
		let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
		let range = Range(match.range, in: text) else { return text }
	return text.replacingCharacters(in: range, with: template)
}

/// A copy of the installed bundle that holds the current source, reduced to that one layout and
/// renamed: same Info.plist keys, same files, only the name and the two ids changed.
func cloneInstalledBundle(name: String) throws -> URL? {
	guard let installed = installedBundle(holding: currentIdentifier()) else { return nil }
	let root = "\(layoutsDirectory)/\(name).bundle"
	try FileManager.default.copyItem(atPath: installed.path, toPath: root)
	createdPaths.append(root)
	createdNames.append(name)
	let baseName = String(installed.key.dropFirst("KLInfo_".count))
	let resources = root + "/Contents/Resources"
	let id = freshIdentifier()
	layoutIdentifiers[name] = id
	for file in (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? [] {
		let path = resources + "/" + file
		if file == baseName + ".keylayout" || file == baseName + ".icns" { continue }
		try FileManager.default.removeItem(atPath: path)
	}
	var layout = try String(contentsOfFile: resources + "/" + baseName + ".keylayout", encoding: .utf8)
	layout = replacingFirst("(<keyboard\\b[^>]*?\\bname=\")[^\"]*(\")", in: layout, with: "$1\(name)$2")
	layout = replacingFirst("(<keyboard\\b[^>]*?\\bid=\")-?[0-9]+(\")", in: layout, with: "$1\(id)$2")
	try layout.write(toFile: resources + "/" + name + ".keylayout", atomically: true, encoding: .utf8)
	try FileManager.default.removeItem(atPath: resources + "/" + baseName + ".keylayout")
	let icon = resources + "/" + baseName + ".icns"
	let hasIcon = FileManager.default.fileExists(atPath: icon)
	if hasIcon { try FileManager.default.moveItem(atPath: icon, toPath: resources + "/" + name + ".icns") }
	let plistPath = root + "/Contents/Info.plist"
	guard var info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: plistPath)),
		options: [], format: nil) as? [String: Any] else { return nil }
	var entry = (info[installed.key] as? [String: Any]) ?? [:]
	for key in info.keys where key.hasPrefix("KLInfo_") { info.removeValue(forKey: key) }
	let sourceID = sourceIdentifier(for: name)
	entry["TISInputSourceID"] = sourceID
	if hasIcon { entry["ICNS"] = name + ".icns" }
	info["KLInfo_\(name)"] = entry
	info["CFBundleIdentifier"] = sourceID
	info["CFBundleName"] = name
	try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: URL(fileURLWithPath: plistPath))
	return URL(fileURLWithPath: root)
}

/// The first .icns of the installed bundle that holds the current source, if any.
func installedIcon() -> String? {
	guard let installed = installedBundle(holding: currentIdentifier()) else { return nil }
	let resources = installed.path + "/Contents/Resources"
	let icon = ((try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []).first { $0.hasSuffix(".icns") }
	return icon.map { resources + "/" + $0 }
}

var bundleBackup: (original: String, backup: String)?

/// Adds one layout (new name, new numeric id, Q types Z) to the bundle that holds the current source.
func replaceInsideErgoptiBundle() {
	let current = currentIdentifier()
	guard let installed = installedBundle(holding: current) else {
		verdict("P7", false, "ended before changing anything because no installed bundle declares the current source \(current)")
		return
	}
	let bundle = installed.path
	guard FileManager.default.isWritableFile(atPath: bundle + "/Contents/Info.plist") else {
		verdict("P7", false, "ended before changing anything because \(bundle) is not writable by this user (a system bundle needs the administrator route)")
		return
	}
	let backup = NSTemporaryDirectory() + "\(pidTag)-bundle-backup"
	try? FileManager.default.removeItem(atPath: backup)
	do { try FileManager.default.copyItem(atPath: bundle, toPath: backup) } catch {
		verdict("P7", false, "ended before changing anything because the backup of \(bundle) failed: \(error)")
		return
	}
	bundleBackup = (bundle, backup)
	let name = pidTag + "d"
	do {
		let plistPath = bundle + "/Contents/Info.plist"
		let data = try Data(contentsOf: URL(fileURLWithPath: plistPath))
		guard var info = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
		else { verdict("P7", false, "ended because \(plistPath) is not a readable property list"); return }
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
		let took = waitUntil(5) { find(tag: name) != nil }
		guard let source = find(tag: name) else {
			verdict("P7", false, "register status \(status) ended with the layout unlisted after 5 s because \(describeMatches(name))")
			return
		}
		verdict("P7", nil, "register status \(status), listed after \(took.map(seconds) ?? "?") inside \(bundle): \(capabilities(source))")
		trySelect("P7", "new layout inside the enabled bundle, select", name)
		if writePrefs { tryThroughPreferences("P7", "new layout inside the enabled bundle", name, tag: name) }
	} catch {
		verdict("P7", false, "ended on an error: \(error)")
	}
}

// MARK: - After-logout mode

if CommandLine.arguments.dropFirst().first == "after-logout" {
	let leftover = inventory().map(nameOf).filter { $0.hasPrefix("EPProbe") }
	verdict("P6", leftover.isEmpty, "after a logout, EPProbe sources still listed: \(leftover.isEmpty ? "none" : leftover.joined(separator: ", "))")
	exit(0)
}

// MARK: - The run

print("probe \(probeVersion) flags: write-prefs=\(writePrefs) replace-ergopti=\(replaceErgopti)")
let originalSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
print("start current source: \(currentIdentifier())")
verdict("P0", nil, "probe \(probeVersion); \(identifierTaken.count) numeric layout ids already taken; this run draws from \(nextIdentifier) downward")

let originalDomain = writePrefs ? exportDomain() : nil
if writePrefs && originalDomain == nil {
	print("P5 FAIL ended before changing anything because com.apple.HIToolbox cannot be exported, so nothing will be written to the preferences")
}
let mayWritePreferences = writePrefs && originalDomain != nil

func cleanUp() {
	if let original = originalSource { _ = TISSelectInputSource(original) }
	for name in createdNames {
		if let source = find(tag: name) { _ = TISDisableInputSource(source) }
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
		verdict("P5", nil, "preferences put back from the export (import status \(status)); " + restartInputSourceAgent())
	}
	if let original = originalSource { _ = TISSelectInputSource(original) }
}

do {
	// P1 and P2: a loose file with a unique id; its capabilities, then an immediate select.
	let loose = pidTag + "a"
	let looseURL = try writeLoose(name: loose, output: "A")
	let registered = TISRegisterInputSource(looseURL as CFURL)
	if let source = find(tag: loose) {
		verdict("P1", nil, "loose file, register status \(registered), before selecting: \(capabilities(source))")
		trySelect("P2", "loose file, select at once", loose)
	} else {
		verdict("P1", false, "loose file, register status \(registered) ended with nothing listed because \(describeMatches(loose))")
	}

	// P3: the same source after a run-loop turn, then after the list is read again.
	turn(0.3)
	trySelect("P3", "loose file, after a 0.3 s run-loop turn", loose)
	turn(0.3)
	_ = inventory()
	trySelect("P3", "loose file, after re-reading the list", loose)

	// P4: bundles, registered by their bundle URL.
	func tryBundle(_ label: String, _ name: String, _ make: () throws -> URL?, register: (URL) -> OSStatus) {
		do {
			guard let url = try make() else {
				verdict("P4", nil, "\(label): skipped because no installed bundle holds the current source to copy from")
				return
			}
			let status = register(url)
			let took = waitUntil(3) { find(tag: name) != nil }
			guard let source = find(tag: name) else {
				verdict("P4", false, "\(label): register status \(status) ended with the layout unlisted after 3 s because \(describeMatches(name))")
				return
			}
			verdict("P4", nil, "\(label): register status \(status), listed after \(took.map(seconds) ?? "?"): \(capabilities(source))")
			trySelect("P4", "\(label), select at once", name)
		} catch {
			verdict("P4", false, "\(label): ended on an error: \(error)")
		}
	}
	let bundleA = pidTag + "b"
	tryBundle("a. shaped like the Ergopti bundle", bundleA, { try writeBundle(name: bundleA, output: "B") },
		register: { TISRegisterInputSource($0 as CFURL) })
	let bundleB = pidTag + "f"
	tryBundle("b. the same with an icon copied from the installed bundle", bundleB, {
		guard let icon = installedIcon() else { return nil }
		return try writeBundle(name: bundleB, output: "F", icon: icon)
	}, register: { TISRegisterInputSource($0 as CFURL) })
	let bundleC = pidTag + "g"
	tryBundle("c. the inner .keylayout registered alone", bundleC, {
		let url = try writeBundle(name: bundleC, output: "G")
		return url.appendingPathComponent("Contents/Resources/\(bundleC).keylayout")
	}, register: { TISRegisterInputSource($0 as CFURL) })
	let bundleD = pidTag + "e"
	tryBundle("d. clone of the installed bundle, only name and ids changed", bundleD, { try cloneInstalledBundle(name: bundleD) },
		register: { TISRegisterInputSource($0 as CFURL) })

	// P5: the driver's own route, with --write-prefs.
	if mayWritePreferences {
		tryThroughPreferences("P5", "loose file enabled through the preferences", loose, tag: loose)
		if find(tag: bundleD) != nil {
			tryThroughPreferences("P5", "clone enabled through the preferences", bundleD, tag: bundleD)
		} else if find(tag: bundleA) != nil {
			tryThroughPreferences("P5", "bundle a enabled through the preferences", bundleA, tag: bundleA)
		} else {
			verdict("P5", nil, "no bundle variant was listed, so only the loose file went through the preferences")
		}
	} else if !writePrefs {
		verdict("P5", nil, "skipped because --write-prefs was not given; it edits and restores com.apple.HIToolbox")
	}

	// P7: a layout added inside the enabled Ergopti bundle, with --replace-ergopti.
	if replaceErgopti {
		replaceInsideErgoptiBundle()
	} else {
		verdict("P7", nil, "skipped because --replace-ergopti was not given; it adds a layout inside the installed bundle that holds the current source (backed up and restored)")
	}
} catch {
	print("probe error: \(error)")
}

cleanUp()
turn(0.5)
let ghosts = inventory().map(nameOf).filter { $0.hasPrefix(pidTag) }
verdict("P6", ghosts.isEmpty, "after the cleanup, probe sources still listed: \(ghosts.isEmpty ? "none" : ghosts.joined(separator: ", ")) (a ghost until logout is expected)")
verdict("END", nil, "probe \(probeVersion) restored to \(currentIdentifier()); started on \(identifier(originalSource)); run again with 'after-logout' after a logout for P6")
