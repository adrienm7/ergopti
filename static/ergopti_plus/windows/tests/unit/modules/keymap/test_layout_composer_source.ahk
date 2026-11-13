; tests/unit/modules/keymap/test_layout_composer_source.ahk

; ==============================================================================
; MODULE: Layout Editor Windows Host Tests
; DESCRIPTION:
; The Windows host of the unified layout editor (docs/design/layout-editor.md
; « Windows host »): the layout manager's new actions and initData flags, the
; composer's source form of composer_save (store, stage, elevate, switch) and
; composer_emulate, and the menu row. The elevated helper runs against the fake
; machine of ../../hotstrings/engine/expander/test_kbd_register.ahk, on the files the composer really staged: no
; UAC prompt, no registry write, no system file.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LCS_CorpusDir() => _SharedDir . "\tests\corpus\layouts\source\"

_LCS_Source() => FileRead(_LCS_CorpusDir() . "source.toml", "UTF-8-RAW")

_LCS_Keylayout() => FileRead(_LCS_CorpusDir() . "source.keylayout", "UTF-8-RAW")

; The Windows emulation table of the main fixture, as the page sends it.
_LCS_Emulation() {
	Text := FileRead(_LCS_CorpusDir() . "source_emulation.json", "UTF-8-RAW")
	return JsonObjectMemberSpans(Text)["windows"]["text"]
}

; The four images the page would send, base64.
_LCS_Dlls() {
	Dlls := Map()
	for Arch in KbdRegister_Architectures()
		Dlls[Arch] := CryptoBase64Encode(_KBR_Image(A_Index))
	return Dlls
}

_LCS_Payload() {
	return Map("action", "composer_save", "source", _LCS_Source(), "keylayout", _LCS_Keylayout(),
		"emulation", _LCS_Emulation(), "use", 1, "dll_name", "kbdsrcfx", "dlls", _LCS_Dlls())
}

; The composer's collaborators over a scratch folder and the fake machine: the
; elevated helper runs in process on the files the composer staged.
_LCS_Deps(Dir, Log, Machine, Options := 0) {
	Options := (Options is Map) ? Options : Map()
	Deps := _LCH_Deps(Dir, Log, Options.Get("selected", ""))
	Ports := Machine.Ports.Clone()
	Ports["read_file"] := (Path) => FileRead(Path, "RAW")
	Ports["read_text"] := (Path) => FileRead(Path, "UTF-8")
	Ports["write_text"] := (Path, Text) => FileAppend(Text, Path, "UTF-8-RAW")
	Elevate(Command) {
		Log.Push(Map("call", "elevate " . Command["arguments"]))
		if Options.Has("elevate")
			return Options["elevate"].Call(Command)
		Words := StrSplit(StrReplace(Command["arguments"], '"'), " ")
		Words.RemoveAt(1, 2)
		Staging := Dir . "stage\kbdsrcfx"
		return KbdRegister_Run(Words[1] == "install" ? ["install", Staging] : ["uninstall", Words[2], Staging], Ports)
	}
	Deps["registry"] := Machine.Ports
	Deps["staging_root"] := Dir . "stage\"
	Deps["self_env"] := Map("compiled", false, "executable", "C:\AHK\AutoHotkey64.exe", "entry", "C:\E\kbd_register.ahk")
	Deps["elevate"] := Elevate
	Deps["activate"] := (Klid) => (Log.Push(Map("call", "activate " . Klid)), Options.Get("activated", true))
	Deps["base_enabled"] := () => Options.Get("base", true)
	Deps["emulate_settled"] := (Id, OnDone) => (Log.Push(Map("call", "emulate " . Id)),
		OnDone.Call(Options.Get("emulated", true)), true)
	return Deps
}

_LCS_Composer(Dir, Field) => LayoutRegistry_ComposerDir(Dir) . LayoutRegistry_Composer()[Field]

_LCS_Bool(Value) => (Value is LayMgrJsonBool) ? (Value.Value ? "true" : "false") : "not a JSON boolean"





; ==============================
; ==============================
; ======= 2/ The checks ========
; ==============================
; ==============================

Test("layout editor host: the source, its emulation table and its images are checked before anything is stored (layout-editor-windows)",
	_LCS_ChecksCase)

_LCS_ChecksCase() {
	Checked := LayoutComposer_CheckSource(_LCS_Source(), _LCS_Keylayout())
	AssertEqual("Source Fixture", Checked["name"])
	AssertEqual("iso", Checked["convention"])
	Table := LayoutComposer_CheckEmulation(_LCS_Emulation(), Checked["document"])
	AssertEqual("windows", Table["platform"])
	Native := LayoutComposer_CheckNative(_LCS_Payload(), Checked["document"])
	AssertEqual("kbdsrcfx", Native["dll"])
	AssertEqual("040c", Native["lcid"])
	AssertEqual("Source Fixture", Native["text"])
	Refused(Label, Fn) {
		Extra := ""
		try Fn()
		catch as Err
			Extra := Err.Extra
		AssertEqual("invalid", Extra, Label)
	}
	Refused("format", () => LayoutComposer_CheckSource(StrReplace(_LCS_Source(), "ergopti-layout", "other"),
		_LCS_Keylayout()))
	Refused("named after another layout", () => LayoutComposer_CheckSource(
		StrReplace(_LCS_Source(), 'id = "source_fixture"', 'id = "renamed"'), _LCS_Keylayout()))
	Refused("entity", () => LayoutComposer_CheckSource(_LCS_Source(), StrReplace(_LCS_Keylayout(), "<keyboard",
		"<!ENTITY x 'y'><keyboard")))
	Refused("macOS table", () => LayoutComposer_CheckEmulation(StrReplace(_LCS_Emulation(), '"windows"', '"macos"'),
		Checked["document"]))
	Refused("not an image", () => LayoutComposer_CheckNative(Map("dll_name", "kbdsrcfx", "dlls",
		Map("x86", "AAAA", "wow64", "AAAA", "x64", "AAAA", "arm64", "AAAA")), Checked["document"]))
	Payload := _LCS_Payload()
	Payload["dll_name"] := "kbdother"
	Refused("another DLL than the source names", () => LayoutComposer_CheckNative(Payload, Checked["document"]))
	Payload := _LCS_Payload()
	Payload["dlls"].Delete("arm64")
	Refused("a missing architecture", () => LayoutComposer_CheckNative(Payload, Checked["document"]))
}





; ==================================
; ==================================
; ======= 3/ Install and use =======
; ==================================
; ==================================

Test("layout editor host: « Install and use » stores the source, stages the images, registers them elevated and switches (layout-editor-windows)",
	_LCS_InstallCase)

_LCS_InstallCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		DirCreate(LayoutRegistry_ComposerDir(Dir))
		FileAppend(_LCH_Declaration(), _LCS_Composer(Dir, "declaration_file"), "UTF-8-RAW")
		Deps := _LCS_Deps(Dir, Log, Machine)
		AssertTrue(LayoutComposer_Handle("composer_save", _LCS_Payload(), Deps))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual("true", _LCS_Bool(Result["ok"]), "installed: " . Result["detail"])
		AssertEqual("true", _LCS_Bool(Result["used"]))
		AssertEqual("composer_save", Result["action"])
		AssertEqual(_LCS_Source(), FileRead(_LCS_Composer(Dir, "source_file"), "UTF-8-RAW"))
		AssertEqual(_LCS_Keylayout(), FileRead(_LCS_Composer(Dir, "keylayout_file"), "UTF-8-RAW"))
		AssertEqual(_LCS_Emulation(), FileRead(_LCS_Composer(Dir, "emulation_file"), "UTF-8-RAW"))
		AssertFalse(FileExist(_LCS_Composer(Dir, "declaration_file")), "composition.json is gone")
		; The staged images are the bytes the page's base64 decodes to.
		Request := JsonParse(FileRead(Dir . "stage\kbdsrcfx\request.json", "UTF-8"))
		for Arch in KbdRegister_Architectures() {
			Staged := FileRead(Dir . "stage\kbdsrcfx\" . Arch . "\kbdsrcfx.dll", "RAW")
			AssertEqual(CryptoSha256Bytes(_KBR_Image(A_Index)), CryptoSha256Bytes(Staged), Arch . " staged")
			AssertEqual(CryptoSha256Bytes(Staged), Request["sha256"][Arch], Arch . " digest in the request")
		}
		AssertEqual("040c", Request["lcid"])
		AssertEqual("Source Fixture", Request["text"])
		AssertContains(_LCH_Calls(Log), "elevate /force C:\E\kbd_register.ahk install " . Dir . "stage\kbdsrcfx")
		; a001040c is the machine's other layout: the first free one is a002040c.
		AssertContains(_LCH_Calls(Log), "activate a002040c", "LoadKeyboardLayoutW gets the allocated KLID")
		AssertContains(_KBR_Plan(Machine), "copy C:\Windows\System32\kbdsrcfx.dll (redirection off)")
		AssertContains(_KBR_Plan(Machine), "input profile 040C:a002040c 0")
	} finally DirDelete(Dir, true)
}

Test("layout editor host: a refused UAC prompt, a foreign layout and a failed switch are reported, never as success (layout-editor-windows)",
	_LCS_InstallRefusalsCase)

_LCS_InstallRefusalsCase() {
	Run(Options, Machine := 0) {
		Dir := _LCH_TempDir()
		try {
			Log := []
			Machine := Machine ? Machine : _KBR_Machine()
			LayoutComposer_Handle("composer_save", _LCS_Payload(), _LCS_Deps(Dir, Log, Machine, Options))
			Result := _LCH_Pushed(Log, "composerResult")
			return Map("ok", _LCS_Bool(Result["ok"]), "code", Result["code"], "calls", _LCH_Calls(Log))
		} finally DirDelete(Dir, true)
	}
	Cancelled(Command) {
		throw OSError(1223)
	}
	Refused := Run(Map("elevate", Cancelled))
	AssertEqual("false", Refused["ok"])
	AssertEqual("elevation_refused", Refused["code"])
	AssertFalse(InStr(Refused["calls"], "activate"), "nothing is switched")
	Exit1223 := Run(Map("elevate", (*) => 1223))
	AssertEqual("elevation_refused", Exit1223["code"])
	Foreign := _KBR_Machine()
	Foreign.Seed.Call(_KBR_Layouts() . "\a009040c", "Layout File", "kbdsrcfx.dll")
	Owned := Run(Map(), Foreign)
	AssertEqual("foreign_layout", Owned["code"])
	AssertFalse(InStr(Owned["calls"], "elevate"), "no UAC prompt for a layout Ergopti cannot replace")
	NoProfile := Run(Map(), _KBR_Machine(0x8664, 0))
	AssertEqual("false", NoProfile["ok"])
	AssertEqual("profile_not_added", NoProfile["code"])
	NotLoaded := Run(Map("activated", false))
	AssertEqual("use_failed", NotLoaded["code"])
	Silent := Run(Map("elevate", (*) => 0))
	AssertEqual("install_failed", Silent["code"], "a helper that wrote no result is a failure")
}





; =============================================
; =============================================
; ======= 4/ Emulate without installing =======
; =============================================
; =============================================

Test("layout editor host: « Emulate without installing » stores the files and selects the composed layout (layout-editor-windows)",
	_LCS_EmulateCase)

_LCS_EmulateCase() {
	Dir := _LCH_TempDir()
	try {
		Log := []
		DirCreate(LayoutRegistry_ComposerDir(Dir))
		FileAppend(_LCH_Declaration(), _LCS_Composer(Dir, "declaration_file"), "UTF-8-RAW")
		Payload := _LCS_Payload()
		Payload["action"] := "composer_emulate"
		AssertTrue(LayoutComposer_Handle("composer_emulate", Payload, _LCS_Deps(Dir, Log, _KBR_Machine())))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual("composer_emulate", Result["action"])
		AssertEqual("true", _LCS_Bool(Result["ok"]))
		AssertEqual("true", _LCS_Bool(Result["used"]))
		AssertEqual("emulate composed", _LCH_Calls(Log), "no elevation, no install: the emulation selection only")
		AssertEqual(_LCS_Keylayout(), FileRead(_LCS_Composer(Dir, "keylayout_file"), "UTF-8-RAW"))
		AssertFalse(FileExist(_LCS_Composer(Dir, "declaration_file")), "composition.json is gone")
		; The emulation reads that copy back as the composed layout.
		Stored := LayoutComposer_ReadComposed(Dir)
		AssertEqual("iso", Stored["Entry"]["keycode_convention"])
		AssertEqual("windows", LayoutComposer_ReadEmulation(Dir)["platform"])
		; Already emulated: the files change under it, so the emulation reloads.
		Log := []
		LayoutComposer_Handle("composer_emulate", Payload, _LCS_Deps(Dir, Log, _KBR_Machine(), Map("selected", "composed")))
		AssertEqual("after composed install", _LCH_Calls(Log))
		; A selection that was not saved, and a reload the driver refused.
		Log := []
		LayoutComposer_Handle("composer_emulate", Payload, _LCS_Deps(Dir, Log, _KBR_Machine(), Map("emulated", false)))
		AssertEqual("emulate_not_saved", _LCH_Pushed(Log, "composerResult")["code"])
		Log := []
		Refusing := _LCS_Deps(Dir, Log, _KBR_Machine(), Map("selected", "composed"))
		Refusing["after"] := (Id, Action, OnDone) => (OnDone.Call(false), 1)
		LayoutComposer_Handle("composer_emulate", Payload, Refusing)
		AssertEqual("emulate_failed", _LCH_Pushed(Log, "composerResult")["code"])
		; An emulation table of another layout is refused and nothing is stored.
		Log := []
		Payload["emulation"] := StrReplace(_LCS_Emulation(), '"source_fixture"', '"other"')
		FileDelete(_LCS_Composer(Dir, "source_file"))
		LayoutComposer_Handle("composer_emulate", Payload, _LCS_Deps(Dir, Log, _KBR_Machine()))
		AssertEqual("invalid", _LCH_Pushed(Log, "composerResult")["code"])
		AssertFalse(FileExist(_LCS_Composer(Dir, "source_file")))
	} finally DirDelete(Dir, true)
}

Test("layout editor host: the emulation turns the base layer on with the composed layout (layout-editor-windows)",
	_LCS_EmulateOperationsCase)

_LCS_EmulateOperationsCase() {
	Snapshot := Map("valid", true, "path", "C:\c.toml", "presence", true, "content", "", "values", Map())
	Snap := (*) => Snapshot
	Operations := _LayMgrWeb_SelectionOperations("composed", "C:\c.toml", Snapshot, Snap, true)
	AssertEqual(2, Operations.Length)
	Plain := _LayMgrWeb_SelectionOperations("composed", "C:\c.toml", Snapshot, Snap)
	AssertEqual(1, Plain.Length, "a registry selection still writes only its identifier")
}

Test("layout editor host: removing the composed layout uninstalls its Windows layout elevated (layout-editor-windows)",
	_LCS_RemoveCase)

_LCS_RemoveCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		Deps := _LCS_Deps(Dir, Log, Machine)
		LayoutComposer_Handle("composer_save", _LCS_Payload(), Deps)
		AssertEqual("installed", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"])
		Log.Length := 0
		AssertTrue(LayoutComposer_Handle("composer_remove", Map(), Deps))
		AssertContains(_LCH_Calls(Log), "elevate /force C:\E\kbd_register.ahk uninstall kbdsrcfx")
		AssertEqual(1, _LCH_Pushed(Log, "composerResult")["ok"], "removed")
		AssertEqual("new", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"], "the layout is gone")
		for Field in ["source_file", "keylayout_file", "emulation_file"]
			AssertFalse(FileExist(_LCS_Composer(Dir, Field)), Field . " is deleted")
	} finally DirDelete(Dir, true)
}





; =====================================
; =====================================
; ======= 5/ The layout manager =======
; =====================================
; =====================================

Test("layout editor host: initData offers the editor and its file actions reach the store (layout-editor-windows)",
	_LCS_ManagerCase)

_LCS_ManagerCase() {
	global _LayoutCatalogueLast
	SavedCatalogue := _LayoutCatalogueLast
	Dir := _LCH_TempDir()
	try {
		_LayoutCatalogueLast := Map("index", _LMH_Index(), "source", "network", "error", 0)
		Log := []
		Deps := _LMH_Deps(Dir, Log)
		Deps["config_dir"] := Dir
		Deps["editor_strings"] := () => Map("layout_editor.btn.install", "Install")
		Deps["apply_nav"] := (Text) => (Log.Push(Map("call", "nav " . Text)),
			Map("saved", true, "applied", false, "errors", []))
		AssertTrue(LayoutManager_HandleMessage(Map("action", "ready"), Deps))
		Init := _LayMgrWeb_Json(_LCH_Pushed(Log, "initData"))
		for Flag in ['"source_editor":true', '"emulate":true', '"nav_apply":true', '"source_pick":false']
			AssertContains(Init, Flag)
		AssertTrue(LayoutManager_HandleMessage(Map("action", "source_open"), Deps))
		Opened := _LayMgrWeb_Json(_LCH_Pushed(Log, "sourceData"))
		AssertContains(Opened, '"text":null')
		AssertContains(Opened, '"layout_editor.btn.install":"Install"')
		AssertTrue(LayoutManager_HandleMessage(Map("action", "source_save", "filename", "mine.toml",
			"text", "a = 1`n"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceResult")), '"ok":true')
		AssertEqual("a = 1`n", FileRead(Dir . "layout_sources\mine.toml", "UTF-8-RAW"))
		LayoutManager_HandleMessage(Map("action", "source_open"), Deps)
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceData")), '"filename":"mine.toml"')
		AssertTrue(LayoutManager_HandleMessage(Map("action", "source_save", "filename", "../x.toml", "text", "x"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceResult")), '"code":"source_invalid_file"')
		AssertFalse(LayoutManager_HandleMessage(Map("action", "source_save", "filename", "a.toml"), Deps))
		AssertFalse(LayoutManager_HandleMessage(Map("action", "source_pick"), Deps), "WebView2 picks files itself")
		AssertTrue(LayoutManager_HandleMessage(Map("action", "nav_save", "text", "[_meta]`n"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "navResult")), '"applied":false,"errors":[],"saved":true')
		AssertFalse(LayoutManager_HandleMessage(Map("action", "nav_save"), Deps))
	} finally {
		_LayoutCatalogueLast := SavedCatalogue
		DirDelete(Dir, true)
	}
}

Test("layout editor host: the menu row opens the editor and is no longer greyed on Windows (layout-editor-windows)",
	_LCS_MenuCase)

_LCS_MenuCase() {
	Commands := _LAY_ScopeCommands()
	AssertTrue(Commands.Has(MenuCommand.OPEN_LAYOUT_EDITOR), "the command is bound")
	AssertEqual(LayoutManager_OpenEditor, Commands[MenuCommand.OPEN_LAYOUT_EDITOR])
	Manifest := JsonParse(FileRead(_SharedDir . "\menu\data\menu_manifest.json", "UTF-8"))
	Found := 0
	Walk(Node) {
		if Node is Map {
			if Node.Get("id", "") == "open_layout_editor"
				Found := Node
			for , Child in Node
				Walk(Child)
		} else if Node is Array {
			for Child in Node
				Walk(Child)
		}
	}
	Walk(Manifest)
	AssertTrue(Found is Map, "the manifest lists the row")
	AssertFalse(Found.Has("platforms"), "the row is on every platform")
	AssertFalse(Found.Has("reason_key"), "no grey reason is left")
}
