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
; The staged rebuild registers detached child menus before replacing the root,
; so Reset() would erase their dispatcher entries. Publication instead advances
; the retry epoch, attaches the staged tree, then prunes entries not reachable
; from the new root.
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




; ==================================================
; ==================================================
; ======= 2/ Reset helper assertions ===============
; ==================================================
; ==================================================

_DMNCSM_ResetHelperClearsBothMaps() {
	Src := _DMNCSM_ReadSource("infra/menu_dispatcher.ahk")
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

_DMNCSM_StagedPublicationRetiresOldIdsAfterAttach() {
	Src := _DMNCSM_ReadSource("ui/tray_menu.ahk")
	Seg := _DriverFuncBody("TrayMenuStage_Publish")
	Assert(Seg != "", "TrayMenuStage_Publish() must exist in ui/tray_menu.ahk")
	EpochPos := InStr(Seg, "MenuDispatcher_BeginReplacement()")
	DeletePos := InStr(Seg, "A_TrayMenu.Delete()")
	PrunePos := InStr(Seg, "MenuDispatcher_PruneMenu(A_TrayMenu)")
	Assert(EpochPos > 0 and DeletePos > EpochPos and PrunePos > DeletePos,
		"staged publication must invalidate old retry timers, replace the root, then prune unreachable IDs — clearing Maps before detached callbacks are published would silently drop clicks")
}
Test("tray_menu: staged publication retires old dispatcher IDs after attach (dispatcher-map-never-cleared-stale-misfire)", _DMNCSM_StagedPublicationRetiresOldIdsAfterAttach)

_DMNCSM_RebuildUsesStagedInit() {
	Coordinator := _DriverFuncBody("RebuildTrayMenu")
	Worker := _DriverFuncBody("_TrayRootBuildOnce")
	Assert(Coordinator != "", "RebuildTrayMenu() must exist")
	Assert(Worker != "", "_TrayRootBuildOnce() must exist")
	Assert(InStr(Coordinator, "A_TrayMenu.Delete()") = 0
		and InStr(Coordinator, "_TrayRootDrain()") > 0,
		"RebuildTrayMenu must leave the live root intact and delegate to the single tray-root generation owner")
	Assert(InStr(Worker, "initMenu(PublishAuthorizeFn)") > 0,
		"the canonical root worker must carry terminal authorization into initMenu's staged publication")
}
Test("tray_menu: coordinated rebuild delegates root replacement to staged init (dispatcher-map-never-cleared-stale-misfire)", _DMNCSM_RebuildUsesStagedInit)
