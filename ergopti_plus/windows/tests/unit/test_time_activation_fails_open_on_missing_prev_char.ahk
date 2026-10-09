; tests/unit/test_time_activation_fails_open_on_missing_prev_char.ahk

; ==============================================================================
; MODULE: IsTimeActivationExpired Fail-Closed Regression Test
; DESCRIPTION:
; Behavioral regression test for finding
; time-activation-fails-open-on-missing-prev-char.
;
; A time-activation gate exists to SUPPRESS an expansion when its trigger is
; typed too slowly. Before the fix, IsTimeActivationExpired defaulted an
; unknown previous-char timestamp to "now", so a missing/pruned timestamp was
; treated as "just typed" and the gate failed OPEN -- letting a deliberately
; paused trigger (e.g. comma, long pause, vowel) fire anyway. After a pause
; the prior char's timestamp may have been pruned by
; LAST_SENT_KEY_TIME_MAX_AGE_MS, so this is the exact case the delay was
; configured to prevent.
;
; The fix makes the gate fail CLOSED: a missing timestamp with a positive
; activation window is reported as expired (True). IsTimeActivationExpired is
; defined in infra/hotstrings/hotstring_engine.ahk, which the headless runner
; #Includes, and it is a pure function (reads LastSentCharacterKeyTime, calls
; A_TickCount) with no OS/COM/hotkey side effects -- so this is a direct
; behavioral test, not a meta-static scan.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Fail-closed regression assertions =======
; ====================================================
; ====================================================

; Missing timestamp + positive window must FAIL CLOSED (expired = True).
; This is the inverted assertion that fails before the fix (old code returned
; False because it defaulted the unknown timestamp to "now").
_TimeActFailClosed_MissingKeyIsExpired() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map()
	AssertTrue(IsTimeActivationExpired("a", 1),
		"missing prev-char timestamp must be treated as EXPIRED (fail closed) -- "
		. "a pruned timestamp after a pause must not let a slow-typed trigger fire")
}
Test("hotstring_engine: IsTimeActivationExpired fails closed on missing prev char (time-activation-fails-open-on-missing-prev-char)",
	_TimeActFailClosed_MissingKeyIsExpired)

; Positive case: a freshly recorded timestamp inside the window must FIRE
; (not expired = False). Pins that the fail-closed change did not break the
; normal "typed recently -> activate" path.
_TimeActFailClosed_FreshKeyFires() {
	global LastSentCharacterKeyTime
	LastSentCharacterKeyTime := Map("a", A_TickCount)
	AssertFalse(IsTimeActivationExpired("a", 1),
		"a just-recorded prev-char timestamp inside the window must NOT be expired")
}
Test("hotstring_engine: IsTimeActivationExpired still fires for a fresh prev char (time-activation-fails-open-on-missing-prev-char)",
	_TimeActFailClosed_FreshKeyFires)

_TimeActFailClosed_UnrepresentableDurationExpires() {
	global LastSentCharacterKeyTime
	AssertTrue(TickTryDurationMsFromSeconds(4294967.295, &MaximumMs),
		"the exact unsigned 32-bit millisecond maximum must remain representable")
	AssertEqual(0xFFFFFFFF, MaximumMs)
	AssertFalse(TickTryDurationMsFromSeconds(4294967.296, &MaximumMs),
		"one millisecond beyond the elapsed-tick domain must be rejected")
	LastSentCharacterKeyTime := Map("a", A_TickCount)
	AssertTrue(IsTimeActivationExpired("a", 4294968),
		"a gate wider than TickElapsed can represent must fail closed")
	Spec := {
		Replacement: "x",
		TimeActivationSeconds: 4294968,
		PrevCharKey: "a",
		Length: 1
	}
	AssertEqual("", _HSE_PrepareDispatchDecision(Spec, "a", ""),
		"the canonical preview/fire decision must reject an unrepresentable gate")
}
Test("hotstring_engine: activation duration must fit the elapsed-tick domain",
	_TimeActFailClosed_UnrepresentableDurationExpires)
