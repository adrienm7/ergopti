; tests/hardware/replay_marker_consumers.ahk
;
; ==============================================================================
; MODULE: What AutoHotkey consumers see of a terminal-capture replay edge
; DESCRIPTION:
; The native owner replays captured physical keyboard edges with SendInput, an
; injected event whose dwExtraInfo is ERGOPTI_NAV_TERMINAL_REPLAY_MARKER (not an
; AutoHotkey Send marker). Every driver consumer (keylayout emulation, dead keys,
; digit row, profile hotkeys, tap-hold, combinations, script shortcuts) is an
; AutoHotkey hotkey, InputHook or physical-state read, so this script measures
; with the real hook what each of those mechanisms does with such an edge, next
; to an AutoHotkey Send edge at the same levels as a control.
;
; Keys F13 to F16 carry hotkeys at InputLevel 0 to 3 and have no function. The
; script prints one JSON object per case. No key is typed into an application:
; every probe key is swallowed by its hotkey, and the Shift case sends a
; Shift press and release that no application treats as input on its own.
; Usage: AutoHotkey64.exe replay_marker_consumers.ahk
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

global REPLAY_MARKER := 0x4552475054524D31
global PROBE_KEYS := [0x7C, 0x7D, 0x7E, 0x7F]
global INPUT_SIZE := 40
global Fired := Map()
global PhysicalAtFire := Map()
global HookSeen := Map()

ReplayOut(Text) {
	FileAppend(Text . "`n", "*", "UTF-8-RAW")
}

; Hotkey body: records that the level fired and what the physical read said.
ReplayFired(Level, HotkeyName) {
	global Fired, PhysicalAtFire
	Fired[Level] := Fired.Get(Level, 0) + 1
	PhysicalAtFire[Level] := GetKeyState(SubStr(HotkeyName, 2), "P") ? 1 : 0
}

; Injects one key edge with an arbitrary dwExtraInfo through the raw API, the
; way the native owner replays: scan code and virtual key, no AutoHotkey marker.
ReplayRawEdge(Vk, KeyUp, Marker) {
	global INPUT_SIZE
	Scan := DllCall("MapVirtualKeyW", "UInt", Vk, "UInt", 0, "UInt")
	Packet := Buffer(INPUT_SIZE, 0)
	NumPut("UInt", 1, Packet, 0)
	NumPut("UShort", Vk, Packet, 8)
	NumPut("UShort", Scan, Packet, 10)
	NumPut("UInt", KeyUp ? 2 : 0, Packet, 12)
	NumPut("UPtr", Marker, Packet, 24)
	if DllCall("SendInput", "UInt", 1, "Ptr", Packet, "Int", INPUT_SIZE, "UInt") != 1
		throw OSError(A_LastError, "SendInput")
}

ReplayReset() {
	global Fired, PhysicalAtFire
	Fired := Map()
	PhysicalAtFire := Map()
}

ReplayLevels() {
	global Fired
	Text := ""
	for FiredLevel in [0, 1, 2, 3] {
		if Fired.Has(FiredLevel)
			Text .= (Text == "" ? "" : ",") . FiredLevel
	}
	return Text
}

ReplayCase(Name, Action) {
	ReplayReset()
	Action()
	Sleep(250)
	Physical := 0
	for FiredLevel, Value in PhysicalAtFire
		Physical += Value
	ReplayOut('{"case":"' . Name . '","fired_levels":"' . ReplayLevels() . '","physical_reads_true":' . Physical . '}')
}

if A_AhkVersion != "2.0.26" || A_PtrSize != 8
	throw Error("Use pinned AutoHotkey 2.0.26 x64.")
InstallKeybdHook()
for ProbeIndex, ProbeVk in PROBE_KEYS {
	Hotkey("*" . Format("vk{:X}", ProbeVk), ReplayFired.Bind(ProbeIndex - 1), "On I" . (ProbeIndex - 1))
}
SetKeyDelay(-1, -1)

; Raw edge with the replay marker: what the native owner emits.
ReplayCase("replay_marker_edges", () => (ReplayAllRaw(REPLAY_MARKER)))
; Raw edge with no marker at all: any other program's SendInput.
ReplayCase("unmarked_injected_edges", () => (ReplayAllRaw(0)))
; Controls: AutoHotkey's own Send at SendLevel 0 and 3.
ReplayCase("ahk_send_level0", () => (ReplayAhkSend(0)))
ReplayCase("ahk_send_level3", () => (ReplayAhkSend(3)))

; Physical-state reads of an injected modifier (what KLE reads for Shift).
ReplayRawEdge(0xA0, false, REPLAY_MARKER)
Sleep(100)
LogicalDown := GetKeyState("LShift") ? 1 : 0
PhysicalDown := GetKeyState("LShift", "P") ? 1 : 0
ReplayRawEdge(0xA0, true, REPLAY_MARKER)
Sleep(100)
ReplayOut('{"case":"injected_shift_state","logical_down":' . LogicalDown . ',"physical_down":' . PhysicalDown . '}')

; Physical idle time must not restart on an injected edge.
Sleep(1200)
IdleBefore := A_TimeIdlePhysical
ReplayRawEdge(0x7C, false, REPLAY_MARKER)
ReplayRawEdge(0x7C, true, REPLAY_MARKER)
Sleep(50)
IdleAfter := A_TimeIdlePhysical
ReplayOut('{"case":"physical_idle","kept":' . (IdleAfter >= IdleBefore ? 1 : 0) . '}')
ExitApp(0)

ReplayAllRaw(Marker) {
	global PROBE_KEYS
	for ProbeKey in PROBE_KEYS {
		ReplayRawEdge(ProbeKey, false, Marker)
		ReplayRawEdge(ProbeKey, true, Marker)
	}
}

ReplayAhkSend(Level) {
	global PROBE_KEYS
	SendLevel(Level)
	for ProbeKey in PROBE_KEYS
		SendEvent("{" . Format("vk{:X}", ProbeKey) . "}")
	SendLevel(0)
}
