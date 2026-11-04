; tests/unit/modules/hotstrings/engine/test_hotstring_final_result.ahk

; ==============================================================================
; MODULE: Final-result hotstrings (hotstring-final-result)
; DESCRIPTION:
; Replays the shared final_result_vectors.json corpus through the real engine and
; dispatcher with a virtual screen: the output of a final entry is never matched
; again, a final entry that changes nothing still claims its text, and a final
; end-character entry of higher priority holds back a lower immediate one. The
; same corpus runs on macOS and Linux (test_hotstring_final_result.lua).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Headless harness =======
; ===================================
; ===================================

global _HFR_Screen := ""

; Applies one injected burst to the virtual screen: {BackSpace N}, {Text}...
_HFR_SendInput(Keys) {
	global _HFR_Screen
	Pos := 1
	while (Pos <= StrLen(Keys)) {
		if RegExMatch(Keys, "^\{BackSpace (\d+)\}", &Backspace, Pos) {
			loop Integer(Backspace[1])
				_HFR_Screen := SubStr(_HFR_Screen, 1, StrLen(_HFR_Screen) - _TextTailCodeUnits(_HFR_Screen, 1))
			Pos += StrLen(Backspace[0])
		} else if (SubStr(Keys, Pos, 6) == "{Text}") {
			_HFR_Screen .= SubStr(Keys, Pos + 6)
			break
		} else {
			_HFR_Screen .= SubStr(Keys, Pos)
			break
		}
	}
	return 1
}

; Registers one corpus rule through the loaders' own entry point.
_HFR_Register(Rule) {
	CaseSensitive := Rule.Has("case_sensitive") and Rule["case_sensitive"]
	Flags := (Rule["auto"] ? "*" : "") . (Rule["word_start"] ? "" : "?") . (CaseSensitive ? "C" : "")
	Final := Rule.Has("final_result") and Rule["final_result"]
	HSE_RegisterFromTomlFlags(CaseSensitive, Flags, Rule["trigger"], Rule["replacement"],
		Map("TimeActivationSeconds", 0, "FinalResult", Final, "Priority", Rule["priority"]))
}

; Types Text into a clean engine holding Rules; returns what the screen shows.
_HFR_Replay(Rules, Text, MaxArrows) {
	global HSE_CascadeMaxArrows, _AHK_SendInput, _SendHook, _HotstringRegistrar, _HFR_Screen
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	SavedInput := _AHK_SendInput
	SavedHook := _SendHook
	SavedRegistrar := _HotstringRegistrar
	SavedArrows := HSE_CascadeMaxArrows
	SavedTerminators := HSE_WORD_TERMINATORS
	SavedConsumed := HSE_CONSUMED_DELIMITERS
	_HFR_Screen := ""
	_SendHook := 0
	_HotstringRegistrar := 0
	_AHK_SendInput := _HFR_SendInput
	HSE_CascadeMaxArrows := MaxArrows
	HSE_WORD_TERMINATORS := " `t`n"
	HSE_CONSUMED_DELIMITERS := ""
	HSE_RegistryClear()
	HSE_HardReset()
	HSE_FeedReset(true)
	try {
		for Rule in Rules
			_HFR_Register(Rule)
		for Char in StrSplit(Text) {
			_HFR_Screen .= Char
			AppState_TouchLastSentKey(Char)
			Match := HSE_FeedChar(Char, true)
			if IsObject(Match) {
				Effect := 0
				HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect)
			}
		}
		return _HFR_Screen
	} finally {
		_AHK_SendInput := SavedInput
		_SendHook := SavedHook
		_HotstringRegistrar := SavedRegistrar
		HSE_CascadeMaxArrows := SavedArrows
		HSE_WORD_TERMINATORS := SavedTerminators
		HSE_CONSUMED_DELIMITERS := SavedConsumed
		HSE_RegistryClear()
		HSE_HardReset()
	}
}

_HFR_Corpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\final_result_vectors.json"
	if !FileExist(Path)
		throw Error("shared corpus not found at '" . Path . "'")
	return JsonParse(FileRead(Path, "UTF-8"))
}





; ============================================
; ============================================
; ======= 2/ Corpus replays ==================
; ============================================
; ============================================

; Every combination, reported together so a failure names the whole affected set.
_HFR_MatrixBody() {
	Matrix := _HFR_Corpus()["matrix"]
	Failures := ""
	Count := 0
	for PersonalAuto in Matrix["personal_auto"]
		for BundledAuto in Matrix["bundled_auto"]
			for CaseSensitive in Matrix["case_sensitive"]
				for Output in Matrix["output"]
					for Arrows in Matrix["max_arrows"]
						for EndChar in Matrix["end_char"] {
							Rules := [
								Map("trigger", Matrix["trigger"], "replacement", Output, "auto", PersonalAuto,
									"word_start", true, "priority", Matrix["personal_priority"],
									"final_result", true, "case_sensitive", CaseSensitive),
								Map("trigger", Matrix["trigger"], "replacement", Matrix["bundled"], "auto", BundledAuto,
									"word_start", true, "priority", Matrix["bundled_priority"])
							]
							Count += 1
							Screen := _HFR_Replay(Rules, Matrix["trigger"] . EndChar, Arrows)
							if !(Screen == Output . EndChar)
								Failures .= Format("`npersonal_auto={1} bundled_auto={2} cs={3} output={4} arrows={5} end={6}: {7}",
									PersonalAuto, BundledAuto, CaseSensitive, Output, Arrows, Ord(EndChar), Screen)
						}
	AssertEqual(216, Count, "the corpus names every combination")
	AssertEqual("", Failures, "combinations that lost the personal output")
}

_HFR_VectorsBody() {
	Failures := ""
	for Vector in _HFR_Corpus()["vectors"] {
		Screen := _HFR_Replay(Vector["rules"], Vector["typed"], Vector["max_arrows"])
		if !(Screen == Vector["expect_screen"])
			Failures .= "`n" . Vector["id"] . ": [" . Screen . "] instead of [" . Vector["expect_screen"] . "]"
	}
	AssertEqual("", Failures, "explicit vectors")
}

; The paced terminal commit is a commit site of a final output too.
_HFR_TerminalCommitBody() {
	global HSE_Buffer, HSE_StartIsWordBoundary, _LLM_Bridge_Active, _LLM_Bridge_AgentFeeding
	SavedActive := _LLM_Bridge_Active
	SavedAgent := _LLM_Bridge_AgentFeeding
	try {
		_LLM_Bridge_Active := false
		_LLM_Bridge_AgentFeeding := false
		for Final in [false, true] {
			HSE_Buffer := "sru"
			HSE_StartIsWordBoundary := true
			Owner := Map("EraseUnits", 3, "OnlyText", true, "PlainInsertedText", "SRU ", "OutputIsFinal", Final,
				"EndCharPart", " ", "IsPrivate", false, "Trigger", "sru",
				"ReplacementForLog", "SRU", "HType", "star", "Category", "fixture", "Section", "fixture")
			_HSE_CommitTerminalOwner(Owner, "")
			AssertEqual(Final ? "" : "SRU ", HSE_Buffer, "the terminal commit follows the entry's finality")
			AssertTrue(HSE_StartIsWordBoundary, "the output ends at a delimiter")
		}
	} finally {
		_PrefixCancelRender()
		_LLM_Bridge_Active := SavedActive
		_LLM_Bridge_AgentFeeding := SavedAgent
	}
}

Test("final result: the terminal commit forgets a final output (hotstring-final-result)",
	(*) => _AHK04_RunIsolated(_HFR_TerminalCommitBody))
Test("final result: every combination keeps the personal output (hotstring-final-result)",
	(*) => _AHK04_RunIsolated(_HFR_MatrixBody))
Test("final result: the explicit vectors (hotstring-final-result)",
	(*) => _AHK04_RunIsolated(_HFR_VectorsBody))
