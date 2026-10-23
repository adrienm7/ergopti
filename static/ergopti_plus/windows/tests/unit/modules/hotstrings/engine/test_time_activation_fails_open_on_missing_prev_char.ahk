; tests/unit/modules/hotstrings/engine/test_time_activation_fails_open_on_missing_prev_char.ahk

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





; =========================================================
; =========================================================
; ======= Expansion-delay corpus (time-gate-corpus) =======
; =========================================================
; =========================================================

; Replays _shared/tests/corpus/hotstrings/time_gate_vectors.json through the real
; engine. The expansion delay is the time between the LAST LETTER OF THE INPUT
; and the EXPANDER: the magic key when the trigger ends with it, else the end
; character that completes the trigger (the press, for the Space tap-hold). The
; reference is therefore the character typed immediately before the expander.
; Measured from the penultimate letter, `pr` + Space was gated on the p -> r gap
; as well and a normal-speed press missed a 0.5 s delay. macOS replays the same
; vectors in tests/unit/modules/keymap/test_time_gate_corpus.lua and Linux in
; test_shared_hotstring_engine.lua.

_TGC_Vectors() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\hotstrings\time_gate_vectors.json"
	return JsonParse(FileRead(Path, "UTF-8"))["vectors"]
}

_TGC_Replay(Vector) {
	global LastSentCharacterKeyTime, HSE_LastEndChar, ScriptInformation
	Delay := Vector["delay_s"]
	Opts := Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON, "TimeActivationSeconds", Delay)
	Trigger := Vector["trigger"]
	Base := A_TickCount
	Typed := Vector["typed"]
	LastSentCharacterKeyTime := Map()
	Missing := Vector.Has("reference_time_missing") && Vector["reference_time_missing"]
	Reference := Vector["reference_char"]
	for Key in Typed {
		if (Missing && Key["char"] == Reference)
			continue
		LastSentCharacterKeyTime[Key["char"]] := Base + Key["down_ms"]
	}
	Expander := Vector["expander"]
	GateTick := Base + Expander["down_ms"]

	if !Missing
		AssertEqual(Vector["elapsed_ms"], Expander["down_ms"] - (LastSentCharacterKeyTime[Reference] - Base),
			Vector["id"] . ": the vector's elapsed time is expander minus reference character")
	AssertEqual(Reference, Typed[Typed.Length]["char"],
		Vector["id"] . ": the reference is the character typed immediately before the expander")
	AssertEqual(StrLower(Reference), StrLower(HSE_TimeGateReferenceChar(Trigger, Vector["ends_with_magic"])),
		Vector["id"] . ": the engine picks the same reference character")

	if Vector.Has("case_conform") && Vector["case_conform"]
		CreateCaseSensitiveHotstrings("*", Trigger, "out", Opts)
	else
		CreateHotstring(Vector["ends_with_magic"] ? "*" : "", Trigger, "out", Opts)
	Text := Vector.Has("typed_text") ? Vector["typed_text"] : ""
	if (Text == "") {
		for Key in Typed
			Text .= Key["char"]
		Text .= Expander["char"]
	}
	Match := ""
	for Char in StrSplit(Text)
		Match := HSE_FeedChar(Char, true)
	AssertTrue(IsObject(Match), Vector["id"] . ": the typed text must complete the trigger")
	Effect := 0
	Fired := HSE_DispatchMatch(Match, HSE_LastEndChar, &Effect, false, unset, GateTick)
	AssertEqual(Vector["fires"] ? true : false, Fired ? true : false,
		Vector["id"] . ": the delay gate verdict")
}

_TGC_Run(Vector) {
	_HOF_Run(_TGC_Replay.Bind(Vector))
}

for _TGC_Vector in _TGC_Vectors()
	Test("time gate corpus: " . _TGC_Vector["id"] . " (time-gate-corpus)", _TGC_Run.Bind(_TGC_Vector))
