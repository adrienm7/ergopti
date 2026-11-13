; tests/fixtures/core/secure_field_native_style_body.ahk

; Logging is observational only. An inconclusive native classification is a
; setup failure: this fixture never substitutes a UIA or privacy verdict.
global _SFS_DiagnosticErrors := 0
LoggerError(*) {
	global _SFS_DiagnosticErrors
	_SFS_DiagnosticErrors += 1
}
LoggerWarn(*) {
	global _SFS_DiagnosticErrors
	_SFS_DiagnosticErrors += 1
}
LoggerDebug(*) => 0
SFD_ScheduleUiaProbe(*) {
	throw Error("An owned standard Edit must remain natively conclusive; UIA is outside this probe.")
}
_SFS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_SFS_Target(Window, Receiver) {
	_SFS_Require(DllCall("GetForegroundWindow", "Ptr") == Window.Hwnd
		&& DllCall("GetFocus", "Ptr") == Receiver.Hwnd
		&& WinGetPID("ahk_id " . Window.Hwnd) == DllCall("GetCurrentProcessId", "UInt"),
		"The same child-owned Edit must retain native foreground and focus.")
}
_SFS_Main(Mode) {
	global SFD_FIELD_CACHE, SFD_FIELD_CACHE_TTL_MS, _SFS_DiagnosticErrors
	Window := 0, HookStopped := false
	try {
		Window := Gui(, "Ergopti owned native secure-field style probe")
		Receiver := Window.AddEdit("w320", "non_sensitive_probe")
		Window.Show("w360 h100")
		WinActivate("ahk_id " . Window.Hwnd)
		_SFS_Require(WinWaitActive("ahk_id " . Window.Hwnd, , 2), "The private receiver must become active.")
		Receiver.Focus()
		_SFS_Require(SFD_EnsureFocusTracking(), "The actual native WinEvent focus hook must be acquired.")
		Sleep(100)
		_SFS_Target(Window, Receiver)
		NativeBefore := SFD_DetectNative(Receiver.Hwnd, &ConclusiveBefore)
		_SFS_Require(ConclusiveBefore && !NativeBefore, "The initial Edit must be conclusively normal.")
		_SFS_Require(!SFD_IsSecureField(Receiver.Hwnd), "The actual adapter must establish the initial normal verdict.")
		OriginalHwnd := Receiver.Hwnd
		OriginalGeneration := SFD_FIELD_CACHE["focus_generation"]
		OriginalElement := SFD_FIELD_CACHE["current_element_id"]
		OriginalAt := SFD_FIELD_CACHE["at"]
		_SFS_Require(SFD_FIELD_CACHE["focus_hook"] && SFD_FIELD_CACHE["focus_callback"]
			&& SFD_FIELD_CACHE["focus_tracking_active"] && SFD_FIELD_CACHE["hwnd"] == OriginalHwnd
			&& !SFD_FIELD_CACHE["secure"] && OriginalElement != ""
			&& SFD_FIELD_CACHE["verdict_generation"] == OriginalGeneration,
			"The negative cache receipt must belong to the real acquired focus hook and exact Edit.")
		Password := Mode != "normal-current"
		if Password
			Receiver.Opt("+Password")
		; Let ordinary native focus notifications run before the second read. A
		; focus/identity change is a setup refusal, never evidence of a cache bug.
		Sleep(50)
		_SFS_Target(Window, Receiver)
		NativeNow := SFD_DetectNative(Receiver.Hwnd, &ConclusiveNow)
		_SFS_Require(Receiver.Hwnd == OriginalHwnd && ConclusiveNow
			&& NativeNow == Password && !!(WinGetStyle("ahk_id " . Receiver.Hwnd) & 0x20) == Password,
			"The same HWND must have the requested real ES_PASSWORD state.")
		if Mode == "password-expired" {
			while TickElapsed64(OriginalAt) < SFD_FIELD_CACHE_TTL_MS + 25
				Sleep(10)
		}
		_SFS_Target(Window, Receiver)
		Age := TickElapsed64(OriginalAt)
		GenerationSame := SFD_FIELD_CACHE["focus_generation"] == OriginalGeneration
		ElementSame := SFD_FIELD_CACHE["current_element_id"] == OriginalElement
		AtSame := SFD_FIELD_CACHE["at"] == OriginalAt
		ExpectedExpired := Mode == "password-expired"
		FileAppend("# SFD_STYLE_NATIVE phase=receipt mode=" . Mode . " same_hwnd=" . (Receiver.Hwnd == OriginalHwnd)
			. " native_conclusive=" . ConclusiveNow . " native_password=" . NativeNow
			. " focus_same=" . GenerationSame . " element_same=" . ElementSame . " cache_at_same=" . AtSame
			. " cache_age_ms=" . Age . " ttl_ms=" . SFD_FIELD_CACHE_TTL_MS
			. " diagnostic_errors=" . _SFS_DiagnosticErrors . " expected_secure=" . Password . "`n", "*")
		_SFS_Require(GenerationSame && ElementSame && AtSame,
			"The mutation must preserve the original native focus and cache receipt.")
		_SFS_Require(ExpectedExpired ? Age >= SFD_FIELD_CACHE_TTL_MS : Age < SFD_FIELD_CACHE_TTL_MS,
			"The observation must belong to its real current/expired TTL domain.")
		Actual := SFD_IsSecureField(Receiver.Hwnd)
		FileAppend("# SFD_STYLE_NATIVE phase=business mode=" . Mode
			. " actual_secure=" . Actual . " expected_secure=" . Password
			. " diagnostic_errors=" . _SFS_DiagnosticErrors . "`n", "*")
		_SFS_Require(_SFS_DiagnosticErrors == 0,
			"A fail-closed exception or failed native collaborator cannot satisfy the detector oracle.")
		_SFS_Require(Actual == Password,
			"The actual secure-field adapter must follow the current ES_PASSWORD state of its unchanged Edit.")
	} finally {
		try HookStopped := SFD_Stop()
		finally {
			if IsObject(Window)
				Window.Destroy()
		}
		_SFS_Require(HookStopped && !SFD_FIELD_CACHE["focus_hook"] && !SFD_FIELD_CACHE["focus_callback"],
			"The exact native focus hook and callback must acknowledge retirement.")
	}
	_SFS_Require(_SFS_DiagnosticErrors == 0, "Native hook retirement must not hide an adapter diagnostic.")
	FileAppend("PASS secure-field-native-style " . Mode, "*")
}
try {
	_SFS_Require(A_Args.Length == 2 && A_Args[2] == "--allow-owned-native-password-style-probe",
		"Explicit owned native password-style probe opt-in is required.")
	_SFS_Require(A_Args[1] == "normal-current" || A_Args[1] == "password-current" || A_Args[1] == "password-expired",
		"A known native password-style mode is required.")
	_SFS_Main(A_Args[1])
	ExitApp(0)
} catch Any as SFSStyleEntryFailure {
	FileAppend("FAIL secure-field-native-style " . SFSStyleEntryFailure.Message, "*")
	ExitApp(1)
}
