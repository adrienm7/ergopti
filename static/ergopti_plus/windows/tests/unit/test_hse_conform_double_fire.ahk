; tests/unit/test_hse_conform_double_fire.ahk

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
;   2. Real timer: let the production -60 ms SetTimer((*) => PrefixWatcherSuppress(false))
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

; Angle 2 -- real deferred -60 ms release. After the first dispatch arms the
; prefix render guard, a Sleep pumps the message loop so it clears.
TestConformDF_DeferredReleaseClearsSuppression() {
	global _PrefixWatcherSuppressed, HSE_Buffer
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := ScriptInformation["MagicKey"]
	CreateCaseSensitiveHotstrings("*?", "ct" . Star, "cetait")

	HSE_FeedReset(true)
	_ConformDF_FireCtStar(Star)
	Assert(_PrefixWatcherSuppressed > 0, "dispatch must hold the prefix render guard during the burst")

	; Pump the loop past HSE_SUPPRESS_RELEASE_DELAY_MS (60 ms) so the armed
	; release timer actually runs. 500 ms gives ~8× headroom over the 60 ms
	; timer — enough for CI schedulers with variable thread wake latency.

	Sleep 500
	Assert(_PrefixWatcherSuppressed == 0, "prefix render guard should be cleared after 60ms timer")
	
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




; =========================================
; =========================================
; ======= 2/ Atomic send (anti-interleave) =
; =========================================
; =========================================

; A final_result trigger must fire as ONE atomic send burst, not the old 3 separate
; SendFinalResult calls (BackSpace / Replacement / EndChar). The 3-call split left
; interleave gaps where a physical key typed mid-expansion could splice into the
; output ("trigger" + "bc" -> "outpubct"). One SendInput holds the user's
; keystrokes until after the burst, so the only correct recorded-send count is 1.
TestFinalResult_IsAtomicSingleBurst() {
	global _Stub_RecordedSends
	ResetHotstringRecorders()
	SimulateRegularApp()
	HSE_TestReset()
	Star := Chr(0x2605)
	CreateCaseSensitiveHotstrings("*", "xy" . Star, "result", Map("FinalResult", true))

	HSE_FeedReset(true)
	HSE_FeedChar("x")
	HSE_FeedChar("y")
	M := HSE_FeedChar(Star)
	Assert(M != "", "final_result trigger must match")

	N := _Stub_RecordedSends.Length
	HSE_DispatchMatch(M, "")
	Assert(_Stub_RecordedSends.Length == N + 1,
		"final_result expansion must be ONE atomic send, got "
		. (_Stub_RecordedSends.Length - N) . " send(s) -- a >1 split reopens the interleave race")

	Burst := _Stub_RecordedSends[_Stub_RecordedSends.Length].args[1]
	Assert(InStr(Burst, "{BackSpace") > 0 and InStr(Burst, "result") > 0,
		"the single burst must carry BOTH the backspaces and the replacement (burst='" . Burst . "')")
}
Test("HSE final_result: expansion is one atomic send burst, not a 3-call split",
	TestFinalResult_IsAtomicSingleBurst)




; =========================================
; =========================================
; ======= 3/ Off-hot-path metrics logging =
; =========================================
; =========================================

; The fired-hotstring metrics log must be ENQUEUED (O(1)), not run synchronously on
; the fire keystroke: a disk/app-lookup spike inside KL_LogHotstring would otherwise
; stretch OnChar past the engine's 60 ms suppress window and swallow the keys typed
; during it ("abcd"->"acd"). This pins the producer/consumer contract: enqueue grows
; the queue and arms the drain once; drain empties it and disarms so the heavy work
; is the drain's, off the keystroke path.
TestFireLog_EnqueuesAndDrainsOffHotPath() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := false
	Star := Chr(0x2605)

	_HSE_QueueFireLog("ct" . Star, "cetait", "magickey", "magickey", "text_expansion")
	_HSE_QueueFireLog("xy" . Star, "result", "magickey", "magickey", "text_expansion")
	Assert(_HSE_FireLogQueue.Length == 2,
		"two fires must enqueue two records (got " . _HSE_FireLogQueue.Length . ")")
	Assert(_HSE_FireLogScheduled == true,
		"the drain must be armed once after the first enqueue, not run inline")

	; Drain synchronously (production arms it on a timer). It must empty the queue
	; and disarm so a later fire re-arms a fresh batch. The queue is swapped out
	; BEFORE KL_LogHotstring runs, so the contract holds even if logging no-ops.
	_HSE_DrainFireLog()
	Assert(_HSE_FireLogQueue.Length == 0, "drain must empty the queue")
	Assert(_HSE_FireLogScheduled == false, "drain must disarm so the next fire re-schedules")

	; Cancel the still-pending production timer armed by the enqueues so it cannot
	; fire a stray (harmless, empty) drain during a later test that pumps messages.
	SetTimer(_HSE_DrainFireLog, 0)
}
Test("HSE fire-log: metrics are enqueued and drained off the keystroke path",
	TestFireLog_EnqueuesAndDrainsOffHotPath)
