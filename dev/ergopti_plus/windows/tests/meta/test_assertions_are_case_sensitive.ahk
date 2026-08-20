; tests/meta/test_assertions_are_case_sensitive.ahk

; ==============================================================================
; MODULE: Assertion Case-Sensitivity Meta Test
; DESCRIPTION:
; The suite's own equality primitives must distinguish "BTW" from "btw".
;
; ROOT CAUSE ENCODED:
; AssertEqual compared with ``!=`` and AssertContains searched with a default
; InStr — both of which are CASE-INSENSITIVE in AutoHotkey v2. So
; AssertEqual("BTW", "btw") passed, and AssertContains(out, "BTW") was satisfied
; by an output containing "btw".
;
; That is not a cosmetic looseness in this suite specifically. Case IS the
; subject under test across large parts of it: hotstring case propagation
; (case_conform), is_case_sensitive_strict on 1 302 entries, the trigger
; matching, the layout key names, the locale codes. Every one of those
; assertions was blind to the exact distinction it was written to make — an
; implementation that lower-cased its entire output would have gone green.
;
; The fix is ``!==`` and InStr(…, true). It narrows NOTHING else: numbers still
; compare numerically (1 == "1", 1 == 1.0, 255 == "0xFF"), "" stays distinct
; from 0, true stays 1, and objects compare by identity either way. The suite
; went from 3803 passing to 3803 passing — no test had been relying on the
; looseness, which is precisely why nobody had noticed it.
;
; WHY THIS TEST EXISTS AT ALL:
; Because that zero-red result means the suite itself cannot demonstrate the
; bug. Nothing else in 3803 tests fails if the operator is loosened back to
; ``!=`` tomorrow. This file is the only thing standing between the primitive
; and a silent regression.
; ==============================================================================

#Requires AutoHotkey v2.0


; ── The bug, stated directly ─────────────────────────────────────────────────

_ACS_AssertEqualIsCaseSensitive() {
	AssertThrows(() => AssertEqual("BTW", "btw"),
		'AssertEqual must distinguish case — AHK v2 != compares strings case-insensitively, so AssertEqual("BTW", "btw") passed. Use !== (assertions-case-sensitive)')
	AssertThrows(() => AssertEqual("Hello World", "hello world"),
		"AssertEqual must distinguish case in multi-word strings (assertions-case-sensitive)")
	AssertThrows(() => AssertEqual("é", "É"),
		"AssertEqual must distinguish case for accented characters too — the French UI is full of them (assertions-case-sensitive)")
}

_ACS_AssertContainsIsCaseSensitive() {
	AssertThrows(() => AssertContains("the btw expansion", "BTW"),
		"AssertContains must search case-sensitively — InStr defaults to case-INSENSITIVE, so a lower-cased output satisfied an upper-case needle (assertions-case-sensitive)")
}


; ── What must NOT have changed ───────────────────────────────────────────────
;
; !== is a strictly narrower operator, and the danger of narrowing an assertion
; primitive used at ~1 587 sites is narrowing it too far. These pin the four
; behaviours that were verified against the interpreter before the switch, so a
; future "tighten it further" (say, to a type-strict comparison) is caught here
; rather than in a thousand unrelated reds.

_ACS_NumbersStillCompareNumerically() {
	AssertEqual(1, "1", "an integer must still equal its decimal string — !== is not type-strict in AHK v2")
	AssertEqual(1, 1.0, "an integer must still equal the same float")
	AssertEqual(255, "0xFF", "a number must still equal its hex string")
	AssertEqual(" 1", 1, "a space-padded numeric string must still compare numerically")
}

_ACS_NonNumbersStillCompareAsBefore() {
	AssertThrows(() => AssertEqual("", 0),
		"the empty string must stay distinct from 0")
	AssertEqual(true, 1, "true must still equal 1")
	AssertEqual(false, 0, "false must still equal 0")
}

_ACS_ObjectsStillCompareByIdentity() {
	M := Map()
	AssertEqual(M, M, "the same object must still equal itself")
	AssertThrows(() => AssertEqual(Map(), Map()),
		"two distinct objects must still be unequal — comparison is by identity, not contents")
}

_ACS_EqualCasesStillPass() {
	; The obvious direction, kept because a primitive that throws on everything
	; would satisfy every AssertThrows above.
	AssertEqual("BTW", "BTW", "identical strings must still be equal")
	AssertContains("the BTW expansion", "BTW", "an exact-case needle must still be found")
}


Test("meta assertions: AssertEqual distinguishes case (assertions-case-sensitive)", _ACS_AssertEqualIsCaseSensitive)
Test("meta assertions: AssertContains distinguishes case (assertions-case-sensitive)", _ACS_AssertContainsIsCaseSensitive)
Test("meta assertions: numbers still compare numerically (assertions-case-sensitive)", _ACS_NumbersStillCompareNumerically)
Test("meta assertions: non-numeric values compare as before (assertions-case-sensitive)", _ACS_NonNumbersStillCompareAsBefore)
Test("meta assertions: objects still compare by identity (assertions-case-sensitive)", _ACS_ObjectsStillCompareByIdentity)
Test("meta assertions: exact-case comparisons still pass (assertions-case-sensitive)", _ACS_EqualCasesStillPass)
