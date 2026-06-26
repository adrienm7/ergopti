; tests/meta/test_generated_substr_minus_one.ahk

; ==============================================================================
; MODULE: Hotstring Engine SubStr(-1) Guard
; DESCRIPTION:
; Static source guard for the SubStr(-0) tail-char bug in the live custom
; hotstring engine (lib/hotstrings/hotstring_engine_main.ahk).
;
; ROOT CAUSE ENCODED:
; SubStr(s, -0) is equivalent to SubStr(s, 0), which in AHK v2 returns the full
; string because negative-zero is treated as zero (an out-of-range start), rather
; than extracting the last character. The engine extracts the trigger and star
; base tail char with SubStr(..., -1); this test fails if either is reverted to -0.
;
; NOTE: this guard formerly read _generated/{registry,expander}.ahk — orphaned
; codegen classes the production engine never used, deleted in audit GEN-1/2. The
; SubStr(-0) class of bug lives in the real HSE_* engine, so the guard now pins
; the live code it actually protects.
; ==============================================================================

#Requires AutoHotkey v2.0

_TGS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}

; Strips full-line comment lines so assertions never match an explanatory remark.
_TGS_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =============================================================
; =========================================================
; ======= 1/ Hotstring engine SubStr(-1) tail guard =======
; =========================================================
; =============================================================

_TGS_EngineSubstrMinusOne() {
	Src := _TGS_StripLineComments(_TGS_ReadSource("lib/hotstrings/hotstring_engine_main.ahk"))
	Assert(Src != "", "hotstring_engine_main.ahk must be readable")

	; The fix: last character of the trigger is extracted with SubStr(Trigger, -1)
	Assert(InStr(Src, "SubStr(Trigger, -1)") > 0,
		"hotstring_engine_main.ahk must use SubStr(Trigger, -1) to extract the tail char (SubStr(-0) bug)")

	; The fix: last character of the star base is extracted with SubStr(StarBase, -1)
	Assert(InStr(Src, "SubStr(StarBase, -1)") > 0,
		"hotstring_engine_main.ahk must use SubStr(StarBase, -1) to extract the star tail char (SubStr(-0) bug)")

	; Guard: the broken negative-zero form must not appear anywhere in live code
	Assert(InStr(Src, "SubStr(Trigger, -0)") = 0,
		"hotstring_engine_main.ahk must NOT contain SubStr(Trigger, -0) — that returns the full string (SubStr(-0) bug)")
	Assert(InStr(Src, "SubStr(StarBase, -0)") = 0,
		"hotstring_engine_main.ahk must NOT contain SubStr(StarBase, -0) (SubStr(-0) bug)")
}
Test("hotstring engine: SubStr(-1) used for trigger/star tail char, SubStr(-0) absent", _TGS_EngineSubstrMinusOne)
