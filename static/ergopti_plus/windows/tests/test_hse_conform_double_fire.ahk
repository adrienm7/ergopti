; tests/test_hse_conform_double_fire.ahk

; ==============================================================================
; MODULE: HSE Case-Conform Repeat-Fire Test
; DESCRIPTION:
; Guards that a case-conform magic-key hotstring (the kind every magic-key
; text-expansion entry became after faf39a7bb registered ONE case-insensitive
; spec + conformed casing at fire time) fires REPEATEDLY, not just the first
; time. The dispatch carries HSE_Buffer forward via HSE_ApplyExpansion and gates
; further feeds on HSE_Suppressed; a regression that leaves the buffer stale or
; suppression stuck would make the trigger expand once and then never again.
;
; WHY THIS MATTERS (the regression this encodes):
;   A conform spec resolves its output casing from the trigger as actually typed
;   (the last Spec.Length chars of HSE_Buffer). If a future change broke the
;   post-expansion buffer resync, or left HSE_Suppressed set, the SECOND identical
;   trigger would either fail to match (buffer never refilled) or compute a bad
;   typed-trigger and refuse to fire. Both reproduce the user-reported
;   "ct* expands the first time then never expands" symptom. These tests drive two
;   consecutive fires through the production dispatch and assert BOTH expand.
;
; TWO ANGLES:
;   1. Released:  simulate the deferred suppression release between fires (the
;      synchronous harness cannot run a -60 ms SetTimer itself) -- proves the pure
;      buffer-carry-over + conform logic re-fires.
;   2. Real timer: let the production -60 ms SetTimer((*) => HSE_Suppress(false))
;      actually fire (a Sleep pumps the AHK message loop) -- proves the deferred
;      release path itself clears suppression so the next keystroke feeds again.
; ==============================================================================

#Requires AutoHotkey v2.0




; =========================================
; =========================================
; ======= 1/ Repeat-fire dispatch =========
; =========================================
; =========================================

; Last recorded send burst (the atomic BackSpace+replacement string), or "".
_ConformDF_LastBurst() {
	global _Stub_RecordedSends
	if (_Stub_RecordedSends.Length == 0)
		return ""
	return _Stub_RecordedSends[_Stub_RecordedSends.Length].args[1]
}

; Fire the "ct<star>" conform trigger once through the production path, returning
; the resulting send burst. Assumes HSE state is ready to accept "ct<star>".
_ConformDF_FireCtStar(Star) {
	HSE_FeedChar("c")
	HSE_FeedChar("t")
	M := HSE_FeedChar(Star)
	Assert(M != "", "conform trigger must match (hseBuf carry-over broken otherwise)")
	HSE_DispatchMatch(M, "")
	return _ConformDF_LastBurst()
}

; Angle 1 -- deferred release simulated. Both fires must emit the replacement.
TestConformDF_RepeatFiresWhenReleased() {
	global HSE_Suppressed, HSE_Buffer
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := Chr(0x2605)
	CreateCaseSensitiveHotstrings("*?", "ct" . Star, "cetait")

	HSE_FeedReset(true)
	B1 := _ConformDF_FireCtStar(Star)
	Assert(InStr(B1, "cetait") > 0,
		"FIRE 1 must emit the replacement (burst='" B1 "', bufAfter='" HSE_Buffer "')")

	; Production clears suppression ~60 ms later via a deferred timer; simulate it
	; so this synchronous test mirrors the real post-burst state.
	HSE_Suppressed := false

	N := _Stub_RecordedSends.Length
	B2 := _ConformDF_FireCtStar(Star)
	Assert(_Stub_RecordedSends.Length > N,
		"FIRE 2 must produce a send -- the trigger must expand AGAIN, not just once "
		. "(bufAfter1='" HSE_Buffer "')")
	Assert(InStr(B2, "cetait") > 0, "FIRE 2 must emit the replacement again (burst='" B2 "')")
}
Test("HSE conform: magic-key trigger expands on every fire, not just the first",
	TestConformDF_RepeatFiresWhenReleased)

; Angle 2 -- real deferred -60 ms release. After the first dispatch arms it, a
; Sleep pumps the message loop so it fires; HSE_Suppressed must then be cleared.
TestConformDF_DeferredReleaseClearsSuppression() {
	global HSE_Suppressed, HSE_Buffer
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := Chr(0x2605)
	CreateCaseSensitiveHotstrings("*?", "ct" . Star, "cetait")

	HSE_FeedReset(true)
	_ConformDF_FireCtStar(Star)
	Assert(HSE_Suppressed == true, "dispatch must suppress feeds during the burst")

	; Pump the loop past HSE_SUPPRESS_RELEASE_DELAY_MS (60 ms) so the armed
	; release timer actually runs.
	Sleep(150)
	Assert(HSE_Suppressed == false,
		"the deferred -60 ms release must clear HSE_Suppressed (still set => the "
		. "trigger would never feed/match again, the reported 'fires once' symptom)")

	N := _Stub_RecordedSends.Length
	B2 := _ConformDF_FireCtStar(Star)
	Assert(_Stub_RecordedSends.Length > N,
		"after the real release the trigger must expand again (bufAfter1='" HSE_Buffer "')")
	Assert(InStr(B2, "cetait") > 0, "second fire after real release must emit the replacement")
}
Test("HSE conform: deferred -60ms release clears suppression so the trigger re-fires",
	TestConformDF_DeferredReleaseClearsSuppression)




; ==========================================================
; ==========================================================
; ======= 2/ Time-activation honours the typed case ========
; ==========================================================
; ==========================================================

; ROOT CAUSE of the user-reported "ct* expands a few times then stops on UPPER":
; faf39a7bb collapsed the explicit lower/UPPER/Title variants (each with its own
; correctly-cased PrevCharKey: "t" for lower/Title, "T" for UPPER) into ONE conform
; spec carrying the LOWERCASE canonical PrevCharKey ("t"). The time-activation gate
; keys off LastSentCharacterKeyTime, which UpdateLastSentCharacter stores by the
; char AS TYPED. Typing the trigger in UPPER refreshes "T", never "t" -- so the
; lowercase key-time goes stale and the gate wrongly expires the UPPER trigger
; ~2 s later. The gate must use the prev char AS TYPED for conform specs.

; Fails before the fix (gate reads stale lowercase "t" -> expired -> no send),
; passes after (gate reads the typed "T" -> fresh -> fires).
TestConformTA_UpperHonoursTypedChar() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := Chr(0x2605)
	CreateCaseSensitiveHotstrings("*?", "ct" . Star, "cetait", Map("TimeActivationSeconds", 2))

	; Lowercase "t" went stale > 2 s ago; the UPPER "T" the user actually typed is
	; fresh. The pre-fix gate read "t" (stale) and refused to fire.
	LastSentCharacterKeyTime["t"] := A_TickCount - 5000
	LastSentCharacterKeyTime["T"] := A_TickCount

	HSE_FeedReset(true)
	HSE_FeedChar("C")
	HSE_FeedChar("T")
	M := HSE_FeedChar(Star)
	Assert(M != "", "UPPER trigger must MATCH the case-insensitive conform spec")
	N := _Stub_RecordedSends.Length
	HSE_DispatchMatch(M, "")
	Assert(_Stub_RecordedSends.Length > N,
		"UPPER conform must FIRE: time-activation must key off the typed char 'T', "
		. "not the canonical lowercase 't' (stale) -- the once-then-never regression")
}
Test("HSE conform: UPPER trigger uses the typed char (not lowercase) for time-activation",
	TestConformTA_UpperHonoursTypedChar)

; The fix must NOT defeat time-activation: when the char AS TYPED is genuinely
; stale, the trigger must still refuse to fire. (Passes before and after the fix.)
TestConformTA_StillExpiresWhenTypedCharStale() {
	global LastSentCharacterKeyTime
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := Chr(0x2605)
	CreateCaseSensitiveHotstrings("*?", "ct" . Star, "cetait", Map("TimeActivationSeconds", 2))

	LastSentCharacterKeyTime["t"] := A_TickCount - 5000
	LastSentCharacterKeyTime["T"] := A_TickCount - 5000  ; typed char ALSO stale

	HSE_FeedReset(true)
	HSE_FeedChar("C")
	HSE_FeedChar("T")
	M := HSE_FeedChar(Star)
	N := _Stub_RecordedSends.Length
	HSE_DispatchMatch(M, "")
	Assert(_Stub_RecordedSends.Length == N,
		"a genuinely-expired activation (typed char stale too) must STILL block the fire")
}
Test("HSE conform: time-activation still expires when the typed char is stale",
	TestConformTA_StillExpiresWhenTypedCharStale)
