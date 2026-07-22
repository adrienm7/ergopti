; tests/meta/test_terminators_requires_directive.ahk

; ==============================================================================
; MODULE: _generated/terminators.ahk #Requires Directive Guard
; DESCRIPTION:
; Static source guard for the #Requires AutoHotkey v2.0 directive fix in
; _generated/terminators.ahk.
;
; ROOT CAUSE ENCODED:
; Without a #Requires directive, AHK v1 could silently load and partially
; execute a v2 syntax file, producing confusing parse errors rather than a
; clear version mismatch message. The fix adds #Requires AutoHotkey v2.0 as
; the first non-comment line in the generated file, so AHK will refuse to load
; it with v1 and emit a clear error message.
;
; This test also verifies the directive appears before any executable code, not
; buried later in the file where it would be semantically invalid.
; ==============================================================================

#Requires AutoHotkey v2.0

_TTRD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path, "UTF-8")
}


; ===========================================================
; ===========================================================
; ======= 1/ #Requires directive present in terminators.ahk ==
; ===========================================================
; ===========================================================

_TTRD_RequiresDirectivePresent() {
	Src := _TTRD_ReadSource("_generated/terminators.ahk")
	Assert(Src != "", "_generated/terminators.ahk must be readable")

	; The directive must be present
	Assert(InStr(Src, "#Requires AutoHotkey v2.0") > 0,
		"_generated/terminators.ahk must contain #Requires AutoHotkey v2.0 directive")

	; It must appear in the first 512 characters (before any executable code)
	DirectivePos := InStr(Src, "#Requires AutoHotkey v2.0")
	Assert(DirectivePos <= 512,
		"#Requires AutoHotkey v2.0 must appear near the top of _generated/terminators.ahk (within first 512 chars), not buried later")
}
Test("generated/terminators: #Requires AutoHotkey v2.0 directive present near top of file", _TTRD_RequiresDirectivePresent)
