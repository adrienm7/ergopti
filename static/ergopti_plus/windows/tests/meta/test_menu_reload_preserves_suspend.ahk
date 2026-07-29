; tests/meta/test_menu_reload_preserves_suspend.ahk

; ==============================================================================
; MODULE: Menu Reload Preserves Suspend Meta Test
; DESCRIPTION:
; Regression guard for menu-reload-drops-suspend.
;
; AHK's Reload starts a fresh process that is never suspended, and the driver had
; no suspend persistence at all. The tray menu is the ONE surface that stays
; fully interactive while paused -- native Suspend disarms hotkeys and hotstrings
; but never a tray WM_COMMAND -- so it is also the only surface that can reach a
; Reload from the paused state. Every menu action that persists a setting and
; reloads (feature toggles, letter pickers, gesture slots, metrics filters,
; tap-hold options) therefore brought the driver back FULLY ARMED, with the
; « Suspendre » checkmark gone and not one line in the log to explain it.
;
; ROOT CAUSE ENCODED: no function in the tray-menu layer may call a bare Reload;
; they must all route through ReloadPreservingSuspend, which persists the pause
; before reloading, and the boot restore must CONSUME the marker before applying
; it so a crash cannot wedge the driver paused forever.
;
; The offender class is derived from the ui/menu tree via _DriverDirConcat, so a
; new menu action that reaches for a bare Reload fails here without anyone having
; to remember to add it to a list.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================================
; =================================================================
; ======= 1/ No bare Reload anywhere in the tray-menu layer =======
; =================================================================
; =================================================================

_MRS_NoBareReloadInTheMenuLayer() {
	Src := _StripFullLineComments(_DriverDirConcat("ui/menu"))
	Assert(StrLen(Src) > 10000, "the ui/menu source tree must be readable for this scan to mean anything")

	Offenders := ""
	Count := 0
	for Line in StrSplit(Src, "`n", "`r") {
		if RegExMatch(Line, "^\s*Reload\s*(\(\s*\))?\s*$") {
			Count += 1
			Offenders .= (Offenders == "" ? "" : ", ") . Trim(Line)
		}
	}
	Assert(Count == 0,
		"no tray-menu function may call a bare Reload: a tray click is reachable while A_IsSuspended, "
		. "and Reload starts a fresh, unsuspended process, so the user's pause is dropped silently. "
		. "Route it through ReloadPreservingSuspend() (menu-reload-drops-suspend) -- found "
		. Count . ": " . Offenders)

	Routed := 0
	Pos := 1
	while (Found := InStr(Src, "ReloadPreservingSuspend()", , Pos)) {
		Routed += 1
		Pos := Found + 1
	}
	Assert(Routed >= 10,
		"the tray-menu layer must still reload through ReloadPreservingSuspend at its persist-and-"
		. "restart sites -- a scan that found none would pass section 1 vacuously (found "
		. Routed . ")")
}
Test("menu: no tray-menu action calls a bare Reload (menu-reload-drops-suspend)",
	_MRS_NoBareReloadInTheMenuLayer)





; ===========================================================
; ===========================================================
; ======= 2/ The hand-off actually persists the pause =======
; ===========================================================
; ===========================================================

_MRS_HelperPersistsBeforeReloading() {
	Body := _DriverFuncBody("ReloadPreservingSuspend")
	Assert(Body != "", "ReloadPreservingSuspend() must exist in the driver source")

	GuardPos  := InStr(Body, "A_IsSuspended")
	MarkerPos := InStr(Body, "_SuspendMarkerPath()")
	ReloadPos := InStr(Body, "Reload()")
	Assert(GuardPos > 0 and MarkerPos > GuardPos and ReloadPos > MarkerPos,
		"ReloadPreservingSuspend must check A_IsSuspended and write the hand-off marker BEFORE it "
		. "reloads -- the fresh process is never suspended and nothing else carries the state across")
}
Test("menu: ReloadPreservingSuspend persists the pause before reloading (menu-reload-drops-suspend)",
	_MRS_HelperPersistsBeforeReloading)





; ==========================================================
; ==========================================================
; ======= 3/ The boot restore consumes then applies ========
; ==========================================================
; ==========================================================

_MRS_BootRestoreConsumesTheMarkerFirst() {
	Restore := _DriverFuncBody("_SuspendRestoreFromMarker")
	Assert(Restore != "", "_SuspendRestoreFromMarker() must exist in the driver source")

	DeletePos  := InStr(Restore, "FileDelete(")
	SuspendPos := InStr(Restore, "ToggleSuspend()")
	Assert(DeletePos > 0 and SuspendPos > DeletePos,
		"the hand-off marker must be CONSUMED before the pause is re-applied -- a failure past that "
		. "point must cost one restored pause, never wedge the driver suspended on every future boot")
	Assert(!InStr(Restore, "Suspend(1)"),
		"the restore must re-enter the pause through ToggleSuspend, the one path that runs the "
		. "custom-combination prefix drain: a Reload can land while a prefix key is still physically "
		. "held, which is the exact state that drain exists for")

	Watchdog := _DriverFuncBody("_SuspendStateWatchdog")
	Assert(Watchdog != "", "_SuspendStateWatchdog must exist in the driver source")
	Assert(InStr(Watchdog, "_SuspendRestoreFromMarker") > 0,
		"the boot restore must be wired into the suspend watchdog, otherwise the marker is written on "
		. "every menu-driven Reload and never consumed -- the pause would still be lost, and now with "
		. "a stale file left behind")
}
Test("menu: the boot restore consumes the suspend marker before applying it (menu-reload-drops-suspend)",
	_MRS_BootRestoreConsumesTheMarkerFirst)
