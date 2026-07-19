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
; The fix uses an O(1) appended-position fast path and falls back to a unique
; name scan only when Menu.Add modified an existing duplicate label in place.
; Meta-static because menu_dispatcher.ahk installs an OnMessage WM_COMMAND hook at top
; level and cannot be #Included by the headless runner.
; ==============================================================================

#Requires AutoHotkey v2.0


_RMDU_AssertUniqueIdDiscovery() {
	Body := _DriverFuncBody("RegisterMenuItem")
	Assert(Body != "", "RegisterMenuItem must exist")
	Assert(InStr(Body, "CountBefore := _MenuItemCount(MenuObj)") > 0
		and InStr(Body, "CountAfter := _MenuItemCount(MenuObj)") > 0,
		"RegisterMenuItem must compare native counts around Menu.Add so a true append takes an O(1) ID fast path")
	Assert(InStr(Body, "CountAfter = CountBefore + 1") > 0
		and InStr(Body, "_MenuItemIdAtPosition(MenuObj, CountAfter - 1)") > 0,
		"the append fast path must resolve exactly the newly appended position, not scan sibling labels")
	Assert(InStr(Body, "_FindUniqueMenuItemIdByName(") > 0,
		"duplicate-label in-place updates must retain the UNIQUE-name fallback instead of mis-binding Count-1")
}
Test("menu: RegisterMenuItem uses an append fast path with duplicate-safe fallback (menu-add-duplicate-label-misbind)", _RMDU_AssertUniqueIdDiscovery)
