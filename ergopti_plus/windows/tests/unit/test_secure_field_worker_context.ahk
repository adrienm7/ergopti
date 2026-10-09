; tests/unit/test_secure_field_worker_context.ahk

; ============================================================================
; MODULE: Secure-field UIA Worker Context Tests
; DESCRIPTION:
; Behavioral regression coverage for the host-window/control-token boundary
; used by the secure-field UIA worker. A worker request belongs to the focused
; control HWND; the top-level HWND supplies the independent window identity.
; ============================================================================

#Requires AutoHotkey v2.0+





; ====================================
; ====================================
; ======= 1/ Worker dispatch seam ====
; ====================================
; ====================================

global _SFDWCTest_RequestCount := 0
global _SFDWCTest_ReceivedContext := 0
global _SFDWCTest_StartCount := 0

_SFDWCTest_CurrentHwnd() {
	return 61002
}

_SFDWCTest_Context() {
	return Map(
		"Hwnd", 61001,
		"Control", 61002,
		"InputEpoch", 61003,
		"ProcName", "secure-field-fixture.exe"
	)
}

_SFDWCTest_Request(Context, Terminal) {
	global _SFDWCTest_RequestCount, _SFDWCTest_ReceivedContext
	_SFDWCTest_RequestCount += 1
	_SFDWCTest_ReceivedContext := Context
	return true
}

_SFDWCTest_Start() {
	global _SFDWCTest_StartCount
	_SFDWCTest_StartCount += 1
	return true
}

_SFDWCTest_ContextMatches(WorkerContext, Result, LiveContext) {
	return true
}





; ====================================
; ====================================
; ======= 2/ Dispatch contract =======
; ====================================
; ====================================

_SFDWCTest_ProbeAcceptsChildControlContext() {
	global SFD_FIELD_CACHE, SFD_UIA_IDLE_REQUIRED_MS
	global _SFDWCTest_RequestCount, _SFDWCTest_ReceivedContext
	global _SFDWCTest_StartCount
	SavedCache := SFD_FIELD_CACHE
	SavedIdleRequiredMs := SFD_UIA_IDLE_REQUIRED_MS
	try {
		; Make the probe immediately eligible without depending on ambient mouse
		; input while the complete suite is running.
		SFD_UIA_IDLE_REQUIRED_MS := 0
		SFD_FIELD_CACHE := Map(
			"hwnd", 0,
			"secure", true,
			"at", 0,
			"element_id", "",
			"focus_generation", 61004,
			"verdict_generation", 0,
			"current_element_id", "",
			"focus_hook", 0,
			"focus_callback", 0,
			"focus_tracking_active", false,
			"pending_hwnd", 0,
			"pending_generation", 0
		)
		_SFDWCTest_RequestCount := 0
		_SFDWCTest_ReceivedContext := 0
		_SFDWCTest_StartCount := 0

		AssertTrue(SFD_ProbeFocusedUia(61002, 61004,
			_SFDWCTest_CurrentHwnd, _SFDWCTest_Context, _SFDWCTest_Request,
			_SFDWCTest_Start, _SFDWCTest_ContextMatches),
			"a UIA probe must accept a focused-control owner with a distinct parent HWND")
		AssertEqual(1, _SFDWCTest_RequestCount,
			"the accepted worker request must receive the complete focused-control context")
		AssertTrue(_SFDWCTest_ReceivedContext is Map
			&& _SFDWCTest_ReceivedContext["Hwnd"] = 61001
			&& _SFDWCTest_ReceivedContext["Control"] = 61002,
			"the worker must preserve distinct top-level and child-control identities")
		AssertEqual(0, _SFDWCTest_StartCount,
			"the worker startup fallback must not run when dispatch accepts the request")
	} finally {
		SFD_FIELD_CACHE := SavedCache
		SFD_UIA_IDLE_REQUIRED_MS := SavedIdleRequiredMs
	}
}

Test("SecureField: UIA probe accepts a distinct focused-control token (secure-field-worker-context)",
	_SFDWCTest_ProbeAcceptsChildControlContext)


; Observe native Map writes and the setter's actual thread-critical marker.
; The callback model below respects that marker; it never uses native timers.
class _SFDP_ObservedCache extends Map {
	Writes := []
	ModelLookup := false
	ModelRequested := 0
	ModelDeferred := 0
	ModelDelivered := 0
	ModelHit := false
	ModelSecure := true
	ThrowKey := ""

	__Item[Key] {
		get => super[Key]
		set {
			this.Writes.Push({ Key: Key, Critical: A_IsCritical })
			if Key == this.ThrowKey
				throw Error("secure-publisher-owned-map-fault")
			super[Key] := value
			if this.ModelLookup && Key == "at" {
				this.ModelRequested += 1
				if A_IsCritical
					this.ModelDeferred += 1
				else {
					this.ModelDelivered += 1
					Secure := true
					this.ModelHit := SFD_TryGetCachedVerdict(81, 7, "old", &Secure)
					this.ModelSecure := Secure
				}
			}
		}
	}
}

_SFDP_NewCache() {
	return _SFDP_ObservedCache("hwnd", 81, "secure", true, "at", 0,
		"element_id", "old", "focus_generation", 7, "verdict_generation", 7,
		"current_element_id", "old", "focus_tracking_active", true)
}

_SFDP_PublicationOwnsAllWrites(PriorCritical, MatchingGeneration, Positive) {
	global SFD_FIELD_CACHE
	SavedCache := SFD_FIELD_CACHE
	SavedCritical := A_IsCritical
	try {
		Critical(PriorCritical ? PriorCritical : "Off")
		Cache := _SFDP_NewCache()
		SFD_FIELD_CACHE := Cache
		Generation := MatchingGeneration ? 7 : 6
		Before := A_TickCount
		SFD_CommitFieldVerdict(82, Positive, Generation, "new")
		After := A_TickCount
		AssertEqual(PriorCritical, A_IsCritical,
			"publication must restore the exact caller critical setting")
		ExpectedKeys := ["secure", "at", "verdict_generation", "element_id"]
		if MatchingGeneration
			ExpectedKeys.Push("current_element_id")
		ExpectedKeys.Push("hwnd")
		AssertEqual(ExpectedKeys.Length, Cache.Writes.Length,
			"the actual setter must publish only the complete owned tuple")
		for Index, Event in Cache.Writes {
			AssertEqual(ExpectedKeys[Index], Event.Key)
			Assert(Event.Critical is Integer && Event.Critical > 0,
				"every actual verdict/identity write must own native Critical")
		}
		AssertEqual(82, Cache["hwnd"])
		AssertEqual(Positive, Cache["secure"])
		Assert(Cache["at"] is Integer && Cache["at"] >= Before
			&& Cache["at"] <= After, "publication must retain the native timestamp")
		AssertEqual(Generation, Cache["verdict_generation"])
		AssertEqual("new", Cache["element_id"])
		AssertEqual(MatchingGeneration ? "new" : "old", Cache["current_element_id"],
			"a stale generation cannot replace the current focused element")
		Secure := true
		ExpectedHit := Positive || MatchingGeneration
		AssertEqual(ExpectedHit, SFD_TryGetCachedVerdict(82, 7, "new", &Secure))
		AssertEqual(ExpectedHit ? Positive : true, Secure)
		OldSecure := true
		AssertEqual(false, SFD_TryGetCachedVerdict(81, 7, "old", &OldSecure))
		AssertEqual(true, OldSecure, "the retired HWND must remain unknown")
	} finally {
		SFD_FIELD_CACHE := SavedCache
		Critical(SavedCritical ? SavedCritical : "Off")
	}
}

for PriorCritical in [0, 17]
	for MatchingGeneration in [false, true]
		for Positive in [false, true]
			Test("secure-publisher-critical: writes critical=" . PriorCritical
				. " matching=" . MatchingGeneration . " secure=" . Positive,
				_SFDP_PublicationOwnsAllWrites.Bind(PriorCritical, MatchingGeneration, Positive))

_SFDP_ModeledLookupDefersUntilPublication(MatchingGeneration) {
	global SFD_FIELD_CACHE
	SavedCache := SFD_FIELD_CACHE
	SavedCritical := A_IsCritical
	try {
		Critical("Off")
		Cache := _SFDP_NewCache()
		Cache.ModelLookup := true
		SFD_FIELD_CACHE := Cache
		SFD_CommitFieldVerdict(82, false, MatchingGeneration ? 7 : 6, "new")
		AssertEqual(0, A_IsCritical)
		AssertEqual(1, Cache.ModelRequested)
		AssertEqual(1, Cache.ModelDeferred,
			"the modeled ordinary callback must observe the native critical marker")
		AssertEqual(0, Cache.ModelDelivered,
			"the marker-respecting model cannot consume a partially published tuple")
		; Drain the model synchronously after publication; no native timer ran.
		Secure := true
		AssertEqual(false, SFD_TryGetCachedVerdict(81, 7, "old", &Secure))
		AssertEqual(true, Secure)
	} finally {
		SFD_FIELD_CACHE := SavedCache
		Critical(SavedCritical ? SavedCritical : "Off")
	}
}
for MatchingGeneration in [false, true]
	Test("secure-publisher-critical: modeled old-owner lookup matching=" . MatchingGeneration,
		_SFDP_ModeledLookupDefersUntilPublication.Bind(MatchingGeneration))

_SFDP_PublicationFailureRestoresNativeCritical(PriorCritical) {
	global SFD_FIELD_CACHE
	SavedCache := SFD_FIELD_CACHE
	SavedCritical := A_IsCritical
	try {
		Critical(PriorCritical ? PriorCritical : "Off")
		Cache := _SFDP_NewCache()
		Cache.ThrowKey := "element_id"
		SFD_FIELD_CACHE := Cache
		Caught := 0
		try SFD_CommitFieldVerdict(82, false, 7, "new")
		catch as Err
			Caught := Err
		Assert(Caught is Error, "the actual Map write fault must escape the publisher")
		AssertEqual("secure-publisher-owned-map-fault", Caught.Message)
		AssertEqual(PriorCritical, A_IsCritical,
			"the caller critical state must survive a publication fault")
		AssertEqual(4, Cache.Writes.Length)
		AssertEqual("element_id", Cache.Writes[4].Key)
		AssertEqual(81, Cache["hwnd"], "failure cannot publish the new final key")
	} finally {
		SFD_FIELD_CACHE := SavedCache
		Critical(SavedCritical ? SavedCritical : "Off")
	}
}
for PriorCritical in [0, 17]
	Test("secure-publisher-critical: fault preserves native critical=" . PriorCritical,
		_SFDP_PublicationFailureRestoresNativeCritical.Bind(PriorCritical))
