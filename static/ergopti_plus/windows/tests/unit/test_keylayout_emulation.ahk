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
	Capture := (Exe, Args, *) => (Configs.Push(FileRead(Args[2], "UTF-8")), 0)
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
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "native")
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
			"ergopti_alt_gr", true, "ergopti_plus", false, "direct_access_digits", "native"),
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
	Selected := Map("ergopti_base", true, "ergopti_alt_gr", true, "ergopti_plus", true,
		"direct_access_digits", "digits", "ctrl_magic_save", true, "emulated_layout", "ergol")
	_KLT_WithLayoutFeatures(Selected, () => (
		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated),
		AssertFalse(Features["layout"]["ergopti_base"], "the Ergopti base layer stands down"),
		AssertFalse(Features["layout"]["ergopti_alt_gr"], "the Ergopti AltGr layer stands down"),
		AssertFalse(Features["layout"]["ergopti_plus"], "the Ergopti+ changes stand down"),
		AssertTrue(Features["layout"]["direct_access_digits"], "the independent digit override keeps its choice"),
		AssertEqual("digits", Features["layout"]["direct_access_digits"], "the typed intent remains digits rather than a truthy native/symbols string"),
		AssertTrue(Features["layout"]["ctrl_magic_save"], "a feature that works on any layout is kept"),
		AssertEqual("ergol", Features["layout"]["emulated_layout"], "the selection itself is kept")
	))
	NoneSelected := Map("ergopti_base", true, "ergopti_alt_gr", true, "ergopti_plus", true,
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
