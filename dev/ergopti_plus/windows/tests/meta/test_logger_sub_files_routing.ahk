; tests/meta/test_logger_sub_files_routing.ahk

; ==============================================================================
; MODULE: Logger Sub-Files Routing Test
; DESCRIPTION:
; Source-scan meta test that guards the three routing bugs fixed in F11 and F19.
;
; BUGS ENCODED:
; F11 — _LoggerLoadSubFilesToml used a three-level relative path
;        (..\..\..\_shared\modules\logger\sub_files.toml) instead of one level up or
;        the canonical _SharedDir global, causing the TOML file to never be
;        found and silently falling back to the hardcoded list.
; F19a — The platform filter compared P against "autohotkey" but sub_files.toml
;         uses the token "ahk", so no entries were ever selected from the TOML.
; F19b — _LoggerFanOut compared Tag against TagPattern with exact equality, but
;         TOML patterns are bracketed substrings of the full log line (e.g.
;         "[LayoutShift]"), so no line was ever routed to a sub-file.
; F19c — LOGGER_SUB_FILES_FALLBACK used bare tag names ("LayoutShift") instead
;         of the bracketed form ("[LayoutShift]"), breaking fallback routing too.
; ==============================================================================

#Requires AutoHotkey v2.0


_LSFR_ReadSource(RelPath) {
	Root := A_ScriptDir . "\.."
	return FileRead(Root . "\" . RelPath, "UTF-8")
}





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

; F11 — path must NOT climb three directory levels
_LSFR_F11_NoTripleDotPath() {
	Src := _LSFR_ReadSource("lib\logger.ahk")
	; The old broken path contained three consecutive ..\
	HasTripleDot := InStr(Src, "..\..\..\\_shared") or InStr(Src, "..\\..\\..\\ shared") or InStr(Src, "...\\..\\..\\")
	; More reliable: count occurrences of "..\" in the TomlPath assignment line
	FoundBad := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "TomlPath") and InStr(Line, "ScriptDir") {
			if (InStr(Line, "..\..\..\"))
				FoundBad := true
		}
	}
	Assert(!FoundBad, "F11: _LoggerLoadSubFilesToml still uses three-level relative path (..\..\..\).")
}
Test("meta logger sub_files: F11 — path does not climb 3 levels", _LSFR_F11_NoTripleDotPath)


; F11 — path must use _SharedDir or one-level relative form
_LSFR_F11_UsesCorrectPath() {
	Src := _LSFR_ReadSource("lib\logger.ahk")
	HasSharedDir := InStr(Src, "_SharedDir")
	HasOneLevelUp := InStr(Src, "..\_shared\modules\logger")
	Assert(HasSharedDir or HasOneLevelUp,
		"F11: _LoggerLoadSubFilesToml must reference _SharedDir or one-level relative path (..\_shared\logger).")
}
Test("meta logger sub_files: F11 — path uses _SharedDir or one-level relative", _LSFR_F11_UsesCorrectPath)


; F19a — platform filter must use "ahk" not "autohotkey"
_LSFR_F19a_PlatformToken() {
	Src := _LSFR_ReadSource("lib\logger.ahk")
	; The wrong token: comparing against the string "autohotkey"
	HasWrongToken := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "= " . Chr(34) . "autohotkey" . Chr(34)) and InStr(Line, "P ")
			HasWrongToken := true
	}
	; The correct token must appear
	HasCorrectToken := InStr(Src, Chr(34) . "ahk" . Chr(34))
	Assert(!HasWrongToken, "F19a: platform filter still uses the token " . Chr(34) . "autohotkey" . Chr(34) . ".")
	Assert(HasCorrectToken, "F19a: platform filter does not use the token " . Chr(34) . "ahk" . Chr(34) . ".")
}
Test("meta logger sub_files: F19a — platform token is " . Chr(34) . "ahk" . Chr(34), _LSFR_F19a_PlatformToken)


; F19b — fan-out must use substring match (InStr) not exact tag equality
_LSFR_F19b_FanOutSubstringMatch() {
	Src := _LSFR_ReadSource("lib\logger.ahk")
	; Old broken form: (Tag = TagPattern)
	HasExactEquality := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "Tag = TagPattern") or InStr(Line, "(Tag = TagPattern)")
			HasExactEquality := true
	}
	; New correct form must use InStr(Line, Pat
	HasInStr := InStr(Src, "InStr(Line, Pat")
	Assert(!HasExactEquality, "F19b: _LoggerFanOut still uses exact tag equality (Tag = TagPattern).")
	Assert(HasInStr, "F19b: _LoggerFanOut must use InStr(Line, Pat, ...) for substring matching.")
}
Test("meta logger sub_files: F19b — fan-out uses InStr substring match", _LSFR_F19b_FanOutSubstringMatch)


; F19c — fallback patterns must be bracketed, not bare tag names
_LSFR_F19c_FallbackBracketedPatterns() {
	Src := _LSFR_ReadSource("lib\logger.ahk")
	; The canonical bracketed pattern for the layout sub-file
	HasBracketed := InStr(Src, Chr(34) . "[LayoutShift]" . Chr(34))
	; The old bare form must not appear in the fallback definition
	HasBareName := false
	InFallback := false
	for _, Line in StrSplit(Src, "`n", "`r") {
		if InStr(Line, "LOGGER_SUB_FILES_FALLBACK")
			InFallback := true
		if InFallback and InStr(Line, "]") and !InStr(Line, "[[") and !InStr(Line, "Map(")
			InFallback := false
		; A quoted bare "LayoutShift" (no bracket) inside the fallback block is the bug
		if InFallback and InStr(Line, Chr(34) . "LayoutShift" . Chr(34))
			HasBareName := true
	}
	Assert(HasBracketed, "F19c: LOGGER_SUB_FILES_FALLBACK must contain bracketed pattern " . Chr(34) . "[LayoutShift]" . Chr(34) . ".")
	Assert(!HasBareName, "F19c: LOGGER_SUB_FILES_FALLBACK must not contain bare pattern " . Chr(34) . "LayoutShift" . Chr(34) . " (missing brackets).")
}
Test("meta logger sub_files: F19c — fallback uses bracketed patterns", _LSFR_F19c_FallbackBracketedPatterns)
