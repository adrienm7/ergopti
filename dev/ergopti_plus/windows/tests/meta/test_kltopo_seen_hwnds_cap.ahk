; tests/meta/test_kltopo_seen_hwnds_cap.ahk

; ==============================================================================
; MODULE: KLTopo.seen_hwnds Cap Meta-Test
; DESCRIPTION:
; Structural regression for the unbounded-growth fix on KLTopo.seen_hwnds in
; keylogger_window_topology.ahk.
;
; Before the fix, every unique foreground window handle (HWND) seen since
; ErgoptiPlus started was inserted into KLTopo.seen_hwnds and never removed.
; In a long session the Map grew linearly with the number of distinct windows
; that ever became foreground (dialogs, tooltips, pop-ups all contribute). On
; heavy-use machines this accumulates thousands of entries per day and is
; re-serialised with every tick at 1500 ms cadence.
;
; The fix:
;   1. Adds KLTopoConst.SEEN_HWNDS_CAP = 512.
;   2. Clears seen_hwnds when Count >= SEEN_HWNDS_CAP before each insert.
;   3. Clears seen_hwnds and resets prev_hwnd in KL_Topo_Stop().
;
; This test inspects keylogger_window_topology.ahk source and asserts all three.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================================
; ============================================================
; ======= 1/ Assertions ======================================
; ============================================================
; ============================================================

_KTSHC_CapConstantDeclared() {
	src := _DriverDirConcat("modules/keylogger")
	Assert(InStr(src, "SEEN_HWNDS_CAP") > 0,
		"keylogger_window_topology.ahk: KLTopoConst must declare SEEN_HWNDS_CAP to bound seen_hwnds growth")
}
Test("KLTopo: SEEN_HWNDS_CAP constant declared (seen-hwnds-cap)", _KTSHC_CapConstantDeclared)


_KTSHC_CapEnforcedInTick() {
	block := _DriverFuncBody("KL_Topo_Tick")
	Assert(InStr(block, "SEEN_HWNDS_CAP") > 0,
		"keylogger_window_topology.ahk: KL_Topo_Tick() must reference SEEN_HWNDS_CAP to enforce the cap")
	Assert(InStr(block, ".Clear()") > 0,
		"keylogger_window_topology.ahk: KL_Topo_Tick() must call seen_hwnds.Clear() when the cap is reached")
}
Test("KLTopo: KL_Topo_Tick() enforces SEEN_HWNDS_CAP with .Clear() (seen-hwnds-cap)", _KTSHC_CapEnforcedInTick)


_KTSHC_StopClearsSeenHwnds() {
	block := _DriverFuncBody("KL_Topo_Stop")
	Assert(InStr(block, "seen_hwnds") > 0 and InStr(block, ".Clear()") > 0,
		"keylogger_window_topology.ahk: KL_Topo_Stop() must call seen_hwnds.Clear() to free history on stop")
}
Test("KLTopo: KL_Topo_Stop() clears seen_hwnds (seen-hwnds-cap)", _KTSHC_StopClearsSeenHwnds)


_KTSHC_StopResetsPrevHwnd() {
	block := _DriverFuncBody("KL_Topo_Stop")
	Assert(InStr(block, "prev_hwnd") > 0,
		"keylogger_window_topology.ahk: KL_Topo_Stop() must reset prev_hwnd so it does not carry stale state into the next Start()")
}
Test("KLTopo: KL_Topo_Stop() resets prev_hwnd (seen-hwnds-cap)", _KTSHC_StopResetsPrevHwnd)
