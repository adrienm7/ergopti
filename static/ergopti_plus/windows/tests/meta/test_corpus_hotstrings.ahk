; tests/meta/test_corpus_hotstrings.ahk

; ==============================================================================
; MODULE: Hotstring Corpus Consumer (AHK)
; DESCRIPTION:
; Loads the shared cross-driver corpus from
; _shared/tests/corpus/hotstrings/vectors.json and validates each vector
; against the AHK hotstring engine  --  ensuring matching, backspace-count
; arithmetic, and case-sensitivity invariants are consistent with the corpus.
;
; COVERAGE:
; 1. Corpus integrity  --  every vector has required fields (id, trigger, expected).
; 2. Backspace-count arithmetic  --  expected backspace_count equals
;    trigger_length (+ 1 when terminator_consumed = true).
; 3. Registry matching  --  triggers added via Hotstring() are found in the
;    engine registry; non-matching buffers are rejected.
;
; NOTE:
; The full expansion pipeline (emit dispatch, LLM bridge) is exercised by
; test_hotstrings_full.ahk. This file focuses on pure matching and arithmetic

; invariants shared with the Hammerspoon driver.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Corpus file loading =============
; ============================================
; ============================================

_CorpusHS_Root() {
	; Resolve the corpus path relative to the main script's directory (tests/).
	; A_ScriptDir is always the dir of run_all.ahk, i.e. windows/tests/.
	; Two levels up from tests/ reaches ergopti_plus/ where _shared/ lives.
	return A_ScriptDir . "\..\..\_shared\tests\corpus\hotstrings\vectors.json"
}

; THROWS when the corpus is missing or malformed. It used to return "", and
; every consumer below opened with `if Corpus = "" { return }` — so moving or
; breaking the corpus produced ONE red (the readability test) and EIGHT silent
; greens. A cross-driver contract that can be deleted without the suite noticing
; is not a contract.
_CorpusHS_Load() {
	Path := _CorpusHS_Root()
	if not FileExist(Path)
		throw Error("hotstring corpus not found at '" . Path . "' — the shared vectors are a cross-driver contract; a missing corpus must fail this suite, never skip it")
	return FileRead(Path, "UTF-8")
}

_CorpusHS_Parse() {
	Corpus := JsonParse(_CorpusHS_Load())
	if (Corpus = "")
		throw Error("hotstring corpus at '" . _CorpusHS_Root() . "' did not parse into an object — a malformed corpus must fail this suite, never skip it")
	return Corpus
}




; ============================================
; ============================================
; ======= 2/ Corpus integrity tests ==========
; ============================================
; ============================================

_CorpusHS_FileIsReadableAndParseable() {
	; Readability and parseability are now enforced by the loader itself, which
	; throws with the resolved path — asserting them again here would only
	; restate what already cannot be false.
	Corpus := _CorpusHS_Parse()
	AssertTrue(Corpus.Has("vectors"), "corpus must have a vectors key")
	AssertTrue(Corpus["vectors"].Length > 0, "corpus must contain at least one vector")
}
Test("hotstring corpus  --  corpus file is readable and parseable", _CorpusHS_FileIsReadableAndParseable)

_CorpusHS_EveryVectorHasRequiredFields() {
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		AssertTrue(Vec.Has("id") and Vec["id"] != "",
			"vector missing id")
		AssertTrue(Vec.Has("trigger") and Vec["trigger"] != "",
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing trigger")
		AssertTrue(Vec.Has("expected"),
			"vector '" . (Vec.Has("id") ? Vec["id"] : "?") . "' missing expected")
	}
}
Test("hotstring corpus  --  every vector has required fields: id, trigger, expected", _CorpusHS_EveryVectorHasRequiredFields)

_CorpusHS_BackspaceCountFormula() {
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		if not Expected.Has("backspace_count") {
			continue
		}
		TrigLen    := StrLen(Vec["trigger"])
		Consumed   := Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true
		ExpectedBC := TrigLen + (Consumed ? 1 : 0)
		AssertEqual(ExpectedBC, Expected["backspace_count"],
			"vector '" . Vec["id"] . "' backspace_count mismatch")
	}
}
Test("hotstring corpus  --  backspace_count equals trigger_length [+ 1 if consumed]", _CorpusHS_BackspaceCountFormula)




; ============================================
; ============================================
; ======= 3/ Registry matching tests =========
; ============================================
; ============================================

_CorpusHS_TriggerLengthMatchesBuffer() {
	; Validates that every matched vector has a buffer that ends with the trigger  -- 
	; this is required for a real hotstring match to fire in AHK.
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : Vec["trigger"]
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen)
		AssertEqual(Trigger, BufTail,
			"vector '" . Vec["id"] . "': buffer must end with trigger for matched=true")
	}
}
Test("hotstring corpus  --  matched vectors: buffer ends with trigger", _CorpusHS_TriggerLengthMatchesBuffer)

_CorpusHS_NonMatchedBuffersDontEndWithTrigger() {
	; Validates that unmatched non-word vectors have buffers that do not end
	; with the trigger (word-boundary blocking is tested elsewhere).
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = false) {
			continue
		}
		; Skip word-boundary vectors  --  their buffer may end with the trigger
		; but the word-boundary rule blocks the expansion.
		if Vec.Has("is_word") and Vec["is_word"] = true {
			continue
		}
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : ""
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		; Skip triggers longer than the rolling window  --  second legitimate
		; reason a non-matched buffer ends with its trigger, and the one this
		; enumeration was missing. The buffer holds only the last
		; HSE_MAX_BUFFER_LEN codepoints, so a longer trigger is never present in
		; full no matter what the vector's buffer text says. Read from the engine
		; constant rather than a literal, so raising the cap moves both together.
		if (TLen > HSE_MAX_BUFFER_LEN) {
			continue
		}
		if Buf = "" {
			continue
		}
		BufTail := SubStr(Buf, -TLen)
		; Use !== (case-sensitive) so "btw" and "BTW" are treated as distinct
		AssertTrue(BufTail !== Trigger,
			"vector '" . Vec["id"] . "': non-matched buffer must not end with trigger")
	}
}
Test("hotstring corpus  --  non-matched vectors: buffer does not end with trigger", _CorpusHS_NonMatchedBuffersDontEndWithTrigger)

; These two used to sit at the top of the file as AssertTrue(true, "…") with the
; invariant written only in the message — and above the corpus load, so they
; could not have read a vector even if they had wanted to. They are here now,
; where the corpus exists, and they assert instead of assert nothing.

_CorpusHS_ArithmeticIsIndependentOfSuspendState() {
	; The corpus is a pure data contract: backspace_count is derived from the
	; trigger and the terminator, never from runtime state. If any of that
	; arithmetic ever consulted A_IsSuspended, a hotstring would delete a
	; different number of characters after a pause than before one — the worst
	; possible failure, because it silently eats the user's text.
	for Fn in ["IsTimeActivationExpired", "GenerateUppercaseVariants"] {
		Body := _DriverFuncBody(Fn)
		Assert(InStr(Body, "A_IsSuspended") == 0,
			Fn . "() must not read A_IsSuspended — corpus arithmetic has to hold identically "
			. "whether or not the driver is paused")
	}

	; And the vectors themselves must be self-consistent: every matched vector's
	; backspace_count equals the trigger length, plus one when the terminator is
	; consumed. Recomputed here rather than trusted.
	Checked := 0
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true)
			continue
		if !Expected.Has("backspace_count")
			continue
		Want := StrLen(Vec["trigger"])
		if (Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true)
			Want += 1
		AssertEqual(Want, Expected["backspace_count"],
			"vector '" . Vec["id"] . "': backspace_count must be trigger length"
			. " (+1 when the terminator is consumed)")
		Checked += 1
	}
	Assert(Checked > 0, "no matched vector carried a backspace_count — the corpus shape changed")
}
Test("hotstring corpus  --  backspace arithmetic holds, and reads no suspend state",
	_CorpusHS_ArithmeticIsIndependentOfSuspendState)

_CorpusHS_EveryVectorResolvesADelay() {
	; Every corpus trigger belongs to a category, and every category must resolve
	; a delay through the section > file > global cascade. A vector whose category
	; resolved to an empty delay would expand with no activation window at all.
	Checked := 0
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		R := HotstringsResolve("rolls", Vec["id"])
		Assert(R.Delay != "", "vector '" . Vec["id"] . "': resolution must yield a delay, never an empty one")
		Assert(R.Delay >= 0, "vector '" . Vec["id"] . "': a negative activation delay is not a window")
		Checked += 1
	}
	Assert(Checked > 0, "the corpus produced no vectors — the shared contract file is empty or unreadable")
}
Test("hotstring corpus  --  every vector's category resolves a usable delay",
	_CorpusHS_EveryVectorResolvesADelay)

_CorpusHS_Utf8BackspaceCountUsesCodepoints() {
	; For UTF-8 triggers the corpus records backspace_count as the codepoint count,
	; not the byte count. AHK v2 StrLen() counts UTF-16 code units (which collapses
	; to codepoints for the BMP characters used in our triggers), so this test pins
	; that StrLen equals the corpus backspace_count for all matched vectors --
	; catching any future drift if AHK changes its string model.
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		Expected := Vec["expected"]
		if not (Expected.Has("matched") and Expected["matched"] = true) {
			continue
		}
		if not Expected.Has("backspace_count") {
			continue
		}
		Trigger    := Vec["trigger"]
		Consumed   := Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true
		TrigLen    := StrLen(Trigger)
		ExpectedBC := TrigLen + (Consumed ? 1 : 0)
		AssertEqual(ExpectedBC, Expected["backspace_count"],
			"vector '" . Vec["id"] . "': StrLen-based backspace_count must equal corpus value")
	}
}
Test("hotstring corpus  --  UTF-8 triggers: StrLen-based backspace_count matches corpus", _CorpusHS_Utf8BackspaceCountUsesCodepoints)

_CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag() {
	; Validates that case_sensitive=true vectors correctly reflect whether the
	; buffer casing matches the trigger casing.
	Corpus := _CorpusHS_Parse()
	for Vec in Corpus["vectors"] {
		if not (Vec.Has("is_case_sensitive") and Vec["is_case_sensitive"] = true) {
			continue
		}
		Expected := Vec["expected"]
		Buf     := Vec.Has("buffer") ? Vec["buffer"] : ""
		Trigger := Vec["trigger"]
		TLen    := StrLen(Trigger)
		BufTail := SubStr(Buf, -TLen)
		; Exact (case-sensitive) match — use == for case-sensitive comparison
		ActualMatch := (BufTail == Trigger)
		ExpMatch    := Expected.Has("matched") and Expected["matched"] = true
		AssertEqual(ExpMatch, ActualMatch,
			"vector '" . Vec["id"] . "': case-sensitive match flag inconsistency")
	}
}
Test("hotstring corpus  --  case-sensitive vectors: exact match flag is consistent", _CorpusHS_CaseSensitiveVectorsHaveCorrectMatchFlag)





; ================================================
; ================================================
; ======= 4/ Collision priority resolution =======
; ================================================
; ================================================

; Drives the shared collision corpus through the REAL engine: each mapping is
; registered under its own source group (so cross-source same-trigger specs
; compete instead of one shadowing the other), then the buffer is fed one char at
; a time. The winner is whatever the final keystroke resolves — the dispatch point
; in production. star + in-word ("*?") fires immediately on the last char and
; bypasses the word-boundary gate, isolating the collision tie-break (length >
; priority > first-registered). Must agree with the Hammerspoon registry on every
; vector — the cross-driver collision contract.

_CorpusHS_CollisionVectorsArePresent() {
	Corpus := _CorpusHS_Parse()
	AssertTrue(Corpus.Has("collision_vectors"), "corpus must expose a collision_vectors array")
	AssertTrue(Corpus["collision_vectors"].Length > 0, "collision_vectors must be non-empty")
}
Test("hotstring corpus  --  collision_vectors array is present and non-empty", _CorpusHS_CollisionVectorsArePresent)

_CorpusHS_EveryCollisionVectorResolvesToExpectedWinner() {
	global HSE_PRIORITY_COMMON
	Corpus := _CorpusHS_Parse()
	AssertTrue(Corpus.Has("collision_vectors"),
		"corpus must expose collision_vectors — skipping the replay when the key is absent is how the whole tie-break contract stopped being exercised without a single red")
	for Vec in Corpus["collision_vectors"] {
		Id := Vec.Has("id") ? Vec["id"] : "?"
		HSE_TestReset()
		for Mapping in Vec["mappings"] {
			Flags := "*?" . ((Mapping.Has("is_case_sensitive") and Mapping["is_case_sensitive"] = true) ? "C" : "")
			Grp   := Mapping.Has("group")       ? Mapping["group"]       : "g"
			Prio  := Mapping.Has("priority")    ? Mapping["priority"]    : HSE_PRIORITY_COMMON
			Repl  := Mapping.Has("replacement") ? Mapping["replacement"] : ""
			HSE_Register(Flags, Mapping["trigger"], () => 0,
				Map("group", Grp, "Priority", Prio, "Repl", Repl))
		}
		HSE_FeedReset(true)
		InputBuffer := Vec["buffer"]
		Match  := ""
		loop StrLen(InputBuffer) {
			Match := HSE_FeedChar(SubStr(InputBuffer, A_Index, 1))
		}
		Expected := Vec["expected"]
		if (Expected.Has("matched") and Expected["matched"] = true) {
			AssertTrue(Match != "", "collision vector '" . Id . "': expected a match")
			AssertEqual(Expected["winner"], Match.Repl,
				"collision vector '" . Id . "': wrong winner")
		} else {
			AssertEqual("", Match, "collision vector '" . Id . "': expected no match")
		}
	}
}
Test("hotstring corpus  --  every collision vector resolves to the expected winner", _CorpusHS_EveryCollisionVectorResolvesToExpectedWinner)





; =====================================================
; =====================================================
; ======= 5/ Engine replay — all single vectors ========
; =====================================================
; =====================================================

; Replays every single vector from the vectors array through the REAL AHK engine
; (HSE_Register + HSE_FeedChar). This is the behavioral counterpart to the
; structural checks in sections 2-3: it verifies that the engine actually matches
; or rejects each vector at runtime, not just that the arithmetic is correct.
; The Linux shared-engine equivalent (test_corpus_hotstring_engine.lua) replays
; the same vectors through require('hotstring_engine').
;
; For each vector:
; 1. Register the trigger as a star-trigger with the appropriate flags (*/?/C).
; 2. Feed each character of the buffer one at a time.
; 3. Assert the final keystroke produces a match (or not) per expected.matched.
; 4. For matched vectors: assert Spec.Length (+1 if terminator_consumed) equals
;    expected.backspace_count.

_CorpusHS_EveryVectorReplayedThroughEngine() {
	Corpus := _CorpusHS_Parse()
	Failures := 0
	Total    := 0
	for Vec in Corpus["vectors"] {
		Total += 1
		Id := Vec.Has("id") ? Vec["id"] : "?"
		HSE_TestReset()

		; Build flags: star trigger fires on the last trigger char.
		; ? flag allows in-word matching; C flag requires exact case.
		IsWord  := Vec.Has("is_word")  ? Vec["is_word"]  : true
		IsCS    := Vec.Has("is_case_sensitive") and Vec["is_case_sensitive"] = true
		Flags   := "*"
		if not IsWord
			Flags .= "?"
		if IsCS
			Flags .= "C"

		HSE_Register(Flags, Vec["trigger"], () => 0,
			Map("Repl", Vec.Has("replacement") ? Vec["replacement"] : ""))
		HSE_FeedReset(true)

		; Read the buffer and feed characters one at a time.
		InputBuffer := Vec.Has("buffer") ? Vec["buffer"] : ""
		Match  := ""
		if InputBuffer != "" {
			loop StrLen(InputBuffer) {
				Match := HSE_FeedChar(SubStr(InputBuffer, A_Index, 1))
			}
		}

		Expected := Vec["expected"]
		ExpMatch := Expected.Has("matched") and Expected["matched"] = true

		; 1. Verify matched vs not-matched.
		if ExpMatch {
			if Match = "" {
				Failures += 1
				FileAppend("  FAIL '" . Id . "': expected match, got none`n", "*")
				continue
			}
			; 2. Verify trigger identity.
			if Match.Trigger != Vec["trigger"] {
				Failures += 1
				FileAppend("  FAIL '" . Id . "': trigger mismatch '"
					. Match.Trigger . "' vs '" . Vec["trigger"] . "'`n", "*")
				continue
			}
			; 3. Verify replacement text.
			if Vec.Has("replacement") and Match.Repl != Vec["replacement"] {
				Failures += 1
				FileAppend("  FAIL '" . Id . "': replacement mismatch '"
					. Match.Repl . "' vs expected '" . Vec["replacement"] . "'`n", "*")
				continue
			}
			; 4. Verify backspace count.
			if Expected.Has("backspace_count") {
				Consumed   := Vec.Has("terminator_consumed") and Vec["terminator_consumed"] = true
				ExpectedBC := Match.Length + (Consumed ? 1 : 0)
				if ExpectedBC != Expected["backspace_count"] {
					Failures += 1
					FileAppend("  FAIL '" . Id . "': backspace_count " . ExpectedBC
						. " != expected " . Expected["backspace_count"] . "`n", "*")
					continue
				}
			}
		} else {
			if Match != "" {
				Failures += 1
				FileAppend("  FAIL '" . Id . "': expected no match, got '"
					. Match.Trigger . "'`n", "*")
				continue
			}
		}
	}

	if Failures > 0 {
		AssertTrue(false, "engine replay: " . Failures . "/" . Total . " vector(s) FAILED")
	} else {
		AssertTrue(Total > 0, "engine replay: no vectors loaded from corpus")
		AssertEqual(0, Failures, "engine replay: all " . Total . " vector(s) passed")
	}
}
Test("hotstring corpus  --  every single vector replayed through HSE_FeedChar matches expected", _CorpusHS_EveryVectorReplayedThroughEngine)
