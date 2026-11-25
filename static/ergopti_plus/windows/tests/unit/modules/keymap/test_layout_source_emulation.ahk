; tests/unit/modules/keymap/test_layout_source_emulation.ahk

; ==============================================================================
; MODULE: Layout Source Emulation Tests (Windows)
; DESCRIPTION:
; The AutoHotkey engine (modules/keymap/keylayout/source_emulation.ahk) replays
; the shared typing vectors the web and Lua engines replay
; (_shared/tests/corpus/layouts/source/emulation_vectors.json, and for a
; layout's own repeat and magic keys context_vectors.json and
; _shared/tests/corpus/layouts/magic_vectors.json), refuses the
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
			Got := SourceEmulation_Press(Session, Step["press"], Held, Step["at"], Step.Get("before", 0))
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

Test("layout source emulation: Neo 2's Mod3 and Mod4 on Caps Lock and AltGr and their dead keys type as on the web (layout-levels-emulation)",
	_LSE_NeoLevelsCase)

_LSE_NeoLevelsCase() {
	Vectors := JsonParse(FileRead(_LSE_CorpusDir() . "neo2_vectors.json", "UTF-8"))
	Tables := JsonParse(FileRead(_LSE_CorpusDir() . Vectors["table"], "UTF-8"))
	Replayed := 0, Failures := []
	for Platform in Vectors["platforms"] {
		Model := SourceEmulation_Compile(Tables[Platform])
		AssertTrue(SourceEmulation_HoldsModifierKey(Model, "AltRight"), Platform . ": AltGr holds Mod4")
		AssertEqual(Platform != "macos", SourceEmulation_HoldsModifierKey(Model, "CapsLock"),
			Platform . ": Caps Lock holds Mod3 where the hook sees it held")
		for Vector in Vectors["cases"] {
			if Vector.Has("platforms") {
				Listed := false
				for Name in Vector["platforms"]
					Listed := Listed || Name == Platform
				if !Listed
					continue
			}
			Replayed += 1
			Mismatch := _LSE_Replay(Tables[Platform], Vector["steps"])
			if Mismatch != ""
				Failures.Push(Platform . ": " . Vector["name"] . ": " . Mismatch)
		}
	}
	Assert(Replayed >= 3 * 16, "every Neo vector is replayed on the three platforms")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("layout source emulation: a layout's repeat and magic keys type from the text typed before (layout-context-keys-emulation)",
	_LSE_ContextKeysCase)

_LSE_ContextKeysCase() {
	Vectors := JsonParse(FileRead(_LSE_CorpusDir() . "context_vectors.json", "UTF-8"))
	Tables := JsonParse(FileRead(_LSE_CorpusDir() . Vectors["table"], "UTF-8"))
	Replayed := 0, Failures := []
	for Platform in Vectors["platforms"] {
		for Vector in Vectors["cases"] {
			Replayed += 1
			Mismatch := _LSE_Replay(Tables[Platform], Vector["steps"])
			if Mismatch != ""
				Failures.Push(Platform . ": " . Vector["name"] . ": " . Mismatch)
		}
		Session := SourceEmulation_NewSession(SourceEmulation_Compile(Tables[Platform]))
		Refused := false
		try SourceEmulation_Press(Session, "Quote", Map(), 0)
		catch Error as Err
			Refused := InStr(Err.Message, "needs the text typed before it") > 0
		AssertTrue(Refused, Platform . ": a magic key without the text before is refused")
	}
	Assert(Replayed >= 3 * 7, "every context vector is replayed on the three platforms")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("layout source emulation: a repeat or magic key types what the shared magic vectors say (layout-context-keys-emulation)",
	_LSE_MagicVectorsCase)

_LSE_MagicVectorsCase() {
	Vectors := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\magic_vectors.json", "UTF-8"))
	Failures := []
	for Vector in Vectors["vectors"] {
		Action := Vector["action"]
		Mapping := Action.Has("magic") ? Map("magic", Action["magic"]) : Map("repeat", Action["repeat"])
		Got := SourceEmulation_ContextText(Vectors["magic"], Mapping, Vector["before"])
		if Got !== Vector["types"]
			Failures.Push("after [" . Vector["before"] . "]: [" . Got . "] != [" . Vector["types"] . "]")
	}
	Assert(Vectors["vectors"].Length >= 20, "the corpus holds at least 20 vectors")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("layout source emulation: the Ergopti layouts leave Caps Lock and AltGr to Windows and emulate no dead key (ergopti-emulation-unchanged)",
	_LSE_ErgoptiUnchangedCase)

_LSE_ErgoptiUnchangedCase() {
	Pinned := JsonParse(FileRead(_LSE_CorpusDir() . "ergopti_emulation.json", "UTF-8"))
	Checked := 0
	for File, Tables in Pinned
		for Platform, Table in Tables {
			Where := File . " on " . Platform
			AssertFalse(Table.Has("dead_keys"), Where . ": no dead key is emulated")
			Model := SourceEmulation_Compile(Table)
			for Key in ["CapsLock", "AltRight"] {
				AssertFalse(SourceEmulation_HoldsModifierKey(Model, Key), Where . ": " . Key . " keeps its role")
				Got := SourceEmulation_Press(SourceEmulation_NewSession(Model), Key, Map(), 0)
				AssertTrue(!Got["consumed"] && !Got["actions"].Length, Where . ": " . Key . " goes to Windows")
			}
			Checked += 1
		}
	Assert(Checked >= 5 * 3, "every Ergopti table is checked on the three platforms")
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
		["mapping", (T) => T["layers"][1]["keys"]["KeyX"] := Map("dead_key", "undeclared"), "malformed mapping at layers.base.KeyX"],
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
		; The JIS character keys are taken, its input-method keys stay the IME's.
		AssertTrue(Names.Has("*SC073 I0"), "IntlRo is taken while an emulated layer is selected")
		AssertTrue(Names.Has("*SC07D I0"), "IntlYen is taken while an emulated layer is selected")
		for Sc in ["SC079", "SC07B", "SC070"]
			AssertFalse(Names.Has("*" . Sc . " I0"), Sc . " (an input-method key) is never taken")
		AssertFalse(Names.Has("install"), "the composed layout is never downloaded")
		AssertTrue(KLE_SourceSession is Map, "the session is loaded")
	} finally KeylayoutEmulation_SourceUnload()
}

Test("layout source emulation: Caps Lock and AltGr holding Neo's Mod3 and Mod4 are taken as plain keys (layout-levels-emulation)",
	() => _KLT_WithEmulation(_LSE_NeoModifierKeysCase))

_LSE_NeoModifierKeysCase() {
	Registry := JsonParse(FileRead(_SharedDir . "\layouts\data\keycodes\physical_keys.json", "UTF-8"))
	Neo := JsonParse(FileRead(_LSE_CorpusDir() . "neo2_emulation.json", "UTF-8"))["windows"]
	Callbacks := Map()
	KeylayoutEmulation_SourceUnload()
	try {
		KeylayoutEmulation_SourceLoad(SourceEmulation_Compile(Neo), Registry,
			(Name, Callback, Options) => Callbacks[Name] := Callback, (Criterion := 0) => 0)
		for Name in ["*SC03A", "*SC03A up", "*SC138", "*SC138 up", "+SC138", "*SC02B", "*SC056"]
			AssertTrue(Callbacks.Has(Name), Name . " is registered")
		AssertFalse(Callbacks.Has("*SC02A"), "Shift is never taken")
		AssertFalse(Callbacks.Has("*SC01D"), "the LCtrl an AltGr layout adds stays Windows'")
		; The suppressed Caps Lock press holds Mod3 and never reaches Windows as the lock.
		Callbacks["*SC03A"].Call()
		AssertTrue(SourceEmulation_Active(KLE_SourceSession, "mod3"), "Caps Lock holds Mod3")
		Callbacks["*SC03A up"].Call()
		AssertFalse(SourceEmulation_Active(KLE_SourceSession, "mod3"), "its release returns to the base level")
		; AltGr holds Mod4; the LCtrl the AltGr layout adds to it is no Control.
		Callbacks["*SC138"].Call()
		AssertTrue(SourceEmulation_Active(KLE_SourceSession, "mod4"), "AltGr holds Mod4")
		Callbacks["*SC138"].Call()
		AssertTrue(SourceEmulation_Active(KLE_SourceSession, "mod4"), "its auto-repeat keeps Mod4 held")
		Physical := (Key) => (Key == "LControl" || Key == "RAlt")
		Held := KeylayoutEmulation_SourceHeld(Physical, () => false, () => false)
		AssertFalse(Held.Has("control"), "AltGr's own LCtrl is not the user's Control")
		Held := KeylayoutEmulation_SourceHeld(Physical, () => false, () => true)
		AssertTrue(Held.Has("control"), "a Control the user holds with it is kept")
		Callbacks["*SC138 up"].Call()
		AssertFalse(SourceEmulation_Active(KLE_SourceSession, "mod4"), "its release ends Mod4")
		Held := KeylayoutEmulation_SourceHeld(Physical, () => false, () => false)
		AssertTrue(Held.Has("control"), "without Mod4 on AltGr, a held LCtrl is a Control as before")
	} finally KeylayoutEmulation_SourceUnload()
}

Test("layout source emulation: the Ergopti layouts never take Caps Lock or AltGr (ergopti-emulation-unchanged)",
	() => _KLT_WithEmulation(_LSE_ErgoptiModifierKeysCase))

_LSE_ErgoptiModifierKeysCase() {
	Registry := JsonParse(FileRead(_SharedDir . "\layouts\data\keycodes\physical_keys.json", "UTF-8"))
	Pinned := JsonParse(FileRead(_LSE_CorpusDir() . "ergopti_emulation.json", "UTF-8"))
	for File, Tables in Pinned {
		Names := Map()
		KeylayoutEmulation_SourceUnload()
		try {
			Model := SourceEmulation_Compile(Tables["windows"])
			AssertFalse(_KLE_SourceHoldsModifierKey(Model, "CapsLock") || _KLE_SourceHoldsModifierKey(Model, "AltRight"),
				File . ": neither key holds a modifier")
			KeylayoutEmulation_SourceLoad(Model, Registry, (Name, Callback, Options) => Names[Name] := true,
				(Criterion := 0) => 0)
			for Name in ["*SC03A", "*SC138"]
				AssertFalse(Names.Has(Name), File . ": " . Name . " keeps its own role")
		} finally KeylayoutEmulation_SourceUnload()
	}
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
	Held := KeylayoutEmulation_SourceHeld((Key) => (Key == "RShift" || Key == "RAlt"), () => true)
	AssertEqual("alt_right caps_lock shift", _KLT_Join([Held.Has("alt_right") ? "alt_right" : "",
		Held.Has("caps_lock") ? "caps_lock" : "", Held.Has("shift") ? "shift" : ""], " "))
	AssertFalse(Held.Has("control"))
}
