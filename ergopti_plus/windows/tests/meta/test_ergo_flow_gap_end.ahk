; tests/meta/test_ergo_flow_gap_end.ahk

; ==============================================================================
; MODULE: Ergo Flow Gap-Reset End Event Test
; DESCRIPTION:
; Regression guard for the dangling flow_window_start bug in KL_Ergo_UpdateBlock.
;
; THE BUG: When a gap >= GAP_RESET_MS (BLOCK_BREAK_MS) interrupted the current
; typing block while a flow window was active, the block-reset path set
; KLErgo.flow_active := false WITHOUT first emitting a flow_window_end event.
; This left the JSONL session log with an open flow_window_start that had no
; matching flow_window_end — corrupting any downstream analytics that pairs
; the two events to compute total flow duration.
;
; THE FIX: Before resetting the block the gap-reset branch now checks
; KLErgo.flow_active and, when true, emits flow_window_end with the accumulated
; stats of the interrupted flow window.
;
; This is a source-level assertion (not a behavioural harness) because
; KL_Ergo_UpdateBlock depends on the live Keylogger global and KL_AppendLog,
; which would require extensive stubbing to drive at runtime. The byte-offset
; check is resilient to unrelated edits and directly encodes the root cause:
; flow_window_end must appear inside the gap-reset branch, before the
; flow_active reset.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckErgoFlowGapEnd() {
	; Move-resilient: scan the keylogger module tree (comments PRESERVED) instead
	; of a pinned keylogger path. Comments must be kept because flow_window_start
	; appears inside KL_Ergo_UpdateBlock only as a comment (the actual emit is
	; delegated to KL_Ergo_CheckFlow), and the ordering assertions depend on it.
	Body := _DriverDirConcat("modules/keylogger")

	; Locate the KL_Ergo_UpdateBlock function definition
	FnPos := InStr(Body, "KL_Ergo_UpdateBlock(delay_ms, now, app, is_bs) {")
	Assert(FnPos > 0,
		"keylogger_ergonomics.ahk must define KL_Ergo_UpdateBlock — entry point not found")

	; Bound the search to the function body: the first column-0 closing brace
	; after the declaration closes the function in this tab-indented codebase
	BodyEnd := InStr(Body, "`n}", false, FnPos)
	if (BodyEnd == 0)
		BodyEnd := StrLen(Body) + 1
	FnBody := SubStr(Body, FnPos, BodyEnd - FnPos)

	; The gap-reset branch is identified by the BLOCK_BREAK_MS guard
	GapBranchPos := InStr(FnBody, "BLOCK_BREAK_MS")
	Assert(GapBranchPos > 0,
		"KL_Ergo_UpdateBlock must contain the BLOCK_BREAK_MS gap-reset guard")

	; Both flow_window_start and flow_window_end must appear in the function body
	StartPos := InStr(FnBody, "flow_window_start")
	Assert(StartPos > 0,
		"KL_Ergo_UpdateBlock must reference flow_window_start (delegates to KL_Ergo_CheckFlow)")

	EndPos := InStr(FnBody, "flow_window_end")
	Assert(EndPos > 0,
		"KL_Ergo_UpdateBlock must emit flow_window_end in the gap-reset branch — "
		. "without it a dangling flow_window_start is left in the JSONL log")

	; flow_window_end must appear BEFORE flow_window_start in the function body:
	; the end event is emitted in the gap-reset block at the top, while the start
	; event is delegated to KL_Ergo_CheckFlow at the bottom
	Assert(EndPos < StartPos,
		"flow_window_end (offset " . EndPos . ") must appear before the flow_window_start "
		. "reference (offset " . StartPos . ") in KL_Ergo_UpdateBlock — the end must be "
		. "emitted in the gap-reset branch, which precedes the KL_Ergo_CheckFlow call")

	; flow_window_end must appear inside the gap-reset branch (before the block reset)
	FlowActiveResetPos := InStr(FnBody, "flow_active   := false")
	Assert(FlowActiveResetPos > 0,
		"KL_Ergo_UpdateBlock must reset KLErgo.flow_active := false")
	Assert(EndPos < FlowActiveResetPos,
		"flow_window_end (offset " . EndPos . ") must be emitted BEFORE flow_active is "
		. "reset to false (offset " . FlowActiveResetPos . ") — the current order emits "
		. "nothing for the interrupted flow window, leaving a dangling start event")
}

Test("meta ergo: flow_window_end emitted on gap-reset before flow_active cleared",
	_MetaCheckErgoFlowGapEnd)