; tests/meta/test_keylogger_webview_callback_fail_safe.ahk

; ==============================================================================
; MODULE: Keylogger WebView callback fail-safe regression test
; DESCRIPTION:
; WebMessageReceived and its deferred range callback bypass hotkey error
; boundaries. A failed prefetch read or SQLite range projection must be logged
; and dropped, never escape into the keyboard driver's global error handler.
; ==============================================================================

#Requires AutoHotkey v2.0

class _KLWVFS_FakeWebView {
	__New(ShouldThrow := false) {
		this.ShouldThrow := ShouldThrow
		this.Calls := 0
		this.LastMessage := ""
	}

	PostWebMessageAsString(Message) {
		this.Calls += 1
		this.LastMessage := Message
		if this.ShouldThrow
			throw Error("COM delivery refused")
	}
}

_KLWVFS_ThrowDiagnostic(*) {
	throw Error("central diagnostic sink refused")
}

_KLWVFS_ThrowDirCreate(*) {
	throw Error("profile directory refused")
}

global _KLWVFS_ProfileErrors := []
_KLWVFS_RecordProfileError(Args*) {
	global _KLWVFS_ProfileErrors
	_KLWVFS_ProfileErrors.Push(Args)
}

_KLWVFS_CallbacksFailSafe() {
    Push := _DriverFuncBody("KLWV_PushPrefetch")
    Range := _DriverFuncBody("KLWV_OnRangeBuildTerminal")
    First := _DriverFuncBody("KLWV_DelayedFirstPush")
    Full := _DriverFuncBody("KLWV_DelayedFullBuild")

    Assert(Push != "" && Range != "" && First != "" && Full != "",
        "keylogger WebView push/range lifecycle functions must exist")
    Assert(InStr(Push, "try body := FileRead(path, " . Chr(34) . "UTF-8" . Chr(34) . ")") > 0
            && InStr(Push, "LoggerError") > 0,
        "KLWV_PushPrefetch must catch and centrally log a prefetch FileRead failure")
    Assert(InStr(Range, "try KLWV.windows") > 0
            && InStr(Range, "catch as err") > 0
            && InStr(Range, "LoggerError") > 0,
        "KLWV_OnRangeBuildTerminal must contain and log WebView delivery failures")
    Assert(InStr(Range, "A_IsSuspended") > 0,
        "KLWV_OnRangeBuildTerminal must queue a canceled terminal when Suspend occurs after range dispatch")
    Assert(InStr(First, "A_IsSuspended") > 0 && InStr(Full, "A_IsSuspended") > 0,
        "delayed WebView builds must not run while the driver is suspended")
}

Test("keylogger WebView: deferred bridge callbacks contain I/O errors and honour Suspend",
    _KLWVFS_CallbacksFailSafe)

_KLWVFS_PushVerdictIgnoresDiagnosticFailure() {
	global KLPF_LAST_JSON
	SavedWindows := KLWV.windows
	HadCache := IsSet(KLPF_LAST_JSON)
	SavedCache := HadCache ? KLPF_LAST_JSON : 0
	Captured := []
	try {
		LoggerSetTestSink((Line) => Captured.Push(Line))
		WebView := _KLWVFS_FakeWebView()
		KLWV.windows := Map("typing", Map("webview", WebView))
		KLPF_LAST_JSON := Map("typing", '{"rows":[]}')

		AssertTrue(KLWV_PushPrefetch("typing", _KLWVFS_ThrowDiagnostic),
			"a delivered dashboard payload must stay successful when diagnostic I/O fails")
		AssertEqual(1, WebView.Calls,
			"diagnostic failure must not retry or duplicate the COM delivery")
		AssertContains(WebView.LastMessage, '"type":"prefetch"',
			"the successful call must deliver the real prefetch envelope")
		SawFailure := false
		for Line in Captured {
			if InStr(Line, "WebView diagnostic emission failed")
				SawFailure := true
		}
		AssertTrue(SawFailure,
			"a contained central diagnostic failure must remain observable")
	} finally {
		LoggerClearTestSink()
		KLWV.windows := SavedWindows
		KLPF_LAST_JSON := HadCache ? SavedCache : Map()
	}
}
Test("keylogger WebView push success contains and reports diagnostic failure "
	. "(webview-central-redacted-logging)",
	_KLWVFS_PushVerdictIgnoresDiagnosticFailure)

_KLWVFS_ComFailureRemainsContainedWhenDiagnosticFails() {
	global KLPF_LAST_JSON
	SavedWindows := KLWV.windows
	HadCache := IsSet(KLPF_LAST_JSON)
	SavedCache := HadCache ? KLPF_LAST_JSON : 0
	Captured := []
	try {
		LoggerSetTestSink((Line) => Captured.Push(Line))
		WebView := _KLWVFS_FakeWebView(true)
		KLWV.windows := Map("typing", Map("webview", WebView))
		KLPF_LAST_JSON := Map("typing", '{"rows":[]}')

		AssertFalse(KLWV_PushPrefetch("typing"),
			"a COM refusal must return false without escaping the bridge callback")
		AssertEqual(1, WebView.Calls,
			"the functional delivery boundary must be attempted exactly once")
		SawFailure := false
		for Line in Captured {
			if InStr(Line, "dashboard delivery failed")
				SawFailure := true
		}
		AssertTrue(SawFailure, "COM delivery failure must reach the central logger")
	} finally {
		LoggerClearTestSink()
		KLWV.windows := SavedWindows
		KLPF_LAST_JSON := HadCache ? SavedCache : Map()
	}
}
Test("keylogger WebView COM delivery failure is centrally logged and contained "
	. "(ahk5-02-webview-diagnostic-boundary)",
	_KLWVFS_ComFailureRemainsContainedWhenDiagnosticFails)

_KLWVFS_BridgeDiagnosticsNeverRetainPayload() {
	Canary := "SECRET-BRIDGE-CANARY-9471"
	Rows := []
	RecordFn := (Args*) => Rows.Push(Args)
	Loop 500
		_KLWV_LogBridgeReceipt("typing",
			'{"action":"unknown","text":"' . Canary . A_Index . '"}', RecordFn)
	AssertEqual(500, Rows.Length,
		"high-rate bridge diagnostics must use the bounded central logging boundary")
	for Row in Rows {
		Rendered := ""
		for Value in Row
			Rendered .= Value
		AssertFalse(InStr(Rendered, Canary),
			"diagnostics must retain payload length only, never user-derived content")
	}

	for Name in ["KLWV_Open", "KLWV_OnWebMessage", "KLWV_PushPrefetch",
		"KLWV_InjectI18n", "KLWV_RunScript", "KLWV_DelayedFirstPush",
		"KLWV_NotifyIngest"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")
		AssertFalse(InStr(Body, "FileAppend"),
			Name . " must never bypass central bounded logging with synchronous disk I/O")
		AssertFalse(InStr(Body, "webview.log"),
			Name . " must not resurrect the unbounded private log")
	}
	Bridge := _DriverFuncBody("KLWV_OnWebMessage")
	AssertFalse(InStr(Bridge, "SubStr(msg"),
		"bridge diagnostics must not retain message prefixes")
}
Test("keylogger WebView diagnostics are central, bounded, and payload-free "
	. "(webview-central-redacted-logging)",
	_KLWVFS_BridgeDiagnosticsNeverRetainPayload)

_KLWVFS_ProfileDirectoryFailureIsContained() {
	global _KLWVFS_ProfileErrors := []
	AssertFalse(_KLWV_CreateProfileDir("X:\refused", _KLWVFS_ThrowDirCreate,
		_KLWVFS_RecordProfileError),
		"a refused WebView profile directory must fail closed without escaping")
	AssertEqual(1, _KLWVFS_ProfileErrors.Length,
		"profile-directory refusal must be reported exactly once through the central logger seam")
}
Test("keylogger WebView profile-directory refusal is contained and logged "
	. "(ahk5-02-webview-diagnostic-boundary)",
	_KLWVFS_ProfileDirectoryFailureIsContained)
