; static/ergopti_plus/windows/tests/unit/test_layer_editor_host.ahk

; ==============================================================================
; MODULE: Navigation Layer Editor Host Tests
; DESCRIPTION:
; ui/layer_editor/init.ahk answers the shared layer editor page on Windows.
; These tests drive its message handler and save path the way the page does,
; with the real loader, the real atomic writer and a real temporary folder.
;
; COVERAGE:
; 1. init(): the user's file and the problems every OS's loader finds in it;
;    no file is text null and no problem.
; 2. A save is refused, and nothing is written or reloaded, when the text is
;    not a string, is too large, names an action outside the vocabulary, or
;    binds something one of the three OSes cannot resolve.
; 3. End to end: the page's scripted session (_shared/tests/corpus/
;    layer_editor/edited_layers.toml) is written byte for byte with no staging
;    debris, the reload is requested, and the hotkey table then built from the
;    folder carries every Windows edit.
; 4. Messages: save answers saveResult(), cancel closes the window, an unknown
;    action does nothing, "legends" answers setLegends().
; 5. Legends (layer-editor-current-layout-legends): init() carries what the
;    layout the user types with puts on every character key: the shared
;    corpus (_shared/tests/corpus/layer_editor/legends.json) through a fake
;    ToUnicodeEx by scan code; with the Ergopti emulation on, the characters
;    of its .keylayout (ErgoptiLayout_Spec, never a copied table); the keys
;    left without one are reported once; the layer key comes from the
;    tap-hold configuration.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Data and helpers =======
; ===================================
; ===================================

_LEH_SharedDir() => A_ScriptDir . "\..\..\_shared"

_LEH_FixtureText() {
	Path := _LEH_SharedDir() . "\tests\corpus\layer_editor\edited_layers.toml"
	if !FileExist(Path)
		throw Error("edited_layers.toml not found at '" . Path . "' — a missing fixture must fail this suite")
	return FileRead(Path, "UTF-8-RAW")
}

; A fresh, empty configuration folder.
_LEH_MakeDir() {
	Dir := A_Temp . "\ergopti_layer_editor_" . A_TickCount . "_" . Random(100000, 999999)
	DirCreate(Dir)
	return Dir
}

_LEH_RemoveDir(Dir) {
	try DirDelete(Dir, true)
}

; Every error code of a list, sorted and joined.
_LEH_Codes(Errors) {
	Codes := []
	for Err in Errors
		Codes.Push(Err["code"])
	Out := ""
	loop Codes.Length {
		; Insertion order is the loader's; sort for a stable comparison.
		Smallest := 1
		for Index, Code in Codes {
			if (StrCompare(Code, Codes[Smallest]) < 0)
				Smallest := Index
		}
		Out .= (A_Index == 1 ? "" : ",") . Codes.RemoveAt(Smallest)
	}
	return Out
}

; Records what the host asks of the window.
class _LEH_FakeHost {
	Scripts := []
	Closed := 0
	Eval(Js) {
		this.Scripts.Push(Js)
	}
	Close() {
		this.Closed += 1
	}
}

; Records reload requests; returns what the test asks.
class _LEH_FakeApply {
	Calls := 0
	Accept := true
	Call() {
		this.Calls += 1
		return this.Accept
	}
}





; =========================
; =========================
; ======= 2/ init() =======
; =========================
; =========================

_LEH_InitSendsTheFileAndItsProblems() {
	_TestEnsureErgoptiLayout()
	Ctx := KeymapLayers_LoadContext(_LEH_SharedDir())
	Dir := _LEH_MakeDir()
	try {
		Js := LayerEditor_InitJs(Ctx, Dir)
		AssertTrue(InStr(Js, '"os":"windows"'), "init() says the OS")
		AssertTrue(InStr(Js, '"text":null'), "no layers.toml is text null")
		AssertTrue(InStr(Js, '"errors":[]'), "no layers.toml is no problem")
		FileAppend('[_meta]`nschema_version = 1`n`n[layers.nav.all]`n"Space" = "spotlight"`n', Dir . "\layers.toml", "UTF-8-RAW")
		Js := LayerEditor_InitJs(Ctx, Dir)
		AssertTrue(InStr(Js, '\"Space\" = \"spotlight\"'), "init() carries the file's text")
		; Spotlight exists on macOS only; the Windows and Linux loaders share one
		; error, reported once.
		AssertTrue(InStr(Js, '"code":"unavailable_on_os"'), "init() carries what another OS refuses")
		AssertEqual(1, StrSplit(Js, '"code":').Length - 1, "one distinct error, reported once")
	} finally _LEH_RemoveDir(Dir)
}
Test("layer editor host: init() sends the user's file and every OS's problems", _LEH_InitSendsTheFileAndItsProblems)





; ================================
; ================================
; ======= 3/ Refused saves =======
; ================================
; ================================

_LEH_InvalidSavesWriteNothing() {
	global JSON_NULL
	Ctx := KeymapLayers_LoadContext(_LEH_SharedDir())
	Dir := _LEH_MakeDir()
	Big := ""
	loop 70000
		Big .= "#"
	Cases := [
		[JSON_NULL, "invalid_payload"],
		[42, "invalid_payload"],
		[Big, "invalid_payload"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = "format_disk"`n', "unknown_action"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = "keystroke:fn+KeyB"`n', "unavailable_on_os"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"WheelUp" = "vol_up"`n', "unavailable_on_os"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = { a = 1 }`n', "toml_invalid"]
	]
	Apply := _LEH_FakeApply()
	try {
		for Scenario in Cases {
			Result := LayerEditor_SaveAndApply(Scenario[1], _LEH_SharedDir(), Dir, Apply)
			AssertFalse(Result["saved"], "case " . A_Index . " must be refused")
			AssertEqual(Scenario[2], _LEH_Codes(Result["errors"]), "case " . A_Index . " refusal")
		}
		AssertEqual(0, Apply.Calls, "a refused save reloads nothing")
		AssertFalse(FileExist(Dir . "\layers.toml"), "a refused save writes nothing")
		AssertFalse(FileExist(Dir . "\layers.toml.tmp"), "a refused save stages nothing")
	} finally _LEH_RemoveDir(Dir)
}
Test("layer editor host: an invalid save is refused and writes nothing", _LEH_InvalidSavesWriteNothing)





; =============================
; =============================
; ======= 4/ End to end =======
; =============================
; =============================

_LEH_SessionReachesTheHotkeyTable() {
	Ctx := KeymapLayers_LoadContext(_LEH_SharedDir())
	Dir := _LEH_MakeDir()
	Text := _LEH_FixtureText()
	Apply := _LEH_FakeApply()
	try {
		Result := LayerEditor_SaveAndApply(Text, _LEH_SharedDir(), Dir, Apply)
		AssertTrue(Result["saved"], "the page's session must be saved")
		AssertTrue(Result["applied"], "the saved layer must be applied")
		AssertEqual(1, Apply.Calls, "one reload applies the saved layer")
		AssertEqual(Text, FileRead(Dir . "\layers.toml", "UTF-8-RAW"), "the file is the page's text, byte for byte")
		AssertFalse(FileExist(Dir . "\layers.toml.tmp"), "no staging file is left behind")
		Loaded := KeymapLayers_LoadUserFile(Ctx, Dir, "windows")
		AssertTrue(Loaded["ok"], "the saved file loads on Windows without an error")
		Rows := Map()
		for Row in NavLayer_BuildTable(Loaded["layers"][NAV_LAYER_ID], Ctx)
			Rows[Row["hotkey"]] := Row["action"]
		AssertEqual("send:{Up N}", Rows.Get("*SC014", ""), "KeyT: the Windows edit, a repeatable Up")
		AssertFalse(Rows.Has("*SC022"), "KeyG made native on Windows registers no hotkey")
		AssertEqual("send:^+{Home}", Rows.Get("*SC010", ""), "an untouched key keeps its recommended binding")
	} finally _LEH_RemoveDir(Dir)
}
Test("layer editor host: the page's session is saved and reaches the hotkey table (e2e)", _LEH_SessionReachesTheHotkeyTable)

_LEH_RefusedReloadIsReported() {
	Dir := _LEH_MakeDir()
	Apply := _LEH_FakeApply()
	Apply.Accept := false
	try {
		Result := LayerEditor_SaveAndApply(_LEH_FixtureText(), _LEH_SharedDir(), Dir, Apply)
		AssertTrue(Result["saved"], "the file is saved before the reload is asked for")
		AssertFalse(Result["applied"], "a refused reload leaves the layer not applied")
		AssertTrue(InStr(LayerEditor_SaveResultJs(Result), '"saved":true,"applied":false'), "the page is told")
	} finally _LEH_RemoveDir(Dir)
}
Test("layer editor host: a refused reload is reported as saved but not applied", _LEH_RefusedReloadIsReported)





; ===========================
; ===========================
; ======= 5/ Messages =======
; ===========================
; ===========================

_LEH_MessagesRouteToTheirAction() {
	global _SharedDir, _ConfigDir
	SavedShared := _SharedDir, SavedConfig := _ConfigDir
	Dir := _LEH_MakeDir()
	Host := _LEH_FakeHost()
	Apply := _LEH_FakeApply()
	try {
		_SharedDir := _LEH_SharedDir()
		_ConfigDir := Dir
		_LayerEditor_OnMessage(Host, Map("action", "format_disk"), Apply)
		AssertEqual(0, Host.Scripts.Length + Host.Closed, "an unknown action does nothing")
		_LayerEditor_OnMessage(Host, Map("action", "save", "text", _LEH_FixtureText()), Apply)
		AssertEqual(1, Host.Scripts.Length, "a save answers once")
		AssertTrue(InStr(Host.Scripts[1], "window.saveResult({" . '"saved":true,"applied":true'), "the answer is saveResult()")
		_LayerEditor_OnMessage(Host, Map("action", "save"), Apply)
		AssertTrue(InStr(Host.Scripts[2], '"saved":false'), "a save without text is refused")
		_TestEnsureErgoptiLayout()
		_LayerEditor_OnMessage(Host, Map("action", "legends"), Apply)
		AssertEqual(3, Host.Scripts.Length, '"legends" answers once')
		AssertTrue(InStr(Host.Scripts[3], "window.setLegends({" . '"source":'), "the answer is setLegends()")
		_LayerEditor_OnMessage(Host, Map("action", "cancel"), Apply)
		AssertEqual(1, Host.Closed, "cancel closes the window")
		AssertEqual(1, Apply.Calls, "only the valid save reloads")
	} finally {
		_SharedDir := SavedShared
		_ConfigDir := SavedConfig
		_LEH_RemoveDir(Dir)
	}
}
Test("layer editor host: save, cancel and unknown messages", _LEH_MessagesRouteToTheirAction)

; The macOS and Linux hosts share _shared/lua/keymap/layer_editor.lua; this host
; must refuse the same sizes and name its refusals with the same codes.
_LEH_ContractMatchesTheLuaHosts() {
	Source := FileRead(_LEH_SharedDir() . "\lua\keymap\layer_editor.lua", "UTF-8")
	AssertTrue(RegExMatch(Source, "m)^M\.MAX_TEXT_BYTES = (\d+)\r?$", &Found), "the Lua hosts declare MAX_TEXT_BYTES")
	AssertEqual(Integer(Found[1]), LAYER_EDITOR_MAX_TEXT_BYTES, "one size limit on every OS")
	Codes := Map("INVALID_PAYLOAD", LAYER_EDITOR_INVALID_PAYLOAD, "WRITE_FAILED", LAYER_EDITOR_WRITE_FAILED,
		"FILE_UNREADABLE", LAYER_EDITOR_FILE_UNREADABLE)
	for Name, Code in Codes {
		AssertTrue(RegExMatch(Source, "m)^M\." . Name . ' = "([a-z_]+)"\r?$', &Declared), "the Lua hosts declare " . Name)
		AssertEqual(Declared[1], Code, Name . " is one error code on every OS")
	}
	Sources := Map("LEGEND_SOURCE_EMULATION", LAYER_EDITOR_LEGEND_SOURCE_EMULATION,
		"LEGEND_SOURCE_OS", LAYER_EDITOR_LEGEND_SOURCE_OS)
	for Name, Value in Sources {
		AssertTrue(RegExMatch(Source, "m)^M\." . Name . ' = "([a-z_]+)"\r?$', &Declared), "the Lua hosts declare " . Name)
		AssertEqual(Declared[1], Value, Name . " is one legend source on every OS")
	}
}
Test("layer editor host: the size limit and error codes are the Lua hosts' ones", _LEH_ContractMatchesTheLuaHosts)






; ================================================================
; ================================================================
; ======= 6/ Legends (layer-editor-current-layout-legends) =======
; ================================================================
; ================================================================

_LEH_Corpus() => JsonParse(FileRead(_LEH_SharedDir() . "\tests\corpus\layer_editor\legends.json", "UTF-8"))

; A layout as ToUnicodeEx reads it: registry code -> text, looked up by the
; scan code the host probes.
class _LEH_FakeLayout {
	__New(Ctx, Layout) {
		this.BySc := Map()
		for Code, Text in Layout
			this.BySc[Integer("0x" . SubStr(Ctx["keys"][Code]["ahk"], 3))] := Text
	}
	Probe() {
		return {
			Hkl: () => 0x040C040C,
			ScToVk: (Sc, Hkl) => (Hkl == 0x040C040C) ? 0x100 + Sc : 0,
			ToUnicode: this._Text.Bind(this),
		}
	}
	_Text(Vk, Sc, Hkl) {
		Text := this.BySc.Get(Sc, "")
		return { Count: StrLen(Text), Text: Text }
	}
}

_LEH_NoEmulation() => Map("active", false, "character", (Sc) => "")

_LEH_LegendsFollowTheOsLayout() {
	global _LayerEditorReported
	Ctx := KeymapLayers_LoadContext(_LEH_SharedDir())
	Corpus := _LEH_Corpus()
	for LegendCase in Corpus["cases"] {
		Fake := _LEH_FakeLayout(Ctx, LegendCase["layout"])
		Legends := LayerEditor_Legends(Ctx, _LEH_NoEmulation(), Fake.Probe())
		AssertEqual(LegendCase["source"], Legends["source"], LegendCase["name"] . ": source")
		for Code, Text in LegendCase["expected"]
			AssertEqual(Text, Legends["keys"].Get(Code, "<none>"), LegendCase["name"] . ": " . Code)
		for Code in Legends["keys"]
			AssertTrue(LegendCase["expected"].Has(Code), LegendCase["name"] . ": " . Code . " must not have a legend")
		AssertTrue(LegendCase["expected"].Count >= 40, "only " . LegendCase["expected"].Count . " legends compared")
		Unresolved := ""
		for Index, Code in Legends["unresolved"]
			Unresolved .= (Index == 1 ? "" : ",") . Code
		Expected := ""
		for Index, Code in LegendCase["unresolved"]
			Expected .= (Index == 1 ? "" : ",") . Code
		AssertEqual(Expected, Unresolved, LegendCase["name"] . ": the keys left without a legend")
		_LayerEditorReported := Map()
		AssertTrue(LayerEditor_ReportUnresolved(Legends), "the keys without a legend are reported")
		AssertFalse(LayerEditor_ReportUnresolved(Legends), "the same keys are reported once")
		Dir := _LEH_MakeDir()
		try {
			Js := LayerEditor_InitJs(Ctx, Dir, Legends, ["AltLeft"])
			AssertTrue(InStr(Js, '"legends":{"source":"os","keys":{'), "init() carries the legends")
			AssertTrue(InStr(Js, '"KeyQ":' . JsonStringLiteral(LegendCase["expected"]["KeyQ"])), "init() carries KeyQ's legend")
			AssertTrue(InStr(Js, '"layer_keys":["AltLeft"]'), "init() carries the layer key")
		} finally _LEH_RemoveDir(Dir)
		AssertTrue(InStr(LayerEditor_SetLegendsJs(Legends), "window.setLegends({" . '"source":"os"'),
			"setLegends() takes the same legends")
	}
	; No layout could be read: every character key is unresolved, and says why.
	None := LayerEditor_Legends(Ctx, _LEH_NoEmulation(), { Hkl: () => 0, ScToVk: (Sc, Hkl) => 0,
		ToUnicode: (Vk, Sc, Hkl) => ({ Count: 0, Text: "" }) })
	AssertEqual(0, None["keys"].Count, "no layout, no legend")
	AssertTrue(None["unresolved"].Length >= 45, "every character key is unresolved")
	AssertContains(None["reason"], "no keyboard layout", "the reason is logged")
}
Test("layer editor host: legends follow the OS layout (layer-editor-current-layout-legends)", _LEH_LegendsFollowTheOsLayout)

_LEH_EmulatedLegendsComeFromTheKeylayout() {
	_TestEnsureErgoptiLayout()
	Ctx := KeymapLayers_LoadContext(_LEH_SharedDir())
	Spec := ErgoptiLayout_Spec()
	; A QWERTY-like OS layout under the emulation: every key types "x".
	Qwerty := Map()
	for Code, Entry in Ctx["keys"]
		if (Entry["kind"] == "key") && !(Entry["ahk_send"] is String)
			Qwerty[Code] := "x"
	Fake := _LEH_FakeLayout(Ctx, Qwerty)
	Emulation := Map("active", true, "character", _LayerEditor_EmulatedCharacter.Bind(false, true, true))
	Legends := LayerEditor_Legends(Ctx, Emulation, Fake.Probe())
	AssertEqual("emulation", Legends["source"], "the emulated layout is the source")
	Compared := 0
	for Code, Entry in Ctx["keys"] {
		Sc := Entry["ahk"]
		if !Spec["levels"]["base"].Has(Sc) || (Entry["ahk_send"] is String)
			continue
		Descriptor := Spec["levels"]["base"][Sc]
		if !Descriptor.Has("text") && !Descriptor.Has("dead")
			continue
		Want := Descriptor.Has("text") ? Descriptor["text"] : Spec["terminators"][Descriptor["dead"]]
		AssertEqual(Want, Legends["keys"].Get(Code, "<none>"), Code . " (" . Sc . ") shows the .keylayout's character")
		Compared += 1
	}
	AssertTrue(Compared >= 30, "only " . Compared . " emulated keys compared")
	AssertTrue(Legends["keys"]["KeyQ"] != "x", "KeyQ is not read from the OS layout under the emulation")
	AssertEqual("1", Legends["keys"]["Digit1"], "the digit row types its digits")
	AssertEqual(ErgoptiNumberRowEdgeMapping()[0x29], Legends["keys"]["Backquote"], "the digit row's left edge")
	; Without the digit row, the number row is the OS layout's.
	NoDigits := LayerEditor_Legends(Ctx, Map("active", true,
		"character", _LayerEditor_EmulatedCharacter.Bind(false, true, false)), Fake.Probe())
	AssertEqual("x", NoDigits["keys"]["Digit1"], "a key the emulation leaves is the OS layout's")
	; The live emulation: the suite's features turn the Ergopti base layer on.
	AssertTrue(LayerEditor_CurrentEmulation()["active"], "the Ergopti base layer is an emulation")
	AssertEqual(Legends["keys"]["KeyQ"], LayerEditor_CurrentEmulation()["character"].Call("SC010"),
		"the live emulation reads the same .keylayout")
}
Test("layer editor host: emulated legends come from the .keylayout (layer-editor-current-layout-legends)",
	_LEH_EmulatedLegendsComeFromTheKeylayout)

_LEH_LegendTextRefusesTheUnprintable() {
	AssertEqual("a", LayerEditor_LegendText("a"))
	AssertEqual("^", LayerEditor_LegendText("^"), "a dead key's accent is a legend")
	for Bad in ["", " ", "`t", Chr(0x1B), Chr(0x1C), Chr(0x85), Chr(0xA0), 42]
		AssertEqual("", LayerEditor_LegendText(Bad), "case " . A_Index . " is no legend")
}
Test("layer editor host: a legend is printable text", _LEH_LegendTextRefusesTheUnprintable)

_LEH_LayerKeysFollowTheTapHolds() {
	Corpus := _LEH_Corpus()
	Shipped := LayerEditor_LayerKeys(LoadTapHoldToml(_LEH_SharedDir() . "\tap_hold\defaults.toml"))
	Want := ""
	for Index, Code in Corpus["recommended_layer_keys"]["windows"]
		Want .= (Index == 1 ? "" : ",") . Code
	Got := ""
	for Index, Code in Shipped
		Got .= (Index == 1 ? "" : ",") . Code
	AssertEqual(Want, Got, "the shipped tap-holds' layer key")
	Moved := LayerEditor_LayerKeys(Map("keys", Map("space", Map("hold_layer", "nav"))))
	AssertEqual(1, Moved.Length, "one layer key")
	AssertEqual("Space", Moved[1], "the layer key follows the configuration")
	AssertEqual(0, LayerEditor_LayerKeys(Map("keys", Map())).Length, "no tap-hold, no layer key")
}
Test("layer editor host: the layer key comes from the tap-hold configuration", _LEH_LayerKeysFollowTheTapHolds)
