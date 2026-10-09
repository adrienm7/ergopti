; tests/meta/test_is_category_all_enabled_loop.ahk

; ==============================================================================
; MODULE: IsCategoryAllEnabled Full-Loop Guard
; DESCRIPTION:
; Static source guard for the IsCategoryAllEnabled loop fix in ErgoptiPlus.ahk.
;
; ROOT CAUSE ENCODED:
; The original implementation only checked Categories[1], so when multiple
; categories were in the array, all subsequent categories were silently ignored.
; A group with categories ["A", "B"] would return true even when "B" was disabled,
; enabling hotstrings that should have been blocked.
;
; The fix iterates over ALL categories with "for Cat in Categories" and returns
; false as soon as any category is not gated (not enabled). This test checks that
; the source contains "for Cat in Categories" rather than indexing with [1].
; ==============================================================================

#Requires AutoHotkey v2.0

_TICALE_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

_TICALE_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; =================================================================
; =================================================================
; ======= 1/ IsCategoryAllEnabled iterates all categories ==========
; =================================================================
; =================================================================

_TICALE_LoopsAllCategories() {
	Src := _TICALE_StripLineComments(_DriverSourceConcat())
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	Body := _DriverFuncBody("IsCategoryAllEnabled")
	Assert(Body != "", "IsCategoryAllEnabled must be defined in ErgoptiPlus.ahk")

	; Must iterate ALL categories, not just index [1]
	Assert(InStr(Body, "for Cat in Categories") > 0,
		"IsCategoryAllEnabled must use 'for Cat in Categories' to loop over all categories, not index [1]")

	; Must NOT check only the first element
	Assert(InStr(Body, "Categories[1]") = 0,
		"IsCategoryAllEnabled must NOT access Categories[1] — it must loop over all entries")
}
Test("ErgoptiPlus: IsCategoryAllEnabled loops over all categories (not just [1])", _TICALE_LoopsAllCategories)
