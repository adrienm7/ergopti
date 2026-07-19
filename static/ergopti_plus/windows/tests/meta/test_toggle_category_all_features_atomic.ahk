; static/ergopti_plus/windows/tests/meta/test_toggle_category_all_features_atomic.ahk

; ==============================================================================
; MODULE: ToggleCategoryAllFeatures Atomicity Meta Test
; DESCRIPTION:
; Static source guard for finding F39 (live-toggle-critical-window-too-narrow).
;
; ToggleCategoryAllFeatures's live-category branch used to run the snapshot/
; restore step and ApplyMasterGatesToFeatures() completely unprotected, ahead
; of the Critical wrap that only started once RebuildHotstringsLive() was
; entered. A keystroke landing in that window (large category subtrees,
; multiple full-tree loops) could observe transiently inconsistent Features/
; TapHold state via a concurrent #HotIf/InputHook evaluation.
;
; The fix widens the Critical("On") span to start right before the first
; Features mutation (_HSRestoreCategory / _HSSnapshotCategory) and to cover
; the gate flip, TOML write, ApplyMasterGatesToFeatures() and the
; RebuildHotstringsLive() call, released in a finally block — mirroring the
; precedent set by HSE_DisableGroup's Critical wrap (see
; test_hse_disable_group_atomic.ahk).
;
; Meta-static rather than behavioral: the synchronous headless harness cannot
; reproduce the cooperative-threading preemption this guards against, so the
; STRUCTURAL guarantee (the whole mutation window sits inside one Critical
; region) is what we pin.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Atomicity assertion ====================
; ===================================================
; ===================================================

_TCAF_LiveToggleIsAtomic() {
	Body := _DriverFuncBody("ToggleCategoryAllFeatures")
	Assert(Body != "", "ToggleCategoryAllFeatures(Category, Value) declaration must exist in config_io.ahk")

	CritPos := InStr(Body, 'Critical("On")')
	Assert(CritPos > 0,
		"ToggleCategoryAllFeatures must enter Critical around the live-category mutation window so a concurrent #HotIf/InputHook evaluation never observes torn Features/TapHold state")

	RestorePos := InStr(Body, "_HSRestoreCategory(V2Cat)")
	SnapshotPos := InStr(Body, "_HSSnapshotCategory(V2Cat)")
	Assert(RestorePos > 0, "ToggleCategoryAllFeatures must restore the category snapshot on ON")
	Assert(SnapshotPos > 0, "ToggleCategoryAllFeatures must snapshot the category on OFF")
	Assert(CritPos < RestorePos and CritPos < SnapshotPos,
		"Critical must be entered BEFORE the first Features mutation (snapshot/restore), not just before the final rebuild")

	GatesPos := InStr(Body, "ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated")
	Assert(GatesPos > 0, "ToggleCategoryAllFeatures must re-apply master gates before rebuilding")
	Assert(CritPos < GatesPos,
		"Critical must cover the ApplyMasterGatesToFeatures() step, not just the final RebuildHotstringsLive() call")

	RebuildPos := InStr(Body, "RebuildHotstringsLive()")
	Assert(RebuildPos > 0, "ToggleCategoryAllFeatures must rebuild the live hotstring engine")
	Assert(GatesPos < RebuildPos, "master gates must be re-applied before the engine rebuild")

	Assert(InStr(Body, "finally") > 0,
		"ToggleCategoryAllFeatures must release Critical in a finally block so an exception mid-rebuild cannot leak Critical")
	Assert(InStr(Body, "Critical(_TcafCrit)") > 0,
		"ToggleCategoryAllFeatures must restore the prior Critical state after the mutation window (no leaked Critical)")
}
Test("config_io: ToggleCategoryAllFeatures live-category branch is Critical-wrapped end to end (F39)", _TCAF_LiveToggleIsAtomic)
