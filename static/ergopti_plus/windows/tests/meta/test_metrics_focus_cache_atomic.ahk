; tests/meta/test_metrics_focus_cache_atomic.ahk

; ==============================================================================
; MODULE: Metrics Focus Cache Atomic Meta Test
; DESCRIPTION:
; Static source guard for the metrics-focus-cache-atomic finding.
;
; MF_RefreshFocus() must not mutate individual properties of MetricsFocusCache
; directly (which risks a torn read where a reader sees e.g. a new title with
; an old process name). It must build a new state object and publish it via
; a single atomic reference swap.
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
	
	; 2. Verify MF_RefreshFocus publishes via a single swap.
	Body := _DriverFuncBody("MF_RefreshFocus")
	Assert(Body != "", "MF_RefreshFocus must exist in metrics_filters.ahk")
	
	; Look for the assignment to .state
	Assert(InStr(Body, "MetricsFocusCache.state :=") > 0,
		"MF_RefreshFocus must publish the new context via a single assignment to MetricsFocusCache.state (metrics-focus-cache-atomic)")
		
	; 3. Verify MF_ShouldFilter captures the reference once.
	BodySF := _DriverFuncBody("MF_ShouldFilter")
	Assert(InStr(BodySF, "s := MetricsFocusCache.state") > 0,
		"MF_ShouldFilter must capture the MetricsFocusCache.state reference once into a local variable (metrics-focus-cache-atomic)")
}
Test("metrics_filters: MF_RefreshFocus uses build-then-swap (metrics-focus-cache-atomic)", _MFCA_FocusCacheIsAtomic)
