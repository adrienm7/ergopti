; tests/meta/test_dispatcher_register_duplicate_label.ahk

; ==============================================================================
; MODULE: RegisterMenuItem Duplicate-Label Id Discovery Meta Test
; DESCRIPTION:
; Static source guard for finding menu-add-duplicate-label-misbind (F-M05).
;
; RegisterMenuItem discovered the just-added item's Win32 ID via
; GetMenuItemID(HMENU, GetMenuItemCount - 1), trusting that Menu.Add appends. But
; AHK v2 Menu.Add with an already-present ItemName MODIFIES the existing item in
; place and does NOT grow the menu (verified live: before=2, after=2). So when two
; menu items share a label (e.g. two personal-hotstring sections with the same
; description), Count-1 points at an unrelated item and the dispatch bypass binds to
; the wrong callback — clicking the duplicate runs a different item's action. The
; Insert path already guarded this via _FindUniqueMenuItemIdByName (degrade to native
; dispatch on >1 match); the Add path did not.
;
; The fix resolves the id by unique name and returns 0 (native dispatch) on ambiguity.
; Meta-static because menu_dispatcher.ahk installs an OnMessage WM_COMMAND hook at top
; level and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0


_RMDU_AssertUniqueIdDiscovery() {
	Body := _DriverFuncBody("RegisterMenuItem")
	Assert(Body != "", "RegisterMenuItem must exist")
	Assert(InStr(Body, "_FindUniqueMenuItemIdByName(") > 0,
		"RegisterMenuItem must resolve the item id by UNIQUE name match, not GetMenuItemCount-1 — Menu.Add modifies-in-place on a duplicate label so Count-1 mis-binds the dispatch bypass (menu-add-duplicate-label-misbind)")
	Assert(!InStr(Body, "Count - 1") and !InStr(Body, "Count-1"),
		"RegisterMenuItem must not discover the id via GetMenuItemID(.., Count - 1) (menu-add-duplicate-label-misbind)")
}
Test("menu: RegisterMenuItem resolves item id by unique name, not Count-1 (menu-add-duplicate-label-misbind)", _RMDU_AssertUniqueIdDiscovery)
