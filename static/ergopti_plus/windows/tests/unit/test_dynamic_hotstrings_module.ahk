; static/ergopti_plus/windows/tests/unit/test_dynamic_hotstrings_module.ahk

; ==============================================================================
; MODULE: Dynamic Hotstrings Module Tests
; DESCRIPTION:
; Covers modules/dynamic_hotstrings/dynamic_hotstrings.ahk — the dates and the
; phone / SSN / IBAN prefix expansions, which are computed at fire time rather
; than read from a TOML.
;
; WHY THIS EXISTS:
; the code was moved out of section 5 of hotstrings_text_expansion.ahk so the
; three drivers name this subsystem the same way. Nothing in the suite exercised
; it: SpacedPrefix, the three date formatters and the delay resolver had ZERO
; references outside their own file, so a pure move could have broken any of
; them and every one of the 3 833 tests would still have passed. A move with no
; behavioural coverage is exactly where a silent break hides, so the coverage is
; part of the move.
;
; WHAT IS PINNED:
;   1. SpacedPrefix — the trigger builder for SSN and IBAN. Its contract is
;      "shortest prefix containing exactly N non-space characters", which is NOT
;      the same as "first N characters", and the difference is the whole reason
;      the function exists: an SSN is stored with decorative spaces, so the
;      6-raw-character trigger is 7 characters long on screen.
;   2. The three date formatters return today's date in the three declared
;      shapes. Asserted against FormatTime rather than a literal, because a
;      literal makes the test fail at midnight for a reason that is not a bug.
;   3. The module still declares the ordering contract, since the call site's
;      position feeds the engine's collision tiebreak.
;
; SCOPE: pure functions and actual in-memory registration/matching. Synthetic
;   Features/personal values exercise the HSE word boundary without input hooks,
;   GUI, personal configuration, or a positive keyboard/output dispatch.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================
; ==================================
; ======= 1/ SpacedPrefix ==========
; ==================================
; ==================================

_DynHSTest_SpacedPrefixSkipsSpaces() {
	; A French SSN as PersonalInformation stores it: decorative spaces, and the
	; distinguishing prefix is the first 5 DIGITS. "1 99 99" is 7 characters wide
	; and holds exactly those 5 digits, which is the point — SubStr(s, 1, 5) would
	; stop two digits short and register a trigger that never fires.
	AssertEqual("1 99 99", SpacedPrefix("1 99 99 99 999 999 99", 5),
		"SpacedPrefix must count non-space characters, not characters")
}
Test("dynamic hotstrings: SpacedPrefix counts raw characters, not screen width",
	_DynHSTest_SpacedPrefixSkipsSpaces)

_DynHSTest_SpacedPrefixIbanShape() {
	; An IBAN's first 6 raw characters span 7 on screen ("FR76 12" -> F,R,7,6,1,2).
	AssertEqual("FR76 12", SpacedPrefix("FR76 1234 5678 9012 3456 789", 6),
		"the IBAN spaced trigger must stop at the 6th raw character")
}
Test("dynamic hotstrings: SpacedPrefix builds the IBAN spaced trigger",
	_DynHSTest_SpacedPrefixIbanShape)

_DynHSTest_SpacedPrefixNoSpaces() {
	; With no spaces the answer degenerates to a plain substring — pinned so an
	; "optimisation" to SubStr looks correct here and still fails the two above.
	AssertEqual("12345", SpacedPrefix("1234567890", 5),
		"a string without spaces must yield its plain prefix")
}
Test("dynamic hotstrings: SpacedPrefix on a space-free string is a plain prefix",
	_DynHSTest_SpacedPrefixNoSpaces)

_DynHSTest_SpacedPrefixShortInput() {
	; Fewer raw characters than requested: return everything rather than throwing.
	; The caller guards on StrLen before using the result, so the fallback must be
	; a value, not an error.
	AssertEqual("1 2", SpacedPrefix("1 2", 9),
		"a string shorter than the requested count must come back whole")
}
Test("dynamic hotstrings: SpacedPrefix returns the whole string when it is too short",
	_DynHSTest_SpacedPrefixShortInput)





; ==================================
; ==================================
; ======= 2/ Date formatters =======
; ==================================
; ==================================

_DynHSTest_DateFormats() {
	; Compared against FormatTime, not against a written-out date: a literal here
	; would turn every midnight into a red suite for no defect.
	AssertEqual(FormatTime(, "dd/MM/yyyy"), _DateShortFr(),
		"@dt must expand to the short French date")
	AssertEqual(FormatTime(, "yyyy_MM_dd"), _DateIso(),
		"@td must expand to the ISO date")

	; The long form is assembled by hand from French day and month names, so the
	; shape is pinned rather than the text: day name, day number, month name,
	; four-digit year, separated by single spaces.
	Long := _DateLongFr()
	Assert(InStr(Long, FormatTime(, "yyyy")) > 0,
		"the long French date must carry the four-digit year")
	Assert(InStr(Long, " ") > 0, "the long French date must be space-separated")
	Parts := StrSplit(Long, " ")
	AssertEqual(4, Parts.Length,
		"the long French date must be '<day> <n> <month> <year>' — four parts")
	Assert(Parts[2] == FormatTime(, "d"),
		"the long French date must carry the un-padded day number")
}
Test("dynamic hotstrings: the three date formatters return today in their declared shapes",
	_DynHSTest_DateFormats)

class _DynHSTest_ClockSequence {
	__New(Items) {
		this.Items := Items
		this.Index := 0
	}

	Call() {
		this.Index += 1
		return this.Items[this.Index]
	}
}

_DynHSTest_LongDateUsesOneInstant() {
	Cases := [
		Map("instants", ["20260828235959", "20260829000000"],
			"expected", "vendredi 28 août 2026"),
		Map("instants", ["20260930235959", "20261001000000"],
			"expected", "mercredi 30 septembre 2026"),
		Map("instants", ["20261231235959", "20270101000000"],
			"expected", "jeudi 31 décembre 2026")
	]
	for Fixture in Cases {
		Clock := _DynHSTest_ClockSequence(Fixture["instants"])
		Actual := _DateLongFrWithClock(Clock)
		AssertEqual(Fixture["expected"], Actual,
			"weekday, day, month, and year must all derive from the first instant")
		AssertEqual(1, Clock.Index,
			"long-date formatting must sample the clock exactly once")
	}
}
Test("dynamic hotstrings: long French date derives every field from one instant (date-single-instant)",
	_DynHSTest_LongDateUsesOneInstant)




; =========================================
; =========================================
; ======= 3/ The ordering contract ========
; =========================================
; =========================================

_DynHSTest_OrderingContractIsStated() {
	; The call site's POSITION is load-bearing: the engine's collision tiebreak
	; falls through to registration order, so moving _DynHS_RegisterAll() past the
	; repeat-key registration would change which of two equal-length triggers
	; wins — with no error and no failing test anywhere else. The contract cannot
	; be asserted behaviourally without standing up the engine, so what is checked
	; is that the caller still calls it, and still calls it before the repeat key.
	Body := _DriverFuncBody("_HS_RegisterTextExpansionAndDynamic")
	CallPos := InStr(Body, "_DynHS_RegisterAll()")
	Assert(CallPos > 0,
		"_HS_RegisterTextExpansionAndDynamic must still call _DynHS_RegisterAll() — "
		. "dropping the call silently disables every date and prefix expansion")
	RepeatPos := InStr(Body, "repeat_corrections")
	Assert(RepeatPos > 0,
		"the repeat-key registration must still be in this function — if it moved, "
		. "this test is measuring the wrong ordering")
	Assert(CallPos < RepeatPos,
		"_DynHS_RegisterAll() must run BEFORE the repeat-key registration: the magic "
		. "key is the lowest-priority hotstring and registering it first would let it "
		. "win ties against the dynamic entries")
}
Test("dynamic hotstrings: the registration call keeps its position in the boot order",
	_DynHSTest_OrderingContractIsStated)





; ==================================================
; ==================================================
; ======= 4/ Actual registration word boundaries ====
; ==================================================
; ==================================================

; Synthetic personal values and a cached configuration receipt keep registration
; on its real in-memory path. Matching never invokes a keyboard/output owner.
_DynHSTest_WithWordRegistry(Body) {
	global Features, ScriptInformation, PersonalInformation, _HotstringRegistrar
	global _HSResolveCache, _HSResolveGen
	Saved := [IsSet(Features) ? Features : unset,
		IsSet(ScriptInformation) ? ScriptInformation : unset,
		IsSet(PersonalInformation) ? PersonalInformation : unset,
		IsSet(_HotstringRegistrar) ? _HotstringRegistrar : unset,
		IsSet(_HSResolveCache) ? _HSResolveCache : unset]
	global HSE_RegistryByLastChar, HSE_StarSpecs, HSE_StarPrefixSetCI
	global HSE_StarPrefixSetCS, HSE_RegistryByGroup, HSE_DisabledGroups
	global HSE_SeqCounter, HSE_StarByTriggerCI, HSE_StarByTriggerCS
	global HSE_MaxStarTriggerLen, HSE_EndByTriggerCI, HSE_EndByTriggerCS
	global HSE_MaxEndTriggerLen, HSE_RegistryGeneration, HSE_Buffer
	global HSE_StartIsWordBoundary, HSE_LastMatch, HSE_LastEndChar
	global HSE_Suppressed, HSE_TypoNbspStripped, _PrefixWatcherSuppressed
	SavedRegistry := [IsSet(HSE_RegistryByLastChar) ? HSE_RegistryByLastChar : unset,
		IsSet(HSE_StarSpecs) ? HSE_StarSpecs : unset,
		IsSet(HSE_StarPrefixSetCI) ? HSE_StarPrefixSetCI : unset,
		IsSet(HSE_StarPrefixSetCS) ? HSE_StarPrefixSetCS : unset,
		IsSet(HSE_RegistryByGroup) ? HSE_RegistryByGroup : unset,
		IsSet(HSE_DisabledGroups) ? HSE_DisabledGroups : unset,
		IsSet(HSE_SeqCounter) ? HSE_SeqCounter : unset,
		IsSet(HSE_StarByTriggerCI) ? HSE_StarByTriggerCI : unset,
		IsSet(HSE_StarByTriggerCS) ? HSE_StarByTriggerCS : unset,
		IsSet(HSE_MaxStarTriggerLen) ? HSE_MaxStarTriggerLen : unset,
		IsSet(HSE_EndByTriggerCI) ? HSE_EndByTriggerCI : unset,
		IsSet(HSE_EndByTriggerCS) ? HSE_EndByTriggerCS : unset,
		IsSet(HSE_MaxEndTriggerLen) ? HSE_MaxEndTriggerLen : unset,
		IsSet(HSE_RegistryGeneration) ? HSE_RegistryGeneration : unset,
		IsSet(HSE_Buffer) ? HSE_Buffer : unset,
		IsSet(HSE_StartIsWordBoundary) ? HSE_StartIsWordBoundary : unset,
		IsSet(HSE_LastMatch) ? HSE_LastMatch : unset,
		IsSet(HSE_LastEndChar) ? HSE_LastEndChar : unset,
		IsSet(HSE_Suppressed) ? HSE_Suppressed : unset,
		IsSet(HSE_TypoNbspStripped) ? HSE_TypoNbspStripped : unset,
		IsSet(_PrefixWatcherSuppressed) ? _PrefixWatcherSuppressed : unset]
	try {
		Features := Map("hotstrings", Map("dynamic", Map()))
		for Name in ["date_fr", "date_long_fr", "date", "phone_prefixes", "ssn_prefixes", "iban_prefixes"]
			Features["hotstrings"]["dynamic"][Name] := Map("enabled", true)
		ScriptInformation := Map("MagicKey", Chr(0x2605))
		PersonalInformation := Map("phone_number", "0612345678", "phone_number_clean", "06 12 34 56 78",
			"social_security_number", "1 99 99 99 999 999 99", "iban", "FR76 1234 5678 9012 3456 789")
		_HotstringRegistrar := 0
		_HSResolveCache := Map("dynamichotstrings|", { gen: _HSResolveGen,
			val: { Delay: 0, HasOverride: true, Priority: 10 } })
		HSE_TestReset()
		_DynHS_RegisterAll()
		Body.Call()
	} finally {
		HSE_TestReset()
		Features := Saved.Has(1) ? Saved[1] : unset
		ScriptInformation := Saved.Has(2) ? Saved[2] : unset
		PersonalInformation := Saved.Has(3) ? Saved[3] : unset
		_HotstringRegistrar := Saved.Has(4) ? Saved[4] : unset
		_HSResolveCache := Saved.Has(5) ? Saved[5] : unset
		HSE_RegistryByLastChar := SavedRegistry.Has(1) ? SavedRegistry[1] : unset
		HSE_StarSpecs := SavedRegistry.Has(2) ? SavedRegistry[2] : unset
		HSE_StarPrefixSetCI := SavedRegistry.Has(3) ? SavedRegistry[3] : unset
		HSE_StarPrefixSetCS := SavedRegistry.Has(4) ? SavedRegistry[4] : unset
		HSE_RegistryByGroup := SavedRegistry.Has(5) ? SavedRegistry[5] : unset
		HSE_DisabledGroups := SavedRegistry.Has(6) ? SavedRegistry[6] : unset
		HSE_SeqCounter := SavedRegistry.Has(7) ? SavedRegistry[7] : unset
		HSE_StarByTriggerCI := SavedRegistry.Has(8) ? SavedRegistry[8] : unset
		HSE_StarByTriggerCS := SavedRegistry.Has(9) ? SavedRegistry[9] : unset
		HSE_MaxStarTriggerLen := SavedRegistry.Has(10) ? SavedRegistry[10] : unset
		HSE_EndByTriggerCI := SavedRegistry.Has(11) ? SavedRegistry[11] : unset
		HSE_EndByTriggerCS := SavedRegistry.Has(12) ? SavedRegistry[12] : unset
		HSE_MaxEndTriggerLen := SavedRegistry.Has(13) ? SavedRegistry[13] : unset
		HSE_RegistryGeneration := SavedRegistry.Has(14) ? SavedRegistry[14] : unset
		HSE_Buffer := SavedRegistry.Has(15) ? SavedRegistry[15] : unset
		HSE_StartIsWordBoundary := SavedRegistry.Has(16) ? SavedRegistry[16] : unset
		HSE_LastMatch := SavedRegistry.Has(17) ? SavedRegistry[17] : unset
		HSE_LastEndChar := SavedRegistry.Has(18) ? SavedRegistry[18] : unset
		HSE_Suppressed := SavedRegistry.Has(19) ? SavedRegistry[19] : unset
		HSE_TypoNbspStripped := SavedRegistry.Has(20) ? SavedRegistry[20] : unset
		_PrefixWatcherSuppressed := SavedRegistry.Has(21) ? SavedRegistry[21] : unset
	}
}

_DynHSTest_WordFeed(Text, KnownBoundary := true) {
	HSE_HardReset()
	HSE_FeedReset(KnownBoundary)
	Match := ""
	for Char in StrSplit(Text)
		Match := HSE_FeedChar(Char)
	return Match
}

_DynHSTest_RejectDateWordsBody() {
	for Word in ["update", "updates", "date", "td", "dt", "xtd", "xdt", "1date", "_date", "édate"] {
		for Suffix in ["", Chr(0x2605)] {
			Match := _DynHSTest_WordFeed(Word . Suffix)
			AssertFalse(IsObject(Match), "ordinary words do not acquire a Windows @-date candidate")
			AssertFalse(HSE_DispatchMatch(Match, ""), "a missing dynamic candidate cannot dispatch output")
		}
	}
}
Test("dynamic hotstrings: ordinary date words never acquire or dispatch @-date candidates (dynamic-word-boundary)",
	(*) => _DynHSTest_WithWordRegistry(_DynHSTest_RejectDateWordsBody))

_DynHSTest_PrivatePrefixes() {
	return ["06" . Chr(0x2605), "+3306", "0612", "+33612", "6123", "06 12",
		"19999", "1 99 99", "FR7612", "FR76 12"]
}

_DynHSTest_RejectPersonalInsideWordsBody() {
	for Trigger in _DynHSTest_PrivatePrefixes() {
		for Left in ["update", "x", "1", "_", "é", "@"] {
			Match := _DynHSTest_WordFeed(Left . Trigger)
			AssertFalse(IsObject(Match), "personal numeric prefixes must not acquire a candidate inside a larger word")
			AssertFalse(HSE_DispatchMatch(Match, ""), "rejected personal prefixes cannot dispatch output")
		}
	}
}
Test("dynamic hotstrings: personal numeric prefixes reject every larger-word predecessor (dynamic-word-boundary)",
	(*) => _DynHSTest_WithWordRegistry(_DynHSTest_RejectPersonalInsideWordsBody))

_DynHSTest_ExplicitDatesKeepContinuationBody() {
	for Trigger in ["@dt" . Chr(0x2605), "@date" . Chr(0x2605), "@td" . Chr(0x2605)] {
		for Left in ["", "2026", "expandedword"] {
			Match := _DynHSTest_WordFeed(Left . Trigger, Left == "")
			AssertTrue(IsObject(Match), "explicit @ dates remain available after prior expansion text")
			AssertEqual(Trigger, Match.Trigger, "the actual date registration owns its explicit spelling")
			AssertTrue(Match.InWord, "the intentional *? date continuation contract is retained")
			AssertTrue(HasMethod(Match.Replacement), "date output remains resolved at fire time")
		}
	}
}
Test("dynamic hotstrings: explicit @ dates preserve back-to-back continuation and dynamic callbacks (dynamic-word-boundary)",
	(*) => _DynHSTest_WithWordRegistry(_DynHSTest_ExplicitDatesKeepContinuationBody))

_DynHSTest_PersonalAtBoundaryBody() {
	for Trigger in _DynHSTest_PrivatePrefixes() {
		for Left in ["", " ", Chr(0x27), "!"] {
			Match := _DynHSTest_WordFeed(Left . Trigger)
			AssertTrue(IsObject(Match), "personal prefixes remain available at a genuine word boundary")
			AssertEqual(Trigger, Match.Trigger)
			AssertFalse(Match.InWord, "ordinary numeric registration never uses the in-word flag")
			AssertTrue(Match.IsPrivate, "personal registration retains its privacy marker")
		}
	}
	for Trigger in ["fr7612", "fr76 12"] {
		Match := _DynHSTest_WordFeed(Trigger)
		AssertTrue(IsObject(Match), "IBAN prefixes preserve their original case-insensitive admission")
		AssertFalse(Match.CaseSensitive)
	}
}
Test("dynamic hotstrings: personal prefixes keep genuine boundary positives and IBAN case behavior (dynamic-word-boundary)",
	(*) => _DynHSTest_WithWordRegistry(_DynHSTest_PersonalAtBoundaryBody))

_DynHSTest_PersonalUnknownBoundaryBody() {
	for Trigger in _DynHSTest_PrivatePrefixes() {
		Match := _DynHSTest_WordFeed(Trigger, false)
		AssertFalse(IsObject(Match), "a fresh buffer with unknown left context cannot authorize an ordinary personal prefix")
		AssertFalse(HSE_DispatchMatch(Match, ""))
	}
}
Test("dynamic hotstrings: unknown left context refuses ordinary personal prefixes (dynamic-word-boundary)",
	(*) => _DynHSTest_WithWordRegistry(_DynHSTest_PersonalUnknownBoundaryBody))
