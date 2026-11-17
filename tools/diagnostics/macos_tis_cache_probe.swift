// tools/diagnostics/macos_tis_cache_probe.swift

/**
 * ==============================================================================
 * MODULE: macOS TIS Current-Source Cache Probe
 * DESCRIPTION:
 * Answers one question of the keyboard-source CI refusals (TODO « [CI] Native
 * keyboard-source fixture »): in a long-lived process, can
 * TISCopyCurrentKeyboardInputSource keep naming a source after the system has
 * selected another, and under which run-loop mode does the process see the
 * change? Runs 43277967473 and 43276494558 showed it once each: the first
 * restore from French to US returned 0, US then read enabled and selected, and
 * the test process's current source stayed French for good.
 *
 * One process runs one mode for --cycles cycles: select the target (French by
 * default), wait until this process's current source is it, then select the
 * original source back and wait again. Each wait pumps in the chosen way:
 *   default   CFRunLoopRunInMode(default, 10 ms), as KeyboardSourceSelectionFixture does;
 *   tracking  CFRunLoopRunInMode(event tracking, 10 ms): is the cache source in common modes?
 *   nsapp     NSApplication.nextEvent in the default mode, as an app's event loop runs;
 *   none      no run loop at all (usleep), so a cache fed by the run loop never moves.
 * --body adds, between the two selections, what the refused cases did before the
 * restore: a keyboard event built from the HID system state and read back
 * (key code 12, the Q key), nothing posted.
 * --child-select makes each selection in a fresh plain process (this binary run
 * with --select <id>) while this process only observes and pumps: whether the
 * lost selections follow the process that pumps text-input events or the one
 * that selects.
 * --toggle runs each cycle as one fixture case does: enable the target (it must
 * start disabled), select it, restore the original, disable the target once the
 * original is current again.
 *
 * Every step prints one JSON line: the call's status, whether and when this
 * process saw the source it asked for, the selected property of that source as
 * the system reports it, what com.apple.HIToolbox holds for the current layout
 * and the selected sources (the preferences a fresh process starts from), the distributed selection-change notifications this
 * process received, and, when the process did not see the change, what a fresh
 * process reads (this binary run with --read-current) and whether the cache
 * caught up after 10 more seconds in the same mode, then 5 in the default mode.
 * The last line is `SUMMARY {...}`: per mode, the steps this process saw, missed,
 * and missed while the system and a fresh process had the new source (stale).
 *
 * Build and run (macOS 13 or later; the CI probe workflow does this on each runner):
 *   swiftc -O -o /tmp/tis-cache-probe tools/diagnostics/macos_tis_cache_probe.swift
 *   /tmp/tis-cache-probe --mode default --cycles 30 [--body] [--target com.apple.keylayout.French]
 * It changes the input source of the machine it runs on and puts the original
 * back; the target is disabled again only when it enabled it and the original
 * is current. Meant for a disposable CI runner.
 * ==============================================================================
 */

import AppKit
import Carbon
import Foundation

// ==============================
// ======= 1/ Options ===========
// ==============================

let MODES = ["default", "tracking", "nsapp", "none"]
let WAIT_SECONDS = 6.0
let SAME_MODE_RECOVERY_SECONDS = 10.0
let DEFAULT_MODE_RECOVERY_SECONDS = 5.0
let MAX_CYCLES = 200

/// Stops with one reason; a probe that cannot run must not print a summary.
func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("tis-cache-probe: \(message)\n".utf8))
	exit(2)
}

struct Options {
	var mode = ""
	var cycles = 0
	var body = false
	var toggle = false
	var childSelect = false
	var target = "com.apple.keylayout.French"
}

func parseOptions(_ arguments: [String]) -> Options {
	var options = Options()
	var index = 0
	func value(_ flag: String) -> String {
		index += 1
		guard index < arguments.count else { fail("\(flag) needs a value") }
		return arguments[index]
	}
	while index < arguments.count {
		switch arguments[index] {
		case "--mode": options.mode = value("--mode")
		case "--cycles":
			guard let cycles = Int(value("--cycles")), cycles >= 1, cycles <= MAX_CYCLES else {
				fail("--cycles must be an integer from 1 to \(MAX_CYCLES)")
			}
			options.cycles = cycles
		case "--target": options.target = value("--target")
		case "--body": options.body = true
		case "--toggle": options.toggle = true
		case "--child-select": options.childSelect = true
		default: fail("unknown argument \(arguments[index])")
		}
		index += 1
	}
	guard MODES.contains(options.mode) else { fail("--mode must be one of \(MODES.joined(separator: ", "))") }
	guard options.cycles > 0 else { fail("--cycles is required") }
	return options
}

// ==============================
// ======= 2/ TIS reads =========
// ==============================

func identifier(_ source: TISInputSource) -> String {
	guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
	return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
}

func flag(_ source: TISInputSource, _ key: CFString) -> Bool? {
	guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
	return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
}

/// This process's current source: the cache the refusals found stale.
func currentIdentifier() -> String {
	identifier(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
}

/// A fresh lookup of a source, so its properties are the system's, not a kept object's.
func lookup(_ id: String) -> TISInputSource? {
	let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
	guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else {
		return nil
	}
	return list.first
}

/// The HIToolbox preferences: the current layout and the selected sources a new process starts from.
func preferences() -> [String: Any] {
	let domain = "com.apple.HIToolbox" as CFString
	_ = CFPreferencesAppSynchronize(domain)
	var result: [String: Any] = [:]
	let current = CFPreferencesCopyAppValue("AppleCurrentKeyboardLayoutInputSourceID" as CFString, domain)
	result["current_layout"] = (current as? String) ?? NSNull()
	if let selected = CFPreferencesCopyAppValue("AppleSelectedInputSources" as CFString, domain) as? [[String: Any]] {
		result["selected"] = selected.map { entry in
			(entry["KeyboardLayout Name"] as? String) ?? (entry["Bundle ID"] as? String)
				?? (entry["InputSourceKind"] as? String) ?? "?"
		}
	} else {
		result["selected"] = NSNull()
	}
	return result
}

/// Selects `id` from a fresh plain process; its status, or nil when the child did not answer one.
func childSelect(_ id: String) -> OSStatus? {
	guard let executable = Bundle.main.executablePath else { return nil }
	let child = Process()
	child.executableURL = URL(fileURLWithPath: executable)
	child.arguments = ["--select", id]
	let pipe = Pipe()
	child.standardOutput = pipe
	do { try child.run() } catch { return nil }
	child.waitUntilExit()
	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	return Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
}

/// What a new process reads as current: the system's state without this process's cache.
func freshProcessCurrent() -> String {
	guard let executable = Bundle.main.executablePath else { return "no-executable-path" }
	let child = Process()
	child.executableURL = URL(fileURLWithPath: executable)
	child.arguments = ["--read-current"]
	let pipe = Pipe()
	child.standardOutput = pipe
	do { try child.run() } catch { return "spawn-failed: \(error)" }
	child.waitUntilExit()
	let data = pipe.fileHandleForReading.readDataToEndOfFile()
	return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// ==============================
// ======= 3/ Waits =============
// ==============================

final class NotificationCounter {
	var count = 0
}

let notifications = NotificationCounter()

func pump(_ mode: String) {
	switch mode {
	case "default":
		_ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.01, true)
	case "tracking":
		_ = CFRunLoopRunInMode(CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString), 0.01, true)
	case "nsapp":
		if let event = NSApp.nextEvent(
			matching: .any, until: Date(timeIntervalSinceNow: 0.01), inMode: .default, dequeue: true)
		{
			NSApp.sendEvent(event)
		}
	default:
		usleep(10_000)
	}
}

/// Pumps until this process's current source is `wanted` or `seconds` pass.
func waitForCurrent(_ wanted: String, mode: String, seconds: Double) -> (seen: Bool, milliseconds: Int) {
	let started = ProcessInfo.processInfo.systemUptime
	while true {
		let elapsed = ProcessInfo.processInfo.systemUptime - started
		if currentIdentifier() == wanted { return (true, Int(elapsed * 1000)) }
		if elapsed >= seconds { return (false, Int(elapsed * 1000)) }
		pump(mode)
	}
}

// ==============================
// ======= 4/ Steps =============
// ==============================

func emit(_ record: [String: Any?]) {
	let encodable = record.mapValues { $0 ?? NSNull() }
	guard let data = try? JSONSerialization.data(withJSONObject: encodable, options: [.sortedKeys]) else {
		fail("a record could not be encoded")
	}
	print(String(decoding: data, as: UTF8.self))
	fflush(stdout)
}

struct Tally {
	var seen = 0
	var missed = 0
	var stale = 0
	var recovered = 0
}

/// Selects `id`, waits for this process to see it and records what each side reads.
func step(_ name: String, id: String, cycle: Int, mode: String, viaChild: Bool, tally: inout Tally) {
	guard let source = lookup(id) else { fail("\(id) is not an input source here") }
	let before = notifications.count
	let status: OSStatus
	if viaChild {
		guard let answered = childSelect(id) else { fail("the selecting child gave no status for \(id)") }
		status = answered
	} else {
		status = TISSelectInputSource(source)
	}
	let wait = waitForCurrent(id, mode: mode, seconds: WAIT_SECONDS)
	var record: [String: Any?] = [
		"mode": mode, "cycle": cycle, "step": name, "wanted": id, "status": Int(status),
		"seen": wait.seen, "elapsed_ms": wait.milliseconds,
	]
	let systemSelected = lookup(id).flatMap { flag($0, kTISPropertyInputSourceIsSelected) }
	record.updateValue(systemSelected, forKey: "system_selected")
	record["current"] = currentIdentifier()
	record["preferences"] = preferences()
	if wait.seen {
		tally.seen += 1
	} else {
		tally.missed += 1
		let fresh = freshProcessCurrent()
		record["fresh_process_current"] = fresh
		let stale = systemSelected == true && fresh == id
		record["stale"] = stale
		if stale { tally.stale += 1 }
		let sameMode = waitForCurrent(id, mode: mode, seconds: SAME_MODE_RECOVERY_SECONDS)
		record.updateValue(sameMode.seen ? sameMode.milliseconds : nil, forKey: "recovered_same_mode_ms")
		if sameMode.seen {
			tally.recovered += 1
		} else {
			let defaultMode = waitForCurrent(id, mode: "default", seconds: DEFAULT_MODE_RECOVERY_SECONDS)
			record.updateValue(defaultMode.seen ? defaultMode.milliseconds : nil, forKey: "recovered_default_mode_ms")
			if defaultMode.seen { tally.recovered += 1 }
		}
		record["preferences_after_recovery"] = preferences()
		record["fresh_process_current_after_recovery"] = freshProcessCurrent()
	}
	record["notifications"] = notifications.count - before
	emit(record)
}

/// What the refused cases did between the selections: an event built from the HID state, read back.
func body(cycle: Int, mode: String) {
	var typed = "unavailable"
	if let source = CGEventSource(stateID: .hidSystemState),
		let event = CGEvent(keyboardEventSource: source, virtualKey: 12, keyDown: true)
	{
		var length = 0
		var characters = [UniChar](repeating: 0, count: 4)
		event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &characters)
		typed = String(utf16CodeUnits: characters, count: length)
	}
	emit(["mode": mode, "cycle": cycle, "step": "body", "typed": typed, "current": currentIdentifier()])
}

// ==============================
// ======= 5/ Main ==============
// ==============================

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--read-current"] {
	print(currentIdentifier())
	exit(0)
}
if arguments.count == 2 && arguments[0] == "--select" {
	guard let source = lookup(arguments[1]) else { fail("\(arguments[1]) is not an input source here") }
	print(TISSelectInputSource(source))
	exit(0)
}
let options = parseOptions(arguments)
if options.mode == "nsapp" {
	let application = NSApplication.shared
	application.setActivationPolicy(.accessory)
	application.finishLaunching()
}
_ = DistributedNotificationCenter.default().addObserver(
	forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: nil
) { _ in notifications.count += 1 }

let originalID = currentIdentifier()
guard originalID != options.target else { fail("the target \(options.target) is already current") }
guard let target = lookup(options.target) else { fail("\(options.target) is not an input source here") }
let targetWasEnabled = flag(target, kTISPropertyInputSourceIsEnabled) == true
if options.toggle && targetWasEnabled { fail("--toggle needs \(options.target) disabled at the start") }
if !targetWasEnabled && !options.toggle {
	let status = TISEnableInputSource(target)
	emit(["mode": options.mode, "step": "enable", "wanted": options.target, "status": Int(status)])
	guard status == noErr else { fail("enabling \(options.target) answered \(status)") }
}
emit([
	"mode": options.mode, "step": "start", "original": originalID, "target": options.target,
	"body": options.body, "toggle": options.toggle, "child_select": options.childSelect,
	"fresh_process_current": freshProcessCurrent(),
	"preferences": preferences(),
])

var tally = Tally()
var cyclesRun = 0
/// Enables or disables the target from a fresh lookup, as the fixture's own calls do.
func toggleTarget(_ enable: Bool, cycle: Int, mode: String) -> Bool {
	guard let source = lookup(options.target) else { fail("\(options.target) is not an input source here") }
	let status = enable ? TISEnableInputSource(source) : TISDisableInputSource(source)
	emit(["mode": mode, "cycle": cycle, "step": enable ? "enable" : "disable", "status": Int(status),
		"current": currentIdentifier(), "preferences": preferences()])
	return status == noErr
}

for cycle in 1...options.cycles {
	if options.toggle && !toggleTarget(true, cycle: cycle, mode: options.mode) { break }
	step("select", id: options.target, cycle: cycle, mode: options.mode, viaChild: options.childSelect, tally: &tally)
	if options.body { body(cycle: cycle, mode: options.mode) }
	step("restore", id: originalID, cycle: cycle, mode: options.mode, viaChild: options.childSelect, tally: &tally)
	cyclesRun = cycle
	// Like the fixture, retire the target only once the original is this process's current source.
	if options.toggle {
		guard currentIdentifier() == originalID else { break }
		guard toggleTarget(false, cycle: cycle, mode: options.mode) else { break }
	}
}

// Put the machine back: the original current, the target disabled only if this run enabled it.
if currentIdentifier() != originalID, let original = lookup(originalID) {
	_ = TISSelectInputSource(original)
	_ = waitForCurrent(originalID, mode: "default", seconds: WAIT_SECONDS)
}
let originalCurrent = currentIdentifier() == originalID
let targetEnabledNow = lookup(options.target).flatMap { flag($0, kTISPropertyInputSourceIsEnabled) } == true
if !targetWasEnabled && targetEnabledNow && originalCurrent, let source = lookup(options.target) {
	emit(["mode": options.mode, "step": "disable", "status": Int(TISDisableInputSource(source))])
}

let summary: [String: Any] = [
	"mode": options.mode, "body": options.body, "toggle": options.toggle,
	"child_select": options.childSelect, "cycles": options.cycles, "cycles_run": cyclesRun, "steps": cyclesRun * 2,
	"seen": tally.seen, "missed": tally.missed, "stale": tally.stale, "recovered": tally.recovered,
	"original_current_at_end": originalCurrent,
]
guard let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) else {
	fail("the summary could not be encoded")
}
print("SUMMARY " + String(decoding: data, as: UTF8.self))
