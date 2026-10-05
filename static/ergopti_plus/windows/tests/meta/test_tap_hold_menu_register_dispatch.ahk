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
	Commands := _DriverFuncBody("_TH_ScopeCommands")
	Assert(Commands != "", "the terminal command provider must exist")
	Assert(InStr(Body, "_TH_ScopeCommands()") > 0,
		"the menu must consume its tested terminal command map")

	; Both buttons reach the renderer as named commands. A `command` row is drawn
	; by the renderer's _MR_RenderRows path, which registers it — the
	; driver never adds it, so it cannot add it raw.
	for _, Id in ["scope_restore", "scope_clear"] {
		Assert(InStr(Commands, Chr(34) . Id . Chr(34)) > 0,
			"the terminal provider must pass '" . Id . "' to the renderer as a command (HIGH-07)")
	}
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_BuildTapHoldsSubmenu must not register rows itself — the renderer owns the menu shape")
	; RegExMatch, not InStr: AHK's InStr is case-INSENSITIVE, and this function's
	; OWN name ends in "Submenu()" — which contains "menu()".
	Assert(!RegExMatch(Body, "\bMenu\(\)"),
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

	Assert(!RegExMatch(Body, "\bMenu\(\)"),
		"_TH_KeyRows must return row data, never build a Menu — a Menu it filled itself would carry "
		. "callbacks outside the WM_COMMAND retry path (HIGH-07)")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_TH_KeyRows must not register menu items itself (HIGH-07)")
	; The provider binds each native owner to its shared command identity. The
	; template materializes action data through the same renderer as every list.
	Assert(InStr(Body, 'MenuRenderer_TemplateRows("tap_hold_key_head"') > 0,
		"_TH_KeyRows must delegate the complete child head to the shared template")
	for Id, Fn in Map("tap_hold_key_native", "_TH_MakeDisableFn",
		"tap_hold_key_tap", "_TH_MakeTapPickerFn") {
		Assert(RegExMatch(Body, Chr(34) . Id . Chr(34) . "\s*,\s*" . Fn),
			"_TH_KeyRows must bind " . Fn . " to its declared command " . Id . " (HIGH-07)")
	}
	Head := _MR_GetMenuDef("tap_hold_key_head")
	Assert(Head.Length > 0 && Head[1]["type"] == "include"
		&& Head[1]["section"] == "tap_hold_key_native_commands",
		"the shared head must include its actual native command declaration")
	for Section, Id in Map("tap_hold_key_native_commands", "tap_hold_key_native",
		"tap_hold_key_head", "tap_hold_key_tap") {
		Item := _MR_FindItemById(Section, Id)
		Assert(Item is Map && Item["type"] == "command" && _MR_IsForAhk(Item),
			"the bound callback must remain a reachable Windows command: " . Id)
	}
	Assert(InStr(_DriverFuncBody("_MR_TemplateRows"), "MenuRenderer_CommandRow(") > 0,
		"the template must materialize each declared command through the native provider")
	Assert(InStr(_DriverFuncBody("MenuRenderer_CommandRow"), "_MR_DeclaredProviderRow(") > 0,
		"the command provider must use the actual declaration owner")
	Assert(InStr(_DriverFuncBody("_MR_DeclaredProviderRow"), "_MR_CommandRowData(") > 0,
		"the declaration owner must materialize canonical command row data")
	Assert(RegExMatch(_DriverFuncBody("_MR_CommandRowData"),
		Chr(34) . "action" . Chr(34) . "\s*,\s*Commands\[CmdId\]"),
		"canonical command data must retain its callback as an action field (HIGH-07)")
	Assert(InStr(_DriverFuncBody("_MR_RenderRows"), 'RegisterMenuItem(TargetMenu, Label, Row["action"])') > 0,
		"the actual native renderer must register action data through the WM_COMMAND retry owner")
}
Test("meta fix-tapholds-menu-raw-add: the per-key provider returns data, not a menu",
	_THRD_KeyRowsReturnData)

_THRD_HoldPickerReturnsData() {
	Body := _DriverFuncBody("_TH_HoldPickerRows")
	Assert(Body != "", "_TH_HoldPickerRows must be present in the driver source")

	Assert(!RegExMatch(Body, "\bMenu\(\)"),
		"_TH_HoldPickerRows must return row data, never build a Menu (HIGH-07)")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_TH_HoldPickerRows must not register menu items itself (HIGH-07)")
	Assert(RegExMatch(Body, Chr(34) . "action" . Chr(34) . "\s*,\s*_TH_MakeHoldFn"),
		"_TH_HoldPickerRows must carry _TH_MakeHoldFn as an " . Chr(34) . "action" . Chr(34)
		. " row field so the renderer wires it (HIGH-07)")
}
Test("meta fix-tapholds-menu-raw-add: the hold picker returns data, not a menu",
	_THRD_HoldPickerReturnsData)
