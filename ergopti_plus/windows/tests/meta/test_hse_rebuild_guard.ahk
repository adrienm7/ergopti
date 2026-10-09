; tests/meta/test_hse_rebuild_guard.ahk

; ==============================================================================
; MODULE: HSE Rebuild Guard Meta Test
; DESCRIPTION:
; Static source guard for the hse-registry-torn-read-vs-onmessage finding.
;
; Live registry rebuilds (RebuildHotstringsLive) must be protected by a
; generation flag (HSE_RebuildInProgress) so that the OnChar reader thread
; never accesses a cleared or partially repopulated index.
;
; The fix adds the flag in hotstring_engine_main.ahk and wraps the rebuild
; block in tray_menu.ahk with it. HSE_FindMatchAtEnd must return early if
; the flag is set.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_HRG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_HRG_CountText(Haystack, Needle) {
	Count := 0
	Offset := 1
	while (Found := InStr(Haystack, Needle, true, Offset)) {
		Count += 1
		Offset := Found + StrLen(Needle)
	}
	return Count
}


; ===================================================
; ===================================================
; ======= 2/ Rebuild guard assertion ================
; ===================================================
; ===================================================

_HRG_RebuildIsGuarded() {
	; 1. Verify flag exists in engine.
	EngineSrc := _HRG_ReadSource("infra/hotstrings/hotstring_engine_main.ahk")
	Assert(InStr(EngineSrc, "global HSE_RebuildInProgress := false") > 0,
		"HSE_RebuildInProgress global flag must be defined in hotstring_engine_main.ahk")
	
	; 2. Verify HSE_FindMatchAtEnd refuses every registry transition before its
	; first index read. The guard now combines the live-rebuild owner fence with
	; the shorter per-mutation transition depth; pin the semantic ordering rather
	; than the obsolete exact spelling `if HSE_RebuildInProgress`.
	MatchBody := _DriverFuncBody("HSE_FindMatchAtEnd")
	GuardPos := RegExMatch(MatchBody,
		"if\s*\(\s*HSE_RebuildInProgress\s+or\s+HSE_RegistryTransitionDepth\s*>\s*0\s*\)")
	ReturnPos := InStr(MatchBody, 'return ""', true, GuardPos)
	FirstIndexRead := InStr(MatchBody, "HSE_StarByTriggerCS.Count")
	Assert(GuardPos > 0 and ReturnPos > GuardPos
		and FirstIndexRead > ReturnPos,
		"HSE_FindMatchAtEnd must return no match for either rebuild fence before reading any registry index (hse-registry-torn-read-vs-onmessage)")
	
	; 3. Verify the serialized coordinator owns the fence across every pass.
	MenuSrc := _HRG_ReadSource("ui/menu/menu_rebuild.ahk")
	Coordinator := _DriverFuncBody("RebuildHotstringsLive")
	AcquireBody := _DriverFuncBody("_HSLR_RequestAndTryAcquire")
	ReleaseBody := _DriverFuncBody("_HSLR_TryReleaseIfDrained")
	InvariantReleaseBody := _DriverFuncBody("_HSLR_ReleaseAfterInvariantFailure")
	FailureReleaseBody := _DriverFuncBody("_HSLR_TryReleaseFailedGeneration")
	DrainBody := _DriverFuncBody("_HSLR_DrainOwner")
	OnceBody := _DriverFuncBody("_RebuildHotstringsLiveOnce")
	Assert(Coordinator != "" && AcquireBody != "" && ReleaseBody != ""
		&& InvariantReleaseBody != "" && FailureReleaseBody != ""
		&& DrainBody != "" && OnceBody != "",
		"the serialized live-rebuild coordinator and its owner transitions must exist")
	Assert(InStr(Coordinator, "_HSLR_RequestAndTryAcquire") > 0,
		"every live rebuild must pass through the non-reentrant coordinator")
	Assert(InStr(DrainBody, "_RebuildHotstringsLiveOnce()") > 0
		&& _HRG_CountText(MenuSrc, "_RebuildHotstringsLiveOnce(") == 2,
		"only the serialized owner drain may call the unfenced registry-pass helper")
	
	Assert(InStr(AcquireBody, "HSE_RebuildInProgress := true") > 0,
		"owner acquisition must raise HSE_RebuildInProgress before any registry pass")
	Assert(InStr(ReleaseBody, "HSE_RebuildInProgress := false") > 0,
		"idle owner release must lower HSE_RebuildInProgress after every coalesced pass")
	
	Assert(InStr(AcquireBody, 'Critical("On")') > 0
		&& InStr(ReleaseBody, 'Critical("On")') > 0,
		"fence acquire/release must be atomic against AHK pseudo-thread interruption")
	Assert(InStr(OnceBody, "HSE_RebuildInProgress :=") = 0,
		"the yielded rebuild body must never lower or re-raise its coordinator-owned fence between coalesced passes")
	AcquireCritical := InStr(AcquireBody, 'Critical("On")')
	AcquireRequest := InStr(AcquireBody, "_HSLR_RequestedGeneration += 1")
	AcquireCheck := InStr(AcquireBody, "if _HSLR_Active")
	AcquireOwner := InStr(AcquireBody, "_HSLR_Active := true")
	AcquireFence := InStr(AcquireBody, "HSE_RebuildInProgress := true")
	AcquireRestore := InStr(AcquireBody, "Critical(PreviousCritical)")
	Assert(AcquireCritical > 0 && AcquireRequest > AcquireCritical
		&& AcquireCheck > AcquireRequest && AcquireOwner > AcquireCheck
		&& AcquireFence > AcquireOwner && AcquireRestore > AcquireFence,
		"request publication, owner claim, and fence raise must share one atomic transition")
	ReleaseCritical := InStr(ReleaseBody, 'Critical("On")')
	ReleaseCheck := InStr(ReleaseBody,
		"_HSLR_PublishedGeneration < _HSLR_RequestedGeneration")
	ReleaseOwner := InStr(ReleaseBody, "_HSLR_Active := false")
	ReleaseFence := InStr(ReleaseBody, "HSE_RebuildInProgress := false")
	ReleaseRestore := InStr(ReleaseBody, "Critical(PreviousCritical)")
	Assert(ReleaseCritical > 0 && ReleaseCheck > ReleaseCritical
		&& ReleaseOwner > ReleaseCheck
		&& ReleaseFence > ReleaseOwner && ReleaseRestore > ReleaseFence,
		"idle release must recheck pending work before lowering the owner and fence atomically")
	FailureCritical := InStr(FailureReleaseBody, 'Critical("On")')
	FailureCheck := InStr(FailureReleaseBody,
		"_HSLR_RequestedGeneration > TargetGeneration")
	FailureOwner := InStr(FailureReleaseBody, "_HSLR_Active := false")
	FailureFence := InStr(FailureReleaseBody, "HSE_RebuildInProgress := false")
	FailureRestore := InStr(FailureReleaseBody, "Critical(PreviousCritical)")
	Assert(FailureCritical > 0 && FailureCheck > FailureCritical
		&& FailureOwner > FailureCheck
		&& FailureFence > FailureOwner && FailureRestore > FailureFence,
		"failure handoff must retain newer work or release the owner and fence in one atomic transition")
	InvariantCritical := InStr(InvariantReleaseBody, 'Critical("On")')
	InvariantOwner := InStr(InvariantReleaseBody, "_HSLR_Active := false")
	InvariantFence := InStr(InvariantReleaseBody, "HSE_RebuildInProgress := false")
	InvariantRestore := InStr(InvariantReleaseBody, "Critical(PreviousCritical)")
	Assert(InvariantCritical > 0 && InvariantOwner > InvariantCritical
		&& InvariantFence > InvariantOwner && InvariantRestore > InvariantFence,
		"invariant-failure release must lower the owner and fence in one atomic transition")
	Assert(_HRG_CountText(DrainBody,
		"_HSLR_TryReleaseFailedGeneration(TargetGeneration)") == 3,
		"every yielded failure exit must preserve an accepted newer generation")
}
Test("hotstring_engine: live rebuild is guarded by HSE_RebuildInProgress (hse-registry-torn-read-vs-onmessage)", _HRG_RebuildIsGuarded)
