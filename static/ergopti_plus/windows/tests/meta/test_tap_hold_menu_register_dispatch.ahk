; tests/meta/test_tap_hold_menu_register_dispatch.ahk

; ==============================================================================
; MODULE: TapHolds Menu RegisterMenuItem Dispatch Meta Test
; DESCRIPTION:
; Regression guard for HIGH-07: fix-trapholds-menu-raw-add-drops-clicks.
;
; The Tap-Hold submenu's actionable items used raw Menu.Add(Label, Callback) for
; every callback. AHK 2.0's WM_COMMAND -> menu-callback dispatch silently drops
; ~1 click in 3. infra/menu_dispatcher.ahk installs a parallel WM_COMMAND retry
; path, but ONLY for items registered via RegisterMenuItem(MenuObj, Label, Cb).
;
; Since the Tap-Hold block used raw .Add, those items were never in the retry
; path and roughly one in three clicks on reset-defaults, disable-all, per-key
; tap/hold pickers, or per-key disable silently did nothing.
;
; WHERE THE ROOT CAUSE LIVES NOW (2026-08-07): every one of those rows is DATA.
; The two buttons are `command` declarations and the per-key tree is a `list`, so
; the wiring happens once, in _MR_RenderRows, which
; test_keyboard_shortcut_groups_register_dispatch pins to RegisterMenuItem for
; every list on every menu. The same move was made for HIGH-04 and for the same
; reason: a guard on the shared renderer covers every present and future row,
; where a guard on four functions covered four.
;
; What is left to check HERE is the other half — that this menu still hands its
; rows over instead of building them, because a provider that built a Menu again
; would be adding callbacks outside the renderer, which is how the bug got in.
;
; SCOPE: source introspection of the driver tree.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ The buttons are declared ========
; ============================================
; ============================================

_THRD_ButtonsAreCommands() {
	Body := _DriverFuncBody("_BuildTapHoldsSubmenu")
	Assert(Body != "", "_BuildTapHoldsSubmenu must be present in the driver source")

	; Both buttons reach the renderer as named commands. A `command` row is drawn
	; by _MR_RenderToggle/_MR_RenderRows' sibling path, which registers it — the
	; driver never adds it, so it cannot add it raw.
	for _, Id in ["reset_defaults", "disable_all"] {
		Assert(InStr(Body, Chr(34) . Id . Chr(34)) > 0,
			"_BuildTapHoldsSubmenu must pass '" . Id . "' to the renderer as a command (HIGH-07)")
	}
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_BuildTapHoldsSubmenu must not register rows itself — the renderer owns the menu shape")
	; RegExMatch, not InStr: AHK's InStr is case-INSENSITIVE, and this function's
	; OWN name ends in "Submenu()" — which contains "menu()".
	Assert(!RegExMatch(Body, "Menu\(\)"),
		"_BuildTapHoldsSubmenu must not build a Menu itself (HIGH-07)")
}
Test("meta fix-tapholds-menu-raw-add: the two buttons are declared commands",
	_THRD_ButtonsAreCommands)




; ================================================
; ================================================
; ======= 2/ The providers return DATA ===========
; ================================================
; ================================================

_THRD_KeyRowsReturnData() {
	Body := _DriverFuncBody("_TH_KeyRows")
	Assert(Body != "", "_TH_KeyRows must be present in the driver source")

	Assert(!RegExMatch(Body, "Menu\(\)"),
		"_TH_KeyRows must return row data, never build a Menu — a Menu it filled itself would carry "
		. "callbacks outside the WM_COMMAND retry path (HIGH-07)")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_TH_KeyRows must not register menu items itself (HIGH-07)")
	; Every actionable row carries its callback as data under "action", which the
	; renderer wires with RegisterMenuItem.
	for _, Fn in ["_TH_MakeDisableFn", "_TH_MakeTapPickerFn"] {
		Assert(RegExMatch(Body, Chr(34) . "action" . Chr(34) . "\s*,\s*" . Fn),
			"_TH_KeyRows must carry " . Fn . " as an " . Chr(34) . "action" . Chr(34)
			. " row field so the renderer wires it (HIGH-07)")
	}
}
Test("meta fix-tapholds-menu-raw-add: the per-key provider returns data, not a menu",
	_THRD_KeyRowsReturnData)

_THRD_HoldPickerReturnsData() {
	Body := _DriverFuncBody("_TH_HoldPickerRows")
	Assert(Body != "", "_TH_HoldPickerRows must be present in the driver source")

	Assert(!RegExMatch(Body, "Menu\(\)"),
		"_TH_HoldPickerRows must return row data, never build a Menu (HIGH-07)")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_TH_HoldPickerRows must not register menu items itself (HIGH-07)")
	Assert(RegExMatch(Body, Chr(34) . "action" . Chr(34) . "\s*,\s*_TH_MakeHoldFn"),
		"_TH_HoldPickerRows must carry _TH_MakeHoldFn as an " . Chr(34) . "action" . Chr(34)
		. " row field so the renderer wires it (HIGH-07)")
}
Test("meta fix-tapholds-menu-raw-add: the hold picker returns data, not a menu",
	_THRD_HoldPickerReturnsData)
