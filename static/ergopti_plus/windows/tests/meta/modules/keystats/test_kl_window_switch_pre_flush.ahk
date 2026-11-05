; tests/meta/modules/keystats/test_kl_window_switch_pre_flush.ahk

; ==============================================================================
; MODULE: Keystats Window Switch Pre-Flush Order Meta Test
; DESCRIPTION:
; Static source guard for finding T-W09.
;
; KL_Hook_RefreshContext() handles two distinct change events: an app switch
; (NewApp != prev_app) and a title-only change (NewTitle != prev_title) that
; occurs without an app switch, e.g. switching tabs inside a browser. In the
; title-change branch, KL_FlushBuffer() MUST be called BEFORE
; KL_LogWindowSwitch() so that the typing buffer is attributed to the previous
; window context rather than the incoming one.
;
; Without this ordering the chars typed in the old tab are written into the new
; tab's context record, corrupting per-window metrics. The app-switch branch
; already enforces this ordering (M-01 fix); this guard ensures the title-only
; branch obeys the same invariant and that the two calls are never accidentally
; swapped during a future refactor.
;
; ROOT CAUSE ENCODED: The byte offset of "KL_FlushBuffer" must be strictly less
; than the byte offset of "KL_LogWindowSwitch" inside the title-change section
; of KL_Hook_RefreshContext. Any swap makes the test fail immediately.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Source scan helpers =================
; ================================================
; ================================================

_KLWSP_ReadSource(FileName) {
	return _DriverFileSource(FileName)
}

; Extracts the title-change block — the if-block that starts with
; `if (NewTitle != KLHook.prev_title)` — from an already-extracted
; function body. Returns "" when the sentinel line is absent.
_KLWSP_TitleChangeBlock(FuncBody) {
	Sentinel := "if (NewTitle != KLHook.prev_title)"
	Idx := InStr(FuncBody, Sentinel)
	if !Idx
		return ""
	; Return from the sentinel to the end of the function body; that
	; encompasses the entire title-change if-block and is sufficient for
	; the ordering assertions below.
	return SubStr(FuncBody, Idx)
}




; ================================================
; ================================================
; ======= 2/ Ordering assertion ==================
; ================================================
; ================================================

_KLWSP_FlushBeforeWindowSwitch() {
	Drain := _DriverFuncBody("_KL_ContextDrain")
	Prepare := _DriverFuncBody("_KL_ContextPrepare")
	Publish := _DriverFuncBody("_KL_ContextPublishClock")
	PreparePos := InStr(Drain, "_KL_ContextPrepare(")
	PublishPos := InStr(Drain, "_KL_ContextPublishClock(")
	Assert(PreparePos > 0 && PublishPos > PreparePos,
		"Every app/title frame must finish its genuine buffer preparation before publishing either switch")
	FlushPos := InStr(Prepare, "KL_FlushBuffer(")
	DetachPos := InStr(Prepare, "_KL_DetachBufferSnapshot()")
	QueuePos := InStr(Prepare, "Keystats._retry_snapshots.Push(Snapshot)")
	ProjectPos := InStr(Prepare, "Keystats.session_app := Frame.NewApp")
	PreparedPos := InStr(Prepare, "Frame.Prepared := true")
	Assert(DetachPos > 0 && QueuePos > DetachPos && ProjectPos > QueuePos
		&& FlushPos > ProjectPos && PreparedPos > FlushPos,
		"Outgoing typing must be detached before the fresh destination is named; clock preparation still requires the real flush return")
	Assert(InStr(Prepare, "Frame.App.Required || Frame.Title.Required") > 0,
		"Title-only changes must require the same real typing drain as app changes")
	Assert(InStr(Publish, "KL_LogWindowSwitch(Frame.OldApp, Frame.OldTitle,") > 0,
		"The prepared frame must actually call the public window producer with its outgoing identities")
}

Test("keystats_hook: KL_FlushBuffer called before KL_LogWindowSwitch on title change",
	_KLWSP_FlushBeforeWindowSwitch)
