; tests/unit/test_accented_shortcuts.ahk

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
	Features["layout"] := Map("direct_access_digits", DigitAccess)
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
		AssertEqual(0, AccentedShortcutKeysForLayout(1, _ACS_AzertyScanCode).Count,
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
		AssertEqual(18, Count, "three keys times six modifier chords")
		AssertEqual(18, Names.Length)
		Joined := ""
		for Name in Names
			Joined .= Name . " "
		for Expected in ["^SC003", "^+SC003", "!SC008", "!+SC008", "#SC00B", "#+SC00B"]
			Assert(InStr(Joined, Expected . " ") > 0, Expected . " must be registered")
		AssertEqual(0, InStr(Joined, "^!"), "Ctrl+Alt is AltGr and must stay untouched")
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

