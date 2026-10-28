// tools/diagnostics/macos_tis_register_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Register Probe
 * DESCRIPTION:
 * A one-file probe for the macOS questions of docs/design/layout-option-emulation.md:
 * can a keyboard layout written while the system runs be registered, enabled and
 * SELECTED without a logout, and by which route. Every line says why its step ended.
 *
 * What the Mac runs showed so far (macOS 26.6.2, arm64, probe v4):
 *   - TISRegisterInputSource lists a loose .keylayout at once (id org.unknown.keylayout.<Name>);
 *   - TISEnableInputSource answers 0 but the source stays enabled=false, so
 *     TISSelectInputSource answers -50 (paramErr), at once, after a run-loop turn and after
 *     re-reading the list; the same for a bundle shaped like Ergopti's, with an icon, and for
 *     the inner .keylayout alone;
 *   - a disabled source whose file was removed stays listed until logout;
 *   - v4 never exercised the preferences route: its restart ran
 *     `launchctl kickstart -k user/<uid>/com.apple.SystemUIServer`, which answers 113 (no such
 *     service: SystemUIServer is com.apple.SystemUIServer.agent in the gui/<uid> domain), so
 *     nothing was restarted; and its clone of the installed bundle (P4 d) inserted the regex
 *     template "$1<name>$2" literally, which broke the XML ("unexpected character '$'"), so
 *     the clone and P7 never had a chance to be listed.
 *
 * Version 5 fixes both, and adds the questions one field run must decide:
 *   P8  does new CONTENT of an already enabled layout (same file, same name and id) apply
 *       after selecting another source and back, without a logout?
 *   P9  does the preferences route enable a layout without a logout when the text-input
 *       system is asked to re-read it, each re-read mechanism measured on its own layout?
 *   P10 does the preferences route enable it after a logout (the documented behaviour)?
 * Enabled states are read both in this process and in a fresh one (this binary run with
 * `query`), so a stale TIS cache in the probe process cannot pass for a refusal.
 *
 * Run (Terminal, macOS 13 or later, no Xcode project needed). Build first and look at the
 * result; a failed build must not run an old binary:
 *   swiftc -O -o /tmp/ep_tis_probe_v5 tools/diagnostics/macos_tis_register_probe.swift && /tmp/ep_tis_probe_v5
 * Flags (each writes more than the default run; none is on by default):
 *   --write-prefs       P5 and P9: enable throw-away layouts through com.apple.HIToolbox
 *                       (exported first, imported back at the end); also leaves ONE layout,
 *                       EPProbeKeep<pid>, enabled for the after-logout run (P10 and P8 a)
 *   --replace-ergopti   P7: add a layout inside the bundle that holds the current source;
 *                       P8 b: replace the content of that enabled layout in place (both backed
 *                       up and put back at the end)
 * Modes (first argument):
 *   after-logout        P6, P10 and P8 a against the layout a --write-prefs run left; does
 *                       nothing but say so when no logout happened since (loginwindow pid)
 *   marker-path         prints the file whose presence means an after-logout run is due
 *   query <id|tag>      one line about a source, read by a fresh process (used internally)
 *   select <id|tag>     selects a source from a fresh process (used internally)
 *
 * FEATURES & RATIONALE:
 * 1. Throw-away layouts only, named EPProbe<pid>..., with numeric ids outside every layout
 *    file found in the layout folders. The user is put back on the input source they started
 *    on and every file the probe wrote is removed at the end, also when a step fails, except
 *    the one EPProbeKeep layout an after-logout run removes.
 * 2. One verdict line per question:  P<n> PASS|FAIL|INFO <what was observed> [because ...]
 *    Send all printed lines back. A step that is skipped prints a line too.
 * 3. No event is posted: what a source types is read from its own layout data with
 *    UCKeyTranslate (key code 12, the Q key, no modifier).
 * 4. Waits are polls with a ceiling and the time they took is printed.
 *
 * Questions:
 *   P0  version, flags, how many numeric ids are taken (and which ids two files declare),
 *       which launchd services of the text-input system exist in the gui and user domains
 *   P1  capabilities of a freshly registered loose .keylayout, before selecting
 *   P2  select at once (TISEnableInputSource then TISSelectInputSource)
 *   P3  the same after a run-loop turn and after re-reading the list
 *   P4  bundles, registered by the bundle URL: a. shaped like the Ergopti bundle, b. the same
 *       with an icon copied from the installed one, c. the inner .keylayout registered alone,
 *       d. a clone of the installed Ergopti bundle with only name and ids changed
 *   P5  --write-prefs: enabled through AppleEnabledInputSources alone, nothing restarted
 *   P9  --write-prefs: the same, then one re-read mechanism per layout: a. synchronize the
 *       domain and post the TIS enabled-sources notification, b. restart SystemUIServer,
 *       c. restart TextInputMenuAgent, d. restart the user's cfprefsd
 *   P7  --replace-ergopti: a new layout inside the enabled Ergopti bundle: listed? select?
 *   P8  b. --replace-ergopti: new content in the enabled Ergopti layout, select away and back;
 *       a. (after-logout) the same on the EPProbeKeep layout
 *   P6  sources named EPProbe still listed after the cleanup (a ghost until logout is expected);
 *       in after-logout mode, whether any survived the logout
 *   P10 after-logout: is EPProbeKeep enabled and selectable after the logout?
 * ==============================================================================
 */

import Carbon
import Foundation

let probeVersion = "v5"
let layoutsDirectory = NSString(string: "~/Library/Keyboard Layouts").expandingTildeInPath
let keepStateDirectory = NSString(string: "~/Library/Caches/ErgoptiPlus-tis-probe").expandingTildeInPath
let keepStatePath = keepStateDirectory + "/keep.plist"
let keyCodeQ: UInt16 = 12
let pidTag = "EPProbe\(getpid())"
let arguments = Array(CommandLine.arguments.dropFirst())
let mode = arguments.first ?? ""
let writePrefs = arguments.contains("--write-prefs")
let replaceErgopti = arguments.contains("--replace-ergopti")
let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
let guiDomain = "gui/\(getuid())"
let userDomain = "user/\(getuid())"
var createdPaths: [String] = []
var createdNames: [String] = []
var layoutIdentifiers: [String: Int] = [:]
// The source the run started on, set by the run (read by the steps that select back to it).
var originalSource: TISInputSource?

// MARK: - Processes

/// Runs a program and returns its exit status and standard output; standard error is dropped
/// (the layout compiler prints there) so that a full pipe can never block the child.
@discardableResult
func run(_ path: String, _ arguments: [String], input: Data? = nil) -> (Int32, Data) {
	let process = Process()
	process.executableURL = URL(fileURLWithPath: path)
	process.arguments = arguments
	let output = Pipe()
	process.standardOutput = output
	process.standardError = FileHandle.nullDevice
	if let input = input {
		let pipe = Pipe()
		process.standardInput = pipe
		do { try process.run() } catch { return (-1, Data()) }
		pipe.fileHandleForWriting.write(input)
		pipe.fileHandleForWriting.closeFile()
	} else {
		do { try process.run() } catch { return (-1, Data()) }
	}
	let data = output.fileHandleForReading.readDataToEndOfFile()
	process.waitUntilExit()
	return (process.terminationStatus, data)
}

func text(_ data: Data) -> String {
	return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

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

/// The numeric ids declared by the layout files of the user and the system folders, with the
/// files that declare each, so that an id two files declare can be named.
func declaredIdentifiers() -> [Int: [String]] {
	var declared: [Int: [String]] = [:]
	let folders = [layoutsDirectory, "/Library/Keyboard Layouts", "/System/Library/Keyboard Layouts"]
	for folder in folders {
		guard let enumerator = FileManager.default.enumerator(atPath: folder) else { continue }
		for case let relative as String in enumerator where relative.hasSuffix(".keylayout") {
			let path = folder + "/" + relative
			guard let data = FileManager.default.contents(atPath: path),
				let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
				let range = text.range(of: "<keyboard ") else { continue }
			let head = text[range.upperBound...].prefix(400)
			if let idRange = head.range(of: " id=\"") {
				let digits = head[idRange.upperBound...].prefix { $0 == "-" || $0.isNumber }
				if let value = Int(digits) { declared[value, default: []].append(path) }
			}
		}
	}
	return declared
}

let declaredAtStart = declaredIdentifiers()
var identifierTaken = Set(declaredAtStart.keys)
var nextIdentifier = -(700_000 + Int(getpid()) % 200_000)

func freshIdentifier() -> Int {
	while identifierTaken.contains(nextIdentifier) { nextIdentifier -= 1 }
	let value = nextIdentifier
	identifierTaken.insert(value)
	nextIdentifier -= 1
	return value
}

/// Writes a loose layout. `removeAtEnd` false keeps it for the after-logout run.
func writeLoose(name: String, output: String, removeAtEnd: Bool = true) throws -> URL {
	try FileManager.default.createDirectory(atPath: layoutsDirectory, withIntermediateDirectories: true)
	let path = "\(layoutsDirectory)/\(name).keylayout"
	let id = freshIdentifier()
	layoutIdentifiers[name] = id
	try keylayoutText(name: name, id: id, output: output).write(toFile: path, atomically: true, encoding: .utf8)
	if removeAtEnd {
		createdPaths.append(path)
		createdNames.append(name)
	}
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

/// The source whose id is exactly `tag`, else the first whose name or id contains it.
func find(tag: String) -> TISInputSource? {
	let all = inventory()
	if let exact = all.first(where: { identifier($0) == tag }) { return exact }
	return findAll(tag: tag).first
}

func describeMatches(_ tag: String) -> String {
	let found = findAll(tag: tag)
	if found.isEmpty { return "no listed source has '\(tag)' in its name or id (\(inventory().count) sources searched)" }
	return found.map { "name='\(nameOf($0))' id=\(identifier($0))" }.joined(separator: "; ")
}

func currentIdentifier() -> String {
	guard let current = TISCopyCurrentKeyboardLayoutInputSource() else { return "<none>" }
	return identifier(current.takeRetainedValue())
}

func isEnabled(_ tag: String) -> Bool {
	return find(tag: tag).map { flag($0, kTISPropertyInputSourceIsEnabled) == "true" } ?? false
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
	fflush(stdout)
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

/// One line about a source as a fresh process sees it, free of this process's TIS cache.
func freshQuery(_ tag: String) -> String {
	let (status, data) = run(selfPath, ["query", tag])
	let line = text(data)
	return status == 0 ? line : "query exited \(status): \(line)"
}

/// Asks a fresh process to select a source; returns its line.
func freshSelect(_ tag: String) -> String {
	let (status, data) = run(selfPath, ["select", tag])
	let line = text(data)
	return status == 0 ? line : "select exited \(status): \(line)"
}

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

// MARK: - Fresh-process modes

if mode == "marker-path" {
	print(keepStatePath)
	exit(0)
}

if mode == "query" || mode == "select" {
	guard arguments.count >= 2 else { print("usage: \(mode) <id|tag>"); exit(2) }
	guard let source = find(tag: arguments[1]) else { print("unlisted"); exit(0) }
	if mode == "query" {
		print("enabled=\(flag(source, kTISPropertyInputSourceIsEnabled)) selectCapable=\(flag(source, kTISPropertyInputSourceIsSelectCapable)) selected=\(flag(source, kTISPropertyInputSourceIsSelected)) Q='\(typed(source))' id=\(identifier(source))")
	} else {
		let status = TISSelectInputSource(source)
		print("select \(status), current \(currentIdentifier())")
	}
	exit(0)
}

// MARK: - User preferences and the text-input agents

/// The domain as exported, so that it can be put back as it was.
func exportDomain() -> Data? {
	let (status, data) = run("/usr/bin/defaults", ["export", "com.apple.HIToolbox", "-"])
	return status == 0 ? data : nil
}

func pids(_ process: String) -> String {
	let (_, data) = run("/usr/bin/pgrep", ["-x", "-U", "\(getuid())", process])
	return text(data).replacingOccurrences(of: "\n", with: ",")
}

func serviceExists(_ domain: String, _ label: String) -> Bool {
	return run("/bin/launchctl", ["print", "\(domain)/\(label)"]).0 == 0
}

/// The launchd services and processes of the text-input system, as this Mac has them.
let agentCandidates: [(process: String, label: String)] = [
	("SystemUIServer", "com.apple.SystemUIServer.agent"),
	("TextInputMenuAgent", "com.apple.TextInputMenuAgent"),
	("TextInputSwitcher", "com.apple.TextInputSwitcher"),
	("cfprefsd", "com.apple.cfprefsd.xpc.agent"),
]

func describeAgents() -> String {
	return agentCandidates.map { candidate in
		let gui = serviceExists(guiDomain, candidate.label) ? "yes" : "no"
		let user = serviceExists(userDomain, candidate.label) ? "yes" : "no"
		let running = pids(candidate.process)
		return "\(candidate.label) gui=\(gui) user=\(user) \(candidate.process) pid=\(running.isEmpty ? "none" : running)"
	}.joined(separator: "; ")
}

/// Restarts one agent: launchctl kickstart -k in the gui domain when the service is there,
/// else SIGTERM to the user's processes of that name (launchd starts agents again on demand).
/// Polls for a new process and says what happened.
func restartAgent(process: String, label: String) -> String {
	let before = pids(process)
	let did: String
	if serviceExists(guiDomain, label) {
		let status = run("/bin/launchctl", ["kickstart", "-k", "\(guiDomain)/\(label)"]).0
		did = "kickstart -k \(guiDomain)/\(label) status \(status)"
	} else if !before.isEmpty {
		let status = run("/bin/kill", ["-TERM"] + before.split(separator: ",").map(String.init)).0
		did = "\(label) is not in \(guiDomain); kill -TERM \(before) status \(status)"
	} else {
		return "\(label) is not in \(guiDomain) and no \(process) runs, so nothing was restarted"
	}
	let took = waitUntil(10) { let now = pids(process); return !now.isEmpty && now != before }
	return did + ", \(process) pid \(before.isEmpty ? "none" : before) -> \(pids(process))"
		+ (took.map { " after \(seconds($0))" } ?? " (no new process within 10 s)")
}

/// CFPreferencesAppSynchronize on the domain, then the distributed notification TIS posts
/// when the enabled sources change.
func synchronizeAndNotify() -> String {
	let synchronized = CFPreferencesAppSynchronize("com.apple.HIToolbox" as CFString)
	let name = kTISNotifyEnabledKeyboardInputSourcesChanged as String
	DistributedNotificationCenter.default().postNotificationName(NSNotification.Name(name), object: nil,
		userInfo: nil, deliverImmediately: true)
	return "CFPreferencesAppSynchronize \(synchronized), posted \(name)"
}

/// Adds {Keyboard Layout, id, name} to AppleEnabledInputSources, the entry the driver writes,
/// or removes every entry of that name. Nothing is restarted.
func editEnabledList(_ name: String, add: Bool) -> String {
	guard let id = layoutIdentifiers[name] ?? (add ? nil : 0) else { return "no numeric id known for \(name)" }
	let (status, data) = run("/usr/bin/defaults", ["export", "com.apple.HIToolbox", "-"])
	guard status == 0,
		var domain = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
	else { return "cannot read com.apple.HIToolbox" }
	var sources = domain["AppleEnabledInputSources"] as? [[String: Any]] ?? []
	sources.removeAll { ($0["KeyboardLayout Name"] as? String) == name }
	if add { sources.append(["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": id, "KeyboardLayout Name": name]) }
	domain["AppleEnabledInputSources"] = sources
	guard let edited = try? PropertyListSerialization.data(fromPropertyList: domain, format: .xml, options: 0)
	else { return "cannot encode the edited domain" }
	let (imported, _) = run("/usr/bin/defaults", ["import", "com.apple.HIToolbox", "-"], input: edited)
	return add ? "import status \(imported) (entry id \(id) name \(name))" : "import status \(imported) (entries named \(name) removed)"
}

/// The preferences route, one re-read mechanism (or none), then: enabled here? in a fresh
/// process? select? and back to the source the run started on.
func tryThroughPreferences(_ step: String, _ label: String, _ name: String, reread: (() -> String)?) {
	let did = editEnabledList(name, add: true)
	let mechanism = reread.map { $0() } ?? "nothing re-read"
	let took = waitUntil(10) { isEnabled(name) }
	let fresh = freshQuery(name)
	let freshEnabled = fresh.hasPrefix("enabled=true")
	guard let source = find(tag: name) else {
		verdict(step, false, "\(label): \(did); \(mechanism); ended because \(describeMatches(name))")
		return
	}
	var enabledLine = "\(label): \(did); \(mechanism); enabled here "
	enabledLine += took.map { "after \(seconds($0))" } ?? "never within 10 s"
	enabledLine += "; a fresh process sees \(fresh)"
	verdict(step, took != nil || freshEnabled, enabledLine)
	let select = TISSelectInputSource(source)
	let now = currentIdentifier()
	var line = "\(label): select here \(select), current \(now)"
	var ok = select == noErr && now == identifier(source)
	if !ok && freshEnabled {
		let other = freshSelect(identifier(source))
		line += "; select from a fresh process: \(other)"
		ok = currentIdentifier() == identifier(source)
	}
	line += ", Q types '\(typed(source))'"
	if !ok { line += " because select answered \(statusText(select))" }
	verdict(step, ok, line)
	if let original = originalSource { _ = TISSelectInputSource(original) }
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

/// Replaces the first match of `pattern` in `text` with `template`, whose $1 and $2 name the
/// groups of the match. v4 inserted the template literally, which broke the cloned layout.
func replacingFirst(_ pattern: String, in text: String, with template: String) -> String {
	guard let expression = try? NSRegularExpression(pattern: pattern),
		let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
		let range = Range(match.range, in: text) else { return text }
	let replacement = expression.replacementString(for: match, in: text, offset: 0, template: template)
	return text.replacingCharacters(in: range, with: replacement)
}

/// The first capture group of `pattern` in `text`.
func firstGroup(_ pattern: String, in text: String) -> String? {
	guard let expression = try? NSRegularExpression(pattern: pattern),
		let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
		match.numberOfRanges > 1,
		let range = Range(match.range(at: 1), in: text) else { return nil }
	return String(text[range])
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
var contentBackup: (file: String, bytes: Data, sourceID: String, bundle: String, typedBefore: String)?

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
		if writePrefs { tryThroughPreferences("P7", "new layout inside the enabled bundle", name, reread: synchronizeAndNotify) }
	} catch {
		verdict("P7", false, "ended on an error: \(error)")
	}
}

/// An enabled, select-capable keyboard layout other than `sourceID`, to select away to.
func otherEnabledLayout(than sourceID: String) -> TISInputSource? {
	return inventory().first {
		identifier($0) != sourceID
			&& flag($0, kTISPropertyInputSourceIsEnabled) == "true"
			&& flag($0, kTISPropertyInputSourceIsSelectCapable) == "true"
			&& property($0, kTISPropertyInputSourceType) == (kTISTypeKeyboardLayout as String)
	}
}

/// Selects another layout and back, then says what Q types here and in a fresh process.
func awayAndBack(_ sourceID: String) -> String {
	guard let other = otherEnabledLayout(than: sourceID) else { return "no other enabled layout to select away to" }
	let away = TISSelectInputSource(other)
	turn(0.5)
	guard let target = find(tag: sourceID) else { return "away \(away); \(sourceID) is no longer listed" }
	let back = TISSelectInputSource(target)
	turn(0.5)
	let here = find(tag: sourceID).map(typed) ?? "<unlisted>"
	return "away to \(identifier(other)) \(away), back \(back), current \(currentIdentifier()), Q types '\(here)' here; fresh process: \(freshQuery(sourceID))"
}

/// Whether a fresh process reads `output` for the Q key of the source.
func freshTypes(_ sourceID: String, _ output: String) -> Bool {
	return freshQuery(sourceID).contains("Q='\(output)'")
}

/// P8: new content in an enabled layout (same file, same name, same id), select away and
/// back, then the same after registering the file again; restoreContent puts the old bytes back.
func replaceContent(_ step: String, sourceID: String, file: String, registerURL: URL, newOutput: String) {
	guard let bytes = FileManager.default.contents(atPath: file), let original = String(data: bytes, encoding: .utf8) else {
		verdict(step, false, "ended before changing anything because \(file) is unreadable as UTF-8")
		return
	}
	guard let name = firstGroup("<keyboard\\b[^>]*?\\bname=\"([^\"]*)\"", in: original),
		let idText = firstGroup("<keyboard\\b[^>]*?\\bid=\"(-?[0-9]+)\"", in: original), let id = Int(idText) else {
		verdict(step, false, "ended before changing anything because \(file) declares no keyboard name or id")
		return
	}
	let before = find(tag: sourceID).map(typed) ?? "<unlisted>"
	contentBackup = (file, bytes, sourceID, registerURL.path, before)
	do {
		try keylayoutText(name: name, id: id, output: newOutput).write(toFile: file, atomically: true, encoding: .utf8)
	} catch {
		verdict(step, false, "ended because the new content could not be written: \(error)")
		return
	}
	let first = awayAndBack(sourceID)
	verdict(step, freshTypes(sourceID, newOutput), "content of \(sourceID) replaced in place (name \(name), id \(id), Q typed '\(before)', now meant to type '\(newOutput)'), select away and back: \(first)")
	let status = TISRegisterInputSource(registerURL as CFURL)
	let second = awayAndBack(sourceID)
	verdict(step, freshTypes(sourceID, newOutput), "then registered again (status \(status)), select away and back: \(second)")
}

/// Puts back the content P8 replaced and says whether the original applies again.
func restoreContent() {
	guard let saved = contentBackup else { return }
	contentBackup = nil
	do { try saved.bytes.write(to: URL(fileURLWithPath: saved.file)) } catch {
		verdict("P8", false, "THE LAYOUT COULD NOT BE PUT BACK: \(saved.file) (\(error)); reinstall Ergopti's layout")
		return
	}
	_ = TISRegisterInputSource(URL(fileURLWithPath: saved.bundle) as CFURL)
	let line = awayAndBack(saved.sourceID)
	let back = freshTypes(saved.sourceID, saved.typedBefore)
	verdict("P8", back ? nil : false, "original content of \(saved.file) put back: \(line)"
		+ (back ? "" : "; Q does not type '\(saved.typedBefore)' again yet: log out and in to reload it"))
}

// MARK: - The layout kept for the after-logout run

func loginwindowPid() -> String {
	let (_, data) = run("/usr/bin/pgrep", ["-x", "loginwindow"])
	return text(data).replacingOccurrences(of: "\n", with: ",")
}

func readKeepState() -> [String: Any]? {
	guard let data = FileManager.default.contents(atPath: keepStatePath) else { return nil }
	return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
}

/// Leaves one enabled layout for the after-logout run and writes the marker the collector reads.
func keepForAfterLogout() {
	if readKeepState() != nil {
		verdict("P10", nil, "a layout is already kept for the after-logout run (\(keepStatePath)); none added")
		return
	}
	let name = "EPProbeKeep\(getpid())"
	do {
		let url = try writeLoose(name: name, output: "K", removeAtEnd: false)
		let status = TISRegisterInputSource(url as CFURL)
		let did = editEnabledList(name, add: true)
		try FileManager.default.createDirectory(atPath: keepStateDirectory, withIntermediateDirectories: true)
		let state: [String: Any] = [
			"name": name, "id": layoutIdentifiers[name] ?? 0, "path": url.path,
			"loginwindow": loginwindowPid(), "created": ISO8601DateFormatter().string(from: Date()),
		]
		try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0)
			.write(to: URL(fileURLWithPath: keepStatePath))
		verdict("P10", nil, "kept \(name) (Q types 'K', register status \(status), \(did)) for the after-logout run; log out and in, then run the collector again: it runs 'after-logout' first")
	} catch {
		verdict("P10", false, "the layout for the after-logout run could not be kept: \(error)")
	}
}

// MARK: - After-logout mode

if mode == "after-logout" {
	print("probe \(probeVersion) after-logout")
	guard let state = readKeepState(), let name = state["name"] as? String, let path = state["path"] as? String else {
		let leftover = inventory().map(nameOf).filter { $0.hasPrefix("EPProbe") }
		verdict("P6", leftover.isEmpty, "no kept layout; EPProbe sources still listed: \(leftover.isEmpty ? "none" : leftover.joined(separator: ", "))")
		exit(0)
	}
	let markedLogin = state["loginwindow"] as? String ?? "?"
	let created = state["created"] as? String ?? "?"
	if markedLogin == loginwindowPid() {
		verdict("P10", nil, "no logout since \(created) (loginwindow pid \(markedLogin) unchanged); \(name) kept for the next run")
		exit(0)
	}
	let leftover = inventory().map(nameOf).filter { $0.hasPrefix("EPProbe") && $0 != name }
	verdict("P6", leftover.isEmpty, "after a logout, EPProbe sources still listed: \(leftover.isEmpty ? "none" : leftover.joined(separator: ", "))")
	let start = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
	if let source = find(tag: name) {
		let enabled = flag(source, kTISPropertyInputSourceIsEnabled) == "true"
		verdict("P10", enabled, "\(name), enabled through the preferences before the logout (\(created)): \(capabilities(source)); fresh process: \(freshQuery(name))")
		let select = TISSelectInputSource(source)
		let sourceID = identifier(source)
		verdict("P10", select == noErr && currentIdentifier() == sourceID, "\(name): select \(select), current \(currentIdentifier()), Q types '\(typed(source))'")
		if enabled {
			replaceContent("P8", sourceID: sourceID, file: path, registerURL: URL(fileURLWithPath: path), newOutput: "Y")
			verdict("P8", nil, "a. above: the kept loose layout, enabled since the login")
			contentBackup = nil
		} else {
			verdict("P8", nil, "a. skipped because \(name) is not enabled after the logout")
		}
	} else {
		verdict("P10", false, "\(name) is not listed after the logout: \(describeMatches(name))")
	}
	if let start = start { _ = TISSelectInputSource(start) }
	if let source = find(tag: name) { _ = TISDisableInputSource(source) }
	try? FileManager.default.removeItem(atPath: path)
	let removed = editEnabledList(name, add: false)
	try? FileManager.default.removeItem(atPath: keepStatePath)
	verdict("END", nil, "probe \(probeVersion) after-logout: \(name) removed (\(removed)), marker removed, current \(currentIdentifier())")
	exit(0)
}

// MARK: - The run

print("probe \(probeVersion) flags: write-prefs=\(writePrefs) replace-ergopti=\(replaceErgopti)")
originalSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
print("start current source: \(currentIdentifier())")
let duplicates = declaredAtStart.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
	.map { "\($0.key) in \($0.value.joined(separator: " and "))" }
verdict("P0", nil, "probe \(probeVersion); \(identifierTaken.count) numeric layout ids already taken; this run draws from \(nextIdentifier) downward; declared twice: \(duplicates.isEmpty ? "none" : duplicates.joined(separator: "; "))")
verdict("P0", nil, "text-input services: \(describeAgents())")

let originalDomain = writePrefs ? exportDomain() : nil
if writePrefs && originalDomain == nil {
	print("P5 FAIL ended before changing anything because com.apple.HIToolbox cannot be exported, so nothing will be written to the preferences")
}
let mayWritePreferences = writePrefs && originalDomain != nil

func cleanUp() {
	if let original = originalSource { _ = TISSelectInputSource(original) }
	restoreContent()
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
		verdict("P5", nil, "preferences put back from the export (import status \(status)); " + synchronizeAndNotify())
		keepForAfterLogout()
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

	// P5 and P9: the preferences route, alone, then with each re-read mechanism on its own
	// fresh layout, least invasive first, so that each result belongs to one mechanism.
	if mayWritePreferences {
		tryThroughPreferences("P5", "loose file enabled through the preferences alone", loose, reread: nil)
		let mechanisms: [(letter: String, label: String, apply: () -> String)] = [
			("a", "synchronize and notify", synchronizeAndNotify),
			("b", "restart SystemUIServer", { restartAgent(process: "SystemUIServer", label: "com.apple.SystemUIServer.agent") }),
			("c", "restart TextInputMenuAgent", { restartAgent(process: "TextInputMenuAgent", label: "com.apple.TextInputMenuAgent") }),
			("d", "restart cfprefsd", { restartAgent(process: "cfprefsd", label: "com.apple.cfprefsd.xpc.agent") }),
		]
		for mechanism in mechanisms {
			let name = pidTag + "p" + mechanism.letter
			let url = try writeLoose(name: name, output: mechanism.letter.uppercased())
			let status = TISRegisterInputSource(url as CFURL)
			tryThroughPreferences("P9", "\(mechanism.letter). \(mechanism.label) (register status \(status))", name,
				reread: mechanism.apply)
		}
	} else if !writePrefs {
		verdict("P5", nil, "skipped because --write-prefs was not given; it edits and restores com.apple.HIToolbox")
		verdict("P9", nil, "skipped because --write-prefs was not given")
	}

	// P7 and P8 b: inside the enabled Ergopti bundle, with --replace-ergopti.
	if replaceErgopti {
		replaceInsideErgoptiBundle()
		let current = currentIdentifier()
		if let installed = installedBundle(holding: current) {
			let base = String(installed.key.dropFirst("KLInfo_".count))
			let file = installed.path + "/Contents/Resources/" + base + ".keylayout"
			if let saved = bundleBackup {
				// P7 changed the bundle; put it back first so P8 starts from the shipped content.
				try? FileManager.default.removeItem(atPath: saved.original)
				try FileManager.default.copyItem(atPath: saved.backup, toPath: saved.original)
				try? FileManager.default.removeItem(atPath: saved.backup)
				bundleBackup = nil
				verdict("P7", nil, "bundle \(saved.original) put back from its backup before P8")
			}
			if FileManager.default.isWritableFile(atPath: file) {
				replaceContent("P8", sourceID: current, file: file, registerURL: URL(fileURLWithPath: installed.path), newOutput: "Ω")
				verdict("P8", nil, "b. above: the enabled layout of \(installed.path)")
			} else {
				verdict("P8", false, "b. ended before changing anything because \(file) is not writable by this user")
			}
		} else {
			verdict("P8", false, "b. ended before changing anything because no installed bundle declares the current source \(current)")
		}
	} else {
		verdict("P7", nil, "skipped because --replace-ergopti was not given; it adds a layout inside the installed bundle that holds the current source (backed up and restored)")
		verdict("P8", nil, "b. skipped because --replace-ergopti was not given; it replaces the content of the enabled Ergopti layout in place (backed up and restored)")
	}
} catch {
	print("probe error: \(error)")
}

cleanUp()
turn(0.5)
let ghosts = inventory().map(nameOf).filter { $0.hasPrefix(pidTag) }
verdict("P6", ghosts.isEmpty, "after the cleanup, probe sources still listed: \(ghosts.isEmpty ? "none" : ghosts.joined(separator: ", ")) (a ghost until logout is expected)")
verdict("END", nil, "probe \(probeVersion) restored to \(currentIdentifier()); started on \(identifier(originalSource)); the next collector run checks P10 and P8 a by itself after a logout")
