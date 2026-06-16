; tests/meta/test_generated_substr_minus_one.ahk

; ==============================================================================
; MODULE: Generated SubStr(-1) Guard
; DESCRIPTION:
; Static source guard for the SubStr(-0) → SubStr(-1) fix in generated files.
;
; ROOT CAUSE ENCODED:
; SubStr(s, -0) is equivalent to SubStr(s, 0), which in AHK v2 returns the full
; string because negative-zero is treated as zero (an out-of-range start), rather
; than extracting the last character. The fix replaces every occurrence of
; SubStr(trigger, -0) and SubStr(starBase, -0) / SubStr(star_base, -0) with
; SubStr(..., -1) in both _generated/registry.ahk and _generated/expander.ahk.
; This test fails if any of these are reverted back to -0.
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





; =================================================
; =================================================
; ======= 1/ registry.ahk SubStr(-1) checks =======
; =================================================
; =================================================

_TGS_RegistrySubstrMinusOne() {
	Src := _TGS_StripLineComments(_TGS_ReadSource("_generated/registry.ahk"))
	Assert(Src != "", "_generated/registry.ahk must be readable")

	; The fix: last character of trigger is extracted with SubStr(trigger, -1)
	Assert(InStr(Src, "SubStr(trigger, -1)") > 0,
		"_generated/registry.ahk must use SubStr(trigger, -1) to extract the tail char (SubStr(-0) bug)")

	; The fix: last character of star_base is extracted with SubStr(star_base, -1)
	Assert(InStr(Src, "SubStr(star_base, -1)") > 0,
		"_generated/registry.ahk must use SubStr(star_base, -1) to extract the star tail char (SubStr(-0) bug)")

	; Guard: the broken form must not appear anywhere in live code
	Assert(InStr(Src, "SubStr(trigger, -0)") = 0,
		"_generated/registry.ahk must NOT contain SubStr(trigger, -0) — that returns the full string (SubStr(-0) bug)")
	Assert(InStr(Src, "SubStr(star_base, -0)") = 0,
		"_generated/registry.ahk must NOT contain SubStr(star_base, -0) (SubStr(-0) bug)")
}
Test("generated/registry: SubStr(-1) used for tail char extraction, SubStr(-0) absent", _TGS_RegistrySubstrMinusOne)





; =================================================
; =================================================
; ======= 2/ expander.ahk SubStr(-1) checks =======
; =================================================
; =================================================

_TGS_ExpanderSubstrMinusOne() {
	Src := _TGS_StripLineComments(_TGS_ReadSource("_generated/expander.ahk"))
	Assert(Src != "", "_generated/expander.ahk must be readable")

	; The fix: last character of starBase extracted with SubStr(starBase, -1)
	Assert(InStr(Src, "SubStr(starBase, -1)") > 0,
		"_generated/expander.ahk must use SubStr(starBase, -1) to extract the star tail char (SubStr(-0) bug)")

	; Guard: broken form must not appear in live code
	Assert(InStr(Src, "SubStr(starBase, -0)") = 0,
		"_generated/expander.ahk must NOT contain SubStr(starBase, -0) (SubStr(-0) bug)")
}
Test("generated/expander: SubStr(-1) used for starBase tail char, SubStr(-0) absent", _TGS_ExpanderSubstrMinusOne)
