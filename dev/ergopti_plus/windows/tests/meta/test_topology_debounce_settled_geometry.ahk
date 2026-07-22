; tests/meta/test_topology_debounce_settled_geometry.ahk

; ==============================================================================
; MODULE: Topology Debounce Settled Geometry Meta Test
; DESCRIPTION:
; Static source guard for the topology-debounce-stale-geometry fix (F39).
;
; When the debounce accumulator sees consecutive ticks of the same change_type,
; it used to increment pending_ticks but NOT update pending_data. That meant the
; first sampled geometry (potentially the overshoot position captured during a
; drag) was what eventually got logged, not the settled position. The fix adds a
; single assignment on the matching-type branch so pending_data always holds the
; most recent geometry sample.
;
; keylogger_window_topology.ahk registers a top-level SetTimer through
; KL_Topo_Start and depends on Keylogger/KL_AppendLog, so it is NOT in the
; run_all include graph; a behavioral call would be a load-time error that hangs
; the headless runner. Hence this meta-static text scan. If the pending_data
; update on the matching-type branch is removed or moved into the else-branch
; only, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Returns the text of the matching-type branch of the debounce block, from the
; opening `if (change_type = KLTopo.pending_type)` up to (but not including)
; the closing `} else {`. Returns "" when the declaration is absent.
_TDSG_MatchingBranch(Src) {
	OpenToken := "if (change_type = KLTopo.pending_type) {"
	ElseToken := "} else {"
	Idx := InStr(Src, OpenToken)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	ElseIdx := InStr(Rest, ElseToken)
	if !ElseIdx
		return Rest
	return SubStr(Rest, 1, ElseIdx - 1)
}




; ==================================================
; ==================================================
; ======= 2/ Debounce geometry assertions ==========
; ==================================================
; ==================================================

; The matching-type branch must update pending_data so the most recent geometry
; sample is used when the debounce threshold is finally reached, not the first
; (potentially mid-drag overshoot) sample.
_TDSG_MatchingBranchUpdatesPendingData() {
	; Move-resilient: scan the keylogger module dir via the framework helper instead
	; of a pinned keylogger_window_topology.ahk read. The branch's opening marker is
	; unique to that file, so the block extractor still scopes to the right branch.
	Src := _DriverDirConcat("modules/keylogger")
	Branch := _TDSG_MatchingBranch(Src)
	Assert(Branch != "",
		"Debounce matching-type branch (if change_type = KLTopo.pending_type) must exist in keylogger_window_topology.ahk")
	Assert(InStr(Branch, "KLTopo.pending_data") > 0,
		"The matching-type branch must assign KLTopo.pending_data := change_data so the settled geometry is logged, not the first overshoot sample (F39)")
}
Test("topo: debounce matching-type branch updates pending_data with latest geometry (topology-debounce-stale-geometry)", _TDSG_MatchingBranchUpdatesPendingData)

; Guard that the fix assignment targets pending_data, not pending_ticks, to
; ensure it cannot be confused with the increment line already present.
_TDSG_PendingDataAssignmentIsPresent() {
	; Move-resilient: scan the keylogger module dir via the framework helper instead
	; of a pinned keylogger_window_topology.ahk read. The branch's opening marker is
	; unique to that file, so the block extractor still scopes to the right branch.
	Src := _DriverDirConcat("modules/keylogger")
	Branch := _TDSG_MatchingBranch(Src)
	Assert(Branch != "",
		"Debounce matching-type branch must exist")
	; The canonical fix line is: KLTopo.pending_data  := change_data
	Assert(InStr(Branch, "KLTopo.pending_data") > 0 and InStr(Branch, "change_data") > 0,
		"The matching-type branch must contain `KLTopo.pending_data := change_data` so the geometry is refreshed on every accumulating tick (F39)")
}
Test("topo: pending_data := change_data present in matching-type branch (topology-debounce-stale-geometry)", _TDSG_PendingDataAssignmentIsPresent)

; Ensure pending_ticks increment is still present in the same branch — the fix
; must ADD the assignment without removing the counter update.
_TDSG_PendingTicksIncrementRetained() {
	; Move-resilient: scan the keylogger module dir via the framework helper instead
	; of a pinned keylogger_window_topology.ahk read. The branch's opening marker is
	; unique to that file, so the block extractor still scopes to the right branch.
	Src := _DriverDirConcat("modules/keylogger")
	Branch := _TDSG_MatchingBranch(Src)
	Assert(Branch != "",
		"Debounce matching-type branch must exist")
	Assert(InStr(Branch, "KLTopo.pending_ticks += 1") > 0,
		"The matching-type branch must still increment KLTopo.pending_ticks; the fix must not remove it (F39 regression guard)")
}
Test("topo: pending_ticks increment still present in matching-type branch (topology-debounce-stale-geometry)", _TDSG_PendingTicksIncrementRetained)