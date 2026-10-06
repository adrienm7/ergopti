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
	Owners := Map()
	for Name in ["_TH_KeyRows", "MenuRenderer_TemplateRows", "_MR_TemplateRows",
			"MenuRenderer_CommandRow", "_MR_DeclaredProviderRow",
			"_MR_CommandRowData", "_MR_RenderRows"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must have an actual source body")
		Owners[Name] := Body
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
	_THRD_KeyRowsPolicy(Owners)
	Mutant := Owners.Clone()
	Mutant["_TH_KeyRows"] := StrReplace(Owners["_TH_KeyRows"],
		"_TH_MakeDisableFn(KeyId)", "_TH_MakeTapPickerFn(KeyId)", true, &Changed)
	AssertEqual(1, Changed, "the wrong native callback mutation must change its actual binding")
	_THRD_KeyRowsRefuses(Mutant, "native and tap callbacks plus configured state must reach the child template")
	Mutant := Owners.Clone()
	Mutant["_TH_KeyRows"] := StrReplace(Owners["_TH_KeyRows"],
		".Bind(IsConfigured)", ".Bind(false)", true, &Changed)
	AssertEqual(1, Changed, "the wrong state argument mutation must change its actual getter binding")
	_THRD_KeyRowsRefuses(Mutant, "native and tap callbacks plus configured state must reach the child template")
	Mutant := Owners.Clone()
	Mutant["_MR_CommandRowData"] := StrReplace(Owners["_MR_CommandRowData"],
		'"action", Commands[CmdId]', '"action", Commands[Id]', true, &Changed)
	AssertEqual(1, Changed, "the wrong renderer action mutation must change the actual row constructor")
	_THRD_KeyRowsRefuses(Mutant, "the declared command must construct the renderer action")
}

/** Pins shared child-template callbacks and state to reliable native dispatch. */
_THRD_KeyRowsPolicy(Owners) {
	Body := Owners["_TH_KeyRows"]
	Code := _DriverMaskNonCode(&Body)
	Assert(!RegExMatch(Code, "i)\bMenu\s*\("), "per-key providers cannot build a native Menu")
	Assert(!RegExMatch(Code, "i)\bRegisterMenuItem\s*\("), "per-key providers cannot register their own callbacks")
	NativePattern := 'i)MenuRenderer_TemplateRows\(\s*"tap_hold_key_head"\s*,\s*'
		. 'Map\(\s*"tap_hold_key_native"\s*,\s*_TH_MakeDisableFn\(\s*KeyId\s*\)\s*,\s*'
		. '"tap_hold_key_tap"\s*,\s*_TH_MakeTapPickerFn\(\s*KeyId\s*,\s*KeyLabel\s*,\s*TapLbl\s*\)\s*\)\s*,\s*'
		. 'Map\(\s*"tap_hold_key_configured"\s*,\s*\(\(Value\)\s*=>\s*Value\)\.Bind\(\s*IsConfigured\s*\)\s*,'
	Assert(_THRD_ExecutablePattern(Body, NativePattern, "MenuRenderer_TemplateRows"),
		"native and tap callbacks plus configured state must reach the child template")
	Template := Owners["MenuRenderer_TemplateRows"]
	Code := _DriverMaskNonCode(&Template)
	Assert(RegExMatch(Code, "i)\breturn\s+_MR_TemplateRows\(\s*ManifestKey\s*,\s*Commands\s*,\s*StateGetters\s*,\s*Children\s*,"),
		"the public template must forward its exact callbacks and state")
	TemplateRows := Owners["_MR_TemplateRows"]
	Code := _DriverMaskNonCode(&TemplateRows)
	Assert(RegExMatch(Code, "i)\bRow\s*:=\s*MenuRenderer_CommandRow\(\s*ManifestKey\s*,\s*Id\s*,\s*Commands\s*,\s*StateGetters\s*\)"),
		"the child template must materialize callbacks through the command owner")
	Command := Owners["MenuRenderer_CommandRow"]
	Code := _DriverMaskNonCode(&Command)
	Assert(RegExMatch(Code, "i)\breturn\s+_MR_DeclaredProviderRow\(\s*ManifestKey\s*,\s*CommandId\s*,\s*Commands\s*,"),
		"the command factory must forward the actual owner callback map")
	Declared := Owners["_MR_DeclaredProviderRow"]
	Code := _DriverMaskNonCode(&Declared)
	Assert(RegExMatch(Code, "i)Row\s*:=\s*_MR_CommandRowData\(\s*Item\s*,\s*ManifestKey\s*,\s*Commands\s*,\s*Getters\s*\)"),
		"the provider must consume the command map through the declared row owner")
	Data := Owners["_MR_CommandRowData"]
	Assert(_THRD_ExecutablePattern(Data,
		'i)Map\(\s*"label"\s*,\s*t\(I18nKey\)\s*,\s*"action"\s*,\s*Commands\[CmdId\]\s*\)', "Map"),
		"the declared command must construct the renderer action")
	Renderer := Owners["_MR_RenderRows"]
	Assert(_THRD_ExecutablePattern(Renderer,
		'i)RegisterMenuItem\(\s*TargetMenu\s*,\s*Label\s*,\s*Row\["action"\]\s*\)', "RegisterMenuItem"),
		"the shared renderer must register the row action with reliable dispatch")
}

/** Requires literal argument bindings to start at an executable source token. */
_THRD_ExecutablePattern(Source, Pattern, Token) {
	Code := _DriverMaskNonCode(&Source)
	Search := 1
	while RegExMatch(Source, Pattern, &Match, Search) {
		if StrLower(SubStr(Code, Match.Pos(0), StrLen(Token))) == StrLower(Token)
			return true
		Search := Match.Pos(0) + Match.Len(0)
	}
	return false
}

/** Unexpected errors are propagated; only the named policy refusal is accepted. */
_THRD_KeyRowsRefuses(Owners, ExpectedMessage) {
	Refused := false
	try _THRD_KeyRowsPolicy(Owners)
	catch as PolicyFailure {
		if Type(PolicyFailure) != "Error" || PolicyFailure.Message != ExpectedMessage
			throw PolicyFailure
		Refused := true
	}
	AssertTrue(Refused, "the actual per-key policy must reject its targeted mutation")
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
