; tests/fixtures/update_check_native_consent_body.ahk

; ==============================================================================
; MODULE: Update Check Native Consent Child
; DESCRIPTION:
; Real native buttons feed the real deferred dispatcher. A supported central
; logger sink publishes a successor through the public result API at the
; dispatch callout. Only download activation and presentation text are ports;
; no network, installer, UAC or physical user click is exercised.
; ==============================================================================

#Requires AutoHotkey v2.0

global _UCNC_State := {Mode: A_Args[1], Cutpoint: "", Actions: 0, Commands: 0, Clicks: 0,
	ExpectedButton: 0, Admitted: [], Windows: [], BoundaryFailure: 0, Async: 0,
	RequestA: 0, RequestB: 0, WindowA: 0, WindowB: 0, EpochA: 0, EpochB: 0, PublishedB: false, NativeClose: false}

; The production request capture and install bridge remain real. This terminal
; port records the offered release and refuses to start any download or installer.
_Updater_ActivateCachedRelease(Release, Request) {
	global _UCNC_State
	_UCNC_State.Admitted.Push({Tag: Release.Tag, Request: Request.RequestId})
	return false
}

t(Key) => Key

_UCNC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_UCNC_Error(Failure, Mode) {
	global _UCNC_State
	if !IsObject(_UCNC_State.Async)
		_UCNC_State.Async := Failure
	return true
}

_UCNC_Live(Window) {
	if !IsObject(Window)
		return false
	try return Window.Gui.Hwnd == Window.Hwnd && DllCall("User32\IsWindow", "Ptr", Window.Hwnd, "Int")
	catch
		return false
}

_UCNC_Capture() {
	global _UCNC_State, _UC_Gui, _UC_Native, _UC_ResetDone
	_UCNC_Require(_UC_Native && !_UC_ResetDone && IsSet(_UC_Gui),
		"the genuine public route must own a native current window")
	Window := {Gui: _UC_Gui, Hwnd: _UC_Gui.Hwnd}
	_UCNC_State.Windows.Push(Window)
	_UCNC_Require(_UCNC_Live(Window) && DllCall("User32\IsWindowVisible", "Ptr", Window.Hwnd, "Int"),
		"the actual native window must be visible")
	return Window
}

_UCNC_Offer(Request, Tag) {
	_UCNC_Require(UpdateChannels_ShouldOffer(Tag, "v1.0.0", Request.Channel, Request.Channel),
		"the genuine channel and version policy must admit this private offered release")
	_UCNC_Require(UpdateCheck_Begin(Request, "v1.0.0"), "the public check must begin")
	_UCNC_Capture()
	Release := {Tag: Tag, RawJson: "{}"}
	_UCNC_Require(UpdateCheck_ShowResult(Request, Map("state", "available", "current", "v1.0.0",
		"latest", Tag, "others", [], "release", Release)), "the public check must publish its exact offered release")
	return _UCNC_Capture()
}

_UCNC_Command(WParam, LParam, Message, Hwnd) {
	global _UCNC_State
	if LParam == _UCNC_State.ExpectedButton && ((WParam >> 16) & 0xFFFF) == 0
		_UCNC_State.Commands += 1
}

_UCNC_Log(Line) {
	global _UCNC_State, _UC_RequestId, _UC_WindowEpoch
	if !InStr(Line, "[INFO] [UpdateCheck] Update-check window action: update.")
		return
	_UCNC_State.Actions += 1
	Cutpoint := _UCNC_State.Cutpoint
	_UCNC_State.Cutpoint := ""
	try {
		if Cutpoint == "close" {
			DllCall("User32\SendMessageW", "Ptr", _UCNC_State.WindowA.Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Ptr")
			Started := A_TickCount
			while _UCNC_Live(_UCNC_State.WindowA) && TickElapsed(Started) < 1000
				Sleep(10)
			_UCNC_Require(!_UCNC_Live(_UCNC_State.WindowA), "the actual WM_CLOSE callback must retire the clicked window")
			_UCNC_State.NativeClose := true
		} else if Cutpoint == "replace" {
			_UCNC_Require(_UC_RequestId == _UCNC_State.RequestA.RequestId,
				"the native timer must reach its callout while the old request still owns the window")
			_UCNC_State.WindowB := _UCNC_Offer(_UCNC_State.RequestB, "v1.2.0")
			_UCNC_State.EpochB := _UC_WindowEpoch
			_UCNC_State.PublishedB := true
		}
	} catch Any as Failure {
		if !IsObject(_UCNC_State.BoundaryFailure)
			_UCNC_State.BoundaryFailure := Failure
	}
}

_UCNC_Click(Window) {
	global _UCNC_State
	_UCNC_Require(_UCNC_Live(Window), "the actual clicked window must remain live")
	Matches := []
	for Hwnd in WinGetControlsHwnd("ahk_id " . Window.Hwnd) {
		if WinGetClass("ahk_id " . Hwnd) == "Button" && ControlGetText(Hwnd) == t("update_check.update")
			Matches.Push(Hwnd)
	}
	_UCNC_Require(Matches.Length == 1, "the real offered-release Update button must be unique")
	_UCNC_State.ExpectedButton := Matches[1]
	_UCNC_State.Clicks += 1
	; A distinct ordinary log line prevents suppression of the second action's
	; identical diagnostic line, without changing the logger's real dedup state.
	LoggerInfo("UpdateCheckFixture", "Native activation {1}.", _UCNC_State.Clicks)
	Before := _UCNC_State.Actions, CommandBefore := _UCNC_State.Commands
	DllCall("User32\SendMessageW", "Ptr", Matches[1], "UInt", 0xF5, "Ptr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while _UCNC_State.Actions == Before && TickElapsed(Started) < 1000
		Sleep(10)
	if IsObject(_UCNC_State.BoundaryFailure)
		throw _UCNC_State.BoundaryFailure
	if IsObject(_UCNC_State.Async)
		throw _UCNC_State.Async
	_UCNC_Require(_UCNC_State.Commands == CommandBefore + 1 && _UCNC_State.Actions == Before + 1,
		"the real BN_CLICKED and SUT timer dispatch must both be observed exactly once")
}

_UCNC_Run() {
	global _UCNC_State, _UC_WindowEpoch, _UC_RequestId, _UC_ResetDone, UPDATER_REQUEST_ORIGIN_MANUAL
	_UCNC_State.RequestA := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	_UCNC_State.RequestB := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	_UCNC_Require(_UCNC_State.RequestA.RequestId != _UCNC_State.RequestB.RequestId,
		"the genuine request factory must supply distinct private identities")
	_UCNC_State.WindowA := _UCNC_Offer(_UCNC_State.RequestA, "v1.1.0")
	_UCNC_State.EpochA := _UC_WindowEpoch
	if _UCNC_State.Mode == "replaced" {
		_UCNC_State.Cutpoint := "replace"
		_UCNC_Click(_UCNC_State.WindowA)
		_UCNC_Require(_UCNC_State.PublishedB && _UC_RequestId == _UCNC_State.RequestB.RequestId
			&& _UCNC_Live(_UCNC_State.WindowB) && !_UCNC_Live(_UCNC_State.WindowA),
			"the real public result must replace the old native window before the old action continues")
		_UCNC_Require(_UCNC_State.Admitted.Length <= 1, "the old native action may be consumed at most once")
		for Admission in _UCNC_State.Admitted
			_UCNC_Require(Admission.Tag == "v1.1.0",
				"an old native click must never become consent to install the successor's release")
	} else if _UCNC_State.Mode == "successor-current" {
		_UCNC_State.WindowB := _UCNC_Offer(_UCNC_State.RequestB, "v1.2.0")
		_UCNC_State.EpochB := _UC_WindowEpoch
		_UCNC_Require(!_UCNC_Live(_UCNC_State.WindowA), "the earlier native window must be retired")
		_UCNC_Click(_UCNC_State.WindowB)
		_UCNC_Require(_UCNC_State.Admitted.Length == 1 && _UCNC_State.Admitted[1].Tag == "v1.2.0",
			"a freshly clicked successor button must still admit its own offered release")
	} else {
		_UCNC_Click(_UCNC_State.WindowA)
		_UCNC_Require(_UCNC_State.Admitted.Length == 1 && _UCNC_State.Admitted[1].Tag == "v1.1.0",
			"the current actual native button must admit exactly its offered release")
		_UCNC_State.Cutpoint := "close"
		_UCNC_Click(_UCNC_State.WindowA)
		_UCNC_Require(_UC_ResetDone && !_UCNC_Live(_UCNC_State.WindowA) && _UCNC_State.Admitted.Length == 1,
			"closing during dispatch must revoke the second native action before activation")
	}
}

_UCNC_Main() {
	global _UCNC_State
	Primary := 0, ExportFailure := 0
	_UCNC_Require(_UCNC_State.Mode == "replaced" || _UCNC_State.Mode == "current-close"
		|| _UCNC_State.Mode == "successor-current", "the native consent mode must be known")
	PreviousCritical := Critical("Off")
	; This private child permits eligible native GUI callbacks during timer callouts.
	Thread("Interrupt", 0)
	OnError(_UCNC_Error)
	OnMessage(0x111, _UCNC_Command)
	LoggerSetTestSink(_UCNC_Log)
	try _UCNC_Run()
	catch Any as Failure
		Primary := Failure
	finally {
		LoggerClearTestSink()
		OnMessage(0x111, _UCNC_Command, 0)
		try _UpdateCheck_CloseWindow()
		catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		for Window in _UCNC_State.Windows {
			try {
				if _UCNC_Live(Window)
					Window.Gui.Destroy()
				_UCNC_Require(!_UCNC_Live(Window), "every captured private GUI must retire")
			} catch Any as Failure {
				if !IsObject(Primary)
					Primary := Failure
			}
		}
		OnError(_UCNC_Error, 0)
		Critical(PreviousCritical)
	}
	if !IsObject(Primary) && IsObject(_UCNC_State.Async)
		Primary := _UCNC_State.Async
	Tags := ""
	for Admission in _UCNC_State.Admitted
		Tags .= (Tags == "" ? "" : ",") . Admission.Tag
	try FileAppend("RECEIPT update-check-native-consent mode=" . _UCNC_State.Mode
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " click=" . _UCNC_State.Clicks
		. " bn_clicked=" . _UCNC_State.Commands . " timer_dispatch=" . _UCNC_State.Actions
		. " requestA=" . (IsObject(_UCNC_State.RequestA) ? _UCNC_State.RequestA.RequestId : 0)
		. " requestB=" . (IsObject(_UCNC_State.RequestB) ? _UCNC_State.RequestB.RequestId : 0)
		. " epochA=" . _UCNC_State.EpochA . " epochB=" . _UCNC_State.EpochB
		. " publishedB=" . _UCNC_State.PublishedB . " native_close=" . _UCNC_State.NativeClose . " admitted_tags=" . Tags . "`n", "*", "UTF-8")
	catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	if IsObject(ExportFailure)
		throw ExportFailure
	FileAppend("PASS update-check-native-consent " . _UCNC_State.Mode . "`n", "*", "UTF-8")
}

try {
	_UCNC_Main()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL update-check-native-consent " . Failure.Message . " file=" . Failure.File
		. " line=" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
