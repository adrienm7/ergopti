; tests/unit/layouts/engine/registry/test_source_emulation.ahk

; ==============================================================================
; MODULE: Layout Source Emulation Tests (Windows)
; DESCRIPTION:
; The AutoHotkey engine (layouts/engine/keylayout/source_emulation.ahk) replays
; the shared typing vectors the web and Lua engines replay
; (_shared/tests/corpus/layouts/source/emulation_vectors.json), refuses the
; malformed tables they refuse, and keylayout_emulation.ahk performs it for the
; composed layout: the composer-folder fallback of the boot, the hotkeys it
; registers before the layout's own, and what each action sends.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LSE_CorpusDir() => _SharedDir . "\tests\corpus\layouts\source\"

_LSE_Golden() {
	static Golden := 0
	if !(Golden is Map)
		Golden := JsonParse(FileRead(_LSE_CorpusDir() . "emulation.json", "UTF-8"))
	return Golden
}

; A deep copy, so a mutation case never touches the shared golden table.
_LSE_Clone(Value) {
	if Value is Map {
		Copy := Map()
		for Key, Item in Value
			Copy[Key] := _LSE_Clone(Item)
		return Copy
	}
	if Value is Array {
		Copy := []
		for Item in Value
			Copy.Push(_LSE_Clone(Item))
		return Copy
	}
	return Value
}

; One canonical spelling of actions, so an engine result and a vector compare as text.
_LSE_Actions(Actions) {
	Out := ""
	for Action in Actions {
		switch Action["type"] {
			case "text": Item := "text:" . Action["text"]
			case "key":
				Modifiers := ""
				for Id in Action["modifiers"]
					Modifiers .= (A_Index > 1 ? "+" : "") . Id
				Item := "key:" . Action["key"] . "[" . Modifiers . "]"
			case "modifier": Item := "modifier:" . Action["id"] . (Action["down"] ? ":down" : ":up")
			default: Item := "unknown:" . Action["type"]
		}
		Out .= (A_Index > 1 ? " | " : "") . Item
	}
	return Out
}

; Replays one vector case on a fresh session; returns the first mismatch, "" when none.
_LSE_Replay(Table, Steps) {
	Session := SourceEmulation_NewSession(SourceEmulation_Compile(Table))
	for Index, Step in Steps {
		if Step.Has("press") {
			Held := Map()
			for Id in Step["held"]
				Held[Id] := true
			Got := SourceEmulation_Press(Session, Step["press"], Held, Step["at"])
		} else if Step.Has("release") {
			Got := SourceEmulation_Release(Session, Step["release"], Step["at"])
		} else if Step.Has("tick") {
			Got := Map("actions", SourceEmulation_Tick(Session, Step["tick"]))
		} else {
			Got := Map("actions", SourceEmulation_Reset(Session))
		}
		Actual := _LSE_Actions(Got["actions"])
		Expected := _LSE_Actions(Step["actions"])
		if Step.Has("consumed") {
			Actual .= " consumed=" . (Got["consumed"] ? 1 : 0)
			Expected .= " consumed=" . (Step["consumed"] ? 1 : 0)
		}
		if Actual !== Expected
			return "step " . (Index - 1) . ": [" . Actual . "] != [" . Expected . "]"
	}
	return ""
}





; =================================
; =================================
; ======= 2/ Shared vectors =======
; =================================
; =================================

Test("layout source emulation: the AutoHotkey engine replays the shared typing vectors (layout-source-emulation)",
	_LSE_VectorsCase)

_LSE_VectorsCase() {
	Vectors := JsonParse(FileRead(_LSE_CorpusDir() . "emulation_vectors.json", "UTF-8"))
	Golden := _LSE_Golden()
	Platforms := Map()
	for Platform in Vectors["platforms"]
		Platforms[Platform] := true
	AssertTrue(Platforms.Has("windows"), "the vectors are replayed on the Windows table")
	Replayed := 0, Failures := []
	for Platform in Vectors["platforms"]
		for Vector in Vectors["cases"] {
			Replayed += 1
			Mismatch := _LSE_Replay(Golden[Platform], Vector["steps"])
			if Mismatch != ""
				Failures.Push(Platform . ": " . Vector["name"] . ": " . Mismatch)
		}
	Assert(Replayed >= 3 * 15, "the corpus holds at least 15 cases per platform")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("layout source emulation: the replay sees a changed expected action (layout-source-emulation)",
	_LSE_ReplayCanFailCase)

_LSE_ReplayCanFailCase() {
	Vectors := JsonParse(FileRead(_LSE_CorpusDir() . "emulation_vectors.json", "UTF-8"))
	for Vector in Vectors["cases"] {
		Steps := _LSE_Clone(Vector["steps"])
		for Step in Steps {
			if Step["actions"].Length {
				Step["actions"][1]["type"] := "changed"
				Assert(_LSE_Replay(_LSE_Golden()["windows"], Steps) != "", "a changed action is a mismatch")
				return
			}
		}
	}
	Assert(false, "the corpus holds a vector with an action")
}

Test("layout source emulation: a malformed table is refused when compiled, never on a key (layout-source-emulation)",
	_LSE_RefusalsCase)

_LSE_RefusalsCase() {
	Samples := [
		["format", (T) => T["format"] := "other", "is not an ergopti-layout-emulation version 1"],
		["version", (T) => T["version"] := 2, "is not an ergopti-layout-emulation version 1"],
		["layer modifier", (T) => T["layers"][3]["selectors"][1]["required"].Push("unknown"), "unknown modifier 'unknown'"],
		["hold layer", (T) => T["tap_holds"][1]["hold_layer"] := "missing", "unknown layer 'missing'"],
		["two holds", (T) => T["tap_holds"][1]["hold_modifier"] := "shift", "needs one hold"],
		["threshold", (T) => T["tap_holds"][1]["threshold_ms"] := 0, "malformed tap-hold"],
		["mapping", (T) => T["layers"][1]["keys"]["KeyX"] := Map("dead_key", "acute"), "malformed mapping at layers.base.KeyX"],
		["shared key", (T) => T["modifiers"][2]["keys"].Push("IntlBackslash"), "share the key"],
		["two roles", (T) => T["tap_holds"][1]["key"] := "IntlBackslash", "two roles"]
	]
	for Sample in Samples {
		Table := _LSE_Clone(_LSE_Golden()["windows"])
		Sample[2].Call(Table)
		Message := ""
		try SourceEmulation_Compile(Table)
		catch as Err
			Message := Err.Message
		AssertContains(Message, Sample[3], Sample[1])
	}
	AssertTrue(SourceEmulation_HasRecords(SourceEmulation_Compile(_LSE_Golden()["windows"])))
}





; ====================================
; ====================================
; ======= 3/ The driver's half =======
; ====================================
; ====================================

Test("layout source emulation: the composed layout registers its keys before the layout's own (layout-source-emulation)",
	() => _KLT_WithEmulation(_LSE_RegistrationCase))

_LSE_RegistrationCase() {
	Log := []
	Registry := JsonParse(FileRead(_SharedDir . "\layouts\data\keycodes\physical_keys.json", "UTF-8"))
	KeylayoutEmulation_SourceUnload()
	try {
		_KLT_WithLayoutFeatures(Map("emulated_layout", "composed"), () =>
			KeylayoutEmulation_Boot("C:\cfg\", Map(
				"keycodes", LayoutRegistry_Keycodes,
				"register", (*) => Log.Push("register layout"),
				"read_local", _LCH_ReadNothing,
				"read_composed", (*) => 0,
				"read_emulation", (*) => _LSE_Golden()["windows"],
				"physical_keys", Registry,
				"source_hotif", (Criterion := 0) => Log.Push(Criterion ? "hotif source" : "hotif none"),
				"source_hotkey", (Name, Callback, Options) => Log.Push(Name . " " . Options),
				"install", (*) => Log.Push("install"))))
		AssertEqual("hotif source", Log[1], "the source criterion is set first")
		Layout := 0
		for Index, Item in Log
			if Item == "register layout"
				Layout := Index
		Assert(Layout > 2, "the layout's hotkeys register after the source's")
		AssertEqual("hotif none", Log[Layout - 1], "the source criterion is released")
		Names := Map()
		for Item in Log
			Names[Item] := true
		; IntlBackslash (roya), Insert (kana_lock), Space and Tab (tap-holds), KeyQ (shortcut).
		for Name in ["SC056 I0", "*SC056 I0", "*SC056 up I0", "*SC152 I0", "*SC039 I0", "*SC00F up I0",
				"^SC010 I0", "+SC01E I0"]
			AssertTrue(Names.Has(Name), Name . " is registered")
		; An emulated layer takes every alphanumeric key; the modifiers stay the OS's.
		AssertTrue(Names.Has("*SC015 I0"), "KeyY, unmapped, is taken while an emulated layer is selected")
		AssertFalse(Names.Has("*SC02A I0"), "Shift is never taken")
		AssertFalse(Names.Has("install"), "the composed layout is never downloaded")
		AssertTrue(KLE_SourceSession is Map, "the session is loaded")
	} finally KeylayoutEmulation_SourceUnload()
}

Test("layout source emulation: the boot reads the source stored in the composer folder (layout-source-emulation)",
	() => _KLT_WithEmulation(_LSE_ComposedFallbackCase))

_LSE_ComposedFallbackCase() {
	Dir := _KLT_TempDir()
	try {
		Composer := LayoutRegistry_Composer()
		Folder := LayoutRegistry_ComposerDir(Dir)
		DirCreate(Folder)
		FileAppend(FileRead(_LSE_CorpusDir() . "source.toml", "UTF-8-RAW"), Folder . Composer["source_file"], "UTF-8-RAW")
		FileAppend(FileRead(_LSE_CorpusDir() . "source.keylayout", "UTF-8-RAW"), Folder . Composer["keylayout_file"],
			"UTF-8-RAW")
		KeylayoutEmulation_Unload()
		Emulated := false
		_KLT_WithLayoutFeatures(Map("emulated_layout", "composed"), () =>
			Emulated := KeylayoutEmulation_Boot(Dir, Map(
				"keycodes", LayoutRegistry_Keycodes,
				"register", (*) => 0,
				"read_local", _LCH_ReadNothing,
				"install", (*) => Assert(false, "never installed"))))
		AssertTrue(Emulated, "the stored source is emulated")
		AssertEqual("composed", KLE_Id)
		AssertEqual("a", KeylayoutEmulation_Press("SC01E", false, false, false), "KeyA of the source types a")
		; The same folder with a source that names another layout is refused, never emulated.
		FileDelete(Folder . Composer["source_file"])
		FileAppend(StrReplace(FileRead(_LSE_CorpusDir() . "source.toml", "UTF-8-RAW"), 'id = "source_fixture"',
			'id = "other_fixture"'), Folder . Composer["source_file"], "UTF-8-RAW")
		KeylayoutEmulation_Unload()
		_KLT_WithLayoutFeatures(Map("emulated_layout", "composed"), () =>
			Emulated := KeylayoutEmulation_Boot(Dir, Map(
				"keycodes", LayoutRegistry_Keycodes,
				"register", (*) => 0,
				"read_local", _LCH_ReadNothing,
				"install", (*) => 0)))
		AssertFalse(Emulated, "a copy the source does not name is refused")
	} finally DirDelete(Dir, true)
}

Test("layout source emulation: each action sends what the macOS and Linux drivers post (layout-source-emulation)",
	_LSE_SendCase)

_LSE_SendCase() {
	Scans := Map("KeyC", "SC02E", "Escape", "SC001")
	AssertEqual("α", KeylayoutEmulation_SourceSend(Map("type", "text", "text", "α"), Scans)["text"])
	AssertEqual("^{SC02E}", KeylayoutEmulation_SourceSend(Map("type", "key", "key", "KeyC", "modifiers", ["control"]),
		Scans)["keys"])
	AssertEqual("{SC001}", KeylayoutEmulation_SourceSend(Map("type", "key", "key", "Escape", "modifiers", []),
		Scans)["keys"], "a key action releases the hand's modifiers")
	AssertEqual("<+>!{SC02E}", KeylayoutEmulation_SourceSend(Map("type", "key", "key", "KeyC",
		"modifiers", ["shift_left", "alt_right"]), Scans)["keys"])
	AssertEqual("{LShift down}", KeylayoutEmulation_SourceSend(Map("type", "modifier", "id", "shift", "down", true),
		Scans)["keys"])
	AssertEqual("{RAlt up}", KeylayoutEmulation_SourceSend(Map("type", "modifier", "id", "alt_right", "down", false),
		Scans)["keys"])
	AssertThrows(() => KeylayoutEmulation_SourceSend(Map("type", "key", "key", "Mystery", "modifiers", []), Scans))
	Held := KeylayoutEmulation_SourceHeld((Key, Mode) => (Key == "RShift" || Key == "RAlt" || (Key == "CapsLock" && Mode == "T")))
	AssertEqual("alt_right caps_lock shift", _KLT_Join([Held.Has("alt_right") ? "alt_right" : "",
		Held.Has("caps_lock") ? "caps_lock" : "", Held.Has("shift") ? "shift" : ""], " "))
	AssertFalse(Held.Has("control"))
}
