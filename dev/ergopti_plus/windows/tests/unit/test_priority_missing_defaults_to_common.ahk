; tests/unit/test_priority_missing_defaults_to_common.ahk

; ==============================================================================
; MODULE: Regression — a candidate with no Priority is COMMON, not PERSONAL
; DESCRIPTION:
; Both Windows collision comparators fell back to the literal 50 when a
; candidate object carried no Priority property:
;
;     CandPrio := Cand.HasOwnProp("Priority") ? Cand.Priority : 50
;
; 50 is HSE_PRIORITY_PERSONAL, the TOP tier. The source default in
; _shared/modules/hotstrings/priority.json is common = 10, and the macOS
; comparator has always used it (`a.priority or PRIORITY_COMMON`). So the two
; drivers ranked the same pair of same-length triggers differently whenever one
; side lacked the property — which is exactly the preview's prefix-index
; entries, built from the same TOML but carrying only the fields the tooltip
; needs.
;
; ROOT CAUSE ENCODED: the fallback must be the named constant, not a literal.
; The parity gate compared only the three constant DECLARATIONS, so a use site
; that spelled the number was invisible to it — the gate now scans use sites too,
; and this test pins the behaviour those sites produce.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ The fallback is the shared source default =======
; ============================================================
; ============================================================

; A same-length rival with an EXPLICIT common priority must beat a candidate
; that carries none: both are common, so the tiebreak falls through to the
; later rules rather than handing the property-less one the personal tier.
_PMDC_MissingPriorityIsCommon() {
	global HSE_PRIORITY_COMMON, HSE_PRIORITY_PERSONAL

	Bare     := { Length: 5, Seq: 2, GroupOrder: 2 }                              ; no Priority
	Personal := { Length: 5, Seq: 1, GroupOrder: 1, Priority: HSE_PRIORITY_PERSONAL }

	Assert(!_HSE_Beats(Bare, Personal),
		"a candidate with NO Priority must not outrank an explicitly personal one — "
		. "it is common (" . HSE_PRIORITY_COMMON . "), and the old literal 50 made it personal")

	Common := { Length: 5, Seq: 1, GroupOrder: 1, Priority: HSE_PRIORITY_COMMON }
	Assert(!_HSE_Beats(Bare, Common),
		"against an explicitly COMMON rival of equal length the two priorities tie, so the "
		. "later tiebreaks decide and the first-registered entry keeps the win")
}
Test("hotstrings: a candidate with no Priority ranks as common, not personal",
	_PMDC_MissingPriorityIsCommon)





; ================================================
; ================================================
; ======= 2/ Neither comparator holds a 50 =======
; ================================================
; ================================================

; The value must come from the constant. A future edit that re-inlines it would
; still pass section 1 today (the constant happens to be 10) and drift the
; moment priority.json changes, which is the whole reason this bug existed.
_PMDC_ComparatorsUseTheConstant() {
	Beats := _DriverFuncBody("_HSE_Beats")
	Assert(RegExMatch(Beats, "Priority[ \t]*:[ \t]*HSE_PRIORITY_COMMON"),
		"_HSE_Beats must fall back to HSE_PRIORITY_COMMON, not to a literal")
	Assert(!RegExMatch(Beats, "Priority[ \t]*:[ \t]*\d"),
		"_HSE_Beats must not spell any priority number — that literal cannot follow the shared JSON")

	Tail := _DriverFuncBody("HSE_MappingsForTail")
	Assert(RegExMatch(Tail, "Priority[ \t]*:[ \t]*HSE_PRIORITY_COMMON"),
		"the mappings sort must fall back to HSE_PRIORITY_COMMON too")
	Assert(!RegExMatch(Tail, "Priority[ \t]*:[ \t]*\d"),
		"the mappings sort must not spell any priority number either")
}
Test("hotstrings: both collision comparators name the constant instead of a literal",
	_PMDC_ComparatorsUseTheConstant)
