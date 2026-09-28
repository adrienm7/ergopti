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
;    action does nothing.
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
}
Test("layer editor host: the size limit and error codes are the Lua hosts' ones", _LEH_ContractMatchesTheLuaHosts)
