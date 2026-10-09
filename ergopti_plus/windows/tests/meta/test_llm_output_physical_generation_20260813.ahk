; tests/meta/test_llm_output_physical_generation_20260813.ahk

; ==============================================================================
; MODULE: Deferred LLM output physical-intent generation guard
; DESCRIPTION:
; A_TimeIdlePhysical changes for the key-up that completes an accepted Tab, so
; using its derived timestamp as an admission ticket makes clipboard-mode LLM
; output reject itself. Conversely, millisecond timestamps can alias a second
; key-down. The canonical dispatcher must advance a monotonic generation before
; every physical down/wheel fan-out, never on key-up, and the LLM ticket must use
; that generation rather than the idle timestamp.
; ==============================================================================

#Requires AutoHotkey v2.0

_LLOPG_MethodBody(Src, Declaration) {
	Start := InStr(Src, Declaration)
	if !Start
		return ""
	Depth := 0
	SawOpen := false
	Loop Parse SubStr(Src, Start) {
		if (A_LoopField == "{") {
			Depth += 1
			SawOpen := true
		} else if (A_LoopField == "}") {
			Depth -= 1
			if SawOpen and Depth == 0
				return SubStr(Src, Start, A_Index)
		}
	}
	return ""
}

_LLOPG_DispatcherOwnsPhysicalIntentGeneration() {
	DispatcherSrc := _DriverDirConcat("infra")
	KeyDown := _LLOPG_MethodBody(DispatcherSrc, "static _OnKeyDown(")
	KeyUp := _LLOPG_MethodBody(DispatcherSrc, "static _OnKeyUp(")
	Assert(KeyDown != "" and KeyUp != "",
		"HookDispatcher key-down/up handlers must be readable")
	RecordPos := InStr(KeyDown, 'KS_RecordPhysicalKeyDown(vk, sc, "dispatcher")')
	DispatchPos := InStr(KeyDown, "HookDispatcher.Dispatch(")
	Assert(RecordPos > 0 and DispatchPos > RecordPos,
		"physical generation must advance before a key-down can authorize any subscriber action")
	Assert(InStr(KeyUp, "KS_RecordPhysicalKeyDown") = 0,
		"the matching key-up must not invalidate a deferred action authorized by key-down")

	for Handler in ["_OnLDown", "_OnRDown", "_OnMDown", "_OnX1Down",
			"_OnX2Down", "_OnWheelUp", "_OnWheelDown", "_OnWheelRight",
			"_OnWheelLeft", "_OnWheelMessage"] {
		Body := _LLOPG_MethodBody(DispatcherSrc, "static " . Handler . "(")
		Assert(Body != "" and InStr(Body, "KS_RecordPhysicalInput()") > 0,
			Handler . " must invalidate an admission ticket before processing physical pointer intent")
	}
}

Test("LLM output: dispatcher advances a down-only physical generation (llm-output-atomicity)",
	_LLOPG_DispatcherOwnsPhysicalIntentGeneration)

_LLOPG_PrefixAndDispatcherCollapseOneTabDown() {
	global _KS_PhysicalInputGeneration
	global _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc
	global _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	SavedGeneration := _KS_PhysicalInputGeneration
	SavedVk := _KS_LastPhysicalKeyVk
	SavedSc := _KS_LastPhysicalKeySc
	SavedEpoch := _KS_LastPhysicalKeyEpoch
	SavedSources := _KS_LastPhysicalKeySources
	try {
		_KS_LastPhysicalKeyVk := -1
		_KS_LastPhysicalKeySc := -1
		_KS_LastPhysicalKeyEpoch := -1
		_KS_LastPhysicalKeySources := Map()
		Before := KS_GetPhysicalInputGeneration()
		PrefixGeneration := KS_RecordPhysicalKeyDown(0x09, 0x0F, "prefix", 1000)
		DispatcherGeneration := KS_RecordPhysicalKeyDown(0x09, 0x0F, "dispatcher", 1000)
		AssertEqual(Before + 1, PrefixGeneration,
			"the newest prefix hook must publish the Tab intent before acceptance captures it")
		AssertEqual(PrefixGeneration, DispatcherGeneration,
			"the older dispatcher callback for the same Tab must not invalidate that Tab's deferred paste")
		AssertEqual(PrefixGeneration + 1,
			KS_RecordPhysicalKeyDown(0x09, 0x0F, "prefix", 1001),
			"a repeated Tab down from the first hook must open a distinct physical action")
	} finally {
		_KS_PhysicalInputGeneration := SavedGeneration
		_KS_LastPhysicalKeyVk := SavedVk
		_KS_LastPhysicalKeySc := SavedSc
		_KS_LastPhysicalKeyEpoch := SavedEpoch
		_KS_LastPhysicalKeySources := SavedSources
	}
}

Test("LLM output: two hooks count one Tab exactly once (llm-output-atomicity)",
	_LLOPG_PrefixAndDispatcherCollapseOneTabDown)

_LLOPG_MissingPeerCannotConsumeNextSameKeyEvent() {
	global _KS_PhysicalInputGeneration
	global _KS_LastPhysicalKeyVk, _KS_LastPhysicalKeySc
	global _KS_LastPhysicalKeyEpoch, _KS_LastPhysicalKeySources
	SavedGeneration := _KS_PhysicalInputGeneration
	SavedVk := _KS_LastPhysicalKeyVk
	SavedSc := _KS_LastPhysicalKeySc
	SavedEpoch := _KS_LastPhysicalKeyEpoch
	SavedSources := _KS_LastPhysicalKeySources
	try {
		for FirstSource in ["dispatcher", "prefix"] {
			SecondSource := FirstSource == "dispatcher" ? "prefix" : "dispatcher"
			_KS_LastPhysicalKeyVk := -1
			_KS_LastPhysicalKeySc := -1
			_KS_LastPhysicalKeyEpoch := -1
			_KS_LastPhysicalKeySources := Map()
			Before := _KS_PhysicalInputGeneration
			OnlyHookGeneration := KS_RecordPhysicalKeyDown(
				0x09, 0x0F, FirstSource, 2000)
			NextFirstGeneration := KS_RecordPhysicalKeyDown(
				0x09, 0x0F, SecondSource, 2001)
			NextPeerGeneration := KS_RecordPhysicalKeyDown(
				0x09, 0x0F, FirstSource, 2001)
			AssertEqual(Before + 1, OnlyHookGeneration,
				FirstSource . "-only event must still open one generation")
			AssertEqual(OnlyHookGeneration + 1, NextFirstGeneration,
				"a missing peer must not leave residue that consumes the next same-key physical event")
			AssertEqual(NextFirstGeneration, NextPeerGeneration,
				"both callbacks of the next real event must still collapse by their shared physical epoch")
		}
	} finally {
		_KS_PhysicalInputGeneration := SavedGeneration
		_KS_LastPhysicalKeyVk := SavedVk
		_KS_LastPhysicalKeySc := SavedSc
		_KS_LastPhysicalKeyEpoch := SavedEpoch
		_KS_LastPhysicalKeySources := SavedSources
	}
}

Test("LLM output: a dropped hook cannot consume the next Tab (llm-output-atomicity)",
	_LLOPG_MissingPeerCannotConsumeNextSameKeyEvent)

_LLOPG_PrefixRecordsBeforeTabAdmission() {
	Prefix := _DriverFuncBody("_OnPrefixKeyDown")
	RecordPos := InStr(Prefix, 'KS_RecordPhysicalKeyDown(VK, SC, "prefix")')
	AcceptPos := InStr(Prefix, "LLM_Bridge_FeedKeyDownIfActive(VK, true)")
	Assert(RecordPos > 0 and AcceptPos > RecordPos,
		"the newer prefix InputHook must record Tab before its LLM acceptance path captures the generation")
}

Test("LLM output: prefix hook records intent before accepting Tab (llm-output-atomicity)",
	_LLOPG_PrefixRecordsBeforeTabAdmission)

_LLOPG_AdmissionUsesGenerationNotIdleTimestamp() {
	Capture := _DriverFuncBody("_LLM_Bridge_CaptureAdmissionSeed")
	Recheck := _DriverFuncBody("_LLM_Bridge_TextAdmissionStillCurrent")
	Policy := _DriverFuncBody("_LLM_Bridge_TextAdmissionMatches")
	Combined := Capture . Recheck . Policy
	Assert(InStr(Capture, "KS_GetPhysicalInputGeneration()") > 0
		and InStr(Recheck, "KS_GetPhysicalInputGeneration()") > 0,
		"capture and last-moment recheck must read the same monotonic physical generation")
	Assert(InStr(Combined, "KS_GetPhysicalInputEpoch") = 0
		and InStr(Combined, "A_TimeIdlePhysical") = 0,
		"LLM admission must not use an idle timestamp which changes on Tab-up and aliases within one millisecond")
}

Test("LLM output: admission ignores Tab-up but rejects later intent (llm-output-atomicity)",
	_LLOPG_AdmissionUsesGenerationNotIdleTimestamp)
