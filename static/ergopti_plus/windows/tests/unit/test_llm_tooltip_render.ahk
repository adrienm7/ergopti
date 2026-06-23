; tests/unit/test_llm_tooltip_render.ahk

; ==============================================================================
; MODULE: LLM Tooltip Render Regression Tests
; DESCRIPTION:
; Regression guard for the "clignote et part" display bug: the prediction tooltip
; appeared then vanished within ~200 ms with NO hide logged. Root cause: the
; footer formatter _LLM_FormatValModifiers() built the validation-modifier symbol
; with a misplaced StrReplace argument -
;
;     StrReplace(sym, "cmd", Chr(0x2318), , true)   ; the extra comma puts `true`
;                                                    ; on param #5 (&OutputVarCount)
;
; AHK v2 throws "Parameter #5 of StrReplace requires a variable reference, but
; received an Integer." That exception fired inside _TooltipBuildGuiLlm AFTER it
; had torn the current prediction's window down but BEFORE the present + the
; generation bump, so the window was destroyed with no SHOW/HIDE and no trace -
; the tooltip silently disappeared. The single-slot first render skipped the
; footer path, so the first paint survived and a streaming re-render killed it.
;
; WHAT THESE TESTS ENCODE:
; 1. _LLM_FormatValModifiers must NOT throw on ordinary modifiers and must map
;    each name to its symbol (the exact path that used to throw).
; 2. Empty / "none" / combined inputs behave.
; Non-ASCII glyphs are referenced via Chr(0xNNNN) so the suite stays ASCII-only
; (a clean-encoding defensive convention; see copilot-instructions).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================================
; ==================================================================
; ======= 1/ _LLM_FormatValModifiers does not throw + maps =========
; ==================================================================
; ==================================================================

; Mac modifier glyphs, by code point: cmd U+2318, ctrl U+2303, alt U+2325,
; shift U+21E7. These are exactly what the production formatter emits.
_TestRender_ValModsDoesNotThrow() {
	threw := false
	r := ""
	try {
		r := _LLM_FormatValModifiers("alt")
	} catch {
		threw := true
	}
	AssertFalse(threw,
		"_LLM_FormatValModifiers must not throw on a normal modifier (regression: misplaced StrReplace arg)")
	AssertEqual(Chr(0x2325), r, "'alt' must format to the option symbol U+2325")
}
Test("render: _LLM_FormatValModifiers does not throw and maps 'alt'",
	_TestRender_ValModsDoesNotThrow)


_TestRender_ValModsAllSymbols() {
	AssertEqual(Chr(0x2318), _LLM_FormatValModifiers("cmd"),   "'cmd' -> U+2318")
	AssertEqual(Chr(0x2303), _LLM_FormatValModifiers("ctrl"),  "'ctrl' -> U+2303")
	AssertEqual(Chr(0x21E7), _LLM_FormatValModifiers("shift"), "'shift' -> U+21E7")
}
Test("render: each modifier name maps to its glyph", _TestRender_ValModsAllSymbols)


_TestRender_ValModsEmptyAndCombined() {
	AssertEqual("", _LLM_FormatValModifiers(""),     "empty input formats to empty")
	AssertEqual("", _LLM_FormatValModifiers("none"), "'none' formats to empty")
	; "alt+shift" -> option + shift, with the "+" stripped.
	AssertEqual(Chr(0x2325) . Chr(0x21E7), _LLM_FormatValModifiers("alt+shift"),
		"combined modifiers concatenate their glyphs and drop the '+'")
}
Test("render: empty/none/combined modifiers format correctly",
	_TestRender_ValModsEmptyAndCombined)




; ==================================================================
; ==================================================================
; ======= 2/ Source contract: render errors degrade safely =========
; ==================================================================
; ==================================================================

_TestRender_BuildGuardPresent() {
	Body := _DriverDirConcat("ui/tooltip")
	; Defence in depth: even if some future formatter throws mid-build, the tooltip
	; must not be left destroyed with a ghost "visible" flag. LLM_TooltipShow wraps
	; the build and resets to a clean hidden state on error.
	Assert(InStr(Body, "catch as _llm_build_err") > 0,
		"LLM_TooltipShow must guard the prediction build so a render error hides cleanly")
	; And the specific bug must stay fixed: no StrReplace call may pass a literal on
	; its &OutputVarCount parameter (the misplaced ``, , true`` that threw).
	Assert(!_StrReplaceParam5LiteralPresent(Body),
		"no StrReplace(...) may put a literal on param #5 (&OutputVarCount) - it throws at runtime")
}
Test("render: build is guarded + no StrReplace param-5 literal in tooltip.ahk",
	_TestRender_BuildGuardPresent)

; Returns true if any line calls StrReplace with an empty 4th arg followed by a
; literal 5th arg, e.g. ``StrReplace(x, "a", "b", , true)`` - param #5 is the
; &OutputVarCount VariableRef and a literal there throws.
_StrReplaceParam5LiteralPresent(Body) {
	for Line in StrSplit(Body, "`n", "`r") {
		if (InStr(Line, "StrReplace(")
				and RegExMatch(Line, "i)StrReplace\([^)]*,\s*,\s*(true|false|\d)"))
			return true
	}
	return false
}
