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
	Body := _DriverFuncBody("_TH_KeyRows")
	Assert(Body != "", "_TH_KeyRows must be present in the driver source")

	Assert(!RegExMatch(Body, "\bMenu\(\)"),
		"_TH_KeyRows must return row data, never build a Menu — a Menu it filled itself would carry "
		. "callbacks outside the WM_COMMAND retry path (HIGH-07)")
	Assert(!InStr(Body, "RegisterMenuItem("),
		"_TH_KeyRows must not register menu items itself (HIGH-07)")
	; The provider binds each native owner to its shared command identity. The
	; template materializes action data through the same renderer as every list.
	Assert(InStr(Body, 'MenuRenderer_TemplateRows("tap_hold_key_rows"') > 0,
		"_TH_KeyRows must delegate the complete child head to the shared template")
	for Id, Fn in Map("tap_hold_key_native", "_TH_MakeDisableFn",
		"tap_hold_key_tap", "_TH_MakeTapPickerFn") {
		Assert(RegExMatch(Body, Chr(34) . Id . Chr(34) . "\s*,\s*" . Fn),
			"_TH_KeyRows must bind " . Fn . " to its declared command " . Id . " (HIGH-07)")
	}
	Complete := _MR_GetMenuDef("tap_hold_key_rows")
	Assert(Complete.Length == 2 && Complete[1]["type"] == "include"
		&& Complete[1]["section"] == "tap_hold_key_head"
		&& Complete[2]["type"] == "include" && Complete[2]["section"] == "tap_hold_key_delay_tail",
		"the complete template must retain the actual head before its delay tail")
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
	Mutant["_TH_KeyRows"] := StrReplace(Owners["_TH_KeyRows"],
		"_HoldRowsBuilder(KeyId)", "_HoldRowsBuilder(0)", true, &Changed)
	AssertEqual(1, Changed, "the wrong fourth-argument child mutation must change the actual child owner")
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
	Assert(!_THRD_ExecutablePattern(Body, "i)Menu\s*\(", "Menu"), "per-key providers cannot build a native Menu")
	Assert(!_THRD_ExecutablePattern(Body, "i)RegisterMenuItem\s*\(", "RegisterMenuItem"), "per-key providers cannot register their own callbacks")
	NativePattern := 'i)MenuRenderer_TemplateRows\(\s*"tap_hold_key_rows"\s*,\s*'
		. 'Map\(\s*"tap_hold_key_native"\s*,\s*_TH_MakeDisableFn\(\s*KeyId\s*\)\s*,\s*'
		. '"tap_hold_key_tap"\s*,\s*_TH_MakeTapPickerFn\(\s*KeyId\s*,\s*KeyLabel\s*,\s*TapLbl\s*\)\s*\)\s*,\s*'
		. 'Map\(\s*"tap_hold_key_configured"\s*,\s*\(\(Value\)\s*=>\s*Value\)\.Bind\(\s*IsConfigured\s*\)\s*,'
		. '\s*"tap_hold_key_tap_caption"\s*,\s*\(\(Value\)\s*=>\s*Value\)\.Bind\(\s*TapLbl\s*\)\s*,'
		. '\s*"tap_hold_key_hold_caption"\s*,\s*\(\(Value\)\s*=>\s*Value\)\.Bind\(\s*HoldLbl\s*\)\s*,'
		. '\s*"tap_hold_key_delay_caption"\s*,\s*\(\(Value\)\s*=>\s*Value\)\.Bind\(\s*DelayCaption\s*\)\s*\)\s*,'
		. '\s*Map\(\s*"tap_hold_key_hold"\s*,\s*_HoldRowsBuilder\(\s*KeyId\s*\)\s*,'
		. '\s*"tap_hold_key_delay"\s*,\s*DelayRows\s*\)\s*\)'
	Assert(_THRD_ExecutablePattern(Body, NativePattern, "MenuRenderer_TemplateRows"),
		"native and tap callbacks plus configured state must reach the child template")
	Template := Owners["MenuRenderer_TemplateRows"]
	Code := _DriverMaskNonCode(&Template)
	Assert(_THRD_ExecutablePattern(Template, "i)return\s+_MR_TemplateRows\(\s*ManifestKey\s*,\s*Commands\s*,\s*StateGetters\s*,\s*Children\s*,", "return"),
		"the public template must forward its exact callbacks and state")
	TemplateRows := Owners["_MR_TemplateRows"]
	Code := _DriverMaskNonCode(&TemplateRows)
	Assert(_THRD_ExecutablePattern(TemplateRows, "i)Row\s*:=\s*MenuRenderer_CommandRow\(\s*ManifestKey\s*,\s*Id\s*,\s*Commands\s*,\s*StateGetters\s*\)", "Row"),
		"the child template must materialize callbacks through the command owner")
	Command := Owners["MenuRenderer_CommandRow"]
	Code := _DriverMaskNonCode(&Command)
	Assert(_THRD_ExecutablePattern(Command, "i)return\s+_MR_DeclaredProviderRow\(\s*ManifestKey\s*,\s*CommandId\s*,\s*Commands\s*,", "return"),
		"the command factory must forward the actual owner callback map")
	Declared := Owners["_MR_DeclaredProviderRow"]
	Code := _DriverMaskNonCode(&Declared)
	Assert(_THRD_ExecutablePattern(Declared, "i)Row\s*:=\s*_MR_CommandRowData\(\s*Item\s*,\s*ManifestKey\s*,\s*Commands\s*,\s*Getters\s*\)", "Row"),
		"the provider must consume the command map through the declared row owner")
	Data := Owners["_MR_CommandRowData"]
	Assert(_THRD_ExecutablePattern(Data,
		'i)Map\(\s*"label"\s*,\s*IsSet\(\s*Label\s*\)\s*\?\s*Label\s*:\s*t\(I18nKey\)\s*,\s*"action"\s*,\s*Commands\[CmdId\]\s*\)', "Map"),
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
		if _THRD_BareTokenAt(Code, Match.Pos(0), Token)
			return true
		Search := Match.Pos(0) + Match.Len(0)
	}
	return false
}

/** AHK v2 identifiers admit ASCII letters/digits/underscore and any non-ASCII unit. */
_THRD_BareTokenAt(Code, Position, Token) {
	if StrLower(SubStr(Code, Position, StrLen(Token))) != StrLower(Token)
		return false
	Before := Position > 1 ? SubStr(Code, Position - 1, 1) : ""
	After := SubStr(Code, Position + StrLen(Token), 1)
	if _THRD_IdentifierUnit(Before) || _THRD_IdentifierUnit(After)
		return false
	; A global function or local variable must not borrow a member's suffix.
	Prefix := RTrim(SubStr(Code, 1, Position - 1), " `t`r`n")
	return SubStr(Prefix, -1) != "."
}

_THRD_IdentifierUnit(Character) {
	return Character != "" && (Ord(Character) > 0x7F || RegExMatch(Character, "[A-Za-z0-9_]"))
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

_THRD_GlobalAndLocalTokenBoundaries() {
	Owners := Map()
	for Name in ["_TH_KeyRows", "MenuRenderer_TemplateRows", "_MR_TemplateRows",
			"MenuRenderer_CommandRow", "_MR_DeclaredProviderRow",
			"_MR_CommandRowData", "_MR_RenderRows"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must have an actual source body for token boundaries")
		Owners[Name] := Body
	}
	_THRD_KeyRowsPolicy(Owners)
	for Vector in [
		["MenuRenderer_TemplateRows", "return _MR_TemplateRows(ManifestKey, Commands, StateGetters, Children,",
			"the public template must forward its exact callbacks and state"],
		["MenuRenderer_CommandRow", "return _MR_DeclaredProviderRow(ManifestKey, CommandId, Commands,",
			"the command factory must forward the actual owner callback map"],
		["_TH_KeyRows", 'MenuRenderer_TemplateRows("tap_hold_key_rows"',
			"native and tap callbacks plus configured state must reach the child template"],
		["_MR_CommandRowData", 'Map("label", IsSet(Label) ? Label : t(I18nKey), "action", Commands[CmdId])',
			"the declared command must construct the renderer action"],
		["_MR_RenderRows", 'RegisterMenuItem(TargetMenu, Label, Row["action"])',
			"the shared renderer must register the row action with reliable dispatch"],
		["_MR_TemplateRows", "Row := MenuRenderer_CommandRow(ManifestKey, Id, Commands, StateGetters)",
			"the child template must materialize callbacks through the command owner"],
		["_MR_DeclaredProviderRow", "Row := _MR_CommandRowData(Item, ManifestKey, Commands, Getters)",
			"the provider must consume the command map through the declared row owner"]
	] {
		for Prefix in ["Unrelated", "_", "1", Chr(0x00C5), Chr(0x0663), Chr(0x0301), Chr(0x20AC), Chr(0x1F600), "Owner.", "Owner . "] {
			Mutant := Owners.Clone()
			Mutant[Vector[1]] := StrReplace(Owners[Vector[1]], Vector[2], Prefix . Vector[2], true, &Changed)
			AssertEqual(1, Changed, "the wrong identifier must replace one actual source binding")
			_THRD_KeyRowsRefuses(Mutant, Vector[3])
		}
	}
	Mutant := Owners.Clone()
	Mutant["_TH_KeyRows"] := "; " . StrReplace(Owners["_TH_KeyRows"], "`n", "`n; ")
	_THRD_KeyRowsRefuses(Mutant, "native and tap callbacks plus configured state must reach the child template")
	for Token in ["MenuRenderer_TemplateRows", "Map", "RegisterMenuItem", "Row"] {
		AssertTrue(_THRD_BareTokenAt(Token . "(", 1, Token), "a genuine bare source token is admitted")
		AssertFalse(_THRD_BareTokenAt(Token . "Suffix(", 1, Token), "a token cannot borrow a longer suffix")
		AssertFalse(_THRD_ExecutablePattern('; ' . Token . "()", Token . "\(\)", Token),
			"a comment cannot provide an executable binding")
		AssertFalse(_THRD_ExecutablePattern('"' . Token . '()"', Token . "\(\)", Token),
			"a string cannot provide an executable binding")
	}
}

Test("meta fix-tapholds-menu-raw-add: executable bindings use complete global and local identifiers",
	_THRD_GlobalAndLocalTokenBoundaries)
