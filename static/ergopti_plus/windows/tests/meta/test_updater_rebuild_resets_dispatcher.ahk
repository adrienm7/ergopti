; tests/meta/test_updater_rebuild_resets_dispatcher.ahk

; ==============================================================================
; MODULE: Updater Rebuild Resets Menu Dispatcher Meta Test
; DESCRIPTION:
; Regression guard for the AHK-15 fix in the updater tray-rebuild path.
;
; The updater fires SetTimer(-50) callbacks that rebuild the tray menu after a
; channel selection change or background check result. Prior to the fix, these
; rebuilds used a separate dispatcher-reset path. The staged root publication is
; now the single owner of retry invalidation and stale-ID pruning; resetting here
; would erase callbacks registered in detached child menus before they attach.
;
; The fix wraps all updater-originated menu rebuilds in _Updater_RebuildMenu(),
; which calls initMenu(), the single staged publication path used by every tray
; rebuild.
;
; This test asserts:
;   1. _Updater_RebuildMenu is defined in the updater module.
;   2. _Updater_RebuildMenu delegates directly to staged initMenu() and does not
;      perform an unsafe pre-stage dispatcher reset.
;   3. All SetTimer(-50) tray-rebuild calls in the updater go through
;      _Updater_RebuildMenu, not bare initMenu() calls.
;
; SCOPE: source introspection of modules/updater/.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_URRD_ReadSource() {
	return _DriverDirConcat("modules/updater")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_URRD_RebuildMenuWrapperDefined() {
	Src := _URRD_ReadSource()
	Assert(Src != "", "modules/updater/ source must be readable")

	Body := _DriverFuncBody("_Updater_RebuildMenu")
	Assert(Body != "", "_Updater_RebuildMenu must be defined in modules/updater/ — the wrapper is the single point that all updater-originated tray rebuilds must go through (AHK-15)")
}

Test("updater: _Updater_RebuildMenu wrapper is defined (updater-rebuild-resets-dispatcher)",
	_URRD_RebuildMenuWrapperDefined)


_URRD_RebuildMenuUsesStagedPublisher() {
	Body := _DriverFuncBody("_Updater_RebuildMenu")
	Assert(Body != "", "_Updater_RebuildMenu must be defined — prerequisite for this test")

	RebuildPos := InStr(Body, "initMenu()")

	Assert(RebuildPos > 0,
		"_Updater_RebuildMenu must call initMenu() so every updater rebuild uses staged publication")
	Assert(InStr(Body, "MenuDispatcher_Reset()") = 0,
		"_Updater_RebuildMenu must not clear dispatcher Maps before staged child menus publish; TrayMenuStage_Publish owns epoch invalidation and pruning")
}

Test("updater: _Updater_RebuildMenu delegates to staged publication (updater-rebuild-resets-dispatcher)",
	_URRD_RebuildMenuUsesStagedPublisher)


_URRD_NoBareinitMenuInSetTimerCalls() {
	Src := _URRD_ReadSource()
	Assert(Src != "", "modules/updater/ source must be readable")

	; Every SetTimer call targeting a tray rebuild must go through _Updater_RebuildMenu,
	; not invoke initMenu() directly. Count occurrences of the pattern.
	; A direct SetTimer(...initMenu...) without going through the wrapper is a bug.
	BarePattern := "SetTimer((*) => initMenu()"
	Assert(!InStr(Src, BarePattern),
		"updater must not call initMenu() directly via SetTimer — all tray rebuilds must go through _Updater_RebuildMenu() so staged publication remains the single replacement path")
}

Test("updater: no bare initMenu() in SetTimer calls (updater-rebuild-resets-dispatcher)",
	_URRD_NoBareinitMenuInSetTimerCalls)
