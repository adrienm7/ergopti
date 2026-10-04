; tests/unit/test_tap_keys.ahk

; ==============================================================================
; MODULE: Number-Row Tap Keys (Windows)
; DESCRIPTION:
; The three number-row tap keys (SC029, SC00C, SC00D): their assignments, the
; #HotIf predicate that hands an unassigned key back to the layout, the handler
; that runs the action and swallows the auto-repeat, and the live label each
; menu row shows, computed from the emulation table when the Ergopti emulation
; remaps the key and from the OS layout otherwise. The OS layout comes through
; a fake probe standing in for GetKeyboardLayout, MapVirtualKeyEx and
; ToUnicodeEx, so AZERTY and US QWERTY are asserted on any machine.
;
; ROOT CAUSE ENCODED:
; The key left of 1 was hard-wired to an instant capture, the keys right of 0
; could not be assigned at all, and the menu named the key by a fixed legend
; ("² on AZERTY, $ on Ergopti") whatever the layout in use.
; ==============================================================================

#Requires AutoHotkey v2.0

; A grave accent: the US key left of 1, and a dead key on US-international.
global _TK_GRAVE := Chr(0x60)

; A fake OS layout: scancode -> Map("vk", ..., "count", ..., "text", ...).
_TK_FakeLayout(Table) {
	return {
		Hkl: () => 0x040C040C,
		ScToVk: (Scancode, Hkl) => Table.Has(Scancode) ? Table[Scancode]["vk"] : 0,
		ToUnicode: (Vk, Scancode, Hkl) => { Count: Table[Scancode]["count"], Text: Table[Scancode]["text"] },
	}
}

_TK_Key(Vk, Text, Count := 1) {
	return Map("vk", Vk, "count", Count, "text", Text)
}

_TK_Azerty() {
	return _TK_FakeLayout(Map(0x29, _TK_Key(0xDE, "²"), 0x0C, _TK_Key(0xDB, ")"), 0x0D, _TK_Key(0xBB, "=")))
}

_TK_UsQwerty() {
	return _TK_FakeLayout(Map(0x29, _TK_Key(0xC0, _TK_GRAVE), 0x0C, _TK_Key(0xBD, "-"), 0x0D, _TK_Key(0xBB, "=")))
}

; Runs Body with the digit-row emulation switched as asked, then puts it back.
_TK_WithEmulation(Enabled, Body) {
	global Features
	Saved := Features["layout"]["direct_access_digits"]
	Features["layout"]["direct_access_digits"] := Enabled ? "digits" : "native"
	try
		return Body.Call()
	finally
		Features["layout"]["direct_access_digits"] := Saved
}

_TK_Names(Probe) {
	Names := []
	for _, Id in TAP_KEY_ORDER
		Names.Push(TapKeyDisplayName(Id, Probe))
	return Names[1] . " " . Names[2] . " " . Names[3]
}

_TK_LabelsFollowTheOsLayout() {
	_TK_WithEmulation(false, () => (
		AssertEqual("² ) =", _TK_Names(_TK_Azerty()), "AZERTY without the emulation"),
		AssertEqual(_TK_GRAVE . " - =", _TK_Names(_TK_UsQwerty()), "US QWERTY without the emulation")
	))
}
Test("tap keys: labels read the OS layout when the emulation leaves the keys alone (tap-keys)", _TK_LabelsFollowTheOsLayout)

_TK_LabelsFollowTheEmulation() {
	_TK_WithEmulation(true, () => (
		AssertEqual("$ % =", _TK_Names(_TK_Azerty()), "the Ergopti digit row over AZERTY"),
		AssertEqual("$ % =", _TK_Names(_TK_UsQwerty()), "the Ergopti digit row over US QWERTY")
	))
	Table := ErgoptiNumberRowEdgeMapping()
	AssertEqual(3, Table.Count, "the emulation table names the three edge keys")
}
Test("tap keys: labels read the emulation table while it remaps the digit row (tap-keys)", _TK_LabelsFollowTheEmulation)

_TK_DeadAndSilentKeys() {
	UsIntl := _TK_FakeLayout(Map(0x29, _TK_Key(0xC0, _TK_GRAVE, -1), 0x0C, _TK_Key(0xBD, "-"), 0x0D, _TK_Key(0, "")))
	_TK_WithEmulation(false, () => (
		AssertEqual(StrReplace(t("menu.shortcuts.tap_keys.dead_key"), "{1}", _TK_GRAVE),
			TapKeyDisplayName("number_row_left", UsIntl), "a dead key shows its symbol with the hint"),
		AssertTrue(InStr(TapKeyDisplayName("number_row_left", UsIntl), _TK_GRAVE) > 0, "the hint keeps the symbol"),
		AssertEqual(t("menu.shortcuts.tap_keys.number_row_right_2"),
			TapKeyDisplayName("number_row_right_2", UsIntl), "a key with no character is named by its position")
	))
}
Test("tap keys: a dead key is hinted and a silent key named by its position (tap-keys)", _TK_DeadAndSilentKeys)

_TK_PredicateGatesTheHotkey() {
	global TapKeyAssignments, CategoryEnabled
	Saved := TapKeyAssignments
	SavedShortcuts := CategoryEnabled["Shortcuts"]
	try {
		TapKeyAssignments := Map("number_row_left", "screen_capture",
			"number_row_right_1", "none", "number_row_right_2", "no_such_action")
		AssertTrue(TapKeyShouldFire("number_row_left"), "an assigned key fires")
		AssertFalse(TapKeyShouldFire("number_row_right_1"), "an unassigned key keeps its behaviour")
		AssertFalse(TapKeyShouldFire("number_row_right_2"), "an unknown action never swallows the key")
		CategoryEnabled["Shortcuts"] := false
		AssertFalse(TapKeyShouldFire("number_row_left"), "the Shortcuts category gates every tap key")
	} finally {
		TapKeyAssignments := Saved
		CategoryEnabled["Shortcuts"] := SavedShortcuts
	}
}
Test("tap keys: the hotkey predicate hands unassigned keys back to the layout (tap-keys)", _TK_PredicateGatesTheHotkey)

_TK_FireRunsTheBindingActionAndWaits() {
	global TapKeyAssignments, GestureActionParameters, _SendHook
	SavedAssignments := TapKeyAssignments
	SavedParameters := GestureActionParameters
	SavedHook := _SendHook
	Sent := []
	Waited := []
	try {
		TapKeyAssignments := Map("number_row_right_1", "send_text")
		GestureActionParameters := Map(GestureActionParameterKey(TapKeyBindingId("number_row_right_1"), "send_text"),
			"bonjour cela va bien?")
		_SendHook := (Fn, Args*) => (Sent.Push(Args[1]), "")
		TapKeyFire("number_row_right_1", (Key) => Waited.Push(Key))
	} finally {
		TapKeyAssignments := SavedAssignments
		GestureActionParameters := SavedParameters
		_SendHook := SavedHook
	}
	AssertEqual(1, Sent.Length, "the action runs once")
	AssertEqual("bonjour cela va bien?", Sent[1], "under the tap key's own binding")
	AssertEqual(1, Waited.Length, "the handler waits for the release")
	AssertEqual("SC00C", Waited[1], "of its own key, so auto-repeat is swallowed")
}
Test("tap keys: a tap runs the binding's action and swallows the auto-repeat (tap-keys)", _TK_FireRunsTheBindingActionAndWaits)

_TK_ReadConfig() {
	global TapKeyAssignments
	Saved := TapKeyAssignments
	try {
		TapKeysReadConfig(Map("shortcuts.tap_keys", Map(
			"number_row_right_1", "send_text", "number_row_right_2", "no_such_action")))
		AssertEqual("none", TapKeyAssignments["number_row_left"],
			"an absent key keeps the native layout; recommendations require an explicit restore")
		AssertEqual("send_text", TapKeyAssignments["number_row_right_1"], "a stored action is read")
		AssertEqual("none", TapKeyAssignments["number_row_right_2"], "an unknown action leaves the key alone")
		TapKeysReadConfig(Map())
		AssertEqual("none", TapKeyAssignments["number_row_right_1"], "the keys right of 0 have no default")
	} finally {
		TapKeyAssignments := Saved
	}
}
Test("tap keys: assignments come from the config over the manifest defaults (tap-keys)", _TK_ReadConfig)

_TK_Rows() {
	global TapKeyAssignments
	Saved := TapKeyAssignments
	try {
		TapKeyAssignments := Map("number_row_left", "screen_capture", "number_row_right_1", "none",
			"number_row_right_2", "none")
		Rows := _TK_WithEmulation(false, () => TapKeyRows(_TK_Azerty()))
		AssertEqual(3, Rows.Length, "one row per tap key")
		AssertEqual("² : " . GestureActionDisplayLabel("screen_capture", TapKeyBindingId("number_row_left")),
			Rows[1]["label"], "the row names the key by what it types, then its action")
		AssertEqual(") : " . t("menu.shortcuts.tap_keys.unassigned"), Rows[2]["label"],
			"an unassigned key says it keeps its behaviour")
		AssertTrue(HasMethod(Rows[3]["action"], "Call"), "every row opens the picker")
	} finally {
		TapKeyAssignments := Saved
	}
}
Test("tap keys: the menu rows name each key by its live character (tap-keys)", _TK_Rows)
