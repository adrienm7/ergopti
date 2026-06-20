; tests/meta/test_dispatcher_map_never_cleared_stale_misfire.ahk

; ==============================================================================
; MODULE: Menu-Dispatcher Stale-Map Misfire Meta Test
; DESCRIPTION:
; Static source guard for finding dispatcher-map-never-cleared-stale-misfire.
;
; The menu-dispatcher bypass keys callbacks by the Win32 menu-item ID, which
; AHK reuses from an internal pool after Menu.Delete(). On a live tray rebuild
; a stale entry left in _MenuDispatchCallbacks / _MenuDispatchLastFire can bind
; a reused ID to a DIFFERENT item's callback; _DispatchIfMissed's 0 == 0
; double-fire guard then fires the WRONG action on a dropped-click retry.
;
; The fix exposes MenuDispatcher_Reset() in lib/menu_dispatcher.ahk (clearing
; both Maps) and calls it at the very start of BOTH rebuild entry points:
; RebuildTrayMenu() in ui/tray_menu.ahk and BuildTrayMenuDeferred() in
; ErgoptiPlus.ahk, BEFORE the InitSubMenus()/initMenu() re-registration pass.
;
; This is a meta-static test (scans source text) because menu_dispatcher.ahk
; calls _MenuDispatcherInit() at top level (registers an OnMessage WM_COMMAND
; hook) and so cannot be #Included by the headless runner without blocking a
; clean exit. If a future refactor drops the reset, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_DMNCSM_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body - from its declaration to the first closing
; brace at column 0. Returns "" when the declaration is absent.
_DMNCSM_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ Reset helper assertions ===============
; ==================================================
; ==================================================

_DMNCSM_ResetHelperClearsBothMaps() {
	Src := _DMNCSM_ReadSource("lib/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("MenuDispatcher_Reset")
	Assert(Seg != "", "MenuDispatcher_Reset() must be defined in menu_dispatcher.ahk")
	; Whitespace-tolerant: the assignments are alignment-padded in the source
	; (one vs two spaces before :=), so collapse runs of spaces before matching.
	NoPad := RegExReplace(Seg, " +:=", " :=")
	Assert(InStr(NoPad, "_MenuDispatchCallbacks := Map()") > 0,
		"MenuDispatcher_Reset must reset _MenuDispatchCallbacks to a fresh Map() so stale reused IDs cannot fire the wrong callback after a rebuild")
	Assert(InStr(NoPad, "_MenuDispatchLastFire := Map()") > 0,
		"MenuDispatcher_Reset must reset _MenuDispatchLastFire to a fresh Map() so a reused IDs LastFire snapshot cannot defeat the double-fire guard")
}
Test("menu_dispatcher: MenuDispatcher_Reset clears both dispatch Maps (dispatcher-map-never-cleared-stale-misfire)", _DMNCSM_ResetHelperClearsBothMaps)




; ==================================================
; ==================================================
; ======= 3/ Rebuild call-site assertions ==========
; ==================================================
; ==================================================

_DMNCSM_RebuildTrayMenuCallsReset() {
	Src := _DMNCSM_ReadSource("ui/tray_menu.ahk")
	Seg := _DriverFuncBody("RebuildTrayMenu")
	Assert(Seg != "", "RebuildTrayMenu() must exist in ui/tray_menu.ahk")
	Assert(InStr(Seg, "MenuDispatcher_Reset()") > 0,
		"RebuildTrayMenu must call MenuDispatcher_Reset() before re-registering items - otherwise stale reused IDs survive the rebuild and can misfire")
}
Test("tray_menu: RebuildTrayMenu calls MenuDispatcher_Reset (dispatcher-map-never-cleared-stale-misfire)", _DMNCSM_RebuildTrayMenuCallsReset)

_DMNCSM_DeferredBuildCallsReset() {
	Src := _DriverSourceConcat()
	Seg := _DriverFuncBody("BuildTrayMenuDeferred")
	Assert(Seg != "", "BuildTrayMenuDeferred() must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "MenuDispatcher_Reset()") > 0,
		"BuildTrayMenuDeferred must call MenuDispatcher_Reset() before InitSubMenus()/initMenu() repopulate the dispatch Maps")
}
Test("ErgoptiPlus: BuildTrayMenuDeferred calls MenuDispatcher_Reset (dispatcher-map-never-cleared-stale-misfire)", _DMNCSM_DeferredBuildCallsReset)
