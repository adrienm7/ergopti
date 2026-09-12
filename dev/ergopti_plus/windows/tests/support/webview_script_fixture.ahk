; tests/support/webview_script_fixture.ahk

; ==============================================================================
; MODULE: WebView Native Script Test Fixture
; DESCRIPTION:
; A native-shaped test double returns the real vendored Promise. Captured
; resolve/reject callbacks drive completion without creating a real WebView.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WVSO_View {
	__New() {
		this.Scripts := []
		this.Messages := []
		this.Pending := Promise(this._Capture.Bind(this))
	}
	_Capture(Resolve, Reject) {
		this.Resolve := Resolve
		this.Reject := Reject
	}
	ExecuteScriptAsync(Script) {
		this.Scripts.Push(Script)
		if this.HasOwnProp("Failure")
			throw this.Failure
		return this.Pending
	}
	PostWebMessageAsString(Message) {
		this.Messages.Push(Message)
	}
}

_WVSO_CaptureError(Expected, Errors, Err, Mode) {
	if Err !== Expected
		return 0
	Errors.Push(Err)
	return 1
}

_WVSO_Drain(View) {
	Started := A_TickCount
	while View.Pending.HasOwnProp("callbacks") && A_TickCount - Started < 2000
		Sleep(1)
	AssertFalse(View.Pending.HasOwnProp("callbacks"), "the actual Promise timer must execute")
}

_WVSO_WithFixture(Action) {
	global _LOGGER_TEST_SINK, _LOGGER_DEBUG_ENABLED, _LOGGER_ERROR_ENABLED
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT, _LastErrTime
	Old := Map()
	for Name in ["_LOGGER_TEST_SINK", "_LOGGER_DEBUG_ENABLED", "_LOGGER_ERROR_ENABLED",
		"_LOGGER_DEDUP_KEY", "_LOGGER_DEDUP_LEVEL", "_LOGGER_DEDUP_COUNT", "_LastErrTime"]
		Old[Name] := %Name%
	OldWindows := KLWV.windows
	OldSuspended := A_IsSuspended
	OldCritical := Critical("Off")
	Lines := []
	Unhandled := []
	Failure := Error("PRIVATE-SCRIPT-REJECTION-CANARY")
	ErrorHandler := _WVSO_CaptureError.Bind(Failure, Unhandled)
	View := _WVSO_View()
	OnError(ErrorHandler, -1)
	try {
		Suspend(false)
		_LOGGER_DEBUG_ENABLED := true
		_LOGGER_ERROR_ENABLED := true
		_LOGGER_DEDUP_KEY := ""
		_LOGGER_DEDUP_COUNT := 0
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Action.Call(View, Lines, Unhandled, Failure)
	} finally {
		try {
			; Release even an unsubmitted/pending test promise before restoring globals.
			if View.Pending.HasOwnProp("callbacks") {
				View.Resolve.Call("null")
				_WVSO_Drain(View)
			}
		} finally {
			OnError(ErrorHandler, 0)
			for Name, Value in Old
				%Name% := Value
			KLWV.windows := OldWindows
			Suspend(OldSuspended)
			Critical(OldCritical)
		}
	}
}
