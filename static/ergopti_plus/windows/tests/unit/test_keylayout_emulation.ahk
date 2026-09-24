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
; - the registry client: URL, verification, local copy and a download replayed
;   through an injected transport, including the refusal to publish a file
;   that does not match its index;
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
	global KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex
	Saved := [KLE_Model, KLE_Id, KLE_State, KLE_KeyCodes, KLE_LevelIndex]
	try Fn()
	finally {
		KLE_Model := Saved[1]
		KLE_Id := Saved[2]
		KLE_State := Saved[3]
		KLE_KeyCodes := Saved[4]
		KLE_LevelIndex := Saved[5]
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

; A registry download replayed from memory: Served maps each URL to the text a
; request for it writes to its output file; any other URL answers HTTP 404.
class _KLT_FakeRequest {
	__New(Served, Log) {
		this.Served := Served
		this.Log := Log
		this.Url := ""
		this.OutputPath := ""
		this.Status := 0
	}
	Open(Method, Url, Async := true) {
		this.Url := Url
	}
	SetRequestHeader(Name, Value) {
	}
	SetProxy(Proxy) {
	}
	SetTimeouts(ResolveMs, ConnectMs, SendMs, ReceiveMs) {
	}
	SetOutputFile(Path) {
		this.OutputPath := Path
	}
	Send(Body := "") {
		this.Log.Push(this.Url)
		this.Status := this.Served.Has(this.Url) ? 200 : 404
		_KLT_WriteRaw(this.OutputPath, this.Served.Get(this.Url, "404: Not Found"))
		return true
	}
	WaitForResponse(TimeoutSeconds := 0) {
		return true
	}
	Abort() {
		return true
	}
}

_KLT_NoProxy(Urls, Callback) {
	Resolved := Map()
	for Url in Urls
		Resolved[Url] := ""
	Callback.Call(Resolved)
}

_KLT_Transport(Served, Log) {
	return Map(
		"request", () => _KLT_FakeRequest(Served, Log),
		"resolve_proxy", _KLT_NoProxy,
		"schedule", (Fn, DelayMs) => Fn.Call()
	)
}

_KLT_ServedRegistry(LayoutText) {
	return Map(
		LayoutRegistry_RawUrl("index.json"), _KLT_IndexText(),
		LayoutRegistry_RawUrl(_KLT_Entry("ergol")["file"]), LayoutText
	)
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
	AssertEqual("https://raw.githubusercontent.com/adrienm7/ergopti/main/static/layouts/registry/index.json",
		LayoutRegistry_RawUrl("index.json"), "the URL is built from the shared defaults"),
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

Test("layout registry: a local copy is read only when it matches its index (layout-registry-emulation)",
	_KLT_ReadLocalCase)

_KLT_ReadLocalCase() {
	Dir := _KLT_TempDir()
	try {
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "nothing downloaded yet")
		_KLT_WriteRaw(Dir . "index.json", _KLT_IndexText())
		_KLT_WriteRaw(Dir . "ergol.keylayout", _KLT_LayoutText("ergol"))
		LocalCopy := LayoutRegistry_ReadLocal("ergol", Dir)
		AssertEqual("ergol", LocalCopy["Entry"]["id"])
		AssertEqual(_KLT_LayoutText("ergol"), LocalCopy["Text"])
		_KLT_WriteRaw(Dir . "ergol.keylayout", _KLT_Tamper(_KLT_LayoutText("ergol"), 'output="q"', 'output="z"'))
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "an edited local copy must be refused")
	} finally DirDelete(Dir, true)
}

Test("layout registry: a download is verified before it is published (layout-registry-emulation)",
	_KLT_FetchCase)

_KLT_FetchCase() {
	Dir := _KLT_TempDir()
	try {
		Log := []
		Results := []
		LayoutRegistry_Fetch("ergol", Dir, (Ok, Detail) => Results.Push([Ok, Detail]),
			_KLT_Transport(_KLT_ServedRegistry(_KLT_LayoutText("ergol")), Log))
		AssertEqual(1, Results.Length, "OnDone must be called exactly once")
		AssertTrue(Results[1][1], "the download must succeed: " . (Results[1][2] is String ? Results[1][2] : ""))
		AssertEqual("ergol", Results[1][2]["id"])
		AssertEqual(2, Log.Length, "the index then the layout")
		AssertEqual(LayoutRegistry_RawUrl("index.json"), Log[1])
		AssertEqual(_KLT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"])
		AssertFalse(FileExist(Dir . "index.json" . LAYOUT_REGISTRY_PARTIAL_SUFFIX), "no partial index left")
		AssertFalse(FileExist(Dir . "ergol.keylayout" . LAYOUT_REGISTRY_PARTIAL_SUFFIX), "no partial layout left")

		; A tampered layout is refused and the verified copy above survives it.
		Results := []
		LayoutRegistry_Fetch("ergol", Dir, (Ok, Detail) => Results.Push([Ok, Detail]),
			_KLT_Transport(_KLT_ServedRegistry(_KLT_Tamper(_KLT_LayoutText("ergol"), 'output="q"', 'output="z"')), []))
		AssertEqual(1, Results.Length)
		AssertFalse(Results[1][1], "a layout that does not match the index must not be published")
		AssertContains(Results[1][2], "checksum")
		AssertEqual(_KLT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"],
			"the previously verified copy must be left untouched")
		AssertFalse(FileExist(Dir . "ergol.keylayout" . LAYOUT_REGISTRY_PARTIAL_SUFFIX), "the refused download is removed")
	} finally DirDelete(Dir, true)
}

Test("layout registry: a missing index or layout fails the download (layout-registry-emulation)",
	_KLT_FetchFailuresCase)

_KLT_FetchFailuresCase() {
	Dir := _KLT_TempDir()
	try {
		Results := []
		LayoutRegistry_Fetch("ergol", Dir, (Ok, Detail) => Results.Push([Ok, Detail]),
			_KLT_Transport(Map(), []))
		AssertEqual(1, Results.Length)
		AssertFalse(Results[1][1])
		AssertContains(Results[1][2], "HTTP 404")
		Results := []
		LayoutRegistry_Fetch("optimot", Dir, (Ok, Detail) => Results.Push([Ok, Detail]),
			_KLT_Transport(_KLT_ServedRegistry(_KLT_LayoutText("ergol")), []))
		AssertFalse(Results[1][1], "a layout the index does not list cannot be downloaded")
		AssertContains(Results[1][2], "not in the registry index")
		AssertFalse(FileExist(Dir . "index.json"), "nothing is published from a failed download")
		AssertFalse(FileExist(Dir . "index.json" . LAYOUT_REGISTRY_PARTIAL_SUFFIX))
		AssertThrows(() => LayoutRegistry_Fetch("..\evil", Dir, (*) => 0, _KLT_Transport(Map(), [])),
			"an invalid id is refused before any request")
	} finally DirDelete(Dir, true)
}





; ===============================================
; ===============================================
; ======= 5/ Registration, gates and boot =======
; ===============================================
; ===============================================

Test("keylayout emulation: registration covers every key and leaves native chords alone (layout-registry-emulation)",
	_KLT_RegistrationCase)

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
		Count := KeylayoutEmulation_Register(Table, (Name, *) => Names.Push(Name),
			(Args*) => HotIfCalls.Push(Args.Length))
		; plain + Shift per key, six chords per key but the space bar, one AltGr
		; combination per key, one passthrough per dead-key reset key.
		Expected := Keys * 2 + (Keys - 1) * 6 + Keys + KLE_DEAD_RESET_KEYS.Length
		AssertEqual(Expected, Count)
		AssertEqual(Expected, Names.Length)
		Joined := " " . _KLT_Join(Names, " ") . " "
		for Name in ["SC010", "+SC010", "^SC010", "!+SC056", "#+SC029", "SC138 & SC010", "SC039", "+SC039",
			"SC138 & SC039", "~BackSpace"]
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
		"direct_access_digits", true, "ctrl_magic_save", true, "emulated_layout", "ergol")
	_KLT_WithLayoutFeatures(Selected, () => (
		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated),
		AssertFalse(Features["layout"]["ergopti_base"], "the Ergopti base layer stands down"),
		AssertFalse(Features["layout"]["ergopti_alt_gr"], "the Ergopti AltGr layer stands down"),
		AssertFalse(Features["layout"]["ergopti_plus"], "the Ergopti+ changes stand down"),
		AssertFalse(Features["layout"]["direct_access_digits"], "the emulated layout owns its digit row"),
		AssertTrue(Features["layout"]["ctrl_magic_save"], "a feature that works on any layout is kept"),
		AssertEqual("ergol", Features["layout"]["emulated_layout"], "the selection itself is kept")
	))
	NoneSelected := Map("ergopti_base", true, "ergopti_alt_gr", true, "ergopti_plus", true,
		"direct_access_digits", true, "ctrl_magic_save", true, "emulated_layout", "")
	_KLT_WithLayoutFeatures(NoneSelected, () => (
		ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated),
		AssertTrue(Features["layout"]["ergopti_base"], "without a registry layout the Ergopti emulation stays"),
		AssertTrue(Features["layout"]["direct_access_digits"])
	))
}

_KLT_BootLayout(Id) => Map("ergopti_base", false, "emulated_layout", Id)

_KLT_BootDeps(Log, ReadLocalFn, FetchFn) {
	return Map(
		"keycodes", LayoutRegistry_Keycodes,
		"register", (Table) => (Log.Push("register"), 1),
		"read_local", ReadLocalFn,
		"fetch", FetchFn
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
