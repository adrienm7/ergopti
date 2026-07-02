; tests/meta/test_changelog_close_order.ahk

; ==============================================================================
; MODULE: Changelog Close-Order Meta Test
; DESCRIPTION:
; Regression guard for finding F30: both _CLW_OnClose and Changelog_Close()
; used to call Gui.Destroy() BEFORE _CLW_Reset() (which closes the WebView2
; Controller) -- the reverse of the correctly-implemented order in the
; sibling ui/model_browser/init.ahk. The WebView2 spec requires the
; Controller to be closed before its host HWND is destroyed.
;
; SCOPE: source introspection of ui/changelog/init.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ Controller close precedes Gui destroy in both paths ====
; ==================================================================
; ==================================================================

_CLCO_CheckOrder(FnName) {
	Body := _DriverFuncBody(FnName)
	Assert(Body != "", FnName . " must exist in ui/changelog/init.ahk")

	ResetPos := InStr(Body, "_CLW_Reset()")
	Assert(ResetPos > 0, FnName . " must call _CLW_Reset() to close the WebView2 controller")

	DestroyPos := InStr(Body, ".Destroy()")
	Assert(DestroyPos > 0, FnName . " must still destroy the Gui")

	Assert(ResetPos < DestroyPos,
		FnName . " must close the WebView2 Controller (_CLW_Reset()) BEFORE destroying the Gui -- the WebView2 spec requires Controller.Close() before its host HWND is destroyed, matching the sibling ui/model_browser/init.ahk implementation (changelog-close-order)")
}

Test("changelog: _CLW_OnClose closes the Controller before destroying the Gui (changelog-close-order)",
	() => _CLCO_CheckOrder("_CLW_OnClose"))
Test("changelog: Changelog_Close closes the Controller before destroying the Gui (changelog-close-order)",
	() => _CLCO_CheckOrder("Changelog_Close"))
