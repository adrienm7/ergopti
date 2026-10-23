; tests/unit/modules/keymap/test_layout_composer_host.ahk

; ==============================================================================
; MODULE: Layout Composer Host Tests (Windows)
; DESCRIPTION:
; The composed layout (docs/layout-composer.md) is installed under the reserved
; id `composed` and emulated like any registry layout. These tests replay the
; shared composer corpus (_shared/tests/corpus/layouts/composer) through the
; real emulation, pin that registry layouts still type every chord from their
; Command level, and drive the host's open, save and remove with injected
; collaborators and a scratch configuration folder.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LCH_CorpusDir() => _SharedDir . "\tests\corpus\layouts\composer\"

_LCH_Text() => FileRead(_LCH_CorpusDir() . "composed.keylayout", "UTF-8-RAW")

_LCH_Declaration() => FileRead(_LCH_CorpusDir() . "composition.json", "UTF-8-RAW")

_LCH_TempDir() {
	Dir := A_Temp . "\ergopti_composer_host_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

; Collaborators that record every call and settle the way the real ones do.
_LCH_Deps(Dir, Log, Selected := "") {
	State := {Selected: Selected}
	return Map(
		"config_dir", Dir,
		"local_dir", LayoutRegistry_LocalDir(Dir),
		"push", (Name, Payload) => Log.Push(Map("push", Name, "payload", Payload)),
		"selected", () => State.Selected,
		"select", (Id) => (Log.Push(Map("call", "select " . Id)), true),
		"after", (Id, Action, OnDone) => (Log.Push(Map("call", "after " . Id . " " . Action)),
			OnDone.Call(true), 1),
		"state", State
	)
}

_LCH_Pushed(Log, Name) {
	Index := Log.Length
	while (Index > 0) {
		if Log[Index].Has("push") && Log[Index]["push"] == Name
			return Log[Index]["payload"]
		Index -= 1
	}
	return 0
}

_LCH_Calls(Log) {
	Calls := ""
	for Item in Log
		if Item.Has("call")
			Calls .= (Calls != "" ? "; " : "") . Item["call"]
	return Calls
}





; =================================
; =================================
; ======= 2/ Shared corpus ========
; =================================
; =================================

Test("layout composer: the shared corpus types and chords what the composition says (layout-composer)",
	() => _KLT_WithEmulation(_LCH_CorpusCase))

_LCH_CorpusCase() {
	Corpus := JsonParse(FileRead(_LCH_CorpusDir() . "vectors.json", "UTF-8"))
	AssertEqual(LayoutRegistry_Composer()["id"], Corpus["layout"], "the corpus names the composer id")
	KeylayoutEmulation_Load(Corpus["layout"], _LCH_Text(), Corpus["convention"], LayoutRegistry_Keycodes())
	Prefixes := Map("meta", "#", "ctrl", "^", "alt", "!")
	Replayed := 0
	Failures := []
	for Vector in Corpus["vectors"] {
		KeylayoutEmulation_ResetDeadKey()
		Replayed += 1
		if Vector.Has("press") {
			Typed := ""
			for Press in Vector["press"]
				Typed .= _KLT_Press(Press)
			if Typed !== Vector["types"]
				Failures.Push(Vector["id"] . " typed [" . Typed . "] instead of [" . Vector["types"] . "]")
		} else {
			Sent := KeylayoutEmulation_ShortcutChar(Vector["shortcut"], Prefixes[Vector["modifier"]])
			if Sent !== Vector["sends"]
				Failures.Push(Vector["id"] . " sent [" . Sent . "] instead of [" . Vector["sends"] . "]")
		}
	}
	Assert(Replayed >= 12, "the corpus must hold at least 12 vectors")
	AssertEqual(0, Failures.Length, _KLT_Join(Failures))
}

Test("layout composer: a registry layout still sends every chord from its Command level (layout-composer)",
	() => _KLT_WithEmulation(_LCH_RegistryChordsCase))

_LCH_RegistryChordsCase() {
	for Id in ["ergopti", "ergol"] {
		_KLT_Load(Id)
		for Sc in ["SC010", "SC011", "SC012", "SC018", "SC01E"] {
			Win := KeylayoutEmulation_ShortcutChar(Sc, "#")
			AssertEqual(Win, KeylayoutEmulation_ShortcutChar(Sc), Id . " " . Sc . ": Win is the default")
			AssertEqual(Win, KeylayoutEmulation_ShortcutChar(Sc, "^"), Id . " " . Sc . ": Ctrl")
			AssertEqual(Win, KeylayoutEmulation_ShortcutChar(Sc, "^+"), Id . " " . Sc . ": Ctrl+Shift")
			AssertEqual(Win, KeylayoutEmulation_ShortcutChar(Sc, "!"), Id . " " . Sc . ": Alt")
		}
	}
}





; ===========================
; ===========================
; ======= 3/ Checking =======
; ===========================
; ===========================

Test("layout composer: the host refuses what the emulation could not read (layout-composer)",
	_LCH_CheckCase)

_LCH_CheckCase() {
	Text := _LCH_Text()
	Declaration := _LCH_Declaration()
	Checked := LayoutComposer_Check(Declaration, Text)
	Entry := Checked["entry"]
	AssertEqual("composed", Entry["id"])
	AssertEqual("Composer Corpus", Entry["name"])
	AssertEqual(StrPut(Text, "UTF-8") - 1, Entry["size"])
	AssertEqual(CryptoSha256(Text), Entry["sha256"])
	AssertEqual("iso", Entry["keycode_convention"])

	Refused(Label, Declaration2, Text2) {
		try LayoutComposer_Check(Declaration2, Text2)
		catch as Err {
			AssertEqual("invalid", Err.Extra, Label . ": the failure code")
			return
		}
		Assert(false, Label . " must be refused")
	}
	Refused("not text", 5, Text)
	Refused("not JSON", "{ nope", Text)
	Refused("unknown schema", StrReplace(Declaration, '"schema_version": 1', '"schema_version": 9'), Text)
	Refused("unknown convention", StrReplace(Declaration, '"iso"', '"jis"'), Text)
	Refused("renamed", StrReplace(Declaration, "Composer Corpus", "Other"), Text)
	Refused("not a composer product", Declaration, _KLT_LayoutText("ergol"))
	Refused("undefined action", Declaration, StrReplace(Text, 'action="azerty__dead_diaeresis"', 'action="missing"', , , 1))
	Refused("oversized", Declaration, Text . Format("{:" . LayoutRegistry_Settings()["max_file_bytes"] . "}", ""))
}





; =====================================
; =====================================
; ======= 4/ Open, save, remove =======
; =====================================
; =====================================

Test("layout composer: open sends the verified sources and no composer layout (layout-composer)",
	_LCH_OpenCase)

_LCH_OpenCase() {
	Dir := _LCH_TempDir()
	try {
		Log := []
		AssertTrue(LayoutComposer_Handle("composer_open", Map(), _LCH_Deps(Dir, Log)))
		Data := _LCH_Pushed(Log, "composerData")
		Assert(Data is Map, "composerData is pushed")
		AssertEqual("windows", Data["platform"])
		AssertEqual("full", Data["shortcuts"])
		AssertEqual(0, Data["active"])
		Ids := Map()
		for Source in Data["sources"] {
			Ids[Source["id"]] := Source
			AssertEqual(_KLT_Entry(Source["id"])["keycode_convention"], Source["convention"])
		}
		for Id in ["ergol", "ergopti", "ergopti_plus"]
			Assert(Ids.Has(Id), Id . " is offered as a source")
		AssertFalse(Ids.Has("composed"), "the composition is not its own source")
		AssertEqual(_KLT_LayoutText("ergol"), Ids["ergol"]["text"], "the verified file is sent unchanged")
	} finally DirDelete(Dir, true)
}

Test("layout composer: save stores the declaration and installs a verified composed layout (layout-composer)",
	_LCH_SaveCase)

_LCH_SaveCase() {
	Dir := _LCH_TempDir()
	try {
		Log := []
		Deps := _LCH_Deps(Dir, Log)
		Payload := Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(), "use", 0)
		AssertTrue(LayoutComposer_Handle("composer_save", Payload, Deps))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual(1, Result["ok"], "saved: " . (Result.Has("detail") ? Result["detail"] : ""))
		AssertEqual(0, Result["used"])
		AssertEqual("", _LCH_Calls(Log), "not selected without use")
		LocalDir := LayoutRegistry_LocalDir(Dir)
		Copy := LayoutRegistry_ReadLocal("composed", LocalDir)
		AssertEqual(_LCH_Text(), Copy["Text"], "the verified copy is the compiled file")
		AssertEqual(_LCH_Declaration(), LayoutComposer_ReadDeclaration(Dir), "the declaration is stored as sent")
		AssertEqual(1, _LCH_Pushed(Log, "updateState")["installed"].Has("composed") ? 1 : 0)

		; Use selects it; a layout in use reloads instead of reselecting.
		Log2 := []
		LayoutComposer_Handle("composer_save", Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(),
			"use", 1), _LCH_Deps(Dir, Log2))
		AssertEqual("select composed", _LCH_Calls(Log2))
		AssertEqual(1, _LCH_Pushed(Log2, "composerResult")["used"])
		Log3 := []
		LayoutComposer_Handle("composer_save", Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(),
			"use", 1), _LCH_Deps(Dir, Log3, "composed"))
		AssertEqual("after composed install", _LCH_Calls(Log3))
	} finally DirDelete(Dir, true)
}

Test("layout composer: a refused save writes nothing and says why (layout-composer)", _LCH_RefusedSaveCase)

_LCH_RefusedSaveCase() {
	Dir := _LCH_TempDir()
	try {
		Log := []
		LayoutComposer_Handle("composer_save", Map("declaration", _LCH_Declaration(),
			"keylayout", StrReplace(_LCH_Text(), "Composer Corpus", "Other"), "use", 1), _LCH_Deps(Dir, Log))
		Result := _LCH_Pushed(Log, "composerResult")
		AssertEqual(0, Result["ok"])
		AssertEqual("invalid", Result["code"])
		AssertFalse(FileExist(LayoutComposer_DeclarationPath(Dir)), "no declaration is stored")
		AssertFalse(FileExist(LayoutRegistry_LocalDir(Dir) . "composed.keylayout"), "no layout is installed")
		AssertEqual("", _LCH_Calls(Log))
		AssertFalse(LayoutComposer_Handle("composer_save", Map(), _LCH_Deps(Dir, [])), "a save without its files")
	} finally DirDelete(Dir, true)
}

Test("layout composer: remove uninstalls the layout, deletes the declaration and leaves the selection (layout-composer)",
	_LCH_RemoveCase)

_LCH_RemoveCase() {
	Dir := _LCH_TempDir()
	try {
		Payload := Map("declaration", _LCH_Declaration(), "keylayout", _LCH_Text(), "use", 0)
		LayoutComposer_Handle("composer_save", Payload, _LCH_Deps(Dir, []))
		Log := []
		LayoutComposer_Handle("composer_remove", Map(), _LCH_Deps(Dir, Log))
		AssertEqual(1, _LCH_Pushed(Log, "composerResult")["ok"])
		AssertFalse(FileExist(LayoutComposer_DeclarationPath(Dir)))
		AssertFalse(LayoutCatalogue_ReadInstalled(LayoutRegistry_LocalDir(Dir)).Has("composed"))
		AssertEqual("", _LCH_Calls(Log), "not selected: no reload")

		LayoutComposer_Handle("composer_save", Payload, _LCH_Deps(Dir, []))
		Log2 := []
		LayoutComposer_Handle("composer_remove", Map(), _LCH_Deps(Dir, Log2, "composed"))
		AssertEqual("after composed uninstall", _LCH_Calls(Log2), "selected: back to the system layout")
	} finally DirDelete(Dir, true)
}

Test("layout composer: boot never downloads the composed layout (layout-composer)",
	() => _KLT_WithEmulation(_LCH_BootCase))

_LCH_ReadNothing(Id, LocalDir) {
	throw Error("not installed")
}

_LCH_BootCase() {
	Log := []
	KeylayoutEmulation_Unload()
	_KLT_WithLayoutFeatures(Map("emulated_layout", "composed"), () =>
		AssertFalse(KeylayoutEmulation_Boot("C:\cfg\", Map(
			"keycodes", LayoutRegistry_Keycodes,
			"register", (*) => Log.Push("register"),
			"read_local", _LCH_ReadNothing,
			"install", (*) => Log.Push("install")))))
	AssertEqual("register", _KLT_Join(Log), "registered, never installed from the registry")
}
