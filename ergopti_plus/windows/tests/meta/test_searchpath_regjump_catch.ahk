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

_SPRJC_RegJumpUsesReceiptCheckedCommit() {
	Body := _DriverFuncBody("RegJump")
	Assert(Body != "", "RegJump must exist in the Windows shortcuts module")
	Assert(InStr(Body, "_RegJumpCommit(") > 0,
		"RegJump must delegate its desktop effects to the receipt-checked commit boundary")

	CommitBody := _DriverFuncBody("_RegJumpCommit")
	Assert(CommitBody != "", "the RegJump commit boundary must be defined")
	Assert(InStr(CommitBody, "if !WriteFn.Call(") > 0,
		"a refused LastKey registry write must abort the jump")
	Assert(InStr(CommitBody, "if ExistsFn.Call(") > 0
		&& InStr(CommitBody, "!KillFn.Call(") > 0,
		"a refused close of an existing Regedit window must abort the jump")
}
Test("shortcuts: RegJump fails closed on refused effects (regjump-receipt-fail-closed)",
	_SPRJC_RegJumpUsesReceiptCheckedCommit)
