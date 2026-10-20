; tests/unit/modules/llm/api/test_llm_runtime_activation.ahk

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

; ai-disabled-runtime-inert-2026-10-20 (issue #97): a boot with the AI off bound
; the AI hotkeys and armed the health timer anyway. A refused native navigation
; plan then logged LLM errors and threw out of the top-level boot, so a user
; who had never switched the AI on saw « LLM errors » and a startup failure.
_LRA_DisabledIsInert() {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Menu_RuntimeActivated
	global _LLM_Menu_HotkeysAwaitEnable, _LLM_Menu_FirstRestoreHotkeysDeferred
	global LLM_HEALTH_PROBE_INTERVAL_MS
	SavedInterval := IsSet(LLM_HEALTH_PROBE_INTERVAL_MS) ? LLM_HEALTH_PROBE_INTERVAL_MS : 0
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedRuntime := _LLM_Menu_RuntimeActivated
	SavedAwait := IsSet(_LLM_Menu_HotkeysAwaitEnable) ? _LLM_Menu_HotkeysAwaitEnable : false
	SavedDeferred := _LLM_Menu_FirstRestoreHotkeysDeferred
	State := {Bindings: 0, Backends: 0, Timers: 0, Scheduled: [], Activations: 0}
	try {
		LLM_HEALTH_PROBE_INTERVAL_MS := 10000
		_LLM_Menu := Map("enabled", false, "backend", "ollama")
		_LLM_Menu_Loaded := true
		_LLM_Menu_RuntimeActivated := false
		_LLM_Menu_HotkeysAwaitEnable := false
		_LLM_Menu_FirstRestoreHotkeysDeferred := false
		Activate := (First) => State.Bindings += 1
		Backend := (Visible) => State.Backends += 1
		Timer := (Fn, Delay) => State.Timers += 1
		AssertTrue(LLM_Menu_ActivateRuntime(Activate, Backend, Timer),
			"a boot with the AI off completes its AI activation without touching it")
		AssertEqual(0, State.Bindings, "no AI hotkey is bound while the AI is off")
		AssertEqual(0, State.Backends, "no backend lifecycle starts while the AI is off")
		AssertEqual(0, State.Timers, "no health timer is armed while the AI is off")
		AssertTrue(_LLM_Menu_RuntimeActivated, "startup commands still see the AI runtime settled")
		AssertTrue(_LLM_Menu_HotkeysAwaitEnable, "the hotkeys wait for the switch-on")
		; The refused hotkey surface that threw out of the boot cannot be reached.
		_LLM_Menu_RuntimeActivated := false
		_LLM_Menu_HotkeysAwaitEnable := false
		AssertTrue(LLM_Menu_ActivateRuntime((*) => _MSC_Throw(), Backend, Timer),
			"a refused AI hotkey surface cannot abort a boot with the AI off")
		; Nothing is scheduled while the AI stays off, then exactly one
		; activation follows the switch-on.
		Schedule := (Fn, Period) => State.Scheduled.Push(Fn)
		ActivateHotkeys := () => (State.Activations += 1, 1)
		AssertFalse(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, ActivateHotkeys))
		AssertEqual(0, State.Scheduled.Length)
		_LLM_Menu["enabled"] := true
		AssertTrue(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, ActivateHotkeys))
		AssertFalse(LLM_Menu_ScheduleHotkeysAwaitingEnable(Schedule, ActivateHotkeys),
			"one switch-on hands the hotkeys over once")
		AssertEqual(1, State.Scheduled.Length)
		AssertFalse(_LLM_Menu_HotkeysAwaitEnable)
		AssertTrue(_LLM_Menu_FirstRestoreHotkeysDeferred)
		State.Scheduled[1].Call()
		AssertEqual(1, State.Activations)
		AssertFalse(_LLM_Menu_FirstRestoreHotkeysDeferred, "the switch-on activated the AI hotkeys")
	} finally {
		if SavedInterval
			LLM_HEALTH_PROBE_INTERVAL_MS := SavedInterval
		else
			LLM_HEALTH_PROBE_INTERVAL_MS := unset
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Menu_RuntimeActivated := SavedRuntime
		_LLM_Menu_HotkeysAwaitEnable := SavedAwait
		_LLM_Menu_FirstRestoreHotkeysDeferred := SavedDeferred
	}
}
Test("AI runtime: a boot with the AI off binds no hotkey and arms no probe until the switch-on (ai-disabled-runtime-inert-2026-10-20)",
	_LRA_DisabledIsInert)

; ai-disabled-runtime-inert-2026-10-20: the installed-models probe, the model
; correction and the debug install hotkey ignored the AI switch.
_LRA_DisabledProbes() {
	global _DriverInputInitPending, _LLM_Menu, _LLM_Deps_State, _LLM_InstalledTagsCacheAt
	SavedPending := IsSet(_DriverInputInitPending) ? _DriverInputInitPending : false
	SavedMenu := _LLM_Menu
	SavedDeps := _LLM_Deps_State
	SavedCacheAt := _LLM_InstalledTagsCacheAt
	try {
		_DriverInputInitPending := false
		; Ollama answers: only the AI switch can keep the probe silent.
		_LLM_Deps_State := "ready"
		_LLM_InstalledTagsCacheAt := 0
		_LLM_Menu := Map("enabled", false, "backend", "ollama", "model", "")
		Dispatched := 0
		Dispatch := (Done, Owner) => (Dispatched += 1, LLM_AuxFinish(Owner))
		_LLM_Menu_FireInstalledTagsProbe(A_TickCount, Dispatch)
		AssertEqual(0, Dispatched, "the installed-models probe stays silent while the AI is off")
		AssertTrue(LLM_Menu_EnsureModelReady(), "a disabled AI has no model to ready")
		AssertFalse(LLM_Menu_AiEnabled())
		_LLM_Menu["enabled"] := true
		AssertTrue(LLM_Menu_AiEnabled())
		_LLM_Menu_FireInstalledTagsProbe(A_TickCount, Dispatch)
		AssertEqual(1, Dispatched, "the same probe runs once the AI is on")
		; The always-armed debug hotkey checks the switch before installing Ollama.
		Src := _StripFullLineComments(_DriverDirConcat("ui/menu/menu_llm"))
		Start := InStr(Src, "^!+i::")
		AssertTrue(Start > 0, "the Ctrl+Alt+Shift+I rescue hotkey must still exist")
		Body := SubStr(Src, Start, 900)
		Gate := InStr(Body, "if !LLM_Menu_AiEnabled()")
		Install := InStr(Body, "LLM_Menu_BootstrapOllama(")
		AssertTrue(Gate > 0 && Install > Gate,
			"the debug hotkey must refuse to probe or install Ollama while the AI is off")
	} finally {
		_DriverInputInitPending := SavedPending
		_LLM_Menu := SavedMenu
		_LLM_Deps_State := SavedDeps
		_LLM_InstalledTagsCacheAt := SavedCacheAt
	}
}
Test("AI runtime: probes and model corrections stay silent while the AI is off (ai-disabled-runtime-inert-2026-10-20)",
	_LRA_DisabledProbes)

; ai-hotkeys-refusal-degrades-2026-10-20 (issue #97): with the AI on, a native
; owner that refused the navigation plan threw out of the top-level boot. A
; refusal by the system now leaves the driver running without these hotkeys;
; a plan the driver built wrong stays a programming error.
_LRA_RefusalCase(Kind) {
	global _LLM_Menu_HotkeysAwaitEnable, _LLM_Menu_NavLastRefusal
	global LLM_NAV_REFUSAL_EXTERNAL, LLM_NAV_REFUSAL_INVALID
	SavedAwait := IsSet(_LLM_Menu_HotkeysAwaitEnable) ? _LLM_Menu_HotkeysAwaitEnable : false
	Notices := []
	try {
		_LLM_Menu_HotkeysAwaitEnable := false
		Profile := () => 1
		Nav := Kind == "none" ? () => false
			: () => _LLM_Menu_LogNavBindingFailure("Independent " . Kind . " refusal.", (*) => 0,
				Kind == "external" ? LLM_NAV_REFUSAL_EXTERNAL : LLM_NAV_REFUSAL_INVALID)
		Notify := (Title, Body) => Notices.Push([Title, Body])
		Thrown := 0
		try Result := _LLM_Menu_RequireFirstRestoreHotkeys(true, Profile, Nav, false, Notify)
		catch as Err
			Thrown := Err
		if Kind == "external" {
			AssertFalse(Thrown is Error, "a refusal by the system must not abort the boot")
			AssertTrue(Result)
			AssertEqual(1, Notices.Length, "the user is told once that the AI hotkeys are unavailable")
			AssertEqual(t("llm.hotkeys_unavailable"), Notices[1][2])
			AssertTrue(Notices[1][2] != "llm.hotkeys_unavailable", "the notice is localized")
			AssertTrue(_LLM_Menu_HotkeysAwaitEnable, "switching the AI off and on retries the hotkeys")
		} else {
			AssertTrue(Thrown is Error, "an invalid plan or an unexplained refusal stays fail-fast")
			AssertTrue(InStr(Thrown.Message, "initial LLM hotkey surface is incomplete") == 1)
			AssertEqual(0, Notices.Length)
			AssertFalse(_LLM_Menu_HotkeysAwaitEnable)
		}
	} finally {
		_LLM_Menu_HotkeysAwaitEnable := SavedAwait
		_LLM_Menu_NavLastRefusal := 0
	}
}
Test("AI runtime: a refused AI hotkey binding degrades instead of aborting the boot (ai-hotkeys-refusal-degrades-2026-10-20)",
	_LRA_RefusalCase.Bind("external"))
Test("AI runtime: an invalid AI hotkey plan stays fail-fast (ai-hotkeys-refusal-degrades-2026-10-20)",
	_LRA_RefusalCase.Bind("invalid"))
Test("AI runtime: an AI hotkey refusal without a cause stays fail-fast (ai-hotkeys-refusal-degrades-2026-10-20)",
	_LRA_RefusalCase.Bind("none"))

; The production binder names each refusal: a layout the snapshot cannot
; resolve is the system's, malformed modifiers are the driver's.
_LRA_RefusalKinds() {
	global _LLM_Menu_NavLastRefusal, LLM_NAV_REFUSAL_EXTERNAL, LLM_NAV_REFUSAL_INVALID
	try {
		_LLM_Menu_NavLastRefusal := 0
		AssertFalse(_LLM_Menu_PrepareNavHotkeys(Map("nav_modifiers", 7), 0, 0, (*) => 0))
		AssertTrue(_LLM_Menu_NavLastRefusal is Map)
		AssertEqual(LLM_NAV_REFUSAL_INVALID, _LLM_Menu_NavLastRefusal["kind"])
		_LLM_Menu_NavLastRefusal := 0
		AssertFalse(_LLM_Menu_PrepareNavHotkeys(Map("nav_modifiers", "alt", "val_modifiers", "alt"),
			0, 0, (*) => 0, 0, (*) => ""))
		AssertTrue(_LLM_Menu_NavLastRefusal is Map)
		AssertEqual(LLM_NAV_REFUSAL_EXTERNAL, _LLM_Menu_NavLastRefusal["kind"])
		AssertThrows(() => _LLM_Menu_LogNavBindingFailure("Unnamed cause.", (*) => 0))
	} finally _LLM_Menu_NavLastRefusal := 0
}
Test("AI runtime: every navigation refusal names a system or a programming cause (ai-hotkeys-refusal-degrades-2026-10-20)",
	_LRA_RefusalKinds)

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
