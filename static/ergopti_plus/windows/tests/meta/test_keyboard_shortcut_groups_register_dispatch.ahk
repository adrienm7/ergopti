; tests/meta/test_keyboard_shortcut_groups_register_dispatch.ahk

; ==============================================================================
; MODULE: Keyboard-Shortcut Groups RegisterMenuItem Dispatch Meta Test
; DESCRIPTION:
; Regression guard for HIGH-04: raw Menu.Add drops menu clicks.
;
; The keyboard-shortcut group submenus were built with raw GMenu.Add(Label,
; Callback) for the per-slot picker and the add-slot item. AHK 2.0's WM_COMMAND
; -> menu-callback dispatch silently drops roughly one click in three.
; infra/menu_dispatcher.ahk installs a parallel WM_COMMAND retry path, but ONLY
; for items registered via RegisterMenuItem(MenuObj, Label, Cb).
;
; Since these items used raw .Add, they were never in the retry path and ~30-50%
; of clicks on a slot picker or the add-slot entry silently did nothing.
;
; WHERE THE ROOT CAUSE LIVES NOW: those rows moved onto the manifest "list" type,
; so the wiring happens once, in _MR_RenderRows, for every list on every menu.
; That makes the guard stronger rather than weaker -- it now covers every current
; and future list section, not just the four keyboard groups -- and it moves with
; the code instead of pinning a function that no longer exists.
;
; The parent Menu.Add(Label, SubMenu) call stays raw: a submenu parent carries no
; callback, so it was never in the dispatch path and never dropped a click. That
; was the sanctioned exception before this moved, and it still is.
;
; SCOPE: source introspection of the driver tree.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ The renderer wires every row ==========
; ==================================================
; ==================================================

_KSGRD_RowsUseRegisterMenuItem() {
	Body := _DriverFuncBody("_MR_RenderRows")
	Assert(Body != "", "_MR_RenderRows must exist in the driver source -- the list renderer is where "
		. "every list row is now wired, and a scan over an empty body would pass forever")

	Assert(InStr(Body, "RegisterMenuItem(TargetMenu") > 0,
		"_MR_RenderRows must wire actionable rows via RegisterMenuItem(TargetMenu, ...) so they land "
		. "in the WM_COMMAND retry path (HIGH-04)")

	; The sanctioned raw Adds in the renderer are the two submenu parents, which
	; carry no callback: the nested-rows one (`items`) and the native-Menu one
	; (`submenu`, the transitional hand-over for a tree a driver has already
	; built). A raw Add that passes anything ELSE off the row is the original bug,
	; because a callback added that way misses the WM_COMMAND retry path.
	;
	; The pattern used to forbid every `TargetMenu.Add(Label, Row[…])`, which the
	; `submenu` branch trips while carrying no callback at all — so it names the
	; two allowed fields instead of banning the shape.
	for _, Forbidden in ["action", "fn", "callback"] {
		Assert(!RegExMatch(Body, "TargetMenu\.Add\(\s*Label\s*,\s*Row\[." . Forbidden . "."),
			"_MR_RenderRows must NOT use raw TargetMenu.Add for Row['" . Forbidden . "'] — a callback "
			. "added that way misses the WM_COMMAND retry path; use RegisterMenuItem (HIGH-04)")
	}
}
Test("meta keyboard-shortcut-groups: list rows are wired via RegisterMenuItem (HIGH-04)", _KSGRD_RowsUseRegisterMenuItem)




; ==================================================
; ==================================================
; ======= 2/ The provider builds no menu ===========
; ==================================================
; ==================================================

_KSGRD_ProviderReturnsData() {
	; The provider must hand over DATA. One that built a Menu itself would be
	; wiring rows outside the renderer again, which is how the raw-Add bug got in.
	Body := _DriverFuncBody("KeyboardSlotRows")
	Assert(Body != "", "KeyboardSlotRows must exist in the driver source")

	Assert(!InStr(Body, "Menu()"),
		"KeyboardSlotRows must return row data, never build a Menu -- the renderer owns the menu shape")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"KeyboardSlotRows must not register menu items itself")
	Assert(InStr(Body, '"label"') > 0,
		"KeyboardSlotRows must produce labelled rows")
}
Test("meta keyboard-shortcut-groups: the slot provider returns data, not a menu", _KSGRD_ProviderReturnsData)
