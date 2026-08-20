; tests/meta/test_prefix_render_flush_suspend_guard.ahk

; ==============================================================================
; MODULE: _PrefixRenderFlush Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard for LOW-02: _PrefixRenderFlush ignored suspend.
;
; _PrefixRenderFlush runs from a SetTimer and rebuilds the hotstring preview
; tooltip via _LookupAndRender. AHK timer callbacks bypass native Suspend, so a
; render queued just before the script was suspended (password field, manual
; pause) would still paint a preview while the driver is meant to be silent.
;
; The render now delegates to the shared lifecycle predicate immediately after
; canceling its timer. The predicate checks both native Suspend and the captured
; generation, so even a pre-pause callback dispatched after resume stays inert.
; This test verifies the indirection as a whole and its position before render.
;
; SCOPE: source introspection of infra/hotstrings/hotstring_prefix_watcher.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_PRFSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Guard assertion =======================
; ==================================================
; ==================================================

_PRFSG_FlushGuardsSuspend() {
	Src := _PRFSG_ReadSource("infra/hotstrings/hotstring_prefix_watcher.ahk")
	FlushBody := _DriverFuncBody("_PrefixRenderFlush")
	Assert(FlushBody != "", "_PrefixRenderFlush() must exist in hotstring_prefix_watcher.ahk")

	GuardPos := InStr(FlushBody, "_PrefixDeferredCanPublish")
	Assert(GuardPos > 0,
		"_PrefixRenderFlush must call the shared pause+generation predicate — timer callbacks bypass native Suspend (LOW-02)")
	LookupPos := InStr(FlushBody, "_LookupAndRender")
	Assert(LookupPos > 0, "_PrefixRenderFlush must call _LookupAndRender")
	Assert(GuardPos < LookupPos,
		"the lifecycle guard must precede _LookupAndRender so a paused or stale callback never renders a preview (LOW-02)")

	GuardBody := _DriverFuncBody("_PrefixDeferredCanPublish")
	Assert(InStr(GuardBody, "A_IsSuspended") > 0,
		"the shared deferred-callback predicate must still check native A_IsSuspended (LOW-02)")
	Assert(InStr(GuardBody, "_PrefixDeferredGeneration") > 0,
		"the shared deferred-callback predicate must reject a stale lifecycle generation (LOW-02)")
}
Test("meta prefix-render-flush-suspend: _PrefixRenderFlush guards pause and generation (LOW-02)", _PRFSG_FlushGuardsSuspend)
