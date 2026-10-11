; tests/hardware/group7_hook_trace.ahk
;
; ==============================================================================
; MODULE: Group 7 Owned Native Hook Callback Trace
; DESCRIPTION:
; Logs actual native, HotIf, hotkey and InputHook observations on one QPC clock.
; The explicit synthetic fixture is the only admitted receiver. Missing callback
; observations remain missing; installation requests never prove physical order.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut

global TraceDll := ""
global TraceGui := 0
global TraceEditor := 0
global TraceInput := 0
global TraceNativeStarted := false
global TraceSessionActive := false
global TraceHotkeyInstalled := false
global TraceRecording := false
global TraceInvalid := false
global TraceOwner := 0
global TraceToken := 901
global TraceGeneration := 1
global TraceCurrentCase := ""
global TraceAhkSequence := 0
global TraceEvents := []
global TraceCriterionFn := TraceCriterion
OnError(TraceFatal)
OnExit(TraceRetire)

TraceQpc() {
	Counter := 0
	if !DllCall("QueryPerformanceCounter", "Int64*", &Counter)
		throw OSError()
	return Counter
}

TraceWrite(Json) {
	FileAppend(Json . "`n", "*", "UTF-8-RAW")
}

TraceNative(Name, Arguments*) {
	global TraceDll
	Arguments.Push("CDecl Int")
	return DllCall(TraceDll . "\ErgoptiNav_" . Name, Arguments*)
}

TraceRequire(Status, Stage) {
	if Status != 0
		throw Error("Native " . Stage . " refused with status " . Status . ".")
}

TraceOwned() {
	global TraceGui, TraceEditor
	return IsObject(TraceGui) && IsObject(TraceEditor)
		&& DllCall("GetForegroundWindow", "Ptr") == TraceGui.Hwnd
		&& DllCall("GetFocus", "Ptr") == TraceEditor.Hwnd
}

TraceCheck() {
	global TraceInvalid
	if !TraceOwned() || TraceInvalid
		throw Error("Owned synthetic receiving admission or callback contract failed.")
	for Key in ["Ctrl", "Alt", "Shift", "LWin", "RWin"] {
		if GetKeyState(Key, "P")
			throw Error("Release physical modifiers before synthetic hook tracing.")
	}
	if GetKeyState("CapsLock", "T")
		throw Error("Turn CapsLock off before synthetic hook tracing.")
}

TraceObserve(Channel, Vk := 65, Sc := 30, Codepoint := 0, ObservedQpc := 0) {
	global TraceRecording, TraceInvalid, TraceCurrentCase
	global TraceEvents, TraceAhkSequence
	if !TraceRecording
		return
	EntryQpc := ObservedQpc ? ObservedQpc : TraceQpc()
	if !TraceOwned() || TraceCurrentCase == "" || Vk != 65 || Sc != 30
			|| (Channel == "char" && Codepoint != 97) || TraceEvents.Length >= 256 {
		; Refuse unknown input without logging its character or third-party text.
		TraceInvalid := true
		return
	}
	TraceAhkSequence += 1
	Json := '{"type":"ahk","sequence":"' . TraceAhkSequence
		. '","qpc":"' . EntryQpc . '","channel":"' . Channel
		. '","case_id":"' . TraceCurrentCase . '","vk":' . Vk . ',"sc":' . Sc
	if Channel == "char"
		Json .= ',"codepoint":' . Codepoint
	if Channel == "hotif"
		Json .= ',"decision":true'
	TraceEvents.Push(Json . "}")
}

TraceCriterion(*) {
	EntryQpc := TraceQpc()
	if !TraceOwned()
		return false
	TraceObserve("hotif", 65, 30, 0, EntryQpc)
	return true
}

TraceHotkey(*) {
	TraceObserve("hotkey", 65, 30, 0, TraceQpc())
}

TraceDown(Input, Vk, Sc) {
	TraceObserve("down", Vk, Sc, 0, TraceQpc())
}

TraceUp(Input, Vk, Sc) {
	TraceObserve("up", Vk, Sc, 0, TraceQpc())
}

TraceChar(Input, Text) {
	global TraceInvalid, TraceRecording
	EntryQpc := TraceQpc()
	if !TraceRecording
		return
	if Text != "a" {
		TraceInvalid := true
		return
	}
	TraceObserve("char", 65, 30, 97, EntryQpc)
}

TraceInstallAhk() {
	global TraceInput, TraceHotkeyInstalled, TraceCriterionFn
	InstallKeybdHook()
	HotIf(TraceCriterionFn)
	try {
		Hotkey("~*a", TraceHotkey, "On I1")
		TraceHotkeyInstalled := true
	} finally HotIf()
	TraceInput := InputHook("V L0 I1")
	TraceInput.KeyOpt("a", "N")
	TraceInput.OnKeyDown := TraceDown
	TraceInput.OnKeyUp := TraceUp
	TraceInput.OnChar := TraceChar
	TraceInput.Start()
}

TraceRetire(Reason, Code) {
	global TraceRecording, TraceInput, TraceHotkeyInstalled, TraceCriterionFn
	global TraceSessionActive, TraceNativeStarted, TraceOwner, TraceToken, TraceGeneration
	global TraceGui
	TraceRecording := false
	if IsObject(TraceInput) {
		try TraceInput.Stop()
		catch as Failure {
			FileAppend("RETAINED InputHook cleanup: " . Failure.Message . "`n", "**")
			return 1
		}
		TraceInput := 0
	}
	if TraceHotkeyInstalled {
		try {
			HotIf(TraceCriterionFn)
			Hotkey("~*a", "Off")
			TraceHotkeyInstalled := false
		} catch as Failure {
			FileAppend("RETAINED HotIf/hotkey cleanup: " . Failure.Message . "`n", "**")
			return 1
		} finally HotIf()
	}
	if TraceSessionActive {
		Status := TraceNative("StopHookTrace", "UInt64", TraceOwner,
			"UInt64", TraceToken, "UInt64", TraceGeneration)
		if Status != 0 && Status != 11 {
			FileAppend("RETAINED native trace owner status=" . Status . "`n", "**")
			return 1
		}
		if Status == 11
			FileAppend("Native diagnostic trace is incomplete; no qualification is possible.`n", "**")
		TraceSessionActive := false
	}
	if TraceNativeStarted {
		Status := TraceNative("Stop")
		if Status != 0 {
			FileAppend("RETAINED native owner status=" . Status . "`n", "**")
			return 1
		}
		TraceNativeStarted := false
	}
	if IsObject(TraceGui) {
		TraceGui.Destroy()
		TraceGui := 0
	}
	return 0
}

TraceFatal(Failure, Mode) {
	FileAppend("FATAL " . Type(Failure) . ": " . Failure.Message . "`n", "**")
	ExitApp(1)
}

TraceClose(*) {
	ExitApp(1)
	return true
}

TracePage(Receipt) {
	Fields := [
		["owner", 0], ["token", 8], ["generation", 16], ["attempted", 24],
		["dropped", 32], ["first_sequence", 40], ["last_sequence", 48]]
	Json := '{"type":"page"'
	for Field in Fields
		Json .= ',"' . Field[1] . '":"' . NumGet(Receipt, Field[2], "UInt64") . '"'
	for Field in [["capacity", 56], ["stored", 60], ["page_offset", 64],
			["page_count", 68], ["enabled", 72], ["overflow", 76]]
		Json .= ',"' . Field[1] . '":' . NumGet(Receipt, Field[2], "UInt")
	TraceWrite(Json . "}")
}

TraceNativeRecord(Entries, Offset) {
	Json := '{"type":"native","sequence":"' . NumGet(Entries, Offset, "UInt64")
		. '","qpc":"' . NumGet(Entries, Offset + 8, "UInt64")
		. '","extra_info":"' . Format("0x{:016X}", NumGet(Entries, Offset + 16, "UInt64"))
		. '","capture_sequence":"' . NumGet(Entries, Offset + 24, "UInt64") . '"'
	for Field in [["vk", 32], ["sc", 36], ["flags", 40], ["time", 44],
			["message", 48], ["decision", 52]]
		Json .= ',"' . Field[1] . '":' . NumGet(Entries, Offset + Field[2], "UInt")
	if NumGet(Entries, Offset + 56, "UInt64") != 0
		throw Error("Native trace record reserved bytes are nonzero.")
	TraceWrite(Json . ',"reserved":0}')
}

if A_Args.Length != 4 || A_AhkVersion != "2.0.26" || A_PtrSize != 8
	throw Error("Use the supervisor with AutoHotkey 2.0.26 x64.")
TraceDll := A_Args[1]
RequestedSequence := A_Args[2]
Samples := Integer(A_Args[3])
SendMarker := A_Args[4]
if !FileExist(TraceDll) || Samples < 3 || Samples > 20
		|| (RequestedSequence != "ahk-before-native" && RequestedSequence != "native-before-ahk")
		|| !RegExMatch(SendMarker, "^0x[0-9A-F]{16}$")
	throw Error("Invalid synthetic trace arguments.")
TraceGui := Gui("", "Ergopti Group 7 isolated synthetic hook trace")
TraceGui.OnEvent("Close", TraceClose)
TraceGui.AddText("w620", "Keep the keyboard idle. Only synthetic a is traced in this owned receiver.")
TraceEditor := TraceGui.AddEdit("w620 r5")
TraceGui.Show()
WinActivate("ahk_id " . TraceGui.Hwnd)
if !WinWaitActive("ahk_id " . TraceGui.Hwnd, , 3)
	throw Error("Owned receiving window could not acquire foreground.")
TraceEditor.Focus()
TraceCheck()
TraceOwner := TraceGui.Hwnd
if RequestedSequence == "ahk-before-native"
	TraceInstallAhk()
TraceRequire(TraceNative("Start", "UInt64", A_ScriptHwnd, "UInt", 0x8057), "Start")
TraceNativeStarted := true
if RequestedSequence == "native-before-ahk"
	TraceInstallAhk()
TraceRequire(TraceNative("StartHookTrace", "UInt64", TraceOwner,
	"UInt64", TraceToken, "UInt64", TraceGeneration), "StartHookTrace")
TraceSessionActive := true
Frequency := 0
if !DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	throw OSError()
TraceWrite('{"type":"start","schema":1,"owner":"' . TraceOwner
	. '","token":"' . TraceToken . '","generation":"' . TraceGeneration
	. '","qpc_frequency":"' . Frequency . '","requested_install_sequence":"'
	. RequestedSequence . '","mode":"synthetic","fixture_codepoint":97,"samples":'
	. Samples . ',"send_level":31,"send_marker":"' . SendMarker . '"}')
SetKeyDelay(-1, -1)
SendLevel(31)
TraceRecording := true
for Backend in ["SendEvent", "SendInput"] {
	Loop Samples {
		TraceEditor.Value := ""
		TraceEditor.Focus()
		TraceCheck()
		TraceCurrentCase := Backend . "-" . A_Index
		TraceWrite('{"type":"emission","case_id":"' . TraceCurrentCase
			. '","backend":"' . Backend . '","phase":"before","qpc":"' . TraceQpc() . '"}')
		if Backend == "SendEvent"
			SendEvent("{vk41sc01E}")
		else
			SendInput("{vk41sc01E}")
		TraceWrite('{"type":"emission","case_id":"' . TraceCurrentCase
			. '","backend":"' . Backend . '","phase":"after","qpc":"' . TraceQpc() . '"}')
		Deadline := A_TickCount + 3000
		while TraceEditor.Value != "a" && A_TickCount < Deadline {
			TraceCheck()
			Sleep(1)
		}
		Sleep(100)
		TraceCheck()
		if TraceEditor.Value != "a"
			throw Error("Exact synthetic receiving failed.")
		TraceWrite('{"type":"receiving","case_id":"' . TraceCurrentCase
			. '","backend":"' . Backend . '","value_codepoints":[97],"qpc":"'
			. TraceQpc() . '","settled":true}')
		TraceCurrentCase := ""
	}
}
TraceRecording := false
TraceStopStatus := TraceNative("StopHookTrace", "UInt64", TraceOwner,
	"UInt64", TraceToken, "UInt64", TraceGeneration)
if TraceStopStatus != 0 && TraceStopStatus != 11
	TraceRequire(TraceStopStatus, "StopHookTrace")
TraceSessionActive := false
Entries := Buffer(256 * 64, 0)
Page := Buffer(80, 0)
TraceReadStatus := TraceNative("ReadHookTrace", "UInt64", TraceOwner, "UInt64", TraceToken,
	"UInt64", TraceGeneration, "UInt", 0, "Ptr", Entries, "UInt", 256, "Ptr", Page)
if TraceReadStatus != 0 && TraceReadStatus != 11
	TraceRequire(TraceReadStatus, "ReadHookTrace")
if NumGet(Page, 72, "UInt") != 0
		|| NumGet(Page, 68, "UInt") > 256 || NumGet(Page, 60, "UInt") != NumGet(Page, 68, "UInt")
	throw Error("Native trace page is not a complete frozen observation.")
for EventJson in TraceEvents
	TraceWrite(EventJson)
TracePage(Page)
Loop NumGet(Page, 68, "UInt")
	TraceNativeRecord(Entries, (A_Index - 1) * 64)
if TraceStopStatus == 11 || TraceReadStatus == 11 || NumGet(Page, 76, "UInt") != 0
	throw Error("Incomplete native diagnostic trace; bounded evidence retained without completion.")
if TraceRetire("Completed", 0) == 1
	throw Error("Native trace retirement remains pending.")
TraceWrite('{"type":"complete","native_stop":true,"inputhook_stop":true,"trace_stop":true,'
	. '"hotkey_stop":true,"hotif_clear":true,"hook_order_qualified":false,'
	. '"physical_qualified":false,"production_qualified":false}')
ExitApp(0)
