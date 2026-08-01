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
; The fix adds "if A_IsSuspended\n\treturn" right after the SetTimer cancel and
; before the suppression check, so a paused script never renders. This test
; extracts the function body, asserts A_IsSuspended is present, and asserts it
; precedes _LookupAndRender, so a regression that drops the guard fails CI.
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

	SuspendPos := InStr(FlushBody, "A_IsSuspended")
	Assert(SuspendPos > 0,
		"_PrefixRenderFlush must check A_IsSuspended — timer callbacks bypass native Suspend (LOW-02)")
	LookupPos := InStr(FlushBody, "_LookupAndRender")
	Assert(LookupPos > 0, "_PrefixRenderFlush must call _LookupAndRender")
	Assert(SuspendPos < LookupPos,
		"A_IsSuspended guard must precede _LookupAndRender so a paused script never renders a preview (LOW-02)")
}
Test("meta prefix-render-flush-suspend: _PrefixRenderFlush guards A_IsSuspended (LOW-02)", _PRFSG_FlushGuardsSuspend)
