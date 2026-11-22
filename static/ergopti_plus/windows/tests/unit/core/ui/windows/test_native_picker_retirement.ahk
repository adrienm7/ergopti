; tests/unit/core/ui/windows/test_native_picker_retirement.ahk

; ==============================================================================
; MODULE: Native Slot Picker Retirement Regression
; DESCRIPTION:
; Exercises the keyboard-slot picker, a native ListBox by design, through its
; native Close/Escape/button routes. Repeated cancellation must destroy owned
; HWNDs and controls, rather than leave inaccessible hidden pickers retaining
; their callback graphs. The action picker has no native form any more: without
; WebView2 it builds no window and shows the shared refusal (decision 2026-11-21).
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../../ui/action_picker/init.ahk

_NPR_Windows(Title, Pid) {
	Matches := []
	for Hwnd in WinGetList("ahk_pid " . Pid) {
		if WinGetClass("ahk_id " . Hwnd) == "AutoHotkeyGUI"
				&& WinGetTitle("ahk_id " . Hwnd) == Title
			Matches.Push(Hwnd)
	}
	return Matches
}

_NPR_Post(Hwnd, Mode) {
	if Mode == "close"
		Accepted := DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x10, "Ptr", 0, "Ptr", 0, "Int")
	else if Mode == "escape" {
		; The pinned Gui dispatcher maps native IDCANCEL without a control to
		; the real Escape event, including while another modal owns translation.
		Accepted := DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x111, "Ptr", 2, "Ptr", 0, "Int")
	} else {
		Button := ControlGetHwnd("Button2", "ahk_id " . Hwnd)
		AssertTrue(DllCall("IsChild", "Ptr", Hwnd, "Ptr", Button), "the actual picker must own its native button")
		AssertEqual(t("button.cancel"), ControlGetText(Button),
			"the native command must target the constructor's real requested button")
		Id := DllCall("GetDlgCtrlID", "Ptr", Button, "Int")
		AssertTrue(Id > 0)
		Accepted := DllCall("PostMessageW", "Ptr", Hwnd, "UInt", 0x111, "Ptr", Id, "Ptr", Button, "Int")
	}
	AssertTrue(Accepted, "the exact owned HWND must receive its native retirement command")
}

_NPR_DefaultCloseStillHides(Title) {
	Control := Gui("+ToolWindow", Title . " default control")
	try {
		Control.Show("w120 h80")
		Hwnd := Control.Hwnd
		AssertTrue(DllCall("IsWindowVisible", "Ptr", Hwnd))
		_NPR_Post(Hwnd, "close")
		Started := A_TickCount
		while DllCall("IsWindowVisible", "Ptr", Hwnd) && TickElapsed(Started) < 5000
			Sleep(10)
		AssertFalse(DllCall("IsWindowVisible", "Ptr", Hwnd), "the independent default GUI must process its native Close")
		AssertTrue(DllCall("IsWindow", "Ptr", Hwnd),
			"the real default Close hides rather than destroys; the picker must own a stronger retirement route")
	} finally Control.Destroy()
}

_NPR_Run(Mode) {
	global DriverPid, GESTURE_ACTIONS, _VendorDir, _ActPickWeb_SessionEpoch
	AssertTrue(DriverPid is Integer && DriverPid > 0, "the native fixture uses the driver's sole process identity")
	SavedHidden := A_DetectHiddenWindows
	SavedCritical := A_IsCritical
	SavedSuspend := A_IsSuspended
	HadActions := IsSet(GESTURE_ACTIONS)
	SavedActions := HadActions ? GESTURE_ACTIONS : 0
	SavedVendor := _VendorDir
	SavedWebEpoch := _ActPickWeb_SessionEpoch
	OwnedWindows := []
	CleanupErrors := []
	Prefix := "native_picker_" . DriverPid . "_" . A_TickCount . "_"
	; The slot picker names a real group's modifiers (« Ctrl + … »), never its
	; prefix, so it opens on a declared group; the driver PID keeps it unique.
	SlotPrefix := "primary_"
	Title := WindowTitle(t("dialog.keyboard_shortcut.title_prefix") . _KeyboardSlotFamilyLabel(SlotPrefix) . " + …")
	try {
		Critical("Off")
		Suspend(false)
		DetectHiddenWindows(true)
		_VendorDir := A_Temp . "\ergopti_picker_missing_loader_" . Prefix
		AssertFalse(FileExist(_VendorDir), "the actual loader must be genuinely unavailable")
		AssertTrue(WebView_UnavailableReason() != "", "WebView2 must be genuinely unavailable")
		GESTURE_ACTIONS := Map(Prefix . "a", (*) => 0)
		if Mode == "close"
			_NPR_DefaultCloseStillHides(Title)
		loop 3 {
			AssertEqual(0, _NPR_Windows(Title, DriverPid).Length, "an older hidden picker must not survive a new opening")
			ShowKeyboardSlotPicker(SlotPrefix)
			Windows := _NPR_Windows(Title, DriverPid)
			AssertEqual(1, Windows.Length, "the actual constructor must publish exactly one real native picker")
			Hwnd := Windows[1]
			OwnedWindows.Push(Hwnd)
			AssertTrue(DllCall("IsWindowVisible", "Ptr", Hwnd))
			List := ControlGetHwnd("ListBox1", "ahk_id " . Hwnd)
			Rows := DllCall("SendMessageW", "Ptr", List, "UInt", 0x18B, "Ptr", 0, "Ptr", 0, "Int")
			AssertTrue(Rows == KeyboardSlotDeclaration()["keys"].Length,
				"the real constructor must populate its native selection control before retirement")
			_NPR_Post(Hwnd, Mode)
			Started := A_TickCount
			while DllCall("IsWindow", "Ptr", Hwnd) && TickElapsed(Started) < 5000
				Sleep(10)
			AssertFalse(DllCall("IsWindow", "Ptr", Hwnd), "retirement must destroy the picker, not just hide it")
			AssertFalse(DllCall("IsWindow", "Ptr", List), "the exact native selection control must retire too")
		}
		AssertEqual(0, _NPR_Windows(Title, DriverPid).Length, "three reopen/retire cycles leave no hidden owned GUI")
		AssertEqual(SavedWebEpoch, _ActPickWeb_SessionEpoch, "the native slot picker must not mutate a WebView session")
	} finally {
		try {
			for Hwnd in OwnedWindows {
				try {
					if DllCall("IsWindow", "Ptr", Hwnd)
						GuiFromHwnd(Hwnd).Destroy()
				} catch as Err
					CleanupErrors.Push(Err.Message)
			}
		} finally {
			_VendorDir := SavedVendor
			GESTURE_ACTIONS := HadActions ? SavedActions : unset
			DetectHiddenWindows(SavedHidden)
			Suspend(SavedSuspend)
			Critical(SavedCritical)
		}
	}
	AssertEqual(0, CleanupErrors.Length, "cleanup must not conceal a native owned-window failure")
}

for _NPR_Mode in ["close", "escape", "cancel"]
	Test("native picker retirement: slots " . _NPR_Mode . " destroys all repeated windows (native-picker-retirement)",
		_NPR_Run.Bind(_NPR_Mode))

; Every top-level window this process owns, hidden ones included.
_NPR_OwnWindows() {
	global DriverPid
	PreviousDetect := DetectHiddenWindows(true)
	try return WinGetList("ahk_class AutoHotkeyGUI ahk_pid " . DriverPid)
	finally DetectHiddenWindows(PreviousDetect)
}

; Without WebView2 the action picker and the folders editor refuse in words and
; build nothing; they used to open a native ListBox or single-field dialog.
_NPR_WebViewOnlyRefuses(Surface, OpenFn) {
	global _VendorDir, _LOGGER_TEST_SINK, _ActPickWeb_SessionEpoch
	SavedVendor := _VendorDir, PreviousSink := _LOGGER_TEST_SINK
	SavedWebEpoch := _ActPickWeb_SessionEpoch
	Shown := [], Logs := [], Before := Map()
	for Hwnd in _NPR_OwnWindows()
		Before[Hwnd] := true
	try {
		_VendorDir := A_Temp . "\ergopti_picker_missing_loader_" . A_ScriptHwnd . "_" . A_TickCount
		AssertFalse(FileExist(_VendorDir), "the actual loader must be genuinely unavailable")
		TestMsgBoxResponder((Text, Title, Options) => (Shown.Push(Text), ""))
		_LoggerFlushRepeats(true)
		LoggerSetTestSink((Line) => Logs.Push(Line))
		Result := OpenFn.Call()
		_LoggerFlushRepeats(true)
	} finally {
		LoggerSetTestSink(PreviousSink)
		TestMsgBoxResponder("")
		_VendorDir := SavedVendor
	}
	AssertFalse(Result, "a refused opening reports that nothing opened")
	Created := 0
	for Hwnd in _NPR_OwnWindows()
		if !Before.Has(Hwnd)
			Created += 1
	AssertEqual(0, Created, "no native picker or host window may remain after the refusal")
	AssertEqual(SavedWebEpoch, _ActPickWeb_SessionEpoch, "a refusal opens no WebView session")
	AssertEqual(1, Shown.Length, "the user is told exactly once")
	AssertEqual(t("webview.required"), Shown[1], "the message is the shared WebView2-required text")
	Errors := 0
	for Line in Logs
		if InStr(Line, "[ERROR]") && InStr(Line, "The " . Surface . " cannot open: WebView2 is required")
			Errors += 1
	AssertEqual(1, Errors, "the refusal is logged once at ERROR")
}
Test("Action picker: an absent WebView2 shows the required message and builds no native ListBox (action-picker-webview-only)",
	_NPR_WebViewOnlyRefuses.Bind("action picker", () => ShowActionPicker("Private refused picker", "none", (*) => 0)))
Test("Folders editor: an absent WebView2 shows the required message and builds no native dialog (action-picker-webview-only)",
	_NPR_WebViewOnlyRefuses.Bind("paths editor", () => FilePathsEditor()))
