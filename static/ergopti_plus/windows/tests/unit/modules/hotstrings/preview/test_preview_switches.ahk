; tests/unit/modules/hotstrings/preview/test_preview_switches.ahk

; ==============================================================================
; MODULE: Preview-bubble switches on Windows (PAR-24)
; DESCRIPTION:
; macOS and Linux have four switches for the hotstring preview bubble: the star
; family, the autocorrect family, the AI bubble and the category tint. Windows
; drew its bubble with none of them. These cases pin the Windows side:
;
; 1. The prefix watcher classifies each candidate into the star family (a
;    magic-key completion) or the autocorrect family (an end-character
;    completion) and paints it only when that family's switch is on.
; 2. The tint is dropped when the colour switch is off.
; 3. The automatic AI prediction is skipped when the AI switch is off, while a
;    request the user asked for by name (an Override) is not a preview.
; 4. The switches default to the manifest's value, persist through the config
;    gateway, publish to the readers at once, and are drawn by the shared rows.
; ==============================================================================

#Requires AutoHotkey v2.0

global _PSW_Writes := []





; ==============================
; ==============================
; ======= 1/ The fixture =======
; ==============================
; ==============================

; Runs Body with the four switches set from Wanted (Map key -> Boolean), then
; puts the published values back.
_PSW_WithSwitches(Wanted, Body) {
	global HSE_PreviewSwitches
	Saved := HSE_PreviewSwitches
	Fresh := Map()
	for Key in HSE_PreviewSwitchKeys()
		Fresh[Key] := Wanted.Has(Key) ? Wanted[Key] : true
	HSE_PreviewSwitches := Fresh
	try Body()
	finally HSE_PreviewSwitches := Saved
}

; Registers the star row "(v)" + magic key and the autocorrect row "api", types
; Typed, renders, and returns the texts the bubble was asked to show.
_PSW_RenderedTexts(Typed) {
	Saved := _HPS_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_HPS_RegisterDelayed("*C", "(v)" . MK, Chr(0x2713), 2, "magickey", "text_expansion_symbols")
		_HPS_RegisterDelayed("", "api", "API", 1, "autocorrection", "caps")
		HSE_FeedReset(true)
		_HPS_ObserveTyped(Typed)
		_LookupAndRender()
		Texts := []
		for Row in _HPS_PendingRows()
			Texts.Push(Row.Text)
		return Texts
	} finally {
		_HPS_Teardown(Saved)
	}
}

; The pending rows (not only their texts) for one typed word.
_PSW_RenderedRows(Typed) {
	Saved := _HPS_Setup()
	try {
		MK := ScriptInformation["MagicKey"]
		_HPS_RegisterDelayed("*C", "(v)" . MK, Chr(0x2713), 2, "magickey", "text_expansion_symbols")
		HSE_FeedReset(true)
		_HPS_ObserveTyped(Typed)
		_LookupAndRender()
		Rows := []
		for Row in _HPS_PendingRows()
			Rows.Push(Row)
		return Rows
	} finally {
		_HPS_Teardown(Saved)
	}
}





; ========================================
; ========================================
; ======= 2/ Families and the tint =======
; ========================================
; ========================================

_PSW_StarSwitchGovernsTheMagicKeyRow() {
	_PSW_WithSwitches(Map(), () => AssertEqual(1, _PSW_RenderedTexts("(v)").Length,
		"sanity: with every switch on the magic-key row is shown"))
	_PSW_WithSwitches(Map("preview_star_enabled", false), () =>
		AssertEqual(0, _PSW_RenderedTexts("(v)").Length,
			"the star switch off must hide the magic-key bubble (PAR-24)"))
	_PSW_WithSwitches(Map("preview_star_enabled", false), () =>
		AssertEqual(1, _PSW_RenderedTexts("api").Length,
			"the star switch must not hide the autocorrect bubble"))
}

_PSW_AutocorrectSwitchGovernsTheEndCharacterRow() {
	_PSW_WithSwitches(Map("preview_autocorrect_enabled", false), () =>
		AssertEqual(0, _PSW_RenderedTexts("api").Length,
			"the autocorrect switch off must hide the end-character bubble (PAR-24)"))
	_PSW_WithSwitches(Map("preview_autocorrect_enabled", false), () =>
		AssertEqual(1, _PSW_RenderedTexts("(v)").Length,
			"the autocorrect switch must not hide the magic-key bubble"))
}

_PSW_ColourSwitchDropsTheTint() {
	Tinted := 0
	_PSW_WithSwitches(Map(), () => Tinted := _PSW_RenderedRows("(v)"))
	AssertEqual(1, Tinted.Length, "sanity: the magic-key row is shown")
	Expected := HotstringsResolve("magickey", "text_expansion_symbols").Color
	AssertTrue(Expected != "", "sanity: the magic-key category carries a colour, or this case proves nothing")
	AssertEqual(Expected, Tinted[1].ColorHex, "with the colour switch on the bubble carries its category colour")
	Plain := 0
	_PSW_WithSwitches(Map("preview_colored_tooltips", false), () => Plain := _PSW_RenderedRows("(v)"))
	AssertEqual(1, Plain.Length, "the colour switch governs appearance, not presence")
	AssertEqual("", Plain[1].ColorHex, "the colour switch off must leave the bubble neutral (PAR-24)")
}

Test("preview switches: the star switch governs the magic-key bubble only (PAR-24)", _PSW_StarSwitchGovernsTheMagicKeyRow)
Test("preview switches: the autocorrect switch governs the end-character bubble only (PAR-24)", _PSW_AutocorrectSwitchGovernsTheEndCharacterRow)
Test("preview switches: the colour switch drops the tint, not the bubble (PAR-24)", _PSW_ColourSwitchDropsTheTint)





; ============================
; ============================
; ======= 3/ AI bubble =======
; ============================
; ============================

; Fires the automatic prediction against a minimal engine Map and reports
; whether the request id moved, which every fire past the gate does first.
_PSW_FireMoves(Override) {
	global _LLM_Engine
	Saved := _LLM_Engine
	_LLM_Engine := Map("enabled", true, "request_id", 7, "disable_password_fields", false)
	try {
		try LLM_Engine_FirePrediction("hello world", unset, Override)
		return _LLM_Engine["request_id"] != 7
	} finally {
		_LLM_Engine := Saved
	}
}

_PSW_AiSwitchGovernsTheAutomaticPrediction() {
	Moved := true
	_PSW_WithSwitches(Map("preview_ai_enabled", false), () => Moved := _PSW_FireMoves(0))
	AssertFalse(Moved, "the AI switch off must stop the automatic prediction before it starts a request (PAR-24)")
	_PSW_WithSwitches(Map(), () => Moved := _PSW_FireMoves(0))
	AssertTrue(Moved, "sanity: with the AI switch on the same fire starts a request")
	_PSW_WithSwitches(Map("preview_ai_enabled", false), () => Moved := _PSW_FireMoves(
		Map("profile_id", "none", "num_predictions", 0, "live", false)))
	AssertTrue(Moved, "a request the user asked for by name is not a preview: the switch does not stop it")
}

Test("preview switches: the AI switch governs the automatic prediction only (PAR-24)", _PSW_AiSwitchGovernsTheAutomaticPrediction)





; =====================================================
; =====================================================
; ======= 4/ Defaults, persistence and the rows =======
; =====================================================
; =====================================================

_PSW_Writer(Path, Updates) {
	global _PSW_Writes
	_PSW_Writes.Push(Updates[1])
	return true
}

_PSW_DefaultsAreTheManifests() {
	global HSE_PreviewSwitches
	Saved := HSE_PreviewSwitches
	HSE_PreviewSwitches := Map()
	try {
		AssertEqual(4, HSE_PreviewSwitchKeys().Length)
		for Key in HSE_PreviewSwitchKeys() {
			AssertEqual(true, ManifestDefaultFor("hotstrings." . Key),
				Key . " ships on, on all three drivers (PAR-24)")
			AssertEqual(ManifestDefaultFor("hotstrings." . Key), HSE_PreviewSwitchCurrent(Key),
				"an unloaded switch reads the manifest default")
		}
	} finally {
		HSE_PreviewSwitches := Saved
	}
	Refused := false
	try HSE_PreviewSwitchCurrent("preview_nothing")
	catch
		Refused := true
	AssertTrue(Refused, "a key that is no preview switch is an error, not 'off'")
}

_PSW_TogglesPersistAndPublish() {
	global _PSW_Writes, HSE_PreviewSwitches, ConfigurationFile, Features
	Hotstrings := Features["hotstrings"]
	Saved := { path: ConfigurationFile, switches: HSE_PreviewSwitches, leaves: Map() }
	for Key in HSE_PreviewSwitchKeys()
		if Hotstrings.Has(Key)
			Saved.leaves[Key] := Hotstrings[Key]
	Fixture := _ScopeOwnerFixture()
	try {
		ConfigurationFile := Fixture.path
		_PSW_Writes := []
		HSE_PreviewSwitches := Map()
		for Key in HSE_PreviewSwitchKeys()
			AssertTrue(ToggleHotstringsPreviewSwitch(Key, _PSW_Writer, (*) => 0, (*) => 1), Key . " toggles")
		for Index, Key in HSE_PreviewSwitchKeys() {
			AssertFalse(HSE_PreviewSwitchCurrent(Key), "the readers see " . Key . " off at once")
			AssertEqual("hotstrings", _PSW_Writes[Index].Section)
			AssertEqual(Key, _PSW_Writes[Index].Key)
			AssertTrue(_PSW_Writes[Index].Value is TOML_Bool, Key . " is written as a TOML boolean")
			AssertFalse(_PSW_Writes[Index].Value.Value)
		}
		AssertFalse(ToggleHotstringsPreviewSwitch("preview_nothing", _PSW_Writer, (*) => 0, (*) => 1),
			"an unknown switch is refused")
		AssertEqual(4, _PSW_Writes.Length, "a refused switch writes nothing")
	} finally {
		ConfigurationFile := Saved.path
		HSE_PreviewSwitches := Saved.switches
		for Key in HSE_PreviewSwitchKeys() {
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

; The tray draws the four declared rows in the shared order, each ticked from the
; switch in force and running the toggle for its own key.
_PSW_MenuRowsFollowTheSwitches() {
	Toggled := []
	Rows := 0
	_PSW_WithSwitches(Map("preview_ai_enabled", false), () => Rows := _HS_PreviewBubbleRows(
		(Key) => Toggled.Push(Key)))
	AssertEqual(1, Rows.Length, "one parent row hangs the submenu")
	Sub := Rows[1]
	AssertEqual(t("menu.hotstrings.preview_bubbles"), Sub["label"], "the parent carries the shared caption")
	Children := Sub["items"]
	Labels := [], Switches := []
	for Child in Children {
		if !(Child.Has("separator") && Child["separator"] == 1) {
			Labels.Push(Child["label"])
			Switches.Push(Child)
		}
	}
	AssertEqual(4, Labels.Length, "the four switches are offered (PAR-24)")
	Expected := ["menu.hotstrings.tooltip_magic", "menu.hotstrings.tooltip_autocorrect",
		"menu.hotstrings.tooltip_ai", "menu.hotstrings.tooltip_colored"]
	for Index, Key in Expected
		AssertEqual(t(Key), Labels[Index], "row " . Index . " follows the shared order")
	Keys := HSE_PreviewSwitchKeys()
	for Index, Row in Switches {
		AssertEqual(Keys[Index] != "preview_ai_enabled", Row["checked"] ? true : false,
			Keys[Index] . " is ticked from the switch in force")
		Row["action"].Call()
	}
	AssertEqual(Keys.Length, Toggled.Length, "every row runs a toggle")
	for Index, Key in Keys
		AssertEqual(Key, Toggled[Index], "row " . Index . " toggles its own switch")
}

Test("preview switches: defaults come from the manifest and a stray key is refused (PAR-24)", _PSW_DefaultsAreTheManifests)
Test("preview switches: toggles persist and publish (PAR-24)", _PSW_TogglesPersistAndPublish)
Test("preview switches: the tray draws the four shared rows (PAR-24)", _PSW_MenuRowsFollowTheSwitches)
