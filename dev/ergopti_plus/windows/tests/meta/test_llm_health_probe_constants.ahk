; tests/meta/test_llm_health_probe_constants.ahk

; ==============================================================================
; MODULE: Regression - the LLM health probe's cadence lives in named constants
;         (llm-health-probe-magic-numbers)
; DESCRIPTION:
; ROOT CAUSE ENCODED:
; The background Ollama health tick was armed with a bare 10000 at TWO separate
; sites - the boot arm in menu_llm/init.ahk and the re-arm in menu_llm/actions.ahk
; when the user toggles the feature back on - and throttled against a bare 3000
; inside _LLM_Menu_FireHealthProbe. Nothing tied the three literals together, so
; changing the cadence at one site left the other arming the timer at the old
; rate, and the reasoning that makes the numbers correct lived nowhere: the
; throttle is the ONLY thing that breaks the build -> probe -> flip -> build loop
; (the tray-build path re-enters the probe with Force, which bypasses the idle
; gate but not the throttle), and the interval is what the "8640 curl children a
; day" arithmetic behind LLM_HEALTH_PROBE_IDLE_MAX_MS is computed from.
;
; The guards below DERIVE the arming sites from the driver source instead of
; naming today's two, so a third arm added tomorrow is checked automatically -
; the failure mode here is precisely "invariant applied at one site, sibling
; forgotten".
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ Named, unique cadence constants =======
; ==================================================
; ==================================================

; Both cadence constants must be declared exactly once, as named integer globals,
; next to the idle ceiling they are reasoned about with. "Exactly once" matters as
; much as "declared": a second declaration in another file is how two arming sites
; drift apart while both look like they read a constant.
_HPC_ConstantsAreNamedAndUnique() {
	Src := _DriverSourceNoComments()
	for _, Name in ["LLM_HEALTH_PROBE_INTERVAL_MS", "LLM_HEALTH_PROBE_THROTTLE_MS", "LLM_HEALTH_PROBE_IDLE_MAX_MS"] {
		Decls := 0
		Pos := 1
		while (F := RegExMatch(Src, "m)^global\s+" . Name . "\s*:=\s*(\d+)", &M, Pos)) {
			Pos := F + M.Len
			Decls += 1
			Assert(M[1] + 0 > 0,
				Name . " must be declared with a positive millisecond value, not a sentinel")
		}
		Assert(Decls == 1,
			Name . " must be declared exactly once as a named global constant (found " . Decls . " declaration(s)) - a duplicate is how the two arming sites came to drift")
	}
}





; ======================================================
; ======================================================
; ======= 2/ Every arming site uses the constant =======
; ======================================================
; ======================================================

; Every site that arms or disarms the health tick must pass the named constant or
; the literal 0 that means "disarm". Derived from source: the guarantee is "no
; arming site carries a magic cadence", not "these two files are clean".
_HPC_EveryArmingSiteUsesTheConstant() {
	Src := _DriverSourceNoComments()
	Sites := 0
	Pos := 1
	while (F := RegExMatch(Src, "SetTimer\(\s*_LLM_Menu_FireHealthProbe\s*,\s*([^)\r\n]+)\)", &M, Pos)) {
		Pos := F + M.Len
		Sites += 1
		Arg := Trim(M[1])
		Assert(Arg == "LLM_HEALTH_PROBE_INTERVAL_MS" or Arg == "0",
			"the health tick is armed with " . Arg . " - every arming site must pass LLM_HEALTH_PROBE_INTERVAL_MS (or the literal 0 that disarms it), or the boot arm and the toggle re-arm silently run at different cadences")
	}
	Assert(Sites >= 2,
		"the scan must reach the health-tick arming sites (found " . Sites . ") - the boot arm and the toggle re-arm are both real, so a scan finding fewer means the regex stopped matching and this test went vacuous")
}





; ================================================
; ================================================
; ======= 3/ The throttle is not a literal =======
; ================================================
; ================================================

; The probe body itself must carry no millisecond literal. Both ceilings it
; compares against are named, so any 4-or-more-digit number appearing here is a
; magic number by construction.
_HPC_ProbeBodyHasNoMillisecondLiteral() {
	Body := _DriverFuncBody("_LLM_Menu_FireHealthProbe")
	Assert(Body != "", "_LLM_Menu_FireHealthProbe must exist in the driver source")

	Assert(InStr(Body, "LLM_HEALTH_PROBE_THROTTLE_MS") > 0,
		"the re-entrancy throttle must compare against the named LLM_HEALTH_PROBE_THROTTLE_MS - it is the only guard the Force bypass cannot defeat, and an inline literal hides that")
	Assert(InStr(Body, "LLM_HEALTH_PROBE_IDLE_MAX_MS") > 0,
		"the idle gate must compare against the named LLM_HEALTH_PROBE_IDLE_MAX_MS")

	Magic := 0
	Pos := 1
	while (F := RegExMatch(Body, "\b\d{4,}\b", &M, Pos)) {
		Pos := F + M.Len
		Magic += 1
	}
	Assert(Magic == 0,
		"_LLM_Menu_FireHealthProbe still contains " . Magic . " bare millisecond literal(s) - every duration it reasons about belongs next to LLM_HEALTH_PROBE_IDLE_MAX_MS with the reasoning that makes it correct")
}


Test("meta llm-health-probe: the cadence constants are named, valued and unique",
	_HPC_ConstantsAreNamedAndUnique)
Test("meta llm-health-probe: every arming site passes the named interval constant",
	_HPC_EveryArmingSiteUsesTheConstant)
Test("meta llm-health-probe: the probe body carries no bare millisecond literal",
	_HPC_ProbeBodyHasNoMillisecondLiteral)
