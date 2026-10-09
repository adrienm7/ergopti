; tests/meta/test_insert_id_discovery_label_collision.ahk

; ==============================================================================
; MODULE: Insert-Item ID Discovery Label-Collision Meta Test
; DESCRIPTION:
; Static source guard for finding insert-id-discovery-label-collision.
;
; RegisterMenuItemInsert used to resolve the just-inserted item's Win32 ID by
; matching the visible text (first occurrence). When two items in the same
; HMENU share a label, the bypass bound the OLDER item's ID to the new
; callback; a dropped click on the new item then re-dispatched the wrong
; (or no) action, reintroducing the very drop the bypass exists to cure.
;
; The fix resolves the inserted item by POSITION first: BeforeItem encodes the
; 1-based insert position ("N&"), parsed by _ParseInsertPosition, and the ID is
; read by index via _MenuItemIdAtPosition (GetMenuItemID at a position is
; unambiguous). The name match is only a fallback, and it now requires a UNIQUE
; match (_FindUniqueMenuItemIdByName) so a collision degrades to native dispatch
; instead of binding the wrong ID.
;
; This is a meta-static test (scans source text) because menu_dispatcher.ahk
; calls _MenuDispatcherInit() at top level (registers an OnMessage WM_COMMAND
; hook) and so cannot be #Included by the headless runner without blocking a
; clean exit. If a future refactor reverts to first-match-by-name, this fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_IIDLC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Position-first discovery assertions ===
; ==================================================
; ==================================================

_IIDLC_InsertResolvesByPositionFirst() {
	Src := _IIDLC_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("RegisterMenuItemInsert")
	Assert(Seg != "", "RegisterMenuItemInsert must exist in menu_dispatcher.ahk")
	Assert(InStr(Seg, "_ParseInsertPosition(BeforeItem)") > 0,
		"RegisterMenuItemInsert must derive the insert position from BeforeItem via _ParseInsertPosition - position is unambiguous, text match is not")
	Assert(InStr(Seg, "_MenuItemIdAtPosition(") > 0,
		"RegisterMenuItemInsert must read the inserted item's ID by position via _MenuItemIdAtPosition so duplicate labels cannot collide")
}
Test("menu_dispatcher: RegisterMenuItemInsert resolves ID by position first (insert-id-discovery-label-collision)", _IIDLC_InsertResolvesByPositionFirst)


_IIDLC_NameFallbackIsUniquenessChecked() {
	Src := _IIDLC_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("RegisterMenuItemInsert")
	Assert(InStr(Seg, "_FindUniqueMenuItemIdByName(") > 0,
		"RegisterMenuItemInsert text fallback must use _FindUniqueMenuItemIdByName so a duplicate label degrades to native dispatch instead of binding the wrong ID")
	Assert(InStr(Seg, "_FindMenuItemIdByName(") == 0,
		"RegisterMenuItemInsert must NOT use the old first-match _FindMenuItemIdByName - that bound the wrong ID under label collisions")
}
Test("menu_dispatcher: RegisterMenuItemInsert name fallback is uniqueness-checked (insert-id-discovery-label-collision)", _IIDLC_NameFallbackIsUniquenessChecked)


_IIDLC_UniqueFinderRejectsCollisions() {
	Src := _IIDLC_ReadSource("infra/menu_dispatcher.ahk")
	Seg := _DriverFuncBody("_FindUniqueMenuItemIdByName")
	Assert(Seg != "", "_FindUniqueMenuItemIdByName must be defined in menu_dispatcher.ahk")
	; The finder must count matches and only return when exactly one was found,
	; so two items sharing a label cannot bind to the first occurrence.
	Assert(InStr(Seg, "Matches == 1") > 0,
		"_FindUniqueMenuItemIdByName must return the ID only when exactly one item matches the label (Matches == 1) - a collision must return 0")
}
Test("menu_dispatcher: _FindUniqueMenuItemIdByName returns only on a unique match (insert-id-discovery-label-collision)", _IIDLC_UniqueFinderRejectsCollisions)
