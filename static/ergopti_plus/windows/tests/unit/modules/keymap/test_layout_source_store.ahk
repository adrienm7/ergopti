; tests/unit/modules/keymap/test_layout_source_store.ahk

; ==============================================================================
; MODULE: Layout Source Store Tests (Windows)
; DESCRIPTION:
; The layout editor saves its files from the layout manager window through
; ui/layout_manager/source_store.ahk. These tests replay the cases of the Lua
; store's tests (linux/tests/unit/core/ui/editors/test_layout_editor_source_store.lua)
; over an in-memory disk: the bounds (plain names, allowed types, UTF-8, size),
; reopening the last saved source, a failed write reported as such, and the
; editor's downloads written to the Downloads folder, never over a file there.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

; A store over an in-memory disk: Disk maps a path to its text.
_LSS_Ports(Disk, WriteFn := 0) {
	return Map(
		"exists", (Path) => Disk.Has(Path),
		"read", (Path, MaxBytes) => Disk.Has(Path) ? Disk[Path] : false,
		"write", WriteFn ? WriteFn : (Path, Text) => Disk[Path] := Text
	)
}

_LSS_Bytes(Values*) {
	Bytes := Buffer(Values.Length)
	for Index, Value in Values
		NumPut("UChar", Value, Bytes, Index - 1)
	return Bytes
}





; ============================
; ============================
; ======= 2/ The cases =======
; ============================
; ============================

Test("layout source store: reads its bounds from the shared layout defaults and refuses a broken table (layout-source-store)",
	_LSS_SettingsCase)

_LSS_SettingsCase() {
	Settings := SourceStore_SharedSettings()
	AssertEqual("layout_sources", Settings["folder"])
	AssertTrue(Settings["max_file_bytes"] > 0 && Settings["max_name_length"] > 0)
	Message := ""
	try SourceStore_Settings(Map("source", Map("folder", "../x", "last_file", "l", "max_file_bytes", 1,
		"max_name_length", 1)))
	catch as Err
		Message := Err.Message
	AssertContains(Message, "folder")
	Message := ""
	try SourceStore_Settings(Map())
	catch as Err
		Message := Err.Message
	AssertContains(Message, "no source table")
}

Test("layout source store: saves a source in its folder and reopens it as the last one (layout-source-store)",
	_LSS_SaveOpenCase)

_LSS_SaveOpenCase() {
	Disk := Map()
	Settings := SourceStore_SharedSettings()
	Result := SourceStore_Save(Settings, "C:\config\", Map("filename", "my_layout.toml",
		"text", 'format = "ergopti-layout"`n'), _LSS_Ports(Disk))
	AssertTrue(Result["ok"])
	AssertEqual("my_layout.toml", Result["filename"])
	AssertEqual('format = "ergopti-layout"`n', Disk["C:\config\layout_sources\my_layout.toml"])
	AssertEqual("my_layout.toml`n", Disk["C:\config\layout_sources\last_source"])
	Opened := SourceStore_Open(Settings, "C:\config\", _LSS_Ports(Disk))
	AssertEqual("my_layout.toml", Opened["filename"])
	AssertEqual('format = "ergopti-layout"`n', Opened["text"])
	AssertEqual("C:\config\layout_sources\", Opened["folder"])
}

Test("layout source store: keeps the last source when an export is saved (layout-source-store)", _LSS_ExportCase)

_LSS_ExportCase() {
	Disk := Map()
	Settings := SourceStore_SharedSettings()
	for File in [["mine.toml", "a = 1`n"], ["layers.toml", "[_meta]`n"], ["mine.keylayout", "<keyboard/>"]]
		AssertTrue(SourceStore_Save(Settings, "C:\config\", Map("filename", File[1], "text", File[2]),
			_LSS_Ports(Disk))["ok"], File[1])
	AssertEqual("mine.toml`n", Disk["C:\config\layout_sources\last_source"])
	AssertEqual("<keyboard/>", Disk["C:\config\layout_sources\mine.keylayout"])
}

Test("layout source store: refuses paths, other file types, empty, oversized and non-UTF-8 files (layout-source-store)",
	_LSS_RefusalsCase)

_LSS_RefusalsCase() {
	Disk := Map()
	Settings := SourceStore_SharedSettings()
	Big := Format("{:" . (Settings["max_file_bytes"] + 1) . "}", "")
	Samples := [["../evil.toml", "x"], ["sub\dir.toml", "x"], ["Upper.toml", "x"], ["script.sh", "x"],
		["empty.toml", ""], ["big.toml", Big], ["surrogate.toml", "caf" . Chr(0xD800)]]
	for Sample in Samples {
		Result := SourceStore_Save(Settings, "C:\config\", Map("filename", Sample[1], "text", Sample[2]), _LSS_Ports(Disk))
		AssertFalse(Result["ok"], Sample[1])
		AssertEqual(Settings["failures"]["invalid"], Result["code"], Sample[1])
	}
	AssertEqual(0, Disk.Count, "nothing was written")
	; The Lua cases of raw bytes: Latin-1, an encoded surrogate, an overlong form, past U+10FFFF.
	AssertFalse(SourceStore_IsUtf8(_LSS_Bytes(0x63, 0x61, 0x66, 0xE9)), "latin-1")
	AssertFalse(SourceStore_IsUtf8(_LSS_Bytes(0xED, 0xA0, 0x80)), "surrogate")
	AssertFalse(SourceStore_IsUtf8(_LSS_Bytes(0xC0, 0xAF)), "overlong")
	AssertFalse(SourceStore_IsUtf8(_LSS_Bytes(0xF4, 0x90, 0x80, 0x80)), "past U+10FFFF")
	Text := "ffi🦆 ễ"
	Bytes := Buffer(StrPut(Text, "UTF-8") - 1)
	StrPut(Text, Bytes, Bytes.Size, "UTF-8")
	AssertTrue(SourceStore_IsUtf8(Bytes), "multi-byte UTF-8")
	AssertTrue(SourceStore_TextIsUtf8(Text))
}

Test("layout source store: reports a failed write with its detail instead of claiming success (layout-source-store)",
	_LSS_WriteFailureCase)

_LSS_WriteFailureCase() {
	Failing(Path, Text) {
		throw Error("disk full")
	}
	Result := SourceStore_Save(SourceStore_SharedSettings(), "C:\config\", Map("filename", "a.toml", "text", "x"),
		_LSS_Ports(Map(), Failing))
	AssertFalse(Result["ok"])
	AssertEqual("write_failed", Result["code"])
	AssertEqual("disk full", Result["detail"])
}

; The export ports over an in-memory disk: Disk maps a path to its bytes, Folders lists the folders.
_LSS_ExportPorts(Disk, Downloads := "C:\Users\u\Downloads", WriteFn := 0) {
	return Map(
		"downloads_dir", () => Downloads,
		"dir_exists", (Path) => Path == "C:\Users\u\Downloads",
		"exists", (Path) => Disk.Has(Path),
		"write_bytes", WriteFn ? WriteFn : (Path, Bytes) => Disk[Path] := Bytes
	)
}

Test("layout source store: writes a download to the Downloads folder under a free name, never over a file (layout-source-store)",
	_LSS_DownloadCase)

_LSS_DownloadCase() {
	Disk := Map("C:\Users\u\Downloads\mine_xkb.zip", "the user's file")
	Settings := SourceStore_SharedSettings()
	AssertTrue(Settings["export_extensions"].Has("zip") && Settings["export_extensions"].Has("klc"))
	Paths := []
	loop 2 {
		Result := SourceStore_Export(Settings, Map("filename", "mine_xkb.zip", "data", "UEsDBAD/AQ=="),
			_LSS_ExportPorts(Disk))
		AssertTrue(Result["ok"], Result["detail"])
		Paths.Push(Result["path"])
	}
	AssertEqual("C:\Users\u\Downloads\mine_xkb (2).zip", Paths[1])
	AssertEqual("C:\Users\u\Downloads\mine_xkb (3).zip", Paths[2])
	Bytes := Disk[Paths[1]]
	AssertEqual(7, Bytes.Size)
	for Index, Value in [0x50, 0x4B, 0x03, 0x04, 0x00, 0xFF, 0x01]
		AssertEqual(Value, NumGet(Bytes, Index - 1, "UChar"), "byte " . Index)
	AssertEqual("the user's file", Disk["C:\Users\u\Downloads\mine_xkb.zip"], "never replaced")
	Result := SourceStore_Export(Settings, Map("filename", "KBDERGO.klc", "data", "//5r"), _LSS_ExportPorts(Disk))
	AssertEqual("C:\Users\u\Downloads\KBDERGO.klc", Result["path"])
}

Test("layout source store: refuses a download with a path, another type, bad base64, too many bytes or no Downloads folder (layout-source-store)",
	_LSS_DownloadRefusalsCase)

_LSS_DownloadRefusalsCase() {
	Disk := Map()
	Settings := SourceStore_SharedSettings()
	Big := Format("{:" . (Ceil(Settings["max_file_bytes"] / 3) * 4 + 4) . "}", "")
	Samples := [["../evil.zip", "UEs="], ["sub\dir.zip", "UEs="], [".hidden.zip", "UEs="], ["a..zip", "UEs="],
		["script.sh", "UEs="], ["mine.toml", "UEs="], ["mine.zip", ""], ["mine.zip", "not base64!"],
		["mine.zip", "QQ"], ["mine.zip", "UE s="], ["mine.zip", StrReplace(Big, " ", "A")]]
	for Sample in Samples {
		Result := SourceStore_Export(Settings, Map("filename", Sample[1], "data", Sample[2]), _LSS_ExportPorts(Disk))
		AssertFalse(Result["ok"], Sample[1] . " " . Sample[2])
		AssertEqual(Settings["failures"]["invalid"], Result["code"], Sample[1])
	}
	AssertEqual(0, Disk.Count, "nothing was written")
	Result := SourceStore_Export(Settings, Map("filename", "mine.zip", "data", "UEs="), _LSS_ExportPorts(Disk, "D:\nowhere"))
	AssertEqual("write_failed", Result["code"])
	AssertContains(Result["detail"], "D:\nowhere does not exist")
	Failing(Path, Bytes) {
		throw Error("disk full")
	}
	Result := SourceStore_Export(Settings, Map("filename", "mine.zip", "data", "UEs="),
		_LSS_ExportPorts(Disk, , Failing))
	AssertFalse(Result["ok"])
	AssertEqual("disk full", Result["detail"])
	Taken := _LSS_ExportPorts(Disk)
	Taken["exists"] := (Path) => true
	Result := SourceStore_Export(Settings, Map("filename", "mine.zip", "data", "UEs="), Taken)
	AssertContains(Result["detail"], "every name for mine.zip is taken")
	Message := ""
	Defaults := Map("source", Map("folder", "f", "last_file", "l", "nav_file", "n", "max_file_bytes", 1,
		"max_name_length", 1, "max_export_suffix", 2, "export_extensions", ["ZIP"], "failures", Map("invalid", "a", "write", "b")))
	try SourceStore_Settings(Defaults)
	catch as Err
		Message := Err.Message
	AssertContains(Message, "export_extensions")
}

Test("layout source store: opens nothing when the pointer names a missing or foreign file (layout-source-store)",
	_LSS_ForeignPointerCase)

_LSS_ForeignPointerCase() {
	Disk := Map("C:\config\layout_sources\last_source", "..\..\etc\passwd`n")
	Opened := SourceStore_Open(SourceStore_SharedSettings(), "C:\config\", _LSS_Ports(Disk))
	AssertFalse(Opened.Has("text"))
	AssertEqual("C:\config\layout_sources\", Opened["folder"])
	Disk := Map("C:\config\layout_sources\last_source", "gone.toml`n")
	AssertFalse(SourceStore_Open(SourceStore_SharedSettings(), "C:\config\", _LSS_Ports(Disk)).Has("text"))
}

Test("layout source store: the real disk stores a source and reopens it (layout-source-store)", _LSS_DiskCase)

_LSS_DiskCase() {
	Dir := A_Temp . "\ergopti_source_store_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	try {
		Settings := SourceStore_SharedSettings()
		Result := SourceStore_Save(Settings, Dir, Map("filename", "mine.toml", "text", 'name = "é"`n'))
		AssertTrue(Result["ok"], Result["detail"])
		Opened := SourceStore_Open(Settings, Dir)
		AssertEqual('name = "é"`n', Opened["text"])
	} finally {
		if DirExist(Dir)
			DirDelete(Dir, true)
	}
}

; Ergopti Studio's personal layouts (StudioStore_*), over an in-memory disk:
; the twin of the Lua cases of studio_store.lua.
_LSS_StudioDisk(Files) {
	return Map(
		"exists", (Path) => Files.Has(Path),
		"read", (Path, MaxBytes) => Files.Has(Path) ? Files[Path] : false,
		"write", (Path, Text) => (Files[Path] := Text, true))
}

_LSS_StudioRoundTrip() {
	Settings := StudioStore_SharedSettings()
	Files := Map()
	Ports := _LSS_StudioDisk(Files)
	Listed := StudioStore_List(Settings, "C:\cfg\", Ports)
	AssertTrue(Listed["ok"])
	AssertEqual(0, Listed["layouts"].Length, "an absent store is empty")
	B := '{"id":"user_b","rows":{"KeyQ":["q",null,null,"Q"]}}'
	A := '{"id":"user_a","name":"A"}'
	AssertTrue(StudioStore_Save(Settings, "C:\cfg\", Map("id", "user_b", "text", B), Ports)["ok"])
	AssertTrue(StudioStore_Save(Settings, "C:\cfg\", Map("id", "user_a", "text", A), Ports)["ok"])
	Listed := StudioStore_List(Settings, "C:\cfg\", Ports)["layouts"]
	AssertEqual(2, Listed.Length)
	AssertEqual(A, Listed[1], "sorted by id, the text exactly as given")
	AssertEqual(B, Listed[2], "null cells survive: the text is never re-encoded")
	AssertTrue(StudioStore_Remove(Settings, "C:\cfg\", Map("id", "user_a"), Ports)["ok"])
	AssertTrue(StudioStore_Remove(Settings, "C:\cfg\", Map("id", "user_a"), Ports)["ok"], "an absent id is already removed")
	AssertEqual(1, StudioStore_List(Settings, "C:\cfg\", Ports)["layouts"].Length)
	AssertTrue(Files.Has(StudioStore_Path(Settings, "C:\cfg\")))
}
Test("Studio layout store: stores each layout's JSON text as given (studio-layout-store)", _LSS_StudioRoundTrip)

_LSS_StudioRefusals() {
	Settings := StudioStore_SharedSettings()
	Files := Map()
	Ports := _LSS_StudioDisk(Files)
	Invalid := Settings["failures"]["invalid"]
	for Entry in [Map("id", "..\x", "text", '{"id":"..\\x"}'), Map("id", "bepo", "text", '{"id":"bepo"}'),
			Map("id", "user_a", "text", '{"id":"user_b"}'), Map("id", "user_a", "text", "not json")]
		AssertEqual(Invalid, StudioStore_Save(Settings, "C:\cfg\", Entry, Ports)["code"])
	AssertEqual(0, Files.Count, "nothing reached the disk")
	Path := StudioStore_Path(Settings, "C:\cfg\")
	Files[Path] := "{broken"
	Unreadable := Settings["failures"]["unreadable"]
	AssertEqual(Unreadable, StudioStore_List(Settings, "C:\cfg\", Ports)["code"])
	AssertEqual(Unreadable, StudioStore_Save(Settings, "C:\cfg\", Map("id", "user_a", "text", '{"id":"user_a"}'), Ports)["code"])
	AssertEqual("{broken", Files[Path], "a damaged store is never replaced")
}
Test("Studio layout store: refuses foreign ids and never replaces an unreadable store (studio-layout-store)", _LSS_StudioRefusals)

_LSS_StudioCorpus() {
	Settings := StudioStore_SharedSettings()
	Script := 'var LAYOUT_ANALYSIS_CORPORA = {}; LAYOUT_ANALYSIS_CORPORA["fr_swann"] = {};'
	Files := Map("C:\shared\ui\layout_analysis\_generated\corpus_fr_swann.js", Script)
	Ports := _LSS_StudioDisk(Files)
	Read := StudioStore_Corpus(Settings, "C:\shared", Map("id", "fr_swann"), Ports)
	AssertTrue(Read["ok"])
	AssertEqual(Script, Read["text"])
	; An id can name no other file, and a corpus that is not shipped is refused.
	for Id in ["..\..\layouts\data\defaults", "../x", "fr/swann", "FR", "", "absent_corpus"] {
		Refused := StudioStore_Corpus(Settings, "C:\shared", Map("id", Id), Ports)
		AssertFalse(Refused["ok"], Id)
		AssertEqual(Settings["failures"]["corpus"], Refused["code"], Id)
	}
}
Test("Studio layout store: reads only a generated corpus file for the Studio page (studio-corpus-tables)", _LSS_StudioCorpus)

_LSS_StudioProfile() {
	Settings := StudioStore_SharedSettings()
	Files := Map()
	Ports := _LSS_StudioDisk(Files)
	AssertEqual("", StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)["profile"], "no saved profile is the defaults")
	Text := '{"id":"mine","fingers":{"Digit6":"right_index"},"home":{}}'
	AssertTrue(StudioStore_ProfileSave(Settings, "C:\cfg\", Map("text", Text), Ports)["ok"])
	AssertEqual(Text, StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)["profile"])
	for Refused in [Map(), Map("text", ""), Map("text", "[1]"), Map("text", "{broken")]
		AssertEqual(Settings["failures"]["invalid"], StudioStore_ProfileSave(Settings, "C:\cfg\", Refused, Ports)["code"])
	AssertEqual(Text, StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)["profile"], "a refused profile changes nothing")
	AssertTrue(StudioStore_ProfileSave(Settings, "C:\cfg\", Map("reset", true), Ports)["ok"])
	AssertEqual("", StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)["profile"], "reset restores the defaults")
	Files[StudioStore_ProfilePath(Settings, "C:\cfg\")] := "{broken"
	AssertEqual(Settings["failures"]["unreadable"], StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)["code"])
}
Test("Studio layout store: keeps one fingering profile as given (studio-fingering-profile)", _LSS_StudioProfile)

; The file JSON-encodes the page's text, so each quote takes two bytes there:
; reading it back must allow for that, or a large saved document is unreadable.
_LSS_StudioDocumentBound() {
	Settings := StudioStore_SharedSettings()
	Files := Map()
	Ports := Map(
		"exists", (Path) => Files.Has(Path),
		"read", (Path, MaxBytes) => (Files.Has(Path) && StrLen(Files[Path]) <= MaxBytes) ? Files[Path] : false,
		"write", (Path, Text) => (Files[Path] := Text, true))
	Text := '{"a":"' . StrReplace(Format("{:100000}", ""), " ", '\"') . '"}'
	AssertTrue(StudioStore_ProfileSave(Settings, "C:\cfg\", Map("text", Text), Ports)["ok"])
	Loaded := StudioStore_ProfileLoad(Settings, "C:\cfg\", Ports)
	AssertTrue(Loaded["ok"], Loaded.Get("detail", ""))
	AssertEqual(Text, Loaded["profile"])
}
Test("Studio layout store: reads back a document full of quotes up to its bound (studio-document-bound)", _LSS_StudioDocumentBound)
