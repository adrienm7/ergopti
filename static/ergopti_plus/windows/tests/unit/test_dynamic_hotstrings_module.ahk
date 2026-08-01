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
; SCOPE: pure functions only. Registration needs the full Features /
;   PersonalInformation globals and the hotstring engine, which the headless
;   suite does not stand up; that path is covered by the corpus prefix vectors.
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
