; static/ergopti_plus/windows/tests/unit/modules/keymap/test_nav_layer_save.ahk

; ==============================================================================
; MODULE: Navigation Layer Save Tests
; DESCRIPTION:
; platform/remap/nav_layer_save.ahk saves and applies the user's layers.toml for
; Ergopti Studio's « Apply the navigation layer ». These tests drive it with the
; real loader, the real atomic writer and a real temporary folder.
;
; COVERAGE:
; 1. A save is refused, and nothing is written or reloaded, when the text is
;    not a string, is too large, names an action outside the vocabulary, or
;    binds something one of the three OSes cannot resolve.
; 2. End to end: the scripted session (_shared/tests/corpus/layer_editor/
;    edited_layers.toml) is written byte for byte with no staging debris, the
;    reload is requested, and the hotkey table then built from the folder
;    carries every Windows edit; a refused reload reports saved, not applied.
; 3. The size limit and the error codes are the Lua drivers' ones.
; 4. The layer key comes from the tap-hold configuration, and the Studio's
;    « Navigation layer » entries read the user's file, else the preset
;    (studio-nav-entry).
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Data and helpers =======
; ===================================
; ===================================

_NLS_SharedDir() => A_ScriptDir . "\..\..\_shared"

_NLS_FixtureText() {
	Path := _NLS_SharedDir() . "\tests\corpus\layer_editor\edited_layers.toml"
	if !FileExist(Path)
		throw Error("edited_layers.toml not found at '" . Path . "' — a missing fixture must fail this suite")
	return FileRead(Path, "UTF-8-RAW")
}

_NLS_Corpus() => JsonParse(FileRead(_NLS_SharedDir() . "\tests\corpus\layer_editor\layer_keys.json", "UTF-8"))

; A fresh, empty configuration folder.
_NLS_MakeDir() {
	Dir := A_Temp . "\ergopti_nav_layer_save_" . A_TickCount . "_" . Random(100000, 999999)
	DirCreate(Dir)
	return Dir
}

_NLS_RemoveDir(Dir) {
	try DirDelete(Dir, true)
}

; Every error code of a list, sorted and joined.
_NLS_Codes(Errors) {
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

; Records reload requests; returns what the test asks.
class _NLS_FakeApply {
	Calls := 0
	Accept := true
	Call() {
		this.Calls += 1
		return this.Accept
	}
}





; ========================
; ========================
; ======= 2/ Saves =======
; ========================
; ========================

_NLS_InvalidSavesWriteNothing() {
	global JSON_NULL
	Ctx := KeymapLayers_LoadContext(_NLS_SharedDir())
	Dir := _NLS_MakeDir()
	Big := ""
	loop 70000
		Big .= "#"
	Cases := [
		[JSON_NULL, "invalid_payload"],
		[42, "invalid_payload"],
		[Big, "invalid_payload"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = "format_disk"`n', "unknown_action"],
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = "keystroke:fn+KeyB"`n', "unavailable_on_os"],
		; No source kind is OS-specific any more: wheel and pointer sources bind on all three OS.
		['[_meta]`nschema_version = 1`n[layers.nav.all]`n"KeyA" = { a = 1 }`n', "toml_invalid"]
	]
	Apply := _NLS_FakeApply()
	try {
		for Scenario in Cases {
			Result := NavLayerSave_SaveAndApply(Scenario[1], _NLS_SharedDir(), Dir, Apply)
			AssertFalse(Result["saved"], "case " . A_Index . " must be refused")
			AssertEqual(Scenario[2], _NLS_Codes(Result["errors"]), "case " . A_Index . " refusal")
		}
		AssertEqual(0, Apply.Calls, "a refused save reloads nothing")
		AssertFalse(FileExist(Dir . "\layers.toml"), "a refused save writes nothing")
		AssertFalse(FileExist(Dir . "\layers.toml.tmp"), "a refused save stages nothing")
	} finally _NLS_RemoveDir(Dir)
}
Test("navigation layer save: an invalid save is refused and writes nothing", _NLS_InvalidSavesWriteNothing)

_NLS_SessionReachesTheHotkeyTable() {
	Ctx := KeymapLayers_LoadContext(_NLS_SharedDir())
	Dir := _NLS_MakeDir()
	Text := _NLS_FixtureText()
	Apply := _NLS_FakeApply()
	try {
		Result := NavLayerSave_SaveAndApply(Text, _NLS_SharedDir(), Dir, Apply)
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
	} finally _NLS_RemoveDir(Dir)
}
Test("navigation layer save: the session is saved and reaches the hotkey table (e2e)", _NLS_SessionReachesTheHotkeyTable)

_NLS_RefusedReloadIsReported() {
	Dir := _NLS_MakeDir()
	Apply := _NLS_FakeApply()
	Apply.Accept := false
	try {
		Result := NavLayerSave_SaveAndApply(_NLS_FixtureText(), _NLS_SharedDir(), Dir, Apply)
		AssertTrue(Result["saved"], "the file is saved before the reload is asked for")
		AssertFalse(Result["applied"], "a refused reload leaves the layer not applied")
	} finally _NLS_RemoveDir(Dir)
}
Test("navigation layer save: a refused reload is reported as saved but not applied", _NLS_RefusedReloadIsReported)

_NLS_ContractMatchesTheLuaHosts() {
	Source := FileRead(_NLS_SharedDir() . "\layouts\engine\layers\editor.lua", "UTF-8")
	AssertTrue(InStr(Source, 'M.MAX_TEXT_BYTES = Timings.count("limits", "layer_file_bytes")') > 0,
		"the Lua hosts read [limits] layer_file_bytes")
	Registry := ParseTomlFile(_NLS_SharedDir() . "\core\timing\data\constants.toml")
	MaxBytes := Integer(IniCacheGet(Registry, "limits", "layer_file_bytes"))
	AssertEqual(TimingsGet("limits", "layer_file_bytes"), MaxBytes, "the host reads the registry value")
	Refused := NavLayerSave_Validate(Format("{:" . (MaxBytes + 1) . "}", ""), Map())
	AssertEqual(Refused.Length, 1, "one byte over [limits] layer_file_bytes is refused")
	AssertEqual(Refused[1]["code"], NAV_LAYER_SAVE_INVALID_PAYLOAD, "the size refusal is an invalid payload")
	AssertTrue(InStr(Refused[1]["detail"], "more than " . MaxBytes) > 0, "the refusal names the registry limit")
	Codes := Map("INVALID_PAYLOAD", NAV_LAYER_SAVE_INVALID_PAYLOAD, "WRITE_FAILED", NAV_LAYER_SAVE_WRITE_FAILED)
	for Name, Code in Codes {
		AssertTrue(RegExMatch(Source, "m)^M\." . Name . ' = "([a-z_]+)"\r?$', &Declared), "the Lua hosts declare " . Name)
		AssertEqual(Declared[1], Code, Name . " is one error code on every OS")
	}
}
Test("navigation layer save: the size limit and error codes are the Lua drivers' ones", _NLS_ContractMatchesTheLuaHosts)





; =================================
; =================================
; ======= 3/ Ergopti Studio =======
; =================================
; =================================

_NLS_LayerKeysFollowTheTapHolds() {
	Corpus := _NLS_Corpus()
	Shipped := NavLayerSave_LayerKeys(LoadTapHoldToml(_NLS_SharedDir() . "\tap_hold\data\defaults.toml"))
	Want := ""
	for Index, Code in Corpus["recommended_layer_keys"]["windows"]
		Want .= (Index == 1 ? "" : ",") . Code
	Got := ""
	for Index, Code in Shipped
		Got .= (Index == 1 ? "" : ",") . Code
	AssertEqual(Want, Got, "the shipped tap-holds' layer key")
	Moved := NavLayerSave_LayerKeys(Map("keys", Map("space", Map("hold_layer", "nav"))))
	AssertEqual(1, Moved.Length, "one layer key")
	AssertEqual("Space", Moved[1], "the layer key follows the configuration")
	AssertEqual(0, NavLayerSave_LayerKeys(Map("keys", Map())).Length, "no tap-hold, no layer key")
}
Test("navigation layer save: the layer key comes from the tap-hold configuration", _NLS_LayerKeysFollowTheTapHolds)

; (studio-nav-entry) The Studio shows the user's layers.toml, else the preset.
_NLS_StudioNavReadsTheUserFileElseThePreset() {
	global _SharedDir, _ConfigDir
	SavedShared := _SharedDir, SavedConfig := _ConfigDir
	Dir := _NLS_MakeDir()
	try {
		_SharedDir := _NLS_SharedDir()
		_ConfigDir := Dir
		Preset := FileRead(_NLS_SharedDir() . "\layouts\data\layers.recommended.toml", "UTF-8-RAW")
		Nav := NavLayerSave_StudioNav()
		AssertEqual(Preset, Nav["text"], "no layers.toml: the preset is where the layer starts")
		AssertTrue(Nav["hold"] is String, "the layer key is a registry code, or empty")
		FileAppend(_NLS_FixtureText(), Dir . "\layers.toml", "UTF-8-RAW")
		AssertEqual(_NLS_FixtureText(), NavLayerSave_StudioNav()["text"], "the user's own file when there is one")
	} finally {
		_SharedDir := SavedShared
		_ConfigDir := SavedConfig
		_NLS_RemoveDir(Dir)
	}
}
Test("navigation layer save: the Studio reads the user's file, else the preset (studio-nav-entry)",
	_NLS_StudioNavReadsTheUserFileElseThePreset)
