; tests/unit/menu/test_register_duplicate_label.ahk

; ==============================================================================
; MODULE: Menu Registration Duplicate Label Behaviour Tests
; DESCRIPTION:
; Regression guard for menu-add-duplicate-label-misbind, replacing a source
; read of RegisterMenuItem. Menu.Add with a label already present updates that
; row in place without growing the menu, so binding the last position (the
; append fast path) would hand the new callback to another row. The real
; dispatcher registers rows on a private native menu here and reads back which
; native item each callback is bound to.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ In-place label updates =========
; ===========================================
; ===========================================

_RMDL_First(*) {
}

_RMDL_Second(*) {
}

_RMDL_Replacement(*) {
}

_RMDL_DuplicateLabelRebindsItsOwnRow() {
	global _MenuDispatchCallbacks
	Private := Menu()
	try {
		AssertEqual(1, RegisterMenuItem(Private, "Duplicate label first row", _RMDL_First))
		AssertEqual(1, RegisterMenuItem(Private, "Duplicate label second row", _RMDL_Second))
		FirstId := _MenuItemIdAtPosition(Private, 0)
		SecondId := _MenuItemIdAtPosition(Private, 1)
		Assert(FirstId && SecondId && FirstId != SecondId, "the two appended rows have distinct native ids")
		AssertTrue(_MenuDispatchCallbacks[FirstId] == _RMDL_First, "the append fast path binds the appended row")
		AssertTrue(_MenuDispatchCallbacks[SecondId] == _RMDL_Second, "the second append binds the second row")

		AssertEqual(1, RegisterMenuItem(Private, "Duplicate label first row", _RMDL_Replacement),
			"an in-place update of an existing label still registers")
		AssertEqual(2, DllCall("GetMenuItemCount", "ptr", Private.Handle, "int"), "an in-place update adds no row")
		AssertTrue(_MenuDispatchCallbacks[FirstId] == _RMDL_Replacement,
			"the updated label's own row must receive the new callback (menu-add-duplicate-label-misbind)")
		AssertTrue(_MenuDispatchCallbacks[SecondId] == _RMDL_Second,
			"the last row must keep its callback after another label is updated (menu-add-duplicate-label-misbind)")
	} finally {
		try Private.Delete()
		MenuDispatcher_PruneMenu(Private)
	}
}
Test("menu: re-registering a label rebinds its own row, not the last one (menu-add-duplicate-label-misbind)",
	_RMDL_DuplicateLabelRebindsItsOwnRow)
