; tests/unit/test_keylayout_emulation.ahk

; ==============================================================================
; MODULE: Registry Layout Emulation Tests
; DESCRIPTION:
; Windows emulates a registry layout by reading its macOS .keylayout, with no
; Windows version of the layout anywhere (layout-registry-emulation). These
; tests drive the real modules on the real registry files:
; - the shared keystroke vectors (_shared/tests/corpus/layouts), read by hand
;   from the XML, replayed through the emulation for Ergo-L and Ergopti (the
;   Ergopti emulation's own tables are pinned by test_ergopti_keylayout_tables);
; - the reader's rules on synthetic layouts, and its fail-fast refusals;
; - the registry client: URL, verification and the local copy read through
;   the installed record (downloads are the catalogue's, test_layout_catalogue);
; - registration (every key, no native chord taken), supersession of the
;   Ergopti emulation by the master gates, and the boot sequence.
; Non-ASCII expectations come from the JSON vectors or Chr() so the suite
; source stays ASCII-only.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_KLT_RegistryDir() => _StaticDir . "\layouts\registry\"

_KLT_IndexText() => FileRead(_KLT_RegistryDir() . "index.json", "UTF-8-RAW")

_KLT_Entry(Id) => LayoutRegistry_FindEntry(JsonParse(_KLT_IndexText()), Id)

_KLT_LayoutText(Id) {
	Entry := _KLT_Entry(Id)
	return FileRead(_KLT_RegistryDir() . StrReplace(Entry["file"], "/", "\"), "UTF-8-RAW")
}

_KLT_Load(Id) {
	Entry := _KLT_Entry(Id)
	return KeylayoutEmulation_Load(Id, _KLT_LayoutText(Id), Entry["keycode_convention"],
		LayoutRegistry_Keycodes())
}

; Runs Fn with the emulation state restored afterwards, whatever Fn loads.
_KLT_WithEmulation(Fn) {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	try Fn()
	finally {
		KLE_Model := Saved[1]
		KLE_Id := Saved[2]
		KLE_State := Saved[3]
		KLE_KeyCodes := Saved[4]
		KLE_LevelIndex := Saved[5]
		KLE_Compositions := Saved[6]
	}
}

; Runs Fn with Features["layout"] replaced by Layout.
_KLT_WithLayoutFeatures(Layout, Fn) {
	global Features
	Saved := Features["layout"]
	Features["layout"] := Layout
	try Fn()
	finally Features["layout"] := Saved
}

_KLT_Press(Press) {
	Parts := StrSplit(Press, " ")
	Shift := false
	Caps := false
	Option := false
	Loop Parts.Length - 1 {
		switch Parts[A_Index] {
			case "shift": Shift := true
			case "caps": Caps := true
			case "altgr": Option := true
			default: throw ValueError("Unknown modifier in a keylayout vector.", -1, Parts[A_Index])
		}
	}
	return KeylayoutEmulation_Press(Parts[Parts.Length], Shift, Caps, Option)
}

_KLT_Join(Items, Separator := "; ") {
	Out := ""
	for Item in Items
		Out .= (A_Index > 1 ? Separator : "") . Item
	return Out
}

_KLT_TempDir() {
	Dir := A_Temp . "\ergopti_keylayout_test_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

_KLT_WriteRaw(Path, Text) {
	F := FileOpen(Path, "w", "UTF-8-RAW")
	F.Write(Text)
	F.Close()
}

; Replaces the first occurrence of Old by New, failing loudly if absent so a
; tampering helper can never silently serve the untouched file.
_KLT_Tamper(Text, Old, New) {
	Pos := InStr(Text, Old, true)
	if !Pos
		throw Error("tamper target not found: " . Old)
	return SubStr(Text, 1, Pos - 1) . New . SubStr(Text, Pos + StrLen(Old))
}





; =================================
; =================================
; ======= 2/ Shared vectors =======
; =================================
; =================================

Test("keylayout emulation: shared keystroke vectors type what the .keylayout says (layout-registry-emulation)",
	() => _KLT_WithEmulation(_KLT_VectorsCase))

_KLT_VectorsCase() {
	Doc := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\keylayout_vectors.json", "UTF-8"))
	Vectors := Doc["vectors"]
	Assert(Vectors.Length >= 30, "the keystroke corpus must hold at least 30 vectors, got " . Vectors.Length)
	Loaded := ""
	Layouts := Map()
	Presses := 0
	Shortcuts := 0
	Failures := []
	for Vector in Vectors {
		if (Vector["layout"] != Loaded) {
			_KLT_Load(Vector["layout"])
			Loaded := Vector["layout"]
		}
		Layouts[Loaded] := true
		KeylayoutEmulation_ResetDeadKey()
		if Vector.Has("press") {
			Presses += 1
			Typed := ""
			for Press in Vector["press"]
				Typed .= _KLT_Press(Press)
			if (Typed !== Vector["types"])
				Failures.Push(Vector["id"] . " typed [" . Typed . "] instead of [" . Vector["types"] . "]")
		} else {
			Shortcuts += 1
			Sent := KeylayoutEmulation_ShortcutChar(Vector["shortcut"])
			if (Sent !== Vector["sends"])
				Failures.Push(Vector["id"] . " sent [" . Sent . "] instead of [" . Vector["sends"] . "]")
		}
	}
	AssertEqual(2, Layouts.Count, "the vectors must cover both the ansi (Ergo-L) and the iso (Ergopti) conventions")
	Assert(Presses >= 25 && Shortcuts >= 4, "both vector kinds must be replayed")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("keylayout emulation: captured routes retain layout and modifiers after unload (todo49-captured-kle)",
	() => _KLT_WithEmulation(_KLT_CapturedReplayVectorsCase))

_KLT_CaptureReplayPress(Press) {
	Parts := StrSplit(Press, " ")
	Shift := false
	Caps := false
	Option := false
	Loop Parts.Length - 1 {
		switch Parts[A_Index] {
			case "shift": Shift := true
			case "caps": Caps := true
			case "altgr": Option := true
			default: throw ValueError("Unknown modifier in a captured keylayout vector.")
		}
	}
	return KeylayoutEmulation_CaptureReplayRoute(Parts[Parts.Length], Shift, Caps, Option)
}

_KLT_CapturedReplayVectorsCase() {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE
	Doc := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\keylayout_vectors.json", "UTF-8"))
	Captured := 0
	for Vector in Doc["vectors"] {
		if !Vector.Has("press")
			continue
		_KLT_Load(Vector["layout"])
		Recipes := []
		for Press in Vector["press"]
			Recipes.Push(_KLT_CaptureReplayPress(Press))
		KeylayoutEmulation_Unload()
		KLE_State := "unrelated-live-state"
		State := KEYLAYOUT_NEUTRAL_STATE
		Output := ""
		for Recipe in Recipes {
			AssertEqual(Vector["layout"], Recipe["layout_id"], "the event retains its accepted layout")
			Step := KeylayoutEmulation_StepReplayRoute(Recipe, State)
			State := Step["Next"]
			Output .= Step["Output"]
		}
		AssertEqual(Vector["types"], Output, Vector["id"] . " must replay the independent corpus after unload")
		AssertEqual("unrelated-live-state", KLE_State, "queued stepping cannot mutate the current live composition")
		Captured += 1
	}
	Assert(Captured >= 25, "captured replay must cover base, modifiers, digits and dead-key corpus vectors")
}

Test("keylayout emulation: captured route refuses unowned and malformed input (todo49-captured-kle)",
	() => _KLT_WithEmulation(_KLT_CapturedReplayRefusalCase))

_KLT_CapturedReplayRefusalCase() {
	_KLT_Load("ergol")
	AssertThrows(() => KeylayoutEmulation_CaptureReplayRoute("SC777", false, false, false),
		"an unregistered physical key cannot acquire a route")
	AssertThrows(() => KeylayoutEmulation_StepReplayRoute(Map(), "none"),
		"an incomplete recipe cannot run")
	Recipe := KeylayoutEmulation_CaptureReplayRoute("SC010", false, false, false)
	AssertThrows(() => KeylayoutEmulation_StepReplayRoute(Recipe, 0),
		"the replay stream must provide an explicit composition state")
	KeylayoutEmulation_Unload()
	AssertThrows(() => KeylayoutEmulation_CaptureReplayRoute("SC010", false, false, false),
		"an unloaded layout cannot admit new recipes")
	_KLT_Load("ergopti")
	AssertEqual("q", KeylayoutEmulation_StepReplayRoute(Recipe, "none")["Output"],
		"a live layout swap cannot replace the admitted Ergo-L source")
}

; The registry emulation and the Ergopti emulation read the same .keylayout
; through two readers (keylayout_emulation.ahk steps the model per key,
; keylayout_tables.ahk flattens it into tables). The golden file records what
; the Windows Ergopti emulation typed before either reader existed, so it is an
; expectation independent of both: the registry emulation of Ergopti must type
; it on every level, and compose it after both base dead keys, wherever the
; Windows emulation does not deliberately deviate from the file.
Test("keylayout emulation: emulating the Ergopti registry layout types what the Windows Ergopti emulation types (layout-registry-emulation)",
	() => _KLT_WithEmulation(_KLT_ErgoptiGoldenCase))

_KLT_ErgoptiGoldenCase() {
	global ERGOPTI_KEY_DEVIATIONS, ERGOPTI_DEAD_KEY_DEVIATIONS
	Golden := JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_emulation_golden.json", "UTF-8"))
	; Level -> [Shift, CapsLock, AltGr] as the registry emulation receives them.
	Levels := Map("base", [false, false, false], "shift", [true, false, false], "caps", [false, true, false],
		"altgr_number_row", [false, false, true], "altgr_number_row_shift", [true, false, true],
		"altgr_rows", [false, false, true], "altgr_rows_shift", [true, false, true])
	_KLT_Load("ergopti")
	Failures := []
	Keys := 0
	; Base-level key typing each character, for the dead-key replay below.
	KeyOf := Map()
	for Level, Flags in Levels {
		for Sc, Descriptor in Golden["levels"][Level] {
			if !Descriptor.Has("text")
				continue
			if ERGOPTI_KEY_DEVIATIONS.Has(Level) && ERGOPTI_KEY_DEVIATIONS[Level].Has(Sc)
				continue
			Keys += 1
			KeylayoutEmulation_ResetDeadKey()
			Typed := KeylayoutEmulation_Press(Sc, Flags[1], Flags[2], Flags[3])
			if (Typed !== Descriptor["text"])
				Failures.Push(Level . " " . Sc . " typed [" . Typed . "] instead of [" . Descriptor["text"] . "]")
			if (Level == "base" || Level == "shift") && !KeyOf.Has(Descriptor["text"])
				KeyOf[Descriptor["text"]] := [Sc, Flags[1]]
		}
	}
	Composed := 0
	for DeadSc, Name in Map("SC02B", "Circumflex", "SC01B", "Diaresis") {
		AssertEqual(Name, Golden["levels"]["base"][DeadSc]["dead"], DeadSc . " must be the " . Name . " dead key")
		Deviations := ERGOPTI_DEAD_KEY_DEVIATIONS.Get(Name, Map())
		for Input, Output in Golden["dead_keys"][Name] {
			if Deviations.Has(Input) || !KeyOf.Has(Input)
				continue
			Composed += 1
			KeylayoutEmulation_ResetDeadKey()
			Started := KeylayoutEmulation_Press(DeadSc, false, false, false)
			Key := KeyOf[Input]
			Typed := Started . KeylayoutEmulation_Press(Key[1], Key[2], false, false)
			if (Typed !== Output)
				Failures.Push(Name . " then " . Key[1] . " typed [" . Typed . "] instead of [" . Output . "]")
		}
	}
	KeylayoutEmulation_ResetDeadKey()
	Assert(Keys >= 150, "the golden levels must give at least 150 typed keys, got " . Keys)
	Assert(Composed >= 80, "the two base dead keys must compose at least 80 golden entries, got " . Composed)
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}





; =============================
; =============================
; ======= 3/ The reader =======
; =============================
; =============================

_KLT_Doc(Layouts, Modifiers, KeyMaps, Actions := "") {
	return '<?xml version="1.0" encoding="UTF-8"?><keyboard group="0" id="1" name="T">'
		. '<layouts>' . Layouts . '</layouts>'
		. '<modifierMap id="M" defaultIndex="0">' . Modifiers . '</modifierMap>'
		. '<keyMapSet id="S">' . KeyMaps . '</keyMapSet>'
		. '<actions>' . Actions . '</actions></keyboard>'
}

_KLT_Layouts() => '<layout first="0" last="0" mapSet="S" modifiers="M"/>'

_KLT_Modifiers(ShiftKeys := "anyShift caps?") {
	return '<keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect>'
		. '<keyMapSelect mapIndex="1"><modifier keys="' . ShiftKeys . '"/></keyMapSelect>'
}

_KLT_KeyMaps() {
	return '<keyMap index="0"><key code="0" output="a"/><key code="1" output="&#x41;&amp;"/>'
		. '<!-- <key code="2" output="z"/> --><key code="3" action="x"/>'
		. '<key code="4" output="&#x0010;"/></keyMap>'
		. '<keyMap index="1" baseMapSet="S" baseIndex="0"><key code="0" output="A"/></keyMap>'
}

Test("keylayout reader: modifier selection, entities, comments and base keyMaps (layout-registry-emulation)", () => (
	Model := Keylayout_Parse(_KLT_Doc(_KLT_Layouts(), _KLT_Modifiers(), _KLT_KeyMaps(),
		'<action id="x"><when state="none" output="x"/></action>')),
	AssertEqual(0, Keylayout_KeyMapIndex(Model, Map())),
	AssertEqual(1, Keylayout_KeyMapIndex(Model, Map("shift", true)), "anyShift selects keyMap 1"),
	AssertEqual(1, Keylayout_KeyMapIndex(Model, Map("shift", true, "caps", true)), "caps? is optional"),
	AssertEqual(0, Keylayout_KeyMapIndex(Model, Map("caps", true)), "caps alone falls back to the default index"),
	AssertEqual("a", Keylayout_Resolve(Model, 0, 0)["Text"]),
	AssertEqual("A&", Keylayout_Resolve(Model, 0, 1)["Text"], "character references are decoded"),
	AssertEqual("none", Keylayout_Resolve(Model, 0, 2)["Kind"], "a commented-out key does not exist"),
	AssertEqual("x", Keylayout_Resolve(Model, 0, 3)["Text"], "an action types its neutral-state output"),
	AssertEqual("none", Keylayout_Resolve(Model, 0, 4)["Kind"], "a control character types nothing"),
	AssertEqual("A", Keylayout_Resolve(Model, 1, 0)["Text"]),
	AssertEqual("A&", Keylayout_Resolve(Model, 1, 1)["Text"], "a key missing from keyMap 1 comes from its base keyMap")
))

Test("keylayout reader: malformed layouts are refused, not half-read (layout-registry-emulation)", () => (
	AssertThrows(() => Keylayout_Parse(_KLT_Doc('<layout first="1" last="1" mapSet="S" modifiers="M"/>',
		_KLT_Modifiers(), _KLT_KeyMaps())), "a layout without first=0 must be refused"),
	AssertThrows(() => Keylayout_Parse(_KLT_Doc(_KLT_Layouts(), _KLT_Modifiers("hyper"), _KLT_KeyMaps())),
		"an unknown modifier token must be refused"),
	AssertThrows(() => Keylayout_Parse(_KLT_Doc('<layout first="0" last="0" mapSet="Nope" modifiers="M"/>',
		_KLT_Modifiers(), _KLT_KeyMaps())), "an undefined keyMapSet must be refused"),
	AssertThrows(() => Keylayout_Resolve(Keylayout_Parse(_KLT_Doc(_KLT_Layouts(), _KLT_Modifiers(), _KLT_KeyMaps())), 0, 3),
		"a key using an undefined action must be refused"),
	AssertThrows(() => _KLT_WithEmulation(() => KeylayoutEmulation_Load("t",
		_KLT_Doc(_KLT_Layouts(), _KLT_Modifiers(), _KLT_KeyMaps()), "iso", LayoutRegistry_Keycodes())),
		"loading resolves every key, so a broken action fails at load time"),
	AssertThrows(() => KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), "jis"),
		"an unknown keycode convention must be refused")
))





; ==================================
; ==================================
; ======= 4/ Registry client =======
; ==================================
; ==================================

Test("layout registry: URL, ids and verification against the index (layout-registry-emulation)", () => (
	AssertEqual("https://raw.githubusercontent.com/adrienm7/ergopti/" . _Updater_InstalledChannel() . "/static/layouts/registry/index.json",
		LayoutRegistry_RawUrl("index.json"), "the URL combines shared registry defaults with the installed channel"),
	AssertTrue(LayoutRegistry_IsValidId("ergopti_plus_ansi")),
	AssertFalse(LayoutRegistry_IsValidId("..\evil"), "an id is a file name and must not escape the folder"),
	AssertFalse(LayoutRegistry_IsValidId("Ergol")),
	AssertFalse(LayoutRegistry_IsValidId("")),
	LayoutRegistry_Verify(_KLT_Entry("ergol"), _KLT_LayoutText("ergol")),
	AssertThrows(() => LayoutRegistry_Verify(_KLT_Entry("ergol"),
		_KLT_Tamper(_KLT_LayoutText("ergol"), 'output="q"', 'output="z"')),
		"a same-size edit must fail the checksum"),
	AssertThrows(() => LayoutRegistry_Verify(_KLT_Entry("ergol"), SubStr(_KLT_LayoutText("ergol"), 1, -1)),
		"a truncated file must fail the size check")
))

Test("curl: a request can write its body to a file, byte for byte (layout-registry-emulation)",
	_KLT_CurlOutputFileCase)

_KLT_CurlOutputFileCase() {
	Configs := []
	; Reads the curl config at the spawn boundary, then refuses to start a child.
	Capture := (Exe, Args, *) => (Configs.Push(FileRead(Args[3], "UTF-8")), 0)
	Target := A_Temp . "\ergopti_keylayout_output_" . A_TickCount . ".test"
	for OutputPath in [Target, ""] {
		Req := CurlAsyncRequest(Map("spawn", Capture))
		Req.Open("GET", "https://example.invalid/index.json", true)
		if (OutputPath != "")
			Req.SetOutputFile(OutputPath)
		AssertThrows(() => Req.Send(), "a child that did not start must be reported")
	}
	AssertEqual(2, Configs.Length, "both requests must reach the spawn boundary")
	AssertContains(Configs[1], "output = " . _HTTP_CurlConfigQuote(Target), "the body goes to the requested file")
	AssertContains(Configs[2], 'output = "-"', "without an output file the body stays on stdout")
	AssertThrows(() => CurlAsyncRequest().SetOutputFile(""), "an empty output path is refused")
}

Test("layout registry: a local copy is read only when it matches its record (layout-registry-emulation)",
	_KLT_ReadLocalCase)

_KLT_ReadLocalCase() {
	Dir := _KLT_TempDir()
	try {
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "nothing installed yet")
		_KLT_WriteRaw(Dir . "ergol.keylayout", _KLT_LayoutText("ergol"))
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "an unrecorded copy is not installed")
		LayoutCatalogue_WriteInstalled(Dir, Map("ergol", _KLT_Entry("ergol")))
		LocalCopy := LayoutRegistry_ReadLocal("ergol", Dir)
		AssertEqual("ergol", LocalCopy["Entry"]["id"])
		AssertEqual(_KLT_LayoutText("ergol"), LocalCopy["Text"])
		_KLT_WriteRaw(Dir . "ergol.keylayout", _KLT_Tamper(_KLT_LayoutText("ergol"), 'output="q"', 'output="z"'))
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "an edited local copy must be refused")
	} finally DirDelete(Dir, true)
}





; ===============================================
; ===============================================
; ======= 5/ Registration, gates and boot =======
; ===============================================
; ===============================================

Test("keylayout emulation: registration covers every key and leaves native chords alone (layout-registry-emulation)",
	_KLT_RegistrationCase)

Test("keylayout emulation: AltGr alone preserves native AZERTY base and Shift (layout-layer-selection)",
	() => _KLT_WithEmulation(_KLT_IndependentLayersCase))

_KLT_IndependentLayersCase() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone()]
	try {
		Desired := Map("emulated_layout", "ergol", "ergopti_base", false,
			"ergopti_alt_gr", true, "ergopti_variant", "ergopti", "direct_access_digits", "native")
		Features := Map("layout", Desired.Clone())
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		Desired := State["features"]["layout"]
		AssertTrue(Desired["ergopti_alt_gr"], "the source choice retains the requested AltGr layer")
		AssertFalse(Features["layout"]["ergopti_alt_gr"], "built-in Ergopti AltGr stands down for the registry source")
		_KLT_Load("ergol")
		KLE_Registered := false
		Capture := {Criterion: 0, Rows: Map()}
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, *) => Capture.Rows[Name] := Capture.Criterion,
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0, 0,
			(Scan, Callback, Criterion) => Capture.Rows["#" . Scan] := Criterion)
		for Name in ["SC010", "+SC010", "^SC010", "#SC010", "!SC010", "#SC010", "SC002", "+SC002"]
			AssertFalse(Capture.Rows[Name].Call(), Name . " must stay with the native Windows layout")
		Azerty := _APRL_Layout("0000040C")
		Assert(Azerty != 0, "the AZERTY preservation proof requires the installed French layout")
		AssertEqual("a", _APRL_Text(Azerty, 0x10, []), "the real Windows DLL keeps native base a")
		AssertEqual("A", _APRL_Text(Azerty, 0x10, [0x10]), "the real Windows DLL keeps native Shift+A")
		AssertEqual("&", _APRL_Text(Azerty, 0x02, []), "the disabled digit override keeps AZERTY symbols")
		AssertEqual("1", _APRL_Text(Azerty, 0x02, [0x10]), "native Shift keeps its digit")
		AssertTrue(KeylayoutEmulation_LayerIsActive("ergopti_alt_gr"), "AltGr has an independent switch")
		AssertEqual("^", KeylayoutEmulation_Press("SC010", false, false, true))
		AssertEqual(Chr(0x2081), KeylayoutEmulation_Press("SC002", false, false, true))
		AssertEqual(Chr(0xB9), KeylayoutEmulation_Press("SC002", true, false, true), "Shift+AltGr uses the selected layout")
		KeylayoutEmulation_Press("SC010", true, false, true)
		AssertTrue(Capture.Rows["SC010"].Call(), "a pending AltGr dead key owns only its native continuation")
		Step := KeylayoutEmulation_PressNative("SC010", false, false, Azerty)
		AssertEqual(Chr(0xE2), Step["Output"], "the accent composes native AZERTY a, not Ergo-L q")
		AssertFalse(Step["Native"], "a composed character consumes the physical continuation")
		AssertFalse(Capture.Rows["SC010"].Call(), "base immediately returns to Windows after composition")
		KeylayoutEmulation_Press("SC010", true, false, true)
		AssertEqual(Chr(0xC2), KeylayoutEmulation_PressNative("SC010", false, true, Azerty)["Output"],
			"native CapsLock is read without changing the user's state")
		KeylayoutEmulation_Press("SC010", true, false, true)
		AssertEqual(Chr(0xCA), KeylayoutEmulation_PressNative("SC012", true, false, Azerty)["Output"],
			"native Shift+E composes to uppercase E circumflex")
		KeylayoutEmulation_Press("SC010", true, false, true)
		Step := KeylayoutEmulation_PressNative("SC01A", false, false, Azerty)
		AssertTrue(Step["Native"], "an OS dead key is replayed to its native state machine")
		AssertEqual("^", Step["Output"], "the registry dead key terminates before a native dead key")
		AssertFalse(Capture.Rows["SC010"].Call(), "a native dead key never leaves registry state armed")
		Features["layout"]["direct_access_digits"] := "digits"
		KeylayoutEmulation_Press("SC010", true, false, true)
		; Ergo-L's digit1 action explicitly maps circumflex + 1 to superscript 1.
		AssertEqual(Chr(0xB9), KeylayoutEmulation_PressNative("SC002", false, false, Azerty)["Output"],
			"a dead-key continuation composes the direct digit, not the native ampersand")
		Features["layout"]["direct_access_digits"] := "native"
		Desired["ergopti_base"] := true
		AssertTrue(Capture.Rows["SC010"].Call(), "base can be enabled independently")
		AssertTrue(Capture.Rows["+SC010"].Call(), "the same base switch owns Shift")
		AssertTrue(Capture.Rows["^SC010"].Call(), "base owns shortcut letters")
		AssertEqual("q", KeylayoutEmulation_Press("SC010", false, false, false))
		Desired["ergopti_alt_gr"] := false
		AssertFalse(KeylayoutEmulation_LayerIsActive("ergopti_alt_gr"))
		AssertFalse(Capture.Rows["SC138 & SC010"].Call(), "disabled AltGr must not capture its key")
		Features["layout"]["direct_access_digits"] := "digits"
		AssertFalse(Capture.Rows["SC002"].Call(), "direct digits own their unshifted row")
		AssertTrue(Capture.Rows["SC010"].Call(), "direct digits do not disable letters")
		CategoryEnabled["Layout"] := false
		AssertFalse(Capture.Rows["SC010"].Call(), "the master still gates effective behavior")
		AssertTrue(Desired["ergopti_base"], "gating never mutates the user's choice")
		CategoryEnabled["Layout"] := true
		LayerEnabled := true
		AssertFalse(Capture.Rows["SC010"].Call(), "navigation owns its physical keys")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
	}
}

Test("magic key: the configured key wins over the layout's declaration and the OS layout (layout-magic-key)",
	_KLT_MagicKeySourceOrderCase)

; The resolution order of LayoutRegistry_MagicKeySource, with a detection that
; records whether it was consulted at all.
_KLT_MagicKeySourceOrderCase() {
	Probe := { Calls: 0, Answer: "SC024" }
	Shipped := { Calls: 0 }
	Resolve(Changes) {
		Inputs := Map("chosen", false, "configured", "auto", "declared", "", "emulated", false,
			"keycodes", LayoutRegistry_Keycodes(), "detect", () => (Probe.Calls += 1, Probe.Answer),
			"shipped", () => (Shipped.Calls += 1, "KeyC"))
		for Key, Value in Changes
			Inputs[Key] := Value
		return LayoutRegistry_MagicKeySource(Inputs)
	}
	; [hotstrings] magic_key_source names the key by its KeyboardEvent.code, the
	; spelling every driver shares: KeyN is SC031 on Windows.
	Chosen := Resolve(Map("chosen", true, "configured", "KeyN", "declared", "KeyC"))
	AssertEqual("SC031", Chosen["scan"], "the user's key wins over the layout's declaration")
	AssertEqual("user", Chosen["origin"])
	AssertFalse(Chosen["follows_os_layout"])
	AssertTrue(Chosen["overrides_emulation"], "a chosen key is the magic key on any layout")
	AssertEqual(0, Probe.Calls, "a configured key is never replaced by a detection")
	AssertEqual(0, Shipped.Calls, "nor read from the shipped layout")
	Declared := Resolve(Map("declared", "Semicolon", "emulated", true))
	AssertEqual("SC027", Declared["scan"], "the declared KeyboardEvent.code reaches its scan code")
	AssertEqual("layout", Declared["origin"])
	AssertTrue(Declared["overrides_emulation"], "the declaring layout yields its key to the magic key")
	AssertEqual(0, Probe.Calls)
	Emulated := Resolve(Map("emulated", true))
	AssertEqual("SC02E", Emulated["scan"], "an emulated layout without declaration keeps the shipped key")
	AssertEqual(1, Shipped.Calls, "the shipped key is read only when nothing else names one")
	AssertFalse(Emulated["follows_os_layout"], "and never follows the OS layout it replaces")
	AssertFalse(Emulated["overrides_emulation"], "a layout declaring no magic key keeps its own character")
	AssertEqual(0, Probe.Calls, "the OS layout an emulation replaces is never probed")
	Detected := Resolve(Map())
	AssertEqual("SC024", Detected["scan"], "the user's own layout is probed for the source character")
	AssertEqual("detected", Detected["origin"])
	AssertTrue(Detected["follows_os_layout"])
	Probe.Answer := ""
	Missing := Resolve(Map())
	AssertEqual("SC02E", Missing["scan"], "a character on no key keeps the shipped key")
	AssertTrue(Missing["follows_os_layout"], "another OS layout may still carry the character")
	AssertThrows(() => Resolve(Map("declared", "MouseLeft")), "a code no layout key has is refused")
	AssertEqual("KeyC", LayoutRegistry_ShippedMagicKey(),
		"the last-resort key is the one the shipped Ergopti layout declares: SC02E, the former default")
}

Test("magic key: the active layout's declaration comes from its extension (layout-magic-key)",
	_KLT_MagicKeyDeclarationCase)

_KLT_MagicKeyDeclarationCase() {
	Bundled := LayoutRegistry_BundledDir()
	AssertEqual("KeyC", LayoutRegistry_DeclaredMagicKey("ergopti", [], Bundled),
		"the shipped Ergopti extension declares the key its layout turns into the magic key")
	AssertEqual("Semicolon", LayoutRegistry_DeclaredMagicKey("ergopti", [{ id: "ergopti", magic_key: "Semicolon" }],
		Bundled), "an installed or user copy of the extension wins over the shipped one")
	AssertEqual("", LayoutRegistry_DeclaredMagicKey("ergol", [{ id: "ergol", magic_key: "" }], Bundled))
	AssertEqual("", LayoutRegistry_DeclaredMagicKey("", [], Bundled), "no active layout declares nothing")
	AssertThrows(() => LayoutRegistry_DeclaredMagicKey("missing_extension", [], Bundled),
		"an extension with no manifest is a broken install, not an undeclared key")
	Record := Map("ergol", Map("id", "ergol", "extension", Map("id", "ergol")))
	AssertEqual("ergol", LayoutRegistry_ActiveLayoutExtension("ergol", true, "ergopti", () => Record),
		"the emulated registry layout wins over the built-in Ergopti emulation")
	AssertEqual("", LayoutRegistry_ActiveLayoutExtension("bepo", true, "ergopti", () => Record),
		"a layout not installed yet declares nothing")
	AssertEqual("", LayoutRegistry_ActiveLayoutExtension("ergol", false, "ergopti", () => Record),
		"a layout left selected with the base layer off types nothing: the OS layout is probed")
	AssertEqual("ergopti", LayoutRegistry_ActiveLayoutExtension("", true, "ergopti", () => Record))
	AssertEqual("", LayoutRegistry_ActiveLayoutExtension("", false, "ergopti", () => Record),
		"the user's own OS layout declares nothing")
	Failing() {
		throw Error("damaged record")
	}
	AssertEqual("", LayoutRegistry_ActiveLayoutExtension("ergol", true, "ergopti", Failing),
		"a damaged record is logged and declares nothing")
}

Test("magic key: only a declared or chosen key takes an emulated layout's unshifted level (layout-magic-key)",
	() => _KLT_WithEmulation(_KLT_MagicKeyYieldCase))

; Evaluates the actual registered criterion with a modeled physical press.
; Host input is never injected; the physical-state port is restored on refusal.
; @param Criterion {Func} The #HotIf criterion the row was registered under.
; @param Pressed {Boolean} Whether the modeled AltGr key is physically held.
; @returns {Boolean} The criterion's answer while AltGr is held as AltGr.
_KLT_AltGrRowOnKanaFamily(Criterion, Pressed := true) {
	global TapHold, _ALTGR_PHYSICAL_STATE_QUERY
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true), Query: _ALTGR_PHYSICAL_STATE_QUERY }
	try {
		TapHold := Map("keys", Map(), "layers", Map())
		_ALTGR_PHYSICAL_STATE_QUERY := (Key) => Pressed
		return Criterion.Call()
	} finally {
		_ALTGR_PHYSICAL_STATE_QUERY := Saved.Query
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}

_KLT_MagicKeyYieldCase() {
	global Features, CategoryEnabled, LayerEnabled, KLE_Registered, ScriptInformation
	State := MasterGateState()
	Saved := [Features, CategoryEnabled, LayerEnabled, KLE_Registered, State.Clone(),
		ScriptInformation["MagicKeySourceScan"], ScriptInformation["MagicKeySourceOverridesEmulation"]]
	try {
		Replace := Map("enabled", true)
		Features := Map("layout", Map("emulated_layout", "ergol", "ergopti_base", true,
			"ergopti_alt_gr", true, "ergopti_variant", "ergopti", "direct_access_digits", "native"),
			"hotstrings", Map("magic_key", Map("replace", Replace)))
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => true)
		_KLT_Load("ergol")
		KLE_Registered := false
		Capture := { Criterion: 0, Rows: Map() }
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, *) => Capture.Rows[Name] := Capture.Criterion,
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0, 0,
			(Scan, Callback, Criterion) => Capture.Rows["#" . Scan] := Criterion)
		ScriptInformation["MagicKeySourceScan"] := "SC02E"
		ScriptInformation["MagicKeySourceOverridesEmulation"] := false
		AssertTrue(Capture.Rows["SC02E"].Call(), "Ergo-L declares no magic key: its '-' stays on that key")
		ScriptInformation["MagicKeySourceOverridesEmulation"] := true
		AssertFalse(Capture.Rows["SC02E"].Call(), "a declared or chosen key's unshifted level is the remap's")
		AssertTrue(Capture.Rows["+SC02E"].Call(), "Shift keeps the emulated layout's character")
		AssertTrue(_KLT_AltGrRowOnKanaFamily(Capture.Rows["SC138 & SC02E"]),
			"AltGr keeps the emulated layout's character")
		AssertFalse(_KLT_AltGrRowOnKanaFamily(Capture.Rows["SC138 & SC02E"], false),
			"released AltGr leaves the magic-key suffix to its current owner")
		AssertTrue(Capture.Rows["SC010"].Call(), "every other key stays with the emulation")
		ScriptInformation["MagicKeySourceScan"] := "SC027"
		AssertTrue(Capture.Rows["SC02E"].Call(), "the yield follows the chosen key, not a fixed position")
		AssertFalse(Capture.Rows["SC027"].Call())
		Replace["enabled"] := false
		AssertTrue(Capture.Rows["SC027"].Call(), "without the remap the emulation keeps the key")
		Replace["enabled"] := true
		KeylayoutEmulation_Press("SC010", true, false, true)
		AssertTrue(Capture.Rows["SC027"].Call(), "a pending dead key still owns its continuation")
	} finally {
		Features := Saved[1]
		CategoryEnabled := Saved[2]
		LayerEnabled := Saved[3]
		KLE_Registered := Saved[4]
		State.Clear()
		for Key, Value in Saved[5]
			State[Key] := Value
		ScriptInformation["MagicKeySourceScan"] := Saved[6]
		ScriptInformation["MagicKeySourceOverridesEmulation"] := Saved[7]
	}
}

_KLT_RegistrationCase() {
	global KLE_Registered, KLE_DEAD_RESET_KEYS
	Saved := KLE_Registered
	KLE_Registered := false
	Names := []
	HotIfCalls := []
	try {
		Table := LayoutRegistry_Keycodes()
		Keys := Table["keys"].Length
		Assert(Keys >= 48, "the shared keycode table must list the whole typing area")
		BrokerRows := []
		Count := KeylayoutEmulation_Register(Table, (Name, *) => Names.Push(Name),
			(Args*) => HotIfCalls.Push(Args.Length), 0,
			(Scan, Callback, Criterion) => (Names.Push("#" . Scan),
				BrokerRows.Push(Map("scan", Scan, "callback", Callback, "criterion", Criterion))))
		; plain + Shift per key, six chords per key but the space bar, one AltGr
		; combination per key, one passthrough per dead-key reset key.
		Expected := Keys * 2 + (Keys - 1) * 6 + Keys + KLE_DEAD_RESET_KEYS.Length
		AssertEqual(Expected, Count)
		AssertEqual(Expected, Names.Length)
		AssertEqual(Keys - 1, BrokerRows.Length, "every Win typing chord joins the physical broker exactly once")
		for Row in BrokerRows {
			AssertTrue(HasMethod(Row["callback"], "Call"), "the real layout callback is retained")
			AssertTrue(Row["criterion"] == _KLE_ShortcutCriterion, "the real native admission is retained")
		}
		Joined := " " . _KLT_Join(Names, " ") . " "
		for Name in ["SC010", "+SC010", "^SC010", "#SC010", "!+SC056", "#+SC029", "SC138 & SC010", "SC039", "+SC039",
			"SC138 & SC039", "~SC00E"]
			Assert(InStr(Joined, " " . Name . " "), Name . " must be registered")
		for Name in ["^SC039", "#SC039", "!SC039"]
			AssertEqual(0, InStr(Joined, " " . Name . " "), Name . " is a system shortcut and must stay native")
		AssertEqual(0, InStr(Joined, "^!"), "Ctrl+Alt is AltGr and must stay untouched")
		AssertEqual(0, HotIfCalls[HotIfCalls.Length], "the HotIf context must be reset after registration")
		AssertThrows(() => KeylayoutEmulation_Register(Table, (*) => 0, (*) => 0),
			"a second registration must be refused")
	} finally KLE_Registered := Saved
}

Test("master gates: a selected registry layout supersedes the Ergopti emulation (layout-registry-emulation)",
	_KLT_SupersedeCase)

_KLT_SupersedeCase() {
	global Features, TapHold
	Selected := Map("ergopti_base", true, "ergopti_alt_gr", true, "ergopti_variant", "ergopti_plus",
		"direct_access_digits", "digits", "ctrl_magic_save", true, "emulated_layout", "ergol")
	_KLT_WithLayoutFeatures(Selected, () => (
		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated),
		AssertFalse(Features["layout"]["ergopti_base"], "the Ergopti base layer stands down"),
		AssertFalse(Features["layout"]["ergopti_alt_gr"], "the Ergopti AltGr layer stands down"),
		AssertFalse(ErgoptiLayout_PlusIsActive(Features), "the Ergopti+ changes stand down"),
		AssertTrue(Features["layout"]["direct_access_digits"], "the independent digit override keeps its choice"),
		AssertEqual("digits", Features["layout"]["direct_access_digits"], "the typed intent remains digits rather than a truthy native/symbols string"),
		AssertTrue(Features["layout"]["ctrl_magic_save"], "a feature that works on any layout is kept"),
		AssertEqual("ergol", Features["layout"]["emulated_layout"], "the selection itself is kept")
	))
	NoneSelected := Map("ergopti_base", true, "ergopti_alt_gr", true, "ergopti_variant", "ergopti_plus",
		"direct_access_digits", "digits", "ctrl_magic_save", true, "emulated_layout", "")
	_KLT_WithLayoutFeatures(NoneSelected, () => (
		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated),
		AssertTrue(Features["layout"]["ergopti_base"], "without a registry layout the Ergopti emulation stays"),
		AssertTrue(Features["layout"]["direct_access_digits"]),
		AssertEqual("digits", Features["layout"]["direct_access_digits"])
	))
}

_KLT_BootLayout(Id) => Map("ergopti_base", false, "emulated_layout", Id)

_KLT_BootDeps(Log, ReadLocalFn, FetchFn) {
	return Map(
		"keycodes", LayoutRegistry_Keycodes,
		"register", (Table) => (Log.Push("register"), 1),
		"read_local", ReadLocalFn,
		"install", FetchFn
	)
}

_KLT_ReadRepoLocal(Id, LocalDir) => Map("Text", _KLT_LayoutText(Id), "Entry", _KLT_Entry(Id))

_KLT_ReadNothing(Id, LocalDir) {
	throw Error("The layout '" . Id . "' is not downloaded in " . LocalDir)
}

Test("keylayout emulation: boot registers first, then loads the local copy or downloads it (layout-registry-emulation)",
	() => _KLT_WithEmulation(_KLT_BootCase))

_KLT_BootCase() {
	global KLE_Model, KLE_Id
	Log := []
	NoFetch := (*) => Log.Push("fetch")
	KeylayoutEmulation_Unload()
	_KLT_WithLayoutFeatures(_KLT_BootLayout(""), () =>
		AssertFalse(KeylayoutEmulation_Boot("C:\cfg\", _KLT_BootDeps(Log, _KLT_ReadRepoLocal, NoFetch))))
	AssertEqual(0, Log.Length, "nothing selected: nothing registered, nothing downloaded")
	_KLT_WithLayoutFeatures(_KLT_BootLayout("..\evil"), () =>
		AssertFalse(KeylayoutEmulation_Boot("C:\cfg\", _KLT_BootDeps(Log, _KLT_ReadRepoLocal, NoFetch))))
	AssertEqual(0, Log.Length, "an invalid id registers nothing")

	_KLT_WithLayoutFeatures(_KLT_BootLayout("ergol"), () =>
		AssertTrue(KeylayoutEmulation_Boot("C:\cfg\", _KLT_BootDeps(Log, _KLT_ReadRepoLocal, NoFetch))))
	AssertEqual("register", _KLT_Join(Log), "a local copy is loaded without a download")
	AssertEqual("ergol", KLE_Id)

	; Missing locally: the hotkeys are still registered at boot, the layout
	; arrives when the download reports success.
	KeylayoutEmulation_Unload()
	Log := []
	; An object, not a captured local: the download callback flips it.
	Store := {Downloaded: false}
	ReadAfterDownload := (Id, LocalDir) => Store.Downloaded ? _KLT_ReadRepoLocal(Id, LocalDir) : _KLT_ReadNothing(Id, LocalDir)
	Fetch := (Id, LocalDir, OnDone, *) => (Log.Push("fetch " . Id . " into " . LocalDir),
		Store.Downloaded := true, OnDone.Call(true, _KLT_Entry(Id)))
	_KLT_WithLayoutFeatures(_KLT_BootLayout("ergol"), () =>
		AssertFalse(KeylayoutEmulation_Boot("C:\cfg\", _KLT_BootDeps(Log, ReadAfterDownload, Fetch)),
			"the layout is not emulated yet when boot returns"))
	AssertEqual("register; fetch ergol into C:\cfg\" . LayoutRegistry_Settings()["local_folder"] . "\", _KLT_Join(Log))
	AssertEqual("ergol", KLE_Id, "the downloaded layout is loaded once the download succeeds")

	; A failed download leaves the emulation inert.
	KeylayoutEmulation_Unload()
	Failing := (Id, LocalDir, OnDone, *) => OnDone.Call(false, "HTTP 404")
	_KLT_WithLayoutFeatures(_KLT_BootLayout("ergol"), () =>
		KeylayoutEmulation_Boot("C:\cfg\", _KLT_BootDeps([], _KLT_ReadNothing, Failing)))
	AssertFalse(IsObject(KLE_Model), "nothing is emulated after a failed download")
}

; Capture the actual registration boundary, including names built by concatenation.
; Resolve expectations independently from the shared physical-key registry.
_KLT_ResetKeyCase(Code) {
	global CategoryEnabled, LayerEnabled, KLE_Registered
	static Registry := JsonParse(FileRead(_SharedDir . "\data\keycodes\physical_keys.json", "UTF-8"))
	Record := Registry["keys"][Code]
	Saved := [CategoryEnabled, LayerEnabled, KLE_Registered]
	try {
		CategoryEnabled := Map("Layout", true)
		LayerEnabled := false
		KLE_Registered := false
		Capture := {Criterion: 0, Rows: Map()}
		KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
			(Name, Callback, Options) => Capture.Rows[Name] := Map("callback", Callback,
				"criterion", Capture.Criterion, "options", Options),
			(Args*) => Capture.Criterion := Args.Length ? Args[1] : 0, 0,
			(Scan, Callback, Criterion) => Capture.Rows["#" . Scan] := Criterion)
		Name := "~" . Record["ahk"]
		AssertTrue(Capture.Rows.Has(Name), Code . ": the computed reset must share its scan-code identity")
		AssertFalse(Capture.Rows.Has("~" . Record["ahk_send"]), Code . ": no shadowed name twin")
		Row := Capture.Rows[Name]
		Seeds := JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\keylayout_vectors.json", "UTF-8"))["dead_reset_seeds"]
		Assert(Seeds.Length >= 5, "all shipped dead-key seed cases must be replayed")
		for Seed in Seeds {
			_KLT_Load(Seed["layout"])
			Plain := KeylayoutEmulation_Press("SC020", false, false, false)
			AssertFalse(Row["criterion"].Call(), "a reset stays inert without a pending dead key")
			AssertEqual("", _KLT_Press(Seed["press"]),
				Seed["layout"] . " " . Seed["press"] . ": the seed starts a dead key")
			AssertTrue(Row["criterion"].Call(), Name . ": the registered reset owns a pending dead key")
			CategoryEnabled["Layout"] := false
			AssertFalse(Row["criterion"].Call(), "a disabled layout leaves navigation native")
			CategoryEnabled["Layout"] := true
			LayerEnabled := true
			AssertFalse(Row["criterion"].Call(), "an active navigation layer keeps its ownership")
			LayerEnabled := false
			Row["callback"].Call(Name)
			AssertFalse(Row["criterion"].Call(), "the actual registered callback cancels the pending accent")
			AssertEqual(Plain, KeylayoutEmulation_Press("SC020", false, false, false),
				Code . " on " . Seed["layout"] . ": the next letter must have no stale accent")
		}
	} finally {
		CategoryEnabled := Saved[1]
		LayerEnabled := Saved[2]
		KLE_Registered := Saved[3]
	}
}
for Code in ["Backspace", "Escape", "Enter", "Tab", "Delete", "ArrowLeft", "ArrowRight", "ArrowUp",
	"ArrowDown", "Home", "End", "PageUp", "PageDown"]
	Test("keylayout emulation: " . Code . " cancels pending accents by physical identity (keylayout-dead-reset-identity)",
		_KLT_WithEmulation.Bind(_KLT_ResetKeyCase.Bind(Code)))





; ====================================================
; ====================================================
; ======= 12/ Ergopti+ AltGr characterization =========
; ====================================================
; ====================================================

_KLT_PlusOutputMatrixCase() {
	Matrix := JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_plus_altgr_output_matrix.json", "UTF-8"))
	Golden := JsonParse(FileRead(_DriverDir . "\tests\fixtures\ergopti_emulation_golden.json", "UTF-8"))["levels"]
	AssertEqual(6, Matrix["rows"].Length, "all three legacy plus keys need both Shift states")
	_KLT_Load("ergopti_plus")
	Seen := Map()
	Observed := 0
	TextDifferences := 0
	for Row in Matrix["rows"] {
		Identity := Row["legacy_level"] . ":" . Row["scan"]
		AssertFalse(Seen.Has(Identity), "the independent matrix must not repeat a legacy entry")
		Seen[Identity] := true
		ExpectedLegacy := Golden[Row["legacy_level"]][Row["scan"]]
		AssertEqual(_EKT_Describe(ExpectedLegacy), _EKT_Describe(Row["descriptor"]),
			"the independent historical golden remains authoritative")
		for Caps in [false, true] {
			KeylayoutEmulation_ResetDeadKey()
			Actual := KeylayoutEmulation_Press(Row["scan"], Row["shift"], Caps, true)
			AssertEqual(Row["selected"], Actual,
				Identity . ": selected Ergopti+ types the independent neutral output with Caps " . Caps)
			Observed += 1
			if ExpectedLegacy.Has("text") {
				AssertFalse(Actual == ExpectedLegacy["text"],
					"the current selected text is not the legacy Shift deviation")
				TextDifferences += 1
			}
		}
	}
	for Level in ["altgr_plus", "altgr_plus_shift"] {
		AssertEqual(3, Golden[Level].Count, "the historical plus level has three keys")
		for Scan in Golden[Level]
			AssertTrue(Seen.Has(Level . ":" . Scan), "no legacy plus entry may be omitted")
	}
	AssertEqual(12, Observed, "each independent output runs with both Caps states")
	AssertEqual(4, TextDifferences, "both Shift deviations remain distinct with Caps off and on")
}
Test("Ergopti+ matrix: selected raw AltGr outputs retain the independently recorded legacy differences (todo96-output-matrix)",
	_KLT_WithEmulation.Bind(_KLT_PlusOutputMatrixCase))

; Captured KLE reset metadata: authored AHK behavior, UNRUN outside Windows.
; These callables cannot authenticate a captured physical event or consume FIFO.
_KLTR_WithObserver(Fn) {
	global KLE_Registered, _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering
	global _KLE_ResetObserverGeneration, _KLE_ResetObserverCapture, CategoryEnabled, LayerEnabled
	Saved := [KLE_Registered, _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering,
		_KLE_ResetObserverGeneration, CategoryEnabled, LayerEnabled, _KLE_ResetObserverCapture]
	try {
		KLE_Registered := false
		_KLE_ResetObserverCohort := 0, _KLE_ResetObserverRegistering := 0, _KLE_ResetObserverCapture := 0
		CategoryEnabled := Map("Layout", true), LayerEnabled := false
		_KLT_WithEmulation(_KLTR_RunObserver.Bind(Fn))
	} finally {
		KLE_Registered := Saved[1], _KLE_ResetObserverCohort := Saved[2]
		_KLE_ResetObserverRegistering := Saved[3], _KLE_ResetObserverGeneration := Saved[4]
		CategoryEnabled := Saved[5], LayerEnabled := Saved[6], _KLE_ResetObserverCapture := Saved[7]
	}
}

_KLTR_RunObserver(Fn) {
	global KLE_State
	_KLT_Load("ergol")
	KLE_State := "acute"
	Fn()
}

_KLTR_Port(Mode := "") {
	return {Mode: Mode, Rows: Map(), Criterion: 0, Injected: false,
		During: 0, Returns: 0, Cleanup: 0}
}

_KLTR_HotIf(Port, Args*) {
	if Args.Length
		Port.Criterion := Args[1]
	else {
		Port.Cleanup += 1
		if Port.Mode == "cleanup_throw"
			throw Error("Original reset registration cleanup failed.")
	}
}

_KLTR_Hotkey(Port, Name, Callback, Options) {
	global _KLE_ResetObserverRegistering
	Port.Rows[Name] := Map("callback", Callback, "criterion", Port.Criterion, "options", Options)
	if SubStr(Name, 1, 1) == "~" && !Port.Injected {
		Port.Injected := true
		Port.During := KeylayoutEmulation_CaptureResetObserver(SubStr(Name, 2))
		switch Port.Mode {
			case "hotkey_throw": throw Error("A physical reset binding may already be installed.")
			case "reentry":
				AssertThrows(KeylayoutEmulation_Register.Bind(LayoutRegistry_Keycodes(),
					(*) => 0, (*) => 0, 0, (*) => 0))
			case "lost_registering": _KLE_ResetObserverRegistering := Map("invalid", false)
		}
	}
	; Original registration accepts nonthrowing ports, not an invented ACK type.
	Port.Returns += 1
	return Port.Mode == "untyped_return" ? "no native ACK promised" : 0
}

_KLTR_Register(Port) {
	return KeylayoutEmulation_Register(LayoutRegistry_Keycodes(),
		_KLTR_Hotkey.Bind(Port), _KLTR_HotIf.Bind(Port), 0, (*) => 0)
}

_KLTR_Event(Sc, Origin := 1, Repeat := 0) {
	return Map("scan", Integer("0x" . SubStr(Sc, 3)), "origin", Origin,
		"key_up", 0, "repeat", Repeat)
}

_KLTR_Positive(Sc, Origin, Repeat) {
	global KLE_State, KEYLAYOUT_NEUTRAL_STATE, _KLE_ResetObserverCohort
	Port := _KLTR_Port()
	_KLTR_Register(Port)
	AssertEqual(0, Port.During, "Partial physical registration grants no captured recipe.")
	AssertEqual(13, _KLE_ResetObserverCohort["bindings"].Count)
	Actual := Port.Rows["~" . Sc]
	AssertTrue(Actual["callback"] == KeylayoutEmulation_ResetDeadKey)
	AssertTrue(Actual["criterion"] == _KLE_PendingDeadKeyCriterion)
	AssertEqual("I2", Actual["options"])
	Recipe := KeylayoutEmulation_CaptureResetObserver(Sc)
	AssertTrue(HasMethod(Recipe, "Call"), "The real successful registration supplies a retained callable.")
	for Pass in [1, 2] {
		Result := Recipe.Call(_KLTR_Event(Sc, Origin, Repeat), "acute")
		AssertEqual(KEYLAYOUT_NEUTRAL_STATE, Result["Next"])
		AssertEqual("", Result["Output"])
		AssertTrue(Result["metadata_only"])
		AssertFalse(Result["cohort_complete"])
		AssertFalse(Result["transformed_output_enabled"])
		AssertFalse(Result["native_consumed"])
		AssertEqual("acute", KLE_State, "Pure interpretation does not reset live composition or consume an edge.")
	}
	Actual["callback"].Call()
	AssertEqual(KEYLAYOUT_NEUTRAL_STATE, KLE_State, "The unchanged physical callback shares the neutral transition.")
}

_KLTR_Mutate(Source) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering, KLE_Model, KLE_Id, KLE_State
	global KLE_Registered, _KLE_ResetObserverCapture
	Row := _KLE_ResetObserverCohort["bindings"].Get("SC00E", 0)
	switch Source {
		case "cohort_removed": _KLE_ResetObserverCohort := 0
		case "cohort_replaced": _KLE_ResetObserverCohort := _KLE_ResetObserverCohort.Clone()
		case "generation": _KLE_ResetObserverCohort["generation"] += 1
		case "bindings_replaced": _KLE_ResetObserverCohort["bindings"] := _KLE_ResetObserverCohort["bindings"].Clone()
		case "factory_removed": _KLE_ResetObserverCapture := 0
		case "factory_call_override": _KLE_ResetObserverCapture.DefineProp("Call", {Call: (*) => 0})
		case "cohort_get_override": _KLE_ResetObserverCohort.DefineProp("Get", {Call: (*) => 0})
		case "bindings_get_override": _KLE_ResetObserverCohort["bindings"].DefineProp("Get", {Call: (*) => 0})
		case "binding_get_override": Row.DefineProp("Get", {Call: (*) => 0})
		case "binding_removed": _KLE_ResetObserverCohort["bindings"].Delete("SC00E")
		case "binding_replaced": _KLE_ResetObserverCohort["bindings"]["SC00E"] := Row.Clone()
		case "callback": Row["callback"] := (*) => 0
		case "criterion": Row["criterion"] := (*) => true
		case "options": Row["options"] := "I3"
		case "scan": Row["scan"] := "SC001"
		case "name": Row["name"] := "~SC001"
		case "model": KLE_Model := KLE_Model.Clone()
		case "layout": KLE_Id := "foreign-layout"
		case "state": KLE_State := "other-dead"
		case "unregistered": KLE_Registered := false
		case "registering": _KLE_ResetObserverRegistering := Map("invalid", false)
		default: throw ValueError("Unknown captured reset mutation.")
	}
}

_KLTR_Invoke(Recipe, Event, State) => Recipe.Call(Event, State)

_KLTR_SourceRefusal(Source) {
	Port := _KLTR_Port()
	_KLTR_Register(Port)
	Recipe := KeylayoutEmulation_CaptureResetObserver("SC00E")
	AssertTrue(HasMethod(Recipe, "Call"))
	_KLTR_Mutate(Source)
	AssertThrows(_KLTR_Invoke.Bind(Recipe, _KLTR_Event("SC00E"), "acute"),
		"A retained callable must reject changed registration or source identity.")
	Fresh := KeylayoutEmulation_CaptureResetObserver("SC00E")
	if Source == "model" || Source == "layout" || Source == "state"
		AssertTrue(HasMethod(Fresh, "Call"), "A fresh valid source can capture its own pure reset recipe.")
	else
		AssertEqual(0, Fresh)
}

_KLTR_BadEvent(Field, Value, Delete := false) {
	_KLTR_Register(_KLTR_Port())
	Recipe := KeylayoutEmulation_CaptureResetObserver("SC00E")
	Event := _KLTR_Event("SC00E")
	if Delete
		Event.Delete(Field)
	else
		Event[Field] := Value
	AssertThrows(_KLTR_Invoke.Bind(Recipe, Event, "acute"))
}

_KLTR_RegistrationRefusal(Mode) {
	global _KLE_ResetObserverCohort, _KLE_ResetObserverRegistering, KLE_Registered
	Port := _KLTR_Port(Mode)
	if Mode == "hotkey_throw" || Mode == "cleanup_throw" {
		AssertThrows(_KLTR_Register.Bind(Port))
		AssertFalse(KLE_Registered)
		AssertTrue(Port.Rows.Count > 0, "Already installed bindings are not falsely rolled back.")
	} else {
		Count := _KLTR_Register(Port)
		AssertEqual(Port.Rows.Count + LayoutRegistry_Keycodes()["keys"].Length - 1, Count,
			"Existing Win broker calls retain the original registration count.")
		AssertTrue(KLE_Registered)
	}
	AssertEqual(0, _KLE_ResetObserverRegistering)
	AssertEqual(0, _KLE_ResetObserverCohort)
	AssertEqual(0, KeylayoutEmulation_CaptureResetObserver("SC00E"))
}

class _KLTR_ObservedCategory extends Map {
	Has(Name) {
		if this.Armed {
			this.Armed := false
			_KLTR_Mutate(this.Mutation)
		}
		return super.Has(Name)
	}
}

_KLTR_CriterionWithdrawal(Source) {
	global CategoryEnabled
	_KLTR_Register(_KLTR_Port())
	Gate := _KLTR_ObservedCategory("Layout", true)
	Gate.Armed := true, Gate.Mutation := Source
	CategoryEnabled := Gate
	AssertEqual(0, KeylayoutEmulation_CaptureResetObserver("SC00E"),
		"The actual criterion's category read cannot publish a changed source.")
	AssertFalse(Gate.Armed, "The actual existing criterion must cross the observed category read.")
}

_KLTR_ReturnConvention() {
	_KLTR_Register(_KLTR_Port("untyped_return"))
	AssertTrue(HasMethod(KeylayoutEmulation_CaptureResetObserver("SC00E"), "Call"),
		"No synthetic native registration ACK is required.")
}

; Every original KLE test and assertion remains an exact byte prefix above.
for Scan in ["SC00E", "SC001", "SC01C", "SC00F", "SC153", "SC14B", "SC14D",
		"SC148", "SC150", "SC147", "SC14F", "SC149", "SC151"] {
	for Origin in [1, 2] {
		for Repeated in [0, 1] {
			Test("KLE captured reset: " . Scan . "/" . Origin . "/" . Repeated . " (kle-reset-observer)",
				_KLTR_WithObserver.Bind(_KLTR_Positive.Bind(Scan, Origin, Repeated)))
		}
	}
}
for Mutation in ["cohort_removed", "cohort_replaced", "generation", "binding_removed",
		"binding_replaced", "bindings_replaced", "factory_removed", "factory_call_override",
		"cohort_get_override", "bindings_get_override", "binding_get_override", "callback", "criterion", "options", "scan", "name", "model",
		"layout", "state", "unregistered", "registering"] {
	Test("KLE captured reset: refuses " . Mutation . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_SourceRefusal.Bind(Mutation)))
}
for Vector in [["scan", 1], ["origin", 0], ["origin", 3], ["key_up", 1],
		["repeat", 2], ["repeat", -1], ["origin", "1"], ["scan", 0, true]] {
	Test("KLE captured reset: malformed " . Vector[1] . "/" . Vector[2] . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_BadEvent.Bind(Vector[1], Vector[2], Vector.Length == 3)))
}
for Mode in ["hotkey_throw", "cleanup_throw", "reentry", "lost_registering"] {
	Test("KLE captured reset: unavailable after " . Mode . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_RegistrationRefusal.Bind(Mode)))
}
for Mutation in ["cohort_replaced", "binding_replaced", "model", "layout", "state"] {
	Test("KLE captured reset: actual criterion withdraws " . Mutation . " (kle-reset-observer)",
		_KLTR_WithObserver.Bind(_KLTR_CriterionWithdrawal.Bind(Mutation)))
}
Test("KLE captured reset: original registration return convention (kle-reset-observer)",
	_KLTR_WithObserver.Bind(_KLTR_ReturnConvention))


; Genuine binding issuance is received separately on an idle Windows desktop.
; These controlled registrations must never manufacture that native authority.
_KAB_UnissuedSource() {
	global KLE_Registered
	AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())
	for ProbeSource in [0, Map("complete", true), {}, ((*) => 0).Bind()]
		for ProbeScan in ["SC010", "SC002", "", 0, {}]
			AssertEqual(0, KeylayoutEmulation_CaptureAltGrBinding(ProbeSource, ProbeScan),
				"caller descriptions cannot issue original native binding custody")
	ProbeSaved := KLE_Registered
	try {
		KLE_Registered := true
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "a public completion flag grants no source")
	} finally KLE_Registered := ProbeSaved
}

_KAB_NoPublicIssuer() {
	AssertFalse(IsSet(_KLE_RegisterBindings), "the effectful original body has no alternate public entry")
	for ProbeRequest in ["issue", "ready", "reset", "complete", {}, 0]
		AssertThrows(_KLE_AltGrBindingOwner.Bind(ProbeRequest))
	AssertThrows(_KLE_AltGrBindingOwner.Bind("initialize"), "initialization has exactly one owner")
	AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())
}

_KAB_FreshRegistryRead() {
	global _LayoutRegistryKeycodes
	ProbeSaved := _LayoutRegistryKeycodes
	try {
		ProbeOriginal := _LayoutRegistryReadKeycodes()
		AssertTrue(ProbeOriginal["keys"].Length > 1, "the real physical-key inventory must be nonempty")
		_LayoutRegistryKeycodes := ProbeOriginal.Clone()
		_LayoutRegistryKeycodes["keys"] := [ProbeOriginal["keys"][1]]
		AssertEqual(1, LayoutRegistry_Keycodes()["keys"].Length,
			"the legacy public cache still retains its original ordinary behavior")
		ProbeFresh := _LayoutRegistryReadKeycodes()
		AssertEqual(ProbeOriginal["keys"].Length, ProbeFresh["keys"].Length,
			"native preflight reads the real file rather than trusting a replaced cache")
		for ProbeIndex, ProbeKey in ProbeOriginal["keys"]
			AssertEqual(ProbeKey["ahk"], ProbeFresh["keys"][ProbeIndex]["ahk"])
	} finally _LayoutRegistryKeycodes := ProbeSaved
}

_KAB_InjectedRegistration() {
	global KLE_Registered, KLE_DEAD_RESET_KEYS, _KLE_ResetObserverRegistering
	global _KLE_ResetObserverCohort, _KLE_ResetObserverCapture, _KLE_ResetObserverGeneration
	ProbeSaved := [KLE_Registered, _KLE_ResetObserverRegistering, _KLE_ResetObserverCohort,
		_KLE_ResetObserverCapture, _KLE_ResetObserverGeneration]
	try {
		KLE_Registered := false
		_KLE_ResetObserverRegistering := 0
		ProbeRows := [], ProbeContexts := []
		ProbeTable := LayoutRegistry_Keycodes()
		ProbeCount := KeylayoutEmulation_Register(ProbeTable,
			(ProbeName, *) => (ProbeRows.Push(ProbeName), AssertEqual(0, KeylayoutEmulation_AltGrBindingSource())),
			(ProbeArgs*) => ProbeContexts.Push(ProbeArgs.Length), 0,
			(ProbeScan, *) => ProbeRows.Push("#" . ProbeScan))
		ProbeExpected := ProbeTable["keys"].Length * 3 + (ProbeTable["keys"].Length - 1) * 6 + KLE_DEAD_RESET_KEYS.Length
		AssertEqual(ProbeExpected, ProbeCount)
		AssertEqual(ProbeExpected, ProbeRows.Length)
		AssertEqual(0, ProbeContexts[ProbeContexts.Length], "the original process-wide criterion is released")
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "injected ports grant no native source")
		AssertThrows(KeylayoutEmulation_Register.Bind(ProbeTable, (*) => 0, (*) => 0),
			"the original duplicate-registration refusal remains effective")
		KLE_Registered := false
		KeylayoutEmulation_Register(ProbeTable, (*) => 0, (*) => 0, 0, (*) => 0)
		AssertEqual(0, KeylayoutEmulation_AltGrBindingSource(), "restoring public state cannot revive issuance")
	} finally {
		KLE_Registered := ProbeSaved[1], _KLE_ResetObserverRegistering := ProbeSaved[2]
		_KLE_ResetObserverCohort := ProbeSaved[3], _KLE_ResetObserverCapture := ProbeSaved[4]
		_KLE_ResetObserverGeneration := ProbeSaved[5]
	}
}

Test("kle-altgr-binding-source: unissued factories grant no binding custody", _KAB_UnissuedSource)
Test("kle-altgr-binding-source: no public initialization or issuance bypass", _KAB_NoPublicIssuer)
Test("kle-altgr-binding-source: canonical inventory ignores the public registry cache", _KAB_FreshRegistryRead)
Test("kle-altgr-binding-source: controlled registration preserves legacy behavior without native issuance", _KAB_InjectedRegistration)

/** Actual original-loader source receiving. No native registration or output. */
_KSO_Load() {
	AssertEqual(49, _KLT_Load("ergol"), "the original registry loader owns49 physical keys")
	Lease := KeylayoutEmulation_CaptureCanonicalSource()
	AssertTrue(Lease["current"].Call(), "the genuine source is current")
	AssertEqual(392, Lease["read"].Call("info")["transitions"], "the complete base family includes dead transitions")
	return Lease
}

_KSO_Reject(Fn, Expected) {
	try Fn.Call()
	catch as Failure {
		AssertContains(Failure.Message, Expected, "the refusal reaches its exact cause")
		return
	}
	throw Error("The private source operation unexpectedly succeeded: " . Expected)
}

_KSO_Scans() {
	global KLE_KeyCodes
	Result := Map()
	for Scan, Code in KLE_KeyCodes {
		if Code == 31
			Result["dead"] := Scan
		if Code == 0
			Result["a"] := Scan
	}
	AssertEqual(2, Result.Count, "literal Ergol anchors have actual canonical physical keys")
	return Result
}

_KSO_Lifetime() {
	global KLE_Model, KLE_State
	A := _KSO_Load(), Keys := _KSO_Scans()
	Again := KeylayoutEmulation_CaptureCanonicalSource()
	AssertEqual(A["epoch"], Again["epoch"], "recapture preserves the exact source epoch")
	Starter := A["read"].Call("find", "none", Keys["dead"], 0)
	Bridge := A["read"].Call("find", "1dk", Keys["dead"], 0)
	Final := A["read"].Call("find", "diaeresis", Keys["a"], 0)
	States := A["read"].Call("states"), RecapturedStates := Again["read"].Call("states")
	AssertEqual(4, States.Length, "the actual Ergol base family has four reachable states")
	AssertEqual(States.Length, RecapturedStates.Length, "recapture preserves the complete state table")
	for Index, State in States
		AssertEqual(State, RecapturedStates[Index], "recapture preserves each exact state identity")
	for Row in [Starter, Bridge, Final] {
		Recaptured := Again["read"].Call("find", Row["before"], Row["scan"], Row["shift"])
		AssertEqual(Row["before_id"], Recaptured["before_id"], "recapture preserves the literal transition's before ID")
		AssertEqual(Row["after_id"], Recaptured["after_id"], "recapture preserves the literal transition's after ID")
	}
	AssertEqual(0, Starter["before_id"], "neutral has the exact zero ID")
	AssertEqual("1dk", States[Starter["after_id"] + 1], "starter ID names the actual1dk state")
	AssertEqual(Starter["after_id"], Bridge["before_id"], "the retained starter and bridge share one exact state ID")
	AssertEqual(Bridge["after_id"], Final["before_id"], "the retained bridge and final share one exact state ID")
	AssertEqual(0, Final["after_id"], "completion names the same exact neutral ID")
	AssertEqual("", Starter["output"], "the starter owns an empty canonical transition")
	AssertEqual("1dk", Starter["after"], "the starter selects literal1dk")
	AssertEqual("diaeresis", Bridge["after"], "the second original key selects literal diaeresis")
	AssertEqual(Chr(0xE4), Final["output"], "the final canonical text is literal a-diaeresis")
	AssertEqual("none", Final["after"], "completion returns to literal neutral")
	Copied := A["read"].Call("find", "diaeresis", Keys["a"], 0)
	Copied["output"] := "foreign"
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "a detached row cannot mutate the retained graph")
	ModelA := KLE_Model
	AssertEqual(49, _KLT_Load("ergopti_plus"), "a genuine successor loads normally")
	B := KeylayoutEmulation_CaptureCanonicalSource()
	AssertFalse(A["current"].Call(), "the old lease cannot admit successor input")
	AssertTrue(B["current"].Call(), "the successor owns its new source")
	AssertTrue(B["epoch"] > A["epoch"], "successful replacement advances exact source identity")
	AssertFalse(KLE_Model == ModelA, "the successor has its own parsed model")
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "historical rows do not borrow the successor")
	AssertEqual("none", KLE_State, "historical reads leave live composition untouched")
	KeylayoutEmulation_Unload()
	AssertFalse(B["current"].Call(), "Unload withdraws live admission")
	AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "Unload preserves independently retained historical data")
	Inactive := KeylayoutEmulation_CaptureCanonicalSource()
	AssertFalse(Inactive["active"], "the original owner reports inactive data explicitly")
	AssertTrue(Inactive["current"].Call(), "the inactive receipt matches the genuine owner")
}

_KSO_InvalidLoad() {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex
	A := _KSO_Load(), Before := [KLE_Model, KLE_KeyCodes, KLE_LevelIndex]
	Entry := _KLT_Entry("ergol")
	_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Entry["keycode_convention"], LayoutRegistry_Keycodes()), "keylayout")
	AssertTrue(A["current"].Call(), "failed preparation preserves the original current source")
	AssertTrue(KLE_Model == Before[1] && KLE_KeyCodes == Before[2] && KLE_LevelIndex == Before[3], "failed preparation changes no public source roots")
	AssertEqual(A["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"], "failed preparation does not advance the source epoch")
}

_KSO_ExplicitReplacement() {
	global KLE_Model, KLE_Id, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions, KLE_State
	A := _KSO_Load()
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	_KLT_Load("ergopti_plus")
	KLE_Model := Saved[1], KLE_Id := Saved[2], KLE_State := Saved[3]
	KLE_KeyCodes := Saved[4], KLE_LevelIndex := Saved[5], KLE_Compositions := Saved[6]
	_KSO_Reject(KeylayoutEmulation_CaptureCanonicalSource, "changed during capture")
	Fresh := _KSO_Load()
	AssertTrue(Fresh["current"].Call(), "explicit genuine Load reparses after a legacy fixture restoration")
	AssertTrue(Fresh["epoch"] > A["epoch"], "replacement issues a new identity instead of adopting restored globals")
}

_KSO_InputObserver() {
	global KLE_Id
	A := _KSO_Load(), OldId := KLE_Id
	Table := LayoutRegistry_Keycodes().Clone(), Facts := {Calls: 0, ReentryRefused: 0}
	Table.DefineProp("__Item", {Get: Observe})
	Entry := _KLT_Entry("ergol")
	try {
		_KSO_Reject(() => KeylayoutEmulation_Load("ergol", _KLT_LayoutText("ergol"), Entry["keycode_convention"], Table), "starting canonical source changed")
		AssertTrue(Facts.Calls >= 2, "the real keycode constructor reached the supplied input observer")
		AssertEqual(1, Facts.ReentryRefused, "Busy refuses the actual recursive owner operation")
		AssertEqual("foreign-during-preparation", KLE_Id, "publication does not overwrite intervening public state")
	} finally {
		Table.DeleteProp("__Item")
		KLE_Id := OldId
	}
	AssertTrue(_KSO_Load()["current"].Call(), "genuine replacement remains available after refused preparation")

	Observe(Self, Key) {
		Facts.Calls += 1
		if Facts.Calls == 1 {
			_KSO_Reject(() => KeylayoutEmulation_Unload(), "unavailable")
			Facts.ReentryRefused += 1
			KLE_Id := "foreign-during-preparation"
		}
		return Map.Prototype.Get.Call(Self, Key)
	}
}

_KSO_BusyPreparationFailure() {
	A := _KSO_Load(), Table := LayoutRegistry_Keycodes().Clone(), Facts := {Calls: 0, ObservedBusy: 0}
	Table.DefineProp("__Item", {Get: Observe})
	Entry := _KLT_Entry("ergol")
	try {
		_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Entry["keycode_convention"], Table), "keylayout")
		AssertTrue(Facts.Calls >= 2, "actual keycode acquisition precedes the malformed parser input")
		AssertEqual(1, Facts.ObservedBusy, "the retained lease observes transient preparation exactly once")
	} finally Table.DeleteProp("__Item")
	AssertTrue(A["current"].Call(), "a transient Busy refusal does not revoke a source after failed preparation")
	AssertEqual(A["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"], "failed preparation retains its old source identity")

	Observe(Self, Key) {
		Facts.Calls += 1
		if Facts.Calls == 1 {
			AssertFalse(A["current"].Call(), "Busy blocks fresh admission during actual preparation")
			_KSO_Reject(KeylayoutEmulation_CaptureCanonicalSource, "unavailable")
			Facts.ObservedBusy += 1
		}
		return Map.Prototype.Get.Call(Self, Key)
	}
}

_KSO_HelperWithdrawal(Name) {
	A := _KSO_Load(), Keys := _KSO_Scans(), Facts := {Calls: 0}
	Helper := Name == "load" ? KeylayoutEmulation_Load : Name == "step" ? Keylayout_Step : _KLE_BuildReplayGraph
	Helper.DefineProp("Call", {Call: Observe})
	try {
		AssertFalse(A["current"].Call(), "helper withdrawal refuses new source admission")
		AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "historical data needs neither withdrawn loader nor parser")
		AssertEqual(0, Facts.Calls, "the source guard never invokes a withdrawn own.Call")
	} finally Helper.DeleteProp("Call")
	AssertFalse(A["current"].Call(), "observed withdrawal cannot reactivate the same lease after restoration")
	AssertTrue(_KSO_Load()["current"].Call(), "explicit reparse can issue a fresh source after helper restoration")

	Observe(*) {
		Facts.Calls += 1
		throw Error("A withdrawn helper callback must not run")
	}
}

_KSO_DuplicateInitialize() {
	A := _KSO_Load()
	_KSO_Reject(() => _KLE_CanonicalSourceOwner("initialize"), "cannot initialize twice")
	AssertTrue(A["current"].Call(), "duplicate initialization cannot replace the original source")
}

_KSO_Mutation(Kind) {
	global KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE
	global KEYLAYOUT_MODIFIER_TOKENS, KEYLAYOUT_MAX_BASE_DEPTH, _KEYLAYOUT_TAG_RE
	A := _KSO_Load(), Keys := _KSO_Scans()
	Before := [KLE_Model, KLE_KeyCodes, KLE_LevelIndex, KEYLAYOUT_NEUTRAL_STATE,
		KEYLAYOUT_MODIFIER_TOKENS, KEYLAYOUT_MAX_BASE_DEPTH, _KEYLAYOUT_TAG_RE]
	Restore := 0
	try {
		switch Kind {
			case "nested-action":
				for _, Action in KLE_Model["Actions"] {
					for _, Step in Action {
						Target := Step, Prior := Step["Output"]
						break
					}
					break
				}
				Restore := () => Target["Output"] := Prior
				Target["Output"] := "mutated"
			case "model-clone": KLE_Model := KLE_Model.Clone()
			case "keys-clone": KLE_KeyCodes := KLE_KeyCodes.Clone()
			case "keycode":
				Scan := Keys["a"], Prior := KLE_KeyCodes[Scan]
				Restore := () => KLE_KeyCodes[Scan] := Prior
				KLE_KeyCodes[Scan] := Prior + 1
			case "levels-scalar":
				Prior := KLE_LevelIndex[""], Restore := () => KLE_LevelIndex[""] := Prior
				KLE_LevelIndex[""] := Prior + 1
			case "array-hole":
				Target := KLE_Model["Selects"], Prior := Target[1]
				Restore := () => Target[1] := Prior
				Target.Delete(1)
			case "own-property":
				KLE_Model.DefineProp("foreign", {Value: 1})
				Restore := () => KLE_Model.DeleteProp("foreign")
			case "neutral":
				KEYLAYOUT_NEUTRAL_STATE := "withdrawn-neutral"
				Actual := Keylayout_Step(KLE_Model, "diaeresis", KLE_LevelIndex[""], KLE_KeyCodes[Keys["a"]])
				AssertEqual("withdrawn-neutral", Actual["Next"], "the actual live Step observes the changed declaration")
			case "vocabulary-token":
				Prior := KEYLAYOUT_MODIFIER_TOKENS["shift"]
				Restore := () => KEYLAYOUT_MODIFIER_TOKENS["shift"] := Prior
				KEYLAYOUT_MODIFIER_TOKENS["shift"] := "option"
			case "vocabulary-map": KEYLAYOUT_MODIFIER_TOKENS := KEYLAYOUT_MODIFIER_TOKENS.Clone()
			case "vocabulary-regex": _KEYLAYOUT_TAG_RE .= " "
			case "base-depth": KEYLAYOUT_MAX_BASE_DEPTH += 1
			default: throw Error("Unknown exact source mutation")
		}
		AssertFalse(A["current"].Call(), "actual mutation withdraws original source admission")
		AssertEqual("none", A["read"].Call("find", "diaeresis", Keys["a"], 0)["after"], "the historical graph retains its literal neutral identity")
		AssertEqual(Chr(0xE4), A["read"].Call("find", "diaeresis", Keys["a"], 0)["output"], "the historical graph retains its literal output")
	} finally {
		if IsObject(Restore)
			Restore.Call()
		KLE_Model := Before[1], KLE_KeyCodes := Before[2], KLE_LevelIndex := Before[3]
		KEYLAYOUT_NEUTRAL_STATE := Before[4], KEYLAYOUT_MODIFIER_TOKENS := Before[5]
		KEYLAYOUT_MAX_BASE_DEPTH := Before[6], _KEYLAYOUT_TAG_RE := Before[7]
	}
	AssertFalse(A["current"].Call(), "restoration cannot revive an observed withdrawn lease")
	AssertTrue(_KSO_Load()["current"].Call(), "fresh original loading recovers through parsing")
}

_KSO_Image(Kind) {
	Child := Map("value", Kind == "map-value-type" ? "1" : "one")
	ArrayData := [1, "two"], Empty := Map()
	Root := Map("child", Child, "shared", Child, "array", ArrayData, "empty", Empty)
	if Kind == "map-value-type"
		AssertEqual("String", Type(Child["value"]), "the equal-valued map control begins with a String")
	if Kind == "array-value-type"
		AssertEqual("Integer", Type(ArrayData[1]), "the equal-valued array control begins with an Integer")
	Current := _KLE_CaptureCanonicalImage([Root])
	AssertTrue(Current.Call(), "the original typed shared source image is current")
	switch Kind {
		case "map-value-type": Child["value"] := 1
		case "map-policy":
			AssertEqual("On", Empty.CaseSense, "the actual empty Map starts case-sensitive")
			Empty.CaseSense := "Off"
		case "nested-container": Root["child"] := Child.Clone()
		case "array-hole": ArrayData.Delete(1)
		case "own-property": Child.DefineProp("foreign", {Value: 1})
		case "key-insert": Child["other"] := "two"
		case "scalar-case": Child["value"] := "ONE"
		case "array-value-type": ArrayData[1] := "1"
		case "shared-subtree": Root["shared"] := Child.Clone()
		default: throw Error("Unknown exact image mutation")
	}
	if Kind == "map-value-type"
		AssertEqual("Integer", Type(Child["value"]), "only the equal-valued map scalar type changes")
	if Kind == "array-value-type"
		AssertEqual("String", Type(ArrayData[1]), "only the equal-valued array scalar type changes")
	AssertFalse(Current.Call(), "the exact typed data image detects the independent mutation")
}

Test("canonical-source-owner: lifetime", () => _KLT_WithEmulation(_KSO_Lifetime))
Test("canonical-source-owner: invalid-load-atomic", () => _KLT_WithEmulation(_KSO_InvalidLoad))
Test("canonical-source-owner: explicit-replacement", () => _KLT_WithEmulation(_KSO_ExplicitReplacement))
Test("canonical-source-owner: input-observer-reentry", () => _KLT_WithEmulation(_KSO_InputObserver))
Test("canonical-source-owner: busy-preparation-failure", () => _KLT_WithEmulation(_KSO_BusyPreparationFailure))
Test("canonical-source-owner: duplicate-initialize", () => _KLT_WithEmulation(_KSO_DuplicateInitialize))
Test("canonical-source-owner: helper-load", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("load")))
Test("canonical-source-owner: helper-step", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("step")))
Test("canonical-source-owner: helper-graph", () => _KLT_WithEmulation(_KSO_HelperWithdrawal.Bind("graph")))
Test("canonical-source-owner: source-nested-action", () => _KLT_WithEmulation(_KSO_Mutation.Bind("nested-action")))
Test("canonical-source-owner: source-model-clone", () => _KLT_WithEmulation(_KSO_Mutation.Bind("model-clone")))
Test("canonical-source-owner: source-keys-clone", () => _KLT_WithEmulation(_KSO_Mutation.Bind("keys-clone")))
Test("canonical-source-owner: source-keycode", () => _KLT_WithEmulation(_KSO_Mutation.Bind("keycode")))
Test("canonical-source-owner: source-levels-scalar", () => _KLT_WithEmulation(_KSO_Mutation.Bind("levels-scalar")))
Test("canonical-source-owner: source-array-hole", () => _KLT_WithEmulation(_KSO_Mutation.Bind("array-hole")))
Test("canonical-source-owner: source-own-property", () => _KLT_WithEmulation(_KSO_Mutation.Bind("own-property")))
Test("canonical-source-owner: source-neutral", () => _KLT_WithEmulation(_KSO_Mutation.Bind("neutral")))
Test("canonical-source-owner: source-vocabulary-token", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-token")))
Test("canonical-source-owner: source-vocabulary-map", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-map")))
Test("canonical-source-owner: source-vocabulary-regex", () => _KLT_WithEmulation(_KSO_Mutation.Bind("vocabulary-regex")))
Test("canonical-source-owner: source-base-depth", () => _KLT_WithEmulation(_KSO_Mutation.Bind("base-depth")))
Test("canonical-source-owner: image-map-value-type", () => _KLT_WithEmulation(_KSO_Image.Bind("map-value-type")))
Test("canonical-source-owner: image-map-policy", () => _KLT_WithEmulation(_KSO_Image.Bind("map-policy")))
Test("canonical-source-owner: image-nested-container", () => _KLT_WithEmulation(_KSO_Image.Bind("nested-container")))
Test("canonical-source-owner: image-array-hole", () => _KLT_WithEmulation(_KSO_Image.Bind("array-hole")))
Test("canonical-source-owner: image-own-property", () => _KLT_WithEmulation(_KSO_Image.Bind("own-property")))
Test("canonical-source-owner: image-key-insert", () => _KLT_WithEmulation(_KSO_Image.Bind("key-insert")))
Test("canonical-source-owner: image-scalar-case", () => _KLT_WithEmulation(_KSO_Image.Bind("scalar-case")))
Test("canonical-source-owner: image-array-value-type", () => _KLT_WithEmulation(_KSO_Image.Bind("array-value-type")))
Test("canonical-source-owner: image-shared-subtree", () => _KLT_WithEmulation(_KSO_Image.Bind("shared-subtree")))

/** Requires an exact detached copy of every original graph field. */
_KRG_SameRecord(Left, Right) {
	AssertEqual(Left.Count, Right.Count, "a detached graph record retains its field inventory")
	for Name, Value in Left {
		AssertTrue(Right.Has(Name), "a detached graph record retains every field")
		AssertTrue(Type(Value) == Type(Right[Name]) && Value == Right[Name],
			"a detached graph field retains its exact type and value")
	}
}

/** Receives all four fixed graph families against independently walked parser states. */
_KRG_Receive(Id, BaseCount) {
	Entry := _KLT_Entry(Id)
	Model := Keylayout_Parse(_KLT_LayoutText(Id))
	Keys := KeylayoutEmulation_KeyCodes(LayoutRegistry_Keycodes(), Entry["keycode_convention"])
	AssertEqual(49, Keys.Count, "the graph receives the complete canonical physical inventory")
	for Caps in [0, 1] {
		for Option in [0, 1] {
			Levels := []
			for Shift in [0, 1] {
				Pressed := Map()
				if Shift
					Pressed["shift"] := true
				if Caps
					Pressed["caps"] := true
				if Option
					Pressed["option"] := true
				Levels.Push(Keylayout_KeyMapIndex(Model, Pressed))
			}
			ExpectedLevels := Levels.Clone(), SuppliedKeys := Keys.Clone()
			OracleStates := Map()
			OracleStates.CaseSense := "On"
			OracleStates["none"] := true
			Loop {
				Added := false
				for Before in OracleStates.Clone() {
					for Shift in [0, 1] {
						for Scan, Code in Keys {
							Step := Keylayout_Step(Model, Before, ExpectedLevels[Shift + 1], Code)
							if !OracleStates.Has(Step["Next"]) {
								OracleStates[Step["Next"]] := true
								Added := true
							}
						}
					}
				}
				if !Added
					break
			}
			Graph := _KLE_BuildReplayGraph(Model, SuppliedKeys, Levels, Id, Caps, Option)
			AssertTrue(Graph is BoundFunc, "the actual graph retains its private data through a closure")
			Info := Graph.Call("info"), States := Graph.Call("states")
			AssertEqual(49, Info["physical_keys"], "the graph omits no physical key")
			AssertEqual(States.Length * 98, Info["transitions"], "each state retains both complete levels")
			AssertEqual(OracleStates.Count, States.Length, "an independent reachability walk finds the same state inventory")
			AssertTrue(Info["caps"] == Caps && Info["option"] == Option,
				"the fixed family does not claim event-time modifier ownership")
			AssertTrue(Info["layout_name"] == Id && Info["model_key"] == ObjPtr(Model),
				"the graph retains its original source identity")
			AssertTrue(Graph.Call("matches_model", Model), "the graph recognizes its own model")
			AssertFalse(Graph.Call("matches_model", Map()), "a foreign model grants no graph identity")
			if !Caps && !Option
				AssertEqual(BaseCount, Info["transitions"], "the shipped base family matches its measured full size")
			for Before in States
				AssertTrue(OracleStates.Has(Before), "every retained state is canonically reachable")
			Seen := Map()
			Seen.CaseSense := "On"
			Loop Info["transitions"] {
				Row := Graph.Call("row", A_Index)
				Expected := Keylayout_Step(Model, Row["before"], ExpectedLevels[Row["shift"] + 1], Keys[Row["scan"]])
				AssertTrue(Row["index"] == ExpectedLevels[Row["shift"] + 1] && Row["keycode"] == Keys[Row["scan"]],
					"each row retains its exact physical and canonical level identity")
				AssertTrue(Row["output"] == Expected["Output"] && Row["after"] == Expected["Next"],
					"each row agrees with the independent parser step")
				AssertTrue(Row["before"] == States[Row["before_id"] + 1] && Row["after"] == States[Row["after_id"] + 1],
					"state IDs name the exact retained state strings")
				Selector := Row["before"] . "|" . Row["scan"] . "|" . Row["shift"]
				AssertFalse(Seen.Has(Selector), "the graph cannot repeat a selector")
				Seen[Selector] := true
				Found := Graph.Call("find", Row["before"], Row["scan"], Row["shift"])
				_KRG_SameRecord(Row, Found)
				Kind := Row["before_id"] || Row["after_id"] ? 3
					: Expected["Output"] == "" ? 0 : RegExMatch(Expected["Output"], "^[0-9]$") ? 2 : 1
				AssertEqual(Kind, Row["kind"], "empty composition and nonprinting neutral rows keep their exact data kind")
				Saved := Row.Clone()
				for Name in Row
					Row[Name] := "foreign row mutation"
				Found["output"] := "foreign find mutation"
				_KRG_SameRecord(Saved, Graph.Call("row", A_Index))
				_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
			}
			AssertEqual(Info["transitions"], Seen.Count, "every row has one unique selector")
			Saved := Graph.Call("row", 1), SavedInfo := Info.Clone()
			Info["transitions"] := 0, Info["layout_name"] := "foreign info"
			_KRG_SameRecord(SavedInfo, Graph.Call("info"))
			Levels[1] := -99, SuppliedKeys.Clear(), States.Push("foreign-state")
			AssertEqual(SavedInfo["states"], Graph.Call("states").Length,
				"a detached state array cannot extend the graph")
			_KRG_SameRecord(Saved, Graph.Call("row", 1))
			_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
		}
	}
	Saved := Graph.Call("row", 1)
	Model.Clear()
	_KRG_SameRecord(Saved, Graph.Call("row", 1))
	_KRG_SameRecord(Saved, Graph.Call("find", Saved["before"], Saved["scan"], Saved["shift"]))
}

/** Exercises the actual ambiguous-string selector and undefined-level predecessors. */
_KRG_Malformed(Mode) {
	Xml := '<keyboard><layouts><layout first="0" last="0" modifiers="mods" mapSet="maps"/></layouts>'
		. '<modifierMap id="mods" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="maps"><keyMap index="0"><key code="0" action="dead"/></keyMap></keyMapSet>'
		. '<actions><action id="dead"><when state="none" next="x|y"/><when state="x|y" output="a"/></action></actions></keyboard>'
	Model := Keylayout_Parse(Xml), Keys := Map("SC002", 0)
	if Mode == "levels" {
		_KSO_Reject(() => _KLE_BuildReplayGraph(Model, Keys, [1, 1], "missing-level", 0, 0),
			"canonical graph level identity is invalid")
		return
	}
	AssertEqual("selectors", Mode, "the test control selection must be exact")
	Graph := _KLE_BuildReplayGraph(Model, Keys, [0, 0], "separator-control", 0, 0)
	Row := Graph.Call("find", "x|y", "SC002", 0)
	AssertTrue(Row["before"] == "x|y" && Row["output"] == "a", "a legitimate separator state remains readable")
	_KSO_Reject(() => Graph.Call("find", "x", "y|SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "NONE", "SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC003", 0), "does not own that transition")
	_KSO_Reject(() => Graph.Call("row", 0), "row identity is invalid")
	_KSO_Reject(() => Graph.Call("info", 1), "info takes no arguments")
	_KSO_Reject(() => Graph.Call("foreign-operation"), "Unknown canonical graph operation")
}

for _KrgCase in [["ergol", 392], ["ergopti", 294], ["ergopti_ansi", 294],
	["ergopti_plus", 196], ["ergopti_plus_ansi", 196]]
	Test("canonical-replay-graph: complete fixed families for " . _KrgCase[1], _KRG_Receive.Bind(_KrgCase*))
for _KrgMode in ["selectors", "levels"]
	Test("canonical-replay-graph: exact " . _KrgMode . " refusal", _KRG_Malformed.Bind(_KrgMode))

/** Rejected public activation cannot discard the original admitted source. */
_KSO_PublicActivationFailure() {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	Lease := _KSO_Load()
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	Keycodes := LayoutRegistry_Keycodes(), Convention := _KLT_Entry("ergol")["keycode_convention"]
	_KSO_Reject(() => KeylayoutEmulation_Load("broken", "<keyboard>", Convention, Keycodes), "keylayout")
	AssertTrue(Lease["current"].Call(), "actual failed parser preparation retains the original direct loader source")
	LocalCopy := Map("Text", "<keyboard>", "Entry", Map("keycode_convention", Convention, "version", "invalid-fixture"))
	AssertFalse(_KLE_Activate("broken", LocalCopy, Keycodes), "the actual public activation wrapper reports failure")
	AssertTrue(KLE_Model == Saved[1] && KLE_Id == Saved[2] && KLE_State == Saved[3]
		&& KLE_KeyCodes == Saved[4] && KLE_LevelIndex == Saved[5] && KLE_Compositions == Saved[6],
		"public activation failure preserves every original source root")
	AssertTrue(Lease["current"].Call(), "the original source remains genuinely admitted after wrapper failure")
	AssertEqual(Lease["epoch"], KeylayoutEmulation_CaptureCanonicalSource()["epoch"],
		"the rejected public activation cannot issue a replacement or an unload epoch")
}
Test("canonical-source-owner: failed public activation preserves the original source",
	() => _KLT_WithEmulation(_KSO_PublicActivationFailure))

/** Historical copies cannot borrow a replacement container method or constructor. */
_KSO_IntrinsicWithdrawal(Mode) {
	Lease := _KSO_Load(), Keys := _KSO_Scans(), Facts := {Calls: 0}
	OriginalInfo := Lease["read"].Call("info")
	OriginalStateCount := Lease["read"].Call("states").Length
	IsArray := InStr(Mode, "array-") == 1
	IsConstructor := Mode == "map-constructor"
	IsOwnCall := InStr(Mode, "own-call") > 0
	AssertTrue(IsConstructor || Mode == "map-clone-value" || Mode == "array-clone-value"
		|| Mode == "map-clone-own-call" || Mode == "array-clone-own-call", "the intrinsic withdrawal selection is exact")
	Target := IsConstructor ? Map : IsArray ? Array.Prototype : Map.Prototype
	Property := IsConstructor ? "Call" : "Clone"
	Original := IsConstructor ? Map.Call : IsArray ? Array.Prototype.Clone : Map.Prototype.Clone
	HadOwn := Object.Prototype.HasOwnProp.Call(Target, Property)
	Descriptor := HadOwn ? Target.GetOwnPropDesc(Property) : 0
	Installed := false
	try {
		if IsOwnCall {
			AssertFalse(Object.Prototype.HasOwnProp.Call(Original, "Call"), "the original intrinsic starts without an own.Call observer")
			Original.DefineProp("Call", {Call: Observe})
		} else
			Target.DefineProp(Property, {Value: Observe})
		Installed := true
		_TestPrint("# canonical-source-intrinsic phase=installed kind=" . Mode)
		Info := Lease["read"].Call("info"), States := Lease["read"].Call("states")
		Row := Lease["read"].Call("find", "diaeresis", Keys["a"], 0)
		_TestPrint("# canonical-source-intrinsic phase=read kind=" . Mode
			. " info_type=" . Type(Info) . " states_type=" . Type(States) . " row_type=" . Type(Row) . " calls=" . Facts.Calls)
		AssertTrue(Info is Map && States is Array && Row is Map,
			"historical reads retain their actual native container types")
		AssertEqual(Chr(0xE4), Row["output"], "the historical row retains its literal canonical output")
		AssertEqual("ergol", Info["layout_name"], "the historical information retains its original layout identity")
		AssertEqual(OriginalStateCount, States.Length, "the historical state inventory remains complete")
		Row["output"] := "foreign row", Info["layout_name"] := "foreign information", States.Push("foreign state")
		AssertEqual(Chr(0xE4), Lease["read"].Call("find", "diaeresis", Keys["a"], 0)["output"],
			"a historical copy cannot expose the private row through a withdrawn clone")
		AssertEqual("ergol", Lease["read"].Call("info")["layout_name"],
			"a historical copy cannot expose private information through a withdrawn constructor")
		AssertEqual(OriginalStateCount, Lease["read"].Call("states").Length,
			"a historical copy cannot expose the private state array through a withdrawn clone")
		AssertEqual(0, Facts.Calls, "historical reads never invoke the replaced method or its own.Call observer")
		AssertFalse(Lease["current"].Call(), "intrinsic withdrawal refuses new original-source admission")
	} finally {
		if Installed {
			if IsOwnCall
				Original.DeleteProp("Call")
			else if HadOwn
				Target.DefineProp(Property, Descriptor)
			else
				Target.DeleteProp(Property)
		}
	}
	AssertFalse(Lease["current"].Call(), "restoring an observed withdrawn intrinsic cannot resurrect the old source")
	AssertTrue(_KSO_Load()["current"].Call(), "genuine reparsing can issue a fresh source after intrinsic restoration")

	Observe(Values*) {
		Facts.Calls += 1
		for Value in Values
			if Value is Map || Value is Array
				return Value
		return 0
	}
}
for _KsoIntrinsic in ["map-clone-value", "array-clone-value", "map-clone-own-call", "array-clone-own-call", "map-constructor"]
	Test("canonical-source-owner: historical copies retain original " . _KsoIntrinsic,
		_KLT_WithEmulation.Bind(_KSO_IntrinsicWithdrawal.Bind(_KsoIntrinsic)))

/** Supplied keycode observers cannot lend a self-restoring parser constructor. */
_KSO_InputParserSubstitution() {
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions
	Lease := _KSO_Load(), OriginalParser := Keylayout_Parse
	OriginalCall := Func.Prototype.Call
	AssertFalse(Object.Prototype.HasOwnProp.Call(OriginalParser, "Call"), "the parser starts without a supplied observer")
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex, KLE_Compositions]
	Table := LayoutRegistry_Keycodes().Clone(), Entry := _KLT_Entry("ergol")
	Facts := {ObserverCalls: 0, ParserCalls: 0}, Failure := 0
	Table.DefineProp("__Item", {Get: Observe})
	try {
		try KeylayoutEmulation_Load("ergol", _KLT_LayoutText("ergol"), Entry["keycode_convention"], Table)
		catch as Err
			Failure := Err
		ForeignAdmitted := KLE_Model is Map && KLE_Model.Has("foreign_parser_origin")
		_TestPrint("# canonical-source-input-dispatch observer_calls=" . Facts.ObserverCalls
			. " parser_calls=" . Facts.ParserCalls . " foreign_admitted=" . (ForeignAdmitted ? 1 : 0))
		AssertTrue(Facts.ObserverCalls >= 2, "the actual keycode reader reaches the supplied observer")
		AssertEqual(0, Facts.ParserCalls, "the source owner never dispatches a parser supplied by an input observer")
		AssertTrue(Failure is Error && Failure.Message == "The original canonical source constructor was withdrawn.",
			"observed constructor withdrawal refuses before parsing or publication")
		AssertTrue(KLE_Model == Saved[1] && KLE_Id == Saved[2] && KLE_State == Saved[3]
			&& KLE_KeyCodes == Saved[4] && KLE_LevelIndex == Saved[5] && KLE_Compositions == Saved[6],
			"the rejected input boundary preserves every original source root")
	} finally {
		if Object.Prototype.HasOwnProp.Call(OriginalParser, "Call")
			OriginalParser.DeleteProp("Call")
		Table.DeleteProp("__Item")
	}
	AssertFalse(Lease["current"].Call(), "observed constructor withdrawal cannot resurrect its old source")
	Fresh := _KSO_Load()
	AssertTrue(Fresh["current"].Call(), "actual reparsing remains available after input observer restoration")
	AssertEqual(Lease["epoch"] + 1, Fresh["epoch"], "rejected preparation issues no intermediate source epoch")

	Observe(Self, Key) {
		Facts.ObserverCalls += 1
		OriginalParser.DefineProp("Call", {Call: ForeignParser})
		return Map.Prototype.Get.Call(Self, Key)
	}

	ForeignParser(Receiver, Text) {
		Facts.ParserCalls += 1
		OriginalParser.DeleteProp("Call")
		Foreign := OriginalCall.Call(OriginalParser, Text)
		Foreign["foreign_parser_origin"] := "supplied observer"
		return Foreign
	}
}
Test("canonical-source-owner: supplied input cannot lend a self-restoring parser",
	() => _KLT_WithEmulation(_KSO_InputParserSubstitution))

/** A literal chain whose middle states cannot occur in any fixed family. */
_KNG_Fixture() {
	Xml := '<keyboard><layouts><layout first="0" last="0" modifiers="mods" mapSet="maps"/></layouts>'
		. '<modifierMap id="mods" defaultIndex="0"><keyMapSelect mapIndex="0"><modifier keys=""/></keyMapSelect></modifierMap>'
		. '<keyMapSet id="maps">'
		. '<keyMap index="0"><key code="18" action="start"/><key code="19" output="n"/></keyMap>'
		. '<keyMap index="1"><key code="18" output="a"/><key code="19" output="b"/></keyMap>'
		. '<keyMap index="2"><key code="18" output="c"/><key code="19" action="bridge"/></keyMap>'
		. '<keyMap index="3"><key code="18" output="d"/><key code="19" output="e"/></keyMap>'
		. '<keyMap index="4"><key code="18" action="cap_bridge"/><key code="19" output="f"/></keyMap>'
		. '<keyMap index="5"><key code="18" output="g"/><key code="19" output="h"/></keyMap>'
		. '<keyMap index="6"><key code="18" output="i"/><key code="19" output="j"/></keyMap>'
		. '<keyMap index="7"><key code="18" output="k"/><key code="19" action="finish"/></keyMap>'
		. '</keyMapSet><actions>'
		. '<action id="start"><when state="none" next="A"/></action>'
		. '<action id="bridge"><when state="none" output="y"/><when state="A" next="B"/></action>'
		. '<action id="cap_bridge"><when state="none" output="x"/><when state="B" next="C"/></action>'
		. '<action id="finish"><when state="none" output="z"/><when state="C" output="Z"/></action>'
		. '</actions></keyboard>'
	return [Keylayout_Parse(Xml), Map("SC002", 18, "SC003", 19),
		Map("", 0, "s", 1, "o", 2, "so", 3, "c", 4, "sc", 5, "co", 6, "sco", 7)]
}

/** Receives mixed reachability from literal expected states and output. */
_KNG_MixedChain() {
	Fixture := _KNG_Fixture(), Model := Fixture[1], Keys := Fixture[2], Levels := Fixture[3]
	FixedStates := Map()
	for Caps in [0, 1] {
		for Option in [0, 1] {
			Fixed := _KLE_BuildReplayGraph(Model, Keys,
				[Levels[_KLE_ComboKey(0, Caps, Option)], Levels[_KLE_ComboKey(1, Caps, Option)]],
				"mixed-chain", Caps, Option)
			for State in Fixed.Call("states")
				FixedStates[State] := true
		}
	}
	AssertFalse(FixedStates.Has("B") || FixedStates.Has("C"),
		"even the union of fixed-family closures misses the mixed-only states")
	Graph := _KLE_BuildNormalReplayGraph(Model, Keys, Levels, "mixed-chain")
	Info := Graph.Call("info"), States := Graph.Call("states")
	AssertEqual(8, Info["selectors"], "the normal graph retains every modifier selector")
	AssertEqual(4, Info["states"], "the literal chain reaches exactly none, A, B and C")
	AssertEqual(64, Info["transitions"], "four states own two keys across all eight selectors")
	AssertFalse(Info.Has("caps") || Info.Has("option"), "normal information does not claim a fixed family")
	Starter := Graph.Call("find", "none", "SC002", 0, 0, 0)
	Bridge := Graph.Call("find", "A", "SC003", 0, 0, 1)
	CapsBridge := Graph.Call("find", "B", "SC002", 0, 1, 0)
	Final := Graph.Call("find", "C", "SC003", 1, 1, 1)
	for Row in [Starter, Bridge, CapsBridge]
		AssertEqual("", Row["output"], "each literal prefix is an empty composition transition")
	AssertTrue(Starter["after"] == "A" && Bridge["after"] == "B" && CapsBridge["after"] == "C",
		"modifier changes retain the literal mixed-only composition states")
	AssertTrue(Starter["before_id"] == 0 && Starter["after_id"] == Bridge["before_id"]
		&& Bridge["after_id"] == CapsBridge["before_id"] && CapsBridge["after_id"] == Final["before_id"],
		"one exact state namespace joins all four modifier families")
	AssertTrue(Final["output"] == "Z" && Final["after"] == "none" && Final["after_id"] == 0,
		"the final selector emits literal capital Z and returns to the same neutral ID")
	Seen := Map()
	Loop Info["transitions"] {
		Row := Graph.Call("row", A_Index)
		Selector := Row["before"] . "|" . Row["scan"] . "|" . Row["shift"] . "|" . Row["caps"] . "|" . Row["option"]
		AssertFalse(Seen.Has(Selector), "every normal transition selector occurs exactly once")
		Seen[Selector] := true
		AssertEqual(Levels[_KLE_ComboKey(Row["shift"], Row["caps"], Row["option"])], Row["index"],
			"each row carries its exact literal keyMap selector")
		AssertTrue(Row["before"] == States[Row["before_id"] + 1]
			&& Row["after"] == States[Row["after_id"] + 1], "all rows use the same state IDs")
		_KRG_SameRecord(Row, Graph.Call("find", Row["before"], Row["scan"], Row["shift"], Row["caps"], Row["option"]))
	}
	AssertEqual(64, Seen.Count, "the complete mixed graph omits no selector")
	Saved := Final.Clone(), SavedInfo := Info.Clone()
	Final["output"] := "foreign", Info["selectors"] := 0, States.Push("foreign")
	Model.Clear(), Keys.Clear(), Levels.Clear()
	_KRG_SameRecord(Saved, Graph.Call("find", "C", "SC003", 1, 1, 1))
	_KRG_SameRecord(SavedInfo, Graph.Call("info"))
	AssertEqual(4, Graph.Call("states").Length, "detached arrays cannot alter historical states")
}

/** Joins the shipped Option and base families through the original source. */
_KNG_OriginalSource() {
	global KLE_State
	_KLT_Load("ergol")
	Lease := KeylayoutEmulation_CaptureCanonicalSource()
	AssertTrue(Lease.Has("normal_read"), "the genuine source retains a coherent normal graph reader")
	Read := Lease["normal_read"], Info := Read.Call("info")
	AssertEqual(8, Info["selectors"], "all eight source selectors were prepared before publication")
	AssertEqual(Info["states"] * 49 * 8, Info["transitions"], "the original source has complete normal rows")
	Starter := Read.Call("find", "none", "SC010", 1, 0, 1)
	Final := Read.Call("find", "circumflex", "SC002", 0, 0, 0)
	AssertTrue(Starter["index"] == 4 && Starter["keycode"] == 12 && Starter["output"] == ""
		&& Starter["after"] == "circumflex", "the shipped Option-Shift key starts literal circumflex")
	AssertTrue(Final["index"] == 0 && Final["keycode"] == 18 && Final["output"] == Chr(0xB9)
		&& Final["after"] == "none", "the shipped base key completes literal superscript one")
	AssertEqual(Starter["after_id"], Final["before_id"], "the source shares one state ID across families")
	AssertEqual(0, Final["after_id"], "the mixed completion retains exact neutral identity")
	Saved := Final.Clone(), Final["output"] := "foreign"
	KLE_State := "retained-live-state"
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	AssertEqual("retained-live-state", KLE_State, "graph reads leave live composition untouched")
	_KLT_Load("ergopti_plus")
	AssertFalse(Lease["current"].Call(), "source replacement withdraws old live admission")
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	KeylayoutEmulation_Unload()
	_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
	Inactive := KeylayoutEmulation_CaptureCanonicalSource()
	_KSO_Reject(() => Inactive["normal_read"].Call("info"), "no admitted graph reader")
}

/** Typed refusals must reach their selector checks. */
_KNG_InvalidSelector() {
	Fixture := _KNG_Fixture()
	Graph := _KLE_BuildNormalReplayGraph(Fixture[1], Fixture[2], Fixture[3], "selector-control")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, 0, 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", "0", 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, "0", 0), "lookup modifier is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC002", 0, 0, 2), "lookup modifier is invalid")
	_KSO_Reject(() => Graph.Call("find", "NONE", "SC002", 0, 0, 0), "lookup identity is invalid")
	_KSO_Reject(() => Graph.Call("find", "none", "SC004", 0, 0, 0), "does not own that transition")
	Fixture[3].Delete("sco")
	_KSO_Reject(() => _KLE_BuildNormalReplayGraph(Fixture[1], Fixture[2], Fixture[3], "missing-selector"),
		"selector table is incomplete")
}

/** New graph constructors share source withdrawal without revoking historical rows. */
_KNG_WithdrawHelper(Helper) {
	_KLT_Load("ergol")
	Lease := KeylayoutEmulation_CaptureCanonicalSource(), Read := Lease["normal_read"]
	Saved := Read.Call("find", "circumflex", "SC002", 0, 0, 0), Facts := {Calls: 0}
	Helper.DefineProp("Call", {Call: Observe})
	try {
		AssertFalse(Lease["current"].Call(), "graph constructor withdrawal refuses live source admission")
		_KRG_SameRecord(Saved, Read.Call("find", "circumflex", "SC002", 0, 0, 0))
		AssertEqual(0, Facts.Calls, "historical rows invoke neither replaced constructor")
	} finally Helper.DeleteProp("Call")
	AssertFalse(Lease["current"].Call(), "restoration cannot reactivate a withdrawn source lease")
	AssertTrue(_KSO_Load()["current"].Call(), "a genuine reparse issues a fresh source after restoration")

	Observe(*) {
		Facts.Calls += 1
		throw Error("A withdrawn normal graph constructor must not run.")
	}
}

Test("canonical-normal-graph: mixed-only states share one modifier namespace", _KNG_MixedChain)
Test("canonical-normal-graph: original source retains mixed-family historical rows",
	() => _KLT_WithEmulation(_KNG_OriginalSource))
Test("canonical-normal-graph: exact selector arity and types", _KNG_InvalidSelector)
Test("canonical-normal-graph: normal constructor withdrawal preserves historical data",
	() => _KLT_WithEmulation(_KNG_WithdrawHelper.Bind(_KLE_BuildNormalReplayGraph)))
Test("canonical-normal-graph: shared constructor withdrawal preserves historical data",
	() => _KLT_WithEmulation(_KNG_WithdrawHelper.Bind(_KLE_BuildReplayGraphOwned)))
