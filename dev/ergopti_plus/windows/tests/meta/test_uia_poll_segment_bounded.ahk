; tests/meta/test_uia_poll_segment_bounded.ahk

; ==============================================================================
; MODULE: UIA Selection-Poll Bounding Meta Test
; DESCRIPTION:
; Regression guard for uia-poll-segment-unbounded.
;
; _UIA_SelectionPollTick is the driver's only unattended repeating cross-process
; COM round trip, and it runs on the SAME message thread that dispatches
; keystrokes (asserted independently by tests/meta/test_hotpath_segment_coverage).
;
; MEASURED 2026-07-29, one 31-minute session: 2993 ticks exceeded the 5 ms
; hot-path threshold, mean 14.3 ms, worst 301.0 ms. Windows will not wait past
; LowLevelHooksTimeout (~300 ms) for a low-level keyboard hook — past it the
; keystroke is delivered WITHOUT the hook's verdict and the hook may be
; uninstalled. So this is silent data loss, not a slow feel.
;
; TWO ROOT CAUSES ENCODED, because the driver's own comment stated the first one
; and the code did not implement it:
;   1. The UIA timeout clamp bounds each individual COM CALL. The probe makes
;      five, so a provider answering just under the per-call limit each time
;      still owns the thread for a multiple of it. The SEGMENT needs its own
;      deadline, checked BETWEEN hops, and abandoning must fall to the same "no
;      selection" state every other early exit uses.
;   2. The gates decided whether to START a probe but not whether one was WORTH
;      starting. A selection cannot appear unless the focus moved or the user
;      touched the input stream, yet the poll repeated the full round trip twice
;      a second on a completely idle machine. Skipping probes whose inputs are
;      identical to the previous one removes that without weakening anything —
;      and both release signals must remain, or a real selection could be missed.
;
; SCOPE: source introspection. The probe needs a live UIA provider, a focused
; window and a ready driver phase, none of which this runner has; the same
; constraint that makes test_hotpath_segment_coverage source-level.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==============================================================
; ==============================================================
; ======= 1/ The whole probe is bounded, not each call ==========
; ==============================================================
; ==============================================================

_UPB_Body() {
	Body := _DriverFuncBody("_UIA_SelectionPollTick")
	Assert(Body != "", "_UIA_SelectionPollTick() must exist in the driver source")
	return Body
}

_UPB_SegmentHasItsOwnDeadline() {
	; Read the constant from SOURCE, not from the runtime global:
	; modules/keymap/layout.ahk is outside this runner's include graph, so the
	; global does not exist here and an IsSet() check would fail against correct
	; code — the selective-loading trap recorded in PROJECT_MEMORY.
	Src := _DriverSourceConcat()
	Assert(RegExMatch(Src, "global\s+UIA_SELECTION_SEGMENT_BUDGET_MS\s*:=\s*([0-9]+)", &BudgetM) > 0,
		"a named budget for the whole probe must exist — the per-call timeout clamp cannot bound a five-hop "
		. "sequence (uia-poll-segment-unbounded)")
	Budget := BudgetM[1] + 0
	Assert(Budget > 0 and Budget < 300,
		"the probe budget must sit strictly below Windows' ~300 ms LowLevelHooksTimeout: at or past it, the "
		. "keystroke is delivered without the hook's verdict, which is the data loss this bound exists to prevent "
		. "(found " . Budget . " ms)")

	Body := _UPB_Body()
	DeadlinePos := InStr(Body, "Deadline :=")
	Assert(DeadlinePos > 0,
		"_UIA_SelectionPollTick must compute a deadline for the whole probe (uia-poll-segment-unbounded)")

	FocusPos := InStr(Body, "UIA.GetFocusedElement")
	Assert(FocusPos > 0, "prerequisite: the probe must still make the focused-element round trip")
	Assert(DeadlinePos < FocusPos,
		"the deadline must be computed BEFORE the first COM hop — a deadline taken afterwards cannot bound it")

	; A bound that is only tested once, after every hop, is not a bound: the point
	; is to stop paying for the hops that have not happened yet.
	Checks := 0
	Pos := 1
	while (Found := InStr(Body, "A_TickCount > Deadline", , Pos)) {
		Checks += 1
		Pos := Found + 1
	}
	Assert(Checks >= 3,
		"the deadline must be re-checked BETWEEN the COM hops (found " . Checks . " check(s)). Checking once at the "
		. "end measures the overrun instead of preventing it, and the hops are exactly what has to be skipped")

	GetTextPos := InStr(Body, "GetText(")
	Assert(GetTextPos > 0, "prerequisite: the probe must still read the selection text")
	LastCheckBeforeText := 0
	Pos := 1
	while (Found := InStr(Body, "A_TickCount > Deadline", , Pos)) {
		if (Found < GetTextPos)
			LastCheckBeforeText := Found
		Pos := Found + 1
	}
	Assert(LastCheckBeforeText > 0 and LastCheckBeforeText < GetTextPos,
		"the deadline must be checked before GetText — that is the hop that asks a provider for a document range "
		. "and the one most able to block")
}

; Abandoning must land on the SAFE state. Leaving the previous snapshot in place
; would let a wrap act on a selection that may no longer exist, which is worse
; than doing nothing: WrapTextIfSelected erases and retypes what it wraps.
_UPB_AbandonFallsToNoSelection() {
	Body := _UPB_Body()
	Pos := 1
	Bounded := 0
	while (Found := InStr(Body, "A_TickCount > Deadline", , Pos)) {
		Pos := Found + 1
		; The branch body follows the condition; the clear must be inside it, before
		; the next deadline check or the end of the function.
		Next := InStr(Body, "A_TickCount > Deadline", , Pos)
		Chunk := (Next > 0) ? SubStr(Body, Found, Next - Found) : SubStr(Body, Found)
		if (InStr(Chunk, "_UIA_SelectionCache := 0") > 0)
			Bounded += 1
	}
	Assert(Bounded >= 3,
		"every deadline bail-out must clear the selection snapshot (found " . Bounded . " that do). Abandoning a "
		. "probe while leaving the previous snapshot lets a wrap erase and retype text against a selection that may "
		. "be gone (uia-poll-segment-unbounded)")
}




; ==============================================================
; ===== 1.1) An unchanged probe is not repeated ================
; ==============================================================

; The volume half. The skip is only correct because BOTH release signals are
; present: a selection is made by physical input, which moves the idle epoch, and
; a focus change moves the window handle. Losing either one turns this from an
; optimisation into a missed selection.
_UPB_UnchangedInputsAreNotReprobed() {
	Body := _UPB_Body()

	Assert(InStr(Body, "_UIA_LastProbeHwnd") > 0,
		"the poll must remember the window it last probed, or it cannot tell an unchanged state from a new one "
		. "(uia-poll-segment-unbounded)")
	Assert(InStr(Body, "_UIA_LastProbeIdleEpoch") > 0,
		"the poll must remember the input-stream state it last probed under")
	Assert(InStr(Body, "A_TimeIdlePhysical") > 0,
		"the input-stream state must be derived from A_TimeIdlePhysical — physical input is what a user selection "
		. "produces, and it is the signal that must release the skip")

	SkipPos := InStr(Body, "_UIA_LastProbeHwnd ==")
	Assert(SkipPos > 0, "the skip must compare the remembered window against the current one")
	FocusPos := InStr(Body, "UIA.GetFocusedElement")
	Assert(SkipPos < FocusPos,
		"the skip must come BEFORE the COM round trip it is meant to avoid")

	; Both conditions in ONE test: an OR would skip whenever either matched, which
	; would suppress a probe after a real focus change or a real keystroke.
	Chunk := SubStr(Body, SkipPos, 400)
	Assert(InStr(Chunk, "_UIA_LastProbeIdleEpoch ==") > 0 and InStr(Chunk, " and ") > 0,
		"the skip must require BOTH the same window AND the same input-stream state. Releasing on only one of them "
		. "would suppress the probe that follows a real selection gesture, and the tooltip would offer a wrap the "
		. "engine cannot perform")
}


Test("meta uia-poll: the whole probe is bounded, not just each COM call (uia-poll-segment-unbounded)",
	_UPB_SegmentHasItsOwnDeadline)
Test("meta uia-poll: abandoning the probe falls back to no selection (uia-poll-segment-unbounded)",
	_UPB_AbandonFallsToNoSelection)
Test("meta uia-poll: a probe whose inputs are unchanged is not repeated (uia-poll-segment-unbounded)",
	_UPB_UnchangedInputsAreNotReprobed)
