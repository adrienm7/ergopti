; tests/meta/test_changelog_ready_not_stranded.ahk

; ==============================================================================
; MODULE: Regression — the changelog page's "ready" must never be stranded
;         (changelog-ready-not-stranded)
; DESCRIPTION:
; Two halves of one defect, both already found and fixed in the sibling model
; browser and never propagated here:
;
;   (a) _CLW_OnWebMessage put its `if A_IsSuspended / return` BEFORE the
;       Msg == "ready" branch, so pausing the driver (the tray menu stays live —
;       Suspend only disarms hotkeys) swallowed the page-lifecycle signal. The
;       page posts "ready" exactly once, so resuming could not recover it.
;   (b) _CLW_SafetyFlush, the net for exactly that case, called _CLW_FlushQueue()
;       alone — which LATCHES _CLW_Ready without fetching anything. No later
;       message re-triggers the fetch.
;
; Result: a correctly styled, correctly localised window with an empty release
; list, a fully paired Navigating…/Navigation issued log, and no error anywhere.
;
; ROOT CAUSE ENCODED: a lifecycle signal that arrives once must be exempt from
; the suspend gate, and every entry point that latches "the page is ready" must
; run the SAME handler — which is why model_browser routes both of its through
; _LLM_MBW_OnPageReady, with an in-source comment saying the omission left its
; table "permanently EMPTY".
;
; SCOPE: source-level — the changelog window creates a WebView2 host at open time
; and is outside the headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ The suspend guard exempts the lifecycle signal ========
; ==================================================================
; ==================================================================

_CLRS_ReadyIsNotGatedAway() {
	Body := _DriverFuncBody("_CLW_OnWebMessage")
	Assert(Body != "", "_CLW_OnWebMessage must exist in the driver source")

	CapturePos := InStr(Body, "_Updater_ReadManualBridgeMessage(")
	Assert(CapturePos > 0,
		"the bridge must capture manual request provenance before reading the one-shot page message")
	MsgPos := CapturePos > 0 ? InStr(Body, "TryGetWebMessageAsString", , CapturePos) : 0
	Assert(MsgPos > 0, "prerequisite: the handler still reads the page message")
	SessionPos := MsgPos > 0 ? InStr(Body, 'Payload["session"] !== ExpectedSession', , MsgPos) : 0
	ActionPos := SessionPos > 0 ? InStr(Body, 'Action := Payload.Has("action")', , SessionPos) : 0
	ReadyPos := ActionPos > 0 ? InStr(Body, 'if (Action == "ready")', , ActionPos) : 0
	ReadyHandlerPos := ReadyPos > 0
		? InStr(Body, "_CLW_OnPageReady(ExpectedWindowEpoch)", , ReadyPos)
		: 0
	BornPausedPos := ReadyHandlerPos > 0
		? InStr(Body, "Request.BornSuspended", , ReadyHandlerPos)
		: 0
	PolicyPos := BornPausedPos > 0
		? InStr(Body, "_Updater_RequestMayPublish(Request)", , BornPausedPos)
		: 0
	Assert(CapturePos > 0 and MsgPos > CapturePos and SessionPos > MsgPos
		and ActionPos > SessionPos and ReadyPos > ActionPos
		and ReadyHandlerPos > ReadyPos and BornPausedPos > ReadyHandlerPos
		and PolicyPos > BornPausedPos,
		'the authenticated one-shot `ready` lifecycle signal must route before both captured pause gates, while every user action after it remains guarded. Gating `ready` strands the window because resume re-triggers nothing')
}
Test("meta changelog-ready-not-stranded: the suspend guard exempts the page's ready signal",
	_CLRS_ReadyIsNotGatedAway)





; ==================================================================
; ==================================================================
; ======= 2/ Both entry points run the same ready handler ==========
; ==================================================================
; ==================================================================

_CLRS_SafetyFlushRoutesThroughTheReadyHandler() {
	Ready := _DriverFuncBody("_CLW_OnPageReady")
	Assert(Ready != "",
		"_CLW_OnPageReady must exist — one handler for 'the page is ready' is what stops the two entry points from drifting apart, and it is the shape the model browser adopted after the same bug")
	Assert(InStr(Ready, "_CLW_FlushQueue(") > 0,
		"the ready handler must flush the queued i18n/bootstrap scripts")
	Assert(InStr(Ready, "_CLW_FetchAndInject(") > 0,
		"the ready handler must ALSO fetch the releases — flushing alone latches _CLW_Ready and leaves the window permanently empty")

	Flush := _DriverFuncBody("_CLW_SafetyFlush")
	Assert(Flush != "", "_CLW_SafetyFlush must exist in the driver source")
	Assert(InStr(Flush, "_CLW_OnPageReady(") > 0,
		"_CLW_SafetyFlush must route through the shared ready handler. Calling _CLW_FlushQueue() directly is the whole bug: it sets _CLW_Ready := true, so no later message can re-trigger the fetch and the release list stays empty for the life of the window")

	Msgs := _DriverFuncBody("_CLW_OnWebMessage")
	Assert(InStr(Msgs, "_CLW_OnPageReady(") > 0,
		"the ready branch of the message handler must use the same entry point, or the two paths can diverge again exactly as they did")
}
Test("meta changelog-ready-not-stranded: the safety flush and the ready message share one handler",
	_CLRS_SafetyFlushRoutesThroughTheReadyHandler)
