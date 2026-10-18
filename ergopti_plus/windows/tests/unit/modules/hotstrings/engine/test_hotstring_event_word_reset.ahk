; tests/unit/modules/hotstrings/engine/test_hotstring_event_word_reset.ahk

; ==============================================================================
; MODULE: Arrow, Shortcut and Tap-Hold Word-Reset Tests
; DESCRIPTION:
; Three settings decide whether an event starts a new word, as a mouse click
; does: hotstrings.arrow_resets_word (an arrow key, typed or sent by the
; navigation layer), hotstrings.shortcut_resets_word (a key under Ctrl, Alt or
; Win) and hotstrings.tap_hold_resets_word (a tap-hold key's own output: its
; command tap, or a shortcut made under its held modifier or layer). All
; default to on. Off, the word in progress stays open: "c", Ctrl+V, "t★"
; still expands « ct★ ».
;
; The probe is a real personal TOML section read by LoadHotstringsSection:
; "r" -> "R" flagged is_word (fires only at a word start) and "ax" -> "AX"
; not flagged (fires inside a word). After « a », the event, then « r »: a
; reset makes « R » fire; a kept word leaves « ar ». After « a », the event,
; then « x »: a kept word fires « AX »; a reset forgot the « a ».
; ==============================================================================

#Requires AutoHotkey v2.0

global _HEWR_Section := "eventwordreset"
global _HEWR_Sent := []





; ======================================
; ======================================
; ======= 1/ Pure classification =======
; ======================================
; ======================================

_HEWR_PayloadKinds() {
	Vectors := [
		["{Left}", "arrow"], ["+{Right}", "arrow"], ["^{Up}", "arrow"], ["{Blind}{Down}", "arrow"],
		["!{Left}", "arrow"],
		["^{v}", "shortcut"], ["^+{v}", "shortcut"], ["^!{x}", "shortcut"], ["#+{s}", "shortcut"],
		["{Blind}^{z}", "shortcut"],
		["<^>!{e}", "edit"], ["+{a}", "edit"], ["^{BackSpace}", "edit"], ["^{Delete}", "edit"],
		["{Home}", "edit"], ["{Tab}", "edit"], ["{Enter}", "edit"],
		["{BackSpace}", "backspace"], ["{BackSpace 3}", "backspace"], ["{Volume_Up}", "neutral"],
		["{End}{Left}", "edit"],
	]
	for _, Vector in Vectors
		AssertEqual(Vector[2], HS_SyntheticPayloadKind(Vector[1]), "kind of " . Vector[1])
}

; Runs Body under a layout family: "altgr" (AZERTY-style AltGr, a fake LCtrl
; with the right Alt), "kana" (AltGr is VK_OEM_8) or "qwerty" (no AltGr).
_HEWR_WithLayout(Family, Body) {
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	SavedKana := _ALTGR_KANA_FIXUP
	HadProbe := IsSet(_ALTGR_LAYOUT_PROBE)
	if HadProbe
		SavedProbe := _ALTGR_LAYOUT_PROBE
	try {
		_ALTGR_KANA_FIXUP := (Family == "kana")
		_ALTGR_LAYOUT_PROBE := Map("altgr_level", Family == "altgr")
		Body()
	} finally {
		_ALTGR_KANA_FIXUP := SavedKana
		if HadProbe
			_ALTGR_LAYOUT_PROBE := SavedProbe
	}
}

; Whether the modifiers Down (key names) make a shortcut.
_HEWR_IsShortcut(Down*) {
	global _PrefixModifierIsDown
	Saved := _PrefixModifierIsDown
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	try {
		_PrefixModifierIsDown := (Name) => Held.Has(Name)
		return _PrefixShortcutModifierHeld()
	} finally {
		_PrefixModifierIsDown := Saved
	}
}

_HEWR_ShortcutsOnEveryLayout(Family) {
	AssertTrue(_HEWR_IsShortcut("LControl"), Family . ": Ctrl")
	AssertTrue(_HEWR_IsShortcut("LControl", "LShift"), Family . ": Ctrl+Shift")
	AssertTrue(_HEWR_IsShortcut("LControl", "LAlt"), Family . ": Ctrl+Alt (left Alt)")
	AssertTrue(_HEWR_IsShortcut("LWin", "LShift"), Family . ": Win+Shift")
	AssertTrue(_HEWR_IsShortcut("LAlt"), Family . ": Alt")
	AssertFalse(_HEWR_IsShortcut("LShift"), Family . ": Shift alone is typing")
	AssertFalse(_HEWR_IsShortcut(), Family . ": nothing held")
}

_HEWR_AltGrLayoutRightAlt() {
	AssertFalse(_HEWR_IsShortcut("LControl", "RAlt"), "AltGr's fake LCtrl is typing")
	AssertFalse(_HEWR_IsShortcut("RAlt"), "the right Alt is AltGr there")
}

_HEWR_QwertyRightAlt() {
	AssertTrue(_HEWR_IsShortcut("RAlt"), "without AltGr the right Alt is a plain Alt")
	AssertTrue(_HEWR_IsShortcut("LControl", "RAlt"), "and Ctrl+right Alt a real chord")
}

_HEWR_ShortcutModifiers() {
	for _, Family in ["altgr", "kana", "qwerty"]
		_HEWR_WithLayout(Family, _HEWR_ShortcutsOnEveryLayout.Bind(Family))
	_HEWR_WithLayout("altgr", _HEWR_AltGrLayoutRightAlt)
	_HEWR_WithLayout("qwerty", _HEWR_QwertyRightAlt)
}

Test("event word reset: synthetic payload kinds", _HEWR_PayloadKinds)
Test("event word reset: which modifiers make a shortcut, on all three layout families", _HEWR_ShortcutModifiers)





; =========================================================
; =========================================================
; ======= 2/ The word after each event, both states =======
; =========================================================
; =========================================================

; Loads the probe section from a personal TOML file through the production
; section loader.
_HEWR_LoadFixture() {
	global ScriptInformation, _HEWR_Section
	Path := A_Temp . "\ergopti_event_word_reset_" . A_TickCount . ".toml"
	Flags := ", auto_expand = true, is_case_sensitive = true, final_result = false }`n"
	FileAppend("[[" . _HEWR_Section . "]]`n"
		. '"r" = { output = "R", is_word = true' . Flags
		. '"ax" = { output = "AX", is_word = false' . Flags, Path, "UTF-8")
	ScriptInformation["PersonalTomlPath"] := Path
	LoadHotstringsSection("personal", _HEWR_Section, { TimeActivationSeconds: 0 })
	return Path
}

; Types « a », runs Event under Settings (Map leaf -> Boolean), types Probe and
; returns the trigger that fired, "" when none did.
_HEWR_Run(Settings, Event, Probe) {
	global ScriptInformation, HSE_RegistryByGroup, HotstringGroupConfig
	global HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	global _PrefixFocusedControlToken, _PrefixModifierIsDown, _AHK_SendInput
	global TapHold, LayerEnabled, _TH_OwnedModifiers, _HEWR_Section, _HEWR_Sent
	Saved := { path: ScriptInformation["PersonalTomlPath"], arrow: HSE_ArrowResetsWord,
		shortcut: HSE_ShortcutResetsWord, taphold: HSE_TapHoldResetsWord,
		token: _PrefixFocusedControlToken, mods: _PrefixModifierIsDown, send: _AHK_SendInput,
		taphold_config: TapHold, layer: LayerEnabled, owned: _TH_OwnedModifiers.Clone() }
	Path := ""
	try {
		HSE_TestReset()
		Path := _HEWR_LoadFixture()
		HSE_ArrowResetsWord := Settings.Get("arrow_resets_word", true)
		HSE_ShortcutResetsWord := Settings.Get("shortcut_resets_word", true)
		HSE_TapHoldResetsWord := Settings.Get("tap_hold_resets_word", true)
		_PrefixFocusedControlToken := 1
		_PrefixModifierIsDown := (*) => false
		_HEWR_Sent := []
		_AHK_SendInput := (Keys) => _HEWR_Sent.Push(Keys)
		AssertFalse(IsObject(HSE_FeedChar("a", true)), "« a » alone fires nothing")
		Event()
		Match := HSE_FeedChar(Probe, true)
		return IsObject(Match) ? Match.Trigger : ""
	} finally {
		ScriptInformation["PersonalTomlPath"] := Saved.path
		HSE_ArrowResetsWord := Saved.arrow, HSE_ShortcutResetsWord := Saved.shortcut
		HSE_TapHoldResetsWord := Saved.taphold
		_PrefixFocusedControlToken := Saved.token, _PrefixModifierIsDown := Saved.mods
		_AHK_SendInput := Saved.send, TapHold := Saved.taphold_config, LayerEnabled := Saved.layer
		_TH_OwnedModifiers.Clear()
		for Key, Value in Saved.owned
			_TH_OwnedModifiers[Key] := Value
		Group := "personal." . _HEWR_Section
		if HSE_RegistryByGroup.Has(Group)
			HSE_RegistryByGroup.Delete(Group)
		if HotstringGroupConfig.Has("personal")
			HotstringGroupConfig.Delete("personal")
		if (Path != "" and HotstringGroupConfig.Has(Path))
			HotstringGroupConfig.Delete(Path)
		try HotstringsResolveBumpGen()
		if (Path != "")
			try FileDelete(Path)
		HSE_TestReset()
	}
}

; Asserts the reference pattern for one event governed by Setting: on, « a »
; event « r » gives « aR » and « ax » no longer fires; off, « ar » stays « ar »
; and « ax » still fires. Other settings stay on unless Others says otherwise.
_HEWR_AssertGoverned(Name, Setting, Event, Others := 0) {
	On := IsObject(Others) ? Others.Clone() : Map()
	Off := On.Clone()
	On[Setting] := true
	Off[Setting] := false
	AssertEqual("r", _HEWR_Run(On, Event, "r"), Name . ", on: « a » then « r » starts a new word (aR)")
	AssertEqual("", _HEWR_Run(On, Event, "x"), Name . ", on: the « a » is forgotten (no AX)")
	AssertEqual("", _HEWR_Run(Off, Event, "r"), Name . ", off: « r » stays inside the word (ar)")
	AssertEqual("ax", _HEWR_Run(Off, Event, "x"), Name . ", off: the word continues (AX)")
}

; A physical key going down under the modifiers Down.
_HEWR_PhysicalKey(VK, SC, Down*) {
	global _PrefixModifierIsDown
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	_PrefixModifierIsDown := (Name) => Held.Has(Name)
	_OnPrefixKeyDown(0, VK, SC)
}

_HEWR_ProbeUnaffectedWithoutEvent() {
	AssertEqual("", _HEWR_Run(Map(), (*) => 0, "r"), "« ar » never fires the word-start « r »")
	AssertEqual("ax", _HEWR_Run(Map(), (*) => 0, "x"), "« ax » fires inside a word")
}

_HEWR_PhysicalArrows() {
	_HEWR_AssertGoverned("Left arrow", "arrow_resets_word", () => _HEWR_PhysicalKey(0x25, 0x14B))
	_HEWR_AssertGoverned("Shift+Down", "arrow_resets_word", () => _HEWR_PhysicalKey(0x28, 0x150, "LShift"))
	; Ctrl+Right is an arrow, not a shortcut: the shortcut setting does not matter.
	_HEWR_AssertGoverned("Ctrl+Right", "arrow_resets_word", () => _HEWR_PhysicalKey(0x27, 0x14D, "LControl"),
		Map("shortcut_resets_word", false))
}

_HEWR_SyntheticArrows() {
	global LayerEnabled
	_HEWR_AssertGoverned("navigation layer Left", "arrow_resets_word",
		() => ((LayerEnabled := true), ActionLayer("{Left}")), Map("tap_hold_resets_word", false))
	_HEWR_AssertGoverned("sent Ctrl+Up", "arrow_resets_word", () => TextPressKey("Up", ["Ctrl"]))
}

_HEWR_PhysicalShortcuts() {
	_HEWR_AssertGoverned("Ctrl+V", "shortcut_resets_word", () => _HEWR_PhysicalKey(0x56, 0x2F, "LControl"))
	_HEWR_AssertGoverned("Ctrl+Shift+V", "shortcut_resets_word",
		() => _HEWR_PhysicalKey(0x56, 0x2F, "LControl", "LShift"))
	_HEWR_AssertGoverned("Ctrl+Alt+X", "shortcut_resets_word",
		() => _HEWR_PhysicalKey(0x58, 0x2D, "LControl", "LAlt"))
	_HEWR_AssertGoverned("Win+Shift+S", "shortcut_resets_word",
		() => _HEWR_PhysicalKey(0x53, 0x1F, "LWin", "LShift"))
	_HEWR_AssertGoverned("Ctrl+A", "shortcut_resets_word", () => _HEWR_PhysicalKey(0x41, 0x1E, "LControl"))
	_HEWR_AssertGoverned("sent Ctrl+Z", "shortcut_resets_word", () => TextPressKey("z", ["Ctrl"]))
}

; Typing keys never reset, whatever the settings: an AltGr keystroke (the
; fake LCtrl with the right Alt; nothing at all on a Kana-style layout, whose
; AltGr is VK_OEM_8) and Shift+letter.
_HEWR_TypingOnLayout(Family) {
	AltGr := (Family == "altgr") ? ["LControl", "RAlt"] : []
	AssertEqual("ax", _HEWR_Run(Map(), () => _HEWR_PhysicalKey(0x58, 0x2D, AltGr*), "x"),
		Family . ": an AltGr keystroke is typing, the word continues")
	AssertEqual("ax", _HEWR_Run(Map(), () => _HEWR_PhysicalKey(0x58, 0x2D, "LShift"), "x"),
		Family . ": Shift+letter is typing, the word continues")
}

_HEWR_TypingIsNoShortcut() {
	for _, Family in ["altgr", "kana"]
		_HEWR_WithLayout(Family, _HEWR_TypingOnLayout.Bind(Family))
}

; Ctrl+Backspace deletes a word: both buffers go, the word start unknown,
; with every setting off.
_HEWR_CtrlBackspaceAlwaysForgets() {
	Off := Map("arrow_resets_word", false, "shortcut_resets_word", false, "tap_hold_resets_word", false)
	Event := () => _HEWR_PhysicalKey(0x08, 0x0E, "LControl")
	AssertEqual("", _HEWR_Run(Off, Event, "x"), "Ctrl+Backspace forgets the « a »")
	AssertEqual("", _HEWR_Run(Off, Event, "r"), "and promises no word start")
}

Test("event word reset: the probe without any event", _HEWR_ProbeUnaffectedWithoutEvent)
Test("event word reset: physical arrows, on and off", _HEWR_PhysicalArrows)
Test("event word reset: navigation-layer and sent arrows, on and off", _HEWR_SyntheticArrows)
Test("event word reset: shortcuts with one and several modifiers, on and off", _HEWR_PhysicalShortcuts)
Test("event word reset: AltGr and Shift keystrokes are typing", _HEWR_TypingIsNoShortcut)
Test("event word reset: Ctrl+Backspace forgets the word whatever the settings", _HEWR_CtrlBackspaceAlwaysForgets)





; =====================================
; =====================================
; ======= 3/ Tap-hold ownership =======
; =====================================
; =====================================

; A left Ctrl tapped as Paste and held as Ctrl, as Ergopti recommends.
_HEWR_PasteTapHold() {
	global TapHold
	TapHold := Map("keys", Map("left_ctrl", Map("time_activation_seconds", 0.2,
		"tap_action", "paste", "hold_modifier", "ctrl")), "layers", Map())
	return TapHoldDispatchTap("left_ctrl", _TapHoldInvokeConfiguredAction.Bind("left_ctrl"))
}

; The tap's Ctrl+V belongs to the tap-hold setting alone: off, the word
; continues even with the shortcut setting on, the maintainer's « c, tap-hold
; Ctrl+V, t★ ».
_HEWR_PasteTapIsTheTapHolds() {
	_HEWR_AssertGoverned("tap-hold Paste tap", "tap_hold_resets_word", _HEWR_PasteTapHold,
		Map("shortcut_resets_word", true))
	_HEWR_AssertGoverned("tap-hold Paste tap, shortcuts off", "tap_hold_resets_word", _HEWR_PasteTapHold,
		Map("shortcut_resets_word", false))
	AssertTrue(_HEWR_Sent.Length >= 1 and InStr(_HEWR_Sent[_HEWR_Sent.Length], "{v}") > 0,
		"the tap really typed its Ctrl+V")
}

; CapsLock held as Ctrl: its owner presses the Ctrl, so V under it is the
; tap-hold's shortcut.
_HEWR_ShortcutUnderAHeldModifier() {
	global _TH_OwnedModifiers, LayerEnabled
	Event := () => ((_TH_OwnedModifiers["caps_lock"] := "LCtrl"),
		_HEWR_PhysicalKey(0x56, 0x2F, "LControl"))
	_HEWR_AssertGoverned("V under CapsLock held as Ctrl", "tap_hold_resets_word", Event,
		Map("shortcut_resets_word", true))
	; A layer key's shortcut (Ctrl+Z bound in the layer) is the tap-hold's too.
	_HEWR_AssertGoverned("layer Ctrl+Z", "tap_hold_resets_word",
		() => ((LayerEnabled := true), ActionLayer("^{z}")), Map("shortcut_resets_word", true))
}

; A Shift or AltGr hold only types: shortcuts made beside it stay the
; shortcut setting's.
_HEWR_TypingHoldsOnAltGrLayout() {
	global _TH_OwnedModifiers
	_HEWR_AssertGoverned("Ctrl+V beside a Shift hold", "shortcut_resets_word",
		() => ((_TH_OwnedModifiers["space"] := "LShift"), _HEWR_PhysicalKey(0x56, 0x2F, "LControl", "LShift")),
		Map("tap_hold_resets_word", false))
	_HEWR_AssertGoverned("Ctrl+V beside an AltGr hold", "shortcut_resets_word",
		() => ((_TH_OwnedModifiers["alt_gr"] := "RAlt"), _HEWR_PhysicalKey(0x56, 0x2F, "LControl")),
		Map("tap_hold_resets_word", false))
}

_HEWR_TypingHoldsAreNotTheTapHolds() {
	AssertFalse(_TH_HoldMakesShortcuts("LShift"), "a Shift hold only types")
	AssertFalse(_TH_HoldMakesShortcuts(["LShift", "RShift"]), "nor does a two-Shift hold")
	AssertTrue(_TH_HoldMakesShortcuts(["LCtrl", "LShift"]), "a Ctrl+Shift hold makes shortcuts")
	_HEWR_WithLayout("altgr", _HEWR_TypingHoldsOnAltGrLayout)
}

_HEWR_TypingTapsAreNoCommands() {
	global TapHold
	Saved := TapHold
	try {
		TapHold := Map("keys", Map(
			"left_ctrl", Map("time_activation_seconds", 0.2, "tap_action", "paste"),
			"right_ctrl", Map("time_activation_seconds", 0.2, "tap_action", "one_shot_shift"),
			"caps_lock", Map("time_activation_seconds", 0.2, "tap_action", "enter"),
			"alt_gr", Map("time_activation_seconds", 0.2, "tap_action", "tab_next"),
			"tab", Map("time_activation_seconds", 0.2, "tap_action", "alt_tab_monitor")), "layers", Map())
		AssertTrue(TapHoldTapIsCommand("left_ctrl"), "Paste is a command")
		AssertTrue(TapHoldTapIsCommand("alt_gr"), "Ctrl+Tab is a command")
		AssertTrue(TapHoldTapIsCommand("tab"), "a window switch is a command")
		AssertFalse(TapHoldTapIsCommand("right_ctrl"), "the one-shot Shift types")
		AssertFalse(TapHoldTapIsCommand("caps_lock"), "Enter is the key itself")
		AssertFalse(TapHoldTapIsCommand("space"), "an unconfigured key taps itself")
	} finally {
		TapHold := Saved
	}
}

Test("event word reset: a tap-hold's Paste tap answers to the tap-hold setting", _HEWR_PasteTapIsTheTapHolds)
Test("event word reset: a shortcut under a tap-hold's hold or layer is the tap-hold's", _HEWR_ShortcutUnderAHeldModifier)
Test("event word reset: Shift and AltGr holds leave shortcuts to the shortcut setting", _HEWR_TypingHoldsAreNotTheTapHolds)
Test("event word reset: which tap actions are commands", _HEWR_TypingTapsAreNoCommands)





; =======================================
; =======================================
; ======= 4/ Menu and persistence =======
; =======================================
; =======================================

global _HEWR_Writes := []

_HEWR_Writer(Path, Updates) {
	global _HEWR_Writes
	_HEWR_Writes.Push(Updates[1])
	return true
}

_HEWR_DefaultsAreTheManifests() {
	global HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	Saved := [HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord]
	try {
		HSE_ArrowResetsWord := "", HSE_ShortcutResetsWord := "", HSE_TapHoldResetsWord := ""
		for _, Key in ["arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word"] {
			AssertEqual(ManifestDefaultFor("hotstrings." . Key), HSE_WordResetFlagCurrent(Key), Key)
			AssertTrue(HSE_WordResetFlagCurrent(Key), Key . " defaults to on")
		}
		Refused := false
		try HSE_WordResetFlagCurrent("click")
		catch ValueError
			Refused := true
		AssertTrue(Refused, "an unknown setting is refused")
	} finally {
		HSE_ArrowResetsWord := Saved[1], HSE_ShortcutResetsWord := Saved[2], HSE_TapHoldResetsWord := Saved[3]
	}
}

_HEWR_TogglesPersistAndPublish() {
	global _HEWR_Writes, HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord
	global ConfigurationFile, Features
	Hotstrings := Features["hotstrings"]
	Keys := ["arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word"]
	Saved := { path: ConfigurationFile, values: [HSE_ArrowResetsWord, HSE_ShortcutResetsWord, HSE_TapHoldResetsWord],
		leaves: Map() }
	for _, Key in Keys
		if Hotstrings.Has(Key)
			Saved.leaves[Key] := Hotstrings[Key]
	Fixture := _ScopeOwnerFixture()
	try {
		ConfigurationFile := Fixture.path
		_HEWR_Writes := []
		HSE_ArrowResetsWord := true, HSE_ShortcutResetsWord := true, HSE_TapHoldResetsWord := false
		for _, Key in Keys
			AssertTrue(ToggleHotstringsWordResetFlag(Key, _HEWR_Writer, (*) => 0, (*) => 1), Key . " toggles")
		AssertFalse(HSE_ArrowResetsWord, "the engine reads the arrow setting at once")
		AssertFalse(HSE_ShortcutResetsWord)
		AssertTrue(HSE_TapHoldResetsWord)
		AssertEqual(3, _HEWR_Writes.Length)
		for Index, Key in Keys {
			AssertEqual("hotstrings", _HEWR_Writes[Index].Section)
			AssertEqual(Key, _HEWR_Writes[Index].Key)
			AssertTrue(_HEWR_Writes[Index].Value is TOML_Bool, Key . " is written as a TOML boolean")
		}
		AssertFalse(_HEWR_Writes[1].Value.Value)
		AssertTrue(_HEWR_Writes[3].Value.Value)
	} finally {
		ConfigurationFile := Saved.path
		HSE_ArrowResetsWord := Saved.values[1], HSE_ShortcutResetsWord := Saved.values[2]
		HSE_TapHoldResetsWord := Saved.values[3]
		for _, Key in Keys {
			if Saved.leaves.Has(Key)
				Hotstrings[Key] := Saved.leaves[Key]
			else if Hotstrings.Has(Key)
				Hotstrings.Delete(Key)
		}
		PreviousCritical := Critical("Off")
		try _ScopeOwnerCleanup(Fixture)
		finally Critical(PreviousCritical)
	}
}

; The rows the manifest declares are drawn from the driver's commands and
; getters, ticked from the setting in force.
_HEWR_LoaderAndMenuWiring() {
	Reader := _DriverFuncBody("ReadScriptConfig")
	for _, Key in ["arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word"]
		AssertTrue(InStr(Reader, '_FeatureStateWordResetFlag(Cache, "' . Key . '")') > 0,
			"the loader reads hotstrings." . Key)
	Stage := _DriverFuncBody("_MI_StageHotstrings")
	for _, Key in ["arrow_resets_word", "shortcut_resets_word", "tap_hold_resets_word"] {
		AssertTrue(InStr(Stage, '"' . Key . '", (*) => ToggleHotstringsWordResetFlag("' . Key . '")') > 0,
			"the " . Key . " row has its command")
		AssertTrue(InStr(Stage, '"hotstrings_' . Key . '", () => HSE_WordResetFlagCurrent("' . Key . '")') > 0,
			"the " . Key . " row has its tick")
	}
	Dispatch := _DriverFuncBody("TapHoldDispatchTap")
	AssertTrue(InStr(Dispatch, 'HS_ApplyEventWordReset("tap_hold_resets_word"') > 0,
		"a command tap applies the tap-hold setting")
	Commit := _DriverFuncBody("HS_CommitSyntheticEffect")
	AssertTrue(InStr(Commit, "HS_SyntheticPayloadKind(Payload)") > 0,
		"every synthetic key press is classified before it resets the word")
}

Test("event word reset: defaults come from the manifest", _HEWR_DefaultsAreTheManifests)
Test("event word reset: toggles persist and publish", _HEWR_TogglesPersistAndPublish)
Test("event word reset: loader, menu and tap-hold wiring", _HEWR_LoaderAndMenuWiring)
