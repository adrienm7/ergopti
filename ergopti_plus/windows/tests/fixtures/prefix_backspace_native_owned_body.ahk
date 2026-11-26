; tests/fixtures/prefix_backspace_native_owned_body.ahk

; Ancillary services are passive ports: they never decide field admission,
; emit a prediction, perform HTTP, or acknowledge any physical screen effect.
global _LLM_Bridge_Active := true, _LLM_Bridge_Buffer := "", _LLM_Bridge_ContentGeneration := 0
global _LLM_Bridge_BufferSource := 0, _LLM_Bridge_BufferAgentSafe := true, _LLM_Bridge_PrefixObserver := 0
global _LLM_Bridge_AgentBuffer := "", _LLM_Bridge_AgentBufferSource := 0, _LLM_Bridge_AgentContentGeneration := 0
global _LLM_Bridge_AgentFeeding := false, _PrefixDeferredGeneration := 1, _KS_PhysicalInputGeneration := 0
global _LLM_Bridge_ReadLiveFocus := _LLM_Bridge_ReadFocusReceipt
global _LLM_Engine := Map("enabled", false, "request_id", 1, "disable_password_fields", true,
	"pending_timer", "", "timer_active", false, "last_buffer", "", "active_request_signature", "")
global _SFBX_Diagnostics := 0
LoggerError(*) {
	global _SFBX_Diagnostics
	_SFBX_Diagnostics += 1
}
LoggerWarn(*) {
	global _SFBX_Diagnostics
	_SFBX_Diagnostics += 1
}
LoggerDebug(*) => 0
SFD_ScheduleUiaProbe(*) {
	throw Error("The owned standard Edit must stay natively conclusive.")
}
LLM_Engine_CancelTimer() {
	global _LLM_Engine
	_LLM_Engine["pending_timer"] := "", _LLM_Engine["timer_active"] := false
}
LLM_Agent_InvalidateTyping(*) => 0
LLM_Agent_WatchesTyping() => false
_LLM_Bridge_RunPrefixObserver(Owner) {
	global _LLM_Bridge_PrefixObserver
	if IsObject(_LLM_Bridge_PrefixObserver) && _LLM_Bridge_PrefixObserver == Owner
		_LLM_Bridge_PrefixObserver := 0
	Owner.Timer := 0
}
LLM_Bridge_MirrorAgentEdit(*) {
	throw Error("This owned prediction-active probe never enters the agent-only edit branch.")
}
_LLM_Bridge_ObserveAgentTyping(*) {
	throw Error("This owned prediction-active probe never enters the agent-only key branch.")
}
KS_IsContextResetKey(*) {
	throw Error("Only the explicit Backspace key may enter the public key producer.")
}
LLM_Tooltip_TryAcceptTab(*) {
	throw Error("No Tab acceptance is part of this probe.")
}
LLM_Bridge_OnFlush(*) {
	throw Error("No flush key is part of this probe.")
}
LLM_Bridge_ResetPredictions(*) {
	throw Error("No navigation key is part of this probe.")
}
_SFBX_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_SFBX_Target(State) {
	_SFBX_Require(DllCall("GetForegroundWindow", "Ptr") == State.Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == State.Receiver.Hwnd
		&& WinGetPID("ahk_id " . State.Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"Every injected key must target the same child-owned foreground Edit.")
}
_SFBX_Char(State, IH, Char) {
	if !State.Accepting
		return
	PreviousCritical := Critical("On")
	try {
		_SFBX_Target(State)
		_SFBX_Require(IH == State.Hook && State.Hook.InProgress, "The exact private I1 hook must deliver its character.")
		State.Chars .= Char
		LLM_Bridge_FeedCharForPrefix(Char)
	} catch Any as Failure {
		State.Failure := Failure
	} finally Critical(PreviousCritical)
}
_SFBX_Key(State, IH, VK, SC) {
	if !State.Accepting || State.Stage != "backspace" || VK != 0x08
		return
	PreviousCritical := Critical("On")
	try {
		global _LLM_Bridge_Buffer, _LLM_Bridge_PrefixObserver
		_SFBX_Target(State)
		_SFBX_Require(IH == State.Hook && State.Hook.InProgress, "The exact private I1 hook must deliver Backspace.")
		State.NativePrivate := !!(WinGetStyle("ahk_id " . State.Receiver.Hwnd) & 0x20)
		LLM_Bridge_FeedKeyDownIfActive(VK)
		State.BufferAtKey := _LLM_Bridge_Buffer
		State.CapturedAtKey := IsObject(_LLM_Bridge_PrefixObserver) ? _LLM_Bridge_PrefixObserver.CapturedSecure : -1
		State.Keys += 1
	} catch Any as Failure {
		State.Failure := Failure
	} finally Critical(PreviousCritical)
}
_SFBX_Send(State, Keys, Text := false) {
	_SFBX_Target(State)
	SavedLevel := A_SendLevel, SavedDelay := A_KeyDelay, SavedDuration := A_KeyDuration
	try {
		SendLevel(2), SetKeyDelay(-1, -1)
		SendEvent((Text ? "{Text}" : "") . Keys)
	} finally {
		SendLevel(SavedLevel), SetKeyDelay(SavedDelay, SavedDuration)
	}
}
_SFBX_Main(Private) {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS, _LLM_Bridge_Buffer, _LLM_Bridge_PrefixObserver, _SFBX_Diagnostics
	State := {Window: 0, Receiver: 0, Hook: 0, Accepting: false, Stage: "seed",
		Chars: "", Keys: 0, BufferAtKey: "", CapturedAtKey: -1, NativePrivate: false, Failure: 0}
	try {
		State.Window := Gui(, "Owned native Backspace privacy gap")
		State.Receiver := State.Window.AddEdit("w320", "")
		State.Window.Show("w360 h100")
		WinActivate("ahk_id " . State.Window.Hwnd)
		_SFBX_Require(WinWaitActive("ahk_id " . State.Window.Hwnd, , 2), "The private receiver must become active.")
		State.Receiver.Focus()
		_SFBX_Require(SFD_EnsureFocusTracking(), "The native focus hook must be genuinely acquired.")
		Sleep(100)
		_SFBX_Target(State)
		_SFBX_Require(!SFD_IsSecureField(State.Receiver.Hwnd), "The original Edit must be conclusively normal.")
		State.Hook := InputHook("V L0 I1")
		State.Hook.KeyOpt("{All}", "+N")
		State.Hook.OnChar := _SFBX_Char.Bind(State)
		State.Hook.OnKeyDown := _SFBX_Key.Bind(State)
		State.Accepting := true
		State.Hook.Start()
		_SFBX_Require(State.Hook.InProgress, "The actual private InputHook must start.")
		_SFBX_Send(State, "abc", true)
		Started := A_TickCount
		while (State.Chars != "abc" || IsObject(_LLM_Bridge_PrefixObserver)) && TickElapsed64(Started) < 2000
			Sleep(5)
		if IsObject(State.Failure)
			throw State.Failure
		_SFBX_Require(State.Chars == "abc" && ControlGetText(State.Receiver.Hwnd) == "abc" && _LLM_Bridge_Buffer == "abc",
			"The genuine native receiver and prefix producer must establish the same normal context.")
		Generation := SFD_FIELD_CACHE["focus_generation"]
		Element := SFD_FIELD_CACHE["current_element_id"]
		Origin := SFD_FIELD_CACHE["at"]
		_SFBX_Require(SFD_FIELD_CACHE["focus_hook"] && SFD_FIELD_CACHE["focus_callback"]
			&& SFD_FIELD_CACHE["focus_tracking_active"] && !SFD_FIELD_CACHE["secure"]
			&& SFD_FIELD_CACHE["hwnd"] == State.Receiver.Hwnd && Element != "",
			"The original negative receipt must belong to the actual focus hook and Edit.")
		if Private
			State.Receiver.Opt("+Password")
		Sleep(30)
		_SFBX_Target(State)
		NativePrivate := SFD_DetectNative(State.Receiver.Hwnd, &Conclusive)
		_SFBX_Require(Conclusive && NativePrivate == Private, "The unchanged native Edit must have its intended password style.")
		_SFBX_Require(Generation == SFD_FIELD_CACHE["focus_generation"] && Element == SFD_FIELD_CACHE["current_element_id"],
			"The gap must preserve the original native focus and element identity.")
		Age := TickElapsed64(Origin)
		_SFBX_Require(Age < SFD_FIELD_CACHE_TTL_MS, "The original unmodified negative-cache TTL must still be current.")
		State.Stage := "backspace"
		_SFBX_Send(State, "{BackSpace}")
		Started := A_TickCount
		while (State.Keys != 1 || ControlGetText(State.Receiver.Hwnd) != "ab") && TickElapsed64(Started) < 2000
			Sleep(5)
		if IsObject(State.Failure)
			throw State.Failure
		FileAppend("# PREFIX_BACKSPACE_NATIVE private=" . Private . " keys=" . State.Keys
			. " native_private=" . State.NativePrivate . " buffer_at_key_units=" . StrLen(State.BufferAtKey)
			. " captured_private=" . State.CapturedAtKey . " cache_age_before_key_ms=" . Age
			. " ttl_ms=" . SFD_FIELD_CACHE_TTL_MS . " diagnostics=" . _SFBX_Diagnostics . "`n", "*")
		_SFBX_Require(State.Keys == 1 && ControlGetText(State.Receiver.Hwnd) == "ab", "One actual I1 Backspace must delete one native receiver character.")
		_SFBX_Require(State.NativePrivate == Private && _SFBX_Diagnostics == 0, "Native classification must agree without any hidden diagnostic failure.")
		_SFBX_Require(State.BufferAtKey == (Private ? "" : "ab"), "Backspace must retire private context at admission and still edit a normal context.")
		if Private && State.CapturedAtKey != -1
			_SFBX_Require(State.CapturedAtKey, "A retained callback must freeze its private capture origin.")
	} finally {
		State.Accepting := false
		try {
			if IsObject(State.Hook) {
				State.Hook.Stop()
				State.Hook.OnChar := "", State.Hook.OnKeyDown := ""
				_SFBX_Require(!State.Hook.InProgress, "The private InputHook must acknowledge retirement.")
				State.Hook := 0
			}
			LLM_Bridge_CancelPrefixObserver()
		} finally {
			try _SFBX_Require(SFD_Stop(), "The actual native focus hook must acknowledge retirement.")
			finally {
				if IsObject(State.Window)
					State.Window.Destroy()
			}
		}
	}
	_SFBX_Require(_SFBX_Diagnostics == 0, "Native retirement cannot hide adapter errors.")
}
try {
	_SFBX_Require(A_Args.Length == 2 && A_Args[2] == "--allow-owned-native-backspace-gap",
		"Explicit owned native Backspace probe opt-in is required.")
	_SFBX_Require(A_Args[1] == "private" || A_Args[1] == "normal", "A known Backspace mode is required.")
	_SFBX_Main(A_Args[1] == "private")
	FileAppend("PASS prefix-backspace-native " . A_Args[1], "*")
	ExitApp(0)
} catch Any as SFBXEntryFailure {
	FileAppend("FAIL prefix-backspace-native " . SFBXEntryFailure.Message, "*")
	ExitApp(1)
}
