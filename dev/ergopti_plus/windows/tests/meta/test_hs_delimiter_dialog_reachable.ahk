; tests/meta/test_hs_delimiter_dialog_reachable.ahk

; ==============================================================================
; MODULE: Add-Delimiter Dialog Stays Reachable
; DESCRIPTION:
; The add-delimiter dialog blocks its menu thread in WinWaitClose. It was an
; owned AlwaysOnTop window: once it stopped being topmost, another app could
; cover it, and an owned window has no taskbar button and no Alt+Tab entry, so
; the dialog could not be reached again and a second request stacked a new one
; over it. The dialog must be an unowned window and a request while it is open
; must present it again (ui-focus-not-topmost).
;
; SCOPE: source introspection. The dialog blocks in WinWaitClose and presenting
; focuses a real window, neither of which the headless runner may do.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaHsDelimiterDialogReachable() {
	Body := _DriverFuncBody("_HS_DelimAddCustom")
	Assert(Body != "", "_HS_DelimAddCustom must exist in ui/menu/menu_hotstrings.ahk")

	Assert(!InStr(Body, "+Owner"),
		"the dialog must be unowned: an owned window has no taskbar button once another app covers it")
	Assert(!InStr(Body, "AlwaysOnTop"), "the dialog must never be kept on top")

	OpenPos := InStr(Body, "if IsObject(_HS_DelimAddGui) {")
	PresentPos := InStr(Body, "WMPresentWindow(_HS_DelimAddGui)", , Max(OpenPos, 1))
	BuildPos := InStr(Body, "Gui_Create(")
	Assert(OpenPos > 0 && PresentPos > OpenPos && BuildPos > PresentPos,
		"a request while the dialog is open must present it instead of building a second one")

	PublishPos := InStr(Body, "_HS_DelimAddGui := G")
	WaitPos := InStr(Body, "WinWaitClose(")
	ClearPos := InStr(Body, '_HS_DelimAddGui := ""', , Max(WaitPos, 1))
	Assert(PublishPos > 0 && WaitPos > PublishPos && ClearPos > WaitPos,
		"the open dialog must be published before the wait and withdrawn after it")
}
Test("hotstrings: the add-delimiter dialog stays reachable and is presented again (ui-focus-not-topmost)",
	_MetaHsDelimiterDialogReachable)
