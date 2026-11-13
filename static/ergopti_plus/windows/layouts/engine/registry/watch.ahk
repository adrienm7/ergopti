; layouts/engine/registry/watch.ahk

; ==============================================================================
; MODULE: Keyboard Layout Registry Watch
; DESCRIPTION:
; Sees a change of the Windows keyboard-layout registry at once and runs the
; layout poll's capture right away (maintainer decision of 2026-11-11: a change
; seen only at the poll's next capture is not acceptable). The one-second
; layout poll (CheckKeyboardLayoutChange) stays the backstop.
;
; FEATURES & RATIONALE:
; 1. RegNotifyChangeKeyValue arms one auto-reset event per watched key:
;    HKCU\Keyboard Layout (Preload, Substitutes: the user's layouts) and the
;    machine's installed layouts (KLS_LAYOUTS_KEY), each with its subtree.
; 2. AutoHotkey has one thread, and a thread-pool wait would call back on
;    another one, so the driver polls the events with a zero timeout: a cheap
;    kernel query per key, every [adapters] layout_registry_watch_poll_ms.
; 3. A signaled key is armed again before the capture runs, so a change made
;    during the capture is caught by the next tick.
; 4. Explicit lifecycle: a start refuses a running watch, a refused start
;    releases what it opened, and the stop (driver shutdown) closes every key
;    and event. The events are created without inheritable security, so no
;    child process receives them.
; 5. Every native call is a port, so the tests replay a notification without
;    touching the real layout keys.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include %A_LineFile%\..\..\..\..\hotstrings\adapters\registry_notify.ahk





; ======================================
; ======================================
; ======= 1/ Constants and state =======
; ======================================
; ======================================

; Win32 predefined keys, sign-extended as the registry API expects them.
global LAYOUT_REGISTRY_WATCH_HKEY_CURRENT_USER := -2147483647
global LAYOUT_REGISTRY_WATCH_HKEY_LOCAL_MACHINE := -2147483646
; REG_NOTIFY_CHANGE_NAME | REG_NOTIFY_CHANGE_LAST_SET: a subkey added or
; removed, a value added, removed or rewritten.
global LAYOUT_REGISTRY_WATCH_FILTER := 0x0005
; The running watch, 0 when none: "capture", "port", "keys" (each "name",
; "handle", "event"), "tick" (the bound poll) and "captures" (count).
global _LayoutRegistryWatch := 0





; =================================
; =================================
; ======= 2/ Start and stop =======
; =================================
; =================================

/**
 * The keys whose change means the installed keyboard layouts changed.
 * @returns {Array} Maps with "root" (predefined key), "subkey" and "name".
 */
LayoutRegistryWatch_DefaultKeys() {
	global KLS_LAYOUTS_KEY, LAYOUT_REGISTRY_WATCH_HKEY_CURRENT_USER, LAYOUT_REGISTRY_WATCH_HKEY_LOCAL_MACHINE
	MachinePrefix := "HKLM\"
	if (SubStr(KLS_LAYOUTS_KEY, 1, StrLen(MachinePrefix)) != MachinePrefix)
		throw ValueError("The installed layouts key is not under HKLM: " . KLS_LAYOUTS_KEY)
	return [
		Map("root", LAYOUT_REGISTRY_WATCH_HKEY_CURRENT_USER, "subkey", "Keyboard Layout",
			"name", "HKCU\Keyboard Layout"),
		Map("root", LAYOUT_REGISTRY_WATCH_HKEY_LOCAL_MACHINE,
			"subkey", SubStr(KLS_LAYOUTS_KEY, StrLen(MachinePrefix) + 1), "name", KLS_LAYOUTS_KEY)
	]
}

/**
 * Starts watching the keyboard-layout registry.
 * @param {Func} Capture Run at once after a change (the layout poll's tick).
 * @param {Array} Keys Optional keys (LayoutRegistryWatch_DefaultKeys' shape);
 *   the layout keys when omitted.
 * @param {Map} Port Optional native port (_LayoutRegistryWatchNativePort's
 *   shape); the live registry when omitted.
 * @returns {Boolean} True once watching; false when Windows refused, after
 *   releasing what was opened: the layout poll alone sees a change then.
 */
LayoutRegistryWatch_Start(Capture, Keys := 0, Port := 0) {
	global _LayoutRegistryWatch
	if IsObject(_LayoutRegistryWatch)
		throw Error("The keyboard layout registry watch is already running.", -1)
	if !HasMethod(Capture, "Call")
		throw ValueError("The keyboard layout registry watch needs a capture.", -1)
	if !(Keys is Array)
		Keys := LayoutRegistryWatch_DefaultKeys()
	if !(Port is Map)
		Port := _LayoutRegistryWatchNativePort()
	try LoggerStart("LayoutRegistryWatch", "Watching {1} keyboard layout registry key(s)…", Keys.Length)
	Watch := Map("capture", Capture, "port", Port, "keys", [], "tick", 0, "captures", 0)
	try {
		for Key in Keys {
			Entry := Map("name", Key["name"], "handle", 0, "event", 0)
			Watch["keys"].Push(Entry)
			Entry["handle"] := Port["open"].Call(Key["root"], Key["subkey"])
			Entry["event"] := Port["event"].Call()
			Port["arm"].Call(Entry["handle"], Entry["event"])
		}
	} catch as Err {
		ReleaseError := _LayoutRegistryWatchRelease(Watch)
		try LoggerError("LayoutRegistryWatch",
			"The keyboard layout registry watch could not start: {1}{2}. A change is seen at the layout poll's next capture only.",
			Err.Message, ReleaseError == "" ? "" : " (release: " . ReleaseError . ")")
		return false
	}
	Watch["tick"] := _LayoutRegistryWatchTick.Bind(Watch)
	_LayoutRegistryWatch := Watch
	Port["schedule"].Call(Watch["tick"], TimingsGet("adapters", "layout_registry_watch_poll_ms"))
	try LoggerSuccess("LayoutRegistryWatch", "A keyboard layout registry change is captured at once.")
	return true
}

/**
 * Stops the watch: ends its poll and closes every key and event. Nothing to
 * do when no watch runs.
 * @returns {Boolean} False when a handle could not be closed (logged).
 */
LayoutRegistryWatch_Stop() {
	global _LayoutRegistryWatch
	if !IsObject(_LayoutRegistryWatch)
		return true
	Watch := _LayoutRegistryWatch
	_LayoutRegistryWatch := 0
	Watch["port"]["schedule"].Call(Watch["tick"], 0)
	ReleaseError := _LayoutRegistryWatchRelease(Watch)
	if (ReleaseError != "") {
		try LoggerError("LayoutRegistryWatch", "The keyboard layout registry watch stopped with a handle left open: {1}.",
			ReleaseError)
		return false
	}
	try LoggerInfo("LayoutRegistryWatch", "The keyboard layout registry watch stopped after {1} capture(s).",
		Watch["captures"])
	return true
}

/** Whether a watch runs. */
LayoutRegistryWatch_IsRunning() {
	global _LayoutRegistryWatch
	return IsObject(_LayoutRegistryWatch)
}

; Closes every key (which ends its notification) and event the watch opened.
; @returns {String} "" when all closed, else the failures.
_LayoutRegistryWatchRelease(Watch) {
	Failures := ""
	for Entry in Watch["keys"] {
		for Kind in ["handle", "event"] {
			if !Entry[Kind]
				continue
			try {
				Watch["port"][Kind == "handle" ? "close_key" : "close_event"].Call(Entry[Kind])
				Entry[Kind] := 0
			} catch as Err
				Failures .= (Failures == "" ? "" : "; ") . Entry["name"] . " " . Kind . ": " . Err.Message
		}
	}
	return Failures
}





; ==================================
; ==================================
; ======= 3/ Seeing a change =======
; ==================================
; ==================================

; One poll: arms every signaled key again, then runs the capture once.
_LayoutRegistryWatchTick(Watch) {
	global _LayoutRegistryWatch
	; A tick queued before the stop belongs to a retired watch.
	if (_LayoutRegistryWatch != Watch)
		return
	Port := Watch["port"]
	Changed := ""
	for Entry in Watch["keys"] {
		if !Port["signaled"].Call(Entry["event"])
			continue
		try Port["arm"].Call(Entry["handle"], Entry["event"])
		catch as Err {
			LayoutRegistryWatch_Stop()
			try LoggerError("LayoutRegistryWatch",
				"Watching {1} again failed: {2}. A change is seen at the layout poll's next capture only.",
				Entry["name"], Err.Message)
			return
		}
		Changed .= (Changed == "" ? "" : ", ") . Entry["name"]
	}
	if (Changed == "")
		return
	Watch["captures"] += 1
	try LoggerInfo("LayoutRegistryWatch", "Keyboard layout registry changed ({1}); capturing the layout state now.", Changed)
	try Watch["capture"].Call()
	catch as Err
		try LoggerError("LayoutRegistryWatch", "The layout capture after a registry change failed: {1}.", Err.Message)
}





; ==============================
; ==============================
; ======= 4/ Native port =======
; ==============================
; ==============================

; The live registry, events and timer behind the watch
; (hotstrings/adapters/registry_notify.ahk).
_LayoutRegistryWatchNativePort() {
	static Port := Map(
		"open", RegistryNotifyOpenKey,
		"event", RegistryNotifyCreateEvent,
		"arm", _LayoutRegistryWatchArm,
		"signaled", RegistryNotifySignaled,
		"close_key", RegistryNotifyCloseKey,
		"close_event", RegistryNotifyCloseEvent,
		"schedule", _LayoutRegistryWatchSchedule)
	return Port
}

; A change of the key or its subtree: a subkey or a value.
_LayoutRegistryWatchArm(Handle, Event) {
	global LAYOUT_REGISTRY_WATCH_FILTER
	RegistryNotifyArm(Handle, Event, LAYOUT_REGISTRY_WATCH_FILTER)
}

; Arms or cancels the watch's poll; [adapters] layout_registry_watch_poll_ms.
_LayoutRegistryWatchSchedule(Tick, PeriodMs) {
	TimerSetCallback(Tick, PeriodMs)
}
