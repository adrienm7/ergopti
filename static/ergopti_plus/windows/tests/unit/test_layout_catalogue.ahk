; tests/unit/test_layout_catalogue.ahk

; ==============================================================================
; MODULE: Layout Catalogue Tests (Windows)
; DESCRIPTION:
; The Windows layout manager installs a registry layout by keeping its
; verified .keylayout in the configuration folder, with the record the
; emulation verifies it against (layout-catalogue). These tests replay the
; shared catalogue vectors every driver replays, then drive the real module
; through a transport that serves the real registry files from memory:
; conditional refresh and its cache, installation, update, the refusal of a
; file that does not match its index, the offline installation of a layout
; shipped with the driver, and uninstallation.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================
; ==========================
; ======= 1/ Helpers =======
; ==========================
; ==========================

_LCT_RegistryDir() => _StaticDir . "\layouts\registry\"

_LCT_Read(Path) => FileRead(Path, "UTF-8-RAW")

_LCT_Index() => JsonParse(_LCT_Read(_LCT_RegistryDir() . "index.json"))

_LCT_LayoutText(Id) {
	Entry := LayoutCatalogue_Entry(_LCT_Index(), Id)
	return _LCT_Read(_LCT_RegistryDir() . StrReplace(Entry["file"], "/", "\"))
}

_LCT_TempDir() {
	Dir := A_Temp . "\ergopti_layout_catalogue_" . A_TickCount . "_" . Random(1000, 9999) . "\"
	DirCreate(Dir)
	return Dir
}

_LCT_WriteRaw(Path, Text) {
	F := FileOpen(Path, "w", "UTF-8-RAW")
	F.Write(Text)
	F.Close()
}

; A registry replayed from memory. Served maps a URL to Map("status", Code,
; "body", Text, "etag", Tag); any other URL answers HTTP 404. Offline answers
; no HTTP response at all. Every request is logged with its headers.
class _LCT_FakeRequest {
	__New(Served, Log, Offline) {
		this.Served := Served
		this.Log := Log
		this.Offline := Offline
		this.Url := ""
		this.Headers := Map()
		this.OutputPath := ""
		this.Status := 0
		this.Etag := ""
	}
	Open(Method, Url, Async := true) {
		this.Url := Url
	}
	SetRequestHeader(Name, Value) {
		this.Headers[Name] := Value
	}
	SetProxy(Proxy) {
	}
	SetTimeouts(ResolveMs, ConnectMs, SendMs, ReceiveMs) {
	}
	SetOutputFile(Path) {
		this.OutputPath := Path
	}
	Send(Body := "") {
		this.Log.Push(Map("url", this.Url, "headers", this.Headers))
		if this.Offline {
			this.Status := 0
			return true
		}
		Answer := this.Served.Get(this.Url, Map("status", 404, "body", "404: Not Found", "etag", ""))
		this.Status := Answer["status"]
		this.Etag := Answer["etag"]
		_LCT_WriteRaw(this.OutputPath, Answer["body"])
		return true
	}
	WaitForResponse(TimeoutSeconds := 0) {
		return true
	}
	GetResponseHeader(Name) {
		return (StrLower(Name) == "etag") ? this.Etag : ""
	}
	Abort() {
		return true
	}
}

_LCT_Transport(Served, Log, Offline := false) {
	return Map(
		"request", () => _LCT_FakeRequest(Served, Log, Offline),
		"resolve_proxy", (Urls, Callback) => Callback.Call(_LCT_NoProxy(Urls)),
		"schedule", (Fn, DelayMs) => Fn.Call()
	)
}

_LCT_NoProxy(Urls) {
	Resolved := Map()
	for Url in Urls
		Resolved[Url] := ""
	return Resolved
}

_LCT_Served(LayoutText, Etag := '"e1"') {
	return Map(
		LayoutRegistry_RawUrl("index.json"), Map("status", 200, "body", _LCT_Read(_LCT_RegistryDir() . "index.json"),
			"etag", Etag),
		LayoutRegistry_RawUrl("ergol/ergol.keylayout"), Map("status", 200, "body", LayoutText, "etag", "")
	)
}

_LCT_Tamper(Text, Old, New) {
	Pos := InStr(Text, Old, true)
	if !Pos
		throw Error("tamper target not found: " . Old)
	return SubStr(Text, 1, Pos - 1) . New . SubStr(Text, Pos + StrLen(Old))
}

; Runs one installation and returns [Ok, CodeOrDetail, Detail].
_LCT_Install(Id, Dir, Transport, Bundled := 0, BundledDir := "") {
	Results := []
	LayoutCatalogue_Install(Id, Dir, (Args*) => Results.Push(Args), Transport, Bundled, BundledDir)
	AssertEqual(1, Results.Length, "OnDone must be called exactly once")
	Result := Results[1]
	while (Result.Length < 3)
		Result.Push("")
	return Result
}





; =================================
; =================================
; ======= 2/ Shared vectors =======
; =================================
; =================================

Test("layout catalogue: the shared vectors choose the same index on Windows (layout-catalogue)",
	_LCT_VectorsCase)

_LCT_VectorsCase() {
	Doc := JsonParse(_LCT_Read(_SharedDir . "\tests\corpus\layouts\catalogue_vectors.json"))
	Indexes := Doc["indexes"]
	MaxBytes := Doc["max_bytes"]
	Cases := Doc["cases"]
	Assert(Cases.Length >= 10, "the shared vectors must cover every outcome")
	for Scenario in Cases {
		Name := Scenario["response"]["body"]
		if Indexes.Has(Name)
			Body := _LayoutCatalogueJson(Indexes[Name])
		else if (Name == "not_json")
			Body := "<html>proxy</html>"
		else if (Name == "no_layouts")
			Body := '{"schema_version": 1}'
		else if (Name == "oversized") {
			Body := _LayoutCatalogueJson(Indexes["fresh"])
			Loop MaxBytes
				Body .= " "
		} else
			Body := ""
		Cached := Scenario["cache"] ? Map("index", Indexes["cached"], "etag", Scenario["cached_etag"]) : 0
		Bundled := Scenario["shipped"] ? Indexes["shipped"] : 0
		Outcome := LayoutCatalogue_ResolveIndex(Scenario["response"]["status"], Body, Scenario["response"]["etag"], "",
			Cached, Bundled, MaxBytes)
		Expect := Scenario["expect"]
		Shown := ""
		if (Outcome["index"] is Map)
			for IndexName, Candidate in Indexes
				if (Candidate["layouts"][1]["version"] == Outcome["index"]["layouts"][1]["version"])
					Shown := IndexName
		AssertEqual(Expect["index"], Shown, Scenario["id"] . ": index")
		AssertEqual(Expect["source"], Outcome["source"], Scenario["id"] . ": source")
		AssertEqual(Expect["store"] ? 1 : 0, Outcome["store"] ? 1 : 0, Scenario["id"] . ": store")
		AssertEqual(Expect["etag"], Outcome["etag"], Scenario["id"] . ": etag")
		AssertEqual(Expect["error"], (Outcome["error"] is Map) ? Outcome["error"]["code"] : "", Scenario["id"] . ": error")
	}
}





; ==========================
; ==========================
; ======= 3/ Refresh =======
; ==========================
; ==========================

Test("layout catalogue: a refresh caches the index with its ETag and sends it back (layout-catalogue)",
	_LCT_RefreshCase)

_LCT_RefreshCase() {
	Dir := _LCT_TempDir()
	try {
		Log := []
		Outcomes := []
		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome),
			_LCT_Transport(_LCT_Served(_LCT_LayoutText("ergol")), Log), 0)
		AssertEqual(1, Outcomes.Length)
		AssertEqual("network", Outcomes[1]["source"])
		AssertEqual(_LCT_Read(_LCT_RegistryDir() . "index.json"), _LCT_Read(Dir . "index.json"))
		AssertEqual('"e1"', _LCT_Read(Dir . "index.etag"))
		AssertFalse(Log[1]["headers"].Has("If-None-Match"), "nothing cached yet: no condition")

		Served := Map(LayoutRegistry_RawUrl("index.json"), Map("status", 304, "body", "", "etag", '"e1"'))
		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome), _LCT_Transport(Served, Log), 0)
		AssertEqual('"e1"', Log[2]["headers"]["If-None-Match"], "the cached ETag makes the request conditional")
		AssertEqual("cache", Outcomes[2]["source"])
		AssertEqual(0, Outcomes[2]["error"], "an unchanged index is no error")

		LayoutCatalogue_Refresh(Dir, (Outcome) => Outcomes.Push(Outcome), _LCT_Transport(Map(), Log, true), 0)
		AssertEqual("cache", Outcomes[3]["source"])
		AssertEqual("offline", Outcomes[3]["error"]["code"])
		AssertFalse(FileExist(Dir . "index.json" . LAYOUT_REGISTRY_PARTIAL_SUFFIX), "no partial index is left")
	} finally DirDelete(Dir, true)
}





; =============================================
; =============================================
; ======= 4/ Install, update, uninstall =======
; =============================================
; =============================================

Test("layout catalogue: a verified download is installed and read back by the emulation (layout-catalogue)",
	_LCT_InstallCase)

_LCT_InstallCase() {
	Dir := _LCT_TempDir()
	try {
		Log := []
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(_LCT_Served(_LCT_LayoutText("ergol")), Log))
		AssertTrue(Result[1], "the installation must succeed: " . (Result[2] is String ? Result[3] : ""))
		AssertEqual("network", Result[2]["source"])
		AssertEqual(2, Log.Length, "the index then the layout")
		LocalCopy := LayoutRegistry_ReadLocal("ergol", Dir)
		AssertEqual(_LCT_LayoutText("ergol"), LocalCopy["Text"])
		AssertEqual("ansi", LocalCopy["Entry"]["keycode_convention"], "the record keeps what the emulation reads")
		AssertTrue(LayoutCatalogue_ReadInstalled(Dir).Has("ergol"))
		AssertEqual(0, LayoutCatalogue_Busy(), "the operation slot is released")
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: an update replaces the copy and its record (layout-catalogue)",
	_LCT_UpdateCase)

_LCT_UpdateCase() {
	Dir := _LCT_TempDir()
	try {
		Old := Map("id", "ergol", "version", "1.0.0", "sha256", "1111111111111111111111111111111111111111111111111111111111111111",
			"size", 10, "file", "ergol/ergol.keylayout")
		LayoutCatalogue_WriteInstalled(Dir, Map("ergol", Old))
		_LCT_WriteRaw(Dir . "ergol.keylayout", "old bytes!")
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(_LCT_Served(_LCT_LayoutText("ergol")), []))
		AssertTrue(Result[1])
		Entry := LayoutCatalogue_Entry(_LCT_Index(), "ergol")
		AssertEqual(Entry["version"], LayoutCatalogue_ReadInstalled(Dir)["ergol"]["version"])
		AssertEqual(_LCT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"])
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: a layout that does not match its index is refused (layout-catalogue)",
	_LCT_MismatchCase)

_LCT_MismatchCase() {
	Dir := _LCT_TempDir()
	try {
		Tampered := _LCT_Tamper(_LCT_LayoutText("ergol"), 'output="q"', 'output="z"')
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(_LCT_Served(Tampered), []))
		AssertFalse(Result[1])
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, Result[2])
		AssertContains(Result[3], "checksum")
		AssertFalse(FileExist(Dir . "ergol.keylayout"), "an unverified layout never reaches the local folder")
		AssertFalse(FileExist(Dir . "installed.json"), "nor the record")
		AssertFalse(FileExist(Dir . "ergol.keylayout" . LAYOUT_REGISTRY_PARTIAL_SUFFIX), "the refused download is removed")
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: a layout shipped with the driver installs offline (layout-catalogue)",
	_LCT_OfflineCase)

_LCT_OfflineCase() {
	Dir := _LCT_TempDir()
	try {
		Log := []
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), Log, true), _LCT_Index(), _LCT_RegistryDir())
		AssertTrue(Result[1], "the shipped copy must install offline: " . (Result[2] is String ? Result[3] : ""))
		AssertEqual("bundled", Result[2]["source"])
		AssertEqual(1, Log.Length, "only the index refresh is attempted")
		AssertEqual(_LCT_LayoutText("ergol"), LayoutRegistry_ReadLocal("ergol", Dir)["Text"])

		Result := _LCT_Install("ergol", _LCT_TempDir(), _LCT_Transport(Map(), [], true), 0, "")
		AssertFalse(Result[1], "offline without a shipped copy nothing can be installed")
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_DOWNLOAD, Result[2])
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: uninstalling removes the copy and the record (layout-catalogue)",
	_LCT_UninstallCase)

_LCT_UninstallCase() {
	Dir := _LCT_TempDir()
	try {
		AssertTrue(_LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())[1])
		Removed := LayoutCatalogue_Uninstall("ergol", Dir)
		AssertTrue(Removed["ok"])
		AssertFalse(FileExist(Dir . "ergol.keylayout"))
		AssertFalse(LayoutCatalogue_ReadInstalled(Dir).Has("ergol"))
		AssertThrows(() => LayoutRegistry_ReadLocal("ergol", Dir), "an uninstalled layout is not emulated")
		Again := LayoutCatalogue_Uninstall("ergol", Dir)
		AssertFalse(Again["ok"])
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_NOT_INSTALLED, Again["code"])
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: only the Ergopti family is an Ergopti layout (layout-catalogue)", _LCT_IsErgoptiCase)

_LCT_IsErgoptiCase() {
	AssertTrue(LayoutCatalogue_IsErgopti(Map("id", "ergopti_ansi", "family", "ergopti")))
	AssertFalse(LayoutCatalogue_IsErgopti(Map("id", "ergol", "family", "ergol")))
	AssertFalse(LayoutCatalogue_IsErgopti(Map("id", "ergopti_like")), "an entry without a family is not Ergopti")
	AssertFalse(LayoutCatalogue_IsErgopti(0))
}

Test("layout catalogue: a damaged record is refused, never read as empty (layout-catalogue)",
	_LCT_DamagedRecordCase)

_LCT_DamagedRecordCase() {
	Dir := _LCT_TempDir()
	try {
		for Text in ["{ damaged", '{"schema_version": 2, "layouts": {}}', '{"schema_version": 1}',
				'{"schema_version": 1, "layouts": {"ergol": {"id": "other", "sha256": "x", "version": "1", "size": 1}}}'] {
			_LCT_WriteRaw(Dir . "installed.json", Text)
			AssertThrows(() => LayoutCatalogue_ReadInstalled(Dir), "accepted: " . Text)
		}
	} finally DirDelete(Dir, true)
}

Test("layout catalogue: an installation under a damaged record writes nothing (layout-install-record-first)",
	_LCT_DamagedRecordInstallCase)

_LCT_DamagedRecordInstallCase() {
	Dir := _LCT_TempDir()
	try {
		_LCT_WriteRaw(Dir . "installed.json", "{ damaged")
		Result := _LCT_Install("ergol", Dir, _LCT_Transport(Map(), [], true), _LCT_Index(), _LCT_RegistryDir())
		AssertFalse(Result[1], "a layout cannot be recorded in a damaged record")
		AssertEqual(LAYOUT_CATALOGUE_FAILURE_RECORD, Result[2])
		AssertFalse(FileExist(Dir . "ergol.keylayout"), "no layout is written that the record cannot vouch for")
		AssertEqual("{ damaged", _LCT_Read(Dir . "installed.json"), "the damaged record is left for the user to see")
		AssertEqual(0, LayoutCatalogue_Busy(), "the operation slot is released")
	} finally DirDelete(Dir, true)
}
