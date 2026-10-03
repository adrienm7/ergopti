; tests/unit/test_llm_runtime_activation.ahk

; ==============================================================================
; MODULE: AI Startup Runtime Activation Tests
; DESCRIPTION:
; Rendering restored AI settings must not activate runtime probes or hotkeys.
; The separate activation latch consumes bindings once and retains failures.
; ==============================================================================

#Requires AutoHotkey v2.0

_LRA_Activation() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Menu_RuntimeActivated
	global LLM_HEALTH_PROBE_INTERVAL_MS
	SavedInterval := IsSet(LLM_HEALTH_PROBE_INTERVAL_MS) ? LLM_HEALTH_PROBE_INTERVAL_MS : 0
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedRuntime := _LLM_Menu_RuntimeActivated
	State := {Bindings: 0, Backends: 0, Timers: 0}
	try {
		LLM_HEALTH_PROBE_INTERVAL_MS := 10000
		_LLM_Menu := Map("enabled", true)
		_LLM_Menu_Loaded := true
		_LLM_Menu_RuntimeActivated := false
		Activate := (First) => State.Bindings += First
		Backend := (Visible) => State.Backends += !Visible
		Timer := (Fn, Delay) => State.Timers += 1
		AssertTrue(LLM_Menu_ActivateRuntime(Activate, Backend, Timer))
		AssertFalse(LLM_Menu_ActivateRuntime(Activate, Backend, Timer))
		AssertEqual(1, State.Bindings)
		AssertEqual(1, State.Backends)
		AssertEqual(1, State.Timers)
		_LLM_Menu_RuntimeActivated := false
		Threw := false
		try LLM_Menu_ActivateRuntime((*) => _MSC_Throw(), Backend, Timer)
		catch
			Threw := true
		AssertTrue(Threw)
		AssertFalse(_LLM_Menu_RuntimeActivated, "failed binding cannot publish AI runtime readiness")
		AssertTrue(_LLM_Menu_Loaded, "failed activation must not replay stale restored settings")
	} finally {
		if SavedInterval
			LLM_HEALTH_PROBE_INTERVAL_MS := SavedInterval
		else
			LLM_HEALTH_PROBE_INTERVAL_MS := unset
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Menu_RuntimeActivated := SavedRuntime
	}
}
Test("AI runtime: restored settings activate once and binding failures retain provenance", _LRA_Activation)

_LRA_EarlyProbes() {
	global _DriverInputInitPending, _LLM_Menu
	SavedPending := IsSet(_DriverInputInitPending) ? _DriverInputInitPending : false
	SavedMenu := _LLM_Menu
	try {
		_DriverInputInitPending := true
		_LLM_Menu := Map()
		_LLM_Menu_FireHealthProbe(true)
		_LLM_Menu_FireInstalledTagsProbe()
		AssertTrue(LLM_Menu_EnsureModelReady(),
			"early rendering refuses runtime probes before inspecting incomplete backend state")
	} finally {
		_DriverInputInitPending := SavedPending
		_LLM_Menu := SavedMenu
	}
}
Test("AI runtime: early menu publication cannot launch backend probes or corrections", _LRA_EarlyProbes)
