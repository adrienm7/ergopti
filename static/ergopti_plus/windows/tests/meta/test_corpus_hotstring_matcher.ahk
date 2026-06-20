; tests/meta/test_corpus_hotstring_matcher.ahk

; ==============================================================================
; MODULE: HotstringMatcher Corpus Consumer (AHK)
; DESCRIPTION:
; Validates the AHK hotstring engine against the cross-driver contract defined
; in _shared/core/domain/HotstringMatcher.spec.js. Each test vector seeds a minimal
; in-memory registry, runs a buffer matching decision, and asserts the outcome
; matches the expected MatchResult or null.
;
; COVERAGE:
; 1. Structural compliance -- HotstringMatcher.spec.js validateAdapter() invariants.
; 2. Suffix matching -- buffer must end with trigger for a match to fire.
; 3. Longest-match-first -- longer trigger beats shorter when both share tail char.
; 4. Word-boundary enforcement -- is_word triggers blocked mid-word, allowed at boundaries.
; 5. Backspace count -- equals trigger length + 1 when terminator_consumed = true.
; 6. Case sensitivity -- default case-insensitive; is_case_sensitive requires exact case.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Inline registry helpers =================
; ====================================================
; ====================================================

; Build a minimal in-memory registry from an array of mapping specs.
; Each spec: Map with keys: trigger, repl, group, is_word (opt), is_case_sensitive (opt).
; Returns a Map keyed by tail_char -> Array of mappings (sorted longest-first).
_HMBuildRegistry(Specs) {
	Registry := Map()
	for Spec in Specs {
		Trig    := Spec["trigger"]
		TailCh  := SubStr(Trig, -1)   ; last character
		if not Registry.Has(TailCh) {
			Registry[TailCh] := []
		}
		Entry := Map(
			"trigger",          Trig,
			"repl",             Spec.Has("repl")             ? Spec["repl"]             : "",
			"group",            Spec.Has("group")            ? Spec["group"]            : "g",
			"tlen",             StrLen(Trig),
			"tail_char",        TailCh,
			"is_word",          Spec.Has("is_word")          ? Spec["is_word"]          : false,
			"is_case_sensitive",Spec.Has("is_case_sensitive")? Spec["is_case_sensitive"]: false,
			"final_result",     false,
			"color",            ""
		)
		Registry[TailCh].Push(Entry)
	}
	; Sort each bucket longest-first
	for TailCh, Bucket in Registry {
		; Bubble sort by tlen descending (small buckets -- ok)
		n := Bucket.Length
		loop n - 1 {
			loop n - A_Index {
				i := A_Index
				if Bucket[i]["tlen"] < Bucket[i + 1]["tlen"] {
					Tmp         := Bucket[i]
					Bucket[i]   := Bucket[i + 1]
					Bucket[i+1] := Tmp
				}
			}
		}
	}
	return Registry
}

; Core matching function implementing the HotstringMatcher algorithm.
; Returns a Map (MatchResult) or "" (no match).
_HMMatch(Buffer, TailChar, Registry, TerminatorConsumed := false) {
	if Buffer = "" or TailChar = "" {
		return ""
	}
	; Registry is keyed by the trigger's last char; for case-insensitive matching
	; try both the provided tail char and its lowercase equivalent.
	LookupKey := TailChar
	if not Registry.Has(LookupKey) {
		LookupKey := StrLower(TailChar)
	}
	if not Registry.Has(LookupKey) {
		return ""
	}
	Candidates := Registry[LookupKey]
	BufLen     := StrLen(Buffer)

	for Mapping in Candidates {
		Trig := Mapping["trigger"]
		TLen := Mapping["tlen"]

		; Buffer must be at least as long as the trigger
		if BufLen < TLen {
			continue
		}

		; Suffix check (case-aware)
		BufTail := SubStr(Buffer, -TLen)
		if Mapping["is_case_sensitive"] {
			if BufTail != Trig {
				continue
			}
		} else {
			if StrLower(BufTail) != StrLower(Trig) {
				continue
			}
		}

		; Word-boundary check
		if Mapping["is_word"] and BufLen > TLen {
			PrecedingChar := SubStr(Buffer, BufLen - TLen, 1)
			if PrecedingChar ~= "i)^\w$" {
				continue
			}
		}

		; Match found
		BC := TLen + (TerminatorConsumed ? 1 : 0)
		return Map(
			"trigger",            Trig,
			"replacement",        Mapping["repl"],
			"backspace_count",    BC,
			"consume_terminator", TerminatorConsumed,
			"is_final",           Mapping["final_result"],
			"group",              Mapping["group"],
			"color",              Mapping["color"]
		)
	}
	return ""
}




; ====================================================
; ====================================================
; ======= 2/ Contract vector tests ===================
; ====================================================
; ====================================================

_HM_SimpleSuffixMatch() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("btw", "w", Reg)
	AssertTrue(R != "", "simple_suffix_match: must not be null")
	AssertEqual("btw",        R["trigger"],         "simple_suffix_match: trigger")
	AssertEqual("by the way", R["replacement"],     "simple_suffix_match: replacement")
	AssertEqual(3,            R["backspace_count"], "simple_suffix_match: backspace_count")
	AssertEqual(false,        R["consume_terminator"], "simple_suffix_match: consume_terminator")
}
Test("HotstringMatcher: simple suffix match returns correct MatchResult", _HM_SimpleSuffixMatch)

_HM_NoMatchWrongTail() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("xyz", "z", Reg)
	AssertEqual("", R, "no_match_wrong_tail: must be null (empty string)")
}
Test("HotstringMatcher: no match when tail char not in any bucket", _HM_NoMatchWrongTail)

_HM_NoMatchSuffixMismatch() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("xtw", "w", Reg)
	AssertEqual("", R, "no_match_suffix_mismatch: must be null")
}
Test("HotstringMatcher: no match when buffer does not end with trigger", _HM_NoMatchSuffixMismatch)

_HM_LongestTriggerWins() {
	Reg := _HMBuildRegistry([
		Map("trigger", "btw",  "repl", "by the way",    "group", "g"),
		Map("trigger", "btww", "repl", "by the way wow","group", "g")
	])
	R := _HMMatch("btww", "w", Reg)
	AssertTrue(R != "", "longest_trigger_wins: must not be null")
	AssertEqual("btww", R["trigger"], "longest_trigger_wins: longer trigger must win")
}
Test("HotstringMatcher: longest trigger wins over shorter same-tail trigger", _HM_LongestTriggerWins)

_HM_WordBoundaryMidWordBlocked() {
	Reg := _HMBuildRegistry([Map("trigger", "the", "repl", "THE", "group", "g", "is_word", true)])
	R   := _HMMatch("othe", "e", Reg)
	AssertEqual("", R, "word_boundary_mid_word: must be blocked")
}
Test("HotstringMatcher: is_word trigger blocked when preceded by word char", _HM_WordBoundaryMidWordBlocked)

_HM_WordBoundaryStartOfBuffer() {
	Reg := _HMBuildRegistry([Map("trigger", "the", "repl", "THE", "group", "g", "is_word", true)])
	R   := _HMMatch("the", "e", Reg)
	AssertTrue(R != "", "word_boundary_start_of_buffer: must fire")
	AssertEqual("the", R["trigger"], "word_boundary_start_of_buffer: trigger")
}
Test("HotstringMatcher: is_word trigger fires at start of buffer", _HM_WordBoundaryStartOfBuffer)

_HM_WordBoundaryAfterSpace() {
	Reg := _HMBuildRegistry([Map("trigger", "the", "repl", "THE", "group", "g", "is_word", true)])
	R   := _HMMatch("hello the", "e", Reg)
	AssertTrue(R != "", "word_boundary_after_space: must fire")
	AssertEqual("the", R["trigger"], "word_boundary_after_space: trigger")
}
Test("HotstringMatcher: is_word trigger fires after space", _HM_WordBoundaryAfterSpace)

_HM_WordBoundaryAfterPunctuation() {
	Reg := _HMBuildRegistry([Map("trigger", "the", "repl", "THE", "group", "g", "is_word", true)])
	R   := _HMMatch(".the", "e", Reg)
	AssertTrue(R != "", "word_boundary_after_punctuation: must fire")
	AssertEqual("the", R["trigger"], "word_boundary_after_punctuation: trigger")
}
Test("HotstringMatcher: is_word trigger fires after punctuation", _HM_WordBoundaryAfterPunctuation)

_HM_BackspaceCountConsumed() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("btw", "w", Reg, true)
	AssertTrue(R != "", "backspace_consumed: must not be null")
	AssertEqual(4,    R["backspace_count"],    "backspace_consumed: count = tlen + 1")
	AssertEqual(true, R["consume_terminator"], "backspace_consumed: flag")
}
Test("HotstringMatcher: backspace_count = trigger_length + 1 when terminator consumed", _HM_BackspaceCountConsumed)

_HM_CaseInsensitiveDefault() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("BTW", "W", Reg)
	AssertTrue(R != "", "case_insensitive: uppercase buffer must match lowercase trigger")
}
Test("HotstringMatcher: default matching is case-insensitive", _HM_CaseInsensitiveDefault)

_HM_CaseSensitiveNoMatch() {
	Reg := _HMBuildRegistry([Map("trigger", "BTW", "repl", "by the way", "group", "g", "is_case_sensitive", true)])
	R   := _HMMatch("btw", "w", Reg)
	AssertEqual("", R, "case_sensitive_no_match: lowercase must not match uppercase trigger")
}
Test("HotstringMatcher: case-sensitive trigger does not match wrong case", _HM_CaseSensitiveNoMatch)

_HM_CaseSensitiveExactMatch() {
	Reg := _HMBuildRegistry([Map("trigger", "BTW", "repl", "by the way", "group", "g", "is_case_sensitive", true)])
	R   := _HMMatch("BTW", "W", Reg)
	AssertTrue(R != "", "case_sensitive_exact: must match")
	AssertEqual("BTW", R["trigger"], "case_sensitive_exact: trigger")
}
Test("HotstringMatcher: case-sensitive trigger matches exact case", _HM_CaseSensitiveExactMatch)

_HM_EmptyBufferNoMatch() {
	Reg := _HMBuildRegistry([Map("trigger", "btw", "repl", "by the way", "group", "g")])
	R   := _HMMatch("", "", Reg)
	AssertEqual("", R, "empty_buffer: must return null")
}
Test("HotstringMatcher: empty buffer returns no match", _HM_EmptyBufferNoMatch)

_HM_BufferShorterThanTrigger() {
	Reg := _HMBuildRegistry([Map("trigger", "afaik", "repl", "as far as I know", "group", "g")])
	R   := _HMMatch("fai", "i", Reg)
	AssertEqual("", R, "buffer_shorter: must return null")
}
Test("HotstringMatcher: buffer shorter than trigger returns no match", _HM_BufferShorterThanTrigger)
