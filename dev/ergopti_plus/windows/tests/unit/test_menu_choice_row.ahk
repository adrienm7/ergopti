; tests/unit/test_menu_choice_row.ahk

; ==============================================================================
; MODULE: A Choice Row Is One Row With Its Values Beneath It
; DESCRIPTION:
; A `choice` row is one setting with a fixed set of values (an enum feature):
; the renderer draws ONE row titled by its key and, beneath it, one row per
; value with the current one ticked. Choosing a value runs the command the
; driver registered for the row, with that value. The shared Lua renderer draws
; the identical row; its fixture cases live in the Linux suite.
;
; ROOT CAUSE ENCODED: the macOS menubar icon was two sibling rows, one per
; variant, each an action of its own — a choice between values drawn as two
; unrelated buttons. The state is read back through GetMenuState on the rendered
; native submenu and the click through the dispatcher's registered callback.
; ==============================================================================

#Requires AutoHotkey v2.0

; The probe row, rendered alone. Returns the rendered menu.
_MCR_Render(Commands, Getters) {
	static PROBE_KEY := "_test_choice_row_probe_menu"
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Root[PROBE_KEY] := [Map(
		"type", "choice", "id", "probe_choice", "path", "ui.probe",
		"i18n", "common.none",
		"choices", [
			Map("value", "v1", "i18n", "common.ok"),
			Map("value", "v2", "i18n", "common.cancel")])]
	try {
		return MenuRenderer_Build(PROBE_KEY, "Layout", Map(), "", Map(), Commands, Getters)
	} finally {
		Root.Delete(PROBE_KEY)
	}
}

; The native submenu hanging off the row at a zero-based position.
_MCR_SubMenuAt(TargetMenu, Position) {
	Handle := DllCall("GetSubMenu", "ptr", TargetMenu.Handle, "int", Position, "ptr")
	Assert(Handle != 0, "the choice row must open a submenu")
	return Handle
}

; True when the row at a zero-based position of a native menu handle is ticked.
_MCR_IsChecked(Handle, Position) {
	static MF_BYPOSITION := 0x400, MF_CHECKED := 0x8
	State := DllCall("GetMenuState", "ptr", Handle, "uint", Position, "uint", MF_BYPOSITION, "uint")
	Assert(State != 0xFFFFFFFF, "GetMenuState must find row " . Position)
	return (State & MF_CHECKED) != 0
}

_MCR_DrawsOneRowWithTheValuesTicked() {
	Rendered := _MCR_Render(Map("probe_choice", (V) => 0), Map("ui.probe", () => "v2"))
	AssertEqual(1, TrayMenuItemCount(Rendered), "a choice is ONE row, not one row per value")
	Sub := _MCR_SubMenuAt(Rendered, 0)
	AssertEqual(2, DllCall("GetMenuItemCount", "ptr", Sub, "int"), "one row per value")
	AssertEqual(false, _MCR_IsChecked(Sub, 0), "v1 is not the current value")
	AssertEqual(true, _MCR_IsChecked(Sub, 1), "the current value is ticked")
}
Test("menu: a choice row draws its values beneath one row, the current one ticked (menu-choice-row)",
	_MCR_DrawsOneRowWithTheValuesTicked)

_MCR_ChoosingRunsTheCommandWithTheValue() {
	global _MenuDispatchCallbacks
	Chosen := []
	Rendered := _MCR_Render(Map("probe_choice", (V) => Chosen.Push(V)), Map("ui.probe", () => "v1"))
	Sub := _MCR_SubMenuAt(Rendered, 0)
	ItemId := DllCall("GetMenuItemID", "ptr", Sub, "int", 1, "uint")
	Assert(_MenuDispatchCallbacks.Has(ItemId), "the value row must be registered with the dispatcher")
	(_MenuDispatchCallbacks[ItemId])()
	AssertEqual(1, Chosen.Length, "choosing a value runs the row's command once")
	AssertEqual("v2", Chosen[1], "with the value chosen")
}
Test("menu: choosing a value runs the row's command with that value (menu-choice-row)",
	_MCR_ChoosingRunsTheCommandWithTheValue)

_MCR_UnregisteredCommandIsNotDrawn() {
	Rendered := _MCR_Render(Map(), Map("ui.probe", () => "v1"))
	AssertEqual(0, TrayMenuItemCount(Rendered), "a choice with no registered command must not be drawn")
}
Test("menu: a choice row whose command is not registered is not drawn (menu-choice-row)",
	_MCR_UnregisteredCommandIsNotDrawn)
