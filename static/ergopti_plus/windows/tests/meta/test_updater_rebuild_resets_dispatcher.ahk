; tests/meta/test_updater_rebuild_resets_dispatcher.ahk

; ==============================================================================
; MODULE: Updater Rebuild Resets Menu Dispatcher Meta Test
; DESCRIPTION:
; Regression guard for the AHK-15 fix in the updater tray-rebuild path.
;
; The updater fires SetTimer(-50) callbacks that rebuild the tray menu after a
; channel selection change or background check result. Prior to the fix, these
; rebuilds called initMenu() directly without first calling MenuDispatcher_Reset().
; The menu-item dispatch Maps (_MenuDispatchCallbacks, _MenuDispatchLastFire) were
; never cleared, so reused item IDs from the new menu could fire the OLD callback
; from a previous build — a silent misfire that sent the user to the wrong settings
; screen or triggered the wrong install path.
;
; The fix wraps all updater-originated menu rebuilds in _Updater_RebuildMenu(),
; which calls MenuDispatcher_Reset() BEFORE initMenu(). This mirrors the same
; reset already present in RebuildTrayMenu (menu_rebuild.ahk) for the non-updater
; rebuild path.
;
; This test asserts:
;   1. _Updater_RebuildMenu is defined in the updater module.
;   2. _Updater_RebuildMenu calls MenuDispatcher_Reset() before initMenu().
;   3. All SetTimer(-50) tray-rebuild calls in the updater go through
;      _Updater_RebuildMenu, not bare initMenu() calls.
;
; SCOPE: source introspection of lib/updater/.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_URRD_ReadSource() {
	return _DriverDirConcat("lib/updater")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_URRD_RebuildMenuWrapperDefined() {
	Src := _URRD_ReadSource()
	Assert(Src != "", "lib/updater/ source must be readable")

	Body := _DriverFuncBody("_Updater_RebuildMenu")
	Assert(Body != "", "_Updater_RebuildMenu must be defined in lib/updater/ — the wrapper is the single point that all updater-originated tray rebuilds must go through (AHK-15)")
}

Test("updater: _Updater_RebuildMenu wrapper is defined (updater-rebuild-resets-dispatcher)",
	_URRD_RebuildMenuWrapperDefined)


_URRD_RebuildMenuResetsDispatcherFirst() {
	Body := _DriverFuncBody("_Updater_RebuildMenu")
	Assert(Body != "", "_Updater_RebuildMenu must be defined — prerequisite for this test")

	ResetPos  := InStr(Body, "MenuDispatcher_Reset()")
	RebuildPos := InStr(Body, "initMenu()")

	Assert(ResetPos > 0,
		"_Updater_RebuildMenu must call MenuDispatcher_Reset() — without clearing the dispatch Maps, reused menu IDs from the new build fire the old callbacks from the previous build (AHK-15)")
	Assert(RebuildPos > 0,
		"_Updater_RebuildMenu must call initMenu() to actually rebuild the tray — prerequisite for the ordering check")
	Assert(ResetPos < RebuildPos,
		"MenuDispatcher_Reset() must be called BEFORE initMenu() in _Updater_RebuildMenu — the dispatch Maps must be empty before the new items register their callbacks")
}

Test("updater: _Updater_RebuildMenu calls MenuDispatcher_Reset before initMenu (updater-rebuild-resets-dispatcher)",
	_URRD_RebuildMenuResetsDispatcherFirst)


_URRD_NoBareinitMenuInSetTimerCalls() {
	Src := _URRD_ReadSource()
	Assert(Src != "", "lib/updater/ source must be readable")

	; Every SetTimer call targeting a tray rebuild must go through _Updater_RebuildMenu,
	; not invoke initMenu() directly. Count occurrences of the pattern.
	; A direct SetTimer(...initMenu...) without going through the wrapper is a bug.
	BarePattern := "SetTimer((*) => initMenu()"
	Assert(!InStr(Src, BarePattern),
		"updater must not call initMenu() directly via SetTimer — all tray rebuilds must go through _Updater_RebuildMenu() so MenuDispatcher_Reset() is always called first (AHK-15)")
}

Test("updater: no bare initMenu() in SetTimer calls (updater-rebuild-resets-dispatcher)",
	_URRD_NoBareinitMenuInSetTimerCalls)
