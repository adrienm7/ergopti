; tests/meta/test_topo_checkvirtualdesktop_stale_prev_hwnd.ahk

; ==============================================================================
; MODULE: Topology Virtual-Desktop Stale prev_hwnd Meta Test
; DESCRIPTION:
; Static source guard for finding topo-checkvirtualdesktop-stale-prev-hwnd.
;
; The virtual-desktop heuristic used to read KLTopo.prev_hwnd and
; KLTopo.seen_hwnds inside KL_Topo_CheckVirtualDesktop, but the caller updated
; those AFTER the call — so the alive-check and the last-seen gap reasoned over
; an inconsistent mix of outgoing/incoming state, worsening the documented
; Alt+Tab false positives. The fix captures the reference windows explicitly
; in the caller BEFORE mutating module state and delegates the decision to a
; pure function KL_Topo_IsLikelyDesktopSwitch(prev_alive, incoming_last_seen,
; now), which returns false for a recent re-visit (small gap = Alt+Tab) and
; true only for a long-unseen incoming window while the outgoing one is alive.
;
; keylogger_window_topology.ahk registers a top-level SetTimer through
; KL_Topo_Start and depends on Keylogger/KL_AppendLog, so it is NOT in the
; run_all include graph; a behavioral call would be a load-time error that
; hangs the headless runner. Hence this meta-static text scan. If the explicit
; two-argument signature, the pre-capture ordering, or the pure decision
; helper regress, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_TCSP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Heuristic ordering assertions =========
; ==================================================
; ==================================================

; The decision must live in a pure helper that takes the outgoing-alive flag,
; the incoming last-seen tick, and the current time — proving the reference
; windows are passed in rather than re-read from mutated module state.
_TCSP_PureDecisionExists() {
	Src := _TCSP_ReadSource("modules/keylogger/keylogger_window_topology.ahk")
	Assert(InStr(Src, "KL_Topo_IsLikelyDesktopSwitch(prev_alive, incoming_last_seen, now)") > 0,
		"KL_Topo_IsLikelyDesktopSwitch(prev_alive, incoming_last_seen, now) pure decision helper must exist so the heuristic no longer mixes stale prev_hwnd with the incoming hwnd")
}
Test("topo: KL_Topo_IsLikelyDesktopSwitch pure helper exists (topo-checkvirtualdesktop-stale-prev-hwnd)", _TCSP_PureDecisionExists)

; The caller must capture incoming_last_seen BEFORE overwriting seen_hwnds, and
; pass both the outgoing prev_hwnd and that captured value into the check.
_TCSP_PreCaptureBeforeWrite() {
	Src := _TCSP_ReadSource("modules/keylogger/keylogger_window_topology.ahk")
	Seg := _DriverFuncBody("KL_Topo_Tick")
	Assert(Seg != "", "KL_Topo_Tick() declaration must exist")
	CapIdx := InStr(Seg, "incoming_last_seen := KLTopo.seen_hwnds.Has(hwnd)")
	CallIdx := InStr(Seg, "KL_Topo_CheckVirtualDesktop(KLTopo.prev_hwnd, incoming_last_seen)")
	WriteIdx := InStr(Seg, "KLTopo.seen_hwnds[hwnd] := A_TickCount")
	Assert(CapIdx > 0, "incoming_last_seen must be captured from seen_hwnds before the heuristic runs")
	Assert(CallIdx > 0, "KL_Topo_CheckVirtualDesktop must be called with the outgoing prev_hwnd and the captured incoming_last_seen")
	Assert(WriteIdx > 0, "seen_hwnds[hwnd] update must still exist")
	Assert(CapIdx < CallIdx, "incoming_last_seen must be captured before KL_Topo_CheckVirtualDesktop is called")
	Assert(CallIdx < WriteIdx, "KL_Topo_CheckVirtualDesktop must run before seen_hwnds[hwnd] is overwritten, otherwise the gap is computed from fresh state and the heuristic is meaningless")
}
Test("topo: tick captures incoming_last_seen before mutating seen_hwnds (topo-checkvirtualdesktop-stale-prev-hwnd)", _TCSP_PreCaptureBeforeWrite)

; The named gap constant must replace the magic 3000 ms literal.
_TCSP_GapConstantNamed() {
	Src := _TCSP_ReadSource("modules/keylogger/keylogger_window_topology.ahk")
	Assert(InStr(Src, "DESKTOP_SWITCH_MIN_GAP_MS") > 0,
		"The desktop-switch gap threshold must be a named constant (DESKTOP_SWITCH_MIN_GAP_MS), not a magic 3000 literal")
	Seg := _DriverFuncBody("KL_Topo_IsLikelyDesktopSwitch")
	Assert(InStr(Seg, "KLTopoConst.DESKTOP_SWITCH_MIN_GAP_MS") > 0,
		"KL_Topo_IsLikelyDesktopSwitch must compare the gap against KLTopoConst.DESKTOP_SWITCH_MIN_GAP_MS")
}
Test("topo: desktop-switch gap uses named constant (topo-checkvirtualdesktop-stale-prev-hwnd)", _TCSP_GapConstantNamed)
