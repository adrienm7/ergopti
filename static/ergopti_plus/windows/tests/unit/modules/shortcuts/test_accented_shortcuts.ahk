; tests/unit/modules/shortcuts/test_accented_shortcuts.ahk

; ==============================================================================
; MODULE: Accented-letter shortcuts — layout-driven registration
; DESCRIPTION:
; The accented-letter shortcuts used to exist only inside the Ergopti emulation,
; on Ergopti's fixed scancodes. These tests pin the layout-driven path: a letter
; gets chords only where the user's layout types it without Shift or AltGr, the
; live layout decides each press, AltGr is never taken, and « Désactivé » is
; honoured on both paths (accented-shortcuts-any-layout).
; Non-ASCII letters are built with Chr() so the suite stays ASCII-only.
; ==============================================================================

#Requires AutoHotkey v2.0

_ACS_EAcute() => Chr(0xE9)
_ACS_EGrave() => Chr(0xE8)
_ACS_ECirc() => Chr(0xEA)
_ACS_AGrave() => Chr(0xE0)

; AZERTY-like: é, è, à on the digit row, ê only through the ^ dead key.
_ACS_AzertyScanCode(Char, Hkl) {
	static Keys := Map(_ACS_EAcute(), 0x03, _ACS_EGrave(), 0x08, _ACS_AGrave(), 0x0B)
	return Keys.Get(Char, 0)
}

; QWERTY-like: no accented letter is directly accessible.
_ACS_QwertyScanCode(Char, Hkl) => 0

_ACS_WithShortcuts(Config, Callback, DigitAccess := false) {
	global Features
	HadShortcuts := Features.Has("shortcuts")
	if HadShortcuts
		Saved := Features["shortcuts"]
	HadLayout := Features.Has("layout")
	if HadLayout
		SavedLayout := Features["layout"]
	Features["shortcuts"] := Config
	Features["layout"] := Map("direct_access_digits", DigitAccess ? "digits" : "native")
	try Callback()
	finally {
		if HadShortcuts
			Features["shortcuts"] := Saved
		else
			Features.Delete("shortcuts")
		if HadLayout
			Features["layout"] := SavedLayout
		else
			Features.Delete("layout")
	}
}

_ACS_DefaultConfig(DisabledId := "") {
	Config := Map()
	for Id, Letter in Map("e_grave", "z", "e_circ", "x", "e_acute", "c", "a_grave", "v")
		Config[Id] := Map("enabled", Id != DisabledId, "letter", Letter)
	return Config
}

_ACS_KeysPerLayout(Hkl) {
	if (Hkl == 1)
		return AccentedShortcutKeysForLayout(Hkl, _ACS_AzertyScanCode)
	return AccentedShortcutKeysForLayout(Hkl, _ACS_QwertyScanCode)
}

Test("accented shortcuts: only directly typed letters get a key (accented-shortcuts-any-layout)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig(), () => _ACS_DirectKeysCase()))

Test("accented shortcuts: direct-access digits take the AZERTY top row back (accented-shortcuts-any-layout)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig(), () =>
		AssertEqual(0, AccentedShortcutKeysForLayout(1, _ACS_AzertyScanCode, true).Count,
			"with digits in direct access, e-acute/e-grave/a-grave need Shift and are no longer direct"),
		true))

_ACS_DirectKeysCase() => (
	Keys := AccentedShortcutKeysForLayout(1, _ACS_AzertyScanCode),
	AssertEqual(3, Keys.Count, "AZERTY types e-acute, e-grave and a-grave directly, not e-circ"),
	AssertEqual("e_acute", Keys[0x03]),
	AssertEqual("e_grave", Keys[0x08]),
	AssertEqual("a_grave", Keys[0x0B]),
	AssertEqual(0, AccentedShortcutKeysForLayout(2, _ACS_QwertyScanCode).Count,
		"QWERTY has no direct accented key, so nothing may be remapped")
)

Test("accented shortcuts: a chord resolves to the configured letter (accented-shortcuts-any-layout)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig("e_grave"), () => (
		Keys := AccentedShortcutKeysForLayout(1, _ACS_AzertyScanCode),
		AssertEqual("c", AccentedShortcutResolve("^SC003", Keys), "Ctrl+e-acute is Ctrl+C"),
		AssertEqual("c", AccentedShortcutResolve("!+SC003", Keys), "any configured modifier chord follows"),
		AssertEqual("v", AccentedShortcutResolve("#SC00B", Keys)),
		AssertEqual("", AccentedShortcutResolve("^SC008", Keys),
			"a disabled letter keeps its native chord"),
		AssertEqual("", AccentedShortcutResolve("^SC003", AccentedShortcutKeysForLayout(2, _ACS_QwertyScanCode)),
			"after a switch to QWERTY the same key is a digit again")
	)))

; A layout whose KeyC types the real star at its base level (Ergopti+).
_ACS_StarScanCode(Char, Hkl) => Char == Chr(0x2605) ? 0x2E : 0

; The key that types the real star joins the accented letters (2026-11-21):
; with « s », Ctrl+star saves. Before, only é è ê à had a letter picker.
Test("accented shortcuts: the key typing the real star maps its chords to its letter (star-letter-shortcut)", () => (
	Config := _ACS_DefaultConfig(),
	Config["star"] := Map("enabled", true, "letter", "s"),
	_ACS_WithShortcuts(Config, () => _ACS_StarCase())))

_ACS_StarCase() {
	global KeyboardShortcutAssignments
	Keys := AccentedShortcutKeysForLayout(3, _ACS_StarScanCode)
	AssertEqual("star", Keys.Get(0x2E, ""), "the star key is a direct key of its own")
	AssertEqual("s", AccentedShortcutResolve("^SC02E", Keys), "Ctrl+star is Ctrl+S")
	AssertEqual("s", AccentedShortcutResolve("!+SC02E", Keys), "every configured chord follows")
	Had := IsSet(KeyboardShortcutAssignments), Saved := Had ? KeyboardShortcutAssignments : 0
	try {
		KeyboardShortcutAssignments := Map("meta_star", "open_hotstrings_editor")
		AssertEqual("", AccentedShortcutResolve("#SC02E", Keys), "Win+star stays the star slot's")
		AssertEqual("s", AccentedShortcutResolve("^SC02E", Keys), "the slot takes only the Win chords")
		KeyboardShortcutAssignments := Map("meta_star", "none")
		AssertEqual("s", AccentedShortcutResolve("#SC02E", Keys), "a cleared star slot leaves Win+star to the letter")
	} finally {
		if Had
			KeyboardShortcutAssignments := Saved
	}
	AssertEqual(0, AccentedShortcutKeysForLayout(1, _ACS_AzertyScanCode).Get(0x2E, 0),
		"AZERTY types no star: the configured magic key never becomes the star key")
}

Test("accented shortcuts: the star letter is off by default (star-letter-shortcut)", () => (
	AssertFalse(ManifestDefaultFor("shortcuts.star.enabled"), "off in an empty configuration"),
	AssertEqual("s", ManifestDefaultFor("shortcuts.star.letter"))))

Test("accented shortcuts: registration covers every chord but AltGr (accented-shortcuts-any-layout)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig(), () => _ACS_RegistrationCase()))

_ACS_RegistrationCase() {
	global _AccentedShortcutRegistered
	Saved := _AccentedShortcutRegistered
	_AccentedShortcutRegistered := false
	Names := []
	HotIfCalls := []
	try {
		Count := AccentedShortcuts_Register([1, 2],
			(Name, *) => Names.Push(Name),
			(Args*) => HotIfCalls.Push(Args.Length),
			_ACS_KeysPerLayout)
		AssertEqual(24, Count, "three keys times eight modifier chords")
		AssertEqual(24, Names.Length)
		Joined := ""
		for Name in Names
			Joined .= Name . " "
		for Expected in ["^SC003", "^+SC003", "!SC008", "!+SC008", "#SC00B", "#+SC00B", "<^<!SC003", "<^<!+SC00B"]
			Assert(InStr(Joined, Expected . " ") > 0, Expected . " must be registered")
		AssertEqual(0, InStr(Joined, "^!"), "Ctrl+Alt is AltGr and must stay untouched")
		AssertEqual(0, InStr(Joined, ">!"), "AltGr's right Alt is never a chord (SCD-2)")
		; SCD-2: the left Ctrl+Alt chord resolves the key like the others, so
		; Ctrl+Alt+é sends Ctrl+Alt and the logical letter.
		Plain := AccentedShortcutResolve("^SC003", _ACS_KeysPerLayout(1))
		AssertTrue(Plain != "", "the AZERTY é key resolves a logical letter")
		AssertEqual(Plain, AccentedShortcutResolve("<^<!SC003", _ACS_KeysPerLayout(1)),
			"Ctrl+Alt+é sends the same logical letter as Ctrl+é")
		AssertEqual(2, HotIfCalls.Length, "the HotIf context must be opened then closed")
		AssertEqual(0, HotIfCalls[2], "the HotIf context must be reset after registration")
		AssertThrows(() => AccentedShortcuts_Register([1],
			(Name, *) => 0, (Args*) => 0, _ACS_KeysPerLayout),
			"a second registration must be refused")
	} finally _AccentedShortcutRegistered := Saved
}

Test("accented shortcuts: Ergopti emulation honours Disabled (accented-shortcut-disable-ignored)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig("e_acute"), () => (
		AssertEqual(_ACS_EAcute(), _ErgoptiLetterOr("e_acute", _ACS_EAcute()),
			"a disabled shortcut must fall back to the accented letter itself"),
		AssertEqual("v", _ErgoptiLetterOr("a_grave", _ACS_AGrave()))
	)))

; The Layout menu reads input sources, emulation, then the tuning of the active
; layout (maintainer, 2026-11-19). The rows are read from the generated manifest
; the renderer draws, so a row moved back across the headers fails here
; (layout-menu-sections).
_ACS_LayoutMenuTokens() {
	Tokens := []
	for Row in _MR_GetMenuDef("layout_menu") {
		Type := _MR_Get(Row, "type")
		if (Type == "section_header")
			Tokens.Push(_MR_Get(Row, "i18n"))
		else if (Type == "feature")
			Tokens.Push(_MR_Get(Row, "path"))
		else if (Type != "---")
			Tokens.Push(_MR_Get(Row, "id"))
	}
	return Tokens
}

_ACS_TokenIndex(Tokens, Token) {
	for Index, Value in Tokens
		if (Value == Token)
			return Index
	throw Error("Layout menu row '" . Token . "' is not declared.")
}

Test("layout menu: the input sources, then the emulation, precede the layout tuning section (layout-menu-sections)",
	() => _ACS_LayoutSectionsCase())

_ACS_LayoutSectionsCase() {
	Tokens := _ACS_LayoutMenuTokens()
	Sources := _ACS_TokenIndex(Tokens, "menu.layout.active_layouts")
	Emulation := _ACS_TokenIndex(Tokens, "menu.layout.header_emulation")
	AnyLayout := _ACS_TokenIndex(Tokens, "menu.layout.header_tuning")
	Assert(Sources < Emulation && Emulation < AnyLayout, "the input sources, the emulation, then the tuning")
	for Row in ["active_layouts", "layout_switching", "layout_manager", "layout_system_install"]
		Assert(_ACS_TokenIndex(Tokens, Row) > Sources && _ACS_TokenIndex(Tokens, Row) < Emulation,
			Row . " belongs to the input sources section")
	Assert(_ACS_TokenIndex(Tokens, "layout_emulation") > Emulation
		&& _ACS_TokenIndex(Tokens, "layout_emulation") < AnyLayout, "the emulated layout has its own section")
	for Row in ["layout_features_base", "layout_features_altgr", "layout_emulated_rows", "number_row_policy",
			"accented_letters"]
		Assert(_ACS_TokenIndex(Tokens, Row) > AnyLayout, Row . " tunes the active layout")
	AssertEqual(0, _ACS_CountLayoutToken(Tokens, "hotstrings.magic_key.replace"),
		"the removed replacement switch must not reappear in the Layout menu")
	_ACS_LayoutProviderPlacement(Tokens, AnyLayout)
	Assert(InStr(_TrayRootBuilderBodies(), "group_accented") == 0,
		"the accented-letter group must stay enabled without the Ergopti emulation")
}


; Exercise the included provider, not the value of its unused exclusion marker.
_ACS_LayoutProviderPlacement(Tokens, AnyLayout) {
	global Features
	SavedFeatures := Features
	State := MasterGateState()
	SavedState := State.Clone()
	try {
		Features := Map("layout", Map("ergopti_base", true, "ergopti_alt_gr", true,
			"ergopti_variant", "ergopti_plus",
			"direct_access_digits", "digits", "emulated_layout", "",
				; Rows of the same section layout_switching owns: a provider listing the
				; section's remainder drew them here as raw ids.
				"pause_switch_enabled", false, "on_pause", "", "on_resume", ""))
		State["initialized"] := false
		Rows := _LAY_LayoutFeatureAltGrRows()
		AssertEqual(1, Rows.Length, "the actual AltGr provider owns only its independent general layer")
		Expected := ["ergopti_alt_gr"]
		for Index, Id in Expected {
			Entry := ManifestFindEntryByPath("layout." . Id)
			Assert(Entry is Map, "each independently expected overlay must be declared")
			AssertEqual(MenuLabelFromManifestEntry(Entry), Rows[Index]["label"],
				"actual provider order retains the general layer without a variant or digit-row control")
			AssertTrue(HasMethod(Rows[Index]["action"], "Call"), "each real overlay retains its native action")
		}
		AssertEqual(0, _ACS_CountLayoutToken(Tokens, "layout.ergopti_plus"), "the retired variant switch cannot reappear")
		AssertEqual(0, _ACS_CountLayoutToken(Tokens, "layout.ergopti_variant"), "the internal variant cannot become a replacement public control")
		Count := 0
		for Index, Token in Tokens {
			if Token == "number_row_policy" {
				Count += 1
				Assert(Index > AnyLayout, "the single global policy belongs after the tuning header")
			}
		}
		AssertEqual(1, Count, "the actual global declaration must contain exactly one number-row policy")
	} finally {
		Features := SavedFeatures
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
	}
}

_ACS_CountLayoutToken(Tokens, Token) {
	Count := 0
	for Value in Tokens
		if Value == Token
			Count += 1
	return Count
}

; A cached HKL is insufficient: digit access and the Layout master change
; in-process. Registration must retain the hidden native keys for that return.
_ACS_NumberRowPolicyCache() {
	global Features, CategoryEnabled, _AccentedShortcutLayoutCache, _AccentedShortcutRegistered
	SavedCache := _AccentedShortcutLayoutCache
	SavedRegistered := _AccentedShortcutRegistered
	SavedCategory := CategoryEnabled["Layout"]
	_AccentedShortcutLayoutCache := Map()
	_AccentedShortcutRegistered := false
	CategoryEnabled["Layout"] := true
	; Digits first applies only on a layout whose row it reorders: the real AZERTY.
	Azerty := _LDRP_Layout("0000040C")
	if !Azerty
		Azerty := 0x040C040C
	try {
		Native := _AccentedShortcutKeysCached(Azerty, _ACS_AzertyScanCode)
		AssertEqual("c", AccentedShortcutResolve("^SC003", Native))
		Features["layout"]["direct_access_digits"] := "digits"
		Digits := _AccentedShortcutKeysCached(Azerty, _ACS_AzertyScanCode)
		AssertEqual(0, Digits.Count, "live digits mode must not reuse the native accented-key cache")
		AssertEqual("", AccentedShortcutResolve("^SC003", Digits), "Ctrl+2 must keep its native chord")

		Names := []
		; The fake native profile is already cached. Keep the production default
		; KeysFn so this also proves registration selects the native inventory.
		Count := AccentedShortcuts_Register([Azerty], (Name, *) => Names.Push(Name), (Args*) => 0)
		AssertEqual(24, Count, "digits mode must still register the three hidden native accent positions")
		AssertEqual(24, Names.Length)

		Features["layout"]["direct_access_digits"] := "native"
		AssertEqual(Native, _AccentedShortcutKeysCached(Azerty, _ACS_AzertyScanCode),
			"returning to native mode must recover its own cached profile")
		Features["layout"]["direct_access_digits"] := "digits"
		CategoryEnabled["Layout"] := false
		AssertEqual(Native, _AccentedShortcutKeysCached(Azerty, _ACS_AzertyScanCode),
			"disabling the Layout master returns accented chords to the native profile")
	} finally {
		_AccentedShortcutLayoutCache := SavedCache
		_AccentedShortcutRegistered := SavedRegistered
		CategoryEnabled["Layout"] := SavedCategory
	}
}
Test("accented shortcuts: live number-row changes select their own cache (accented-shortcuts-live-digits)", () =>
	_ACS_WithShortcuts(_ACS_DefaultConfig(), _ACS_NumberRowPolicyCache))
