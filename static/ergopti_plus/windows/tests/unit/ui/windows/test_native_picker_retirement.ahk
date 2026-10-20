; tests/unit/ui/windows/test_native_picker_retirement.ahk

; ==============================================================================
; MODULE: Native Action Picker Retirement Regression
; DESCRIPTION:
; Exercises the real fallback constructors and native Close/Escape/button routes.
; Repeated cancellation must destroy owned HWNDs and controls, rather than leave
; inaccessible hidden pickers retaining their callback graphs. No key is sent and
; no shortcut assignment or configuration writer runs.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../../../ui/action_picker/init.ahk

_NPR_Picked(State, Id) {
	State.Picks.Push(Id)
}

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
		Button := ControlGetHwnd(Mode == "accept" ? "Button1" : "Button2", "ahk_id " . Hwnd)
		AssertTrue(DllCall("IsChild", "Ptr", Hwnd, "Ptr", Button), "the actual picker must own its native button")
		AssertEqual(t(Mode == "accept" ? "button.ok" : "button.cancel"), ControlGetText(Button),
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

_NPR_Run(Kind, Mode) {
	global DriverPid, GESTURE_ACTIONS, _VendorDir, _ActPickWeb_SessionEpoch
	AssertTrue(DriverPid is Integer && DriverPid > 0, "the native fixture uses the driver's sole process identity")
	SavedHidden := A_DetectHiddenWindows
	SavedCritical := A_IsCritical
	SavedSuspend := A_IsSuspended
	HadActions := IsSet(GESTURE_ACTIONS)
	SavedActions := HadActions ? GESTURE_ACTIONS : 0
	SavedVendor := _VendorDir
	SavedWebEpoch := _ActPickWeb_SessionEpoch
	State := { Picks: [] }
	OwnedWindows := []
	CleanupErrors := []
	Prefix := "native_picker_" . DriverPid . "_" . A_TickCount . "_"
	Title := WindowTitle(Kind == "slots" ? t("dialog.keyboard_shortcut.title_prefix") . Prefix : Prefix)
	try {
		Critical("Off")
		Suspend(false)
		DetectHiddenWindows(true)
		_VendorDir := A_Temp . "\ergopti_picker_missing_loader_" . Prefix
		AssertFalse(FileExist(_VendorDir), "the actual loader must be genuinely unavailable for the native fallback")
		AssertFalse(_ActPickWeb_Available())
		GESTURE_ACTIONS := Map(Prefix . "a", (*) => 0)
		if Mode == "close"
			_NPR_DefaultCloseStillHides(Title)
		loop 3 {
			AssertEqual(0, _NPR_Windows(Title, DriverPid).Length, "an older hidden picker must not survive a new opening")
			if Kind == "slots"
				ShowKeyboardSlotPicker(Prefix)
			else
				ShowActionPicker(Prefix, "none", _NPR_Picked.Bind(State))
			Windows := _NPR_Windows(Title, DriverPid)
			AssertEqual(1, Windows.Length, "the actual constructor must publish exactly one real native picker")
			Hwnd := Windows[1]
			OwnedWindows.Push(Hwnd)
			AssertTrue(DllCall("IsWindowVisible", "Ptr", Hwnd))
			List := ControlGetHwnd("ListBox1", "ahk_id " . Hwnd)
			Rows := DllCall("SendMessageW", "Ptr", List, "UInt", 0x18B, "Ptr", 0, "Ptr", 0, "Int")
			AssertTrue(Kind == "slots" ? Rows == 1 : Rows > 1,
				"the real constructor must populate its native selection control before retirement")
			_NPR_Post(Hwnd, Mode)
			Started := A_TickCount
			while DllCall("IsWindow", "Ptr", Hwnd) && TickElapsed(Started) < 5000
				Sleep(10)
			AssertFalse(DllCall("IsWindow", "Ptr", Hwnd), "retirement must destroy the picker, not just hide it")
			AssertFalse(DllCall("IsWindow", "Ptr", List), "the exact native selection control must retire too")
			AssertEqual(Mode == "accept" ? A_Index : 0, State.Picks.Length,
				"cancellation must never invoke assignment; accepted action picks keep the callback API")
		}
		AssertEqual(0, _NPR_Windows(Title, DriverPid).Length, "three reopen/retire cycles leave no hidden owned GUI")
		AssertEqual(SavedWebEpoch, _ActPickWeb_SessionEpoch, "the actual missing-loader fallback must not mutate a WebView session")
		for Pick in State.Picks
			AssertEqual("none", Pick, "ordinary accepted picks preserve their exact public action identifier")
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

for _NPR_Kind in ["actions", "slots"]
	for _NPR_Mode in ["close", "escape", "cancel"]
		Test("native picker retirement: " . _NPR_Kind . " " . _NPR_Mode . " destroys all repeated windows (native-picker-retirement)",
			_NPR_Run.Bind(_NPR_Kind, _NPR_Mode))
Test("native picker retirement: accepted action keeps its callback (native-picker-retirement)",
	_NPR_Run.Bind("actions", "accept"))
