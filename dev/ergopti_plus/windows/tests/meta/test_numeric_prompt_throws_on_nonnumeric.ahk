; tests/meta/test_numeric_prompt_throws_on_nonnumeric.ahk

; ==============================================================================
; MODULE: Numeric Prompt Non-Numeric Guard Meta Test
; DESCRIPTION:
; Static source guard for the numeric-prompt-throws-on-nonnumeric finding.
;
; The five numeric tray dialogs in ui/menu/menu_llm/menu_settings.ahk feed raw
; InputBox text straight into Integer() / Float(). In AHK v2 those conversion
; functions THROW on a non-numeric string (e.g. "abc", or "12,5" — the comma
; decimal a French keyboard user types out of habit) instead of returning 0.
; These prompts run in a menu-callback thread, so the throw is not swallowed:
; the user gets an unhandled AHK error dialog for a trivial typo.
;
; The fix guards every conversion with IsInteger / IsNumber before converting
; (mirroring the existing IsInteger guard in LLM_Menu_PromptOllamaPort) and
; normalises comma decimals to dots for the temperature Float() path.
;
; This is a meta-static test (scans source text) because menu_settings.ahk is
; not in the headless runner include graph and every prompt opens an InputBox
; (an OS-level dialog) that cannot run unattended. If a guard is removed, the
; conversion is once again reachable with raw text and this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_NPNN_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertions ======================
; ==================================================
; ==================================================

_NPNN_PromptNumericGuardsInteger() {
	Src := _NPNN_ReadSource("ui/menu/menu_llm/menu_settings.ahk")
	Seg := _DriverFuncBody("LLM_Menu_PromptNumeric")
	Assert(Seg != "", "LLM_Menu_PromptNumeric declaration must exist in menu_settings.ahk")
	Assert(InStr(Seg, "IsInteger") > 0,
		"LLM_Menu_PromptNumeric must guard with IsInteger before Integer() — a non-numeric typo would otherwise throw an unhandled error in the menu-callback thread")
}
Test("menu_settings: LLM_Menu_PromptNumeric guards Integer() with IsInteger (numeric-prompt-throws-on-nonnumeric)", _NPNN_PromptNumericGuardsInteger)

_NPNN_PromptMaxWordsGuardsInteger() {
	Src := _NPNN_ReadSource("ui/menu/menu_llm/menu_settings.ahk")
	Seg := _DriverFuncBody("LLM_Menu_PromptMaxWords")
	Assert(Seg != "", "LLM_Menu_PromptMaxWords declaration must exist in menu_settings.ahk")
	Assert(InStr(Seg, "IsInteger") > 0,
		"LLM_Menu_PromptMaxWords must guard with IsInteger before Integer() — a non-numeric typo would otherwise throw an unhandled error")
}
Test("menu_settings: LLM_Menu_PromptMaxWords guards Integer() with IsInteger (numeric-prompt-throws-on-nonnumeric)", _NPNN_PromptMaxWordsGuardsInteger)

_NPNN_PromptTemperatureGuardsFloat() {
	Src := _NPNN_ReadSource("ui/menu/menu_llm/menu_settings.ahk")
	Seg := _DriverFuncBody("LLM_Menu_PromptTemperature")
	Assert(Seg != "", "LLM_Menu_PromptTemperature declaration must exist in menu_settings.ahk")
	; The comma decimal is the common French-keyboard habit; the fix must
	; normalise it to a dot before the canonical temperature boundary.
	; Build the expected substring from Chr() so the test stays ASCII-only and
	; matches the exact StrReplace(value, ",", ".") normalisation the fix adds.
	Comma  := Chr(44)
	Dot    := Chr(46)
	NormPat := "StrReplace(ib.Value, " . Chr(34) . Comma . Chr(34) . ", " . Chr(34) . Dot . Chr(34) . ")"
	Assert(InStr(Seg, NormPat) > 0,
		"LLM_Menu_PromptTemperature must normalise comma decimals to dots so a French-keyboard '0,7' is accepted")
	ValidatorPos := InStr(Seg, "LLM_Option_TryNormalizeTemperature(raw, &Normalized)")
	Assert(ValidatorPos > InStr(Seg, NormPat),
		"LLM_Menu_PromptTemperature must pass normalized input through the canonical bounded-decimal validator")
	Assert(InStr(Seg, "Float(raw)") == 0,
		"LLM_Menu_PromptTemperature must not bypass canonical validation with a direct Float conversion")
}
Test("menu_settings: LLM_Menu_PromptTemperature uses the canonical temperature boundary (numeric-prompt-throws-on-nonnumeric)", _NPNN_PromptTemperatureGuardsFloat)
