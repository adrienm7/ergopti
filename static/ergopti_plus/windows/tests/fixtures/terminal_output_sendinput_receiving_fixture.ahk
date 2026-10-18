; tests/fixtures/terminal_output_sendinput_receiving_fixture.ahk

; ==============================================================================
; MODULE: Explicit INPUT40 Native Receiving Fixture
; DESCRIPTION:
; Operator-selected real user32 SendInput/owned Edit receiving, with injected
; plan/serializer/custody ports. This never qualifies the native FIFO, hooks,
; complete cohort, physical typing or a production backend policy.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Warn VarUnset, Off

if A_Args.Length != 1 || A_Args[1] != "--allow-explicit-user32-sendinput" {
	FileAppend("REFUSED: one explicit --allow-explicit-user32-sendinput flag is required before GUI/input.`n", "**")
	ExitApp(2)
}
if A_AhkVersion != "2.0.26" || A_PtrSize != 8 {
	FileAppend("REFUSED: pinned AutoHotkey 2.0.26 64-bit Windows desktop is required.`n", "**")
	ExitApp(2)
}

#Include %A_LineFile%\..\..\test_framework.ahk
#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_parser.ahk
#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_tables.ahk
#Include %A_LineFile%\..\..\..\modules\keymap\keylayout\keylayout_emulation.ahk
#Include %A_LineFile%\..\..\..\adapters\llm_nav_event_owner.ahk
#Include %A_LineFile%\..\..\..\adapters\terminal_output_custody.ahk
#Include %A_LineFile%\..\..\unit\modules\llm\nav_event_owner\test_terminal_route_metadata.ahk
#Include %A_LineFile%\..\..\unit\modules\llm\nav_event_owner\test_terminal_output_custody.ahk

; Unit callbacks are registered by their existing owner but never run here.
; Only this fixture's two explicit receiving vectors execute.
global _TSIF := {Gui: 0, Editor: 0, Hwnd: 0, EditHwnd: 0, Thread: 0, Pid: DllCall("GetCurrentProcessId", "UInt"),
	Debt: false, Consumer: 0, NativeCalls: 0, Received: 0, ExitCode: 1}
OnExit(_TSIF_Exit)
; Exact opt-in precedes this hook; physical state is never inferred from injection.
InstallKeybdHook()

_TSIF_WindowIdentity(Hwnd) {
	Pid := 0
	Thread := DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &Pid, "UInt")
	return Map("thread", Thread, "pid", Pid)
}

_TSIF_Admit() {
	global _TSIF
	Owner := _TSIF_WindowIdentity(_TSIF.Hwnd), Child := _TSIF_WindowIdentity(_TSIF.EditHwnd)
	if !IsObject(_TSIF.Gui) || !IsObject(_TSIF.Editor) || !_TSIF.Hwnd || !_TSIF.EditHwnd
			|| _TSIF.Gui.Hwnd != _TSIF.Hwnd || _TSIF.Editor.Hwnd != _TSIF.EditHwnd
			|| Owner["pid"] != _TSIF.Pid || Child["pid"] != _TSIF.Pid
			|| Owner["thread"] != _TSIF.Thread || Child["thread"] != _TSIF.Thread
			|| DllCall("GetForegroundWindow", "Ptr") != _TSIF.Hwnd
			|| DllCall("GetFocus", "Ptr") != _TSIF.EditHwnd || A_IsSuspended
		throw Error("Owned receiving PID/thread/foreground/focus admission was withdrawn.")
	for Key, Vk in Map("LCtrl", 0xA2, "RCtrl", 0xA3, "LAlt", 0xA4, "RAlt", 0xA5,
		"LShift", 0xA0, "RShift", 0xA1, "LWin", 0x5B, "RWin", 0x5C)
		if GetKeyState(Key, "P") || (DllCall("GetAsyncKeyState", "Int", Vk, "Short") & 0x8000)
			throw Error("Release physical modifiers and keep typing idle during the explicit fixture.")
}

_TSIF_SelectedNative(Count, Packets, Size) {
	global _TSIF
	_TSIF_Admit()
	_TSIF.Debt := true
	_TSIF.NativeCalls += 1
	Accepted := _LLM_TerminalOutputSendInputNative(Count, Packets, Size)
	_TSIF_Admit()
	return Accepted
}

_TSIF_ResetRoutes() {
	global _LLM_NavEventOwnerTerminalRouteGeneration, _LLM_NavEventOwnerTerminalRouteNextRecipe
	global _LLM_NavEventOwnerTerminalRouteNextLayout, _LLM_NavEventOwnerTerminalRouteRecipes
	global _LLM_NavEventOwnerTerminalRouteModels, _LLM_NavEventOwnerTerminalRouteRefreshing
	global _LLM_TerminalOutputRecords, _LLM_TerminalOutputUnknown
	if _LLM_TerminalOutputRecords.Count || IsObject(_LLM_TerminalOutputUnknown)
		throw Error("An earlier fixture retains unresolved output custody.")
	_LLM_NavEventOwnerTerminalRouteGeneration := 0
	_LLM_NavEventOwnerTerminalRouteNextRecipe := 0
	_LLM_NavEventOwnerTerminalRouteNextLayout := 1
	_LLM_NavEventOwnerTerminalRouteRecipes := Map()
	_LLM_NavEventOwnerTerminalRouteModels := Map()
	_LLM_NavEventOwnerTerminalRouteRefreshing := false
	_LNTR_LoadFixture("a")
}

_TSIF_Receive(Vector, Expected) {
	global _TSIF
	_TSIF_ResetRoutes()
	_TSIF.Editor.Value := ""
	_TSIF_Admit()
	State := _LNTOC_PacketState(Vector)
	Consumer := TerminalOutputPacketConsumer(901, "none", State.Port, (*) => 0)
	_TSIF.Consumer := Consumer
	Consumer.PacketEmitter := LLM_NavEventOwner_TerminalOutputSendInputEmitter(Consumer.Handle, _TSIF_SelectedNative)
	if !Consumer.Service() || !Consumer.Retired
		throw Error("The real primitive did not settle the full inserted fixture prefix.")
	Started := DllCall("GetTickCount64", "UInt64")
	while _TSIF.Editor.Value != Expected && DllCall("GetTickCount64", "UInt64") - Started < 2000 {
		Sleep(10)
		_TSIF_Admit()
	}
	_TSIF_Admit()
	AssertEqual(Expected, _TSIF.Editor.Value, "The owned native Edit received the complete literal UTF-16 fixture.")
	AssertEqual(1, State.Consumes), AssertEqual(0, State.Cancels)
	AssertEqual(Vector == "plain" ? 2 : 4, State.Acks[1])
	_TSIF.Debt := false
	_TSIF.Received += 1
}

_TSIF_Close(*) {
	ExitApp(1)
	return true
}

_TSIF_Exit(Reason, Code) {
	global _TSIF
	if _TSIF.Debt {
		FileAppend("RETAINED pid=" . _TSIF.Pid . " natural_exit=false output_custody=injected physical_outcome=unqualified`n", "**")
		return 1
	}
	if IsObject(_TSIF.Gui)
		_TSIF.Gui.Destroy()
	FileAppend("NATURAL_EXIT code=" . Code . " vectors=" . _TSIF.Received . " native_calls=" . _TSIF.NativeCalls
		. " source_plan=injected source_serializer=injected native_fifo_qualified=false production_qualified=false backend_policy_changed=false`n", "*")
	return 0
}

try {
	_TSIF.Gui := Gui("", "Ergopti explicit INPUT40 owned receiving fixture")
	_TSIF.Gui.OnEvent("Close", _TSIF_Close)
	_TSIF.Editor := _TSIF.Gui.AddEdit("w460 r3")
	_TSIF.Hwnd := _TSIF.Gui.Hwnd, _TSIF.EditHwnd := _TSIF.Editor.Hwnd
	_TSIF.Thread := _TSIF_WindowIdentity(_TSIF.Hwnd)["thread"]
	_TSIF.Gui.Show()
	WinActivate("ahk_id " . _TSIF.Hwnd)
	if !WinWaitActive("ahk_id " . _TSIF.Hwnd, , 3)
		throw Error("Owned explicit native receiver could not activate.")
	_TSIF.Editor.Focus()
	_TSIF_Receive("plain", "a")
	_TSIF_Receive("surrogate", Chr(0x1F600))
	AssertEqual(2, _TSIF.NativeCalls)
	_TSIF.ExitCode := 0
} catch {
	FileAppend("FAILED explicit_input40_receiving pid=" . _TSIF.Pid . " qualification=unrun_or_failed`n", "**")
	if _TSIF.Debt {
		Persistent()
		return
	}
}
ExitApp(_TSIF.ExitCode)
