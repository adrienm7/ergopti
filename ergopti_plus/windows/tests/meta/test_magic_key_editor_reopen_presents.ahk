; tests/meta/test_magic_key_editor_reopen_presents.ahk

; ==============================================================================
; MODULE: Magic Key Editor Re-Open Presents The Live Editor
; DESCRIPTION:
; The magic key editor waits on a suppressive InputHook: the next key typed
; anywhere becomes the magic key. While it was AlwaysOnTop it could not be
; lost; now that it is an ordinary window, the user can cover it, and asking
; for it again used to return silently while its hook stayed live, so the next
; keystroke in another app was swallowed as the new magic key. A re-open must
; present the live editor through the shared helper (ui-focus-not-topmost).
;
; SCOPE: source introspection. The editor blocks in InputHook.Wait and the
; helper focuses a real window, neither of which the headless runner may do;
; the helper itself is exercised in tests/unit/test_window_manager_present_window.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaMagicKeyEditorReopenPresents() {
	Body := _DriverFuncBody("MagicKeyEditor")
	Assert(Body != "", "MagicKeyEditor must exist in ui/editors.ahk")

	LivePos := InStr(Body, "if !_MagicKeyEditorStopDebt {")
	PresentPos := InStr(Body, "WMPresentWindow(_MagicKeyEditorGui)", , Max(LivePos, 1))
	ReturnPos := InStr(Body, "return", , Max(PresentPos, 1))
	RetryPos := InStr(Body, "_MagicKeyEditorStopOwned(_MagicKeyEditorInputHook)")
	Assert(LivePos > 0 && PresentPos > LivePos && ReturnPos > PresentPos && RetryPos > ReturnPos,
		"a re-open while the capture is live must present the editor before returning, ahead of the stop-debt retry")

	HookPos := InStr(Body, "_MagicKeyEditorInputHook := IH")
	GuiPos := InStr(Body, "_MagicKeyEditorGui := GuiToShow")
	StartPos := InStr(Body, "IH.Start()")
	Assert(HookPos > 0 && GuiPos > HookPos && StartPos > GuiPos,
		"the editor window must be published with its hook, before the capture starts")

	ClearPos := InStr(Body, '_MagicKeyEditorGui := ""')
	DestroyPos := InStr(Body, "GuiToShow.Destroy()")
	Assert(ClearPos > 0 && DestroyPos > ClearPos,
		"the published window must be withdrawn before the editor is destroyed")
}
Test("magic key editor: a re-open presents the live editor (ui-focus-not-topmost)",
	_MetaMagicKeyEditorReopenPresents)
