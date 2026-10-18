; tests/unit/modules/llm/nav_event_owner/test_terminal_capture_admission.ahk

; ==============================================================================
; MODULE: Terminal Capture Admission Cost Tests
; DESCRIPTION:
; A terminal hotstring admits native keyboard capture synchronously inside the
; completing key's OnChar callback. Admission re-registered every terminal route
; there, a custody-checked rebuild that cost 300 ms to 900 ms per expansion in a
; real session, so keys typed meanwhile interleaved with the expansion
; ("cc'était"). These cases pin that admission performs no route registration
; and stays within a keystroke budget. Uses the injected native port without
; installing a live keyboard hook.
; ==============================================================================

#Requires AutoHotkey v2.0

global _TCA_ADMISSION_BUDGET_MS := 15

_TCA_CountSource(State) {
	State.SourceCalls += 1
	return Map("active", 0, "caps", 0)
}

_TCA_CountRegister(State, Owner, Generation, Layout, Bindings, Count) {
	State.RegisterCalls += 1
	return 0
}

_TCA_EmptyHeld(State, Owner, Ids, Capacity) {
	return Map("status", 0, "count", 0)
}

_TCA_ElapsedMs(StartTicks) {
	Frequency := 0, Now := 0
	DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	DllCall("QueryPerformanceCounter", "Int64*", &Now)
	return (Now - StartTicks) * 1000 / Frequency
}

_TCA_AdmissionRegistersNothing() {
	global _LLM_NavEventOwnerTerminalRouteGeneration, _TCA_ADMISSION_BUDGET_MS
	Native := _LNEO_Setup()
	try {
		Counts := {SourceCalls: 0, RegisterCalls: 0}
		; Admission's default path is the genuine native capture call. These
		; seams only observe a route registration, which admission must not do.
		Native.Port["terminal_route_source"] := _TCA_CountSource.Bind(Counts)
		Native.Port["register_terminal_routes"] := _TCA_CountRegister.Bind(Counts)
		Native.Port["list_terminal_held_recipes"] := _TCA_EmptyHeld.Bind(Counts)
		Generation := _LLM_NavEventOwnerTerminalRouteGeneration
		; The first native export lookup loads the DLL; keep it out of the budget.
		Token := 0x7CA000
		try LLM_NavEventOwner_BeginTerminalCapture(++Token)
		try LLM_NavEventOwner_ReleaseTerminalCapture(Token, false)
		Slowest := 0.0
		Loop 5 {
			Started := 0
			DllCall("QueryPerformanceCounter", "Int64*", &Started)
			try LLM_NavEventOwner_BeginTerminalCapture(++Token)
			Slowest := Max(Slowest, _TCA_ElapsedMs(Started))
			try LLM_NavEventOwner_ReleaseTerminalCapture(Token, false)
		}
		AssertEqual(0, Counts.SourceCalls,
			"capture admission must not rebuild the terminal routes")
		AssertEqual(0, Counts.RegisterCalls,
			"capture admission must not re-register the terminal routes")
		AssertEqual(Generation, _LLM_NavEventOwnerTerminalRouteGeneration,
			"capture admission must leave the registered route generation alone")
		AssertTrue(Slowest < _TCA_ADMISSION_BUDGET_MS,
			"capture admission runs inside the completing keystroke; slowest took "
			. Round(Slowest, 2) . " ms")
	} finally _LNEO_Teardown()
}

Test("terminal capture admission: no route registration on the keystroke path (hsfix-terminal-admission)",
	_LNTR_WithState.Bind(_TCA_AdmissionRegistersNothing))
