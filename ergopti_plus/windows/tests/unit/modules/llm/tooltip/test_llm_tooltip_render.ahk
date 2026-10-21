; tests/unit/modules/llm/tooltip/test_llm_tooltip_render.ahk

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

; This headless harness does not run UiStyle_LoadSharedConst: read the shared
; shortcut spec from the same constants.toml it reads, so the labels below are
; the shipped ones.
_TestRender_SeedShortcutSpec() {
	global _SharedDir, UI_LLM_SHORTCUT_ORDER, UI_LLM_SHORTCUT_LABELS, UI_LLM_SHORTCUT_JOINER
	Constants := ParseTomlFile(_SharedDir . "\modules\tooltip\constants.toml")
	UI_LLM_SHORTCUT_ORDER := IniCacheGet(Constants, "llm_ui", "shortcut_modifier_order")
	UI_LLM_SHORTCUT_LABELS := IniCacheGet(Constants, "llm_ui", "shortcut_labels_ahk")
	UI_LLM_SHORTCUT_JOINER := IniCacheGet(Constants, "llm_ui", "shortcut_joiner_ahk")
	AssertTrue(UI_LLM_SHORTCUT_ORDER != "_" && UI_LLM_SHORTCUT_LABELS != "_" && UI_LLM_SHORTCUT_JOINER != "_",
		"constants.toml must declare the shortcut spec")
}

; Windows names its modifiers in words. The macOS glyphs (U+2318 cmd, U+2303
; ctrl, U+2325 option, U+21E7 shift) are meaningless on a Windows keyboard and
; made "Alt+1" read as a Mac Cmd shortcut (llm-val-mods-windows-labels).
_TestRender_ValModsDoesNotThrow() {
	_TestRender_SeedShortcutSpec()
	threw := false
	r := ""
	try {
		r := _LLM_FormatValModifiers("alt")
	} catch {
		threw := true
	}
	AssertFalse(threw,
		"_LLM_FormatValModifiers must not throw on a normal modifier (regression: misplaced StrReplace arg)")
	AssertEqual("Alt", r, "'alt' must format to the Windows key name")
}
Test("render: _LLM_FormatValModifiers does not throw and maps 'alt'",
	_TestRender_ValModsDoesNotThrow)


_TestRender_ValModsAllSymbols() {
	_TestRender_SeedShortcutSpec()
	AssertEqual("Win",   _LLM_FormatValModifiers("cmd"),   "'cmd' -> Win")
	AssertEqual("Ctrl",  _LLM_FormatValModifiers("ctrl"),  "'ctrl' -> Ctrl")
	AssertEqual("Shift", _LLM_FormatValModifiers("shift"), "'shift' -> Shift")
	for Name in ["cmd", "ctrl", "alt", "shift", "alt+shift"] {
		Label := _LLM_FormatValModifiers(Name)
		for Glyph in [0x2318, 0x2303, 0x2325, 0x21E7]
			AssertEqual(0, InStr(Label, Chr(Glyph)),
				"'" . Name . "' must not render a macOS glyph on Windows (llm-val-mods-windows-labels)")
	}
}
Test("render: each modifier name maps to its Windows label (llm-val-mods-windows-labels)",
	_TestRender_ValModsAllSymbols)


_TestRender_ValModsEmptyAndCombined() {
	_TestRender_SeedShortcutSpec()
	AssertEqual("", _LLM_FormatValModifiers(""),     "empty input formats to empty")
	AssertEqual("", _LLM_FormatValModifiers("none"), "'none' formats to empty")
	AssertEqual("Alt+Shift", _LLM_FormatValModifiers("alt+shift"),
		"combined modifiers keep the Windows '+' separator")
}
Test("render: empty/none/combined modifiers format correctly",
	_TestRender_ValModsEmptyAndCombined)


; Every prediction row shows the chord that inserts it in a right-aligned
; column: bare digits included (they had no hint at all), a single prediction
; included, under the Windows labels of the shared shortcut spec
; (_shared/tests/corpus/tooltip/llm_shortcut_vectors.json, llm-shortcut-column).
_TestRender_ShortcutLabelsFollowTheCorpus() {
	_TestRender_SeedShortcutSpec()
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\llm_shortcut_vectors.json"
	if !FileExist(Path)
		throw Error("LLM shortcut corpus not found at '" . Path . "'")
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	AssertTrue(Corpus["vectors"].Length >= 10, "the corpus must carry every prediction row")
	for Vec in Corpus["vectors"] {
		Mods := ""
		for Name in Vec["modifiers"]
			Mods .= (Mods = "" ? "" : "+") . Name
		AssertEqual(Vec["expected"]["ahk"], _LLM_PredictionShortcutLabel(Vec["index"], Mods),
			"shortcut '" . Vec["id"] . "'")
	}
}
Test("render: the shortcut column follows the shared corpus (llm-shortcut-column)",
	_TestRender_ShortcutLabelsFollowTheCorpus)

; The hint is read from the same validation modifiers that build the binding:
; for each modifier choice, every digit route of the real binding plan and the
; label of its row name the same modifiers and the same digit.
_TestRender_ShortcutLabelsAgreeWithTheBinding() {
	_TestRender_SeedShortcutSpec()
	global UI_LLM_SHORTCUT_JOINER
	Names := Map("^", "ctrl", "!", "alt", "+", "shift", "#", "cmd")
	for ValMods in ["", "alt", "ctrl", "shift", "cmd", "ctrl+alt", "shift+alt+ctrl", "cmd+shift"] {
		Built := _LLM_Menu_BuildNavBindingPlan(Map("nav_modifiers", "", "val_modifiers", ValMods))
		AssertTrue(Built is Map, "'" . ValMods . "' must build a binding plan")
		Routes := 0
		for Record in Built["plan"] {
			if !Record.Has("jump_idx") || !Record["jump_idx"]
				continue
			Routes += 1
			Spec := Record["spec"]
			Bound := ""
			for Char in StrSplit(SubStr(Spec, 1, -1))
				if (Char != "")
					Bound .= (Bound = "" ? "" : "+") . Names[Char]
			AssertEqual(_LLM_PredictionShortcutLabel(Record["jump_idx"], Bound),
				_LLM_PredictionShortcutLabel(Record["jump_idx"], ValMods),
				"'" . ValMods . "' row " . Record["jump_idx"] . ": hint and binding modifiers")
			AssertEqual(SubStr(Spec, -1),
				SubStr(_LLM_PredictionShortcutLabel(Record["jump_idx"], ValMods), -1),
				"'" . ValMods . "' row " . Record["jump_idx"] . ": hint and binding digit")
		}
		AssertEqual(10, Routes, "'" . ValMods . "' must bind the ten digit routes")
	}
}
Test("render: each row's shortcut names the chord its binding consumes (llm-shortcut-column)",
	_TestRender_ShortcutLabelsAgreeWithTheBinding)




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
