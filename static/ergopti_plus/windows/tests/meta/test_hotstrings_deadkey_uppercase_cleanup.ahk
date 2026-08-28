; tests/meta/test_hotstrings_deadkey_uppercase_cleanup.ahk

; ==============================================================================
; MODULE: Circumflex Dead-Key Case Matrix Regression
; DESCRIPTION:
; Exercises the production registration helper and matcher for every lower/upper
; combination of the dead key and its vowel. The former source scan passed on an
; unreachable case-insensitive inequality and could not distinguish a duplicate,
; a declined conform match, or the exact replacement that reaches the screen.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include ../../modules/hotstrings/hotstrings_helpers.ahk
#Include ../../modules/hotstrings/hotstrings_distances.ahk





; ======================================================
; ======================================================
; ======= 1/ Exact case matrix and single winner =======
; ======================================================
; ======================================================

_HSDU_PreparedReplacement(Match, Typed) {
	if Match.HasOwnProp("RawCallback") && Match.RawCallback {
		Verdict := Match.Callback.Call("", true)
		return Verdict.Ok ? Verdict.Ins : ""
	}
	Decision := _HSE_PrepareDispatchDecision(Match, " " . Typed, "")
	return IsObject(Decision) ? Decision.Replacement : ""
}

_HSDU_CircumflexCaseMatrixHasOneExactWinner() {
	global LastSentCharacterKeyTime
	Mapping := Map(
		"a", "â", "A", "Â", "à", "æ", "À", "Æ",
		"i", "î", "I", "Î", "o", "ô", "O", "Ô",
		"u", "û", "U", "Û", "s", "ß", "S", "ẞ",
		"e", "ê", "E", "Ê", "t", "!", "T", "¡")
	Cases := [
		{ Typed: "êa", Expected: "â" },
		{ Typed: "Êa", Expected: "Â" },
		{ Typed: "ÊA", Expected: "Â" },
		{ Typed: "êA", Expected: "Â" }
	]
	for Fixture in Cases {
		HSE_TestReset()
		ResetHotstringRecorders()
		_HS_RegisterCircumflexDeadkeys(60, Mapping)
		_LSCResetFrom([" ", SubStr(Fixture.Typed, 1, 1), SubStr(Fixture.Typed, 2, 1)])
		LastSentCharacterKeyTime := Map(
			SubStr(Fixture.Typed, 1, 1), A_TickCount,
			SubStr(Fixture.Typed, 2, 1), A_TickCount)
		HSE_FeedChar(" ")
		HSE_FeedChar(SubStr(Fixture.Typed, 1, 1))
		Match := HSE_FeedChar(SubStr(Fixture.Typed, 2, 1))
		Assert(IsObject(Match),
			"case " . Fixture.Typed . " must produce exactly one matcher winner")
		AssertEqual(Fixture.Expected, _HSDU_PreparedReplacement(Match, Fixture.Typed),
			"case " . Fixture.Typed . " must preserve its exact circumflex output")
	}
}

Test("hotstrings: circumflex dead-key lower/upper matrix has one exact winner (AHK-066)",
	_HSDU_CircumflexCaseMatrixHasOneExactWinner)
