; tests/meta/test_case_transform_synthetic_mark.ahk

; ==============================================================================
; MODULE: Case Transform Synthetic Mark Meta Test
; DESCRIPTION:
; Regression guard ensuring the case-transform injectors in modules/gestures.ahk
; and modules/shortcuts/win.ahk mark their output as synthetic before calling
; SendInstant, so the keylogger does not record injected characters as real
; keystrokes that would corrupt ngram statistics.
;
; SCOPE: source introspection of modules/gestures.ahk and modules/shortcuts/win.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_CTSM_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_CTSM_CheckGestures() {
	Src := _CTSM_ReadSource("modules/gestures.ahk")
	Assert(Src != "", "modules/gestures.ahk must be readable")

	Assert(InStr(Src, 'KL_MarkSynthetic("case-transform")'),
		"GestureToggleUppercase/TitleCase must call KL_MarkSynthetic before SendInstant")
	Assert(InStr(Src, "KL_ClearSynthetic"),
		"GestureToggleUppercase/TitleCase must schedule KL_ClearSynthetic after SendInstant")
}

_CTSM_CheckWinShortcuts() {
	Src := _CTSM_ReadSource("modules/shortcuts/win.ahk")
	Assert(Src != "", "modules/shortcuts/win.ahk must be readable")

	Assert(InStr(Src, 'KL_MarkSynthetic("case-transform")'),
		"ConvertToTitleCase/ConvertToUppercase must call KL_MarkSynthetic before SendInstant")
	Assert(InStr(Src, "KL_ClearSynthetic"),
		"ConvertToTitleCase/ConvertToUppercase must schedule KL_ClearSynthetic after SendInstant")
}


Test("meta case-transform: gestures.ahk marks output as synthetic",
	_CTSM_CheckGestures)

Test("meta case-transform: shortcuts/win.ahk marks output as synthetic",
	_CTSM_CheckWinShortcuts)