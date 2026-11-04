; tests/hardware/hook_front_reassert.ahk
;
; ==============================================================================
; MODULE: Native owner hook front reassertion (real hooks, real DLL)
; DESCRIPTION:
; AutoHotkey removes and reinstalls its keyboard hook around every SendInput,
; which puts it ahead of the native owner's hook. The owner reinstalls itself
; after a burst of AutoHotkey-stamped output; this script proves it with the
; real DLL and the real hook chain, and prints one JSON object per phase.
;
; A foreign hook installed after the owner stands for AutoHotkey after a
; rehook: it swallows F24, so the owner can only count that key while it is
; again the first hook. F23 and F24 have no function on any layout, and the
; probe key never reaches an application.
;
; With the owner first again, the same chain proves the press ledger: edges
; carrying the owner's replay marker, as a terminal replay sends them, on the two
; keys the driver asks about for AltGr (right Alt, by both of its names) and on
; Shift. AutoHotkey reads them as not physical; the ledger holds them until their
; release. The foreign hook swallows them right behind the owner, so no
; application receives an AltGr or a Shift.
; Usage: AutoHotkey64.exe hook_front_reassert.ahk <dll path>
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

global ForeignSeen := 0
global DllPath := ""
global WaitMs := 2000
global PROBE_VK := 0x87
global BURST_VK := 0x86
global STATS_SIZE := 48
global REPLAY_MARKER := 0x4552475054524D31
global KEY_RIGHT_ALT := 0x138
global KEY_LEFT_SHIFT := 0x02A
global KEY_HIDDEN := 0x02

HookOut(Text) {
	FileAppend(Text . "`n", "*", "UTF-8-RAW")
}

HookNative(Name, Arguments*) {
	global DllPath
	Arguments.Push("CDecl Int")
	return DllCall(DllPath . "\ErgoptiNav_" . Name, Arguments*)
}

HookStats() {
	global STATS_SIZE
	Buf := Buffer(STATS_SIZE, 0)
	NumPut("UInt", STATS_SIZE, Buf, 0)
	StatsStatus := HookNative("GetHookOrderStats", "Ptr", Buf)
	if StatsStatus != 0
		throw Error("GetHookOrderStats failed with status " . StatsStatus)
	return Map("keys", NumGet(Buf, 8, "UInt64"), "armed", NumGet(Buf, 16, "UInt64"),
		"reinstalls", NumGet(Buf, 24, "UInt64"), "failures", NumGet(Buf, 32, "UInt64"),
		"error", NumGet(Buf, 40, "UInt"))
}

; The foreign hook: swallows the probe key, counts its presses.
HookForeign(Code, WParam, LParam) {
	global ForeignSeen, PROBE_VK, REPLAY_MARKER
	if (Code >= 0 && NumGet(LParam, 0, "UInt") == PROBE_VK) {
		if (WParam == 0x100 || WParam == 0x104)
			ForeignSeen += 1
		return 1
	}
	if (Code >= 0 && NumGet(LParam, 24, "UPtr") == REPLAY_MARKER)
		return 1
	return DllCall("CallNextHookEx", "Ptr", 0, "Int", Code, "Ptr", WParam, "Ptr", LParam, "Ptr")
}

; Waits until Condition(Stats) holds; returns the last stats either way.
HookWait(Condition) {
	global WaitMs
	Deadline := A_TickCount + WaitMs
	Loop {
		Stats := HookStats()
		if Condition(Stats) || A_TickCount >= Deadline
			return Stats
		Sleep(5)
	}
}

HookPhase(Name, Before, After) {
	HookOut('{"phase":"' . Name . '","native_keys_delta":' . (After["keys"] - Before["keys"])
		. ',"reinstalls_delta":' . (After["reinstalls"] - Before["reinstalls"])
		. ',"armed_delta":' . (After["armed"] - Before["armed"])
		. ',"failures":' . After["failures"] . ',"error":' . After["error"]
		. ',"foreign_seen":' . ForeignSeen . '}')
}

; One edge as the owner's terminal replay sends it: by scan code, with its marker.
HookReplayEdge(Sc, KeyUp) {
	global REPLAY_MARKER
	Packet := Buffer(40, 0)
	NumPut("UInt", 1, Packet, 0)
	NumPut("UShort", Sc & 0xFF, Packet, 10)
	NumPut("UInt", 0x8 | (Sc > 0xFF ? 0x1 : 0) | (KeyUp ? 0x2 : 0), Packet, 12)
	NumPut("UPtr", REPLAY_MARKER, Packet, 24)
	if DllCall("SendInput", "UInt", 1, "Ptr", Packet, "Int", 40, "UInt") != 1
		throw OSError(A_LastError, "SendInput")
}

; Flags and press number of one key in the real ledger.
HookLedger(Sc) {
	Press := Buffer(24, 0)
	NumPut("UInt", 24, Press, 0)
	QueryStatus := HookNative("QueryKeyPress", "UShort", Sc, "Ptr", Press)
	if QueryStatus != 0
		throw Error("QueryKeyPress failed with status " . QueryStatus)
	return { flags: NumGet(Press, 4, "UInt"), sequence: NumGet(Press, 8, "UInt64") }
}

; Holds a replayed key and reports what each source says about it.
HookLedgerPhase(Name, Sc, AhkNames) {
	global KEY_HIDDEN
	HookReplayEdge(Sc, false)
	Sleep(30)
	Held := HookLedger(Sc)
	Physical := 0
	for KeyName in AhkNames
		Physical += GetKeyState(KeyName, "P") ? 1 : 0
	HookReplayEdge(Sc, true)
	Sleep(30)
	After := HookLedger(Sc)
	HookOut('{"phase":"' . Name . '","hidden_while_held":' . ((Held.flags & KEY_HIDDEN) ? 1 : 0)
		. ',"sequence_while_held":' . Held.sequence
		. ',"physical_while_held":' . Physical
		. ',"flags_after":' . After.flags . '}')
}

if A_Args.Length != 1 || A_AhkVersion != "2.0.26" || A_PtrSize != 8
	throw Error("Usage: pinned AutoHotkey 2.0.26 x64 with the DLL path.")
DllPath := A_Args[1]
if !DllCall("LoadLibraryW", "Str", DllPath, "Ptr")
	throw OSError()
StartStatus := HookNative("Start", "UInt64", A_ScriptHwnd, "UInt", 0x8057)
if StartStatus != 0
	throw Error("Start failed with status " . StartStatus)
Callback := 0
Hook := 0
try {
	Callback := CallbackCreate(HookForeign, "Fast", 3)
	Hook := DllCall("SetWindowsHookExW", "Int", 13, "Ptr", Callback,
		"Ptr", DllCall("GetModuleHandleW", "Ptr", 0, "Ptr"), "UInt", 0, "Ptr")
	if !Hook
		throw OSError()
	SetKeyDelay(-1, -1)
	; Control: the foreign hook is newest, so the owner is blind to the probe key.
	Start := HookStats()
	SendEvent("{vk87}")
	Sleep(150)
	Stop := HookStats()
	HookPhase("foreign_first", Start, Stop)
	; One AutoHotkey-stamped burst: the owner must reinstall itself in front.
	Start := HookStats()
	SendEvent("{vk86}")
	Stop := HookWait((S) => S["reinstalls"] >= Start["reinstalls"] + 2)
	HookPhase("burst", Start, Stop)
	; The settle pass is done; the probe key must now reach the owner first.
	Start := HookStats()
	SendEvent("{vk87}")
	Sleep(150)
	Stop := HookStats()
	HookPhase("owner_first", Start, Stop)
		HookWait((S) => S["reinstalls"] >= Start["reinstalls"] + 2)
	; Without AutoHotkey's own hook its "P" mode is only the logical state.
	InstallKeybdHook()
	HookLedgerPhase("ledger_altgr", KEY_RIGHT_ALT, ["SC138", "RAlt"])
	HookLedgerPhase("ledger_shift", KEY_LEFT_SHIFT, ["LShift", "SC02A"])
} finally {
	if Hook
		DllCall("UnhookWindowsHookEx", "Ptr", Hook)
	if Callback
		CallbackFree(Callback)
	StopCode := HookNative("Stop")
	HookOut('{"phase":"stop","status":' . StopCode . '}')
}
ExitApp(0)
