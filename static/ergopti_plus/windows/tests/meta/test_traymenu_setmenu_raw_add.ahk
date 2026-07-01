; tests/meta/test_traymenu_setmenu_raw_add.ahk

; ==============================================================================
; MODULE: TrayMenu setMenu RegisterMenuItem-Routing Meta Test
; DESCRIPTION:
; Static source guard for the finding traymenu-setmenu-raw-add-drops-clicks.
;
; adapters/tray_menu.ahk TrayMenuSetMenu() is the contract-sanctioned path the
; cross-platform shared layer drives the Windows tray menu through. AHK 2.0's
; WM_COMMAND -> menu-callback dispatch intermittently drops ~1 click in 3 with
; no error. lib/menu_dispatcher.ahk installs a parallel WM_COMMAND retry path,
; but ONLY for items registered via RegisterMenuItem(MenuObj, Name, Callback).
; The original code used raw A_TrayMenu.Add(ItemTitle, ItemFn) for actionable
; items, so they never joined the retry path and dropped clicks vanished.
;
; The fix: actionable items are routed through RegisterMenuItem(A_TrayMenu, ...)
; and the two-argument raw A_TrayMenu.Add(ItemTitle, ItemFn) is gone (separators
; keep the zero-argument A_TrayMenu.Add()).
;
; This is a meta-static test: TrayMenuSetMenu mutates the live A_TrayMenu and
; now references RegisterMenuItem, which lives in lib/menu_dispatcher.ahk — a
; file NOT in the headless run_all include graph, so calling the function would
; be a load-time error that hangs the CI runner.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_TMRA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Dispatch-routing assertions ============
; ===================================================
; ===================================================

_TMRA_ActionableRoutesThroughRegister() {
	Src := _TMRA_ReadSource("adapters/tray_menu.ahk")
	Seg := _DriverFuncBody("TrayMenuSetMenu")
	Assert(Seg != "", "TrayMenuSetMenu(Items) must exist in adapters/tray_menu.ahk")
	Assert(InStr(Seg, "RegisterMenuItem(A_TrayMenu") > 0,
		"TrayMenuSetMenu must route actionable items through RegisterMenuItem(A_TrayMenu, ...) so they join the WM_COMMAND retry path")
}
Test("tray_menu: actionable items routed through RegisterMenuItem (traymenu-setmenu-raw-add-drops-clicks)", _TMRA_ActionableRoutesThroughRegister)

_TMRA_NoRawActionableAdd() {
	Src := _TMRA_ReadSource("adapters/tray_menu.ahk")
	Seg := _DriverFuncBody("TrayMenuSetMenu")
	; The two-argument raw Add bypasses the dispatch retry and is the bug.
	; Separators keep the zero-argument A_TrayMenu.Add(), which is fine.
	Assert(InStr(Seg, "A_TrayMenu.Add(ItemTitle") = 0,
		"TrayMenuSetMenu must NOT add actionable items via raw A_TrayMenu.Add(ItemTitle, ItemFn) — that bypasses the menu_dispatcher retry and drops clicks")
}
Test("tray_menu: no raw two-arg A_TrayMenu.Add for actionable items (traymenu-setmenu-raw-add-drops-clicks)", _TMRA_NoRawActionableAdd)

_TMRA_ResetsMenuDispatcherBeforeDelete() {
	Seg := _DriverFuncBody("TrayMenuSetMenu")
	ResetPos  := InStr(Seg, "MenuDispatcher_Reset()")
	Assert(ResetPos > 0,
		"TrayMenuSetMenu must call MenuDispatcher_Reset() before clearing the menu -- a raw A_TrayMenu.Delete() leaves stale menu-item IDs in the dispatcher's tracking Maps, which can be recycled by the next Add() and fire the wrong callback")

	DeletePos := InStr(Seg, "A_TrayMenu.Delete()")
	Assert(DeletePos > 0, "TrayMenuSetMenu must still call A_TrayMenu.Delete()")
	Assert(ResetPos < DeletePos,
		"MenuDispatcher_Reset() must run BEFORE A_TrayMenu.Delete() -- resetting after the delete would not prevent the stale-ID recycling it guards against")
}
Test("tray_menu: TrayMenuSetMenu resets the menu dispatcher before clearing the menu (traymenu-stale-id-recycle)",
	_TMRA_ResetsMenuDispatcherBeforeDelete)
