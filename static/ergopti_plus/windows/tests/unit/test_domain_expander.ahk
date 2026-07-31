; static/ergopti_plus/windows/tests/unit/test_domain_expander.ahk

; ==============================================================================
; MODULE: Expander Domain Contract Tests (AutoHotkey)
; DESCRIPTION:
; AHK translation of the contractTestVectors() scenarios defined in
; static/ergopti_plus/_shared/core/domain/Expander.spec.js. Every vector
; exercises the same logical assertion as the JS spec so the AHK engine
; and the Hammerspoon engine are held to an identical standard.
;
; APPROACH:
; The AHK Expander is implemented by HSE_FeedChar / HSE_FindMatchAtEnd /
; HSE_DispatchMatch in hotstring_engine_main.ahk. The "decide(buffer, tailChar)"
; contract maps to: set HSE_Buffer = buffer, call HSE_FeedChar(tailChar), inspect
; HSE_LastMatch + HSE_LastEndChar. The backspace_count and consume_terminator
; fields are computed from the returned Spec.
; ==============================================================================





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; Shorthand: register an end-char trigger (no star) with optional is_word gate.
_DE_Add(Trigger, Repl, Group := "default", IsWord := false) {
	Flags := IsWord ? "" : "?"
	Meta := Map("group", Group, "Repl", Repl, "Replacement", Repl)
	return HSE_Register(Flags, Trigger, 0, Meta)
}

; Simulate "decide(buffer, tailChar)": seed the buffer then feed tailChar.
; Returns a Map with the fields the JS Expander contract defines:
;   not_null          — true when a match was found
;   replacement       — Spec.Replacement / Spec.Repl (or "" when no match)
;   backspace_count   — Spec.Length + (EndChar != "" ? 1 : 0)
;   consume_terminator — true when a star trigger consumed the tailChar
;   trigger           — matched trigger string
;   is_null           — true when no match was found
_DE_Decide(Buffer, TailChar, TermConsumed := false) {
	global HSE_Buffer, HSE_StartIsWordBoundary
	HSE_Buffer := Buffer
	; Ensure word-boundary assumption for the left edge of a seeded buffer.
	HSE_StartIsWordBoundary := true
	Spec := HSE_FeedChar(TailChar)
	if (Spec == "") {
		return Map(
			"is_null",           true,
			"not_null",          false,
			"replacement",       "",
			"backspace_count",   0,
			"consume_terminator", false,
			"trigger",           ""
		)
	}
	EndChar := HSE_LastEndChar
	Repl := ""
	if Spec.HasOwnProp("Replacement") {
		Repl := Spec.Replacement
	} else if Spec.HasOwnProp("Repl") {
		Repl := Spec.Repl
	}
	BSCount := Spec.Length + (EndChar != "" ? 1 : 0)
	return Map(
		"is_null",           false,
		"not_null",          true,
		"replacement",       Repl,
		"backspace_count",   BSCount,
		"consume_terminator", (EndChar == ""),
		"trigger",           Spec.Trigger
	)
}




; ===========================
; ===========================
; ======= 2/ simple_match ===
; ===========================
; ===========================

_DE_SimpleMatch() {
	HSE_TestReset()
	_DE_Add("btw", "by the way")
	R := _DE_Decide("btw", " ")
	AssertTrue(R["not_null"], "simple_match: result must not be null")
	AssertEqual("by the way", R["replacement"], "simple_match: replacement must be 'by the way'")
	; Trigger "btw" (3 chars) + terminator " " (1 char) = 4 backspaces total
	AssertEqual(4, R["backspace_count"], "simple_match: backspace_count must be 4 (trigger + end char)")
	AssertTrue(R["consume_terminator"] = false, "simple_match: consume_terminator must be false")
}
Test("Expander: buffer ending with trigger + terminator returns correct expansion", _DE_SimpleMatch)




; ====================================
; ====================================
; ======= 3/ no_match_returns_null ===
; ====================================
; ====================================

_DE_NoMatchReturnsNull() {
	HSE_TestReset()
	_DE_Add("btw", "by the way")
	R := _DE_Decide("xyz", " ")
	AssertTrue(R["is_null"], "no_match_returns_null: result must be null for unregistered trigger")
}
Test("Expander: buffer not ending with any trigger returns null", _DE_NoMatchReturnsNull)





; ==========================================
; ==========================================
; ======= 4/ word_boundary_respected =======
; ==========================================
; ==========================================

_DE_WordBoundaryRespected() {
	HSE_TestReset()
	; is_word=true — Flags="" means no "?" flag, so IsWord gate is applied.
	_DE_Add("the", "THE", "g", true)
	; "othe " — "the" is present but preceded by "o" (word char)
	R := _DE_Decide("othe", " ")
	AssertTrue(R["is_null"], "word_boundary_respected: must not fire mid-word")
}
Test("Expander: is_word=true trigger does not fire mid-word", _DE_WordBoundaryRespected)





; ==================================================
; ==================================================
; ======= 5/ word_boundary_fires_after_space =======
; ==================================================
; ==================================================

_DE_WordBoundaryFiresAfterSpace() {
	HSE_TestReset()
	_DE_Add("the", "THE", "g", true)
	; "hello the " — "the" preceded by a space (word boundary)
	R := _DE_Decide("hello the", " ")
	AssertTrue(R["not_null"], "word_boundary_fires_after_space: must fire when preceded by space")
	AssertEqual("THE", R["replacement"], "word_boundary_fires_after_space: replacement must be 'THE'")
}
Test("Expander: is_word=true trigger fires when preceded by a space", _DE_WordBoundaryFiresAfterSpace)




; =================================
; =================================
; ======= 6/ longest_match_wins ===
; =================================
; =================================

_DE_LongestMatchWins() {
	HSE_TestReset()
	_DE_Add("btw",  "by the way")
	_DE_Add("btww", "by the way wow")
	; Buffer "btww" — both triggers are suffixes, longer one must win.
	R := _DE_Decide("btww", " ")
	AssertTrue(R["not_null"], "longest_match_wins: a match must be found")
	AssertEqual("btww", R["trigger"], "longest_match_wins: longer trigger 'btww' must win")
}
Test("Expander: longest trigger wins when multiple triggers share a tail", _DE_LongestMatchWins)





; ======================================================
; ======================================================
; ======= 7/ backspace_count_consumed_terminator =======
; ======================================================
; ======================================================

_DE_BackspaceCountWithConsumedTerminator() {
	HSE_TestReset()
	; Star trigger (auto = true, terminator consumed by the trigger itself)
	Flags := "*?"
	Meta := Map("group", "g", "Repl", "by the way", "Replacement", "by the way")
	; "btw" + magic key star (U+2605)
	HSE_Register(Flags, "btw" . Chr(0x2605), 0, Meta)
	; Feed "btw" into the buffer then feed the magic key as the trigger char.
	R := _DE_Decide("btw", Chr(0x2605), true)
	AssertTrue(R["not_null"], "backspace_with_consumed_terminator: match must be found for star trigger")
	; Star trigger backspace_count = Length (no +1 for end char, none involved)
	AssertEqual(4, R["backspace_count"], "backspace_with_consumed_terminator: backspace_count must be 4 (btw + magic key)")
}
Test("Expander: star trigger backspace_count equals trigger length", _DE_BackspaceCountWithConsumedTerminator)




; ================================
; ================================
; ======= 8/ reset_clears_state ==
; ================================
; ================================

_DE_ResetClearsState() {
	HSE_TestReset()
	_DE_Add("btw", "by the way", "g")
	; Feed a match, then hard-reset (simulate reset()).
	_DE_Decide("btw", " ")
	HSE_HardReset()
	HSE_FeedReset(true)
	; After reset, decide on a fresh buffer — must still match (registry intact).
	R := _DE_Decide("btw", " ")
	AssertTrue(R["not_null"], "reset_clears_state: match must still fire after reset")
	AssertEqual("by the way", R["replacement"], "reset_clears_state: replacement must be 'by the way'")
}
Test("Expander: reset() clears buffer state but registry survives", _DE_ResetClearsState)





; ============================================
; ============================================
; ======= 9/ Pause silences every path =======
; ============================================
; ============================================

; These two replace a pair of placeholders that asserted AssertTrue(true) — and
; that were declared INSIDE the body of _DE_Add, so they registered only if that
; helper happened to be called. They promised "pause must silence every
; expansion path" and "high volume must remain stable" and verified neither.
;
; The prefix watcher owns its OWN InputHook, so the HookDispatcher's suspend
; guard does not cover it: each of its two entry points has to check
; A_IsSuspended itself, and it has to do so BEFORE touching the buffer — a guard
; placed after the buffer mutation still corrupts the preview state while paused.
_DE_PauseSilencesEveryEntryPoint() {
	for Name in ["_OnPrefixChar", "_OnPrefixKeyDown"] {
		Body := _DriverFuncBody(Name)
		GuardPos := InStr(Body, "if A_IsSuspended")
		Assert(GuardPos > 0,
			Name . "() must bail on A_IsSuspended — the prefix watcher runs on its own InputHook, which the HookDispatcher suspend guard does not reach")

		; The guard has to precede every buffer mutation in the function.
		for Mutation in ["_PrefixBuffer :=", "HSE_FeedChar(", "HSE_FeedBackspace(", "HSE_FeedReset("] {
			MutPos := InStr(Body, Mutation)
			if (MutPos > 0)
				Assert(GuardPos < MutPos,
					Name . "(): the A_IsSuspended guard must come before '" . Mutation . "' — a guard placed after it still mutates the buffer while paused")
		}
	}
}
Test("Expander: pause silences every expansion entry point (domain-expander-placeholders)",
	_DE_PauseSilencesEveryEntryPoint)


; Feeds the engine far more input than any single vector does, then asserts it
; still decides correctly. The placeholder this replaces claimed to be a stress
; test and ran no engine code at all.
_DE_HighVolumeStaysCorrect() {
	HSE_TestReset()
	_DE_Add("btw", "by the way")

	; 500 non-matching decisions, each seeding a fresh buffer, to shake out state
	; that leaks between calls.
	Loop 500 {
		R := _DE_Decide("noise" . A_Index, " ")
		if !R["is_null"]
			Assert(false, "high volume: decision " . A_Index . " matched a buffer that ends with no trigger")
	}

	; The registry and the matcher must be exactly as good as on the first call.
	Final := _DE_Decide("btw", " ")
	AssertTrue(Final["not_null"], "high volume: the trigger must still match after 500 decisions")
	AssertEqual("by the way", Final["replacement"], "high volume: the replacement must be unchanged")
	AssertEqual(4, Final["backspace_count"], "high volume: the backspace arithmetic must be unchanged")
}
Test("Expander: 500 decisions leave the matcher correct (domain-expander-placeholders)",
	_DE_HighVolumeStaysCorrect)
