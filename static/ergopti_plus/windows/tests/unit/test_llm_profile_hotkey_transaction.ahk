; tests/unit/test_llm_profile_hotkey_transaction.ahk

; ==============================================================================
; MODULE: LLM Profile Hotkey Transaction Tests
; DESCRIPTION:
; Root-cause regression coverage for AHK-024 and AHK-028. The fixed Ctrl+1..9 surface must
; remain inert until every native variant exists and the HotIf context is proven
; reset; boot must consume profile and navigation readiness strictly; and only
; digits backed by a current profile may suppress native application input.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Deterministic seams =======
; ======================================
; ======================================

global _LPHT_Hotkeys := Map()
global _LPHT_CurrentPredicate := 0
global _LPHT_FaultSpec := ""
global _LPHT_FaultMode := ""
global _LPHT_OpenFaultMode := ""
global _LPHT_FailCloseRemaining := 0
global _LPHT_CloseThrowAfter := false
global _LPHT_FailReset := false
global _LPHT_HotkeyCalls := 0
global _LPHT_OpenCalls := 0
global _LPHT_CloseCalls := 0
global _LPHT_ResetCalls := 0
global _LPHT_LogCalls := 0
global _LPHT_LogCritical := -1
global _LPHT_NavCalls := 0
global _LPHT_NativeCriticalSamples := []
global _LPHT_AppOutput := []
global _LPHT_SelectedProfiles := []

_LPHT_ResetPorts() {
	global _LPHT_Hotkeys, _LPHT_CurrentPredicate
	global _LPHT_FaultSpec, _LPHT_FaultMode, _LPHT_OpenFaultMode
	global _LPHT_FailCloseRemaining, _LPHT_CloseThrowAfter, _LPHT_FailReset
	global _LPHT_HotkeyCalls, _LPHT_OpenCalls, _LPHT_CloseCalls
	global _LPHT_ResetCalls, _LPHT_LogCalls, _LPHT_LogCritical
	global _LPHT_NavCalls, _LPHT_NativeCriticalSamples
	global _LPHT_AppOutput, _LPHT_SelectedProfiles
	_LPHT_Hotkeys := Map()
	_LPHT_CurrentPredicate := 0
	_LPHT_FaultSpec := ""
	_LPHT_FaultMode := ""
	_LPHT_OpenFaultMode := ""
	_LPHT_FailCloseRemaining := 0
	_LPHT_CloseThrowAfter := false
	_LPHT_FailReset := false
	_LPHT_HotkeyCalls := 0
	_LPHT_OpenCalls := 0
	_LPHT_CloseCalls := 0
	_LPHT_ResetCalls := 0
	_LPHT_LogCalls := 0
	_LPHT_LogCritical := -1
	_LPHT_NavCalls := 0
	_LPHT_NativeCriticalSamples := []
	_LPHT_AppOutput := []
	_LPHT_SelectedProfiles := []
}

_LPHT_HotIf(Args*) {
	global _LPHT_CurrentPredicate, _LPHT_OpenFaultMode
	global _LPHT_FailCloseRemaining, _LPHT_CloseThrowAfter
	global _LPHT_OpenCalls, _LPHT_CloseCalls, _LPHT_NativeCriticalSamples
	_LPHT_NativeCriticalSamples.Push(A_IsCritical)
	if Args.Length > 0 {
		_LPHT_OpenCalls += 1
		if _LPHT_OpenFaultMode == "before"
			throw Error("injected HotIf open refusal")
		_LPHT_CurrentPredicate := Args[1]
		if _LPHT_OpenFaultMode == "after"
			throw Error("injected HotIf post-open refusal")
		return
	}
	_LPHT_CloseCalls += 1
	if _LPHT_FailCloseRemaining > 0 {
		_LPHT_FailCloseRemaining -= 1
		if _LPHT_CloseThrowAfter
			_LPHT_CurrentPredicate := 0
		throw Error("injected HotIf close refusal")
	}
	_LPHT_CurrentPredicate := 0
}

_LPHT_ForceReset() {
	global _LPHT_CurrentPredicate, _LPHT_FailReset, _LPHT_ResetCalls
	global _LPHT_NativeCriticalSamples
	_LPHT_NativeCriticalSamples.Push(A_IsCritical)
	_LPHT_ResetCalls += 1
	if _LPHT_FailReset
		throw Error("injected HotIf force-reset refusal")
	_LPHT_CurrentPredicate := 0
}

_LPHT_Hotkey(Spec, Callback, Options := "") {
	global _LPHT_Hotkeys, _LPHT_CurrentPredicate
	global _LPHT_FaultSpec, _LPHT_FaultMode, _LPHT_HotkeyCalls
	global _LPHT_NativeCriticalSamples
	_LPHT_NativeCriticalSamples.Push(A_IsCritical)
	_LPHT_HotkeyCalls += 1
	if Options != "On"
		throw ValueError("profile fixture accepts only On registrations")
	if !HasMethod(_LPHT_CurrentPredicate, "Call")
		throw Error("profile fixture requires an owned HotIf predicate")
	if Spec == _LPHT_FaultSpec && _LPHT_FaultMode == "before"
		throw Error("injected pre-apply registration refusal")
	_LPHT_Hotkeys[Spec] := Map("predicate", _LPHT_CurrentPredicate,
		"callback", Callback)
	if Spec == _LPHT_FaultSpec && _LPHT_FaultMode == "after"
		throw Error("injected post-apply registration refusal")
}

_LPHT_Log(Message) {
	global _LPHT_LogCalls, _LPHT_LogCritical
	_LPHT_LogCalls += 1
	_LPHT_LogCritical := A_IsCritical
}

_LPHT_ProfileBindPort() {
	return LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
}

_LPHT_ProfileBindSelectPort() {
	return LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset, _LPHT_Select)
}

_LPHT_Select(ProfileId) {
	global _LPHT_SelectedProfiles
	_LPHT_SelectedProfiles.Push(ProfileId)
	return true
}

_LPHT_NavReadyPort() {
	global _LPHT_NavCalls
	_LPHT_NavCalls += 1
	return true
}

_LPHT_IsEffective(Spec) {
	global _LPHT_Hotkeys
	if !_LPHT_Hotkeys.Has(Spec)
		return false
	Record := _LPHT_Hotkeys[Spec]
	return Record["predicate"].Call(Spec)
}

_LPHT_EffectiveCount() {
	Count := 0
	Loop 9 {
		if _LPHT_IsEffective("^" . A_Index)
			Count += 1
	}
	return Count
}

_LPHT_RoutePhysical(Spec) {
	return _LPHT_IsEffective(Spec) ? "hotkey" : "app"
}

_LPHT_FirePhysical(Spec, PhysicalEvent, PermanentSpec := "<default>",
		InvokeCallback := false) {
	global _LPHT_Hotkeys, _LPHT_AppOutput
	if PermanentSpec == "<default>"
		PermanentSpec := Spec
	if _LPHT_Hotkeys.Has(Spec) {
		Record := _LPHT_Hotkeys[Spec]
		if Record["predicate"].Call(PermanentSpec) {
			; Never invoke a callback for a route the test expects to pass through.
			; This keeps the regression harness safe even if the old synthetic Send
			; fallback and its broad predicate are accidentally restored together.
			if InvokeCallback
				Record["callback"].Call()
			return "hotkey"
		}
	}
	_LPHT_AppOutput.Push(PhysicalEvent)
	return "app"
}

_LPHT_WithFixture(TestFn) {
	global _LLM_Menu, _LLM_Menu_Loaded, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_Menu_NavHotkeysBound, _LLM_Menu_NavActiveSlot
	global LLM_PROFILE_BUILTIN_ORDER, LLM_PROFILE_HOTKEY_LIMIT
	SavedMenu := _LLM_Menu
	SavedLoaded := _LLM_Menu_Loaded
	SavedOwner := _LLM_Menu_ProfileHotkeyOwner
	SavedFailureCount := _LLM_Menu_ProfileHotkeyFailureCount
	SavedNavBound := _LLM_Menu_NavHotkeysBound
	SavedNavSlot := _LLM_Menu_NavActiveSlot
	SavedCritical := A_IsCritical
	HadBuiltinOrder := IsSet(LLM_PROFILE_BUILTIN_ORDER)
	HadLimit := IsSet(LLM_PROFILE_HOTKEY_LIMIT)
	if HadBuiltinOrder
		SavedBuiltinOrder := LLM_PROFILE_BUILTIN_ORDER
	if HadLimit
		SavedLimit := LLM_PROFILE_HOTKEY_LIMIT
	try {
		_LPHT_ResetPorts()
		_LLM_Menu := Map("enabled", true, "user_profiles", [])
		Loop 5
			_LLM_Menu["user_profiles"].Push(Map("id", "user_" . A_Index))
		_LLM_Menu_Loaded := true
		_LLM_Menu_ProfileHotkeyOwner := 0
		_LLM_Menu_ProfileHotkeyFailureCount := 0
		_LLM_Menu_NavHotkeysBound := []
		_LLM_Menu_NavActiveSlot := 0
		LLM_PROFILE_BUILTIN_ORDER := ["raw", "basic", "advanced",
			"batch_advanced"]
		LLM_PROFILE_HOTKEY_LIMIT := 9
		return TestFn.Call()
	} finally {
		_LLM_Menu := SavedMenu
		_LLM_Menu_Loaded := SavedLoaded
		_LLM_Menu_ProfileHotkeyOwner := SavedOwner
		_LLM_Menu_ProfileHotkeyFailureCount := SavedFailureCount
		_LLM_Menu_NavHotkeysBound := SavedNavBound
		_LLM_Menu_NavActiveSlot := SavedNavSlot
		LLM_PROFILE_BUILTIN_ORDER := HadBuiltinOrder ? SavedBuiltinOrder : unset
		LLM_PROFILE_HOTKEY_LIMIT := HadLimit ? SavedLimit : unset
		_LPHT_ResetPorts()
		Critical(SavedCritical)
	}
}





; ==============================================
; ==============================================
; ======= 2/ Registration fault matrix ========
; ==============================================
; ==============================================

_LPHT_RegistrationFaultMatrixCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LPHT_FaultSpec, _LPHT_FaultMode, _LPHT_CurrentPredicate
	global _LPHT_LogCalls, _LPHT_LogCritical, _LPHT_HotkeyCalls
	global _LPHT_OpenCalls, _LPHT_CloseCalls, _LPHT_ResetCalls
	for FaultMode in ["before", "after"] {
		Loop 9 {
			FaultIndex := A_Index
			_LPHT_ResetPorts()
			_LLM_Menu_ProfileHotkeyOwner := 0
			_LLM_Menu_ProfileHotkeyFailureCount := 0
			_LPHT_FaultSpec := "^" . FaultIndex
			_LPHT_FaultMode := FaultMode
			Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
				_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
			AssertTrue((Result is Integer) && Result == 0,
				"a refused profile registration must return strict false")
			AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map,
				"a partial native pass must never publish readiness")
			AssertEqual(0, _LPHT_EffectiveCount(),
				"every partial raw variant must remain functionally inert")
			Loop 9
				AssertEqual("app", _LPHT_RoutePhysical("^" . A_Index),
					"cold failure must pass every profile chord to the app")
			AssertFalse(HasMethod(_LPHT_CurrentPredicate, "Call"),
				"the dynamic HotIf context must be reset after refusal")
			AssertEqual(0, _LPHT_LogCalls,
				"a retryable refusal must remain silent until the bounded terminal")

			_LPHT_FaultSpec := ""
			_LPHT_FaultMode := ""
			Retry := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
				_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
			AssertTrue((Retry is Integer) && Retry == 1)
			AssertTrue(_LLM_Menu_ProfileHotkeyOwner is Map)
			AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
			AssertEqual(9,
				_LLM_Menu_ProfileHotkeyOwner["plan"].Length)
			AssertEqual(9, _LPHT_EffectiveCount(),
				"the retained retry must reconstruct the complete surface")
			CallsAfterRetry := _LPHT_HotkeyCalls
			OpenAfterRetry := _LPHT_OpenCalls
			CloseAfterRetry := _LPHT_CloseCalls
			ResetAfterRetry := _LPHT_ResetCalls
			PublishedOwner := _LLM_Menu_ProfileHotkeyOwner
			_LPHT_FaultSpec := "^1"
			_LPHT_FaultMode := "before"
			Again := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
				_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
			AssertTrue((Again is Integer) && Again == 1)
			AssertEqual(CallsAfterRetry, _LPHT_HotkeyCalls,
				"a published immutable surface must be an idempotent no-op")
			AssertEqual(OpenAfterRetry, _LPHT_OpenCalls)
			AssertEqual(CloseAfterRetry, _LPHT_CloseCalls)
			AssertEqual(ResetAfterRetry, _LPHT_ResetCalls,
				"a ready owner must not reopen or reset its native HotIf context")
			AssertTrue(_LLM_Menu_ProfileHotkeyOwner == PublishedOwner)
			AssertEqual(9, _LPHT_EffectiveCount())
		}
	}
}

_LPHT_RegistrationFaultMatrix() {
	return _LPHT_WithFixture(_LPHT_RegistrationFaultMatrixCore)
}

Test("[llm-profile-hotkeys] every registration refusal stays inactive and retries",
	_LPHT_RegistrationFaultMatrix)





; =========================================
; =========================================
; ======= 3/ HotIf ownership faults =======
; =========================================
; =========================================

_LPHT_OpenFaultsCore() {
	global _LLM_Menu_ProfileHotkeyOwner, _LPHT_OpenFaultMode
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LPHT_HotkeyCalls, _LPHT_LogCalls, _LPHT_CurrentPredicate
	for Mode in ["before", "after"] {
		_LPHT_ResetPorts()
		_LLM_Menu_ProfileHotkeyOwner := 0
		_LLM_Menu_ProfileHotkeyFailureCount := 0
		_LPHT_OpenFaultMode := Mode
		Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
			_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
		AssertTrue((Result is Integer) && Result == 0)
		AssertEqual(0, _LPHT_HotkeyCalls)
		AssertEqual(0, _LPHT_LogCalls)
		AssertFalse(HasMethod(_LPHT_CurrentPredicate, "Call"),
			"even a post-open throw must close the selected HotIf context")
		AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
	}
}

_LPHT_OpenFaults() {
	return _LPHT_WithFixture(_LPHT_OpenFaultsCore)
}

Test("[llm-profile-hotkeys] HotIf open ambiguity never publishes readiness",
	_LPHT_OpenFaults)

_LPHT_CloseRecoveryCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LPHT_FailCloseRemaining, _LPHT_CloseCalls, _LPHT_ResetCalls
	global _LPHT_CurrentPredicate, _LPHT_CloseThrowAfter
	_LPHT_FailCloseRemaining := 1
	Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
	AssertTrue((Result is Integer) && Result == 1)
	AssertEqual(2, _LPHT_CloseCalls)
	AssertEqual(0, _LPHT_ResetCalls)
	AssertFalse(HasMethod(_LPHT_CurrentPredicate, "Call"))
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner is Map)

	_LPHT_ResetPorts()
	_LLM_Menu_ProfileHotkeyOwner := 0
	_LPHT_FailCloseRemaining := 1
	_LPHT_CloseThrowAfter := true
	Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
	AssertTrue((Result is Integer) && Result == 1)
	AssertEqual(2, _LPHT_CloseCalls)
	AssertEqual(0, _LPHT_ResetCalls)
	AssertFalse(HasMethod(_LPHT_CurrentPredicate, "Call"),
		"a close that applies then throws must still be proven by retry")
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())

	_LPHT_ResetPorts()
	_LLM_Menu_ProfileHotkeyOwner := 0
	_LPHT_FailCloseRemaining := 2
	Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
	AssertTrue((Result is Integer) && Result == 1)
	AssertEqual(2, _LPHT_CloseCalls)
	AssertEqual(1, _LPHT_ResetCalls)
	AssertFalse(HasMethod(_LPHT_CurrentPredicate, "Call"))
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner is Map)
}

_LPHT_CloseRecovery() {
	return _LPHT_WithFixture(_LPHT_CloseRecoveryCore)
}

Test("[llm-profile-hotkeys] HotIf close retries and proven reset can publish",
	_LPHT_CloseRecovery)

_LPHT_ClosePoisonCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LPHT_FailCloseRemaining, _LPHT_FailReset
	global _LPHT_CurrentPredicate, _LPHT_LogCalls, _LPHT_LogCritical
	_LPHT_FailCloseRemaining := 2
	_LPHT_FailReset := true
	Caught := false
	try LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
		_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
	catch as e {
		Caught := true
		AssertTrue(e is TrayRootFatalContextError)
		AssertTrue(InStr(e.Message, "HotIf reset") > 0)
	}
	AssertTrue(Caught,
		"an unproven HotIf reset must never return normal control")
	AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
	AssertTrue(HasMethod(_LPHT_CurrentPredicate, "Call"),
		"the fault seam must prove that the dynamic context stayed selected")
	AssertEqual(1, _LPHT_LogCalls)
	AssertEqual(0, _LPHT_LogCritical,
		"terminal HotIf diagnostics must run after Critical is restored")
}

_LPHT_ClosePoison() {
	return _LPHT_WithFixture(_LPHT_ClosePoisonCore)
}

Test("[llm-profile-hotkeys] unproven HotIf reset fails fast without publication",
	_LPHT_ClosePoison)

_LPHT_InheritedCriticalCore() {
	global _LLM_Menu_ProfileHotkeyOwner, _LPHT_FaultSpec, _LPHT_FaultMode
	global _LPHT_LogCritical
	_LPHT_FaultSpec := "^5"
	_LPHT_FaultMode := "before"
	PreviousCritical := Critical("On")
	try {
		Result := LLM_Menu_BindProfileHotkeys(_LPHT_Hotkey,
			_LPHT_HotIf, _LPHT_Log, _LPHT_ForceReset)
		AssertTrue(A_IsCritical,
			"the binder must restore inherited Critical before returning")
	}
	finally Critical(PreviousCritical)
	AssertTrue((Result is Integer) && Result == 0)
	AssertEqual(-1, _LPHT_LogCritical,
		"a retryable refusal must not emit a diagnostic")
	AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
}

_LPHT_InheritedCritical() {
	return _LPHT_WithFixture(_LPHT_InheritedCriticalCore)
}

Test("[llm-profile-hotkeys] inherited Critical never covers diagnostics",
	_LPHT_InheritedCritical)

_LPHT_NativePassIsSerializedCore() {
	global _LPHT_NativeCriticalSamples, _LPHT_LogCalls
	Status := _LPHT_ProfileBindPort()
	AssertTrue((Status is Integer) && Status == 1)
	AssertEqual(11, _LPHT_NativeCriticalSamples.Length,
		"one complete pass must own open + nine registrations + close")
	for Sample in _LPHT_NativeCriticalSamples
		AssertTrue((Sample is Integer) && Sample > 0,
			"every fallible native registration call must run under one Critical pass")
	AssertEqual(0, _LPHT_LogCalls)
}

_LPHT_NativePassIsSerialized() {
	return _LPHT_WithFixture(_LPHT_NativePassIsSerializedCore)
}

Test("[llm-profile-hotkeys] the complete native pass is serialized",
	_LPHT_NativePassIsSerialized)

_LPHT_TerminalDiagnosticDropsInheritedCriticalCore() {
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	global _LPHT_FaultSpec, _LPHT_FaultMode
	global _LPHT_LogCalls, _LPHT_LogCritical
	_LLM_Menu_ProfileHotkeyFailureCount :=
		_LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1
	_LPHT_FaultSpec := "^5"
	_LPHT_FaultMode := "before"
	PreviousCritical := Critical(37)
	try {
		Status := _LPHT_ProfileBindPort()
		AssertTrue((Status is Integer)
			&& Status == _LLM_PROFILE_HOTKEY_STATUS_DEGRADED)
		AssertEqual(37, A_IsCritical,
			"the exact inherited Critical interval must be restored")
	} finally Critical(PreviousCritical)
	AssertEqual(1, _LPHT_LogCalls)
	AssertEqual(0, _LPHT_LogCritical,
		"the terminal diagnostic must run outside inherited Critical")
}

_LPHT_TerminalDiagnosticDropsInheritedCritical() {
	return _LPHT_WithFixture(
		_LPHT_TerminalDiagnosticDropsInheritedCriticalCore)
}

Test("[llm-profile-hotkeys] terminal diagnostics drop and restore inherited Critical",
	_LPHT_TerminalDiagnosticDropsInheritedCritical)





; =========================================
; =========================================
; ======= 4/ Bounded boot ownership =======
; =========================================
; =========================================

_LPHT_TransientRetriesThenReadyCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
	global _LLM_PROFILE_HOTKEY_STATUS_READY
	global _LPHT_FaultSpec, _LPHT_FaultMode, _LPHT_LogCalls
	AssertTrue((_LLM_PROFILE_HOTKEY_RETRY_LIMIT is Integer)
		&& _LLM_PROFILE_HOTKEY_RETRY_LIMIT >= 2)
	_LPHT_FaultSpec := "^5"
	_LPHT_FaultMode := "before"
	Loop _LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1 {
		Status := _LPHT_ProfileBindPort()
		AssertTrue((Status is Integer) && Status == 0)
		AssertEqual(A_Index, _LLM_Menu_ProfileHotkeyFailureCount)
		AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
		AssertEqual(0, _LPHT_LogCalls)
	}
	_LPHT_FaultSpec := ""
	_LPHT_FaultMode := ""
	Status := _LPHT_ProfileBindPort()
	AssertTrue((Status is Integer)
		&& Status == _LLM_PROFILE_HOTKEY_STATUS_READY)
	AssertEqual(0, _LLM_Menu_ProfileHotkeyFailureCount)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	AssertEqual(9, _LPHT_EffectiveCount())
	AssertEqual(0, _LPHT_LogCalls)
}

_LPHT_TransientRetriesThenReady() {
	return _LPHT_WithFixture(_LPHT_TransientRetriesThenReadyCore)
}

Test("[llm-profile-hotkeys] bounded transient refusals can still publish ready",
	_LPHT_TransientRetriesThenReady)

_LPHT_PersistentRetryDegradesOnceCore() {
	global _LLM_Menu_Loaded, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
	global _LLM_PROFILE_HOTKEY_STATUS_DEGRADED
	global _LPHT_FaultSpec, _LPHT_FaultMode
	global _LPHT_LogCalls, _LPHT_LogCritical, _LPHT_NavCalls
	global _LPHT_HotkeyCalls, _LPHT_OpenCalls, _LPHT_CloseCalls
	global _LPHT_ResetCalls
	_LLM_Menu_Loaded := false
	_LPHT_FaultSpec := "^5"
	_LPHT_FaultMode := "before"
	Loop _LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1 {
		Caught := false
		try _LLM_Menu_RequireFirstRestoreHotkeys(true,
			_LPHT_ProfileBindPort, _LPHT_NavReadyPort)
		catch as e {
			Caught := true
			AssertTrue(e is TrayRootRetryPendingError)
		}
		AssertTrue(Caught)
		AssertEqual(A_Index, _LLM_Menu_ProfileHotkeyFailureCount)
		AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
		AssertEqual(0, _LPHT_NavCalls)
		AssertEqual(0, _LPHT_LogCalls)
		AssertEqual(0, _LPHT_EffectiveCount())
	}

	TerminalResult := _LLM_Menu_RequireFirstRestoreHotkeys(true,
		_LPHT_ProfileBindPort, _LPHT_NavReadyPort)
	AssertTrue((TerminalResult is Integer) && TerminalResult == 1)
	AssertEqual(1, _LPHT_NavCalls)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner is Map)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwnerReady())
	AssertTrue((_LLM_Menu_ProfileHotkeyOwner["ready"] is Integer)
		&& _LLM_Menu_ProfileHotkeyOwner["ready"] == 0)
	AssertTrue((_LLM_Menu_ProfileHotkeyOwner["degraded"] is Integer)
		&& _LLM_Menu_ProfileHotkeyOwner["degraded"] == 1)
	AssertTrue(_LLM_Menu_ProfileHotkeyOwner["plan"] is Array)
	AssertEqual(0, _LLM_Menu_ProfileHotkeyOwner["plan"].Length)
	AssertEqual(_LLM_PROFILE_HOTKEY_RETRY_LIMIT,
		_LLM_Menu_ProfileHotkeyFailureCount)
	AssertEqual(1, _LPHT_LogCalls)
	AssertEqual(0, _LPHT_LogCritical)

	_LLM_Menu_Loaded := true
	Loop 9
		AssertEqual("app", _LPHT_RoutePhysical("^" . A_Index))
	CallsAtTerminal := _LPHT_HotkeyCalls
	OpenAtTerminal := _LPHT_OpenCalls
	CloseAtTerminal := _LPHT_CloseCalls
	ResetAtTerminal := _LPHT_ResetCalls
	Status := _LPHT_ProfileBindPort()
	AssertTrue((Status is Integer)
		&& Status == _LLM_PROFILE_HOTKEY_STATUS_DEGRADED)
	AssertEqual(CallsAtTerminal, _LPHT_HotkeyCalls)
	AssertEqual(OpenAtTerminal, _LPHT_OpenCalls)
	AssertEqual(CloseAtTerminal, _LPHT_CloseCalls)
	AssertEqual(ResetAtTerminal, _LPHT_ResetCalls,
		"a degraded owner must never reopen the dynamic HotIf context")
	AssertEqual(1, _LPHT_LogCalls,
		"a degraded process stays terminal and silent until Reload")
}

_LPHT_PersistentRetryDegradesOnce() {
	return _LPHT_WithFixture(_LPHT_PersistentRetryDegradesOnceCore)
}

Test("[llm-profile-hotkeys] persistent refusal degrades once after a bounded retry",
	_LPHT_PersistentRetryDegradesOnce)

_LPHT_PoisonNeverDegradesCore() {
	global _LLM_Menu_ProfileHotkeyOwner
	global _LLM_Menu_ProfileHotkeyFailureCount
	global _LLM_PROFILE_HOTKEY_RETRY_LIMIT
	global _LPHT_FaultSpec, _LPHT_FaultMode
	global _LPHT_FailCloseRemaining, _LPHT_FailReset
	global _LPHT_LogCalls, _LPHT_LogCritical
	_LPHT_FaultSpec := "^5"
	_LPHT_FaultMode := "before"
	Loop _LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1 {
		PendingStatus := _LPHT_ProfileBindPort()
		AssertTrue((PendingStatus is Integer) && PendingStatus == 0)
	}
	AssertEqual(_LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1,
		_LLM_Menu_ProfileHotkeyFailureCount)
	_LPHT_FaultSpec := ""
	_LPHT_FaultMode := ""
	_LPHT_FailCloseRemaining := 2
	_LPHT_FailReset := true
	Caught := false
	try _LPHT_ProfileBindPort()
	catch as e {
		Caught := true
		AssertTrue(e is TrayRootFatalContextError)
	}
	AssertTrue(Caught)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwner is Map)
	AssertEqual(_LLM_PROFILE_HOTKEY_RETRY_LIMIT - 1,
		_LLM_Menu_ProfileHotkeyFailureCount,
		"an unproven HotIf reset must never consume the degrade budget")
	AssertEqual(1, _LPHT_LogCalls)
	AssertEqual(0, _LPHT_LogCritical)
}

_LPHT_PoisonNeverDegrades() {
	return _LPHT_WithFixture(_LPHT_PoisonNeverDegradesCore)
}

Test("[llm-profile-hotkeys] HotIf poison never degrades into normal boot",
	_LPHT_PoisonNeverDegrades)

_LPHT_OwnerAndLoadedGateCore() {
	global _LLM_Menu_Loaded, _LLM_Menu_ProfileHotkeyOwner
	global _LLM_PROFILE_HOTKEY_PRED, _LPHT_Hotkeys
	ReadyStatus := _LPHT_ProfileBindPort()
	AssertTrue((ReadyStatus is Integer) && ReadyStatus == 1)
	ReadyOwner := _LLM_Menu_ProfileHotkeyOwner
	AssertTrue(_LLM_Menu_ProfileHotkeyOwnerReady())
	AssertEqual(9, ReadyOwner["plan"].Length)
	for Index, Entry in ReadyOwner["plan"] {
		AssertTrue(Entry is Map)
		AssertEqual("^" . Index, Entry["spec"])
		AssertTrue(HasMethod(Entry["callback"], "Call"))
		AssertTrue(_LPHT_Hotkeys[Entry["spec"]]["predicate"]
			== _LLM_PROFILE_HOTKEY_PRED,
			"every retry must reuse the one stable profile HotIf predicate")
	}
	_LLM_Menu_Loaded := false
	AssertEqual(0, _LPHT_EffectiveCount(),
		"a ready profile plan stays inert until the whole LLM module is loaded")
	_LLM_Menu_Loaded := true
	AssertEqual(9, _LPHT_EffectiveCount())

	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", false, "degraded", true, "plan", [])
	AssertEqual(0, _LPHT_EffectiveCount())
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", "1", "degraded", false, "plan", ReadyOwner["plan"])
	AssertEqual(0, _LPHT_EffectiveCount(),
		"non-integer readiness must fail closed")
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", true, "plan", ReadyOwner["plan"])
	AssertEqual(0, _LPHT_EffectiveCount(),
		"a contradictory ready/degraded owner must fail closed")
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false,
		"plan", [1, 2, 3, 4, 5, 6, 7, 8, 9])
	AssertEqual(0, _LPHT_EffectiveCount(),
		"a scalar native plan must fail closed")
	ShortPlan := ReadyOwner["plan"].Clone()
	ShortPlan.Pop()
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false, "plan", ShortPlan)
	AssertEqual(0, _LPHT_EffectiveCount(),
		"an incomplete native plan must fail closed")
	LongPlan := ReadyOwner["plan"].Clone()
	LongPlan.Push(ReadyOwner["plan"][9])
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false, "plan", LongPlan)
	AssertEqual(0, _LPHT_EffectiveCount(),
		"an overlong native plan must fail closed")
	SparsePlan := ReadyOwner["plan"].Clone()
	SparsePlan.Delete(5)
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false, "plan", SparsePlan)
	AssertFalse(_LLM_Menu_ProfileHotkeyOwnerReady(),
		"a sparse native plan must fail closed without reading an unset slot")
	AssertEqual(0, _LPHT_EffectiveCount())
	BadSpecPlan := ReadyOwner["plan"].Clone()
	BadSpecPlan[1] := Map("spec", "^2",
		"callback", ReadyOwner["plan"][1]["callback"])
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false, "plan", BadSpecPlan)
	AssertEqual(0, _LPHT_EffectiveCount(),
		"a duplicated native spec must fail closed")
	BadCallbackPlan := ReadyOwner["plan"].Clone()
	BadCallbackPlan[1] := Map("spec", "^1", "callback", 0)
	_LLM_Menu_ProfileHotkeyOwner := Map(
		"ready", true, "degraded", false, "plan", BadCallbackPlan)
	AssertEqual(0, _LPHT_EffectiveCount(),
		"an uncallable native callback must fail closed")
	_LLM_Menu_ProfileHotkeyOwner := ReadyOwner
	AssertEqual(9, _LPHT_EffectiveCount())
}

_LPHT_OwnerAndLoadedGate() {
	return _LPHT_WithFixture(_LPHT_OwnerAndLoadedGateCore)
}

Test("[llm-profile-hotkeys] only a complete ready owner activates after loaded",
	_LPHT_OwnerAndLoadedGate)





; =====================================================
; =====================================================
; ======= 8/ Per-index native pass-through gate =======
; =====================================================
; =====================================================

_LPHT_SetExposedProfileCount(Count) {
	global _LLM_Menu, LLM_PROFILE_BUILTIN_ORDER
	LLM_PROFILE_BUILTIN_ORDER := []
	_LLM_Menu["user_profiles"] := []
	Loop Count
		_LLM_Menu["user_profiles"].Push(Map("id", "range_" . A_Index))
}

_LPHT_ProfileRangeAdmissionCore() {
	Status := _LPHT_ProfileBindPort()
	AssertTrue((Status is Integer) && Status == 1)
	for Count in [0, 1, 4, 9] {
		_LPHT_SetExposedProfileCount(Count)
		Loop 9 {
			Index := A_Index
			AssertEqual(Index <= Count, _LPHT_IsEffective("^" . Index),
				"only Ctrl+digits backed by a published profile may suppress input")
		}
	}
}

_LPHT_ProfileRangeAdmission() {
	return _LPHT_WithFixture(_LPHT_ProfileRangeAdmissionCore)
}

Test("[llm-profile-hotkeys] profile range is decided before native suppression",
	_LPHT_ProfileRangeAdmission)

_LPHT_ProfileRangeRoutesExactlyOnceCore() {
	global _LPHT_AppOutput, _LPHT_SelectedProfiles
	Status := _LPHT_ProfileBindSelectPort()
	AssertTrue((Status is Integer) && Status == 1)
	for Count in [0, 1, 4, 9] {
		_LPHT_SetExposedProfileCount(Count)
		ExpectedOrder := LLM_Menu_GetHotkeyProfileOrder()
		Loop 9 {
			Index := A_Index
			_LPHT_AppOutput := []
			_LPHT_SelectedProfiles := []
			PhysicalEvent := Map("spec", "^" . Index, "serial", Count * 10 + Index)
			Route := _LPHT_FirePhysical("^" . Index, PhysicalEvent,
				"<default>", Index <= Count)
			if (Index <= Count) {
				AssertEqual("hotkey", Route)
				AssertEqual(1, _LPHT_SelectedProfiles.Length)
				AssertEqual(ExpectedOrder[Index], _LPHT_SelectedProfiles[1],
					"an in-range physical chord must select exactly its published profile")
				AssertEqual(0, _LPHT_AppOutput.Length)
			} else {
				AssertEqual("app", Route)
				AssertEqual(0, _LPHT_SelectedProfiles.Length)
				AssertEqual(1, _LPHT_AppOutput.Length)
				AssertTrue(ObjPtr(_LPHT_AppOutput[1]) == ObjPtr(PhysicalEvent),
					"an out-of-range chord must preserve the exact physical app event")
			}
			AssertEqual(1, _LPHT_SelectedProfiles.Length + _LPHT_AppOutput.Length,
				"each physical chord must have exactly one terminal effect")
		}
	}

	_LPHT_SetExposedProfileCount(9)
	for PermanentSpec in ["^7", "~^7", "$^7"] {
		_LPHT_AppOutput := []
		_LPHT_SelectedProfiles := []
		PhysicalEvent := Map("spec", PermanentSpec)
		AssertEqual("hotkey", _LPHT_FirePhysical("^7", PhysicalEvent,
			PermanentSpec, true))
		AssertEqual("range_7", _LPHT_SelectedProfiles[1],
			"AHK permanent-name decorations must preserve the profile index")
		AssertEqual(0, _LPHT_AppOutput.Length)
	}
	for PermanentSpec in ["*^7", "!^7", "^0", "^10", ""] {
		_LPHT_AppOutput := []
		_LPHT_SelectedProfiles := []
		PhysicalEvent := Map("spec", PermanentSpec)
		AssertEqual("app", _LPHT_FirePhysical("^7", PhysicalEvent,
			PermanentSpec))
		AssertEqual(0, _LPHT_SelectedProfiles.Length)
		AssertEqual(1, _LPHT_AppOutput.Length)
		AssertTrue(ObjPtr(_LPHT_AppOutput[1]) == ObjPtr(PhysicalEvent))
	}

	; The old callback rebuilt Ctrl+7 from the current keyboard layout. This seam
	; models Windows' native ineligible-variant route by retaining the immutable
	; US-bound VK/SC event after the focused app switches to a French layout; the
	; audit still records that no live dual-layout physical probe was run.
	_LPHT_SetExposedProfileCount(4)
	_LPHT_AppOutput := []
	_LPHT_SelectedProfiles := []
	LayoutEvent := Map("vk", 0x37, "sc", 0x08, "ctrl", true,
		"shift", false, "bound_hkl", 0x0409, "current_hkl", 0x040C)
	AssertEqual("app", _LPHT_FirePhysical("^7", LayoutEvent, "$^7"))
	AssertEqual(0, _LPHT_SelectedProfiles.Length)
	AssertEqual(1, _LPHT_AppOutput.Length)
	AssertTrue(ObjPtr(_LPHT_AppOutput[1]) == ObjPtr(LayoutEvent),
		"layout changes must not reconstruct an out-of-range Ctrl+digit chord")
}

_LPHT_ProfileRangeRoutesExactlyOnce() {
	return _LPHT_WithFixture(_LPHT_ProfileRangeRoutesExactlyOnceCore)
}

Test("[llm-profile-hotkeys] profile digits select or pass through exactly once",
	_LPHT_ProfileRangeRoutesExactlyOnce)
