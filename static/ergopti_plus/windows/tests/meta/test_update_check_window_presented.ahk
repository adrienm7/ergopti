; tests/meta/test_update_check_window_presented.ahk

; ==============================================================================
; MODULE: Update-Check Window Is Presented, Never Topmost
; DESCRIPTION:
; The update-check window (C4) was built with +AlwaysOnTop, and Gui_Create now
; refuses that option (ui-focus-not-topmost): every open, the native fallback
; included, would have thrown. As an ordinary window it can be covered, so a new
; manual check must present the open window again through the shared helper,
; while a check's answer only updates it where it is.
;
; SCOPE: source introspection. The window hosts WebView2 or a native Gui and the
; helper focuses a real window, which the headless runner may not do; the helper
; itself is exercised in tests/unit/test_window_manager_present_window.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaUpdateCheckWindowPresented() {
	Window := _DriverFuncBody("_UpdateCheck_NewWindow")
	Assert(Window != "", "_UpdateCheck_NewWindow must exist in ui/update_check/init.ahk")
	Assert(InStr(Window, "Gui_Create(") > 0 && InStr(Window, "AlwaysOnTop") == 0,
		"the update-check window is an ordinary window built by the factory")

	Present := _DriverFuncBody("_UpdateCheck_Present")
	Assert(Present != "", "_UpdateCheck_Present must exist in ui/update_check/init.ahk")
	OpenPos := InStr(Present, "if !_UC_ResetDone {")
	ReopenPos := InStr(Present, "if Reopen", , Max(OpenPos, 1))
	HelperPos := InStr(Present, "WMPresentWindow(_UC_Gui)", , Max(ReopenPos, 1))
	Assert(OpenPos > 0 && ReopenPos > OpenPos && HelperPos > ReopenPos,
		"an open window is presented again only when a new check re-opens it")

	Begin := _DriverFuncBody("UpdateCheck_Begin")
	Assert(Begin != "", "UpdateCheck_Begin must exist in ui/update_check/init.ahk")
	Assert(RegExMatch(Begin, "_UpdateCheck_Present\([\s\S]*,\s*true\)") > 0,
		"a manual check re-opens the window")
	Result := _DriverFuncBody("UpdateCheck_ShowResult")
	Assert(Result != "", "UpdateCheck_ShowResult must exist in ui/update_check/init.ahk")
	Assert(InStr(Result, "_UpdateCheck_Present(State)") > 0,
		"an answer updates the window where it is, without taking the focus")
}
Test("update check: the window is presented, never topmost (ui-focus-not-topmost)",
	_MetaUpdateCheckWindowPresented)
