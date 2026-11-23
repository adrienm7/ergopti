; tests/unit/modules/keymap/test_layout_composer_source.ahk

; ==============================================================================
; MODULE: Layout Editor Windows Host Tests
; DESCRIPTION:
; The Windows host of the unified layout editor (docs/design/layout-editor.md
; « Windows host »): the editor window's actions and initData flags, the
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
		; install <staging> or uninstall <dll> <staging>, the folder of that DLL.
		return KbdRegister_Run(Words, Ports)
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

; The main fixture registered under another DLL name, as a re-saved source.
_LCS_Renamed(Dll) {
	Payload := _LCS_Payload()
	Payload["source"] := StrReplace(_LCS_Source(), 'dll_name = "kbdsrcfx"', 'dll_name = "' . Dll . '"')
	Payload["dll_name"] := Dll
	return Payload
}

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

; The selection is the one gate of the layer switches (maintainer decision of
; 2026-11-23): emulating the composed layout writes its identifier and leaves
; the base and AltGr switches to the user (layout-selection-is-the-gate).
Test("layout editor host: emulating the composed layout writes only its identifier (layout-selection-is-the-gate)",
	_LCS_EmulateOperationsCase)

_LCS_EmulateOperationsCase() {
	Snapshot := Map("valid", true, "path", "C:\c.toml", "presence", true, "content", "", "values", Map())
	Snap := (*) => Snapshot
	Operations := _LayMgrWeb_SelectionOperations("composed", "C:\c.toml", Snapshot, Snap)
	AssertEqual(1, Operations.Length, "a registry selection writes only its identifier")
	AssertEqual(ConfigLeaf.EMULATED_LAYOUT, Operations[1].Key, "the identifier is the selection")
}

Test("layout editor host: a source re-saved under another DLL name uninstalls the previous DLL first (kbd-dll-replaced)",
	_LCS_RenamedCase)

; The stored source is the only record of the DLL it registered: overwriting
; it left the previous DLL registered, found only by Windows Settings › Apps.
_LCS_RenamedCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		Deps := _LCS_Deps(Dir, Log, Machine)
		LayoutComposer_Handle("composer_save", _LCS_Payload(), Deps)
		AssertEqual("installed", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"])
		Log.Length := 0
		AssertTrue(LayoutComposer_Handle("composer_save", _LCS_Renamed("kbdsrcfy"), Deps))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual("true", _LCS_Bool(Result["ok"]), "installed: " . Result["detail"])
		Calls := _LCH_Calls(Log)
		Removed := InStr(Calls, "elevate /force C:\E\kbd_register.ahk uninstall kbdsrcfx")
		AssertTrue(Removed, "the previous DLL is uninstalled: " . Calls)
		AssertTrue(Removed < InStr(Calls, "install " . Dir . "stage\kbdsrcfy"), "before the new one is registered")
		AssertEqual("new", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"], "nothing is left of kbdsrcfx")
		AssertEqual("installed", KbdRegister_Inspect("kbdsrcfy", Machine.Ports)["state"])
		AssertEqual("kbdsrcfy", _LayoutComposer_StoredDll(Dir))
		; The same DLL name again upgrades in place: no uninstall.
		Log.Length := 0
		LayoutComposer_Handle("composer_save", _LCS_Renamed("kbdsrcfy"), Deps)
		AssertFalse(InStr(_LCH_Calls(Log), "uninstall"), "an upgrade keeps its DLL")
	} finally DirDelete(Dir, true)
}

Test("layout editor host: a refused uninstall of the previous DLL keeps the stored source (kbd-dll-replaced)",
	_LCS_RenamedRefusedCase)

_LCS_RenamedRefusedCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		LayoutComposer_Handle("composer_save", _LCS_Payload(), _LCS_Deps(Dir, Log, Machine))
		Cancelled(Command) {
			throw OSError(1223)
		}
		Log.Length := 0
		LayoutComposer_Handle("composer_save", _LCS_Renamed("kbdsrcfy"),
			_LCS_Deps(Dir, Log, Machine, Map("elevate", Cancelled)))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual("false", _LCS_Bool(Result["ok"]))
		AssertEqual("elevation_refused", Result["code"])
		AssertEqual("kbdsrcfx", _LayoutComposer_StoredDll(Dir), "the source of the registered DLL is kept")
		AssertEqual("installed", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"])
	} finally DirDelete(Dir, true)
}

Test("layout editor host: an emulation that replaces the source keeps the DLL, which the manager still lists (kbd-dll-replaced)",
	_LCS_EmulationKeepsDllCase)

; Emulating needs no administrator right, so it never asks to uninstall: the
; DLL stays a Windows layout the user may keep using, and the layout manager
; finds it from its uninstall entry rather than from the stored source.
_LCS_EmulationKeepsDllCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		Deps := _LCS_Deps(Dir, Log, Machine)
		LayoutComposer_Handle("composer_save", _LCS_Payload(), Deps)
		Payload := _LCS_Renamed("kbdsrcfy")
		Payload["action"] := "composer_emulate"
		Log.Length := 0
		LayoutComposer_Handle("composer_emulate", Payload, Deps)
		AssertEqual("emulate composed", _LCH_Calls(Log), "no UAC prompt for an emulation")
		AssertEqual("kbdsrcfy", _LayoutComposer_StoredDll(Dir))
		Native := LayoutManager_PageState(Deps["local_dir"], Machine.Ports)["native"]
		AssertEqual(1, Native.Length)
		AssertEqual("kbdsrcfx", Native[1]["dll"], "the DLL the source no longer names is still found")
	} finally DirDelete(Dir, true)
}

Test("layout manager: a DLL Studio registered is listed and removed after its own confirmation (kbd-dll-manager)",
	_LCS_NativeManagerCase)

; The layout manager listed no DLL Studio registered: removing one went through
; Windows Settings › Apps. Each Ergopti_kbd_<dll> uninstall entry is now a row
; whose « Uninstall » asks first, then runs the elevated uninstaller.
_LCS_NativeManagerCase() {
	Dir := _LCH_TempDir()
	try {
		Log := [], Machine := _KBR_Machine()
		Composer := _LCS_Deps(Dir, Log, Machine)
		LayoutComposer_Handle("composer_save", _LCS_Payload(), Composer)
		Native := LayoutManager_PageState(Composer["local_dir"], Machine.Ports)["native"]
		AssertEqual(1, Native.Length, "the registered DLL is listed")
		AssertEqual("kbdsrcfx", Native[1]["dll"])
		AssertEqual("Source Fixture", Native[1]["name"])
		AssertEqual("a002040c", Native[1]["klid"])
		AssertEqual(0, LayoutManager_PageState(Composer["local_dir"], _KBR_Machine().Ports)["native"].Length,
			"a machine without an Ergopti_kbd_ entry lists none")
		Manager := _LMH_Deps(Composer["local_dir"], Log)
		Manager["registry"] := Machine.Ports
		Asked := []
		Answer := false
		Manager["confirm"] := (Text) => (Asked.Push(Text), Answer)
		Manager["uninstall_native"] := (Dll) => LayoutComposer_UninstallDll(Composer, Dll)
		Message := Map("action", "uninstall", "dll", "kbdsrcfx")
		; « No »: nothing runs.
		Log.Length := 0
		AssertTrue(LayoutManager_HandleMessage(Message, Manager))
		AssertEqual(1, Asked.Length, "the removal asks first")
		AssertContains(Asked[1], "kbdsrcfx")
		AssertFalse(InStr(_LCH_Calls(Log), "elevate"), "no UAC prompt after « No »")
		AssertEqual("installed", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"])
		; « Yes »: the elevated uninstaller, then the page lists nothing.
		Answer := true
		Log.Length := 0
		AssertTrue(LayoutManager_HandleMessage(Message, Manager))
		AssertContains(_LCH_Calls(Log), "elevate /force C:\E\kbd_register.ahk uninstall kbdsrcfx")
		AssertEqual("new", KbdRegister_Inspect("kbdsrcfx", Machine.Ports)["state"])
		State := _LMH_LastPush(Log)["payload"]
		AssertEqual(0, State["native"].Length, "the row is gone")
		AssertEqual("native:kbdsrcfx", State["result"]["id"])
		AssertEqual(true, State["result"]["ok"])
		AssertEqual("Source Fixture", State["result"]["name"])
		; A DLL Ergopti did not register is refused without a question.
		Asked.Length := 0
		AssertFalse(LayoutManager_HandleMessage(Map("action", "uninstall", "dll", "kbdother"), Manager))
		AssertFalse(LayoutManager_HandleMessage(Map("action", "uninstall", "dll", "../x"), Manager))
		AssertEqual(0, Asked.Length)
	} finally DirDelete(Dir, true)
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

Test("layout editor host: the manager opens the editor in its own window (layout-editor-own-window)",
	_LCS_OwnWindowCase)

_LCS_OwnWindowCase() {
	global _LayoutCatalogueLast
	SavedCatalogue := _LayoutCatalogueLast
	Dir := _LCH_TempDir()
	try {
		_LayoutCatalogueLast := Map("index", _LMH_Index(), "source", "network", "error", 0)
		Log := []
		Deps := _LMH_Deps(Dir, Log)
		Deps["open_editor"] := () => (Log.Push(Map("call", "open editor")), true)
		AssertTrue(LayoutManager_HandleMessage(Map("action", "ready"), Deps))
		Init := _LayMgrWeb_Json(_LCH_Pushed(Log, "initData"))
		AssertContains(Init, '"source_editor":true')
		AssertTrue(LayoutManager_HandleMessage(Map("action", "open_editor"), Deps))
		AssertEqual("open editor", _LMH_Calls(Log)[_LMH_Calls(Log).Length], "the manager's button opens the editor window")
		for Action in ["source_open", "source_save", "source_pick", "source_export", "nav_save", "composer_emulate"]
			AssertFalse(LayoutManager_HandleMessage(Map("action", Action), Deps),
				"the manager page no longer carries the editor: " . Action)
		; The composer view of the manager page is retired (2026-11-14): its three messages are refused.
		for Action in ["composer_open", "composer_save", "composer_remove"]
			AssertFalse(LayoutManager_HandleMessage(Map("action", Action), Deps),
				"the manager page no longer carries the composer: " . Action)
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "install", "id", "ergol"), Deps),
			"the editor window installs no catalogue layout")
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "close"), Deps))
		AssertEqual("close", _LMH_Calls(Log)[_LMH_Calls(Log).Length], "the editor's « Close » closes its window")
	} finally {
		_LayoutCatalogueLast := SavedCatalogue
		DirDelete(Dir, true)
	}
}

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
		; A vendor folder without the export step host's identity: lua_export is not offered.
		Deps["vendor_dir"] := Dir
		; The editor window's ready answers with its flags, then with the last saved source.
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "ready"), Deps))
		Init := _LayMgrWeb_Json(_LCH_Pushed(Log, "initData"))
		for Flag in ['"source_editor":true', '"emulate":true', '"nav_apply":true', '"source_pick":false',
				'"source_export":true', '"lua_export":false', '"layout_editor.title":']
			AssertContains(Init, Flag)
		Opened := _LayMgrWeb_Json(_LCH_Pushed(Log, "sourceData"))
		AssertContains(Opened, '"text":null')
		AssertContains(Opened, '"layout_editor.btn.install":"Install"')
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "source_save", "filename", "mine.toml",
			"text", "a = 1`n"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceResult")), '"ok":true')
		AssertEqual("a = 1`n", FileRead(Dir . "layout_sources\mine.toml", "UTF-8-RAW"))
		LayoutEditorWindow_HandleMessage(Map("action", "source_open"), Deps)
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceData")), '"filename":"mine.toml"')
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "source_save", "filename", "../x.toml", "text", "x"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "sourceResult")), '"code":"source_invalid_file"')
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "source_save", "filename", "a.toml"), Deps))
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "source_pick"), Deps), "WebView2 picks files itself")
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "nav_save", "text", "[_meta]`n"), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "navResult")), '"applied":false,"errors":[],"saved":true')
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "nav_save"), Deps))
		; A download lands in the Downloads folder (here the test folder), never over a file there.
		DirCreate(Dir . "downloads")
		Deps["export_ports"] := Map("downloads_dir", () => Dir . "downloads")
		FileAppend("kept", Dir . "downloads\mine_xkb.zip", "UTF-8-RAW")
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "source_export", "filename", "mine_xkb.zip",
			"data", "UEs="), Deps))
		Written := _LayMgrWeb_Json(_LCH_Pushed(Log, "exportResult"))
		AssertContains(Written, '"ok":true')
		AssertContains(Written, "mine_xkb (2).zip")
		AssertEqual("PK", FileRead(Dir . "downloads\mine_xkb (2).zip", "UTF-8-RAW"))
		AssertEqual("kept", FileRead(Dir . "downloads\mine_xkb.zip", "UTF-8-RAW"))
		AssertTrue(LayoutEditorWindow_HandleMessage(Map("action", "source_export", "filename", "../x.zip",
			"data", "UEs="), Deps))
		AssertContains(_LayMgrWeb_Json(_LCH_Pushed(Log, "exportResult")), '"code":"source_invalid_file"')
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "source_export", "filename", "a.zip"), Deps))
	} finally {
		_LayoutCatalogueLast := SavedCatalogue
		DirDelete(Dir, true)
	}
}

Test("layout editor host: a change refused while a layout reload is pending answers the page (ltp-04-busy-answer)",
	_LCS_BusyAnswerCase)

; The page waits for one answer per change: a silent refusal left « Install »,
; « Emulate » or « Apply » pending until the window closed (LTP-04).
_LCS_BusyAnswerCase() {
	global _LayMgrWeb_RuntimeRefresh, _LayoutCatalogueLast, LAYOUT_CATALOGUE_FAILURE_BUSY
	SavedRefresh := _LayMgrWeb_RuntimeRefresh, SavedCatalogue := _LayoutCatalogueLast
	Dir := _LCH_TempDir()
	try {
		_LayoutCatalogueLast := Map("index", _LMH_Index(), "source", "network", "error", 0)
		_LayMgrWeb_RuntimeRefresh := Map("id", "ergol", "action", "install")
		Log := []
		Deps := _LMH_Deps(Dir, Log)
		Deps["config_dir"] := Dir
		Deps["apply_nav"] := (Text) => (Log.Push(Map("call", "nav")), Map("saved", true, "applied", true, "errors", []))
		for Action in ["composer_save", "composer_emulate"] {
			AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", Action, "source", "s", "keylayout", "k"), Deps),
				Action . " is refused while the reload is pending")
			Answer := _LayMgrWeb_Json(_LCH_Pushed(Log, "composerResult"))
			AssertContains(Answer, '"action":"' . Action . '"', "the refusal answers " . Action)
			AssertContains(Answer, '"ok":false')
			AssertContains(Answer, '"code":"' . LAYOUT_CATALOGUE_FAILURE_BUSY . '"')
			Log.Length := 0
		}
		AssertFalse(LayoutEditorWindow_HandleMessage(Map("action", "nav_save", "text", "[_meta]`n"), Deps))
		Nav := _LayMgrWeb_Json(_LCH_Pushed(Log, "navResult"))
		AssertContains(Nav, '"saved":false', "the navigation layer refusal answers the page")
		AssertContains(Nav, '"code":"' . LAYOUT_CATALOGUE_FAILURE_BUSY . '"')
		AssertEqual(0, _LMH_Calls(Log).Length, "nothing was applied")
	} finally {
		_LayMgrWeb_RuntimeRefresh := SavedRefresh
		_LayoutCatalogueLast := SavedCatalogue
		DirDelete(Dir, true)
	}
}

Test("layout editor host: the layout menu opens no Studio of its own (no-duplicate-studio)",
	_LCS_MenuCase)

; « Create or edit a layout… » opened the Studio the tray root's « Ergopti
; Studio… » row opens too; it left the layout menu on 2026-11-19.
_LCS_MenuCase() {
	Commands := _LAY_ScopeCommands()
	AssertFalse(Commands.Has("open_layout_editor"), "the layout menu binds no editor command")
	AssertTrue(Commands.Has(MenuCommand.LAYOUT_MANAGER), "the layout manager row stays")
	Manifest := JsonParse(FileRead(_SharedDir . "\menu\data\menu_manifest.json", "UTF-8"))
	for Row in Manifest["layout_menu"]
		AssertFalse(Row.Get("id", "") == "open_layout_editor" || Row.Get("id", "") == "ergopti_studio",
			"Ergopti Studio is a row of the tray root only")
}

Test("layout editor host: the top-level Ergopti Studio row opens the editor and greys with a pause (ergopti-studio-menu-row)",
	_LCS_StudioRowCase)

_LCS_StudioRowCase() {
	global _TrayMenuStage
	Builders := _MI_TopLevelBuilders()
	AssertTrue(Builders.Has("ergopti_studio"), "the tray root has a builder for the row")
	Body := _DriverFuncBody(Builders["ergopti_studio"].Name)
	; The test source view reads generated constants as their values (test_framework.ahk).
	; The row reopens the Studio on the tab it was left on (studio-edit-tab).
	AssertContains(Body, 'Map("ergopti_studio", LayoutEditorWindow_Open)')
	Stage := TrayMenuStage_Begin()
	try {
		Builders["ergopti_studio"].Call()
		AssertEqual(1, Stage.Length, "the builder stages exactly one row")
		Entry := Stage[1]
		AssertEqual("action", Entry["kind"], "the row is a command, registered with the startup admission")
		AssertEqual(t("menu.studio.title"), Entry["label"])
		AssertTrue(HasMethod(Entry["target"], "Call"), "the row runs a command")
		AssertFalse(Entry.Has("feature"), "the row stays live while paused, as every top-level row (EDD-1)")
	} finally {
		TrayMenuStage_Abort()
	}
	AssertFalse(IsObject(_TrayMenuStage), "the stage is released")
}

Test("layout editor host: the Studio window title is exactly « Ergopti Studio » (window-title-product-name)",
	_LCS_StudioTitleCase)

_LCS_StudioTitleCase() {
	AssertEqual("Ergopti Studio", WindowTitle(t("layout_editor.title")), "the whole title is the product name")
	AssertEqual("ErgoptiPlus — Paths", WindowTitle("Paths"), "every other window keeps the brand")
	AssertEqual("ErgoptiPlus — Ergopti Studio 2", WindowTitle("Ergopti Studio 2"))
	; Both entry points (the plain opener and the navigation-layer one) open
	; through the one host opener, which owns the caption.
	for Opener in ["LayoutEditorWindow_Open", "LayoutEditorWindow_OpenOnNav", "LayoutEditorWindow_OpenOnEdit"] {
		Body := _DriverFuncBody(Opener)
		Assert(Body != "", "the editor window opener " . Opener . " must be readable")
		AssertContains(Body, "_LayEdWin_TryOpen()", Opener . " opens through the shared host opener")
	}
	Body := _DriverFuncBody("_LayEdWin_TryOpen")
	Assert(Body != "", "the editor window host opener must be readable")
	AssertContains(Body, '"Title", t("layout_editor.title")', "the window passes its caption to the composing host")
}

Test("layout editor window: the manager's « Layout editor » shows the editor tab, the Studio row keeps its tab (studio-edit-tab)",
	_LCS_StudioEditTabCase)

; The maintainer, 2026-11-17: the row brought an open Studio left on
; « Comparer » to the front without its editor.
_LCS_StudioEditTabCase() {
	AssertContains(_DriverFuncBody("LayoutManager_HandleMessage"),
		'Deps.Get("open_editor", LayoutEditorWindow_OpenOnEdit).Call()',
		"the manager's button asks for the editor tab, as on macOS and Linux")
	AssertContains(_DriverFuncBody("_MI_StageErgoptiStudio"), "LayoutEditorWindow_Open))",
		"the top-level Studio row keeps the tab the Studio was left on")
	Body := _DriverFuncBody("_LayEdWin_PushTab")
	AssertContains(Body, '_LayEdWin_Push(Host, "studioTab", Tab)')
	AssertContains(Body, '_LayEdWin_TabWanted := ""', "the tab is pushed once")
	AssertContains(_DriverFuncBody("_LayEdWin_OnReady"), "_LayEdWin_PushTab(Host)", "a new page takes it on its ready")
}
