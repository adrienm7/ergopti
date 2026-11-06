; tests/unit/modules/hotstrings/engine/test_repeat_activation_window.ahk

; ==============================================================================
; MODULE: Repeat Activation Window (Windows)
; DESCRIPTION:
; The magic-key repeat answers within the magic key category's window, as on
; macOS and Linux (decision of 2026-11-06, repeat-window): its transient Spec
; carries the resolved delay and the repeated letter as the time-gate reference,
; so the dispatcher's existing gate (complex-key widening included) refuses a
; magic key typed long after the letter. Before, the Spec had no time metadata
; and repeated after any pause.
; ==============================================================================

#Requires AutoHotkey v2.0

_RAW_RepeatSpecCarriesTheWindow() {
	global HSE_Buffer, HSE_StartIsWordBoundary
	_RKF_Reset()
	try {
		HSE_Buffer := "po★"
		HSE_StartIsWordBoundary := true
		Spec := HSE_TryRepeatKey("★")
		Assert(IsObject(Spec), "control: po★ is a repeat")
		Expected := HotstringsResolve("magickey", "repeat_corrections").Delay
		AssertEqual(Expected == "" ? 0 : Expected, Spec.TimeActivationSeconds,
			"the repeat carries the magic key category's delay")
		AssertEqual(HSE_TimeGateReferenceChar("o★", true), Spec.PrevCharKey,
			"the gate measures from the repeated letter")
		AssertEqual(HSE_RepeatWindowSeconds(), Spec.TimeActivationSeconds)
	} finally _RKF_Reset()
}
Test("hotstrings: the magic-key repeat carries its category's activation window (repeat-window)",
	_RAW_RepeatSpecCarriesTheWindow)

_RAW_ExpiredRepeatIsRefused() {
	global HSE_Buffer, HSE_StartIsWordBoundary, LastSentCharacterKeyTime, LastSentCharacterKeyComplex
	_RKF_Reset()
	SavedTimes := IsSet(LastSentCharacterKeyTime) ? LastSentCharacterKeyTime : ""
	SavedComplex := IsSet(LastSentCharacterKeyComplex) ? LastSentCharacterKeyComplex : ""
	try {
		HSE_Buffer := "po★"
		HSE_StartIsWordBoundary := true
		Spec := HSE_TryRepeatKey("★")
		Assert(IsObject(Spec), "control: po★ is a repeat")
		Assert(Spec.TimeActivationSeconds > 0, "the shipped magic key window is positive")
		LastSentCharacterKeyComplex := Map()
		; Far past the window, whatever the complex-key widening.
		LastSentCharacterKeyTime := Map(Spec.PrevCharKey,
			Max(0, A_TickCount - Round(Spec.TimeActivationSeconds * 1000) * 10 - 5000))
		AssertEqual("", _HSE_PrepareDispatchDecision(Spec, "po★", ""),
			"a magic key typed long after the letter is no repeat")
	} finally {
		if (SavedTimes != "")
			LastSentCharacterKeyTime := SavedTimes
		if (SavedComplex != "")
			LastSentCharacterKeyComplex := SavedComplex
		_RKF_Reset()
	}
}
Test("hotstrings: a repeat typed after its window is refused by the time gate (repeat-window)",
	_RAW_ExpiredRepeatIsRefused)
