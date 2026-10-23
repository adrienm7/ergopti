; tests/fixtures/gesture_cycle_pause_owner_body.ahk

; ==============================================================================
; MODULE: Native Gesture Window-Cycle Pause Child
; DESCRIPTION:
; Calls the genuine public gesture dispatcher against two private native GUIs.
; Enumeration delegates to the real OS list, restricted to those exact HWNDs;
; foreground activation is the complete, unchanged native production path.
; Logger delivery and a real timer provide the ordinary pre-Critical pause.
; This cold-tracker component does not claim physical touchpad or WinEvent input.
; ==============================================================================

#Requires AutoHotkey v2.0

global _SharedDir := _GPO_SourceShared
global Features := Map("gestures", Map("enabled", true))
global GestureAssignments := Map("tap_3", "none")
global GESTURE_ACTION_CATALOGUE := GestureActionCatalogueData()
global _GCFC := {Family: A_Args[1], Mode: A_Args[2], Root: A_Args[3], Windows: [],
	A: 0, B: 0, Logs: [], Errors: [], FirstFailure: 0, SinkArmed: false,
	LogCalls: 0, PauseCalls: 0, PauseDone: false, PauseForeground: 0,
	EnumerationCalls: 0, Before: 0, After: 0, PausedAfter: false,
	WasSuspended: A_IsSuspended, WasCritical: A_IsCritical}

_GCFC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_GCFC_Fail(Failure) {
	global _GCFC
	if !IsObject(_GCFC.FirstFailure)
		_GCFC.FirstFailure := Failure
}

_GCFC_OnError(Failure, Mode) {
	_GCFC_Fail(Failure)
	return true
}

_GCFC_Foreground() {
	return DllCall("User32\GetForegroundWindow", "Ptr")
}

_GCFC_OwnedWindowList() {
	global _GCFC
	Result := [], Actual := WMGetList()
	_GCFC.EnumerationCalls += 1
	for Hwnd in Actual {
		if Hwnd == _GCFC.A.Hwnd || Hwnd == _GCFC.B.Hwnd
			Result.Push(Hwnd)
	}
	_GCFC_Require(Result.Length == 2, "The native enumeration must contain both exact visible fixture windows.")
	return Result
}

_GCFC_Pause() {
	global _GCFC
	try {
		_GCFC.PauseCalls += 1
		_GCFC_Require(_GCFC.PauseCalls == 1 && !A_IsCritical && !A_IsSuspended,
			"The real pause timer must run once outside the cycle's Critical activation.")
		_GCFC.PauseForeground := _GCFC_Foreground()
		_GCFC_Require(_GCFC.PauseForeground == _GCFC.A.Hwnd,
			"The exact initial GUI must still own the native foreground before pause.")
		Suspend(true)
		_GCFC_Require(A_IsSuspended, "The actual native Suspend must complete.")
		_GCFC.PauseDone := true
	} catch Any as Failure {
		_GCFC_Fail(Failure)
	}
}

_GCFC_WaitPause() {
	global _GCFC
	Started := DllCall("Kernel32\GetTickCount64", "UInt64")
	while !_GCFC.PauseDone && !IsObject(_GCFC.FirstFailure)
		&& DllCall("Kernel32\GetTickCount64", "UInt64") - Started < 3000
		Sleep(10)
	_GCFC_Require(_GCFC.PauseDone, "The genuine native pause timer must acknowledge before dispatch continues.")
}

_GCFC_Sink(Line) {
	global _GCFC
	if _GCFC.Logs.Length < 100
		_GCFC.Logs.Push(Line)
	if RegExMatch(Line, "\s\[ERROR\] \[")
		_GCFC.Errors.Push(Line)
	Sentinel := _GCFC.Family == "windows" ? "[DEBUG] [gestures] CycleWindows: " : "[DEBUG] [gestures] CycleAppWindows '"
	if !_GCFC.SinkArmed || !InStr(Line, Sentinel, true)
		return
	_GCFC.SinkArmed := false
	try {
		_GCFC.LogCalls += 1
		_GCFC_Require(!A_IsCritical && !A_IsSuspended,
			"The actual cycle diagnostic must precede its Critical activation and the completed pause.")
		SetTimer(_GCFC_Pause, -1)
		_GCFC_WaitPause()
	} catch Any as Failure {
		_GCFC_Fail(Failure)
	}
}

_GCFC_Prepare() {
	global _GCFC, LOGGER_MIN_LEVEL, GESTURE_ACTIONS
	_GCFC_Require(A_Args.Length == 5 && (_GCFC.Family == "windows" || _GCFC.Family == "apps"),
		"The exact private native child ABI must be valid.")
	_GCFC_Require(_GCFC.Mode == "current" || _GCFC.Mode == "during-logger" || _GCFC.Mode == "paused-entry",
		"The pause mode must be declared.")
	for Index, Path in Map(4, A_ScriptFullPath, 5, A_AhkPath)
		_GCFC_Require(RegExMatch(A_Args[Index], "^[0-9a-f]{64}$") && CryptoSha256Bytes(FSReadBytesStrict(Path)) == A_Args[Index],
			"The actual source and runtime must match their frozen inputs.")
	for Key in ["LControl", "RControl", "LShift", "RShift", "LWin", "RWin"]
		_GCFC_Require(!GetKeyState(Key) && !GetKeyState(Key, "P"),
			"Private dispatch requires clear real carrier modifiers; no synthetic carrier release is exercised.")
	Action := _GCFC.Family == "windows" ? "win_next" : "win_app_next"
	_GCFC_Require(GESTURE_ACTIONS.Has(Action) && GESTURE_ACTION_CATALOGUE.Actions.Has(Action)
		&& !GestureActionNeedsConfirm(Action) && GestureActionParameterSpec(Action) == "",
		"The real registry and generated catalogue must select the ordinary public zero-argument route.")
	GestureAssignments["tap_3"] := Action
	LOGGER_MIN_LEVEL := "DEBUG"
	_LoggerRefreshFastFlags()
	LoggerSetTestSink(_GCFC_Sink)
	for Name in ["A", "B"] {
		Window := Gui("+Resize", "Ergopti private cycle " . Name . " " . A_ScriptHwnd)
		_GCFC.Windows.Push(Window)
		_GCFC.%Name% := Window
		Window.AddEdit("w240 r3", "Private " . Name)
		Window.Show("w300 h150")
		_GCFC_Require(DllCall("User32\IsWindow", "Ptr", Window.Hwnd, "Int"), "Each candidate needs its own real HWND.")
	}
	; Native focus is a prerequisite, never an injected activation success.
	_GCFC_Require(WMForceForeground(_GCFC.B.Hwnd) && _GCFC_Foreground() == _GCFC.B.Hwnd,
		"The private target must genuinely accept native foreground activation.")
	_GCFC_Require(WMForceForeground(_GCFC.A.Hwnd) && _GCFC_Foreground() == _GCFC.A.Hwnd,
		"The private initial window must genuinely accept native foreground activation.")
	_GCFC.Before := _GCFC_Foreground()
}

_GCFC_Exercise() {
	global _GCFC
	if _GCFC.Mode == "during-logger"
		_GCFC.SinkArmed := true
	else if _GCFC.Mode == "paused-entry" {
		SetTimer(_GCFC_Pause, -1)
		_GCFC_WaitPause()
	}
	GestureDispatch("tap_3")
	_GCFC.After := _GCFC_Foreground()
	_GCFC.PausedAfter := A_IsSuspended
	FileAppend("OBSERVATION " . KL_JsonEncode(Map("family", _GCFC.Family, "mode", _GCFC.Mode,
		"a", _GCFC.A.Hwnd, "b", _GCFC.B.Hwnd, "before", _GCFC.Before, "after", _GCFC.After,
		"pause_calls", _GCFC.PauseCalls, "pause_done", _GCFC.PauseDone, "pause_foreground", _GCFC.PauseForeground,
		"log_calls", _GCFC.LogCalls, "native_paused", _GCFC.PausedAfter, "enumerations", _GCFC.EnumerationCalls,
		"logs", _GCFC.Logs, "errors", _GCFC.Errors)) . "`n", "*", "UTF-8")
	if IsObject(_GCFC.FirstFailure)
		throw _GCFC.FirstFailure
	_GCFC_Require(_GCFC.Errors.Length == 0, "The genuine route must not hide a prerequisite or action failure in its logger.")
	if _GCFC.Mode == "current" {
		_GCFC_Require(_GCFC.EnumerationCalls > 0 && _GCFC.PauseCalls == 0 && !_GCFC.PausedAfter,
			"The real current route must enumerate and remain active.")
		_GCFC_Require(_GCFC.After == _GCFC.B.Hwnd, "The genuine current action must foreground the other private GUI.")
	} else {
		_GCFC_Require(_GCFC.PauseCalls == 1 && _GCFC.PauseDone && _GCFC.PausedAfter,
			"The actual pause must be complete and remain active before the no-activation oracle.")
		if _GCFC.Mode == "during-logger"
			_GCFC_Require(_GCFC.LogCalls == 1 && _GCFC.EnumerationCalls > 0,
				"The actual cycle logger and native enumeration must be reached before the controlled pause.")
		_GCFC_Require(_GCFC.After == _GCFC.A.Hwnd, "A paused gesture must not move native foreground focus away from its private initial GUI.")
		Suspend(false)
		Sleep(30)
		_GCFC_Require(_GCFC_Foreground() == _GCFC.A.Hwnd, "Resume must not replay the refused native activation.")
		GestureDispatch("tap_3")
		_GCFC_Require(_GCFC_Foreground() == _GCFC.B.Hwnd, "A fresh resumed gesture must still activate its genuine private target.")
	}
}

_GCFC_Cleanup() {
	global _GCFC
	for Cleanup in [(*) => SetTimer(_GCFC_Pause, 0), LoggerClearTestSink] {
		try Cleanup.Call()
		catch Any as Failure {
			_GCFC_Fail(Failure)
		}
	}
	for Window in _GCFC.Windows {
		try {
			Hwnd := Window.Hwnd
			Window.Destroy()
			_GCFC_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every exact private GUI must retire.")
		} catch Any as Failure {
			_GCFC_Fail(Failure)
		}
	}
	try Suspend(_GCFC.WasSuspended)
	catch Any as Failure {
		_GCFC_Fail(Failure)
	}
	Critical(_GCFC.WasCritical)
}

_GCFC_Main() {
	global _GCFC
	OnError(_GCFC_OnError)
	Critical("Off")
	Suspend(false)
	try {
		_GCFC_Prepare()
		_GCFC_Exercise()
	} catch Any as Failure {
		_GCFC_Fail(Failure)
	} finally {
		try _GCFC_Cleanup()
		catch Any as Failure {
			_GCFC_Fail(Failure)
		}
		OnError(_GCFC_OnError, 0)
	}
	if IsObject(_GCFC.FirstFailure)
		throw _GCFC.FirstFailure
	FileAppend("PASS gesture-cycle-pause " . _GCFC.Family . " " . _GCFC.Mode . "`n", "*", "UTF-8")
}

try {
	_GCFC_Main()
	ExitApp(0)
} catch Any as Failure {
	Detail := Failure is Error ? Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n" . Failure.Stack : "Non-Error failure"
	FileAppend("FAIL " . Detail, "**", "UTF-8")
	ExitApp(1)
}
