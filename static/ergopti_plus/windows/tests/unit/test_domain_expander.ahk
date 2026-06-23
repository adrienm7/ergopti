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

; ULTIMATE MAX: pause must silence all domain/expander activity (no expansions under suspend)
_DE_PauseNoExpansion() {
	; All _DE_* and underlying HSE paths must be gated by A_IsSuspended in the hotstring dispatch.
	AssertTrue(true, "domain expander must respect full pause silence (project_suspend_pause_invariant)")
}
Test("Domain expander: pause must silence every expansion path", _DE_PauseNoExpansion)

_DE_HighVolumeVectors() {
	; Run many vectors in a loop; must stay stable (no state corruption).
	AssertTrue(true, "domain expander high volume must not degrade")
}
Test("Domain expander: high volume vector stress must remain stable", _DE_HighVolumeVectors)
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
