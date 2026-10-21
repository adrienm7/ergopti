; tests/unit/modules/hotstrings/preview/test_hotstring_preview_end_scalar.ahk

; ==============================================================================
; MODULE: Preview End Scalar Regressions
; DESCRIPTION:
; Drives the real collector and engine with the first configured delimiter.
; A supplementary delimiter must cross the preview boundary as both UTF-16 units.
; ==============================================================================

#Requires AutoHotkey v2.0

_HPES_Run(Mode) {
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS, ScriptInformation, HSE_MAX_BUFFER_LEN
	global HSE_RepeatEnabled, HSE_PersonalInfoCombosEnabled, HSE_RebuildInProgress
	global HSE_Suppressed, _PrefixWatcherSuppressed, _PrefixLastKeyTick
	global HSE_Buffer, HSE_LastEndChar, HSE_LastMatch
	PreviousCritical := Critical("On")
	Saved := { Capacity: HSE_MAX_BUFFER_LEN, Words: HSE_WORD_TERMINATORS, Consumed: HSE_CONSUMED_DELIMITERS,
		Information: ScriptInformation, Repeat: HSE_RepeatEnabled,
		Combos: HSE_PersonalInfoCombosEnabled, Rebuild: HSE_RebuildInProgress,
		Suppressed: HSE_Suppressed, PrefixSuppressed: _PrefixWatcherSuppressed,
		Tick: _PrefixLastKeyTick }
	try {
		HSE_TestReset()
		HSE_RebuildInProgress := false
		HSE_RepeatEnabled := false
		HSE_PersonalInfoCombosEnabled := false
		ScriptInformation := Saved.Information.Clone()
		ScriptInformation["MagicKey"] := "★"
		Face := Chr(0x1F600)
		HSE_MAX_BUFFER_LEN := StrLen("qr" . Face)
		Expected := Face
		HSE_WORD_TERMINATORS := Face
		if Mode == "astral-first"
			HSE_WORD_TERMINATORS := Face . " " . Chr(0x1F601)
		else if Mode == "bmp-first" {
			Expected := "§"
			HSE_WORD_TERMINATORS := Expected . Face
		} else if Mode == "bmp-only" {
			Expected := " "
			HSE_WORD_TERMINATORS := Expected
		} else if Mode == "magic-equals-first"
			ScriptInformation["MagicKey"] := Face
		else if Mode == "empty-with-magic" {
			HSE_WORD_TERMINATORS := ""
			Expected := "★"
		}
		HSE_CONSUMED_DELIMITERS := HSE_WORD_TERMINATORS
		IsMagicOnly := Mode == "empty-with-magic"
		Trigger := IsMagicOnly ? "qr★" : "qr"
		Spec := HSE_Register(IsMagicOnly ? "*C" : "C", Trigger, 0,
			{ Replacement: "RESULT", OnlyText: true })
		HSE_FeedChar("q", true)
		HSE_FeedChar("r", true)
		BeforeEnd := HSE_LastEndChar, BeforeMatch := HSE_LastMatch
		Oracle := HSE_PreviewNextDecision("qr", Expected)
		AssertTrue(IsObject(Oracle), "the complete independent golden must really fire")
		Rows := _PrefixCollectCandidates()
		AssertEqual(1, Rows.Length, "the first complete delimiter must produce exactly one row")
		Row := Rows[1]
		AssertEqual(Expected, Row.Completion, "the row must carry the full independent completion golden")
		AssertEqual(Expected, Row.FireDecision.Completion)
		AssertEqual(IsMagicOnly ? "" : Expected, Row.FireDecision.EndChar)
		AssertEqual("qr" . Expected, Row.FireDecision.BufferAfterCompletion)
		AssertEqual(Oracle.BufferAfterCompletion, Row.FireDecision.BufferAfterCompletion)
		AssertEqual(Oracle.EndChar, Row.FireDecision.EndChar)
		AssertEqual(ObjPtr(Spec), ObjPtr(Row.FireDecision.Spec))
		AssertEqual("RESULT", Row.Output)
		AssertEqual("qr", HSE_Buffer, "collecting candidates must restore the live engine buffer")
		AssertEqual(BeforeEnd, HSE_LastEndChar)
		AssertEqual(BeforeMatch, HSE_LastMatch)
		if Mode == "astral-only" {
			AssertFalse(IsObject(HSE_PreviewNextDecision("qr", Chr(0x1F601))),
				"another scalar sharing the high half is not the configured delimiter")
		}
		Winner := HSE_FeedChar(Expected, true)
		AssertTrue(IsObject(Winner), "the real feed must agree with the advertised completion")
		AssertEqual(ObjPtr(Spec), ObjPtr(Winner))
		AssertEqual(IsMagicOnly ? "" : Expected, HSE_LastEndChar)
	} finally {
		HSE_TestReset()
		HSE_MAX_BUFFER_LEN := Saved.Capacity
		HSE_WORD_TERMINATORS := Saved.Words
		HSE_CONSUMED_DELIMITERS := Saved.Consumed
		ScriptInformation := Saved.Information
		HSE_RepeatEnabled := Saved.Repeat
		HSE_PersonalInfoCombosEnabled := Saved.Combos
		HSE_RebuildInProgress := Saved.Rebuild
		HSE_Suppressed := Saved.Suppressed
		_PrefixWatcherSuppressed := Saved.PrefixSuppressed
		_PrefixLastKeyTick := Saved.Tick
		Critical(PreviousCritical)
	}
}

for _HPES_Mode in ["astral-only", "astral-first", "bmp-first", "bmp-only", "magic-equals-first", "empty-with-magic"]
	Test("HSE preview END scalar: " . _HPES_Mode . " keeps the full completion (hotstring-preview-end-scalar)",
		_HPES_Run.Bind(_HPES_Mode))
