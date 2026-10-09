; tests/meta/test_menu_dispatch_callbacks_unbounded_growth.ahk

; ==============================================================================
; MODULE: Menu-Dispatch Unbounded Growth Prune Guard Meta Test
; DESCRIPTION:
; Static source guard for the menu-dispatch-callbacks-unbounded-growth finding.
;
; The dispatch-bypass layer (infra/menu_dispatcher.ahk) records one entry per
; tracked menu item in _MenuDispatchCallbacks / _MenuDispatchLastFire. A full
; tray rebuild calls MenuDispatcher_Reset() to clear both Maps, but
; LLM_Menu_Build() rebuilds ONLY the LLM submenu and is invoked very frequently
; (every settings tweak, model pull, profile change). Before the fix it deleted
; and repopulated its items without ever pruning the freed IDs, so the two Maps
; grew without bound for the process lifetime.
;
; A global reset cannot be used inside LLM_Menu_Build() - it would wipe the
; dispatch tracking of every OTHER live tray menu. The fix adds a per-menu
; prune, MenuDispatcher_PruneMenu(MenuObj), keyed off the live HMENU, and calls
; it from LLM_Menu_Build() after the staged submenu is published.
;
; This is a meta-static test because infra/menu_dispatcher.ahk installs an
; OnMessage(0x0111) hook at include time and the LLM tray menu modules register
; top-level state, so neither can be #Included by the headless runner without
; blocking a clean exit. If the prune helper is removed, or LLM_Menu_Build stops
; calling it, this test fails.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_MDCUG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ===================================================
; ===================================================
; ======= 2/ Prune-helper presence assertions =======
; ===================================================
; ===================================================

_MDCUG_PruneHelperExists() {
	Src := _MDCUG_ReadSource("infra/menu_dispatcher.ahk")
	Assert(InStr(Src, "MenuDispatcher_PruneMenu(MenuObj) {") > 0,
		"menu_dispatcher.ahk must define MenuDispatcher_PruneMenu(MenuObj) - the per-menu prune that drops dead item IDs after a single-menu rebuild")
}
Test("menu_dispatcher: MenuDispatcher_PruneMenu prune helper exists (menu-dispatch-callbacks-unbounded-growth)", _MDCUG_PruneHelperExists)

_MDCUG_PruneDeletesMapEntries() {
	Src := _MDCUG_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("MenuDispatcher_PruneMenu")
	Assert(Seg != "", "MenuDispatcher_PruneMenu(MenuObj) declaration must exist in menu_dispatcher.ahk")
	Assert(InStr(Seg, "_MenuDispatchCallbacks.Delete(") > 0,
		"MenuDispatcher_PruneMenu must Delete() dead entries from _MenuDispatchCallbacks - otherwise the Map still grows without bound")
	Assert(InStr(Seg, "_MenuDispatchLastFire.Delete(") > 0,
		"MenuDispatcher_PruneMenu must Delete() dead entries from _MenuDispatchLastFire - otherwise that Map still grows without bound")
	Assert(InStr(Seg, "GetMenuItemID") > 0,
		"MenuDispatcher_PruneMenu must read the live IDs via GetMenuItemID so it prunes only IDs no longer present in the menu")
}
Test("menu_dispatcher: PruneMenu deletes dead entries from both dispatch Maps (menu-dispatch-callbacks-unbounded-growth)", _MDCUG_PruneDeletesMapEntries)





; ==========================================
; ==========================================
; ======= 3/ Caller wiring assertion =======
; ==========================================
; ==========================================

_MDCUG_BuildCallsPrune() {
	Src := _MDCUG_ReadSource("ui/menu/menu_llm/menu_main.ahk")
	Seg := _DriverFuncBody("LLM_Menu_Build")
	Assert(Seg != "", "LLM_Menu_Build() declaration must exist in menu_main.ahk")
	Assert(InStr(Seg, "MenuDispatcher_PruneMenu(_LLM_Menu_Handle)") > 0,
		"LLM_Menu_Build must prune obsolete dispatcher IDs after it publishes the staged subtree - without it the dispatch Maps leak dead IDs across every rebuild")
	; The global reset must NOT appear here: this is a single-menu rebuild, and a
	; global reset would wipe the dispatch tracking of every other live tray menu.
	Assert(InStr(Seg, "MenuDispatcher_Reset(") == 0,
		"LLM_Menu_Build must NOT call MenuDispatcher_Reset() - that global wipe would drop other live menus' dispatch entries; use the per-menu prune instead")
}
Test("menu_main: LLM_Menu_Build prunes its own menu (not a global reset) (menu-dispatch-callbacks-unbounded-growth)", _MDCUG_BuildCallsPrune)
