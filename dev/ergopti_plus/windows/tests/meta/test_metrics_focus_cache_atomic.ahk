; tests/meta/test_metrics_focus_cache_atomic.ahk

; ==============================================================================
; MODULE: Metrics Focus Cache Atomic Meta Test
; DESCRIPTION:
; Static source guard for the metrics-focus-cache-atomic finding.
;
; The bounded focus acquisition must not mutate individual cache properties
; directly. It builds a complete candidate, revalidates request ownership, then
; publishes one reference. Validity participates in the same privacy epoch as
; process/title/class identity.
;
; The fix uses a MetricsFocusCache.state object.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_MFCA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Atomicity assertion ====================
; ===================================================
; ===================================================

_MFCA_FocusCacheIsAtomic() {
	Src := _MFCA_ReadSource("infra/metrics/metrics_filters.ahk")
	
	; 1. Verify the class uses a single state object.
	Assert(InStr(Src, "static state :=") > 0, "MetricsFocusCache must use a single 'state' object for atomic updates")
	Assert(InStr(Src, "static process_name :=") == 0, "MetricsFocusCache must NOT have separate process_name property")
	
	; 2. Verify bounded acquisition commits through request ownership and the
	; single swap owner.
	RefreshBody := _DriverFuncBody("_MF_RefreshFocusNonCritical")
	CommitBody := _DriverFuncBody("_MF_CommitFocusRefresh")
	ApplyBody := _DriverFuncBody("_MF_ApplyFocusStateLocked")
	Assert(RefreshBody != "" && CommitBody != "" && ApplyBody != "",
		"focus refresh commit and apply owners must exist")
	Assert(InStr(RefreshBody, "_MF_CommitFocusRefresh(") > 0
		and InStr(RefreshBody, "MetricsFocusCache.state :=") = 0,
		"the bounded acquisition must route every candidate through the generation-fenced commit owner")
	Assert(InStr(CommitBody, "RequestGeneration != MetricsFocusCache.refresh_generation") > 0
		&& InStr(CommitBody, "_MF_ApplyFocusStateLocked") > 0,
		"focus commit must reject stale acquisitions before applying a candidate")
	Assert(InStr(ApplyBody, "MetricsFocusCache.state := Candidate") > 0,
		"the canonical focus publisher must perform one complete reference swap")
	Assert(InStr(ApplyBody, "MetricsFocusCache.generation += 1") > 0,
		"a semantic focus or validity change must advance the journal privacy epoch")
		
	; 3. Verify MF_ShouldFilter captures the reference once.
	BodySF := _DriverFuncBody("MF_ShouldFilter")
	Assert(InStr(BodySF, "s := MF_GetFocusSnapshot()") > 0,
		"MF_ShouldFilter must capture the canonical focus snapshot reference once into a local variable (metrics-focus-cache-atomic)")
}
Test("metrics_filters: MF_RefreshFocus uses build-then-swap (metrics-focus-cache-atomic)", _MFCA_FocusCacheIsAtomic)

_MFCA_PrivacyEpochIgnoresTimestampOnlyRefresh() {
	SavedState := MetricsFocusCache.state
	SavedGeneration := MetricsFocusCache.generation
	SavedRefreshGeneration := MetricsFocusCache.refresh_generation
	try {
		MetricsFocusCache.state := {
			valid: true, last_at: 10, hwnd: 123, process_name: "editor.exe",
			title: "safe", class: "Edit", failure_reason: "", timed_out: false
		}
		MetricsFocusCache.generation := 7
		MetricsFocusCache.refresh_generation := 3
		_MF_PublishFocusState({
			valid: true, last_at: 20, hwnd: 123, process_name: "editor.exe",
			title: "safe", class: "Edit", failure_reason: "", timed_out: false
		})
		AssertEqual(7, MetricsFocusCache.generation,
			"an identical 50ms refresh must not invalidate an in-flight journal")
		_MF_PublishFocusState({
			valid: true, last_at: 30, hwnd: 123, process_name: "editor.exe",
			title: "Private Browsing", class: "Edit", failure_reason: "", timed_out: false
		})
		AssertEqual(8, MetricsFocusCache.generation,
			"a title change that can alter privacy classification must advance the epoch")
	} finally {
		MetricsFocusCache.state := SavedState
		MetricsFocusCache.generation := SavedGeneration
		MetricsFocusCache.refresh_generation := SavedRefreshGeneration
	}
}
Test("metrics filters: privacy epoch changes only on semantic focus changes (metrics-focus-cache-atomic)",
	_MFCA_PrivacyEpochIgnoresTimestampOnlyRefresh)
