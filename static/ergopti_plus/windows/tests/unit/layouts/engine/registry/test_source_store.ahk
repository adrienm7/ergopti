; tests/unit/layouts/engine/registry/test_source_store.ahk

; ==============================================================================
; MODULE: Layout Source Store Tests (Windows)
; DESCRIPTION:
; The layout editor saves its files from the layout manager window through
; layouts/ui/layout_manager/source_store.ahk. These tests replay the cases of the Lua
; store's tests (linux/tests/unit/core/ui/editors/test_layout_editor_source_store.lua)
; over an in-memory disk: the bounds (plain names, allowed types, UTF-8, size),
; reopening the last saved source, and a failed write reported as such.
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
