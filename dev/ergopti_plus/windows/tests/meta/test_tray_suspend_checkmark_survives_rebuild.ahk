; tests/meta/test_tray_suspend_checkmark_survives_rebuild.ahk

; ==============================================================================
; MODULE: Tray Suspend Checkmark Survives A Rebuild Meta Test
; DESCRIPTION:
; Regression guard for tray-suspend-checkmark-cleared-by-rebuild.
;
; UpdateTrayIcon() owns the paused indicator, but it is wired only to STATE
; TRANSITIONS (_SuspendStateWatchdog, which returns early when the state has not
; changed) and to the one boot-time build (BuildTrayMenuDeferred). Meanwhile
; TrayMenuStage_Publish destroys and replays the whole tray root, and the suspend
; row was staged as a plain action carrying no state.
;
; So any in-place rebuild that happens while the driver is paused -- an updater
; refresh (_Updater_RebuildMenu is reachable from the download monitor, which is
; guaranteed to run suspended), or RebuildTrayMenu from a tray toggle, since the
; tray menu stays fully clickable while paused -- left « Suspendre » UNCHECKED on
; a still-paused driver. Clicking it then RESUMES, which is the opposite of what
; the unchecked box says.
;
; ROOT CAUSE ENCODED: the row must carry its own checked state at its single
; construction point. Fixing it by adding an UpdateTrayIcon() call to each
; rebuild caller would reproduce the very forgotten-sibling shape the bug is made
; of, so the assertion is anchored on the staging site itself.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================================
; ===========================================================
; ======= 1/ The staged suspend row carries its state =======
; ===========================================================
; ===========================================================

_TSC_StagedSuspendRowReassertsItsCheck() {
	Src := _DriverSourceNoComments()
	Anchor := InStr(Src, "TrayMenuStage_AddAction(MenuSuspend, ToggleSuspend)")
	Assert(Anchor > 0, "the suspend tray row must still be staged via TrayMenuStage_AddAction")

	Seg := SubStr(Src, Anchor, 250)
	Assert(InStr(Seg, "A_IsSuspended") > 0 and InStr(Seg, "TrayMenuStage_Check(MenuSuspend)") > 0,
		"the staged suspend row must re-assert its checked state when A_IsSuspended. "
		. "TrayMenuStage_Publish deletes and rebuilds the whole tray root, so a rebuild while paused "
		. "otherwise leaves the row unchecked -- and clicking it then RESUMES instead of pausing "
		. "(tray-suspend-checkmark-cleared-by-rebuild)")
}
Test("tray: the staged suspend row re-asserts its checkmark when paused (tray-suspend-checkmark-cleared-by-rebuild)",
	_TSC_StagedSuspendRowReassertsItsCheck)





; ============================================================
; ============================================================
; ======= 2/ Why the row has to own it: the two causes =======
; ============================================================
; ============================================================

; Both halves of the bug are prerequisites, not decoration: if either stopped
; being true the staged check would be redundant rather than load-bearing, and
; whoever removes it deserves to be told which assumption changed.
_TSC_PublicationWipesTheRootAndTheWatchdogCannotHelp() {
	Pub := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(Pub != "", "TrayMenuStage_Publish must exist in the driver source")
	Assert(InStr(Pub, "A_TrayMenu.Delete()") > 0,
		"PREREQUISITE: publication still wipes the tray root and replays only the staged entries, "
		. "which is why the checked state must be staged alongside the row")

	Watchdog := _DriverFuncBody("_SuspendStateWatchdog")
	Assert(Watchdog != "", "_SuspendStateWatchdog must exist in the driver source")
	Assert(InStr(Watchdog, "if (A_IsSuspended == _LastSuspendState)") > 0,
		"PREREQUISITE: the suspend watchdog returns early once the transition has been processed, so "
		. "nothing re-asserts the indicator after a later rebuild -- the row cannot delegate its "
		. "state to UpdateTrayIcon()")
}
Test("tray: rebuild wipes the root and the watchdog cannot re-assert the checkmark (tray-suspend-checkmark-cleared-by-rebuild)",
	_TSC_PublicationWipesTheRootAndTheWatchdogCannotHelp)
