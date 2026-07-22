; tests/meta/test_searchpath_regjump_catch.ahk

; ==============================================================================
; MODULE: SearchPath RegJump Try/Catch Meta Test
; DESCRIPTION:
; Regression guard: SearchPath's RegeditPath branch called RegJump(SelectedText)
; with no try/catch, unlike every sibling Run() branch in the same function
; (FilePath, URLPath, WebsitePath, empty-search, and the generic web-search
; fallback all wrap their call). RegJump calls WMKill, Reg_WriteString, and
; Run("Regedit.exe") -- any of which can throw -- and an uncaught exception
; there escalates to the crash-report error net instead of degrading the
; same way every other branch does.
;
; SCOPE: source introspection of modules/shortcuts/win.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ RegeditPath branch has a catch ===========
; =====================================================
; =====================================================

_SPRJC_CheckRegJumpHasCatch() {
	Body := _DriverFuncBody("SearchPath")
	Assert(Body != "", "SearchPath must exist in modules/shortcuts/win.ahk")

	CallPos := InStr(Body, "RegJump(SelectedText)")
	Assert(CallPos > 0, "SearchPath must still call RegJump(SelectedText) on the RegeditPath branch")

	; The nearest preceding "try" (within a short lookback window) must be
	; the one guarding this specific call, and a "catch" must follow it.
	LookBack := SubStr(Body, Max(1, CallPos - 40), CallPos - Max(1, CallPos - 40))
	Assert(InStr(LookBack, "try") > 0,
		"SearchPath's RegeditPath branch must wrap RegJump(SelectedText) in a try, matching every sibling Run() branch in the same function")

	LookAhead := SubStr(Body, CallPos, 150)
	Assert(InStr(LookAhead, "catch") > 0,
		"SearchPath's RegeditPath branch must have a catch clause after RegJump(SelectedText), matching every sibling Run() branch")
}
Test("shortcuts: SearchPath's RegeditPath branch wraps RegJump in try/catch (searchpath-regjump-uncaught)",
	_SPRJC_CheckRegJumpHasCatch)
